#!/usr/bin/env python3
"""author_repeat.py — 작성자 반복 구절 자동 검출.

같은 작성자(Claude 등)가 쓴 문서 여러 개에서 코퍼스 교차 빈도로 반복 표현을 잡아낸다.
금지어 목록 없이, 문서를 겹쳐 봐야 드러나는 2차 워터마크를 검출하는 것이 목표다.

CLI:
    build   --corpus <파일|디렉터리>... --out <profile.json>
            [--min-docs 3] [--min-doc-ratio 0.3]
    scan    --src <md> [--profile profile.json]
            [--seed references/author-tics.txt] [--json] [--top 20]
    suggest --profile profile.json --out references/author-tics.txt
            [--append] [--include-nouns]

구현 제약:
    - Python 3.11, 표준 라이브러리만 사용.
    - 형태소 분석기 금지 — llm_signature.py 의 strip_particle·PARTICLES 방식 재사용.
    - 마크다운 코드블록·인라인코드·URL·frontmatter·표 구분선을 제거한 산문만 대상.
    - 결과는 report 전용. exit code 는 항상 0 (파싱 실패만 2).

cls 분류:
    verb  — 용언 어미 정규화에서 어미가 실제로 벗겨진 1-gram (갈랐다→갈랐, 성기다→성기)
    adv   — 조사 제거 후 -히/-게로 끝나는 1-gram (솔직히, 정확히, 자연스럽게)
    ngram — 2-gram 또는 3-gram 구절
    noun  — 어미가 벗겨지지 않은 1-gram (주제 명사 등)

점수 가중: verb×1.0, adv×1.0, ngram×1.0, noun×0.3
suggest: 기본은 verb·adv·ngram만 시드에 포함. --include-nouns 로 noun 포함.
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
    "서도", "어도", "아도",
    "서", "고", "며", "지",
    "다",
]
_VERB_ENDINGS_SORTED = sorted(_VERB_ENDINGS, key=len, reverse=True)

# 부사형 어미 — 조사 제거 후 이걸로 끝나면 adv 로 분류
_ADV_ENDINGS = ("히", "게")

# cls 별 점수 가중치
_CLS_WEIGHT: dict[str, float] = {
    "verb": 1.0,
    "adv": 1.0,
    "ngram": 1.0,
    "noun": 0.3,
}

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

        if _TABLE_SEP_RE.match(line):
            continue

        prose = _INLINE_CODE_RE.sub(" ", line)
        prose = _URL_RE.sub(" ", prose)

        if prose.strip():
            result.append((lineno, prose))

    return result


# ---------------------------------------------------------------------------
# 조사 제거 + 용언 어미 정규화 + cls 분류
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


def classify_stem(raw: str) -> tuple[str, str]:
    """(stem, cls) 를 반환한다. cls ∈ {verb, adv, noun}.

    분류 기준:
        1. 조사 제거 후 -히/-게 로 끝나면 adv
        2. 조사 제거 후 용언 어미가 실제로 벗겨지면 verb
        3. 나머지는 noun
    """
    after_particle = strip_particle(raw)

    # 부사형 판별: 조사 제거 후 -히/-게
    if after_particle.endswith(_ADV_ENDINGS):
        stem = normalize_stem(raw)
        return stem, "adv"

    # 용언 어미 판별
    for ending in _VERB_ENDINGS_SORTED:
        if after_particle.endswith(ending) and len(after_particle) - len(ending) >= 1:
            stem = after_particle[: -len(ending)]
            return stem, "verb"

    return after_particle, "noun"


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

# 한글 어절 (2글자 이상 한글)
_EOJEOL_RE = re.compile(r"[가-힣]{2,}")


def tokenize_prose_with_cls(
    prose_text: str, stopwords: set[str]
) -> list[tuple[str, str]]:
    """산문 텍스트에서 (stem, cls) 쌍 목록을 반환한다.

    불용어·1글자·영문·숫자는 제외.
    """
    result: list[tuple[str, str]] = []
    for raw in _EOJEOL_RE.findall(prose_text):
        stem, cls = classify_stem(raw)
        if len(stem) < 2:
            continue
        if stem in stopwords:
            continue
        result.append((stem, cls))
    return result


def tokenize_prose(prose_text: str, stopwords: set[str]) -> list[str]:
    """산문 텍스트에서 어간 목록만 반환한다 (하위 호환)."""
    return [stem for stem, _ in tokenize_prose_with_cls(prose_text, stopwords)]


def make_ngrams(tokens: list[str], n: int) -> list[str]:
    """토큰 목록에서 n-gram 문자열을 만든다."""
    return [" ".join(tokens[i: i + n]) for i in range(len(tokens) - n + 1)]


def extract_all_ngrams_with_cls(
    token_cls_pairs: list[tuple[str, str]], stopwords: set[str]
) -> tuple[dict[int, list[str]], dict[str, str]]:
    """(ngrams_by_n, gram_cls_map) 을 반환한다.

    gram_cls_map: 1-gram → classify_stem 결과 cls, 2/3-gram → "ngram"
    """
    tokens = [stem for stem, _ in token_cls_pairs]
    gram_cls: dict[str, str] = {}

    # 1-gram cls — 첫 등장 기준
    for stem, cls in token_cls_pairs:
        if stem not in gram_cls:
            gram_cls[stem] = cls

    result: dict[int, list[str]] = {}
    for n in (1, 2, 3):
        grams = make_ngrams(tokens, n)
        if n == 1:
            filtered = grams
        else:
            filtered = [
                g for g in grams
                if any(t not in stopwords for t in g.split())
            ]
            for g in filtered:
                if g not in gram_cls:
                    gram_cls[g] = "ngram"
        result[n] = filtered

    return result, gram_cls


def extract_all_ngrams(
    tokens: list[str], stopwords: set[str]
) -> dict[int, list[str]]:
    """n-gram 목록만 반환한다 (하위 호환)."""
    result: dict[int, list[str]] = {}
    for n in (1, 2, 3):
        grams = make_ngrams(tokens, n)
        if n == 1:
            filtered = grams
        else:
            filtered = [
                g for g in grams
                if any(t not in stopwords for t in g.split())
            ]
        result[n] = filtered
    return result


# ---------------------------------------------------------------------------
# 문서 파싱
# ---------------------------------------------------------------------------


def parse_doc(path: Path, stopwords: set[str]) -> dict[str, Any]:
    """마크다운 파일 하나를 파싱해 토큰·ngram·cls 정보를 반환한다."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        return {"error": str(exc), "tokens": [], "ngrams": {1: [], 2: [], 3: []},
                "gram_cls_map": {}, "prose_lines": [], "total_tokens": 0}

    prose_lines = _extract_prose_lines(text)
    prose_text = " ".join(ln for _, ln in prose_lines)
    token_cls_pairs = tokenize_prose_with_cls(prose_text, stopwords)
    tokens = [stem for stem, _ in token_cls_pairs]
    ngrams, gram_cls_map = extract_all_ngrams_with_cls(token_cls_pairs, stopwords)

    return {
        "tokens": tokens,
        "ngrams": ngrams,
        "gram_cls_map": gram_cls_map,
        "prose_lines": prose_lines,
        "total_tokens": len(tokens),
    }


