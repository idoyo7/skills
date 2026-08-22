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
    - 마크다운 코드블록·인라인코드·URL·frontmatter·표 행(|로 시작)을 제거한 산문만 대상.
    - n-gram은 줄 단위, 인접한 어절로만 만든다 (줄 경계를 넘지 않는다).
    - 결과는 report 전용. exit code 는 항상 0 (파싱 실패만 2).

cls 분류:
    verb  — 용언 어미가 실제로 벗겨진 1-gram (단, 서술격 조사 이다/이고/이며 제거는 noun)
    adv   — 조사 제거 후 -히/-게로 끝나는 1-gram (솔직히, 정확히, 자연스럽게)
    ngram — 2-gram 또는 3-gram 구절
    noun  — 어미가 벗겨지지 않은 1-gram (주제 명사 등)

점수 가중: verb×1.0, adv×1.0, ngram×1.0, noun×0.3
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

# 용언 어미 정규화 패턴 (긴 것 먼저)
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

# 서술격 조사 어미 — 이걸로 끝나면 noun (동사가 아니라 명사 + 서술격)
_COPULA_ENDINGS = frozenset({"이다", "이고", "이며", "입니다", "이었다"})

# 부사형 어미
_ADV_ENDINGS = ("히", "게")

# 기능어 어근 — 이 어근으로 시작하는 어간이 어근+2자 이하면 기능어로 제거
_FUNC_ROOTS = frozenset({
    "않", "없", "있", "되", "하", "위", "아래",
    "때문", "경우", "대한", "통해", "위해", "따라",
})

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

    frontmatter, 코드블록(펜스), 인라인코드, URL, 표 행(|로 시작 또는 구분선)은 제외한다.
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
            continue

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

        # 표 행(셀) 제외 — | 로 시작하는 줄
        stripped = line.strip()
        if stripped.startswith("|"):
            continue

        # 인라인코드·URL 마스크
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
    """용언 어미를 얕게 정규화해 어간 근사를 반환한다 (하위 호환용)."""
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
        2. 서술격 조사(이다/이고/이며)를 벗긴 경우 → noun (명사 + 서술격)
        3. 기타 용언 어미가 실제로 벗겨지면 verb
        4. 나머지는 noun
    """
    after_particle = strip_particle(raw)

    # 부사형 판별
    if after_particle.endswith(_ADV_ENDINGS):
        # adv의 어간은 더 이상 어미를 제거하지 않는다 (히/게 자체가 식별 표지)
        return after_particle, "adv"

    # 용언 어미 판별
    for ending in _VERB_ENDINGS_SORTED:
        if after_particle.endswith(ending) and len(after_particle) - len(ending) >= 1:
            stem = after_particle[: -len(ending)]
            # 서술격 조사를 벗긴 경우 noun 으로 분류
            if ending in _COPULA_ENDINGS:
                return stem, "noun"
            return stem, "verb"

    return after_particle, "noun"


def _is_functional(stem: str) -> bool:
    """기능어 어근으로 시작하는 짧은 어간이면 True (불용어 처리 대상)."""
    for root in _FUNC_ROOTS:
        if stem.startswith(root) and len(stem) <= len(root) + 2:
            return True
    return False


# ---------------------------------------------------------------------------
# 불용어 로드
# ---------------------------------------------------------------------------


def load_stopwords(path: Path | None = None) -> set[str]:
    """불용어 파일을 읽어 집합으로 반환한다."""
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
# 토큰화 — 줄 단위, n-gram 생성
# ---------------------------------------------------------------------------

_EOJEOL_RE = re.compile(r"[가-힣]{2,}")

# TokenInfo: (stem, cls, raw_word, lineno)
_TokenInfo = tuple[str, str, str, int]


def _tokenize_line(
    line: str, lineno: int, stopwords: set[str]
) -> list[_TokenInfo]:
    """한 줄의 어절을 (stem, cls, raw_word, lineno) 목록으로 반환한다."""
    result: list[_TokenInfo] = []
    for raw in _EOJEOL_RE.findall(line):
        stem, cls = classify_stem(raw)
        if len(stem) < 2:
            continue
        if stem in stopwords:
            continue
        if _is_functional(stem):
            continue
        result.append((stem, cls, raw, lineno))
    return result


def _build_ngrams_per_line(
    prose_lines: list[tuple[int, str]],
    stopwords: set[str],
) -> tuple[
    list[tuple[str, str]],       # token_cls_pairs (전체 순서 유지)
    dict[int, list[str]],        # ngrams_by_n: {1:[...], 2:[...], 3:[...]}
    dict[str, str],              # gram_cls_map
    dict[str, str],              # gram_raw_map: gram → 첫 원문 단어
    dict[str, int],              # gram_line_map: gram → 첫 등장 줄번호
]:
    """줄 경계를 넘지 않는 n-gram을 만들고, 각 gram의 원문·줄번호를 기록한다.

    핵심 규칙: n-gram 창문의 어절 하나라도 불용어·기능어면 그 n-gram을 버린다.
    필터된 stem 목록이 아니라 원래 어절 순서 그대로 인접한 창문을 검사한다.
    """
    all_token_cls: list[tuple[str, str]] = []
    ngrams_by_n: dict[int, list[str]] = {1: [], 2: [], 3: []}
    gram_cls_map: dict[str, str] = {}
    gram_raw_map: dict[str, str] = {}
    gram_line_map: dict[str, int] = {}

    for lineno, line in prose_lines:
        # 원래 어절 순서대로 모두 분류 (필터 전)
        all_raws = _EOJEOL_RE.findall(line)

        # (stem, cls, raw, is_valid) — 원래 순서 유지
        full_seq: list[tuple[str, str, str, bool]] = []
        for raw in all_raws:
            stem, cls = classify_stem(raw)
            valid = (len(stem) >= 2
                     and stem not in stopwords
                     and not _is_functional(stem))
            full_seq.append((stem, cls, raw, valid))

        # 1-gram: 유효한 토큰만
        for stem, cls, raw, valid in full_seq:
            if valid:
                all_token_cls.append((stem, cls))
                ngrams_by_n[1].append(stem)
                if stem not in gram_cls_map:
                    gram_cls_map[stem] = cls
                    gram_raw_map[stem] = raw
                    gram_line_map[stem] = lineno

        # 2/3-gram: 창문 내 모든 어절이 유효해야 생성
        for n in (2, 3):
            for i in range(len(full_seq) - n + 1):
                window = full_seq[i: i + n]
                if not all(w[3] for w in window):  # 하나라도 비유효면 버림
                    continue
                gram = " ".join(w[0] for w in window)
                ngrams_by_n[n].append(gram)
                if gram not in gram_cls_map:
                    gram_cls_map[gram] = "ngram"
                    gram_raw_map[gram] = window[0][2]
                    gram_line_map[gram] = lineno

    return all_token_cls, ngrams_by_n, gram_cls_map, gram_raw_map, gram_line_map


def tokenize_prose_with_cls(
    prose_text: str, stopwords: set[str]
) -> list[tuple[str, str]]:
    """산문 텍스트에서 (stem, cls) 쌍 목록을 반환한다 (단일 블록용 하위 호환)."""
    result: list[tuple[str, str]] = []
    for raw in _EOJEOL_RE.findall(prose_text):
        stem, cls = classify_stem(raw)
        if len(stem) < 2 or stem in stopwords or _is_functional(stem):
            continue
        result.append((stem, cls))
    return result


def tokenize_prose(prose_text: str, stopwords: set[str]) -> list[str]:
    """산문 텍스트에서 어간 목록만 반환한다 (하위 호환)."""
    return [stem for stem, _ in tokenize_prose_with_cls(prose_text, stopwords)]


def extract_all_ngrams(tokens: list[str], stopwords: set[str]) -> dict[int, list[str]]:
    """n-gram 목록만 반환한다 (하위 호환)."""
    result: dict[int, list[str]] = {}
    for n in (1, 2, 3):
        grams = [" ".join(tokens[i: i + n]) for i in range(len(tokens) - n + 1)]
        if n > 1:
            grams = [g for g in grams if any(t not in stopwords for t in g.split())]
        result[n] = grams
    return result


# ---------------------------------------------------------------------------
# gram 위치 검색 — 실제 매치 줄 번호와 예시 문맥
# ---------------------------------------------------------------------------


def _find_gram_occurrences(
    gram: str,
    prose_lines: list[tuple[int, str]],
    stopwords: set[str],
    max_lines: int = 5,
) -> tuple[list[int], str]:
    """gram 이 실제로 등장하는 줄 번호 목록과 첫 매치 예시 문맥을 반환한다.

    n-gram 은 줄 안에서 연속된 어절로 매치한다.
    줄번호는 실제 매치 줄만 포함한다.
    예시는 첫 매치의 원문 단어 앞뒤 20자다.
    """
    target_stems = gram.split()
    n = len(target_stems)
    linenos: list[int] = []
    example = ""

    for lineno, line in prose_lines:
        line_tokens = _tokenize_line(line, lineno, stopwords)
        if len(line_tokens) < n:
            continue

        stems = [t[0] for t in line_tokens]
        raws  = [t[2] for t in line_tokens]

        for i in range(len(stems) - n + 1):
            if stems[i: i + n] == target_stems:
                if lineno not in linenos:
                    linenos.append(lineno)
                if not example:
                    raw_word = raws[i]
                    idx = line.find(raw_word)
                    if idx >= 0:
                        start = max(0, idx - 20)
                        end = min(len(line), idx + len(raw_word) + 20)
                        example = line[start:end].strip()
                break  # 한 줄에 한 번만 기록

        if len(linenos) >= max_lines:
            break

    return linenos, example


# ---------------------------------------------------------------------------
# 문서 파싱
# ---------------------------------------------------------------------------


def parse_doc(path: Path, stopwords: set[str]) -> dict[str, Any]:
    """마크다운 파일 하나를 파싱해 토큰·ngram·cls·예시 정보를 반환한다."""
    try:
        text = path.read_text(encoding="utf-8")
    except Exception as exc:  # noqa: BLE001
        return {
            "error": str(exc),
            "tokens": [],
            "ngrams": {1: [], 2: [], 3: []},
            "gram_cls_map": {},
            "gram_raw_map": {},
            "gram_line_map": {},
            "prose_lines": [],
            "total_tokens": 0,
        }

    prose_lines = _extract_prose_lines(text)
    (
        token_cls_pairs,
        ngrams_by_n,
        gram_cls_map,
        gram_raw_map,
        gram_line_map,
    ) = _build_ngrams_per_line(prose_lines, stopwords)

    tokens = [stem for stem, _ in token_cls_pairs]
    return {
        "tokens": tokens,
        "ngrams": ngrams_by_n,
        "gram_cls_map": gram_cls_map,
        "gram_raw_map": gram_raw_map,
        "gram_line_map": gram_line_map,
        "prose_lines": prose_lines,
        "total_tokens": len(tokens),
    }


# ---------------------------------------------------------------------------
# build 서브커맨드
# ---------------------------------------------------------------------------


def cmd_build(args: argparse.Namespace) -> int:
    stopwords = load_stopwords(Path(args.stop) if getattr(args, "stop", None) else None)

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

    min_df = max(args.min_docs, math.ceil(args.min_doc_ratio * n_docs))

    gram_docs: dict[str, set[int]] = defaultdict(set)
    gram_total: dict[str, int] = defaultdict(int)
    gram_n_map: dict[str, int] = {}
    gram_cls: dict[str, str] = {}
    gram_example: dict[str, tuple[int, str]] = {}  # gram → (lineno, raw_word)
    doc_prose_lines: dict[str, list[tuple[int, str]]] = {}

    for doc_idx, path in enumerate(corpus_paths):
        doc = parse_doc(path, stopwords)
        if "error" in doc:
            print(f"경고: {path} 읽기 실패: {doc['error']}", file=sys.stderr)
            continue

        for n in (1, 2, 3):
            for gram in doc["ngrams"].get(n, []):
                gram_total[gram] += 1
                gram_docs[gram].add(doc_idx)
                gram_n_map[gram] = n
                if gram not in gram_cls:
                    gram_cls[gram] = doc["gram_cls_map"].get(
                        gram, "ngram" if n > 1 else "noun"
                    )
                if gram not in gram_example:
                    raw = doc["gram_raw_map"].get(gram, gram.split()[0])
                    ln = doc["gram_line_map"].get(gram, 0)
                    gram_example[gram] = (ln, raw)

        doc_prose_lines[str(path)] = doc["prose_lines"]

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

        # 예시 문맥: 첫 등장 문서·줄에서 원문 단어 기반으로 찾음
        example = ""
        ln_raw = gram_example.get(key)
        if ln_raw:
            _, raw_word = ln_raw
            # 해당 문서의 prose_lines 에서 raw_word 위치를 찾는다
            for prose_lines in doc_prose_lines.values():
                for _, text in prose_lines:
                    idx = text.find(raw_word)
                    if idx >= 0:
                        start = max(0, idx - 20)
                        end = min(len(text), idx + len(raw_word) + 20)
                        example = text[start:end].strip()
                        break
                if example:
                    break

        items.append(
            {
                "key": key,
                "n": gram_n_map[key],
                "cls": cls,
                "df": df,
                "total": total,
                "per_doc": round(per_doc, 3),
                "score": round(raw_score, 4),
                "weighted_score": round(weighted_score, 4),
                "example": example,
            }
        )

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
# 문서 내 반복 검출
# ---------------------------------------------------------------------------


def _detect_intra_doc(
    ngrams_by_n: dict[int, list[str]],
    total_tokens: int,
) -> list[dict[str, Any]]:
    """문서 내 반복 어간/구절을 검출한다.

    임계값: 1-gram ≥ 4회, 2/3-gram ≥ 3회
    """
    findings: list[dict[str, Any]] = []
    seen: set[str] = set()

    for n in (1, 2, 3):
        threshold = 4 if n == 1 else 3
        count_map: dict[str, int] = defaultdict(int)
        for gram in ngrams_by_n.get(n, []):
            count_map[gram] += 1

        for key, cnt in count_map.items():
            if cnt < threshold or key in seen:
                continue
            seen.add(key)
            per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
            findings.append({"key": key, "n": n, "count": cnt, "per_1k": round(per_1k, 2)})

    return findings


# ---------------------------------------------------------------------------
# 시드 파일 로드
# ---------------------------------------------------------------------------


def load_seed(path: Path | None = None) -> list[str]:
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

_PRIMARY_CLS = frozenset({"verb", "adv", "ngram"})


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
    (
        token_cls_pairs,
        ngrams_by_n,
        gram_cls_map,
        gram_raw_map,
        gram_line_map,
    ) = _build_ngrams_per_line(prose_lines, stopwords)
    total_tokens = len(token_cls_pairs)

    findings: list[dict[str, Any]] = []
    seen: set[str] = set()

    # 1. 프로필 매치
    if getattr(args, "profile", None):
        profile_path = Path(args.profile)
        if profile_path.exists():
            profile = json.loads(profile_path.read_text(encoding="utf-8"))
            for item in profile.get("items", []):
                key = item["key"]
                n = item["n"]
                count_map: dict[str, int] = defaultdict(int)
                for gram in ngrams_by_n.get(n, []):
                    count_map[gram] += 1
                cnt = count_map.get(key, 0)
                if cnt == 0 or key in seen:
                    continue
                seen.add(key)
                linenos, example = _find_gram_occurrences(key, prose_lines, stopwords)
                per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
                cls = item.get("cls", gram_cls_map.get(key, "noun"))
                findings.append({
                    "key": key, "n": n, "cls": cls, "kind": "프로필",
                    "count": cnt, "per_1k": round(per_1k, 2),
                    "lines": linenos, "example": example,
                })

    # 2. 시드 매치 (원문 표현 직접 검색)
    seed_path = Path(args.seed) if getattr(args, "seed", None) else None
    for seed_key in load_seed(seed_path):
        if seed_key in seen:
            continue
        cnt = 0
        linenos_seed: list[int] = []
        example = ""
        for lineno, line in prose_lines:
            if seed_key in line:
                cnt += 1
                if len(linenos_seed) < 5:
                    linenos_seed.append(lineno)
                if not example:
                    idx = line.find(seed_key)
                    if idx >= 0:
                        start = max(0, idx - 20)
                        end = min(len(line), idx + len(seed_key) + 20)
                        example = line[start:end].strip()
        if cnt == 0:
            continue
        seen.add(seed_key)
        per_1k = (cnt / total_tokens * 1000) if total_tokens else 0
        _, seed_cls = classify_stem(seed_key.replace(" ", ""))
        findings.append({
            "key": seed_key, "n": len(seed_key.split()),
            "cls": seed_cls, "kind": "시드",
            "count": cnt, "per_1k": round(per_1k, 2),
            "lines": linenos_seed, "example": example,
        })

    # 3. 문서 내 반복
    for item in _detect_intra_doc(ngrams_by_n, total_tokens):
        key = item["key"]
        if key in seen:
            continue
        seen.add(key)
        linenos, example = _find_gram_occurrences(key, prose_lines, stopwords)
        cls = gram_cls_map.get(key, "ngram" if item["n"] > 1 else "noun")
        findings.append({
            "key": key, "n": item["n"], "cls": cls, "kind": "문서내",
            "count": item["count"], "per_1k": item["per_1k"],
            "lines": linenos, "example": example,
        })

    # 정렬: primary cls 먼저, 같은 그룹 내 count 내림차순
    def sort_key(f: dict[str, Any]) -> tuple[int, int]:
        return (0 if f.get("cls", "noun") in _PRIMARY_CLS else 1, -f["count"])

    top_n = getattr(args, "top", 20)
    findings_sorted = sorted(findings, key=sort_key)[:top_n]

    if args.json:
        print(json.dumps({
            "src": str(src_path),
            "total_tokens": total_tokens,
            "findings": findings_sorted,
        }, ensure_ascii=False, indent=2))
        return 0

    # 텍스트 출력
    primary_f = [f for f in findings_sorted if f.get("cls", "noun") in _PRIMARY_CLS]
    noun_f    = [f for f in findings_sorted if f.get("cls", "noun") not in _PRIMARY_CLS]

    def _print_table(rows_data: list[dict[str, Any]]) -> None:
        if not rows_data:
            return
        headers = ["키", "cls", "종류", "횟수", "/1k어절", "줄번호(앞5)", "예시"]
        rows = []
        for f in rows_data:
            lines_str = ",".join(str(ln) for ln in f.get("lines", [])[:5])
            rows.append([
                f["key"], f.get("cls", "noun"), f["kind"],
                str(f["count"]), str(f["per_1k"]), lines_str,
                (f.get("example") or "")[:40],
            ])
        widths = [len(h) for h in headers]
        for row in rows:
            for i, cell in enumerate(row):
                widths[i] = max(widths[i], len(cell))

        def fmt(cells: list[str]) -> str:
            return " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells))

        print(fmt(headers))
        print("-+-".join("-" * w for w in widths))
        for row in rows:
            print(fmt(row))

    if not findings_sorted:
        print("(반복 구절 없음)")
        return 0

    if primary_f:
        _print_table(primary_f)
    if noun_f:
        print("\n--- 주제어(참고) — noun cls, 가중치 ×0.3 ---")
        _print_table(noun_f)

    print(
        f"\n총 {len(findings_sorted)}개 표시 (전체 {len(findings)}개 검출)"
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
    ap = argparse.ArgumentParser(description="author_repeat.py — 작성자 반복 구절 자동 검출")
    ap.add_argument("--stop", default=None, help=f"불용어 파일 (기본: {_DEFAULT_STOP_FILE})")
    sub = ap.add_subparsers(dest="cmd")

    bp = sub.add_parser("build", help="작성자 프로필 만들기")
    bp.add_argument("--corpus", nargs="+", required=True)
    bp.add_argument("--out", required=True)
    bp.add_argument("--min-docs", type=int, default=3)
    bp.add_argument("--min-doc-ratio", type=float, default=0.3)

    sp = sub.add_parser("scan", help="새 문서 검사 (report 전용)")
    sp.add_argument("--src", required=True)
    sp.add_argument("--profile", default=None)
    sp.add_argument("--seed", default=None)
    sp.add_argument("--json", action="store_true")
    sp.add_argument("--top", type=int, default=20)

    sgp = sub.add_parser("suggest", help="프로필 상위 항목을 시드 파일에 합친다")
    sgp.add_argument("--profile", required=True)
    sgp.add_argument("--out", required=True)
    sgp.add_argument("--append", action="store_true")
    sgp.add_argument("--include-nouns", action="store_true")

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
