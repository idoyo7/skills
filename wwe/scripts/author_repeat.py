#!/usr/bin/env python3
"""author_repeat.py — 작성자 반복 구절 자동 검출.

같은 작성자(Claude 등)가 쓴 문서 여러 개에서 코퍼스 교차 빈도로 반복 표현을 잡아낸다.
금지어 목록 없이, 문서를 겹쳐 봐야 드러나는 2차 워터마크를 검출하는 것이 목표다.

CLI:
    build   --corpus <파일|디렉터리>... --out <profile.json>
            [--min-docs 3] [--min-doc-ratio 0.3]
    scan    --src <md> [--profile profile.json]
            [--seed references/author-tics.txt] [--json] [--top 20]
    suggest --profile profile.json --out references/author-tics.txt [--append]

구현 제약:
    - Python 3.11, 표준 라이브러리만 사용.
    - 형태소 분석기 금지 — llm_signature.py 의 strip_particle·PARTICLES 방식 재사용.
    - 마크다운 코드블록·인라인코드·URL·frontmatter·표 구분선을 제거한 산문만 대상.
    - 결과는 report 전용. exit code 는 항상 0 (파싱 실패만 2).
"""

from __future__ import annotations

import argparse
import json
import math
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# 경로 상수
# ---------------------------------------------------------------------------

_SELF_DIR = Path(__file__).resolve().parent
_REFS_DIR = _SELF_DIR.parent / "references"
_DEFAULT_STOP_FILE = _REFS_DIR / "author-repeat-stop.txt"
_DEFAULT_SEED_FILE = _REFS_DIR / "author-tics.txt"

# ---------------------------------------------------------------------------
# 조사 목록 (llm_signature.py 의 PARTICLES 와 동일하게 유지)
# ---------------------------------------------------------------------------

PARTICLES = sorted(
    [
        "으로는", "에서는", "에게서", "이라는", "라는", "으로써", "로써",
        "에서", "에게", "한테", "까지", "부터", "처럼", "보다", "마다",
        "조차", "마저", "밖에", "이나", "은", "는", "이", "가", "을",
        "를", "의", "에", "와", "과", "도", "만", "로", "으로",
        "하였습니다", "했습니다", "됩니다", "습니다", "합니다", "입니다",
    ],
    key=len,
    reverse=True,
)

# 용언 어미 정규화 패턴 — 얕게만. 같은 표현이 같은 키로 모이면 충분.
# 순서가 중요: 긴 패턴 먼저(됐다 > 다).
_VERB_ENDINGS = [
    "되었습니다", "하였습니다", "하였다", "되었다",
    "됐습니다", "했습니다", "됐다", "했다",
    "한다", "된다", "하는", "되는", "된", "한",
    "이다", "이고", "이며",
    "였다", "이었다",
    "지만", "이지만",
    "면서", "으면서",
    "으면", "면",
    "지만",
    "서도", "어도", "아도",
    "서", "고", "며", "지",
    "다",
]
_VERB_ENDINGS_SORTED = sorted(_VERB_ENDINGS, key=len, reverse=True)

# ---------------------------------------------------------------------------
# 마크다운 마스킹 — 산문 추출용 (근사치)
# ---------------------------------------------------------------------------

_FRONTMATTER_RE = re.compile(r"^---\r?\n.*?\r?\n---[ \t]*\r?\n?", re.DOTALL)
_FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})")
_INLINE_CODE_RE = re.compile(r"`[^`\n]+`")
_URL_RE = re.compile(r"https?://\S+")
_TABLE_SEP_RE = re.compile(r"^\s*\|?[\s:*-]+\|[\s:*|-]+\|?\s*$")


