#!/usr/bin/env python3
"""llm_signature.py — humanize-docs 문서 레이아웃 지문 스코어러 (L1~L14).

Claude/GPT가 쓴 한국어 게시물·기술문서는 문장이 아니라 "문서 전체 레이아웃"에서
먼저 들킨다. humanize-korean 은 문장·문단 단위 번역투를 다루지만 마크다운 레이아웃
지표는 하나도 갖고 있지 않다. 이 스크립트는 그 레이아웃 지문을 LLM 없이 결정적으로
측정한다.

정책(변경 금지): "장식만 제거, 구조는 보존."
    - 보존: 불릿, 번호목록, 표, 헤딩 텍스트, 코드블록, 링크, 옵션·키워드 표식용 볼드
    - actionable(제거 대상): 상태 이모지, 서두 TL;DR 박스, 마무리 요약 섹션(순수
      재진술일 때만), 수평선 남발, 볼드리드 불릿의 볼드 라벨, 강조용 인용블록
    - report-only(고지만, 자동 수정 안 함): 표 밀도, 섹션 골격 균질성, 삼분 편향,
      ASCII 도식, 헤딩/불릿 균일성 — 구조를 바꿔야 고쳐지는 축이라 판정만 하고
      건드리지 않는다.

CLI:
    score   --src <file.md> [--mode post|reference] [--json]
    compare --before <a.md> --after <b.md> [--mode post|reference]
            [--min-drop 0.25] [--json]

구현 제약:
    - Python 3.11, 표준 라이브러리만 사용.
    - 파싱은 줄 단위 상태 머신. 코드펜스 안은 어떤 지표에도 포함하지 않는다
      (L5 제외 — L5는 펜스 자체의 내용을 본다). frontmatter 도 제외한다.
    - md_shield.py 가 있으면 그 정규식(펜스/헤딩/표/리스트 판별)을 재사용해
      코드펜스 오탐(예: 펜스 안의 `#!/usr/bin/env bash`)을 피한다. 없으면
      자체 정규식으로 graceful degrade 한다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# md_shield.py 재사용 시도 (없으면 자체 정규식으로 graceful degrade)
# ---------------------------------------------------------------------------

_HAVE_MD_SHIELD = False
try:
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from md_shield import (  # type: ignore
        FENCE_OPEN_RE as _MD_FENCE_OPEN_RE,
        HEADING_RE as _MD_HEADING_RE,
        LIST_MARKER_RE as _MD_LIST_MARKER_RE,
        TABLE_SEP_RE as _MD_TABLE_SEP_RE,
        is_fence_close as _md_is_fence_close,
    )

    _HAVE_MD_SHIELD = True
except Exception:
    _HAVE_MD_SHIELD = False

if _HAVE_MD_SHIELD:
    FENCE_OPEN_RE = _MD_FENCE_OPEN_RE
    HEADING_RE = _MD_HEADING_RE
    LIST_MARKER_RE = _MD_LIST_MARKER_RE
    TABLE_SEP_RE = _MD_TABLE_SEP_RE

    def is_fence_close(line: str, fence_char: str, n: int) -> bool:
        return _md_is_fence_close(line, fence_char, n)
else:
    FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
    HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*))?$")
    TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
    LIST_MARKER_RE = re.compile(r"^ {0,3}([-*+]|\d{0,9}[.)])(?:\s+|$)")

    def is_fence_close(line: str, fence_char: str, n: int) -> bool:
        s = line.strip()
        if len(s) < n:
            return False
        return all(c == fence_char for c in s)


HR_RE = re.compile(r"^ {0,3}(-{3,}|\*{3,}|_{3,})\s*$")
SETEXT_EQ_RE = re.compile(r"^ {0,3}={3,}\s*$")
UNORDERED_MARKER_RE = re.compile(r"^[-*+]$")
BQ_LINE_RE = re.compile(r"^ {0,3}>")


# ---------------------------------------------------------------------------
# 상수: 이모지 · ASCII 도식 문자 · 키워드
# ---------------------------------------------------------------------------

EMOJI_LIST = [
    "✅", "❌", "⚠️", "⚠", "🚀", "🔥", "💡", "📌", "🎯", "✔️", "✔",
    "❗", "🎉", "👉", "⭐", "📊", "🔍", "💪",
]
EMOJI_RE = re.compile("|".join(re.escape(e) for e in sorted(EMOJI_LIST, key=len, reverse=True)))

ASCII_ART_CHARS = set("─│┌┐└┘├┤▶◀→←↓↑⟶┃╭╰")

HEADING_SUMMARY_RE = re.compile(
    r"(한\s*줄\s*요약|핵심\s*정리|정리하며|TL;DR|TLDR|요약|정리|마치며|결론|마무리|끝으로)",
    re.IGNORECASE,
)

TLDR_KEYWORDS_RE = re.compile(
    r"TL;DR|TLDR|한\s*줄\s*요약|결론부터|핵심|요약", re.IGNORECASE
)
WARNING_START_RE = re.compile(
    r"^[\s*_>~`⚠️❗🔥]*(주의|경고|중요|Note|Warning|Caution|Tip)\b", re.IGNORECASE
)
# 라벨형 캡션 키워드 — "**출처**: ...", "버전 고지: ..." 처럼 블록 맨 앞
# 콜론 이전 "라벨" 위치에서만 신호로 본다. 본문 아무 데서나 검색하면
# "롤링 업데이트"의 "업데이트" 같은 일반 단어에 오탐한다(ai_01_max 실측 확인됨).
CAPTION_LEAD_RE = re.compile(
    r"출처|원자료|참고|기준|작성일|업데이트|버전|정정", re.IGNORECASE
)
# 위치 무관 강신호 — 기술적으로 뜻이 좁아 일반 문장에 섞여 나올 위험이 낮다.
CAPTION_STRONG_RE = re.compile(
    r"https?://|\d{4}[.\-]\d{2}[.\-]\d{2}|\b[0-9a-fA-F]{7,40}\b|checkout|커밋|commit",
    re.IGNORECASE,
)
# 출처 표시 — em대시는 "글 끝 — 저자/화자" 귀속 패턴일 때만 신호로 본다.
# 문장 중간의 대시(부연설명)나 강조용 따옴표는 인용 출처가 아니라 문체이므로
# 여기서 배제한다(실측: logging-observability-intro.md 판단 블록들의 중간
# 대시·강조 따옴표가 전부 출처로 오분류되던 문제).
SOURCE_MARKER_RE = re.compile(r"출처|https?://|『|「|—\s*[A-Za-z가-힣][\w가-힣.]*\s*$")

BOLD_LEAD_BULLET_RE = re.compile(r"^\*\*([^*]{1,50})\*\*\s*[:：—–\-]?\s*")
BOLD_LEAD_PARA_RE = re.compile(r"^\*\*([^*]{1,60})\*\*\s*[:：—–\-]?\s*\S")

PARTICLES = sorted(
    [
        "으로는", "에서는", "에게서", "이라는", "라는", "으로써", "로써",
        "에서", "에게", "한테", "까지", "부터", "처럼", "보다", "마다",
        "조차", "마저", "밖에", "이나", "은", "는", "이", "가", "을",
        "를", "의", "에", "와", "과", "도", "만", "로", "으로",
        # 엄밀히는 조사가 아니라 종결어미지만, 기술문서의 "-습니다/-합니다"체가
        # 워낙 지배적이라 같은 방식(정규식 근사)으로 함께 제거해야 L8/L9의
        # 내용어 오버랩 계산이 실질적으로 동작한다(순수 조사만 떼면 동사
        # 활용형이 명사형과 매칭되지 않아 재진술을 놓친다).
        "하였습니다", "했습니다", "됩니다", "습니다", "합니다", "입니다",
    ],
    key=len,
    reverse=True,
)

QUESTION_END_RE = re.compile(r"(\?|까요|나요|습니까|을까|ㄴ가|는가)\s*$")
VERB_END_RE = re.compile(r"(다|함|음|기)\s*$")
PARTICLE_END_RE = re.compile(r"(은|는|이|가|을|를|의|와|과|로)\s*$")


# ---------------------------------------------------------------------------
# 1. frontmatter 분리 + 줄 단위 분류(상태 머신)
# ---------------------------------------------------------------------------


def strip_frontmatter(lines: list[str]) -> int:
    """frontmatter 를 인식해 그 다음 줄 인덱스를 돌려준다(없으면 0)."""
    if not lines:
        return 0
    first = lines[0].strip()
    if first not in ("---", "+++"):
        return 0
    for j in range(1, len(lines)):
        if lines[j].strip() == first:
            return j + 1
    return 0


def classify_lines(lines: list[str]) -> tuple[list[str], list[dict | None]]:
    """각 줄을 kind 로 분류한다.

    kind ∈ {fm, fence, heading, hr, skip, blockquote, table, list, blank, prose}
    fence 안, frontmatter 는 어떤 지표에도(L5 제외) 포함하지 않기 위한 기반이다.
    """
    n = len(lines)
    kind: list[str] = [""] * n
    meta: list[dict | None] = [None] * n

    fm_end = strip_frontmatter(lines)
    for k in range(fm_end):
        kind[k] = "fm"

    i = fm_end
    in_fence = False
    fence_char = ""
    fence_n = 0
    while i < n:
        line = lines[i]

        if in_fence:
            kind[i] = "fence"
            if is_fence_close(line, fence_char, fence_n):
                in_fence = False
            i += 1
            continue

        m = FENCE_OPEN_RE.match(line)
        if m:
            kind[i] = "fence"
            fence_char = m.group(1)[0]
            fence_n = len(m.group(1))
            meta[i] = {"lang": line[m.end(1):].strip()}
            in_fence = True
            i += 1
            continue

        hm = HEADING_RE.match(line)
        if hm:
            level = len(hm.group(1))
            text = re.sub(r"\s+#+\s*$", "", (hm.group(2) or "")).strip()
            kind[i] = "heading"
            meta[i] = {"level": level, "text": text}
            i += 1
            continue

        if BQ_LINE_RE.match(line):
            kind[i] = "blockquote"
            i += 1
            continue

        # setext 헤딩(=== 밑줄) — 흔치 않지만 오탐 방지용으로 먼저 처리
        if SETEXT_EQ_RE.match(line) and i > fm_end and kind[i - 1] == "prose":
            prevprev_ok = (i - 1 == fm_end) or kind[i - 2] in ("blank", "heading", "fm")
            if prevprev_ok:
                kind[i - 1] = "heading"
                meta[i - 1] = {"level": 1, "text": lines[i - 1].strip()}
                kind[i] = "skip"
                i += 1
                continue

        hrm = HR_RE.match(line)
        if hrm:
            marker = hrm.group(1)[0]
            if marker == "-" and i > fm_end and kind[i - 1] == "prose":
                prevprev_ok = (i - 1 == fm_end) or kind[i - 2] in ("blank", "heading", "fm")
                if prevprev_ok:
                    kind[i - 1] = "heading"
                    meta[i - 1] = {"level": 2, "text": lines[i - 1].strip()}
                    kind[i] = "skip"
                    i += 1
                    continue
            kind[i] = "hr"
            i += 1
            continue

        if "|" in line and i + 1 < n and "|" in lines[i + 1] and TABLE_SEP_RE.match(lines[i + 1].strip()):
            kind[i] = "table"
            kind[i + 1] = "table"
            j = i + 2
            while j < n and lines[j].strip() != "" and "|" in lines[j]:
                kind[j] = "table"
                j += 1
            i = j
            continue

        if LIST_MARKER_RE.match(line):
            kind[i] = "list"
            i += 1
            continue

        if line.strip() == "":
            kind[i] = "blank"
            i += 1
            continue

        if i > fm_end and kind[i - 1] == "list" and (line[:1] in (" ", "\t")):
            kind[i] = "list"
            i += 1
            continue

        kind[i] = "prose"
        i += 1

    return kind, meta


# ---------------------------------------------------------------------------
# 2. 줄 분류 -> 블록 리스트
# ---------------------------------------------------------------------------


def extract_list_items(sublines: list[str], offset: int) -> list[dict]:
    items: list[dict] = []
    cur: dict | None = None
    for idx, line in enumerate(sublines):
        m = LIST_MARKER_RE.match(line)
        if m:
            if cur is not None:
                items.append(cur)
            marker = m.group(1)
            content = line[m.end():]
            cur = {"line": offset + idx, "marker": marker, "text_lines": [content]}
        else:
            if cur is not None:
                cur["text_lines"].append(line.strip())
    if cur is not None:
        items.append(cur)
    for it in items:
        it["text"] = " ".join(t for t in it["text_lines"] if t).strip()
    return items


def build_blocks(lines: list[str], kind: list[str], meta: list[dict | None]) -> list[dict]:
    blocks: list[dict] = []
    n = len(lines)
    i = 0
    while i < n:
        k = kind[i]
        if k in ("fm", "skip", "blank"):
            i += 1
            continue
        if k == "heading":
            m = meta[i] or {}
            blocks.append({"kind": "heading", "start": i, "end": i, "level": m.get("level", 1), "text": m.get("text", "")})
            i += 1
            continue
        if k == "hr":
            blocks.append({"kind": "hr", "start": i, "end": i})
            i += 1
            continue
        if k == "fence":
            j = i
            while j < n and kind[j] == "fence":
                j += 1
            content = lines[i + 1:j - 1] if j - i >= 2 else []
            lang = (meta[i] or {}).get("lang", "")
            blocks.append({"kind": "fence", "start": i, "end": j - 1, "lang": lang, "content": content})
            i = j
            continue
        if k == "table":
            j = i
            while j < n and kind[j] == "table":
                j += 1
            rows = lines[i:j]
            header_cols = [c for c in rows[0].split("|")] if rows else []
            ncols = max(0, len([c for c in header_cols if c.strip() != ""]) or (rows[0].count("|") - 1 if rows else 0))
            blocks.append({"kind": "table", "start": i, "end": j - 1, "rows": rows, "ncols": ncols})
            i = j
            continue
        if k == "blockquote":
            j = i
            while j < n and kind[j] == "blockquote":
                j += 1
            raw = lines[i:j]
            text = " ".join(re.sub(r"^ {0,3}>\s?", "", ln) for ln in raw).strip()
            blocks.append({"kind": "blockquote", "start": i, "end": j - 1, "text": text, "raw": raw})
            i = j
            continue
        if k == "list":
            j = i
            while j < n and kind[j] == "list":
                j += 1
            items = extract_list_items(lines[i:j], i)
            blocks.append({"kind": "list", "start": i, "end": j - 1, "items": items})
            i = j
            continue
        if k == "prose":
            j = i
            while j < n and kind[j] == "prose":
                j += 1
            text = " ".join(ln.strip() for ln in lines[i:j]).strip()
            blocks.append({"kind": "paragraph", "start": i, "end": j - 1, "text": text})
            i = j
            continue
        i += 1
    return blocks


# ---------------------------------------------------------------------------
# 3. 섹션 분할 (최상위 헤딩 레벨 기준)
# ---------------------------------------------------------------------------


def determine_top_level(headings: list[dict]) -> int | None:
    if not headings:
        return None
    levels = sorted({h["level"] for h in headings})
    lvl = levels[0]
    count_at_lvl = sum(1 for h in headings if h["level"] == lvl)
    if count_at_lvl == 1 and len(levels) > 1 and headings[0]["level"] == lvl:
        lvl = levels[1]
    return lvl


def split_sections(headings: list[dict], total_lines: int, top_level: int | None) -> list[dict]:
    if top_level is None:
        return []
    top_heads = [h for h in headings if h["level"] == top_level]
    if not top_heads:
        return []
    sections = []
    for idx, h in enumerate(top_heads):
        start = h["line"]
        end = top_heads[idx + 1]["line"] - 1 if idx + 1 < len(top_heads) else total_lines - 1
        sections.append({"start": start, "end": end, "heading": h})
    return sections


# ---------------------------------------------------------------------------
# 4. 문서 파싱 진입점
# ---------------------------------------------------------------------------


def parse_document(text: str) -> dict:
    # 마지막 줄이 빈 문자열로 잡히는 것(trailing \n)을 피하되, 내용은 보존한다.
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines = lines[:-1]
    kind, meta = classify_lines(lines)
    blocks = build_blocks(lines, kind, meta)
    headings = [
        {"line": b["start"], "level": b["level"], "text": b["text"]}
        for b in blocks
        if b["kind"] == "heading"
    ]
    top_level = determine_top_level(headings)
    sections = split_sections(headings, len(lines), top_level)

    # 산문(프로즈) 인덱스: fence/fm 을 제외한 모든 줄 텍스트(토큰 오버랩 계산용)
    prose_all_text = "\n".join(
        lines[i] for i in range(len(lines)) if kind[i] not in ("fm", "fence", "skip")
    )

    return {
        "lines": lines,
        "kind": kind,
        "meta": meta,
        "blocks": blocks,
        "headings": headings,
        "top_level": top_level,
        "sections": sections,
        "prose_all_text": prose_all_text,
    }


# ---------------------------------------------------------------------------
# 5. 공통 유틸 — 내용어 추출/오버랩, 인용블록 분류
# ---------------------------------------------------------------------------


def strip_particle(tok: str) -> str:
    # 조사가 겹쳐 붙는 경우(예: "케이스에서의" = 케이스+에서+의)를 대비해
    # 최대 2회까지 반복 제거한다. 어간이 2글자 미만으로 줄어들면 멈춘다.
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


def content_words(text: str) -> set[str]:
    toks = re.findall(r"[가-힣]{2,}", text)
    return {strip_particle(t) for t in toks}


def overlap_ratio(target_text: str, rest_text: str) -> float:
    target_tokens = content_words(target_text)
    if not target_tokens:
        return 0.0
    rest_tokens = content_words(rest_text)
    inter = target_tokens & rest_tokens
    return len(inter) / len(target_tokens)


def strip_leading_deco(text: str) -> str:
    return re.sub(r"^[\s*_>~`\"'“”\-–—]*", "", text)


def classify_quote(text: str, rest_text: str, short_chars: int = 500) -> str:
    """블록쿼트를 caption / warning / summary / other 로 분류한다.

    caption: 출처·버전·checkout·커밋 등 방법론/메타데이터 각주 → L9/L10 제외
    warning: 주의·경고·중요·Note/Warning/Caution/Tip 박스 → L9/L10 제외
    summary: TL;DR 성격(명시 키워드 또는 문서 나머지와 내용어 겹침 0.6+인 짧은 블록)
    other: 위 어디에도 안 걸리는 일반 인용(예: 출처 없는 순수 인용문)
    """
    clean = text.strip()
    stripped = strip_leading_deco(clean)
    if WARNING_START_RE.match(clean) or WARNING_START_RE.match(stripped):
        return "warning"
    lead = re.sub(r"[*_`]", "", clean[:40])
    lead_label = re.split(r"[:：]", lead, maxsplit=1)[0]
    if CAPTION_LEAD_RE.search(lead_label):
        return "caption"
    if CAPTION_STRONG_RE.search(clean):
        return "caption"
    if TLDR_KEYWORDS_RE.search(clean):
        return "summary"
    if len(clean) <= short_chars and overlap_ratio(clean, rest_text) >= 0.6:
        return "summary"
    return "other"


# ---------------------------------------------------------------------------
# 6. 지표 L1~L14
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


def all_unordered_bullets(doc: dict) -> list[dict]:
    out = []
    for b in doc["blocks"]:
        if b["kind"] == "list":
            for it in b["items"]:
                if UNORDERED_MARKER_RE.match(it["marker"]):
                    out.append(it)
    return out


def m_L1(doc: dict) -> dict:
    bullets = all_unordered_bullets(doc)
    total = len(bullets)
    short = 0
    long_ = 0
    for it in bullets:
        m = BOLD_LEAD_BULLET_RE.match(it["text"])
        if not m:
            continue
        body = it["text"][m.end():].strip()
        if len(body) < 60:
            short += 1
        else:
            long_ += 1
    if total < 3:
        return metric("L1", "볼드리드 불릿", "actionable", {"bullets": total, "short_label": short, "long_body": long_}, 0.0, False, "표본 부족")
    ratio_short = short / total
    ratio_long = long_ / total
    value = min(1.0, ratio_short + 0.4 * ratio_long)
    matched = short + long_
    # 트리거는 short_label 비율만이 아니라 value(= short + 0.4*long) 로 판단한다.
    # 실물 검증(logging-observability-intro.md, WRITING_STYLE.md)에서 "강점/약점/제약"
    # 류 라벨은 본문이 60자 넘는 long_body로 분류돼 short_label 비율(0.19/0.28)만 보면
    # 임계 0.35를 못 넘지만, 불릿의 78%/36%가 볼드리드로 시작하는 명백한 카탈로그
    # 패턴이다. 반대로 KARPENTER-FINAL.md/CPU_Burst_학습노트.md/homelab 글은 long_body
    # 볼드가 문장 중간 강조용으로 드문드문 섞여 value가 0.09~0.14에 머문다 — 두 그룹
    # 사이 값 0.14~0.31 구간이 비어 있어 0.25를 경계로 잡으면 실측 마진이 넓다.
    triggered = matched >= 3 and value >= 0.25
    note = f"불릿 {total}개 중 short_label {short}개({ratio_short:.0%}), long_body {long_}개, value {value:.2f}"
    return metric("L1", "볼드리드 불릿", "actionable", {"bullets": total, "short_label": short, "long_body": long_}, value, triggered, note)


def m_L2(doc: dict) -> dict:
    tables = [b for b in doc["blocks"] if b["kind"] == "table"]
    two_col = sum(1 for t in tables if t.get("ncols") == 2)
    n_sections = max(len(doc["sections"]), 1)
    if not tables or len(doc["sections"]) < 2:
        return metric("L2", "표 밀도", "report", {"tables": len(tables), "sections": len(doc["sections"]), "two_col": two_col}, 0.0, False, "표본 부족")
    density = len(tables) / n_sections
    value = min(1.0, density)
    triggered = density >= 0.5
    note = f"표 {len(tables)}개 / 섹션 {n_sections}개 = {density:.2f}, 2열 표 {two_col}개"
    return metric("L2", "표 밀도", "report", {"tables": len(tables), "sections": n_sections, "two_col": two_col, "density": round(density, 3)}, value, triggered, note)


PARA_BUCKETS = [0, 1, 2, 4]


def _bucket(n: int, edges: list[int]) -> int:
    b = 0
    for e in edges:
        if n > e:
            b += 1
    return b


def m_L3(doc: dict) -> dict:
    sections = doc["sections"]
    if len(sections) < 4:
        return metric("L3", "섹션 골격 균질성", "report", {"sections": len(sections)}, 0.0, False, "표본 부족")
    tuples = []
    for s in sections:
        sub_blocks = [b for b in doc["blocks"] if s["start"] <= b["start"] <= s["end"] and b is not None]
        n_para = sum(1 for b in sub_blocks if b["kind"] == "paragraph")
        has_list = any(b["kind"] == "list" for b in sub_blocks)
        has_table = any(b["kind"] == "table" for b in sub_blocks)
        has_code = any(b["kind"] == "fence" for b in sub_blocks)
        length = sum(len(doc["lines"][i]) for i in range(s["start"], s["end"] + 1))
        len_bucket = _bucket(length, [200, 600, 1500])
        tuples.append((_bucket(n_para, PARA_BUCKETS), has_list, has_table, has_code, len_bucket))
    counts: dict[tuple, int] = {}
    for t in tuples:
        counts[t] = counts.get(t, 0) + 1
    top = max(counts.values())
    ratio = top / len(tuples)
    triggered = ratio >= 0.6
    return metric("L3", "섹션 골격 균질성", "report", {"sections": len(sections), "top_tuple_count": top}, ratio, triggered, f"최빈 섹션 골격 비중 {ratio:.0%}")


def m_L4(doc: dict) -> dict:
    list_blocks = [b for b in doc["blocks"] if b["kind"] == "list"]
    if len(list_blocks) < 4:
        return metric("L4", "삼분 편향", "report", {"list_blocks": len(list_blocks)}, 0.0, False, "표본 부족")
    three = sum(1 for b in list_blocks if len(b["items"]) == 3)
    ratio = three / len(list_blocks)
    triggered = ratio >= 0.4
    return metric("L4", "삼분 편향", "report", {"list_blocks": len(list_blocks), "three_item_blocks": three}, ratio, triggered, f"리스트 블록 {len(list_blocks)}개 중 3항목 블록 {three}개")


def m_L5(doc: dict) -> dict:
    fences = [b for b in doc["blocks"] if b["kind"] == "fence"]
    qualifying = 0
    for f in fences:
        content_lines = [ln for ln in f["content"] if ln.strip() != ""]
        if not content_lines:
            continue
        # 문자 비중이 아니라 "박스/화살표 문자를 포함한 줄"의 비중을 본다 —
        # 실측 다이어그램은 레이블 텍스트가 대부분이고 연결선 문자는 줄마다
        # 소수만 섞여 있어, 블록 전체 문자 비중으로 재면 실패한다.
        lines_with_art = sum(1 for ln in content_lines if any(c in ASCII_ART_CHARS for c in ln))
        if lines_with_art / len(content_lines) >= 0.20:
            qualifying += 1
    triggered = qualifying >= 1
    value = min(1.0, qualifying / 2.0) if qualifying else 0.0
    return metric("L5", "ASCII 도식", "report", {"fences": len(fences), "ascii_art_blocks": qualifying}, value, triggered, f"박스/화살표 도식 코드블록 {qualifying}개")


def m_L6(doc: dict) -> dict:
    visible_lines = [doc["lines"][i] for i in range(len(doc["lines"])) if doc["kind"][i] not in ("fm", "fence", "skip")]
    text = "\n".join(visible_lines)
    matches = EMOJI_RE.findall(text)
    count = len(matches)
    bullets = len(all_unordered_bullets(doc))
    table_rows = sum(len(b["rows"]) for b in doc["blocks"] if b["kind"] == "table")
    headings = len(doc["headings"])
    denom = max(1, bullets + table_rows + headings)
    ratio = count / denom
    triggered = count >= 3
    value = min(1.0, count / 8.0)
    return metric("L6", "상태·장식 이모지", "actionable", {"count": count, "denom": denom, "ratio": round(ratio, 3)}, value, triggered, f"이모지 {count}개 발견")


def m_L7(doc: dict) -> dict:
    hr_count = sum(1 for b in doc["blocks"] if b["kind"] == "hr")
    n_sections = max(len(doc["sections"]), 1)
    if not doc["sections"]:
        return metric("L7", "수평선 남발", "actionable", {"hr": hr_count, "sections": 0}, 0.0, False, "표본 부족")
    ratio = hr_count / n_sections
    triggered = ratio >= 0.5 and hr_count >= 3
    value = min(1.0, ratio)
    return metric("L7", "수평선 남발", "actionable", {"hr": hr_count, "sections": n_sections, "ratio": round(ratio, 3)}, value, triggered, f"--- {hr_count}개 / 섹션 {n_sections}개")


def m_L8(doc: dict) -> dict:
    sections = doc["sections"]
    if not sections:
        return metric("L8", "마무리 요약 섹션", "actionable", {}, 0.0, False, "표본 부족(헤딩 없음)")
    last = sections[-1]
    heading_text = last["heading"]["text"]
    heading_match = bool(HEADING_SUMMARY_RE.search(heading_text))
    if not heading_match:
        return metric("L8", "마무리 요약 섹션", "actionable", {"last_heading": heading_text, "heading_match": False}, 0.0, False, "마지막 섹션 헤딩이 요약류 키워드와 불일치")
    section_text = "\n".join(doc["lines"][last["start"]:last["end"] + 1])
    rest_text = "\n".join(doc["lines"][: last["start"]])
    section_tokens = content_words(section_text)
    if len(section_tokens) < 5:
        return metric("L8", "마무리 요약 섹션", "actionable", {"last_heading": heading_text, "heading_match": True}, 0.0, False, "표본 부족(내용어 5개 미만)")
    rest_tokens = content_words(rest_text)
    overlap = len(section_tokens & rest_tokens) / len(section_tokens)
    triggered = overlap >= 0.7
    return metric(
        "L8", "마무리 요약 섹션", "actionable",
        {"last_heading": heading_text, "heading_match": True, "restatement_overlap": round(overlap, 3)},
        overlap, triggered,
        f"마지막 섹션 '{heading_text}' 재진술 overlap {overlap:.0%}",
    )


def m_L9(doc: dict) -> dict:
    blocks = doc["blocks"]
    if not doc["headings"]:
        return metric("L9", "서두 요약 박스", "actionable", {}, 0.0, False, "표본 부족(헤딩 없음)")
    # 스펙 정의: "첫 헤딩 직후 3블록 안". 예전 구현은 "다음 섹션 시작 전까지"를
    # 창으로 썼는데, 이러면 첫 섹션이 길 경우(KARPENTER-FINAL.md의 "## 1. 결론
    # 4줄"처럼 분석 문단 4개가 이어지는 섹션) 창이 그 섹션 전체로 넓어져 서두와
    # 무관한 본문 문단까지 서두 요약 박스로 오탐한다. 첫 헤딩 블록 자체의 다음
    # 3블록으로 창을 좁혀 스펙 표현 그대로 구현한다.
    first_h_idx = next(i for i, b in enumerate(blocks) if b["kind"] == "heading")
    window_blocks = blocks[first_h_idx + 1 : first_h_idx + 1 + 3]
    window_end = window_blocks[-1]["end"] + 1 if window_blocks else blocks[first_h_idx]["end"] + 1
    evidence = []
    triggered = False
    for b in window_blocks:
        if b["kind"] == "blockquote":
            rest_text = "\n".join(doc["lines"][: b["start"]] + doc["lines"][b["end"] + 1 :])
            cls = classify_quote(b["text"], rest_text)
            if cls == "summary":
                triggered = True
                evidence.append({"kind": "blockquote", "line": b["start"], "class": cls})
        elif b["kind"] == "paragraph":
            m = BOLD_LEAD_PARA_RE.match(b["text"])
            if m and TLDR_KEYWORDS_RE.search(m.group(1)):
                # 볼드 라벨 자체가 "요약/핵심/TL;DR" 류일 때만 서두 요약 박스로
                # 본다. 라벨이 "(a) 블로그 원고 주장 판정"처럼 열거형 각주 라벨이면
                # (KARPENTER-FINAL.md "결론 4줄" 섹션) 볼드리드 문단이라는 형태만
                # 같을 뿐 TL;DR 박스가 아니다 — L1의 short/long 구분과 같은 취지로,
                # "형태"가 아니라 "라벨의 내용"으로 판정해야 정직한 분석 문단을
                # AI로 몰지 않는다.
                triggered = True
                evidence.append({"kind": "paragraph", "line": b["start"]})
    note = "서두(첫 헤딩 직후 3블록 안)에 TL;DR성 인용블록/볼드리드 문단 발견" if triggered else "서두 요약 박스 없음"
    return metric("L9", "서두 요약 박스", "actionable", {"window_end_line": window_end, "evidence": evidence}, 1.0 if triggered else 0.0, triggered, note)


def m_L10(doc: dict) -> dict:
    bqs = [b for b in doc["blocks"] if b["kind"] == "blockquote"]
    if not bqs:
        return metric("L10", "강조용 인용블록", "actionable", {"blockquotes": 0}, 0.0, False, "표본 부족(인용블록 없음)")
    valid = []
    excluded = {"caption": 0, "warning": 0}
    for b in bqs:
        rest_text = "\n".join(doc["lines"][: b["start"]] + doc["lines"][b["end"] + 1 :])
        cls = classify_quote(b["text"], rest_text)
        if cls in ("caption", "warning"):
            excluded[cls] += 1
            continue
        valid.append((b, cls))
    if len(valid) < 2:
        return metric(
            "L10", "강조용 인용블록", "actionable",
            {"blockquotes": len(bqs), "excluded_caption": excluded["caption"], "excluded_warning": excluded["warning"], "valid": len(valid)},
            0.0, False, "표본 부족(메타데이터 캡션/경고 제외 후 유효 블록 2개 미만)",
        )
    no_source = sum(1 for b, _ in valid if not SOURCE_MARKER_RE.search(b["text"]))
    ratio = no_source / len(valid)
    triggered = ratio >= 0.6 and len(valid) >= 2
    return metric(
        "L10", "강조용 인용블록", "actionable",
        {"blockquotes": len(bqs), "excluded_caption": excluded["caption"], "excluded_warning": excluded["warning"], "valid": len(valid), "no_source": no_source},
        ratio, triggered,
        f"인용블록 {len(bqs)}개 중 캡션/경고 {excluded['caption']+excluded['warning']}개 제외, 유효 {len(valid)}개 중 무출처 {no_source}개",
    )


def m_L11(doc: dict) -> dict:
    levels = [h["level"] for h in doc["headings"]]
    if len(levels) < 5:
        return metric("L11", "헤딩 깊이 균일성", "report", {"headings": len(levels)}, 0.0, False, "표본 부족")
    import math

    counts: dict[int, int] = {}
    for lv in levels:
        counts[lv] = counts.get(lv, 0) + 1
    n = len(levels)
    distinct = len(counts)
    if distinct == 1:
        norm_entropy = 0.0
    else:
        entropy = -sum((c / n) * math.log2(c / n) for c in counts.values())
        norm_entropy = entropy / math.log2(distinct)
    value = 1 - norm_entropy
    triggered = value >= 0.7
    return metric("L11", "헤딩 깊이 균일성", "report", {"headings": n, "distinct_levels": distinct, "level_counts": counts}, value, triggered, f"헤딩 레벨 정규화 엔트로피 {norm_entropy:.2f}")


def m_L12(doc: dict) -> dict:
    bullets = all_unordered_bullets(doc)
    if len(bullets) < 5:
        return metric("L12", "불릿 길이 균일성", "report", {"bullets": len(bullets)}, 0.0, False, "표본 부족")
    lens = [len(it["text"]) for it in bullets]
    n = len(lens)
    mean = sum(lens) / n
    if mean == 0:
        return metric("L12", "불릿 길이 균일성", "report", {"bullets": n}, 0.0, False, "표본 부족(빈 불릿)")
    var = sum((x - mean) ** 2 for x in lens) / n
    stdev = var ** 0.5
    cv = stdev / mean
    value = 1 - min(cv / 0.7, 1.0)
    triggered = cv < 0.35
    return metric("L12", "불릿 길이 균일성", "report", {"bullets": n, "mean_len": round(mean, 1), "cv": round(cv, 3)}, value, triggered, f"불릿 {n}개 길이 CV {cv:.2f}")


def m_L13(doc: dict) -> dict:
    blocks = doc["blocks"]
    paragraphs = [(idx, b) for idx, b in enumerate(blocks) if b["kind"] == "paragraph"]
    total = len(paragraphs)
    if total < 3:
        return metric("L13", "콜론 유도", "report", {"paragraphs": total}, 0.0, False, "표본 부족")
    numerator = 0
    for idx, b in paragraphs:
        if not b["text"].rstrip().endswith((":", "：")):
            continue
        if idx + 1 < len(blocks) and blocks[idx + 1]["kind"] in ("list", "fence"):
            numerator += 1
    ratio = numerator / total
    triggered = ratio >= 0.4 and numerator >= 3
    return metric("L13", "콜론 유도", "report", {"paragraphs": total, "colon_induced": numerator}, ratio, triggered, f"문단 {total}개 중 콜론-유도 {numerator}개")


def _heading_end_form(text: str) -> str:
    t = re.sub(r"^[\d.\s#]+", "", text).strip()
    t = re.sub(r"[)\]}\s]+$", "", t)
    if not t:
        return "noun"
    if QUESTION_END_RE.search(t):
        return "question"
    if VERB_END_RE.search(t):
        return "verb"
    if PARTICLE_END_RE.search(t):
        return "particle"
    return "noun"


def m_L14(doc: dict) -> dict:
    by_level: dict[int, list[str]] = {}
    for h in doc["headings"]:
        by_level.setdefault(h["level"], []).append(h["text"])
    best_ratio = 0.0
    best_level = None
    best_count = 0
    for lv, texts in by_level.items():
        if len(texts) < 4:
            continue
        forms = [_heading_end_form(t) for t in texts]
        counts: dict[str, int] = {}
        for f in forms:
            counts[f] = counts.get(f, 0) + 1
        ratio = max(counts.values()) / len(forms)
        if ratio > best_ratio:
            best_ratio = ratio
            best_level = lv
            best_count = len(texts)
    if best_level is None:
        return metric("L14", "헤딩 형태 병렬", "report", {}, 0.0, False, "표본 부족(레벨당 헤딩 4개 미만)")
    triggered = best_ratio >= 0.7
    return metric("L14", "헤딩 형태 병렬", "report", {"level": best_level, "count": best_count, "ratio": round(best_ratio, 3)}, best_ratio, triggered, f"H{best_level} 헤딩 {best_count}개 중 최빈 종결형 비중 {best_ratio:.0%}")


METRIC_FUNCS = [m_L1, m_L2, m_L3, m_L4, m_L5, m_L6, m_L7, m_L8, m_L9, m_L10, m_L11, m_L12, m_L13, m_L14]
ACTIONABLE_IDS = ["L1", "L6", "L7", "L8", "L9", "L10"]
REPORT_IDS = ["L2", "L3", "L4", "L5", "L11", "L12", "L13", "L14"]


# ---------------------------------------------------------------------------
# 7. 집계
# ---------------------------------------------------------------------------


def compute_all_metrics(text: str) -> list[dict]:
    doc = parse_document(text)
    return [f(doc) for f in METRIC_FUNCS]


def aggregate(metrics: list[dict]) -> dict:
    by_id = {m["id"]: m for m in metrics}
    actionable_vals = [by_id[i]["value"] for i in ACTIONABLE_IDS]
    report_vals = [by_id[i]["value"] for i in REPORT_IDS]

    # report 축 가중은 actionable 의 1/3 (actionable:report = 3:1)
    w_a, w_r = 3, 1
    weighted_sum = w_a * sum(actionable_vals) + w_r * sum(report_vals)
    weighted_n = w_a * len(actionable_vals) + w_r * len(report_vals)
    layout_ai_score = round(100 * weighted_sum / weighted_n, 1) if weighted_n else 0.0

    actionable_score = round(100 * (sum(actionable_vals) / len(actionable_vals)), 1) if actionable_vals else 0.0

    if layout_ai_score <= 20:
        grade = "A"
    elif layout_ai_score <= 40:
        grade = "B"
    elif layout_ai_score <= 60:
        grade = "C"
    else:
        grade = "D"

    triggered_actionable = [i for i in ACTIONABLE_IDS if by_id[i]["triggered"]]
    triggered_report = [i for i in REPORT_IDS if by_id[i]["triggered"]]
    top_findings = [by_id[i]["note"] for i in (triggered_actionable + triggered_report)][:5]

    return {
        "layout_ai_score": layout_ai_score,
        "actionable_score": actionable_score,
        "grade": grade,
        "triggered_actionable": triggered_actionable,
        "triggered_report": triggered_report,
        "top_findings": top_findings,
    }


# ---------------------------------------------------------------------------
# 8. 사람이 읽는 출력
# ---------------------------------------------------------------------------


def print_score_table(file_: str, mode: str, metrics: list[dict], agg: dict) -> None:
    print(f"파일: {file_}  (mode={mode})")
    print(f"{'ID':<4} {'라벨':<16} {'종류':<10} {'값':>6} {'발동':>6}  근거")
    print("-" * 90)
    for m in metrics:
        mark = "O" if m["triggered"] else "-"
        print(f"{m['id']:<4} {m['label']:<16} {m['kind']:<10} {m['value']:>6.2f} {mark:>6}  {m['note']}")
    print("-" * 90)
    print(f"layout_ai_score = {agg['layout_ai_score']:.1f}  grade = {agg['grade']}")
    print(f"actionable_score = {agg['actionable_score']:.1f}  (판정 기준)")
    if agg["triggered_actionable"]:
        print(f"발동된 actionable 지표: {', '.join(agg['triggered_actionable'])}")
    if agg["triggered_report"]:
        print(f"발동된 report(고지 전용) 지표: {', '.join(agg['triggered_report'])}")


# ---------------------------------------------------------------------------
# 9. CLI — score
# ---------------------------------------------------------------------------


def read_src(path_str: str) -> str | None:
    p = Path(path_str)
    try:
        return p.read_bytes().decode("utf-8")
    except OSError as e:
        print(f"오류: 파일을 읽을 수 없습니다: {e}", file=sys.stderr)
        return None
    except UnicodeDecodeError as e:
        print(f"오류: UTF-8 디코딩 실패: {e}", file=sys.stderr)
        return None


def cmd_score(args: argparse.Namespace) -> int:
    text = read_src(args.src)
    if text is None:
        return 3
    metrics = compute_all_metrics(text)
    agg = aggregate(metrics)
    print_score_table(args.src, args.mode, metrics, agg)
    if args.json:
        report = {
            "file": args.src,
            "mode": args.mode,
            "layout_ai_score": agg["layout_ai_score"],
            "actionable_score": agg["actionable_score"],
            "grade": agg["grade"],
            "metrics": metrics,
            "triggered_actionable": agg["triggered_actionable"],
            "top_findings": agg["top_findings"],
        }
        print(json.dumps(report, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# 10. CLI — compare
# ---------------------------------------------------------------------------


def cmd_compare(args: argparse.Namespace) -> int:
    before_text = read_src(args.before)
    after_text = read_src(args.after)
    if before_text is None or after_text is None:
        return 3

    before_metrics = compute_all_metrics(before_text)
    after_metrics = compute_all_metrics(after_text)
    before_agg = aggregate(before_metrics)
    after_agg = aggregate(after_metrics)

    before_by_id = {m["id"]: m for m in before_metrics}
    after_by_id = {m["id"]: m for m in after_metrics}

    per_metric = []
    newly_triggered = []
    for i in [m["id"] for m in before_metrics]:
        b = before_by_id[i]
        a = after_by_id[i]
        per_metric.append({"id": i, "before": b["value"], "after": a["value"], "delta": round(a["value"] - b["value"], 4)})
        if i in ACTIONABLE_IDS and (not b["triggered"]) and a["triggered"]:
            newly_triggered.append(i)

    before_score = before_agg["actionable_score"]
    after_score = after_agg["actionable_score"]

    if newly_triggered:
        verdict = "regressed"
        exit_code = 2
    elif before_score < 20:
        verdict = "pass"
        exit_code = 0
    elif after_score > before_score:
        verdict = "regressed"
        exit_code = 2
    else:
        rel_drop = (before_score - after_score) / before_score if before_score else 0.0
        if rel_drop >= args.min_drop:
            verdict = "pass"
            exit_code = 0
        else:
            verdict = "insufficient"
            exit_code = 1

    drop = {
        "actionable": round((before_score - after_score) / before_score, 4) if before_score else 0.0,
        "layout": round((before_agg["layout_ai_score"] - after_agg["layout_ai_score"]) / before_agg["layout_ai_score"], 4) if before_agg["layout_ai_score"] else 0.0,
    }

    print(f"before: {args.before}  after: {args.after}  (mode={args.mode})")
    print(f"{'ID':<4} {'라벨':<16} {'before':>8} {'after':>8} {'Δ':>8}")
    print("-" * 60)
    for pm in per_metric:
        arrow = "->"
        print(f"{pm['id']:<4} {before_by_id[pm['id']]['label']:<16} {pm['before']:>8.2f} {arrow:^4} {pm['after']:>8.2f}  Δ{pm['delta']:+.2f}")
    print("-" * 60)
    print(f"actionable_score: {before_score:.1f} -> {after_score:.1f}  (상대 하락률 {drop['actionable']:.0%})")
    print(f"layout_ai_score : {before_agg['layout_ai_score']:.1f} -> {after_agg['layout_ai_score']:.1f}")
    if newly_triggered:
        print(f"경고: 윤문 후 새로 발동한 actionable 지표: {', '.join(newly_triggered)} (지문 재생산)")
    print(f"판정: {verdict}  (exit={exit_code})")

    if args.json:
        report = {
            "before": {"file": args.before, "layout_ai_score": before_agg["layout_ai_score"], "actionable_score": before_score, "grade": before_agg["grade"], "triggered_actionable": before_agg["triggered_actionable"]},
            "after": {"file": args.after, "layout_ai_score": after_agg["layout_ai_score"], "actionable_score": after_score, "grade": after_agg["grade"], "triggered_actionable": after_agg["triggered_actionable"]},
            "drop": drop,
            "verdict": verdict,
            "newly_triggered_actionable": newly_triggered,
            "per_metric": per_metric,
            "exit": exit_code,
        }
        print(json.dumps(report, ensure_ascii=False))

    return exit_code


# ---------------------------------------------------------------------------
# 11. argparse
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="llm_signature.py", description="마크다운 문서의 LLM 레이아웃 지문 스코어러 (L1~L14)")
    sub = p.add_subparsers(dest="command", required=True)

    ps = sub.add_parser("score", help="문서 하나를 채점한다")
    ps.add_argument("--src", required=True, help="채점할 .md 파일")
    ps.add_argument("--mode", choices=["post", "reference"], default="post", help="게시물/참조문서 — 현재 정책상 채점 로직은 동일하다")
    ps.add_argument("--json", action="store_true", help="stdout 마지막 줄에 JSON 한 줄 추가")
    ps.set_defaults(func=cmd_score)

    pc = sub.add_parser("compare", help="윤문 전/후 문서를 비교해 게이트 판정을 낸다")
    pc.add_argument("--before", required=True)
    pc.add_argument("--after", required=True)
    pc.add_argument("--mode", choices=["post", "reference"], default="post")
    pc.add_argument("--min-drop", type=float, default=0.25, dest="min_drop")
    pc.add_argument("--json", action="store_true")
    pc.set_defaults(func=cmd_compare)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:  # noqa: BLE001 — CLI 최상위 안전망
        print(f"오류: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
