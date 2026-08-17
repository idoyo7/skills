#!/usr/bin/env python3
"""humanize-docs — md_shield.py — 마크다운 마스킹/복원/검증 레이어.

humanize-korean 은 평문 전용이다. 이 스크립트는 마크다운 문서의 코드펜스·
frontmatter·표·링크 목적지·수식 등 "구조"를 토큰(⟦HZ-Bnnnn⟧ / ⟦HZ-Innnn⟧)
으로 격리해 산문만 윤문 파이프라인에 넘기고, 윤문이 끝나면 토큰을 원문으로
되돌린 뒤 구조가 그대로인지 검증한다.

핵심 불변식(IDENTITY): mask 로 만든 산문을 한 글자도 고치지 않고 restore
하면 원본 파일과 바이트 단위로 완전히 동일해야 한다. mask 는 자기 자신이
이 불변식을 만족하는지 내부에서 항상 검사하며(_assert_identity), 어긋나면
조용히 넘어가지 않고 exit 3 으로 실패한다.

세 하위 명령:
    mask    — .md -> (산문 텍스트, map.json)
    restore — (윤문된 산문, map.json) -> .md
    verify  — (원본 .md, 복원 .md, map.json) -> 구조 무결성 판정

exit code: 0=통과, 1=경고(사용 가능·고지 필요), 2=실패(채택 금지),
           3=사용법/IO/자체검증 오류.

설계 원칙:
    - 파싱은 줄 단위 상태 머신. 정규식 하나로 문서 전체를 파싱하지 않는다.
    - 처리 순서: frontmatter -> 블록 스캔(fence/html/table/indent_code/
      shortcode/math) -> 남은 프로즈 줄에서만 인라인 스캔. 블록이 인라인을
      항상 이긴다 — 펜스 안의 URL·백틱은 절대 따로 토큰화하지 않는다.
    - 헤딩은 마스킹하지 않는다. map 에 raw 그대로 기록해 두고 restore 가
      헤딩 줄 개수가 맞을 때만 강제로 원문으로 되돌린다(앵커 링크 보존).

파일 I/O 주의: 개행을 조금도 정규화하면 안 된다(CRLF·끝개행 없음까지
바이트 단위로 보존). Path.read_text()/write_text() 는 텍스트 모드 유니버설
뉴라인 변환 때문에 \\r\\n 을 \\n 으로 뭉개버린다 — 이 스크립트는 그 대신
read_bytes().decode('utf-8') / write_bytes(text.encode('utf-8')) 로
바이트 단위 원본을 그대로 보존한다(newline='' 오픈 파라미터는 쓰지 않음).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from collections import deque
from pathlib import Path

# ---------------------------------------------------------------------------
# 파일 I/O — 개행 무변형 읽기/쓰기
# ---------------------------------------------------------------------------


def read_text_raw(path: Path) -> str:
    """개행을 전혀 정규화하지 않고 UTF-8 텍스트를 읽는다."""
    return path.read_bytes().decode("utf-8")


def write_text_raw(path: Path, text: str) -> None:
    """개행을 전혀 정규화하지 않고 UTF-8 텍스트를 쓴다."""
    path.write_bytes(text.encode("utf-8"))


# ---------------------------------------------------------------------------
# 토큰 형식
# ---------------------------------------------------------------------------

TOKEN_OPEN = "⟦"
TOKEN_CLOSE = "⟧"
CONFLICT_RE = re.compile(r"⟦HZ-")


def make_token(sid: str) -> str:
    return f"{TOKEN_OPEN}{sid}{TOKEN_CLOSE}"


# ---------------------------------------------------------------------------
# 공통 정규식 — mask 의 블록/인라인 스캔과 verify 의 구조 재계산이 함께 쓴다
# ---------------------------------------------------------------------------

# 펜스 여는 줄. 탭 들여쓰기 펜스도 인식해야 한다(테스트 코퍼스 01번 참고).
FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
HTML_BLOCK_START_RE = re.compile(r"^ {0,3}<(!--|\?|!\[CDATA\[|/?[a-zA-Z])")
SHORTCODE_BLOCK_RE = re.compile(r"^\s*(\{\{[<%].*?[%>]\}\}|\{%.*?%\})\s*$")
TABLE_SEP_RE = re.compile(r"^\s*\|?\s*:?-{1,}:?\s*(\|\s*:?-{1,}:?\s*)*\|?\s*$")
HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*))?$")
# 순서 목록 마커의 숫자는 0개도 허용한다 — 윤문 중 숫자가 깎여나가도
# (예: "1. " -> ". ") 여전히 리스트 항목으로 인식해 구조 비교가 살아있게 한다.
LIST_MARKER_RE = re.compile(r"^ {0,3}([-*+]|\d{0,9}[.)])(?:\s+|$)")
REF_DEF_RE = re.compile(r"^ {0,3}\[(?!\^)([^\]]+)\]:\s*\S")
FOOTNOTE_REF_RE = re.compile(r"\[\^[^\]\s]+\]")
AUTOLINK_RE = re.compile(
    r"<([a-zA-Z][a-zA-Z0-9+.\-]{1,31}:[^\s<>]*|[^\s<>@]+@[^\s<>]+\.[^\s<>]+)>"
)
HTML_INLINE_RE = re.compile(r"<!--.*?-->|</?[a-zA-Z][^<>\n]*>")
SHORTCODE_INLINE_RE = re.compile(r"\{\{[<%].*?[%>]\}\}|\{%.*?%\}")
MATH_INLINE_RE = re.compile(r"\$(?!\$)[^$\n]+?\$(?!\$)")
ANCHOR_RE = re.compile(r"\{#[A-Za-z0-9_\-:.]+(?:\s[^{}]*)?\}")
URL_BARE_RE = re.compile(r"https?://[^\s<>\]\)]+")


def is_fence_close(line: str, fence_char: str, n: int) -> bool:
    """줄이 fence_char 로만 이루어진 길이 n 이상의 닫힘 줄인지 확인한다."""
    s = line.strip()
    if len(s) < n:
        return False
    return all(c == fence_char for c in s)


def looks_like_indent_code(line: str) -> bool:
    return (line.startswith("    ") or line.startswith("\t")) and line.strip() != ""


def find_matching_bracket(s: str, open_idx: int) -> int | None:
    """s[open_idx] == '[' 에서 시작해 짝이 맞는 ']' 의 인덱스를 찾는다."""
    depth = 0
    i = open_idx
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def find_matching_paren(s: str, open_idx: int) -> int | None:
    """s[open_idx] == '(' 에서 시작해 짝이 맞는 ')' 의 인덱스를 찾는다."""
    depth = 0
    i = open_idx
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\" and i + 1 < n:
            i += 2
            continue
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return None


def match_inline_code(line: str, i: int) -> int | None:
    """line[i] 가 백틱일 때, 같은 길이의 닫는 런을 찾아 끝 인덱스(배타)를 반환한다."""
    n = 0
    j = i
    length = len(line)
    while j < length and line[j] == "`":
        n += 1
        j += 1
    k = j
    while k < length:
        if line[k] == "`":
            start = k
            m = 0
            while k < length and line[k] == "`":
                m += 1
                k += 1
            if m == n:
                return k
        else:
            k += 1
    return None


def match_image(line: str, i: int) -> int | None:
    """line[i] == '!' 이고 다음이 '[' 일 때 ![...](...)  전체의 끝(배타)을 반환한다."""
    if line[i] != "!" or i + 1 >= len(line) or line[i + 1] != "[":
        return None
    close_b = find_matching_bracket(line, i + 1)
    if close_b is None or close_b + 1 >= len(line) or line[close_b + 1] != "(":
        return None
    close_p = find_matching_paren(line, close_b + 1)
    if close_p is None:
        return None
    return close_p + 1


def match_link(line: str, i: int) -> tuple[int, int] | None:
    """line[i] == '[' 일 때 (']' 인덱스, ')' 끝 인덱스(배타)) 를 반환한다.

    호출부는 [close_b:token_end] 만 토큰화하고 그 앞의 '[텍스트' 는 산문으로 남긴다.
    """
    if line[i] != "[":
        return None
    close_b = find_matching_bracket(line, i)
    if close_b is None or close_b + 1 >= len(line) or line[close_b + 1] != "(":
        return None
    close_p = find_matching_paren(line, close_b + 1)
    if close_p is None:
        return None
    return close_b, close_p + 1


# ---------------------------------------------------------------------------
# 줄 분리 — '\n' 만 경계로 삼고, 끝개행 여부를 별도 플래그로 기억한다.
# 이렇게 하면 각 "줄" 문자열에 원본의 \r 이 그대로 남아 CRLF 도 보존된다.
# ---------------------------------------------------------------------------


def split_lines_keep_structure(text: str) -> tuple[list[str], bool]:
    if text == "":
        return [], False
    trailing = text.endswith("\n")
    body = text[:-1] if trailing else text
    lines = body.split("\n")
    return lines, trailing


def join_lines_keep_structure(lines: list[str], trailing_newline: bool) -> str:
    return "\n".join(lines) + ("\n" if trailing_newline else "")


# ---------------------------------------------------------------------------
# MaskContext — mask 진행 중 세그먼트/헤딩을 순서대로 누적한다
# ---------------------------------------------------------------------------


class MaskContext:
    def __init__(self, protect_tables: bool, protect_math: bool):
        self.protect_tables = protect_tables
        self.protect_math = protect_math
        self.block_n = 0
        self.inline_n = 0
        self.segments: list[dict] = []
        self.headings: list[dict] = []

    def new_block(self, kind: str, text: str, pad_before: bool, pad_after: bool) -> str:
        self.block_n += 1
        sid = f"HZ-B{self.block_n:04d}"
        self.segments.append(
            {
                "id": sid,
                "kind": kind,
                "inline": False,
                "text": text,
                "pad_before": pad_before,
                "pad_after": pad_after,
            }
        )
        return make_token(sid)

    def new_inline(self, kind: str, text: str) -> str:
        self.inline_n += 1
        sid = f"HZ-I{self.inline_n:04d}"
        self.segments.append({"id": sid, "kind": kind, "inline": True, "text": text})
        return make_token(sid)


def emit_block(
    ctx: MaskContext,
    out_lines: list[str],
    kind: str,
    seg_lines: list[str],
    lines: list[str],
    end_idx: int,
) -> None:
    """블록 세그먼트를 만들어 out_lines 에 토큰 줄로 삽입한다.

    토큰은 반드시 자기 줄 단독 + 앞뒤 빈 줄. 이미 문서 시작/끝이거나 이미
    빈 줄이 있으면 추가로 패딩하지 않는다(패딩 여부는 segment 에 기록해
    restore 가 정확히 그만큼만 제거하게 한다).
    """
    text = "\n".join(seg_lines)
    pad_before = bool(out_lines) and out_lines[-1].strip() != ""
    pad_after = end_idx < len(lines) and lines[end_idx].strip() != ""
    token = ctx.new_block(kind, text, pad_before, pad_after)
    if pad_before:
        out_lines.append("")
    out_lines.append(token)
    if pad_after:
        out_lines.append("")


def mask_inline(line: str, ctx: MaskContext) -> str:
    """프로즈 한 줄에서 인라인 보호 대상을 찾아 토큰으로 치환한다."""
    out: list[str] = []
    i = 0
    n = len(line)
    while i < n:
        ch = line[i]
        matched = False

        if ch == "`":
            end = match_inline_code(line, i)
            if end is not None:
                token = ctx.new_inline("inline_code", line[i:end])
                out.append(token)
                i = end
                matched = True

        if not matched and ch == "!" and i + 1 < n and line[i + 1] == "[":
            end = match_image(line, i)
            if end is not None:
                token = ctx.new_inline("image", line[i:end])
                out.append(token)
                i = end
                matched = True

        if not matched and ch == "[":
            fm = FOOTNOTE_REF_RE.match(line, i)
            if fm:
                token = ctx.new_inline("footnote_ref", fm.group(0))
                out.append(token)
                i = fm.end()
                matched = True
            else:
                lr = match_link(line, i)
                if lr is not None:
                    close_b, token_end = lr
                    out.append(line[i:close_b])  # '[텍스트' 는 산문으로 남긴다
                    token = ctx.new_inline("link_dest", line[close_b:token_end])
                    out.append(token)
                    i = token_end
                    matched = True

        if not matched and ch == "<":
            am = AUTOLINK_RE.match(line, i)
            if am:
                token = ctx.new_inline("autolink", am.group(0))
                out.append(token)
                i = am.end()
                matched = True
            else:
                hm = HTML_INLINE_RE.match(line, i)
                if hm:
                    token = ctx.new_inline("html_inline", hm.group(0))
                    out.append(token)
                    i = hm.end()
                    matched = True

        if not matched and ctx.protect_math and ch == "$":
            mm = MATH_INLINE_RE.match(line, i)
            if mm:
                token = ctx.new_inline("math_inline", mm.group(0))
                out.append(token)
                i = mm.end()
                matched = True

        if not matched and ch == "{":
            sm = SHORTCODE_INLINE_RE.match(line, i)
            if sm:
                token = ctx.new_inline("shortcode_inline", sm.group(0))
                out.append(token)
                i = sm.end()
                matched = True
            else:
                anm = ANCHOR_RE.match(line, i)
                if anm:
                    token = ctx.new_inline("anchor", anm.group(0))
                    out.append(token)
                    i = anm.end()
                    matched = True

        if not matched and ch == "h":
            um = URL_BARE_RE.match(line, i)
            if um:
                token = ctx.new_inline("url_bare", um.group(0))
                out.append(token)
                i = um.end()
                matched = True

        if not matched:
            out.append(ch)
            i += 1

    return "".join(out)


def _heading_record(index: int, line: str) -> dict:
    m = HEADING_RE.match(line)
    level = len(m.group(1))
    text = (m.group(2) or "")
    text = re.sub(r"\s+#+\s*$", "", text).strip()
    return {"index": index, "level": level, "raw": line, "text": text}


def compute_list_blocks(lines: list[str]) -> list[int]:
    """연속된 리스트 마커 줄들을 블록으로 묶어 블록별 항목 수를 반환한다."""
    blocks: list[int] = []
    in_list = False
    count = 0
    for line in lines:
        if LIST_MARKER_RE.match(line):
            if not in_list:
                in_list = True
                count = 0
            count += 1
        elif line.strip() == "":
            continue
        elif line[:1] in (" ", "\t"):
            continue
        else:
            if in_list:
                blocks.append(count)
                in_list = False
    if in_list:
        blocks.append(count)
    return blocks


def compute_structure(text: str) -> dict:
    """원본/복원본 비교용 구조 통계. mask 시 원본 통계를 map 에 남기고,
    verify 시 복원본에 동일 함수를 다시 돌려 비교한다."""
    lines = text.split("\n")

    fence_infos: list[str] = []
    in_fence = False
    fence_char = fence_n = None
    for line in lines:
        if not in_fence:
            m = FENCE_OPEN_RE.match(line)
            if m:
                fence_char = m.group(1)[0]
                fence_n = len(m.group(1))
                fence_infos.append(line[m.end(1):].strip())
                in_fence = True
        else:
            if is_fence_close(line, fence_char, fence_n):
                in_fence = False

    link_targets: list[str] = []
    for m in re.finditer(r"!\[[^\]\n]*\]\(([^)\n]*)\)", text):
        link_targets.append(m.group(1).strip())
    for m in re.finditer(r"(?<!!)\[[^\]\n]*\]\(([^)\n]*)\)", text):
        link_targets.append(m.group(1).strip())
    for m in AUTOLINK_RE.finditer(text):
        link_targets.append(m.group(0)[1:-1])
    for m in URL_BARE_RE.finditer(text):
        link_targets.append(m.group(0))
    for m in re.finditer(r"(?m)^ {0,3}\[(?!\^)([^\]\n]+)\]:\s*(\S+)", text):
        link_targets.append(m.group(2).strip())

    heading_seq: list[str] = []
    for line in lines:
        m = HEADING_RE.match(line)
        if m:
            htext = re.sub(r"\s+#+\s*$", "", (m.group(2) or "")).strip()
            heading_seq.append(f"{len(m.group(1))}:{htext}")

    list_blocks = compute_list_blocks(lines)

    table_count = 0
    i = 0
    n = len(lines)
    while i < n:
        if (
            "|" in lines[i]
            and i + 1 < n
            and "|" in lines[i + 1]
            and TABLE_SEP_RE.match(lines[i + 1].strip())
        ):
            table_count += 1
            j = i + 2
            while j < n and lines[j].strip() != "" and "|" in lines[j]:
                j += 1
            i = j
        else:
            i += 1

    number_tokens = re.findall(r"\d+", text)
    hangul_chars = sum(1 for c in text if "가" <= c <= "힣")
    total_chars = len(text)

    paragraph_count = 0
    in_para = False
    for line in lines:
        if line.strip() != "":
            if not in_para:
                paragraph_count += 1
                in_para = True
        else:
            in_para = False

    return {
        "fence_count": len(fence_infos),
        "fence_infos": fence_infos,
        "link_targets": link_targets,
        "heading_seq": heading_seq,
        "list_blocks": list_blocks,
        "table_count": table_count,
        "number_tokens": number_tokens,
        "hangul_chars": hangul_chars,
        "total_chars": total_chars,
        "paragraph_count": paragraph_count,
    }


# ---------------------------------------------------------------------------
# mask 본체
# ---------------------------------------------------------------------------


class MaskConflictError(Exception):
    pass


class IdentityViolation(Exception):
    pass


def mask_document(src_text: str, profile: str, protect_tables: bool, protect_math: bool):
    if CONFLICT_RE.search(src_text):
        raise MaskConflictError("원문에 이미 ⟦HZ- 토큰이 있습니다 — 충돌 방지를 위해 거부합니다.")

    lines, trailing_newline = split_lines_keep_structure(src_text)
    ctx = MaskContext(protect_tables, protect_math)
    out_lines: list[str] = []
    n = len(lines)
    i = 0
    in_list = False

    # frontmatter: 파일 맨 앞줄이 --- 또는 +++ 단독일 때만
    if n > 0 and lines[0].rstrip() in ("---", "+++"):
        delim = lines[0].rstrip()
        close_idx = None
        for k in range(1, n):
            if lines[k].rstrip() == delim:
                close_idx = k
                break
        if close_idx is not None:
            emit_block(ctx, out_lines, "frontmatter", lines[0 : close_idx + 1], lines, close_idx + 1)
            i = close_idx + 1

    while i < n:
        line = lines[i]

        # 1) 코드펜스 — 항상 최우선(리스트 컨텍스트와 무관하게 보호)
        m = FENCE_OPEN_RE.match(line)
        if m:
            fence_char = m.group(1)[0]
            fence_n = len(m.group(1))
            j = i + 1
            end_idx = n
            while j < n:
                if is_fence_close(lines[j], fence_char, fence_n):
                    end_idx = j + 1
                    break
                j += 1
            else:
                end_idx = n
            emit_block(ctx, out_lines, "fence", lines[i:end_idx], lines, end_idx)
            i = end_idx
            in_list = False
            continue

        # 2) HTML 블록 — 줄 시작이 '<' 이고 빈 줄까지 소비
        if HTML_BLOCK_START_RE.match(line):
            j = i + 1
            while j < n and lines[j].strip() != "":
                j += 1
            emit_block(ctx, out_lines, "html_block", lines[i:j], lines, j)
            i = j
            continue

        # 3) 블록 수식 $$...$$ (--protect-math 일 때만)
        if protect_math:
            stripped = line.strip()
            if stripped == "$$":
                j = i + 1
                end_idx = n
                while j < n:
                    if lines[j].strip() == "$$":
                        end_idx = j + 1
                        break
                    j += 1
                else:
                    end_idx = n
                emit_block(ctx, out_lines, "math_block", lines[i:end_idx], lines, end_idx)
                i = end_idx
                continue
            if stripped.startswith("$$") and stripped.endswith("$$") and len(stripped) > 2:
                emit_block(ctx, out_lines, "math_block", [line], lines, i + 1)
                i += 1
                continue

        # 4) 쇼트코드 블록 — 자기 줄 단독
        if SHORTCODE_BLOCK_RE.match(line):
            emit_block(ctx, out_lines, "shortcode_block", [line], lines, i + 1)
            i += 1
            continue

        # 5) 헤딩 — 마스킹하지 않는다. map.headings 에만 기록하고 그대로 통과.
        if HEADING_RE.match(line):
            ctx.headings.append(_heading_record(len(ctx.headings), line))
            out_lines.append(line)
            i += 1
            in_list = False
            continue

        # 6) 표 — 헤더 + 구분행 + 본문행
        if (
            protect_tables
            and "|" in line
            and i + 1 < n
            and "|" in lines[i + 1]
            and TABLE_SEP_RE.match(lines[i + 1].strip())
        ):
            j = i + 2
            while j < n and lines[j].strip() != "" and "|" in lines[j]:
                j += 1
            emit_block(ctx, out_lines, "table", lines[i:j], lines, j)
            i = j
            continue

        # 7) 들여쓰기 코드 블록 — 리스트 컨텍스트 밖 + 직전이 빈 줄/문서 시작일 때만
        if (
            not in_list
            and looks_like_indent_code(line)
            and (not out_lines or out_lines[-1].strip() == "")
        ):
            j = i
            last_content = i
            while j < n:
                l2 = lines[j]
                if l2.strip() == "":
                    j += 1
                    continue
                if l2.startswith("    ") or l2.startswith("\t"):
                    j += 1
                    last_content = j
                    continue
                break
            emit_block(ctx, out_lines, "indent_code", lines[i:last_content], lines, last_content)
            i = last_content
            continue

        # 8) 참조 정의 줄 [id]: url 전체 — 인라인 kind 지만 줄 전체를 토큰화
        if REF_DEF_RE.match(line):
            token = ctx.new_inline("ref_def", line)
            out_lines.append(token)
        else:
            out_lines.append(mask_inline(line, ctx))

        # 리스트 컨텍스트 갱신 (다음 줄의 indent_code 판정에 쓰인다)
        if LIST_MARKER_RE.match(line):
            in_list = True
        elif line.strip() == "":
            pass
        elif line[:1] not in (" ", "\t"):
            in_list = False
        i += 1

    prose_text = join_lines_keep_structure(out_lines, trailing_newline)
    map_obj = {
        "version": 1,
        "profile": profile,
        "trailing_newline": trailing_newline,
        "segments": ctx.segments,
        "headings": ctx.headings,
        "structure": compute_structure(src_text),
    }
    return prose_text, map_obj


def _assert_identity(src_text: str, prose_text: str, map_obj: dict) -> None:
    """mask 직후, 산문을 무수정 restore 했을 때 원본과 완전히 같은지 자체 검증한다."""
    restored, _report = apply_restore(prose_text, map_obj, repair_headings=True)
    if restored == src_text:
        return
    a, b = src_text, restored
    minlen = min(len(a), len(b))
    offset = minlen
    for idx in range(minlen):
        if a[idx] != b[idx]:
            offset = idx
            break
    start = max(0, offset - 80)
    a_ctx = a[start : offset + 80]
    b_ctx = b[start : offset + 80]
    msg = (
        "IDENTITY 자체검증 실패 — mask 후 무수정 restore 가 원본과 다릅니다.\n"
        f"  원본 길이={len(a)}자, 복원본 길이={len(b)}자, 첫 차이 offset={offset}\n"
        f"  원본   근처: {a_ctx!r}\n"
        f"  복원본 근처: {b_ctx!r}"
    )
    raise IdentityViolation(msg)


# ---------------------------------------------------------------------------
# restore 본체
# ---------------------------------------------------------------------------


TOKEN_SHAPE_RE = re.compile(r"⟦HZ-([BI])(\d*)⟧")
TOKEN_SHAPE_LINE_RE = re.compile(r"^⟦HZ-([BI])(\d*)⟧$")


def apply_restore(prose_text: str, map_obj: dict, repair_headings: bool = True):
    """산문 + map -> 복원 텍스트. mask 의 자체검증과 restore CLI 가 공유한다.

    토큰 해석은 2단계다.
    1) 자릿수 4개가 온전한 정확한 ID 는 map 에서 그 ID 를 직접 찾아 쓴다
       (토큰 삭제·복제·순서 뒤바뀜을 verify 가 정확히 잡아낼 수 있도록,
       "표기 그대로"인 토큰은 절대 순서만으로 눙치지 않는다).
    2) ID 가 손상됐거나(자릿수가 깎였거나) map 에 없는 토큰만, 블록/인라인
       각각 원래 등장 순서 큐에서 다음 세그먼트를 꺼내 쓴다 — SKILL.md 가
       윤문 에이전트에게 요구하는 불변식이 "토큰 개수·순서·표기 유지"이지
       자릿수 하나하나의 보존이 아니기 때문에, 숫자가 깎이는 정도의 손상은
       순서 신뢰로 복원하고 나머지 진짜 구조 손상은 verify 가 잡는다.
    """
    segments = map_obj.get("segments", [])
    segments_by_id = {s["id"]: s for s in segments}
    block_queue: deque = deque(s for s in segments if not s.get("inline"))
    inline_queue: deque = deque(s for s in segments if s.get("inline"))
    lines, _prose_trailing = split_lines_keep_structure(prose_text)

    def _resolve(letter: str, digits: str):
        is_inline = letter == "I"
        queue = inline_queue if is_inline else block_queue
        if len(digits) == 4:
            cand = segments_by_id.get(f"HZ-{letter}{digits}")
            if cand is not None and bool(cand.get("inline")) == is_inline:
                try:
                    queue.remove(cand)
                except ValueError:
                    pass  # 이미 소비됐거나(중복 토큰) 큐에 없음 — positional 큐로 폴백하지 않고 그대로 채택
                return cand
        if queue:
            return queue.popleft()
        return None

    out_lines: list[str] = []
    # 각 out_lines 항목이 블록 세그먼트 치환으로 나온 줄인지 표시한다.
    # 블록(펜스·표·html_block 등) 내용은 원문 그대로 복원되므로, 그 안에 있는
    # "# 주석" 같은 줄이 HEADING_RE 에 우연히 매칭되더라도 실제 헤딩이 아니다.
    # mask 시 ctx.headings 는 블록 밖에서만 수집되므로(위 5번 분기),
    # 여기서도 블록 밖 줄만 헤딩 후보로 세야 map 의 headings 개수와 정합된다 —
    # 안 그러면 코드펜스에 '# ...' 주석이 하나만 있어도 자동복구가 통째로 무력화된다.
    block_line_flags: list[bool] = []
    skip_next_blank = False

    def _sub_inline(mo: re.Match) -> str:
        seg = _resolve(mo.group(1), mo.group(2))
        return seg["text"] if seg is not None else mo.group(0)

    for line in lines:
        stripped = line.strip()
        lm = TOKEN_SHAPE_LINE_RE.match(stripped)
        if lm and lm.group(1) == "B":
            seg = _resolve("B", lm.group(2))
            if seg is not None:
                if seg.get("pad_before") and out_lines and out_lines[-1].strip() == "":
                    out_lines.pop()
                    block_line_flags.pop()
                new_lines = seg["text"].split("\n")
                out_lines.extend(new_lines)
                block_line_flags.extend([True] * len(new_lines))
                skip_next_blank = bool(seg.get("pad_after"))
                continue
            # 대응 세그먼트를 못 찾음(큐도 비고 ID 도 없음) -> 잔존 토큰으로 남겨 verify 가 잡게 한다

        if skip_next_blank:
            skip_next_blank = False
            if line.strip() == "":
                continue

        out_lines.append(TOKEN_SHAPE_RE.sub(_sub_inline, line))
        block_line_flags.append(False)

    # 헤딩 자동복구
    report = {"heading_count_mismatch": False, "heading_repaired": False}
    if repair_headings:
        headings = map_obj.get("headings", [])
        hidx = [
            idx
            for idx, l in enumerate(out_lines)
            if not block_line_flags[idx] and HEADING_RE.match(l)
        ]
        if len(hidx) == len(headings):
            changed = False
            for idx, hinfo in zip(hidx, headings):
                if out_lines[idx] != hinfo["raw"]:
                    changed = True
                out_lines[idx] = hinfo["raw"]
            report["heading_repaired"] = changed
        elif headings:
            report["heading_count_mismatch"] = True

    restored_text = "\n".join(out_lines)
    want_trailing = bool(map_obj.get("trailing_newline"))
    if want_trailing and not restored_text.endswith("\n"):
        restored_text += "\n"
    elif not want_trailing and restored_text.endswith("\n"):
        restored_text = restored_text[:-1]

    return restored_text, report


# ---------------------------------------------------------------------------
# verify 본체
# ---------------------------------------------------------------------------

BLOCK_KINDS = {
    "frontmatter",
    "fence",
    "indent_code",
    "html_block",
    "table",
    "math_block",
    "shortcode_block",
}


def run_verify(src_text: str, restored_text: str, map_obj: dict, allow_restructure: bool) -> dict:
    fails: list[dict] = []
    warns: list[dict] = []

    def fail(check: str, detail: str) -> None:
        fails.append({"check": check, "detail": detail})

    def warn(check: str, detail: str) -> None:
        warns.append({"check": check, "detail": detail})

    # 토큰 잔존
    if CONFLICT_RE.search(restored_text):
        fail("token_residue", "복원본에 ⟦HZ- 토큰이 남아 있습니다.")

    segments = map_obj.get("segments", [])
    map_struct = map_obj.get("structure", {})
    restored_struct = compute_structure(restored_text)

    # 블록 세그먼트: 정확히 1회씩만 등장해야 한다 (0회=소실, 2회+=중복)
    block_segments = [s for s in segments if not s.get("inline")]
    for seg in block_segments:
        text = seg.get("text", "")
        if not text:
            continue
        cnt = restored_text.count(text)
        if cnt != 1:
            fail(
                f"{seg['kind']}_content",
                f"세그먼트 {seg['id']}({seg['kind']}) 가 복원본에 {cnt}회 등장합니다(기대: 1회).",
            )

    # 블록 세그먼트 등장 순서 보존
    positions = []
    all_found = True
    for seg in block_segments:
        idx = restored_text.find(seg.get("text", "")) if seg.get("text") else -1
        if idx < 0:
            all_found = False
        positions.append((idx, seg["id"]))
    if all_found and positions:
        order_now = [sid for _idx, sid in sorted(positions, key=lambda p: p[0])]
        order_expected = [seg["id"] for seg in block_segments]
        if order_now != order_expected:
            fail("block_order", f"블록 세그먼트 순서가 바뀌었습니다. 기대={order_expected} 실제={order_now}")

    # fence 개수 · info string
    if map_struct.get("fence_count") != restored_struct.get("fence_count"):
        fail(
            "fence_count",
            f"펜스 개수 불일치: 원본={map_struct.get('fence_count')} 복원본={restored_struct.get('fence_count')}",
        )
    elif map_struct.get("fence_infos") != restored_struct.get("fence_infos"):
        fail(
            "fence_info",
            f"펜스 info string 불일치: 원본={map_struct.get('fence_infos')} 복원본={restored_struct.get('fence_infos')}",
        )

    # link target 멀티셋
    from collections import Counter

    lt_orig = Counter(map_struct.get("link_targets", []))
    lt_rest = Counter(restored_struct.get("link_targets", []))
    if lt_orig != lt_rest:
        fail(
            "link_targets",
            f"링크 목적지 멀티셋 불일치. 원본에만={list((lt_orig - lt_rest).elements())}, "
            f"복원본에만={list((lt_rest - lt_orig).elements())}",
        )

    # heading_seq
    if map_struct.get("heading_seq") != restored_struct.get("heading_seq"):
        fail(
            "heading_seq",
            f"헤딩 시퀀스 불일치. 원본={map_struct.get('heading_seq')} 복원본={restored_struct.get('heading_seq')}",
        )

    # table 개수
    if map_struct.get("table_count") != restored_struct.get("table_count"):
        fail(
            "table_count",
            f"표 개수 불일치: 원본={map_struct.get('table_count')} 복원본={restored_struct.get('table_count')}",
        )

    # list_blocks
    if not allow_restructure:
        if map_struct.get("list_blocks") != restored_struct.get("list_blocks"):
            fail(
                "list_blocks",
                f"리스트 블록 구조 변화: 원본={map_struct.get('list_blocks')} 복원본={restored_struct.get('list_blocks')}",
            )

    # WARN: number_tokens 소실
    num_orig = Counter(map_struct.get("number_tokens", []))
    num_rest = Counter(restored_struct.get("number_tokens", []))
    missing = num_orig - num_rest
    if missing:
        warn("number_missing", f"원문 숫자가 복원본에서 사라졌습니다: {sorted(missing.elements())}")

    # WARN: 한글 비율 20%p 이상 변동
    def _hangul_ratio(struct: dict) -> float:
        total = struct.get("total_chars") or 0
        if total <= 0:
            return 0.0
        return (struct.get("hangul_chars") or 0) / total

    r_orig = _hangul_ratio(map_struct)
    r_rest = _hangul_ratio(restored_struct)
    if abs(r_orig - r_rest) >= 0.20:
        warn("hangul_ratio_shift", f"한글 비율 변동: 원본={r_orig:.2f} 복원본={r_rest:.2f}")

    # WARN: 문단 개수 30% 이상 변동
    p_orig = map_struct.get("paragraph_count") or 0
    p_rest = restored_struct.get("paragraph_count") or 0
    if p_orig > 0:
        change = abs(p_rest - p_orig) / p_orig
        if change >= 0.30:
            warn("paragraph_count_shift", f"문단 개수 변동 {change:.0%}: 원본={p_orig} 복원본={p_rest}")

    if fails:
        exit_code = 2
    elif warns:
        exit_code = 1
    else:
        exit_code = 0

    return {
        "ok": exit_code == 0,
        "exit": exit_code,
        "fails": fails,
        "warns": warns,
        "stats": {"map_structure": map_struct, "restored_structure": restored_struct},
    }


# ---------------------------------------------------------------------------
# CLI — mask
# ---------------------------------------------------------------------------


def cmd_mask(args: argparse.Namespace) -> int:
    src_path = Path(args.src)
    try:
        src_bytes = src_path.read_bytes()
    except OSError as e:
        print(f"오류: 원본을 읽을 수 없습니다: {e}", file=sys.stderr)
        return 3
    try:
        src_text = src_bytes.decode("utf-8")
    except UnicodeDecodeError as e:
        print(f"오류: UTF-8 디코딩 실패: {e}", file=sys.stderr)
        return 3

    try:
        prose_text, map_obj = mask_document(
            src_text, args.profile, not args.no_protect_tables, args.protect_math
        )
    except MaskConflictError as e:
        print(f"오류: {e}", file=sys.stderr)
        return 3

    map_obj["source"] = str(src_path.resolve())
    map_obj["source_sha256"] = hashlib.sha256(src_bytes).hexdigest()

    try:
        _assert_identity(src_text, prose_text, map_obj)
    except IdentityViolation as e:
        print(f"오류: {e}", file=sys.stderr)
        return 3

    out_prose = Path(args.out_prose)
    out_map = Path(args.out_map)
    try:
        out_prose.parent.mkdir(parents=True, exist_ok=True)
        out_map.parent.mkdir(parents=True, exist_ok=True)
        write_text_raw(out_prose, prose_text)
        out_map.write_text(json.dumps(map_obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    except OSError as e:
        print(f"오류: 출력 파일을 쓸 수 없습니다: {e}", file=sys.stderr)
        return 3

    kind_counts: dict[str, int] = {}
    for seg in map_obj["segments"]:
        kind_counts[seg["kind"]] = kind_counts.get(seg["kind"], 0) + 1
    struct = map_obj["structure"]
    hangul_ratio = (struct["hangul_chars"] / struct["total_chars"]) if struct["total_chars"] else 0.0

    print(f"mask: {src_path} -> {out_prose}")
    print(f"  보호 구간: " + (", ".join(f"{k}={v}" for k, v in sorted(kind_counts.items())) or "없음"))
    print(f"  헤딩 {len(map_obj['headings'])}개, 산문 {len(prose_text)}자, 한글 비율 {hangul_ratio:.1%}")

    if args.json:
        report = {
            "ok": True,
            "exit": 0,
            "kind_counts": kind_counts,
            "heading_count": len(map_obj["headings"]),
            "prose_chars": len(prose_text),
            "hangul_ratio": hangul_ratio,
        }
        print(json.dumps(report, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# CLI — restore
# ---------------------------------------------------------------------------


def cmd_restore(args: argparse.Namespace) -> int:
    prose_path = Path(args.prose)
    map_path = Path(args.map)
    try:
        prose_text = read_text_raw(prose_path)
        map_obj = json.loads(map_path.read_text(encoding="utf-8"))
    except OSError as e:
        print(f"오류: 입력을 읽을 수 없습니다: {e}", file=sys.stderr)
        return 3
    except json.JSONDecodeError as e:
        print(f"오류: map.json 파싱 실패: {e}", file=sys.stderr)
        return 3

    restored_text, report = apply_restore(
        prose_text, map_obj, repair_headings=not args.no_heading_repair
    )

    out_path = Path(args.out)
    try:
        out_path.parent.mkdir(parents=True, exist_ok=True)
        write_text_raw(out_path, restored_text)
    except OSError as e:
        print(f"오류: 출력을 쓸 수 없습니다: {e}", file=sys.stderr)
        return 3

    print(f"restore: {prose_path} -> {out_path}")
    if report["heading_count_mismatch"]:
        print("  경고: 헤딩 줄 개수가 map 과 달라 헤딩 자동복구를 건너뛰었습니다.")
    elif report["heading_repaired"]:
        print("  헤딩 자동복구가 실제로 적용됐습니다(윤문이 헤딩 텍스트를 건드렸음).")

    if args.json:
        print(json.dumps({"ok": True, "exit": 0, **report}, ensure_ascii=False))
    return 0


# ---------------------------------------------------------------------------
# CLI — verify
# ---------------------------------------------------------------------------


def cmd_verify(args: argparse.Namespace) -> int:
    try:
        src_text = read_text_raw(Path(args.src))
        restored_text = read_text_raw(Path(args.restored))
        map_obj = json.loads(Path(args.map).read_text(encoding="utf-8"))
    except OSError as e:
        print(f"오류: 입력을 읽을 수 없습니다: {e}", file=sys.stderr)
        return 3
    except json.JSONDecodeError as e:
        print(f"오류: map.json 파싱 실패: {e}", file=sys.stderr)
        return 3

    report = run_verify(src_text, restored_text, map_obj, args.allow_restructure)

    verdict = {0: "PASS", 1: "WARN", 2: "FAIL"}[report["exit"]]
    print(f"verify: {verdict} (exit {report['exit']})")
    for f in report["fails"]:
        print(f"  FAIL [{f['check']}] {f['detail']}")
    for w in report["warns"]:
        print(f"  WARN [{w['check']}] {w['detail']}")

    if args.json:
        print(json.dumps(report, ensure_ascii=False))
    return report["exit"]


# ---------------------------------------------------------------------------
# argparse
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="md_shield.py", description="humanize-docs 마크다운 마스킹/복원/검증")
    sub = p.add_subparsers(dest="command", required=True)

    pm = sub.add_parser("mask", help="마크다운을 토큰화된 산문으로 변환")
    pm.add_argument("--src", required=True)
    pm.add_argument("--out-prose", required=True)
    pm.add_argument("--out-map", required=True)
    pm.add_argument("--profile", choices=["docs", "blog"], default="docs")
    pm.add_argument("--no-protect-tables", action="store_true")
    pm.add_argument("--protect-math", action="store_true")
    pm.add_argument("--json", action="store_true")
    pm.set_defaults(func=cmd_mask)

    pr = sub.add_parser("restore", help="윤문된 산문의 토큰을 원문으로 복원")
    pr.add_argument("--prose", required=True)
    pr.add_argument("--map", required=True)
    pr.add_argument("--out", required=True)
    pr.add_argument("--no-heading-repair", action="store_true")
    pr.add_argument("--json", action="store_true")
    pr.set_defaults(func=cmd_restore)

    pv = sub.add_parser("verify", help="원본 대비 복원본의 구조 무결성 검증")
    pv.add_argument("--src", required=True)
    pv.add_argument("--restored", required=True)
    pv.add_argument("--map", required=True)
    pv.add_argument("--allow-restructure", action="store_true")
    pv.add_argument("--json", action="store_true")
    pv.set_defaults(func=cmd_verify)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:  # noqa: BLE001 — CLI 최상위: 크래시 대신 exit 3
        print(f"오류: 예기치 않은 실패: {type(e).__name__}: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