def _extract_prose_lines(text: str) -> list[tuple[int, str]]:
    """마크다운 텍스트에서 산문 줄을 (1-based 줄번호, 텍스트) 형태로 반환한다.

    - frontmatter, 코드블록(펜스), 인라인코드, URL, 표 구분선은 제외한다.
    """
    # frontmatter 제거
    fm_match = _FRONTMATTER_RE.match(text)
    body = text[fm_match.end():] if fm_match else text
    fm_line_count = text[: fm_match.end()].count("\n") if fm_match else 0

    raw_lines = body.split("\n")
    result: list[tuple[int, str]] = []
    in_fence = False
    fence_char = ""
    fence_n = 0

    for i, line in enumerate(raw_lines):
        lineno = fm_line_count + i + 1  # 1-based

        if in_fence:
            s = line.strip()
            if s and all(c == fence_char for c in s) and len(s) >= fence_n:
                in_fence = False
            continue  # 펜스 안은 제외

        m = _FENCE_OPEN_RE.match(line)
        if m:
            fence_marker = m.group(1)
            fence_char = fence_marker[0]
            fence_n = len(fence_marker)
            in_fence = True
            continue

        # 표 구분선 제외
        if _TABLE_SEP_RE.match(line):
            continue

        # 인라인코드·URL 마스크
        prose = _INLINE_CODE_RE.sub(" ", line)
        prose = _URL_RE.sub(" ", prose)

        if prose.strip():
            result.append((lineno, prose))

    return result


# ---------------------------------------------------------------------------
# 조사 제거 + 용언 어미 정규화
# ---------------------------------------------------------------------------


def strip_particle(tok: str) -> str:
    """조사를 벗긴다 (llm_signature.py 와 동일, 최대 2회 반복)."""
    for _ in range(2):
        stripped_any = False
        for p in PARTICLES:
            if tok.endswith(p) and len(tok) - len(p) >= 2:
                tok = tok[: -len(p)]
                stripped_any = True
                break
        if not stripped_any:
            break
    return tok


def normalize_stem(tok: str) -> str:
    """용언 어미를 얕게 정규화해 어간 근사를 반환한다.

    예: "갈랐다"→"갈랐", "거칠다"→"거칠", "거칠고"→"거칠"
    완벽할 필요 없음 — 같은 표현이 같은 키로 모이면 충분.
    """
    tok = strip_particle(tok)
    for ending in _VERB_ENDINGS_SORTED:
        if tok.endswith(ending) and len(tok) - len(ending) >= 1:
            tok = tok[: -len(ending)]
            break
    return tok


# ---------------------------------------------------------------------------
# 불용어 로드
# ---------------------------------------------------------------------------


def load_stopwords(path: Path | None = None) -> set[str]:
    """불용어 파일을 읽어 집합으로 반환한다.

    파일이 없으면 빈 집합을 반환한다(빌드/스캔은 계속 진행).
    """
    target = path or _DEFAULT_STOP_FILE
    if not target.exists():
        return set()
    stops: set[str] = set()
    for line in target.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        stops.add(line)
    return stops


# ---------------------------------------------------------------------------
# 토큰화 — n-gram 추출
# ---------------------------------------------------------------------------

# 한글 어절 (1-gram 후보): 2글자 이상 한글
_EOJEOL_RE = re.compile(r"[가-힣]{2,}")
# 영문 토큰은 제외, 숫자도 제외


def tokenize_prose(prose_text: str, stopwords: set[str]) -> list[str]:
    """산문 텍스트에서 조사 제거 + 어미 정규화한 어절 목록을 반환한다.

    불용어·1글자·영문·숫자는 제외.
    """
    tokens: list[str] = []
    for raw in _EOJEOL_RE.findall(prose_text):
        stem = normalize_stem(raw)
        if len(stem) < 2:
            continue
        if stem in stopwords:
            continue
        tokens.append(stem)
    return tokens


def make_ngrams(tokens: list[str], n: int) -> list[str]:
    """토큰 목록에서 n-gram 문자열을 만든다."""
    return [" ".join(tokens[i: i + n]) for i in range(len(tokens) - n + 1)]


def extract_all_ngrams(
    tokens: list[str], stopwords: set[str]
) -> dict[int, list[str]]:
    """1-gram, 2-gram, 3-gram 목록을 {n: [key, ...]} 형태로 반환한다.

    2-gram/3-gram 에서 구성 토큰 전부가 불용어면 제외.
    """
    result: dict[int, list[str]] = {}
    for n in (1, 2, 3):
        grams = make_ngrams(tokens, n)
        if n == 1:
            filtered = grams  # 이미 tokenize_prose 에서 걸렀음
        else:
            # 구성 토큰 중 내용어가 하나라도 있으면 포함
            filtered = [
                g for g in grams
                if any(t not in stopwords for t in g.split())
            ]
        result[n] = filtered
    return result


