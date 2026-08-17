#!/usr/bin/env python3
"""heading_anchor.py — humanize-docs 헤딩 슬러그 재계산 + 같은 파일 내부 앵커 재작성 + 게이트 D.

기능 A(헤딩/제목 편집) 옵션이 켜졌을 때만 쓰인다. 헤딩 텍스트가 윤문으로 바뀌면
GitHub 스타일 슬러그가 바뀌고, 같은 파일 안에서 그 헤딩을 가리키던 `[텍스트](#슬러그)`
링크가 깨진다. 이 스크립트는 그 슬러그 재계산과 링크 재작성을 LLM 없이 순수 텍스트
치환으로 수행하고(A-4), 새로 끊어진 내부 앵커가 있으면 해당 헤딩 변경만 롤백한다(A-5 게이트 D).

두 하위 명령:
    rewrite — 원본과 복원본의 헤딩을 비교해 슬러그를 재계산하고, 슬러그가 바뀐 헤딩을
              가리키던 같은 파일 내부 앵커 링크를 새 슬러그로 치환한다.
    gate    — rewrite 산출물을 원본과 대조해 같은 파일 내부 앵커가 전부 "이전에 가리키던
              것과 같은 헤딩"을 계속 가리키는지 판정한다(게이트 D). 판정은 슬러그 문자열이
              사후 문서에 "존재하는지"가 아니라 앵커가 가리키는 헤딩의 INDEX 가 편집 전후로
              같은지로 한다 — 그래야 헤딩 A 의 새 슬러그가 헤딩 B 의 옛 슬러그와 우연히
              같아져도(중복 슬러그) B 를 향하던 링크가 A 로 조용히 오배선되는 사고를
              잡아낸다. 새로 끊어지거나 오배선된 앵커가 있으면, 그 앵커가 "원래" 가리키던
              헤딩 하나만 원문으로 롤백하고 그 발생(occurrence) 하나만 옛 슬러그로 되돌린다
              — 문서 전체에서 같은 글자열을 찾아 치환하지 않는다(그러면 우연히 같은 문자열을
              쓰는 무관한 다른 헤딩의 정상 링크까지 건드릴 수 있다). 롤백을 전부 적용한
              뒤에는 결과 문서 전체를 처음부터 다시 스캔해 재검증한다 — 롤백 자체가
              부작용을 냈을 수 있기 때문이다: (a) 같은 헤딩을 가리키던 다른 링크가 원래는
              멀쩡했는데 헤딩 텍스트가 되돌아가면서 함께 깨질 수 있고("부작용 파손"),
              (b) 헤딩 B 의 새 슬러그가 헤딩 A 의 옛 슬러그와 충돌해서 생긴 오배선처럼,
              B 의 텍스트를 되돌려도(원래 안 바뀌었으므로 되돌릴 게 없다) 아무것도
              고쳐지지 않는 "무효 롤백"도 있을 수 있다. 재검증에서 확인된 진짜 remediation
              만 rolled_back_headings 에 남고, 나머지는 unremediated 로 따로 보고한다
              (rolled_back_headings 와 unremediated 는 서로 배타적이지 않다 — 같은 게이트
              호출 안에서 어떤 헤딩은 자기 트리거를 실제로 고쳤으면서 동시에 다른 링크를
              부작용으로 깨뜨릴 수 있다).

exit code: 0=통과(안전하게 그대로 채택), 1=경고(원래도 깨져 있던 링크 — 진행하되 고지),
           2=**채택 금지**(새로 끊어졌거나 다른 헤딩으로 오배선된 앵커가 있었다는 뜻 —
           이 스킬의 게이트 A/B/C 와 동일한 의미다. --out 에는 시도한 롤백까지 반영된
           파일이 쓰여 있지만, 그 롤백이 실제로 문제를 다 해결했다는 보장은 아니다.
           JSON 의 rolled_back_headings 는 재검증까지 통과해 "실제로 고쳐졌다"고 확인된
           헤딩만 담고, 롤백을 시도했지만 여전히 깨져 있거나(원래 트리거였든, 같은
           헤딩을 가리키던 다른 링크가 롤백의 부작용으로 새로 깨졌든) 롤백이 아무
           효과도 없었던 항목은 unremediated 에 담는다 — exit 2 를 받으면 unremediated 가
           비어 있는지부터 확인하고, 비어 있지 않으면 사람이 봐야 한다),
           3=IO/헤딩 개수 불일치/같은 파일 내부 앵커 개수 불일치 오류. (참고: argparse
           자체의 사용법 오류 — 필수 인자 누락, 잘못된 서브커맨드 등 — 은 이 스크립트가
           아니라 argparse 가 직접 처리하며 관례상 exit 2 를 낸다. 이건 이 스크립트의
           명시적 반환값이 아니다.)

구현 제약:
    - Python 3.9+, 표준 라이브러리만 사용.
    - md_shield.py 를 임포트하지 않는다(스크립트 자기완결 원칙, 각 스크립트 독립).
      HEADING_RE 등 정규식·looks_like_indent_code·match_inline_code 는 md_shield.py 와
      동일한 알고리즘을 자체 함수로 다시 선언한다(포팅, 임포트 아님).
    - 헤딩·같은 파일 내부 앵커 스캔에서 다음은 전부 제외한다(코드가 아니라 관례를
      다시 구현):
        * 코드펜스(```/~~~) 안의 줄.
        * 리스트 컨텍스트 밖에서, 직전이 빈 줄이거나 문서 시작인 4칸(또는 탭) 들여쓰기
          코드 블록(md_shield.py 의 looks_like_indent_code 판정과 동일 조건).
        * 같은 줄 안의 인라인 코드 스팬(백틱) 내부.
      헤딩 파싱은 줄 단위 상태 머신이며 정규식 하나로 문서 전체를 파싱하지 않는다.
    - 슬러그는 GitHub 스타일 근사치: 소문자화 → 단어문자(유니코드 포함)·하이픈·공백만
      남기고 나머지 구두점 제거 → 공백은 "한 글자씩" 하이픈으로(연속 공백을 한 하이픈으로
      뭉개지 않는다 — 구두점 제거로 생긴 이중 공백은 이중 하이픈이 된다) → 문서 내 중복은
      끝까지 유일해질 때까지 -1, -2… 접미사를 늘려가며 등록.
    - UTF-8 BOM 이 파일 첫 줄 앞에 있으면 스캔 전에 항상 벗겨낸다 — rewrite/gate 의 --out
      은 입력에 BOM 이 있었든 없었든, 이번에 실제로 뭔가 바뀌었든 아니든 관계없이 BOM
      없이 쓰인다(롤백이 첫 줄을 건드릴 때만 사라지는 게 아니라 무조건 사라진다 — 사소한
      트레이드오프로 감수한다. BOM 을 그대로 보존해야 한다면 이 스크립트를 쓰기 전에
      별도로 처리할 것).
    - 알려진 스코프 한계(고치지 않음, 여기 문서화만 한다):
        * Setext 스타일 헤딩(밑줄 `===`/`---`)은 인식하지 않는다 — ATX(`#`)만 인식한다.
          GitHub 은 setext 헤딩에도 앵커를 만들므로, 그런 헤딩을 가리키는 멀쩡한 링크가
          "이미 깨져 있다"로 오판될 수 있다.
        * 참조 스타일 링크 정의(`[id]: #frag`)와 raw `<a href="#frag">` 는 스캔 범위 밖이다
          (SAME_FILE_ANCHOR_RE 는 인라인 `[텍스트](#frag)` 형태만 잡는다).
        * 원래부터 깨져 있던 링크(warn 대상)가 편집 후 우연히 유효한 헤딩을 가리키게
          되는 경우는 조용히 통과시킨다 — 정답이 뭔지 판단할 근거가 없고(우연인지 의도한
          수정인지 구분 불가), 틀린 방향의 판정(경고 없이 지나침)은 채택을 막지 않으므로
          보고 공백으로만 남겨둔다. 정정도 이쪽으로는 하지 않는다.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# 파일 I/O — md_shield.py 와 동일하게 개행 무변형 읽기/쓰기
# ---------------------------------------------------------------------------


def read_text_raw(path: Path) -> str:
    return path.read_bytes().decode("utf-8")


def write_text_raw(path: Path, text: str) -> None:
    path.write_bytes(text.encode("utf-8"))


# ---------------------------------------------------------------------------
# 공통 정규식 — md_shield.py 의 HEADING_RE/FENCE_OPEN_RE/LIST_MARKER_RE 와 동일 패턴
# ---------------------------------------------------------------------------

HEADING_RE = re.compile(r"^ {0,3}(#{1,6})(?:\s+(.*))?$")
FENCE_OPEN_RE = re.compile(r"^[ \t]*(`{3,}|~{3,})(.*)$")
LIST_MARKER_RE = re.compile(r"^ {0,3}([-*+]|\d{0,9}[.)])(?:\s+|$)")
# ](#fragment) 또는 ](#fragment "제목") 형태의 같은 파일 내부 앵커 링크.
# fragment 는 공백·`)`·`"` 를 만나면 끝난다.
SAME_FILE_ANCHOR_RE = re.compile(r"\]\(#([^)\s\"]+)(?:\s+\"[^\"]*\")?\)")

BOM = "﻿"


def _strip_bom(text: str) -> str:
    return text[len(BOM):] if text.startswith(BOM) else text


# ---------------------------------------------------------------------------
# 줄 단위 스캔 상태 머신 — 다음 줄은 헤딩·앵커 스캔에서 제외한다(protected=True):
#   (a) 코드펜스 안,
#   (b) 리스트 컨텍스트 밖에서 직전이 빈 줄/문서 시작인 들여쓰기 코드 블록.
# (md_shield.py 의 mask_document 7번 케이스와 동일 조건 — 자기완결을 위해 재구현)
# ---------------------------------------------------------------------------


def looks_like_indent_code(line: str) -> bool:
    """md_shield.py 와 동일한 판정 — 4칸/탭 들여쓰기이고 빈 줄이 아니다."""
    return (line.startswith("    ") or line.startswith("\t")) and line.strip() != ""


def iter_lines_with_fence_state(text: str):
    """(line, protected) 쌍을 문서 순서대로 낸다. protected=True 인 줄은 헤딩·앵커
    스캔에서 제외한다(펜스 여는/닫는 줄 자체도 포함, 들여쓰기 코드 블록도 포함)."""
    text = _strip_bom(text)
    lines = text.split("\n")
    n = len(lines)
    in_fence = False
    fence_char = ""
    fence_len = 0
    in_list = False
    prev_blank = True  # 문서 시작은 "직전이 빈 줄"과 동치로 취급
    i = 0
    while i < n:
        line = lines[i]

        if in_fence:
            yield line, True
            stripped = line.strip()
            if len(stripped) >= fence_len and set(stripped) == {fence_char}:
                in_fence = False
            prev_blank = line.strip() == ""
            i += 1
            continue

        m = FENCE_OPEN_RE.match(line)
        if m:
            fence_char = m.group(1)[0]
            fence_len = len(m.group(1))
            in_fence = True
            yield line, True
            prev_blank = False
            i += 1
            continue

        if not in_list and looks_like_indent_code(line) and prev_blank:
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
            for k in range(i, last_content):
                yield lines[k], True
            i = last_content
            continue

        yield line, False

        if LIST_MARKER_RE.match(line):
            in_list = True
        elif line.strip() == "":
            pass
        elif line[:1] not in (" ", "\t"):
            in_list = False

        prev_blank = line.strip() == ""
        i += 1


def _heading_text(raw: str) -> tuple[int, str]:
    m = HEADING_RE.match(raw)
    if m is None:
        raise ValueError(f"HEADING_RE 매치 실패 — 호출부에서 이미 매치된 줄만 넘겨야 합니다: {raw!r}")
    level = len(m.group(1))
    text = (m.group(2) or "")
    text = re.sub(r"\s+#+\s*$", "", text).strip()
    return level, text


def extract_headings(text: str) -> list[dict]:
    """스캔에서 제외되지 않는 헤딩 줄만 문서 순서대로 뽑는다.
    각 항목: index/level/raw/text/line_index(BOM 벗긴 텍스트 기준 물리 줄 번호)."""
    headings: list[dict] = []
    for line_index, (line, protected) in enumerate(iter_lines_with_fence_state(text)):
        if protected:
            continue
        if HEADING_RE.match(line):
            level, htext = _heading_text(line)
            headings.append(
                {
                    "index": len(headings),
                    "level": level,
                    "raw": line,
                    "text": htext,
                    "line_index": line_index,
                }
            )
    return headings


# ---------------------------------------------------------------------------
# 인라인 코드 스팬(백틱) 탐지 — md_shield.py 의 match_inline_code 와 동일 알고리즘.
# 같은 파일 내부 앵커가 백틱 안(예: `` `[텍스트](#frag)` ``)에 있으면 진짜 링크가
# 아니므로 스캔·치환 대상에서 뺀다.
# ---------------------------------------------------------------------------


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
            m = 0
            while k < length and line[k] == "`":
                m += 1
                k += 1
            if m == n:
                return k
        else:
            k += 1
    return None


def inline_code_spans(line: str) -> list[tuple[int, int]]:
    """줄 안의 인라인 코드 스팬 [시작, 끝) 범위 목록을 문서(줄 내) 순서대로 낸다."""
    spans: list[tuple[int, int]] = []
    i = 0
    n = len(line)
    while i < n:
        if line[i] == "`":
            j = i
            while j < n and line[j] == "`":
                j += 1
            end = match_inline_code(line, i)
            if end is not None:
                spans.append((i, end))
                i = end
                continue
            i = j  # 짝이 안 맞는 백틱 런은 건너뛰고 나머지 줄은 계속 스캔한다.
        else:
            i += 1
    return spans


def _pos_in_spans(pos: int, spans: list[tuple[int, int]]) -> bool:
    return any(s <= pos < e for s, e in spans)


def extract_same_file_target_occurrences(text: str) -> list[dict]:
    """펜스·들여쓰기 코드·인라인 코드 스팬 밖에서 `[텍스트](#frag)` 앵커의 발생을
    문서 순서대로 뽑는다. 각 항목: line_index/frag_start/frag_end/frag.
    frag_start/frag_end 는 그 줄 문자열 안에서 frag 부분만의 [시작, 끝) 범위다
    (게이트 롤백이 이 좌표로 "그 발생 하나만" 정확히 되돌린다 — 문서 전체 치환 금지)."""
    occurrences: list[dict] = []
    for line_index, (line, protected) in enumerate(iter_lines_with_fence_state(text)):
        if protected:
            continue
        spans = inline_code_spans(line)
        for m in SAME_FILE_ANCHOR_RE.finditer(line):
            if _pos_in_spans(m.start(), spans):
                continue
            occurrences.append(
                {
                    "line_index": line_index,
                    "frag_start": m.start(1),
                    "frag_end": m.end(1),
                    "frag": m.group(1),
                }
            )
    return occurrences


def extract_same_file_targets(text: str) -> list[str]:
    """extract_same_file_target_occurrences 의 frag 만 문서 순서대로 뽑는다."""
    return [o["frag"] for o in extract_same_file_target_occurrences(text)]


# ---------------------------------------------------------------------------
# GitHub 스타일 슬러그 계산
# ---------------------------------------------------------------------------

_SLUG_STRIP_RE = re.compile(r"[^\w\s-]", re.UNICODE)
# 공백 "런"을 하나로 뭉개지 않는다 — 구두점(이모지·em dash·middot 등) 제거로 생긴
# 이중 공백은 GitHub 처럼 이중 하이픈이 되어야 한다(C1). 그래서 `+` 없이 한 글자씩 치환한다.
_SLUG_WS_RE = re.compile(r"\s")


def slugify(text: str) -> str:
    """GitHub 스타일 슬러그 근사치. 단어문자(유니코드 포함)·하이픈·공백만 남기고
    나머지 구두점을 제거한 뒤, 소문자화하고 공백 문자를 하나씩 하이픈으로 바꾼다."""
    s = text.strip().lower()
    s = _SLUG_STRIP_RE.sub("", s)
    s = _SLUG_WS_RE.sub("-", s)
    return s


def slugify_all(texts: list[str]) -> list[str]:
    """문서 순서대로 슬러그를 계산한다. 중복은 실제로 비어 있는 접미사를 찾을 때까지
    -1, -2… 를 늘려가며 붙이고, 만들어진 모든 슬러그를 등록해 최종 목록이 항상
    전역적으로 유일하도록 보장한다(I2 — 이전 구현은 베이스 슬러그만 등록해서
    ["Foo","Foo","Foo 1"] 같은 입력에서 최종 슬러그가 중복될 수 있었다)."""
    seen: set[str] = set()
    out: list[str] = []
    for t in texts:
        base = slugify(t)
        candidate = base
        n = 0
        while candidate in seen:
            n += 1
            candidate = f"{base}-{n}"
        seen.add(candidate)
        out.append(candidate)
    return out


# ---------------------------------------------------------------------------
# rewrite — 슬러그 재계산 + 같은 파일 내부 앵커 치환(문서 전체 매핑 치환 — 안전한
# 이유: slugify_all 이 이제 전역 유일성을 보장하므로 before_slug 하나는 항상
# 정확히 하나의 헤딩만을 가리킨다).
# ---------------------------------------------------------------------------


def compute_renames(
    before_texts: list[str], after_texts: list[str], before_slugs: list[str], after_slugs: list[str]
) -> dict:
    """before_slug -> after_slug 매핑. 텍스트가 바뀌어 슬러그도 바뀐 헤딩만 담는다."""
    renames: dict[str, str] = {}
    for i in range(len(before_texts)):
        if before_texts[i] != after_texts[i] and before_slugs[i] != after_slugs[i]:
            renames[before_slugs[i]] = after_slugs[i]
    return renames


def _replace_anchor_frags_in_line(line: str, renames: dict) -> tuple[str, int]:
    """줄 안의 SAME_FILE_ANCHOR_RE 매치 중 renames 에 있는 frag 만 치환한다.
    인라인 코드 스팬 안의 매치는 건드리지 않는다(I1). (치환된 줄, 치환 건수)."""
    spans = inline_code_spans(line)
    count = 0

    def _sub(m: re.Match) -> str:
        nonlocal count
        if _pos_in_spans(m.start(), spans):
            return m.group(0)
        frag = m.group(1)
        if frag not in renames:
            return m.group(0)
        count += 1
        rest = m.group(0)[len(frag) + 3 :]  # "](#" + frag 이후 나머지(")" 또는 ' "제목")')
        return f"](#{renames[frag]}{rest}"

    return SAME_FILE_ANCHOR_RE.sub(_sub, line), count


def rewrite_same_file_anchors(text: str, renames: dict) -> tuple[str, int]:
    """renames 에 있는 frag 만 치환한다. 펜스·들여쓰기 코드·인라인 코드 스팬은 건드리지
    않는다. (치환된 텍스트, 치환 건수)."""
    if not renames:
        return _strip_bom(text), 0
    count = 0
    out_lines: list[str] = []
    for line, protected in iter_lines_with_fence_state(text):
        if protected:
            out_lines.append(line)
            continue
        new_line, n = _replace_anchor_frags_in_line(line, renames)
        count += n
        out_lines.append(new_line)
    return "\n".join(out_lines), count


def cmd_rewrite(args: argparse.Namespace) -> int:
    try:
        src_text = read_text_raw(Path(args.src))
        restored_text = read_text_raw(Path(args.restored))
    except OSError as e:
        print(f"오류: 파일을 읽을 수 없습니다: {e}", file=sys.stderr)
        return 3

    src_headings = extract_headings(src_text)
    restored_headings = extract_headings(restored_text)

    if len(src_headings) != len(restored_headings):
        print(
            f"오류: 헤딩 개수 불일치 (원본 {len(src_headings)} vs 복원본 {len(restored_headings)}). "
            "구조가 정상 복원된 입력만 받는다.",
            file=sys.stderr,
        )
        return 3

    before_texts = [h["text"] for h in src_headings]
    after_texts = [h["text"] for h in restored_headings]
    before_slugs = slugify_all(before_texts)
    after_slugs = slugify_all(after_texts)
    renames = compute_renames(before_texts, after_texts, before_slugs, after_slugs)
    out_text, rewritten_count = rewrite_same_file_anchors(restored_text, renames)

    try:
        write_text_raw(Path(args.out), out_text)
    except OSError as e:
        print(f"오류: 출력 파일을 쓸 수 없습니다: {e}", file=sys.stderr)
        return 3

    # M1: renamed_report 는 실제 치환 대상(compute_renames)과 같은 조건으로 걸러야
    # "텍스트는 안 바뀌었는데 다른 헤딩의 dedup 때문에 슬러그만 밀린" 항목이
    # links_rewritten 과 안 맞게 과다 보고되는 걸 막는다.
    renamed_report = [
        {
            "index": i,
            "level": src_headings[i]["level"],
            "before_text": before_texts[i],
            "after_text": after_texts[i],
            "before_slug": before_slugs[i],
            "after_slug": after_slugs[i],
        }
        for i in range(len(src_headings))
        if before_texts[i] != after_texts[i] and before_slugs[i] != after_slugs[i]
    ]

    print(f"rewrite: 헤딩 {len(src_headings)}개 중 슬러그 변경 {len(renamed_report)}건, 링크 치환 {rewritten_count}건")
    for r in renamed_report:
        print(f"  #{r['before_slug']} -> #{r['after_slug']}  ({r['before_text']!r} -> {r['after_text']!r})")

    if args.json:
        report = {
            "renamed": renamed_report,
            "links_rewritten": rewritten_count,
            "out": str(args.out),
        }
        print(json.dumps(report, ensure_ascii=False))

    return 0


# ---------------------------------------------------------------------------
# gate — 게이트 D: 같은 파일 내부 앵커가 "이전과 같은 헤딩 INDEX" 를 계속 가리키는지
# 판정하고, 필요 시 발생(occurrence) 단위로만 롤백한다.
# ---------------------------------------------------------------------------


def cmd_gate(args: argparse.Namespace) -> int:
    try:
        src_text = read_text_raw(Path(args.src))
        cand_text = read_text_raw(Path(args.candidate))
    except OSError as e:
        print(f"오류: 파일을 읽을 수 없습니다: {e}", file=sys.stderr)
        return 3

    src_headings = extract_headings(src_text)
    cand_headings = extract_headings(cand_text)

    if len(src_headings) != len(cand_headings):
        print(
            f"오류: 헤딩 개수 불일치 (원본 {len(src_headings)} vs 후보 {len(cand_headings)}).",
            file=sys.stderr,
        )
        return 3

    before_texts = [h["text"] for h in src_headings]
    after_texts = [h["text"] for h in cand_headings]
    before_slugs = slugify_all(before_texts)
    after_slugs = slugify_all(after_texts)
    # I2 로 slugify_all 이 전역 유일성을 보장하므로 이 두 매핑은 안전한 전단사다.
    before_slug_to_index = {s: i for i, s in enumerate(before_slugs)}
    after_slug_to_index = {s: i for i, s in enumerate(after_slugs)}

    orig_links = extract_same_file_targets(src_text)
    cand_occurrences = extract_same_file_target_occurrences(cand_text)

    out_lines = _strip_bom(cand_text).split("\n")

    if len(orig_links) != len(cand_occurrences):
        # I3: 링크 개수가 안 맞으면 발생 위치를 원본과 안전하게 1:1 대응시킬 수 없어
        # 검증 자체를 포기한다. 그렇다고 후보 파일을 날리지는 않는다 — 그대로 --out 에
        # 써서 데이터 손실을 막는다(이전 구현은 여기서 --out 을 아예 쓰지 않고 종료했다).
        out_text = "\n".join(out_lines)
        try:
            write_text_raw(Path(args.out), out_text)
        except OSError as e:
            print(f"오류: 출력 파일을 쓸 수 없습니다: {e}", file=sys.stderr)
            return 3
        print(
            f"오류: 같은 파일 내부 앵커 링크 개수 불일치 (원본 {len(orig_links)} vs 후보 "
            f"{len(cand_occurrences)}) — 발생 위치를 대응시킬 수 없어 검증을 포기한다. "
            "후보 파일은 변경 없이 --out 에 보존했다.",
            file=sys.stderr,
        )
        if args.json:
            report = {
                "gate": "D",
                "exit": 3,
                "error": "link_count_mismatch",
                "warn": [],
                "fail": [],
                "rolled_back_headings": [],
                "unremediated": [],
                "out": str(args.out),
            }
            print(json.dumps(report, ensure_ascii=False))
        return 3

    warns: list[dict] = []
    fails: list[dict] = []
    rollback_heading_indices: set[int] = set()
    occurrences_to_revert: list[tuple[dict, str]] = []
    # R1/R2 재검증에서 "이 발생이 원래(1차 판정에서) 실패로 잡혔던 자리인지" 를
    # 구분해야 한다 — 같은 헤딩을 가리키는 다른(1차 판정 때는 멀쩡했던) 발생이
    # 롤백의 부작용으로 새로 깨진 경우와 구분하기 위해서다(zip 순서상의 위치로 식별).
    failed_positions: set[int] = set()

    for pos, (occ, orig_frag) in enumerate(zip(cand_occurrences, orig_links)):
        cand_frag = occ["frag"]
        orig_idx = before_slug_to_index.get(orig_frag)
        cand_idx = after_slug_to_index.get(cand_frag)

        if orig_idx is None:
            # 원본에서부터 이미 깨져 있던 링크. 편집 후에도 여전히 유효한 헤딩을 못
            # 찾으면 경고만 하고 진행한다. 우연히 유효해졌다면 그냥 둔다.
            if cand_idx is None:
                warns.append({"target": cand_frag, "was": orig_frag})
            continue

        if cand_idx == orig_idx:
            # 슬러그 문자열이 바뀌었든 아니든, 여전히 "같은 헤딩" 을 가리킨다 — 통과.
            continue

        # C2/C3: cand_idx 가 None(더 이상 어떤 헤딩과도 안 맞음)이거나, orig_idx 와
        # 다른 헤딩을 가리키게 됐다(다른 헤딩이 우연히 같은 슬러그를 갖게 된 오배선).
        # 어느 쪽이든 "원래 이 링크가 가리키던 헤딩"(orig_idx) 기준으로 실패 처리한다
        # — 지금 그 슬러그를 우연히 차지한 다른 헤딩을 롤백 대상으로 잘못 짚지 않는다.
        fails.append({"target": cand_frag, "was": orig_frag, "heading_index": orig_idx})
        rollback_heading_indices.add(orig_idx)
        occurrences_to_revert.append((occ, before_slugs[orig_idx]))
        failed_positions.add(pos)

    rollback_heading_lines: set[int] = set()
    for idx in sorted(rollback_heading_indices):
        line_idx = cand_headings[idx]["line_index"]
        rollback_heading_lines.add(line_idx)
        out_lines[line_idx] = src_headings[idx]["raw"]

    # C4: 문서 전체에서 같은 프래그먼트 문자열을 찾아 치환하지 않는다 — 깨진
    # 발생(occurrence) 하나만, 기록해 둔 정확한 좌표로 되돌린다. 같은 줄에 되돌릴
    # 발생이 여럿이면 뒤(오른쪽)에서부터 적용해 앞쪽 오프셋이 밀리지 않게 한다.
    by_line: dict[int, list[tuple[dict, str]]] = {}
    for occ, before_frag in occurrences_to_revert:
        if occ["line_index"] in rollback_heading_lines:
            # 이 줄은 헤딩 자체가 통째로 원문으로 되돌아갔다(위) — 이미 해결됨.
            continue
        by_line.setdefault(occ["line_index"], []).append((occ, before_frag))
    for line_idx, items in by_line.items():
        items.sort(key=lambda pair: pair[0]["frag_start"], reverse=True)
        line = out_lines[line_idx]
        for occ, before_frag in items:
            line = line[: occ["frag_start"]] + before_frag + line[occ["frag_end"] :]
        out_lines[line_idx] = line

    out_text = "\n".join(out_lines)

    # R1/R2: 롤백을 전부 적용한 뒤, 결과 문서를 처음부터 다시 스캔해 재검증한다.
    # "이 헤딩을 위해 롤백했다" 는 사실만으로 rolled_back_headings 에 넣지 않는다 —
    # (a) 롤백이 자기 트리거조차 못 고쳤으면(R2, 무효 롤백) 그 헤딩은 unremediated 로
    #     보내고 rolled_back_headings 에서 뺀다.
    # (b) 롤백 대상이 아니었던 다른 발생이 이 롤백 때문에 새로 깨졌으면(R1, 부작용
    #     파손) 그 헤딩의 remediation 여부와 무관하게 그 발생을 unremediated 에 추가한다.
    rolled_back: list[dict] = []
    unremediated: list[dict] = []
    if rollback_heading_indices:
        final_headings = extract_headings(out_text)
        final_slugs = slugify_all([h["text"] for h in final_headings])
        final_slug_to_index = {s: i for i, s in enumerate(final_slugs)}
        final_occurrences = extract_same_file_target_occurrences(out_text)

        trigger_ok = {idx: True for idx in rollback_heading_indices}

        if len(final_occurrences) == len(orig_links):
            for pos, (occ, orig_frag) in enumerate(zip(final_occurrences, orig_links)):
                orig_idx = before_slug_to_index.get(orig_frag)
                if orig_idx is None:
                    continue  # 원래부터 깨져 있던 링크 — 재검증 대상 아님(경고만 대상).
                final_idx = final_slug_to_index.get(occ["frag"])
                if final_idx == orig_idx:
                    continue  # 롤백 후에도 여전히 올바른 헤딩을 가리킨다 — 이상 없음.
                reason = "still_broken" if pos in failed_positions else "collateral_break"
                if reason == "still_broken":
                    # 이 발생 자체가 롤백의 트리거였는데 롤백 후에도 안 고쳐졌다(R2).
                    trigger_ok[orig_idx] = False
                unremediated.append({"target": occ["frag"], "heading_index": orig_idx, "reason": reason})
        else:
            # 재검증 시점에 발생 개수가 달라졌다면(있어서는 안 되지만) 안전 쪽으로
            # 이번 게이트 호출의 모든 롤백을 미확인 처리한다.
            for idx in sorted(rollback_heading_indices):
                trigger_ok[idx] = False
                unremediated.append({"heading_index": idx, "reason": "revalidation_count_mismatch"})

        for idx in sorted(rollback_heading_indices):
            if trigger_ok.get(idx, True):
                rolled_back.append(
                    {
                        "index": idx,
                        "before_text": src_headings[idx]["text"],
                        "after_text": cand_headings[idx]["text"],
                    }
                )

    if fails:
        # R3: exit 2 는 이 스킬의 게이트 A/B/C 와 동일하게 "채택 금지" 를 뜻한다 —
        # 재검증에서 전부 remediated 로 확인됐어도(unremediated 가 비어 있어도) 그대로
        # 2 를 유지한다. 롤백이 필요했다는 사실 자체가 사람 검토 없이 그냥 채택하면
        # 안 된다는 신호이기 때문이다(다른 세 게이트와 같은 정책).
        exit_code = 2
    elif warns:
        exit_code = 1
    else:
        exit_code = 0

    try:
        write_text_raw(Path(args.out), out_text)
    except OSError as e:
        print(f"오류: 출력 파일을 쓸 수 없습니다: {e}", file=sys.stderr)
        return 3

    verdict = {0: "PASS", 1: "WARN", 2: "FAIL"}[exit_code]
    print(f"gate D: {verdict} (exit {exit_code})")
    for w in warns:
        print(f"  WARN: #{w['target']} — 원래도 깨져 있던 링크(수정 이전부터 매칭 헤딩 없음)")
    for f in fails:
        print(
            f"  FAIL: #{f['target']} — 헤딩 #{f['heading_index']} 이 가리키던 대상이 깨지거나"
            " 다른 헤딩으로 바뀜, 해당 헤딩 롤백 시도함"
        )
    for u in unremediated:
        target = u.get("target", "?")
        print(f"  UNREMEDIATED: #{target} — 롤백 시도에도 해결되지 않음 (reason={u['reason']})")

    if args.json:
        report = {
            "gate": "D",
            "exit": exit_code,
            "warn": warns,
            "fail": fails,
            "rolled_back_headings": rolled_back,
            "unremediated": unremediated,
            "out": str(args.out),
        }
        print(json.dumps(report, ensure_ascii=False))

    return exit_code


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="heading_anchor.py",
        description="humanize-docs 헤딩 슬러그 재계산 · 같은 파일 내부 앵커 치환 · 게이트 D",
    )
    sub = p.add_subparsers(dest="command", required=True)

    pr = sub.add_parser("rewrite", help="슬러그 재계산 + 같은 파일 내부 앵커 치환")
    pr.add_argument("--src", required=True, help="원본 .md (윤문 이전)")
    pr.add_argument("--restored", required=True, help="복원된 .md (--no-heading-repair 로 복원, 헤딩 텍스트가 바뀌어 있을 수 있음)")
    pr.add_argument("--out", required=True, help="앵커 치환 결과를 쓸 경로")
    pr.add_argument("--json", action="store_true")
    pr.set_defaults(func=cmd_rewrite)

    pg = sub.add_parser("gate", help="게이트 D — 같은 파일 내부 앵커 무결성 판정 + 필요 시 헤딩 단위 롤백")
    pg.add_argument("--src", required=True, help="원본 .md (윤문 이전)")
    pg.add_argument("--candidate", required=True, help="rewrite 의 --out 산출물")
    pg.add_argument("--out", required=True, help="게이트 판정(및 롤백 반영) 후 최종 결과를 쓸 경로")
    pg.add_argument("--json", action="store_true")
    pg.set_defaults(func=cmd_gate)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except Exception as e:  # noqa: BLE001 — CLI 최상위 안전망
        print(f"오류: 예기치 않은 실패: {type(e).__name__}: {e}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    sys.exit(main())
