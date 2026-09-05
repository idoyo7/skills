#!/usr/bin/env python3
"""slop_scan.py — 게이트 S(초안 관문) 결정적 스캐너.

wwe 는 문장과 레이아웃의 AI 티를 걷는다. 이 스크립트는 그 표면 윤문으로 덮이지
않는 축 — 근거 없는 단정(S1), 지워도 손실 없는 문장(S2), 출처 없는 수치·사례(S3) —
를 세어서 승인 전에 사람에게 보여준다. 고치지 않는다.

CLI:
    scan        --src <md> [--lexicon <txt>] [--json]
    extract-llm --final <final.md> --out <11_slop.json>
    compare     --before <원본> --after <candidate> [--lexicon <txt>]
                [--llm <11_slop.json>] [--judge <11_slop_judge.json>]
                [--out <11_slop.json>] [--pending <pending.txt>]

구현 제약:
    - Python 3.11, 표준 라이브러리만. PyYAML·konlpy 금지.
    - md_shield.py 를 import 하지 않는다. 코드펜스·표·헤딩 판별은 같은 기준의
      자체 정규식으로 재현한다(설계 스펙 §2-1).
    - exit code 는 항상 0이다(argparse 사용법 오류만 2). 게이트 exit 에 기여하지 않는다.
    - 출력 스키마는 llm_signature.metric() 계약과 같다. 그 모듈을 import 하면
      md_shield 까지 딸려오므로 같은 형태를 여기서 다시 정의한다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import traceback
from pathlib import Path

DEFAULT_LEXICON = Path(__file__).resolve().parent.parent / "references" / "slop-lexicon.txt"

# ---------------------------------------------------------------------------
# 1. 보호 구간 판별 — md_shield.py 와 같은 기준을 자체 정규식으로 재현한다
# ---------------------------------------------------------------------------

FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
FENCE_CLOSE_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})[ \t]*$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*))?$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
TABLE_ROW_RE = re.compile(r"^\s*\|")
LIST_MARKER_RE = re.compile(r"^ {0,3}([-*+]|\d{0,9}[.)])(?:\s+|$)")

# 문장 분리 — `다.`·`요.`·`까?` 뒤 공백 기준. `습니다.` 는 `다.` 에 포함된다.
SENT_SPLIT_RE = re.compile(r"(?<=다\.)\s+|(?<=요\.)\s+|(?<=까\?)\s+")

SECTION_RE = re.compile(r"^\[([A-Za-z0-9_]+)\]$")
LEXICON_SECTIONS = ("S1_certainty", "S2_filler", "S3_claim", "S3_evidence")


def is_fence_close(line: str, fence_char: str, n: int) -> bool:
    m = FENCE_CLOSE_RE.match(line)
    if not m:
        return False
    run = m.group(1)
    return run[0] == fence_char and len(run) >= n


# ---------------------------------------------------------------------------
# 2. lexicon 로더
# ---------------------------------------------------------------------------


def load_lexicon(path) -> dict[str, list[dict]] | None:
    p = Path(path)
    if not p.exists():
        return None
    sections: dict[str, list[dict]] = {name: [] for name in LEXICON_SECTIONS}
    current = None
    for raw in p.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = SECTION_RE.match(line)
        if m:
            name = m.group(1)
            if name in LEXICON_SECTIONS:
                current = name
            else:
                print(f"slop_scan: lexicon 알 수 없는 절 [{name}] 무시", file=sys.stderr)
                current = None
            continue
        if current is None:
            continue
        body = line
        label = None
        if "=>" in body:
            body, label = (x.strip() for x in body.split("=>", 1))
        if body.startswith("re:"):
            pattern = body[3:].strip()
            try:
                compiled = re.compile(pattern)
            except re.error as e:
                print(
                    f"slop_scan: lexicon 정규식 오류 무시 [{current}] {line!r}: {e}",
                    file=sys.stderr,
                )
                continue
            sections[current].append({"term": label or pattern, "re": compiled})
        else:
            sections[current].append({"term": label or body, "re": re.compile(re.escape(body))})
    return sections


# ---------------------------------------------------------------------------
# 3. 산문 추출 — 보호 구간을 건너뛰고 (줄번호, 텍스트) 로 돌려준다
# ---------------------------------------------------------------------------


def prose_units(text: str) -> tuple[list[tuple[int, str]], str, set[int]]:
    """산문 줄 목록, 문서 차원 근거 코퍼스, 코드펜스 줄번호 집합을 돌려준다.

    근거 코퍼스는 표 행과 코드펜스 안 내용을 이어붙인 문자열이다 — S3 의
    "같은 수치가 문서 안 표나 코드 블록에도 나오면 근거 있음" 예외에 쓴다.
    빈 줄은 텍스트가 빈 항목으로 그대로 남긴다(문단 경계 판정에 필요하다).
    """
    lines = text.splitlines()
    units: list[tuple[int, str]] = []
    evidence: list[str] = []
    fence_lines: set[int] = set()

    i = 0
    if lines and lines[0].strip() == "---":
        for j in range(1, len(lines)):
            if lines[j].strip() == "---":
                i = j + 1
                break

    fence_char: str | None = None
    fence_n = 0
    while i < len(lines):
        line = lines[i]
        lineno = i + 1
        if fence_char is not None:
            fence_lines.add(lineno)
            if is_fence_close(line, fence_char, fence_n):
                fence_char = None
            else:
                evidence.append(line)
            i += 1
            continue
        m = FENCE_OPEN_RE.match(line)
        if m:
            run = m.group(1)
            fence_char, fence_n = run[0], len(run)
            fence_lines.add(lineno)
            i += 1
            continue
        if HEADING_RE.match(line):
            i += 1
            continue
        if TABLE_SEP_RE.match(line) or TABLE_ROW_RE.match(line):
            evidence.append(line)
            i += 1
            continue
        units.append((lineno, LIST_MARKER_RE.sub("", line, count=1)))
        i += 1
    return units, "\n".join(evidence), fence_lines


# ---------------------------------------------------------------------------
# 4. 문장·문단 분리
# ---------------------------------------------------------------------------


def sentences(units: list[tuple[int, str]]) -> list[dict]:
    """산문 줄들을 문단(빈 줄 경계) → 문장으로 쪼갠다. 항목은 {line, text, para}."""
    out: list[dict] = []
    buf: list[tuple[int, str]] = []
    para_idx = 0

    def flush() -> None:
        nonlocal buf, para_idx
        if not buf:
            return
        para_idx += 1
        parts: list[str] = []
        offsets: list[tuple[int, int]] = []
        pos = 0
        for line_no, text in buf:
            t = text.strip()
            if not t:
                continue
            offsets.append((pos, line_no))
            parts.append(t)
            pos += len(t) + 1
        joined = " ".join(parts)
        cursor = 0
        for piece in SENT_SPLIT_RE.split(joined):
            idx = joined.find(piece, cursor)
            if idx < 0:
                idx = cursor
            cursor = idx + len(piece)
            s = piece.strip()
            if not s:
                continue
            line_no = offsets[0][1] if offsets else 0
            for off, ln in offsets:
                if off <= idx:
                    line_no = ln
                else:
                    break
            out.append({"line": line_no, "text": s, "para": para_idx})
        buf = []

    for line_no, text in units:
        if not text.strip():
            flush()
            continue
        buf.append((line_no, text))
    flush()
    return out


# ---------------------------------------------------------------------------
# 5. metric 계약 — llm_signature.metric() 과 같은 형태
# ---------------------------------------------------------------------------


def metric(id_: str, label: str, kind: str, raw: dict, value: float, triggered: bool, note: str) -> dict:
    return {
        "id": id_,
        "label": label,
        "kind": kind,
        "raw": raw,
        "value": round(max(0.0, min(1.0, value)), 4),
        "triggered": bool(triggered),
        "note": note,
    }


# ---------------------------------------------------------------------------
# 5b. 지표 S1 — 확신 표지
# ---------------------------------------------------------------------------

S1_TRIGGER_DENSITY = 3.0     # 히트/1000자(공백 제외)
S1_VALUE_SCALE = 6.0


def m_S1(sents: list[dict], lex: dict, nonspace: int) -> tuple[dict, list[dict]]:
    hits: list[dict] = []
    for s in sents:
        for item in lex.get("S1_certainty", []):
            for _ in item["re"].finditer(s["text"]):
                hits.append({"id": "S1", "term": item["term"], "line": s["line"], "quote": s["text"][:80]})
    density = (len(hits) / nonspace * 1000.0) if nonspace else 0.0
    triggered = density >= S1_TRIGGER_DENSITY
    value = min(1.0, density / S1_VALUE_SCALE)
    note = (
        f"확신 표지 {len(hits)}건 / 공백제외 {nonspace}자 → 밀도 {density:.2f}"
        f" (임계 {S1_TRIGGER_DENSITY})"
    )
    raw = {"hits": len(hits), "chars": nonspace, "density": round(density, 3)}
    return metric("S1", "확신 표지", "report", raw, value, triggered, note), hits


# ---------------------------------------------------------------------------
# 5b-2. 지표 S2 — 필러
#
# 길이 상한과 잔여 음절 기준은 스펙 초기값(30자·4음절)보다 넓다. 그 값으로는
# tests/sig_corpus 12편에서 필러가 0건이라 지표가 아무 말도 하지 않는다. 오탐을
# 감수하고 느슨하게 시작한 뒤 보정 태스크의 실측으로 조인다.
# ---------------------------------------------------------------------------

S2_MAX_CHARS = 40            # 공백 제외 글자 수 상한 (스펙 초기값 30에서 넓혔다 — 아래 주석)
S2_RESIDUAL_SYLLABLES = 6    # 남은 한글 음절이 이 값 미만이면 필러 (스펙 초기값 4에서 넓혔다)
S2_TRIGGER_HITS = 2
S2_TRIGGER_RATIO = 0.05
S2_VALUE_SCALE = 0.15

# lexicon 항목을 뺀 나머지에서 조사·어미·강조부사를 걷어낸다. 긴 것을 먼저 둔다 —
# 정규식 교대는 왼쪽 우선이라 순서가 바뀌면 `에서` 가 `에` 로 잘린다.
_S2_STRIP_RE = re.compile(
    "|".join([
        "것이다", "습니다", "입니다", "였다", "했다", "된다", "한다", "하다", "이다", "되다", "지만",
        "이라는", "라는", "에서", "에게", "으로", "까지", "부터", "처럼", "보다",
        "상당히", "무척", "정말", "물론", "사실", "특히", "매우", "아주", "꽤", "참",
        "은", "는", "이", "가", "을", "를", "의", "에", "와", "과", "도", "만", "로", "고", "며", "서",
    ])
)


def m_S2(sents: list[dict], lex: dict) -> tuple[dict, list[dict]]:
    hits: list[dict] = []
    total = len(sents)
    for s in sents:
        text = s["text"]
        if len(re.sub(r"\s", "", text)) > S2_MAX_CHARS:
            continue
        matched = None
        residual = text
        for item in lex.get("S2_filler", []):
            if item["re"].search(residual):
                if matched is None:
                    matched = item["term"]
                residual = item["re"].sub("", residual)
        if matched is None:
            continue
        residual = _S2_STRIP_RE.sub("", residual)
        if len(re.findall(r"[가-힣]", residual)) >= S2_RESIDUAL_SYLLABLES:
            continue
        hits.append({"id": "S2", "term": matched, "line": s["line"], "quote": text[:80]})
    ratio = (len(hits) / total) if total else 0.0
    triggered = len(hits) >= S2_TRIGGER_HITS or (total > 0 and ratio >= S2_TRIGGER_RATIO and hits)
    value = min(1.0, ratio / S2_VALUE_SCALE)
    note = (
        f"필러 문장 {len(hits)} / 전체 {total} = {ratio:.1%}"
        f" (임계 {S2_TRIGGER_HITS}문장 또는 {S2_TRIGGER_RATIO:.0%})"
    )
    raw = {"hits": len(hits), "sentences": total, "ratio": round(ratio, 4)}
    return metric("S2", "필러", "report", raw, value, bool(triggered), note), hits


# ---------------------------------------------------------------------------
# 5b-3. 지표 S3 — 미검증 사례
# ---------------------------------------------------------------------------

S3_TRIGGER_HITS = 1
S3_VALUE_SCALE = 5.0

# judge 발췌의 유래를 원문 문장과 대조할 때 쓰는 자카드 하한 (verify_judge_origin 2단계).
# 원문이 윤문으로 다시 쓰이면 발췌가 문자 그대로는 안 남으므로, 문자 대조만으로는
# "문제는 원문에 있었다"를 놓친다. 토큰 겹침으로 그 경우를 건진다.
ORIGIN_FUZZY_MIN = 0.6

_NUMBER_RE = re.compile(r"\d+(?:\.\d+)?")

# 근거 표지는 "확인하러 갈 곳"이 어디 있는지에 따라 판정 범위가 갈린다(설계 스펙 §2-1).
#
# 인라인 코드·마크다운 링크·URL·⟦HZ-…⟧ 토큰(마스킹된 코드·표·링크 자리)은 "같은 문장에"
# 있을 때만 근거로 본다 — 문단이 길면 그중 한 문장에 링크가 있다고 다른 문장의 주장까지
# 덩달아 면제되면 안 된다("대부분의 팀이 40% 이상 비용을 절감했다. 배포 방식은
# `docker compose up` 명령을 쓴다." 같은 문단에서 앞 문장은 여전히 미검증이어야 한다).
_SENTENCE_EVIDENCE_RE = re.compile(
    r"`[^`]+`"                                   # 인라인 코드
    r"|\[[^\]]*\]\([^)]*\)"                      # 마크다운 링크
    r"|https?://"                                # URL
    r"|⟦HZ-[^⟧]*⟧"                               # 마스킹 토큰(코드·표·링크가 있던 자리)
)

# 파일명·절대경로는 "같은 문단 안"이면 근거로 본다 — human_02_reference.md 의 `85%` 오탐
# 때문에 넣었다. disk-usage-alert.sh 라고 같은 문단(다른 문장이어도)이 이름을 대고 있으면
# 그 수치는 스크립트를 열어 확인할 수 있어, 문장 단위로 좁힐 이유가 없다.
_PARA_EVIDENCE_RE = re.compile(
    r"[\w.-]+\.(?:sh|py|js|ts|go|rs|java|rb|md|json|ya?ml|toml|ini|conf|cfg|txt|sql|csv)\b"
    r"|(?<![\w/])/[\w.@-]+(?:/[\w.@-]+)+"        # 절대경로
)


def _number_in_corpus(n: str, evidence_corpus: str) -> bool:
    """수치 n 이 근거 코퍼스에 '토큰 전체로' 나오는지 본다.

    부분 문자열 매치(`in`)는 `30명` 을 표의 `130명` 으로 면제해버린다 — 앞뒤가
    숫자/소수점이 아닌 경계에서만 매치되게 lookaround 로 못박는다.
    """
    pattern = r"(?<![\d.])" + re.escape(n) + r"(?![\d.])"
    return re.search(pattern, evidence_corpus) is not None


def _fence_adjacent_paras(sents: list[dict], fence_lines: set[int]) -> set[int]:
    """코드펜스 바로 앞뒤 문단은 근거가 붙은 것으로 본다(설계 스펙 §2-1)."""
    ranges: dict[int, tuple[int, int]] = {}
    for s in sents:
        lo, hi = ranges.get(s["para"], (s["line"], s["line"]))
        ranges[s["para"]] = (min(lo, s["line"]), max(hi, s["line"]))
    out: set[int] = set()
    for para, (lo, hi) in ranges.items():
        probes = list(range(lo - 2, lo)) + list(range(hi + 1, hi + 3))
        if any(p in fence_lines for p in probes):
            out.add(para)
    return out


def m_S3(sents: list[dict], lex: dict, evidence_corpus: str, fence_paras: set[int]) -> tuple[dict, list[dict]]:
    hits: list[dict] = []
    by_para: dict[int, list[dict]] = {}
    for s in sents:
        by_para.setdefault(s["para"], []).append(s)

    for para, group in by_para.items():
        para_text = " ".join(s["text"] for s in group)
        has_para_evidence = (
            para in fence_paras
            or _PARA_EVIDENCE_RE.search(para_text) is not None
            or any(item["re"].search(para_text) for item in lex.get("S3_evidence", []))
        )
        if has_para_evidence:
            continue
        for s in group:
            term = None
            for item in lex.get("S3_claim", []):
                if item["re"].search(s["text"]):
                    term = item["term"]
                    break
            if term is None:
                continue
            if _SENTENCE_EVIDENCE_RE.search(s["text"]) is not None:
                # 같은 문장 안에 인라인 코드·링크·URL·HZ 토큰이 있으면 근거로 본다.
                continue
            nums = _NUMBER_RE.findall(s["text"])
            if nums and all(_number_in_corpus(n, evidence_corpus) for n in nums):
                # 문서 차원 예외 — 같은 수치가 표나 코드 블록에 있으면 근거 있음으로 본다.
                continue
            hits.append({"id": "S3", "term": term, "line": s["line"], "quote": s["text"][:80]})

    triggered = len(hits) >= S3_TRIGGER_HITS
    value = min(1.0, len(hits) / S3_VALUE_SCALE)
    note = f"근거 없는 주장 {len(hits)}건 (임계 {S3_TRIGGER_HITS}건)"
    raw = {"hits": len(hits)}
    return metric("S3", "미검증 사례", "report", raw, value, triggered, note), hits


# ---------------------------------------------------------------------------
# 5c. 집계
# ---------------------------------------------------------------------------


def scan_text(text: str, lex: dict) -> dict:
    units, evidence_corpus, fence_lines = prose_units(text)
    sents = sentences(units)
    nonspace = sum(len(re.sub(r"\s", "", t)) for _, t in units)
    m1, h1 = m_S1(sents, lex, nonspace)
    m2, h2 = m_S2(sents, lex)
    m3, h3 = m_S3(sents, lex, evidence_corpus, _fence_adjacent_paras(sents, fence_lines))
    return {"metrics": [m1, m2, m3], "hits": list(h1) + list(h2) + list(h3)}


# ---------------------------------------------------------------------------
# 6. 입출력 헬퍼
# ---------------------------------------------------------------------------


def read_text(path: str) -> str | None:
    try:
        return Path(path).read_bytes().decode("utf-8")
    except OSError as e:
        print(f"오류: 파일을 읽을 수 없습니다: {e}", file=sys.stderr)
        return None
    except UnicodeDecodeError as e:
        print(f"오류: UTF-8 디코딩 실패: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------------------
# 6b. HUMANIZE-SUMMARY 최소 파서 (PyYAML 금지 — 들여쓰기 2칸 리스트와 키:값만 읽는다)
# ---------------------------------------------------------------------------

SUMMARY_OPEN_RE = re.compile(r"<!--\s*HUMANIZE-SUMMARY\b")
SLOP_KEY_RE = re.compile(r"^slop_findings\s*:")
TRUNC_KEY_RE = re.compile(r"^slop_findings_truncated\s*:")


def extract_summary_block(text: str) -> str | None:
    m = SUMMARY_OPEN_RE.search(text)
    if not m:
        return None
    start = m.end()
    # 첫 "-->" 로 끊으면 quote/why 값 안의 "-->" 에 블록이 잘린다 — 이 블록은
    # final.md 맨 끝에 있으므로 종결자는 항상 "마지막" "-->" 다.
    end = text.rfind("-->")
    if end < start:
        raise ValueError("HUMANIZE-SUMMARY 종결자 없음")
    return text[start:end]


def _unquote(value: str) -> str:
    v = value.strip()
    if v[:1] in ('"', "'"):
        quote = v[0]
        # 첫 닫는 인용부호에서 끊으면 값 안의 이스케이프/중첩 인용부호가 잘린다 —
        # 닫는 인용부호는 항상 "마지막" 인용부호(뒤에 공백·주석만 남는 자리)다.
        last_q = v.rfind(quote)
        tail = v[last_q + 1:].strip()
        if last_q <= 0 or (tail and not tail.startswith("#")):
            raise ValueError(f"닫는 인용부호가 없다: {value!r}")
        inner = v[1:last_q]
        return inner.replace(f"\\{quote}", quote).replace("\\\\", "\\")
    if "#" in v:
        v = v.split("#", 1)[0]
    return v.strip()


def parse_slop_findings(block: str) -> dict | None:
    lines = block.splitlines()
    findings: list[dict] = []
    truncated = False
    seen = False
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        # 탭 들여쓰기도 들여쓰기다 — 공백만 보면 탭으로 들여쓴 하위 키를 최상위로 오판한다.
        top_level = bool(stripped) and not line.startswith((" ", "\t"))
        if top_level and SLOP_KEY_RE.match(stripped):
            seen = True
            rest = _unquote(stripped.split(":", 1)[1])
            i += 1
            if rest == "[]":
                continue
            current: dict | None = None
            while i < len(lines):
                nxt = lines[i]
                if nxt.strip() and not nxt.startswith((" ", "\t")):
                    break
                body = nxt.strip()
                if body.startswith("- "):
                    current = {}
                    findings.append(current)
                    body = body[2:].strip()
                if current is not None and ":" in body:
                    key, value = body.split(":", 1)
                    current[key.strip()] = _unquote(value)
                i += 1
            continue
        if top_level and TRUNC_KEY_RE.match(stripped):
            truncated = _unquote(stripped.split(":", 1)[1]).lower() == "true"
        i += 1
    if not seen:
        return None
    for f in findings:
        if "item" not in f:
            raise ValueError("slop_findings 항목에 item 키가 없다")
        # monolith 는 윤문 전 원문을 판정한다 — 이 층의 검출은 예외 없이 원문 유래다.
        # 윤문이 들여온 것은 결정적 층의 차집합(compare 의 introduced)만 판정한다.
        f["origin"] = "원문"
    return {"provider": "monolith", "findings": findings, "truncated": truncated}


# ---------------------------------------------------------------------------
# 6c. 유래 판정 — 항목별 용어 카운트 차집합
# ---------------------------------------------------------------------------

ITEM_LABEL = {"S1": "확신", "S2": "필러", "S3": "미검증"}


def term_counts(hits: list[dict]) -> dict[tuple[str, str], int]:
    counts: dict[tuple[str, str], int] = {}
    for h in hits:
        key = (h["id"], h["term"])
        counts[key] = counts.get(key, 0) + 1
    return counts


def diff_terms(before_hits: list[dict], after_hits: list[dict]) -> tuple[list[dict], list[dict]]:
    """문장이 바뀌면 문장 단위 대조가 깨지므로 용어 카운트로 유래를 정한다."""
    before = term_counts(before_hits)
    after = term_counts(after_hits)
    introduced: list[dict] = []
    resolved: list[dict] = []
    for key, n_after in after.items():
        delta = n_after - before.get(key, 0)
        if delta <= 0:
            continue
        picked = [h for h in after_hits if (h["id"], h["term"]) == key][-delta:]
        for h in picked:
            introduced.append({
                "id": h["id"], "term": h["term"], "line": h["line"],
                "quote": h["quote"], "origin": "윤문",
            })
    for key, n_before in before.items():
        delta = n_before - after.get(key, 0)
        if delta > 0:
            resolved.append({"id": key[0], "term": key[1], "count": delta})
    introduced.sort(key=lambda x: (x["id"], x["line"]))
    resolved.sort(key=lambda x: (x["id"], x["term"]))
    return introduced, resolved


_WS_RE = re.compile(r"\s+")


def normalize_ws(text: str) -> str:
    """연속 공백을 한 칸으로 접고 앞뒤를 턴다 — 줄바꿈으로 끊긴 발췌도 같게 본다."""
    return _WS_RE.sub(" ", text).strip()


_ORIGIN_TOKEN_RE = re.compile(r"[가-힣A-Za-z0-9]{2,}")


def origin_tokens(text: str) -> set[str]:
    """유래 대조용 토큰 — 두 글자 이상의 한글·영숫자 덩어리."""
    return set(_ORIGIN_TOKEN_RE.findall(text))


def _jaccard(a: set[str], b: set[str]) -> float:
    union = a | b
    return (len(a & b) / len(union)) if union else 0.0


def verify_judge_origin(judge: dict, before_text: str) -> dict:
    """judge 검출의 origin 을 원문 대조로 다시 매긴다.

    에이전트 정의는 "발췌가 원본에 그대로 있으면 원문" 이라는 문자열 기준을 주지만,
    모델이 그 규칙을 문자열이 아니라 문제의 출처로 읽는 일이 실측에서 관측됐다(1.4.0).
    유래 판정을 모델의 규칙 준수에 맡기지 않고 여기서 결정적으로 다시 매긴다.

    다만 문자 대조 하나로는 스펙이 말한 "이 문제가 원문에 있었나"를 못 지킨다 —
    judge 는 candidate 를 읽으므로, 윤문이 문장을 다시 쓰면 문제가 원문 유래여도
    발췌가 원문에 문자 그대로는 없다. 그래서 두 단계로 본다.

    1. 공백 정규화 후 원문에 그대로 있으면 `원문` / `origin_method: verbatim`.
    2. 아니면 원문 산문을 문장으로 쪼개 토큰 자카드를 재고, 최고점이
       ORIGIN_FUZZY_MIN 이상이면 `원문` / `fuzzy` 로 보고 그 문장의 줄번호를
       `origin_match_line` 에 남긴다. 그 아래면 `윤문` / `none`.

    세 경우 모두 `origin_verified: true` 를 달아 기계 판정임을 표시한다. quote 가
    비어 있으면 대조할 것이 없으므로 모델이 준 값을 그대로 두고 아무 표시도 안 한다.
    """
    haystack = normalize_ws(before_text)
    units, _, _ = prose_units(before_text)
    src = [(s["line"], origin_tokens(s["text"])) for s in sentences(units)]

    out = dict(judge)
    findings: list[dict] = []
    for f in judge.get("findings") or []:
        g = dict(f)
        quote = normalize_ws(str(g.get("quote") or ""))
        if not quote:
            findings.append(g)
            continue
        g["origin_verified"] = True
        if quote in haystack:
            g["origin"] = "원문"
            g["origin_method"] = "verbatim"
            findings.append(g)
            continue
        q = origin_tokens(quote)
        best_line, best = None, 0.0
        for line, toks in src:
            r = _jaccard(q, toks)
            if r > best:
                best, best_line = r, line
        if best >= ORIGIN_FUZZY_MIN:
            g["origin"] = "원문"
            g["origin_method"] = "fuzzy"
            g["origin_match_line"] = best_line
        else:
            g["origin"] = "윤문"
            g["origin_method"] = "none"
        findings.append(g)
    out["findings"] = findings
    return out


def merge_llm(llm_monolith: dict | None, judge: dict | None, before_text: str = "") -> dict | None:
    """judge 결과가 있으면 그것이 llm 이고, 없으면 monolith 복사본, 둘 다 없으면 null.

    judge 를 채택할 때는 origin 을 원문 대조로 다시 매긴다(verify_judge_origin).
    monolith 검출은 정의상 전부 원문 유래라 다시 매길 것이 없다.
    """
    if judge is not None and not judge.get("error"):
        return verify_judge_origin(judge, before_text)
    if llm_monolith is not None and not llm_monolith.get("error"):
        return dict(llm_monolith)
    return None


def build_pending_line(summary: dict, triggered: list[str]) -> str | None:
    if not triggered:
        return None
    return (
        "gate=S exit=1 action=none reason=초안 관문: "
        f"확신 {summary['S1']}·필러 {summary['S2']}·미검증 {summary['S3']}"
        f" (윤문 유입 {summary['introduced']})"
    )


def _load_json(path: str | None) -> dict | None:
    if not path:
        return None
    p = Path(path)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


# ---------------------------------------------------------------------------
# 7. CLI
# ---------------------------------------------------------------------------


def print_scan_table(file_: str, result: dict) -> None:
    """형식은 llm_signature.print_score_table 을 따른다 — Phase 4 가 두 표를
    같은 진단문에 이어 붙이므로 모양이 갈리면 읽기 나빠진다."""
    print(f"파일: {file_}  (초안 관문 — 수정 안 함)")
    print(f"{'ID':<4} {'라벨':<12} {'종류':<8} {'값':>6} {'발동':>6}  근거")
    print("-" * 90)
    for m in result["metrics"]:
        mark = "O" if m["triggered"] else "-"
        print(f"{m['id']:<4} {m['label']:<12} {m['kind']:<8} {m['value']:>6.2f} {mark:>6}  {m['note']}")
    print("-" * 90)
    triggered = [m["id"] for m in result["metrics"] if m["triggered"]]
    print(f"발동된 초안 관문 항목: {', '.join(triggered) if triggered else '없음'}")
    for h in result["hits"][:5]:
        print(f"  - {h['id']} (줄 {h['line']}, {h['term']}): {h['quote']}")


def cmd_scan(args: argparse.Namespace) -> int:
    lex = load_lexicon(args.lexicon)
    if lex is None:
        print(f"초안 관문: lexicon 파일 없음 — 스캔 건너뜀 ({args.lexicon})")
        return 0
    text = read_text(args.src)
    if text is None:
        return 0
    result = scan_text(text, lex)
    print_scan_table(args.src, result)
    if args.json:
        payload = {
            "file": args.src,
            "metrics": result["metrics"],
            "hits": result["hits"],
            "triggered": [m["id"] for m in result["metrics"] if m["triggered"]],
        }
        print(json.dumps(payload, ensure_ascii=False))
    return 0


def cmd_extract_llm(args: argparse.Namespace) -> int:
    llm_monolith: dict | None = None
    note: str | None = None
    text = read_text(args.final)
    if text is None:
        note = "final.md 를 읽을 수 없음"
    else:
        try:
            block = extract_summary_block(text)
        except Exception as e:  # noqa: BLE001 — 종결자 누락은 error 객체로 남기고 진행한다
            block = None
            llm_monolith = {"error": str(e)}
        if llm_monolith is None:
            if block is None:
                note = "HUMANIZE-SUMMARY 블록 없음"
            else:
                try:
                    llm_monolith = parse_slop_findings(block)
                    if llm_monolith is None:
                        note = "slop_findings 키 없음"
                except Exception as e:  # noqa: BLE001 — 파싱 실패는 error 객체로 남기고 진행한다
                    llm_monolith = {"error": f"slop_findings 파싱 실패: {e}"}
    # source 는 스펙 §133의 세 키를 다 갖춘 채로 시작한다 — compare 가 before/after 만 채운다.
    payload: dict = {
        "version": 1,
        "source": {"before": None, "after": None, "final": args.final},
        "llm_monolith": llm_monolith,
    }
    if note:
        payload["note"] = note   # Phase 9가 "LLM 판정 누락" 사유를 그대로 옮겨 적는다
    Path(args.out).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    state = note if llm_monolith is None else ("파싱 실패" if "error" in llm_monolith else f"{len(llm_monolith['findings'])}건")
    print(f"초안 관문: monolith 판정 {state} → {args.out}")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    out_path = args.out or args.llm
    if not out_path:
        print("초안 관문: --out 도 --llm 도 없어 쓸 곳이 없다 — 건너뜀")
        return 0

    lex = load_lexicon(args.lexicon)
    if lex is None:
        print(f"초안 관문: lexicon 파일 없음 — 대조 건너뜀 ({args.lexicon})")
        return 0

    before_text = read_text(args.before)
    after_text = read_text(args.after)
    if before_text is None or after_text is None:
        return 0

    before_scan = scan_text(before_text, lex)
    after_scan = scan_text(after_text, lex)
    introduced, resolved = diff_terms(before_scan["hits"], after_scan["hits"])

    prev = _load_json(args.llm) or {}
    llm_monolith = prev.get("llm_monolith")
    judge = _load_json(args.judge)
    llm = merge_llm(llm_monolith, judge, before_text)

    counts = {"S1": 0, "S2": 0, "S3": 0}
    for h in after_scan["hits"]:
        counts[h["id"]] = counts.get(h["id"], 0) + 1
    summary = {
        "S1": counts["S1"], "S2": counts["S2"], "S3": counts["S3"],
        "introduced": len(introduced),
        "llm_findings": len((llm or {}).get("findings", [])),
    }
    triggered = [m["id"] for m in after_scan["metrics"] if m["triggered"]]

    source = dict(prev.get("source") or {})
    source["before"] = args.before
    source["after"] = args.after
    source.setdefault("final", None)
    payload: dict = {
        "version": 1,
        "source": {"before": source["before"], "after": source["after"], "final": source["final"]},
        "scan": {
            "before": before_scan,
            "after": after_scan,
            "introduced": introduced,
            "resolved": resolved,
        },
        "llm": llm,
        "llm_monolith": llm_monolith,
        "summary": summary,
    }
    # extract-llm 이 남긴 누락 사유는 그대로 이어 나른다 — Phase 9가 "LLM 판정 누락"에 쓴다.
    if prev.get("note"):
        payload["note"] = prev["note"]
    Path(out_path).write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    line = build_pending_line(summary, triggered)
    if line:
        if args.pending:
            try:
                with open(args.pending, "a", encoding="utf-8") as f:
                    f.write(line + "\n")
            except OSError as e:
                print(f"slop_scan: pending 기록 실패 ({args.pending}): {e}", file=sys.stderr)
        else:
            print(line)
    print(
        f"초안 관문: 확신 {summary['S1']} · 필러 {summary['S2']} · 미검증 {summary['S3']}"
        f" | 윤문 유입 {summary['introduced']} | LLM 판정 {summary['llm_findings']}건 → {out_path}"
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="slop_scan.py", description="게이트 S(초안 관문) 결정적 스캐너")
    sub = p.add_subparsers(dest="command", required=True)

    ps = sub.add_parser("scan", help="문서 하나를 초안 관문 세 항목으로 스캔한다")
    ps.add_argument("--src", required=True)
    ps.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    ps.add_argument("--json", action="store_true", help="stdout 마지막 줄에 JSON 한 줄 추가")
    ps.set_defaults(func=cmd_scan)

    pe = sub.add_parser("extract-llm", help="final.md 의 HUMANIZE-SUMMARY 에서 slop_findings 를 뽑는다")
    pe.add_argument("--final", required=True)
    pe.add_argument("--out", required=True)
    pe.set_defaults(func=cmd_extract_llm)

    pc = sub.add_parser("compare", help="윤문 전/후를 대조해 11_slop.json 을 완성한다")
    pc.add_argument("--before", required=True)
    pc.add_argument("--after", required=True)
    pc.add_argument("--lexicon", default=str(DEFAULT_LEXICON))
    pc.add_argument("--llm", default=None, help="extract-llm 산출물(11_slop.json)")
    pc.add_argument("--judge", default=None, help="wwe-slop-judge 산출물(11_slop_judge.json)")
    pc.add_argument("--out", default=None, help="생략하면 --llm 경로에 덮어쓴다")
    pc.add_argument("--pending", default=None, help="생략하면 pending 줄을 stdout 에 낸다")
    pc.set_defaults(func=cmd_compare)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:  # noqa: BLE001 — CLI 최상위 안전망. exit 는 항상 0 이다.
        print(f"slop_scan: 내부 오류: {type(e).__name__}: {e}", file=sys.stderr)
        print(traceback.format_exc(), file=sys.stderr)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