# ---------------------------------------------------------------------------
# 문서 파싱 — build 에서 사용
# ---------------------------------------------------------------------------


def parse_doc(path: Path, stopwords: set[str]) -> dict[str, Any]:
    """마크다운 파일 하나를 파싱해 토큰 정보를 반환한다."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc), "tokens": [], "ngrams": {1: [], 2: [], 3: []}}

    prose_lines = _extract_prose_lines(text)
    prose_text = " ".join(ln for _, ln in prose_lines)
    tokens = tokenize_prose(prose_text, stopwords)
    ngrams = extract_all_ngrams(tokens, stopwords)

    # 예시 문맥용: 줄 단위로 위치를 기록해둔다
    return {
        "tokens": tokens,
        "ngrams": ngrams,
        "prose_lines": prose_lines,  # [(lineno, text), ...]
        "total_tokens": len(tokens),
    }


# ---------------------------------------------------------------------------
# 예시 문맥 추출
# ---------------------------------------------------------------------------


def _find_example_context(key: str, prose_lines: list[tuple[int, str]]) -> str:
    """key 가 처음 등장하는 줄의 앞뒤 20자를 예시 문맥으로 반환한다."""
    for lineno, text in prose_lines:
        # n-gram 키는 공백으로 연결되어 있으므로, 원본 텍스트에서 첫 단어로 검색
        first_word = key.split()[0]
        idx = text.find(first_word)
        if idx >= 0:
            start = max(0, idx - 20)
            end = min(len(text), idx + len(key) + 20)
            snippet = text[start:end].strip()
            return snippet
    return ""


# ---------------------------------------------------------------------------
# build 서브커맨드
# ---------------------------------------------------------------------------


def cmd_build(args: argparse.Namespace) -> int:
    stopwords = load_stopwords(Path(args.stop) if getattr(args, "stop", None) else None)

    # 코퍼스 파일 수집
    corpus_paths: list[Path] = []
    for src in args.corpus:
        p = Path(src)
        if p.is_dir():
            corpus_paths.extend(sorted(p.glob("**/*.md")))
        elif p.is_file():
            corpus_paths.append(p)
        else:
            print(f"경고: 경로를 찾을 수 없음: {p}", file=sys.stderr)

    if not corpus_paths:
        print("오류: 코퍼스 파일이 없습니다.", file=sys.stderr)
        return 2

    n_docs = len(corpus_paths)
    if n_docs < 5:
        print(
            f"경고: 코퍼스 문서가 {n_docs}개입니다. 5개 미만이면 통계가 약합니다.",
            file=sys.stderr,
        )

    min_docs_abs = args.min_docs
    min_docs_ratio = args.min_doc_ratio
    min_df = max(min_docs_abs, math.ceil(min_docs_ratio * n_docs))

    # 문서별 n-gram 빈도 수집
    # gram_docs[key] = set of doc indices (문서 빈도)
    # gram_total[key] = 총 출현 횟수
    # gram_n[key] = n (1, 2, 3)
    gram_docs: dict[str, set[int]] = defaultdict(set)
    gram_total: dict[str, int] = defaultdict(int)
    gram_n: dict[str, int] = {}
    # 예시 문맥용
    gram_example: dict[str, str] = {}
    # 원문 prose_lines (첫 등장 문서에서만 저장)
    gram_example_src: dict[str, list[tuple[int, str]]] = {}

    for doc_idx, path in enumerate(corpus_paths):
        doc = parse_doc(path, stopwords)
        if "error" in doc:
            print(f"경고: {path} 읽기 실패: {doc['error']}", file=sys.stderr)
            continue

        prose_lines = doc["prose_lines"]
        for n, grams in doc["ngrams"].items():
            seen_in_doc: set[str] = set()
            for gram in grams:
                gram_total[gram] += 1
                gram_docs[gram].add(doc_idx)
                gram_n[gram] = n
                if gram not in gram_example_src:
                    gram_example_src[gram] = prose_lines

    # 프로필 조건 필터링
    # 조건: DF >= min_df AND 문서당 평균 >= 2
    items: list[dict[str, Any]] = []
    for key, docs in gram_docs.items():
        df = len(docs)
        total = gram_total[key]
        per_doc = total / n_docs

        if df < min_df:
            continue
        if per_doc < 2.0:
            continue

        df_ratio = df / n_docs
        score = df_ratio * math.log(1 + total)

        # 예시 문맥
        src_lines = gram_example_src.get(key, [])
        example = _find_example_context(key, src_lines)

        items.append(
            {
                "key": key,
                "n": gram_n[key],
                "df": df,
                "total": total,
                "per_doc": round(per_doc, 3),
                "score": round(score, 4),
                "example": example,
            }
        )

    # 점수 내림차순 정렬
    items.sort(key=lambda x: x["score"], reverse=True)

    profile = {
        "built_at": datetime.now(timezone.utc).isoformat(),
        "corpus_docs": n_docs,
        "min_df_used": min_df,
        "items": items,
    }

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"프로필 저장: {out_path} ({len(items)}개 항목, {n_docs}개 문서)")
    return 0


# ---------------------------------------------------------------------------
# 문서 내 반복 검출 — scan 에서 사용
# ---------------------------------------------------------------------------


def _detect_intra_doc(
    doc_tokens: list[str],
    doc_ngrams: dict[int, list[str]],
    stopwords: set[str],
    total_tokens: int,
) -> list[dict[str, Any]]:
    """문서 내 반복 어간/2-gram 을 검출한다.

    임계값:
        1-gram: >= 4회
        2-gram: >= 3회
        3-gram: >= 3회
    """
    findings: list[dict[str, Any]] = []
    seen_keys: set[str] = set()

    for n in (1, 2, 3):
        threshold = 4 if n == 1 else 3
        grams = doc_ngrams[n]

        count_map: dict[str, int] = defaultdict(int)
        for gram in grams:
            count_map[gram] += 1

        for key, cnt in count_map.items():
            if cnt < threshold:
                continue
            if key in seen_keys:
                continue
            seen_keys.add(key)
            per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
            findings.append(
                {
                    "key": key,
                    "n": n,
                    "kind": "문서내",
                    "count": cnt,
                    "per_1k": round(per_1k, 2),
                }
            )

    return findings


# ---------------------------------------------------------------------------
# 줄 번호 검색 — scan 출력용
# ---------------------------------------------------------------------------


def _find_line_numbers(key: str, prose_lines: list[tuple[int, str]], max_lines: int = 5) -> list[int]:
    """key (stem/n-gram) 가 등장하는 줄 번호 목록을 반환한다 (최대 max_lines개)."""
    first_word = key.split()[0]
    linenos: list[int] = []
    for lineno, text in prose_lines:
        # 토큰화 후 매칭은 무거우므로, 첫 어절만 존재 여부로 근사
        if first_word in text:
            linenos.append(lineno)
            if len(linenos) >= max_lines:
                break
    return linenos


# ---------------------------------------------------------------------------
# 시드 파일 로드
# ---------------------------------------------------------------------------


def load_seed(path: Path | None = None) -> list[str]:
    """시드 파일(hand-curated 반복구)을 읽어 항목 목록을 반환한다."""
    target = path or _DEFAULT_SEED_FILE
    if not target.exists():
        return []
    items: list[str] = []
    for line in target.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        items.append(line)
    return items


# ---------------------------------------------------------------------------
# scan 서브커맨드
# ---------------------------------------------------------------------------


def cmd_scan(args: argparse.Namespace) -> int:
    src_path = Path(args.src)
    if not src_path.exists():
        print(f"오류: 파일을 찾을 수 없음: {src_path}", file=sys.stderr)
        return 2

    stopwords = load_stopwords(Path(args.stop) if getattr(args, "stop", None) else None)

    # 문서 파싱
    try:
        text = src_path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        print(f"오류: 파일 읽기 실패: {exc}", file=sys.stderr)
        return 2

    prose_lines = _extract_prose_lines(text)
    prose_text = " ".join(ln for _, ln in prose_lines)
    tokens = tokenize_prose(prose_text, stopwords)
    ngrams = extract_all_ngrams(tokens, stopwords)
    total_tokens = len(tokens)

    findings: list[dict[str, Any]] = []
    seen_keys: set[str] = set()

    # 1. 프로필 매치
    if getattr(args, "profile", None):
        profile_path = Path(args.profile)
        if profile_path.exists():
            profile = json.loads(profile_path.read_text(encoding="utf-8"))
            for item in profile.get("items", []):
                key = item["key"]
                n = item["n"]
                doc_grams = ngrams.get(n, [])

                count_map: dict[str, int] = defaultdict(int)
                for gram in doc_grams:
                    count_map[gram] += 1

                cnt = count_map.get(key, 0)
                if cnt == 0:
                    continue
                if key in seen_keys:
                    continue
                seen_keys.add(key)

                linenos = _find_line_numbers(key, prose_lines)
                per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
                example = _find_example_context(key, prose_lines)
                findings.append(
                    {
                        "key": key,
                        "n": n,
                        "kind": "프로필",
                        "count": cnt,
                        "per_1k": round(per_1k, 2),
                        "lines": linenos,
                        "example": example,
                    }
                )

    # 2. 시드 매치
    seed_path = Path(args.seed) if getattr(args, "seed", None) else None
    seed_items = load_seed(seed_path)
    if seed_items:
        # 시드는 원문 표현(어간 비정규화)이므로 prose_text 원문에서 직접 검색
        for seed_key in seed_items:
            if seed_key in seen_keys:
                continue
            # 대소문자 무시, 줄 단위 검색
            cnt = 0
            linenos: list[int] = []
            for lineno, line in prose_lines:
                if seed_key in line:
                    cnt += 1
                    if len(linenos) < 5:
                        linenos.append(lineno)

            if cnt == 0:
                continue
            seen_keys.add(seed_key)

            per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
            # 예시: 첫 등장 줄 앞뒤 20자
            example = ""
            for _, line in prose_lines:
                idx = line.find(seed_key)
                if idx >= 0:
                    s = max(0, idx - 20)
                    e = min(len(line), idx + len(seed_key) + 20)
                    example = line[s:e].strip()
                    break

            findings.append(
                {
                    "key": seed_key,
                    "n": len(seed_key.split()),
                    "kind": "시드",
                    "count": cnt,
                    "per_1k": round(per_1k, 2),
                    "lines": linenos,
                    "example": example,
                }
            )

    # 3. 문서 내 반복 (프로필 없이도 동작)
    intra = _detect_intra_doc(tokens, ngrams, stopwords, total_tokens)
    for item in intra:
        key = item["key"]
        if key in seen_keys:
            continue
        seen_keys.add(key)
        linenos_intra = _find_line_numbers(key, prose_lines)
        example = _find_example_context(key, prose_lines)
        findings.append(
            {
                "key": key,
                "n": item["n"],
                "kind": "문서내",
                "count": item["count"],
                "per_1k": item["per_1k"],
                "lines": linenos_intra,
                "example": example,
            }
        )

    # 상위 N개만
    top_n = getattr(args, "top", 20)
    findings_sorted = sorted(findings, key=lambda x: x["count"], reverse=True)[:top_n]

    if args.json:
        out = {
            "src": str(src_path),
            "total_tokens": total_tokens,
            "findings": findings_sorted,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    # 텍스트 출력
    if not findings_sorted:
        print("(반복 구절 없음)")
        return 0

    # 헤더
    headers = ["키", "종류", "횟수", "/1k어절", "줄번호(앞5)", "예시"]
    rows = []
    for f in findings_sorted:
        lines_str = ",".join(str(ln) for ln in f.get("lines", [])[:5])
        rows.append(
            [
                f["key"],
                f["kind"],
                str(f["count"]),
                str(f["per_1k"]),
                lines_str,
                (f.get("example") or "")[:40],
            ]
        )

    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt_row(cells: list[str]) -> str:
        parts = []
        for i, c in enumerate(cells):
            parts.append(c.ljust(widths[i]))
        return " | ".join(parts)

    print(fmt_row(headers))
    print("-+-".join("-" * w for w in widths))
    for row in rows:
        print(fmt_row(row))

    print(f"\n총 {len(findings_sorted)}개 표시 (전체 {len(findings)}개 검출) / 문서 어절 수: {total_tokens}")
    return 0


# ---------------------------------------------------------------------------
# suggest 서브커맨드
# ---------------------------------------------------------------------------


def cmd_suggest(args: argparse.Namespace) -> int:
    profile_path = Path(args.profile)
    if not profile_path.exists():
        print(f"오류: 프로필 파일을 찾을 수 없음: {profile_path}", file=sys.stderr)
        return 2

    profile = json.loads(profile_path.read_text(encoding="utf-8"))
    new_keys = [item["key"] for item in profile.get("items", [])]

    out_path = Path(args.out)

    # 기존 파일 읽기 (--append 시 중복 제거용)
    existing_keys: set[str] = set()
    existing_lines: list[str] = []
    if args.append and out_path.exists():
        for line in out_path.read_text(encoding="utf-8").splitlines():
            existing_lines.append(line)
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                existing_keys.add(stripped)

    # 새 항목만 추가
    added: list[str] = []
    for key in new_keys:
        if key not in existing_keys:
            added.append(key)
            existing_keys.add(key)

    if args.append and out_path.exists():
        content = "\n".join(existing_lines)
        if content and not content.endswith("\n"):
            content += "\n"
        content += "\n".join(added) + "\n"
    else:
        header = (
            "# author-tics.txt — 알려진 작성자 반복 구절 시드 목록\n"
            "# author_repeat.py scan --seed 에 넘기면 프로필 없이도 이 표현들을 잡아낸다.\n"
            "# 한 줄에 하나, # 으로 시작하는 줄은 주석.\n\n"
        )
        content = header + "\n".join(new_keys) + "\n"

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(content, encoding="utf-8")
    print(f"시드 파일 저장: {out_path} (신규 {len(added)}개 추가, 전체 {len(existing_keys)}개)")
    return 0


# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        description="author_repeat.py — 작성자 반복 구절 자동 검출"
    )
    ap.add_argument(
        "--stop",
        default=None,
        help=f"불용어 파일 (기본: {_DEFAULT_STOP_FILE})",
    )
    sub = ap.add_subparsers(dest="cmd")

    # build
    bp = sub.add_parser("build", help="작성자 프로필 만들기")
    bp.add_argument(
        "--corpus", nargs="+", required=True, help="코퍼스 파일 또는 디렉터리"
    )
    bp.add_argument("--out", required=True, help="출력 JSON 경로")
    bp.add_argument("--min-docs", type=int, default=3, help="최소 문서 빈도 절대값 (기본: 3)")
    bp.add_argument(
        "--min-doc-ratio", type=float, default=0.3, help="최소 문서 빈도 비율 (기본: 0.3)"
    )

    # scan
    sp = sub.add_parser("scan", help="새 문서 검사 (report 전용)")
    sp.add_argument("--src", required=True, help="검사할 마크다운 파일")
    sp.add_argument("--profile", default=None, help="build 로 만든 프로필 JSON")
    sp.add_argument("--seed", default=None, help="시드 파일 경로")
    sp.add_argument("--json", action="store_true", help="JSON 출력")
    sp.add_argument("--top", type=int, default=20, help="출력할 최대 항목 수 (기본: 20)")

    # suggest
    sgp = sub.add_parser("suggest", help="프로필 상위 항목을 시드 파일에 합친다")
    sgp.add_argument("--profile", required=True, help="프로필 JSON 경로")
    sgp.add_argument("--out", required=True, help="시드 파일 출력 경로")
    sgp.add_argument(
        "--append", action="store_true", help="기존 파일에 추가 (기본: 덮어쓰기)"
    )

    args = ap.parse_args(argv)

    if args.cmd == "build":
        return cmd_build(args)
    elif args.cmd == "scan":
        return cmd_scan(args)
    elif args.cmd == "suggest":
        return cmd_suggest(args)
    else:
        ap.print_help()
        return 0


if __name__ == "__main__":
    sys.exit(main())