# ---------------------------------------------------------------------------
# 예시 문맥 추출
# ---------------------------------------------------------------------------


def _find_example_context(key: str, prose_lines: list[tuple[int, str]]) -> str:
    """key 가 처음 등장하는 줄의 앞뒤 20자를 예시 문맥으로 반환한다."""
    first_word = key.split()[0]
    for lineno, text in prose_lines:
        idx = text.find(first_word)
        if idx >= 0:
            start = max(0, idx - 20)
            end = min(len(text), idx + len(key) + 20)
            return text[start:end].strip()
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

    gram_docs: dict[str, set[int]] = defaultdict(set)
    gram_total: dict[str, int] = defaultdict(int)
    gram_n: dict[str, int] = {}
    gram_cls: dict[str, str] = {}          # 첫 등장 문서 기준 cls
    gram_example_src: dict[str, list[tuple[int, str]]] = {}

    for doc_idx, path in enumerate(corpus_paths):
        doc = parse_doc(path, stopwords)
        if "error" in doc:
            print(f"경고: {path} 읽기 실패: {doc['error']}", file=sys.stderr)
            continue

        prose_lines = doc["prose_lines"]
        doc_cls_map = doc["gram_cls_map"]

        for n, grams in doc["ngrams"].items():
            for gram in grams:
                gram_total[gram] += 1
                gram_docs[gram].add(doc_idx)
                gram_n[gram] = n
                if gram not in gram_cls:
                    gram_cls[gram] = doc_cls_map.get(gram, "ngram" if n > 1 else "noun")
                if gram not in gram_example_src:
                    gram_example_src[gram] = prose_lines

    # 프로필 조건 필터링: DF >= min_df AND 문서당 평균 >= 2
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
        raw_score = df_ratio * math.log(1 + total)
        cls = gram_cls.get(key, "noun")
        weight = _CLS_WEIGHT.get(cls, 0.3)
        weighted_score = raw_score * weight

        src_lines = gram_example_src.get(key, [])
        example = _find_example_context(key, src_lines)

        items.append(
            {
                "key": key,
                "n": gram_n[key],
                "cls": cls,
                "df": df,
                "total": total,
                "per_doc": round(per_doc, 3),
                "score": round(raw_score, 4),
                "weighted_score": round(weighted_score, 4),
                "example": example,
            }
        )

    # weighted_score 내림차순 정렬
    items.sort(key=lambda x: x["weighted_score"], reverse=True)

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
    token_cls_pairs: list[tuple[str, str]],
    doc_ngrams: dict[int, list[str]],
    gram_cls_map: dict[str, str],
    total_tokens: int,
) -> list[dict[str, Any]]:
    """문서 내 반복 어간/2-gram 을 검출한다.

    임계값:
        1-gram: >= 4회
        2-gram/3-gram: >= 3회
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
            cls = gram_cls_map.get(key, "ngram" if n > 1 else "noun")
            findings.append(
                {
                    "key": key,
                    "n": n,
                    "cls": cls,
                    "kind": "문서내",
                    "count": cnt,
                    "per_1k": round(per_1k, 2),
                }
            )

    return findings


# ---------------------------------------------------------------------------
# 줄 번호 검색
# ---------------------------------------------------------------------------


def _find_line_numbers(
    key: str, prose_lines: list[tuple[int, str]], max_lines: int = 5
) -> list[int]:
    """key 의 첫 어절이 등장하는 줄 번호 목록을 반환한다 (최대 max_lines개)."""
    first_word = key.split()[0]
    linenos: list[int] = []
    for lineno, text in prose_lines:
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

_PRIMARY_CLS = {"verb", "adv", "ngram"}


def cmd_scan(args: argparse.Namespace) -> int:
    src_path = Path(args.src)
    if not src_path.exists():
        print(f"오류: 파일을 찾을 수 없음: {src_path}", file=sys.stderr)
        return 2

    stopwords = load_stopwords(Path(args.stop) if getattr(args, "stop", None) else None)

    try:
        text = src_path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        print(f"오류: 파일 읽기 실패: {exc}", file=sys.stderr)
        return 2

    prose_lines = _extract_prose_lines(text)
    prose_text = " ".join(ln for _, ln in prose_lines)
    token_cls_pairs = tokenize_prose_with_cls(prose_text, stopwords)
    tokens = [stem for stem, _ in token_cls_pairs]
    ngrams, gram_cls_map = extract_all_ngrams_with_cls(token_cls_pairs, stopwords)
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
                cls = item.get("cls", gram_cls_map.get(key, "noun"))
                findings.append(
                    {
                        "key": key,
                        "n": n,
                        "cls": cls,
                        "kind": "프로필",
                        "count": cnt,
                        "per_1k": round(per_1k, 2),
                        "lines": linenos,
                        "example": example,
                    }
                )

    # 2. 시드 매치 (원문 표현 직접 검색)
    seed_path = Path(args.seed) if getattr(args, "seed", None) else None
    seed_items = load_seed(seed_path)
    if seed_items:
        for seed_key in seed_items:
            if seed_key in seen_keys:
                continue
            cnt = 0
            linenos_seed: list[int] = []
            for lineno, line in prose_lines:
                if seed_key in line:
                    cnt += 1
                    if len(linenos_seed) < 5:
                        linenos_seed.append(lineno)

            if cnt == 0:
                continue
            seen_keys.add(seed_key)

            per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
            example = ""
            for _, line in prose_lines:
                idx = line.find(seed_key)
                if idx >= 0:
                    s = max(0, idx - 20)
                    e = min(len(line), idx + len(seed_key) + 20)
                    example = line[s:e].strip()
                    break

            # 시드 표현의 cls: 어간 근사로 판별
            _, seed_cls = classify_stem(seed_key.replace(" ", ""))  # 공백 무시 근사
            findings.append(
                {
                    "key": seed_key,
                    "n": len(seed_key.split()),
                    "cls": seed_cls,
                    "kind": "시드",
                    "count": cnt,
                    "per_1k": round(per_1k, 2),
                    "lines": linenos_seed,
                    "example": example,
                }
            )

    # 3. 문서 내 반복 (프로필 없이도 동작)
    intra = _detect_intra_doc(token_cls_pairs, ngrams, gram_cls_map, total_tokens)
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
                "cls": item["cls"],
                "kind": "문서내",
                "count": item["count"],
                "per_1k": item["per_1k"],
                "lines": linenos_intra,
                "example": example,
            }
        )

    # 정렬: primary cls(verb/adv/ngram)를 먼저, noun은 나중. 같은 그룹 내 count 내림차순.
    def sort_key(f: dict[str, Any]) -> tuple[int, int]:
        primary = 0 if f.get("cls", "noun") in _PRIMARY_CLS else 1
        return (primary, -f["count"])

    top_n = getattr(args, "top", 20)
    findings_sorted = sorted(findings, key=sort_key)[:top_n]

    if args.json:
        out = {
            "src": str(src_path),
            "total_tokens": total_tokens,
            "findings": findings_sorted,
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    # 텍스트 출력 — primary / noun 구역 분리
    primary_findings = [f for f in findings_sorted if f.get("cls", "noun") in _PRIMARY_CLS]
    noun_findings = [f for f in findings_sorted if f.get("cls", "noun") not in _PRIMARY_CLS]

    def _print_table(rows_data: list[dict[str, Any]]) -> None:
        if not rows_data:
            return
        headers = ["키", "cls", "종류", "횟수", "/1k어절", "줄번호(앞5)", "예시"]
        rows = []
        for f in rows_data:
            lines_str = ",".join(str(ln) for ln in f.get("lines", [])[:5])
            rows.append(
                [
                    f["key"],
                    f.get("cls", "noun"),
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
            return " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

        print(fmt_row(headers))
        print("-+-".join("-" * w for w in widths))
        for row in rows:
            print(fmt_row(row))

    if not findings_sorted:
        print("(반복 구절 없음)")
        return 0

    if primary_findings:
        _print_table(primary_findings)

    if noun_findings:
        print("\n--- 주제어(참고) — noun cls, 가중치 ×0.3 ---")
        _print_table(noun_findings)

    total_shown = len(findings_sorted)
    print(
        f"\n총 {total_shown}개 표시 (전체 {len(findings)}개 검출)"
        f" / 문서 어절 수: {total_tokens}"
    )
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
    include_nouns = getattr(args, "include_nouns", False)

    # cls 필터: 기본은 verb·adv·ngram만. --include-nouns 시 noun 포함.
    new_keys: list[str] = []
    for item in profile.get("items", []):
        cls = item.get("cls", "noun")
        if cls in _PRIMARY_CLS or include_nouns:
            new_keys.append(item["key"])

    out_path = Path(args.out)

    existing_keys: set[str] = set()
    existing_lines: list[str] = []
    if args.append and out_path.exists():
        for line in out_path.read_text(encoding="utf-8").splitlines():
            existing_lines.append(line)
            stripped = line.strip()
            if stripped and not stripped.startswith("#"):
                existing_keys.add(stripped)

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
    noun_note = " (noun 포함)" if include_nouns else " (noun 제외)"
    print(
        f"시드 파일 저장: {out_path} "
        f"(신규 {len(added)}개 추가, 전체 {len(existing_keys)}개{noun_note})"
    )
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
    sgp.add_argument(
        "--include-nouns", action="store_true",
        help="noun cls(주제 명사)도 시드에 포함 (기본: verb·adv·ngram만)"
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
