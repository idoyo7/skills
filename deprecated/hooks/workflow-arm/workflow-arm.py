#!/usr/bin/env python3
"""PreToolUse 훅: 큰 Workflow 실행 전에 재개 예약(freeze arm)부터 걸게 강제한다.

배경 — 5시간 한도에 막히는 순간에는 handoff를 쓸 토큰조차 남지 않을 수 있다.
그래서 워크플로우를 실제로 돌리기 전, 미리 예약을 걸어두는 것만이 유일한
안전장치다. 이 훅은 그 순서를 강제한다: 예약 없이 Workflow 실행을 부르면
한 번 막고 예약 절차를 안내한다.

stdin  (JSON): { session_id, cwd, tool_name, tool_input, hook_event_name, ... }
stdout (JSON): { "hookSpecificOutput": {...} }  — deny 할 때만 출력
stderr       : 내부 오류 시 한 줄, exit 0
exit code    : 항상 0  (훅 때문에 작업이 멈추는 사고는 없어야 한다)
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# constants
# ---------------------------------------------------------------------------

# freeze.sh / thaw.sh 가 reservation.json에 실제로 쓰는 status 값 중 종료 상태.
# (freeze/scripts/freeze.sh, thaw.sh 를 읽고 확인함 — 추측 아님)
_TERMINAL_STATUSES = {"cancelled", "completed_early", "probe_failed", "done", "failed", "ambiguous"}

# tool_input에 이 중 하나라도 있으면 "실행" 호출로 본다. runId만 있으면 조회·제어 호출.
_EXEC_KEYS = ("script", "scriptPath", "name")

# 서브에이전트 규모 추정 — agent( 호출 개수를 센다. 임계값은 환경변수로 오버라이드.
_AGENT_CALL_RE = re.compile(r"\bagent\s*\(")

# agent 라는 단어 자체(호출 형태와 무관). point-free 로 함수 참조만 넘기는 형태
# (`specs.map(agent)`)는 _AGENT_CALL_RE 에 안 걸리지만 이걸로는 걸린다 — 이 둘의
# 매치 수가 다르면(참조가 호출보다 많으면) "agent( 호출로 안 셈"이라는 사고가 나므로
# 무조건 셀 수 없음으로 막는다.
_AGENT_REF_RE = re.compile(r"\bagent\b")

# parallel/pipeline 은 Workflow 툴의 표준 API라 대부분의 스크립트가 쓴다 — 무조건
# 팬아웃으로 보고 막으면 "작은 워크플로우는 통과시킨다"는 취지가 사라진다. 그래서 이
# 호출들과 .map/.forEach/.flatMap 은 팬아웃 "대상"(정적 배열 리터럴이나 const/let/var로
# 선언된 배열 식별자)의 크기를 셀 수 있으면 그 크기로 추정하고, 못 세면(속성 접근·함수
# 호출 결과 등) 그때만 막는다.
_METHOD_FANOUT_RE = re.compile(r"\.\s*(?:map|forEach|flatMap)\s*\(")
_CALL_FANOUT_RE = re.compile(r"\b(?:parallel|pipeline)\s*\(")

# 루프는 반복 횟수를 정적으로 알 방법이 없다 — 무조건 팬아웃 불명으로 막는다.
_LOOP_RE = re.compile(r"\bfor\s*\(|\bfor\s+await\b|\bwhile\s*\(")

# 이 마커들 위에서 벌어지는 팬아웃은 이 파일의 정적 판정 범위 밖이다 — 몇 개가 되는지
# 셀 방법이 없으므로(런타임 값, 누산기 등) 루프와 똑같이 무조건 막는다.
# Array.from({length:N}, ...), new Array(N).fill(...), X.reduce(...),
# Promise.all([...]), Promise.allSettled([...]) 전부 해당.
_UNCOUNTABLE_FANOUT_RE = re.compile(
    r"\bArray\s*\.\s*from\s*\(|\bnew\s+Array\s*\(|\.\s*fill\s*\(|\.\s*reduce\s*\("
    r"|\bPromise\s*\.\s*all\s*\(|\bPromise\s*\.\s*allSettled\s*\("
)

# const/let/var NAME = [ 형태로 선언된 배열의 이름을 찾는다. '[' 위치는 이 매치의
# 끝(-1)이다.
_NAMED_ARRAY_RE = re.compile(r"\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*\[")

# 선언 시점 크기를 더 이상 못 믿게 만드는 변형 메서드 — 재대입은 별도로 검사한다.
_ARRAY_MUTATION_METHODS = ("push", "concat", "splice", "unshift")

# 식별자를 이루는 문자 집합 — JS 규칙과 동일(글자·숫자·_·$).
_IDENT_CHARS = frozenset(
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_$"
)

_AGENT_THRESHOLD_DEFAULT = 10

# .claude/workflows/<name> 을 찾을 때 시도하는 확장자 순서.
_WORKFLOW_EXTS = (".js", ".mjs", ".ts")

# 세션 마커 정리 기준 — 이보다 오래된 마커는 다음 호출 때 지운다.
_MARKER_MAX_AGE = 7 * 24 * 3600

# 스테일 판정 유예 — thaw.sh 의 프로브 재시도가 기본 900s * 12회 = 3시간까지 걸릴 수
# 있고 그 구간 내내 status 는 "frozen" 그대로다. resume_at 을 넘겼다고 바로 죽었다고
# 보면 정상 프로브 중인 예약을 스테일로 오판한다 — 넉넉히 배로 잡는다.
_STALE_GRACE_SECONDS = 6 * 3600


def _err(msg: str) -> None:
    print(f"[workflow-arm] {msg}", file=sys.stderr)


def _state_root() -> Path:
    root = os.environ.get("FREEZE_STATE_DIR")
    if root:
        return Path(root)
    return Path.home() / ".local/state/freeze"


def _is_execution_call(tool_input: dict) -> bool:
    return any(k in tool_input for k in _EXEC_KEYS)


def _agent_threshold() -> int:
    try:
        return int(os.environ.get("FREEZE_HOOK_AGENT_THRESHOLD", _AGENT_THRESHOLD_DEFAULT))
    except (TypeError, ValueError):
        return _AGENT_THRESHOLD_DEFAULT


def _read_text_file(path: str) -> str | None:
    try:
        return Path(path).read_text(encoding="utf-8")
    except Exception:
        return None


def _find_named_workflow(name: str, cwd: str) -> str | None:
    """cwd 의 .claude/workflows/, 그다음 ~/.claude/workflows/ 순서로 찾는다.

    못 찾으면 None — 이 훅의 철학상 예상 밖 상황(워크플로우 파일 부재)에서는
    절대 막지 않고 통과시킨다.
    """
    for base in (Path(cwd) / ".claude/workflows", Path.home() / ".claude/workflows"):
        for ext in _WORKFLOW_EXTS:
            p = base / f"{name}{ext}"
            text = _read_text_file(str(p))
            if text is not None:
                return text
    return None


def _get_script_text(tool_input: dict, cwd: str) -> str | None:
    """규모 판정에 쓸 스크립트 텍스트를 얻는다. 못 얻으면 None(=통과 신호).

    우선순위는 _EXEC_KEYS 와 동일하게 script → scriptPath → name.
    """
    if "script" in tool_input:
        val = tool_input.get("script")
        return val if isinstance(val, str) else None
    if "scriptPath" in tool_input:
        val = tool_input.get("scriptPath")
        if not isinstance(val, str):
            return None
        return _read_text_file(val)
    if "name" in tool_input:
        val = tool_input.get("name")
        if not isinstance(val, str):
            return None
        return _find_named_workflow(val, cwd)
    return None


def _skip_string(text: str, i: int) -> int:
    """text[i]는 여는 따옴표( ' " ` 중 하나). 이스케이프를 건너뛰며 닫는 따옴표 바로
    다음 인덱스를 반환한다. 안 닫히면 텍스트 끝까지로 본다."""
    quote = text[i]
    n = len(text)
    j = i + 1
    while j < n:
        c = text[j]
        if c == "\\":
            j += 2
            continue
        if c == quote:
            return j + 1
        j += 1
    return n


_BLANK_FILL = "#"  # 지운 자리의 채움 문자 — 공백이 아닌 이유는 아래 참고

# 정규식 리터럴 뒤에 붙을 수 있는 플래그 문자.
_REGEX_FLAG_CHARS = frozenset("gimsuyx")


def _prev_significant_char(text: str, i: int) -> str:
    """i 앞에서 공백이 아닌 첫 문자를 찾는다(나눗셈 vs 정규식 리터럴 판별용).
    공백만 있거나 텍스트 시작이면 빈 문자열을 돌려준다 — 문(statement) 맨 앞의
    `/`는 나눗셈일 수 없으니 정규식 시작으로 본다."""
    j = i - 1
    while j >= 0 and text[j].isspace():
        j -= 1
    return text[j] if j >= 0 else ""


def _regex_literal_end(text: str, i: int) -> int | None:
    """text[i]는 '/' 이고 정규식 리터럴 시작으로 판정된 상태. 이스케이프(`\\/`)와
    문자 클래스(`[...]` 안의 `/`)를 존중하며 닫는 `/`를 찾고, 뒤따르는 플래그까지
    포함한 끝 인덱스(배타)를 반환한다.

    줄바꿈을 만날 때까지 못 닫으면 정규식 리터럴이 아니라고 보고 None을 돌려준다
    — JS 정규식 리터럴은 한 줄을 못 넘으므로, 이 경우는 애초에 정규식이 아니었단
    뜻이다. 여기서 "그래도 정규식이라 치고 지운다"를 택하면 실제로는 나눗셈이던
    코드를 줄바꿈 너머까지 통째로 지워버려 과소평가로 흐른다 — 그 반대를 택한다.
    """
    n = len(text)
    in_class = False
    j = i + 1
    while j < n:
        c = text[j]
        if c == "\n":
            return None
        if c == "\\":
            j += 2
            continue
        if c == "[":
            in_class = True
            j += 1
            continue
        if c == "]":
            in_class = False
            j += 1
            continue
        if c == "/" and not in_class:
            k = j + 1
            while k < n and text[k] in _REGEX_FLAG_CHARS:
                k += 1
            return k
        j += 1
    return None


def _strip_comments_and_strings(text: str) -> str:
    """주석(//, /* */), 정규식 리터럴(/.../), 문자열 리터럴(', ", 백틱)을 같은
    길이로 지운다.

    채움 문자는 공백이 아니라 `#`이다 — 공백으로 채우면 원소가 문자열 하나뿐인
    배열(`["a,b", "c"]`)의 각 원소가 전부 "공백만 있는 구간"으로 보여
    `_top_level_spans`의 빈 구간 필터에 걸려 원소 자체가 사라진다(2개짜리 배열이
    0개로 셈해짐). `#`은 이 파일의 어떤 정규식·괄호·식별자 집합에도 안 걸리는
    문자라 안전하다. 개행 문자만은 그대로 남겨 위치가 원본과 어긋나지 않게 한다.
    이후의 모든 패턴 매칭·배열/괄호 스캔은 이 결과 위에서만 돈다 — 주석 속
    `for (`, 문자열 속 `.map(` 에 낚여 작은 워크플로우를 잘못 막는 일을 막는다.

    정규식 리터럴을 문자열보다 먼저 처리하는 이유: 정규식 안의 따옴표(`/['"]/`)를
    문자열의 여는 따옴표로 오인하면 스트리퍼가 다음 따옴표(또는 파일 끝)까지
    통째로 삼켜, 뒤따르는 `agent(`·`.map(`·배열 리터럴이 전부 사라진다 — 큰
    워크플로우가 작다고 판정돼 이 게이트를 그냥 통과해버리는 가장 위험한 오탐.
    """
    n = len(text)
    out = list(text)
    i = 0
    while i < n:
        c = text[i]
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = i
            while j < n and text[j] != "\n":
                out[j] = _BLANK_FILL
                j += 1
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            end = text.find("*/", i + 2)
            stop = end + 2 if end != -1 else n
            for k in range(i, stop):
                if out[k] != "\n":
                    out[k] = _BLANK_FILL
            i = stop
            continue
        if c == "/":
            prev = _prev_significant_char(text, i)
            # 나눗셈과 정규식을 가르는 고전적 휴리스틱: 직전 비공백 문자가
            # )·]·}·식별자 문자·숫자면 나눗셈, 아니면 정규식 시작으로 본다.
            if prev == "" or (prev not in ")]}" and prev not in _IDENT_CHARS):
                end = _regex_literal_end(text, i)
                if end is not None:
                    for k in range(i, end):
                        if out[k] != "\n":
                            out[k] = _BLANK_FILL
                    i = end
                    continue
        if c in "'\"`":
            close = _skip_string(text, i)
            for k in range(i, close):
                if out[k] != "\n":
                    out[k] = _BLANK_FILL
            i = close
            continue
        i += 1
    return "".join(out)


def _matching_close(text: str, open_pos: int) -> int:
    """text[open_pos]는 '(' '[' '{' 중 하나. 짝이 맞는 닫는 괄호 위치를 반환한다.
    깊이만 세고 괄호 종류는 구분하지 않는다(정상적인 코드에서는 항상 짝이 맞는다).
    짝이 안 맞으면 텍스트 끝(len)을 반환한다.
    """
    n = len(text)
    depth = 0
    i = open_pos
    while i < n:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    return n


def _top_level_spans(text: str, open_pos: int, close_pos: int) -> list[tuple[int, int]]:
    """(open_pos, close_pos) 괄호 안 내용을 최상위 콤마로 나눈 (start, end) 구간
    목록을 반환한다. 중첩된 괄호 안의 콤마는 무시한다. 공백만 있는 구간(빈 괄호,
    트레일링 콤마)은 버린다. 배열 원소 개수 세기와 함수 호출 인자 나누기에 함께
    쓰는 공용 스캐너다."""
    spans: list[tuple[int, int]] = []
    depth = 0
    seg_start = open_pos + 1
    i = seg_start
    while i < close_pos:
        c = text[i]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            spans.append((seg_start, i))
            seg_start = i + 1
        i += 1
    spans.append((seg_start, close_pos))
    return [s for s in spans if text[s[0] : s[1]].strip()]


def _collect_array_literals(text: str) -> list[tuple[int, int, int]]:
    """텍스트 전체에서 "배열 리터럴로 보이는" '['을 모두 찾아 (open, close, size)로
    모은다. 여는 '[' 바로 앞이 식별자 문자·')'·']'면 인덱싱(`arr[i]`)으로 보고
    건너뛴다 — 리터럴이 아니라 대상을 못 세는 접근이다. spread(`...`)가 최상위
    원소로 들어있으면(`[...items]`, `[...Array(100)]`) 크기를 셀 수 없는 배열로 보고
    아예 목록에서 뺀다 — 참조하는 쪽에서는 "찾을 수 없음"과 똑같이 취급되어 안전한
    방향(막는 쪽)으로 떨어진다.
    """
    result: list[tuple[int, int, int]] = []
    n = len(text)
    i = 0
    while i < n:
        c = text[i]
        if c == "[":
            prev = text[i - 1] if i > 0 else ""
            if prev in _IDENT_CHARS or prev in ")]":
                i += 1
                continue
            close_pos = _matching_close(text, i)
            spans = _top_level_spans(text, i, close_pos)
            has_spread = any(text[s:e].lstrip().startswith("...") for s, e in spans)
            if not has_spread:
                result.append((i, close_pos, len(spans)))
            i = close_pos + 1
            continue
        i += 1
    return result


def _name_is_reassigned_or_mutated(text: str, name: str, decl_match: re.Match) -> bool:
    """`name`이 `decl_match`(그 배열을 선언한 매치) 말고 다른 곳에서 재대입되거나
    (`name = ...`), push/concat/splice/unshift 로 변형되면 True.

    재대입 판정은 선언 자체("`const name = [...]`")도 `name = ` 형태라 걸리므로,
    선언 매치 안의 `name` 시작 위치(`decl_match.start(1)`)와 일치하는 매치 하나는
    선언 자신으로 보고 제외한다. `==`/`===`/`=>` 는 재대입이 아니라 비교·화살표
    함수이므로 제외한다.
    """
    escaped = re.escape(name)
    reassign_re = re.compile(rf"\b{escaped}\s*=(?!=)(?!>)")
    for m in reassign_re.finditer(text):
        if m.start() != decl_match.start(1):
            return True
    mutate_re = re.compile(
        rf"\b{escaped}\s*\.\s*(?:{'|'.join(_ARRAY_MUTATION_METHODS)})\s*\("
    )
    return mutate_re.search(text) is not None


def _collect_named_array_sizes(
    text: str, open_index: dict[int, int]
) -> dict[str, int]:
    """`const/let/var NAME = [...]`로 선언된 배열의 이름 → 원소 개수.

    이 스캐너는 스코프를 구분하지 않는 평면 텍스트 검색이라, 이름이 두 번 이상
    선언되면(같은 스코프의 재선언이든 다른 함수 안의 동명 지역 변수든) 어느 쪽이
    실제로 참조되는지 알 수 없다 — 안전하게 "믿을 수 없음"으로 보고 아예 뺀다.
    선언 뒤 재대입되거나(`NAME = ...`) push/concat/splice/unshift 로 변형된
    이름도 선언 시점 크기가 더 이상 안 맞을 수 있으므로 뺀다. 목록에서 빠진
    이름은 참조하는 쪽(`_classify_method_receiver`/`_classify_call_arg`)에서
    존재하지 않는 이름과 똑같이 취급되어 크기를 모르는 쪽(=막는 쪽)으로
    떨어진다.
    """
    decls: dict[str, list[re.Match]] = {}
    for m in _NAMED_ARRAY_RE.finditer(text):
        decls.setdefault(m.group(1), []).append(m)

    sizes: dict[str, int] = {}
    for name, matches in decls.items():
        if len(matches) > 1:
            continue
        m = matches[0]
        open_pos = m.end() - 1
        size = open_index.get(open_pos)
        if size is None:
            continue
        if _name_is_reassigned_or_mutated(text, name, m):
            continue
        sizes[name] = size
    return sizes


def _classify_method_receiver(
    text: str, dot_pos: int, close_index: dict[int, int], named_sizes: dict[str, int]
) -> int | None:
    """`.map(`/`.forEach(`/`.flatMap(` 바로 앞의 리시버 크기를 판정한다.

    인라인 배열 리터럴(`[...].map(`)이면 그 크기, 알려진 배열 식별자(`NAME.map(`)면
    그 크기. 속성 접근(`review.findings.map(`)이나 함수 호출 결과 등은 None(알 수 없음).
    """
    j = dot_pos - 1
    while j >= 0 and text[j].isspace():
        j -= 1
    if j < 0:
        return None
    if text[j] == "]":
        return close_index.get(j)
    if text[j] in _IDENT_CHARS:
        start = j
        while start > 0 and text[start - 1] in _IDENT_CHARS:
            start -= 1
        if start > 0 and text[start - 1] == ".":
            # obj.prop.map( — 속성 접근이라 크기를 모른다
            return None
        return named_sizes.get(text[start : j + 1])
    return None


def _classify_call_arg(
    text: str, arg_start: int, open_index: dict[int, int], named_sizes: dict[str, int]
) -> int | None:
    """`parallel(`/`pipeline(` 의 첫 인자 크기를 판정한다.

    인라인 배열 리터럴이면 그 크기, 알려진 배열 식별자면 그 크기. 그 외(함수 호출·
    속성 접근 등)는 None(알 수 없음).
    """
    n = len(text)
    j = arg_start
    while j < n and text[j].isspace():
        j += 1
    if j >= n:
        return None
    if text[j] == "[":
        return open_index.get(j)
    if text[j] in _IDENT_CHARS:
        k = j
        while k < n and text[k] in _IDENT_CHARS:
            k += 1
        return named_sizes.get(text[j:k])
    return None


# parallel(/pipeline(의 단일 인자가 그 자체로 다른 팬아웃 표현식 전체일 때(pass-through,
# 예: `parallel(X.map(fn))`)는 곱하지 않는다 — 안쪽 팬아웃이 이미 별도 사이트로 잡혀
# 자기 크기만큼만 반영되므로, 바깥 호출까지 곱하면 중복 계산된다.
_PASSTHROUGH_METHOD_RE = re.compile(
    r"\A[A-Za-z_$][\w$]*(?:\s*\.\s*[A-Za-z_$][\w$]*)*\s*\.\s*(?:map|forEach|flatMap)\s*\("
)
_PASSTHROUGH_CALL_RE = re.compile(r"\A(?:parallel|pipeline)\s*\(")


def _is_passthrough_arg(arg_text: str) -> bool:
    """parallel(/pipeline(의 인자가 그 자체로 팬아웃 표현식 전체인지 판정한다
    (`parallel(X.map(fn))`처럼). 앞뒤에 다른 연산이 섞이면(`foo + X.map(fn)`,
    `X.map(fn).filter(...)`) 실패한다 — 애매하면 pass-through 로 보지 않고 일반
    인자 판정(`_classify_call_arg`)으로 넘겨 크기를 모르는 쪽으로 떨어지게 한다.
    """
    stripped = arg_text.strip()
    if not stripped:
        return False
    m = _PASSTHROUGH_METHOD_RE.match(stripped) or _PASSTHROUGH_CALL_RE.match(stripped)
    if not m:
        return False
    close_paren = _matching_close(stripped, m.end() - 1)
    return close_paren == len(stripped) - 1


class _FanoutSite:
    """팬아웃 호출 하나(`.map(`/`.forEach(`/`.flatMap(`/`parallel(`/`pipeline(`)의
    위치와 자기 자신의(중첩 반영 전) 크기."""

    __slots__ = ("marker_pos", "paren_open", "paren_close", "own_size")

    def __init__(
        self, marker_pos: int, paren_open: int, paren_close: int, own_size: int | None
    ) -> None:
        self.marker_pos = marker_pos
        self.paren_open = paren_open
        self.paren_close = paren_close
        self.own_size = own_size


def _find_fanout_sites(
    text: str,
    open_index: dict[int, int],
    close_index: dict[int, int],
    named_sizes: dict[str, int],
) -> list[_FanoutSite]:
    """`.map(`/`.forEach(`/`.flatMap(`과 `parallel(`/`pipeline(` 호출을 전부 찾아
    각각의 팬아웃 대상 크기(own_size, 모르면 None)를 판정한다."""
    sites: list[_FanoutSite] = []

    for m in _METHOD_FANOUT_RE.finditer(text):
        dot_pos = m.start()
        paren_open = m.end() - 1
        paren_close = _matching_close(text, paren_open)
        own_size = _classify_method_receiver(text, dot_pos, close_index, named_sizes)
        sites.append(_FanoutSite(dot_pos, paren_open, paren_close, own_size))

    for m in _CALL_FANOUT_RE.finditer(text):
        marker_pos = m.start()
        paren_open = m.end() - 1
        paren_close = _matching_close(text, paren_open)
        arg_spans = _top_level_spans(text, paren_open, paren_close)
        own_size: int | None
        if len(arg_spans) == 1 and _is_passthrough_arg(
            text[arg_spans[0][0] : arg_spans[0][1]]
        ):
            own_size = 1
        elif arg_spans:
            own_size = _classify_call_arg(text, arg_spans[0][0], open_index, named_sizes)
        else:
            own_size = None
        sites.append(_FanoutSite(marker_pos, paren_open, paren_close, own_size))

    return sites


def _nested_multiplier(sites: list[_FanoutSite]) -> int | None:
    """팬아웃 사이트들의 중첩 관계를 곱으로 누적해 전체 배수를 계산한다.

    사이트 하나라도 own_size 를 모르면(None) 전체를 알 수 없는 것으로 본다 — 하나만
    셀 수 없어도 그 워크플로우는 막아야 한다(과소평가 금지). 사이트 A의 괄호 구간
    안에 사이트 B의 시작점이 있으면 B는 A의 자식이다 — 여러 사이트가 감싸면 그중
    가장 좁게 감싸는 쪽을 직계 부모로 삼는다. 각 사이트의 배수는
    own_size × max(자식들의 배수, 최소 1) — 10개 배열 위 팬아웃 안에 10개 배열
    팬아웃이 중첩되면 10×10=100이 된다. 형제 사이트(중첩이 아니라 나란히 있는
    경우)는 정확한 합산 대신 더 큰 쪽을 취한다 — 과소평가보다 과대평가가 안전한
    방향이기 때문이다. 최상위(부모 없는) 사이트들 중 가장 큰 배수를 전체 배수로
    쓴다. 사이트가 하나도 없으면 배수는 1(팬아웃 없음).
    """
    if not sites:
        return 1
    if any(s.own_size is None for s in sites):
        return None

    parent_of: dict[int, int | None] = {}
    for i, site in enumerate(sites):
        best_j: int | None = None
        best_width: int | None = None
        for j, other in enumerate(sites):
            if i == j:
                continue
            if other.paren_open < site.marker_pos < other.paren_close:
                width = other.paren_close - other.paren_open
                if best_width is None or width < best_width:
                    best_width = width
                    best_j = j
        parent_of[i] = best_j

    children: dict[int, list[int]] = {i: [] for i in range(len(sites))}
    roots: list[int] = []
    for i, j in parent_of.items():
        if j is None:
            roots.append(i)
        else:
            children[j].append(i)

    memo: dict[int, int] = {}

    def chain(i: int) -> int:
        if i in memo:
            return memo[i]
        own = sites[i].own_size or 0
        best_child = max((chain(k) for k in children[i]), default=1)
        result = own * max(best_child, 1)
        memo[i] = result
        return result

    return max(chain(i) for i in roots)


_CANNOT_COUNT_REASON = "이 워크플로우는 팬아웃 대상 크기를 정적으로 셀 수 없다."


def _estimate_scale(text: str) -> tuple[bool, str]:
    """워크플로우 규모를 추정한다.

    반환값 (is_large, reason_line):
      - 주석(//, /* */)과 문자열 리터럴은 먼저 지운 텍스트 위에서만 판정한다 — 주석
        속 `for (`, 문자열 속 `.map(` 에 낚여 작은 워크플로우를 잘못 막지 않는다.
      - for/for await/while 루프는 반복 횟수를 정적으로 알 수 없다 — 무조건 막는다.
      - Array.from(/new Array(/.fill(/.reduce(/Promise.all(/Promise.allSettled( 도
        런타임에야 크기가 정해지는 구성이라 무조건 막는다 — 이 파일이 팬아웃
        마커로 아는 것은 parallel/pipeline/.map/.forEach/.flatMap 다섯 개뿐이라,
        이 밖에서 벌어지는 팬아웃은 존재 자체를 못 본다.
      - agent 라는 단어가 agent( 호출 형태보다 더 많이 나오면(point-free로 함수
        참조만 넘기는 `specs.map(agent)` 같은 형태) 그만큼을 못 세므로 무조건
        막는다.
      - parallel(/pipeline(/.map(/.forEach(/.flatMap( 의 팬아웃 대상이 인라인 배열
        리터럴이거나 const/let/var로 선언된 배열 식별자면 그 원소 개수를 안다.
        단, 그 이름이 두 번 이상 선언되거나(스코프를 구분 못 하므로 다른 함수
        안의 동명 지역 변수도 포함) 선언 뒤 재대입되거나 push/concat/splice/
        unshift로 변형되면 선언 시점 크기를 못 믿으므로 모르는 것으로 본다.
        spread(`...items`, `...Array(100)`)가 섞인 배열도 크기를 모르는 것으로
        본다. 그 밖(속성 접근, 함수 호출 결과 등)도 모른다 — 하나라도 모르면
        무조건 막는다.
      - 팬아웃이 중첩되면 곱으로 누적한다(10×10 중첩이면 100). `parallel(X.map(...))`
        처럼 바깥 호출이 안쪽 팬아웃 표현식을 그대로 넘기기만 하는 pass-through는
        곱하지 않는다 — 안쪽 사이트가 이미 자기 크기를 반영하기 때문이다.
      - 전부 알 수 있으면 추정치 = agent( 개수 × max(전체 팬아웃 배수, 1). 임계값
        이하면 통과.
    """
    threshold = _agent_threshold()
    clean = _strip_comments_and_strings(text)

    if _LOOP_RE.search(clean) or _UNCOUNTABLE_FANOUT_RE.search(clean):
        return True, _CANNOT_COUNT_REASON

    agent_count = len(_AGENT_CALL_RE.findall(clean))
    if len(_AGENT_REF_RE.findall(clean)) > agent_count:
        # point-free(`specs.map(agent)`)처럼 agent 라는 단어는 나오는데 그중 일부가
        # agent( 호출 형태가 아니다 — 그 만큼을 못 세므로 무조건 막는다.
        return True, _CANNOT_COUNT_REASON

    array_literals = _collect_array_literals(clean)
    open_index = {o: s for o, c, s in array_literals}
    close_index = {c: s for o, c, s in array_literals}
    named_sizes = _collect_named_array_sizes(clean, open_index)

    sites = _find_fanout_sites(clean, open_index, close_index, named_sizes)
    multiplier = _nested_multiplier(sites)
    if multiplier is None:
        return True, _CANNOT_COUNT_REASON

    multiplier = max(multiplier, 1)
    estimate = agent_count * multiplier
    if estimate > threshold:
        return True, f"이 워크플로우는 서브에이전트 {estimate}개로 추정된다(임계값 {threshold})."
    return False, ""

def _normalize(p: str) -> str:
    try:
        return os.path.normpath(p)
    except Exception:
        return p


def _pid_alive(pid_str: str) -> bool:
    """freeze.sh의 pid_alive와 같은 기준 — ps 상태로 본다(좀비는 죽은 것으로 취급)."""
    if not pid_str:
        return False
    try:
        pid = int(pid_str)
    except (TypeError, ValueError):
        return False
    try:
        out = subprocess.run(
            ["ps", "-o", "state=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=2,
        )
        state = out.stdout.strip()
        return bool(state) and state[0] != "Z"
    except Exception:
        # ps 를 못 쓰는 환경 — kill(pid, 0) 으로 대체 판정(좀비를 살아있다고 오판할 수 있음)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        except Exception:
            return False
        return True


def _sleeper_pid(res_path: Path) -> str:
    # freeze.sh 는 reservation.json 과 같은 디렉토리에 sleeper.pid 를 둔다.
    try:
        return (res_path.parent / "sleeper.pid").read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def _is_stale(data: dict, res_path: Path, now: float) -> bool:
    """죽은 슬리퍼가 남긴 reservation.json 인지 판정한다.

    status=running: thaw.sh 자신이 재개 세션을 물고 있는 동안엔 슬리퍼 프로세스가
    곧 재개 프로세스이므로 계속 살아있어야 한다. 죽어 있으면 무조건 스테일(재시작 등으로
    고아가 된 경우) — running 은 실행 시간이 임의로 길 수 있어 경과 시간으로는 판단 못한다.
    status=frozen: 슬리퍼가 살아있으면 스테일이 아니다. 죽어 있으면 resume_at + 프로브
    유예(_STALE_GRACE_SECONDS)를 넘겼을 때만 스테일로 본다 — resume_at 전에 슬리퍼가
    죽은 경우(예: 재시작)까지 성급하게 스테일로 잡으면, 아직 정상적으로 살아날 수 있는
    예약을 무예약으로 오판해 이 훅이 엉뚱하게 다시 발동한다. 대가도 있다: 재시작으로
    슬리퍼가 resume_at 전에 죽으면 그 예약은 (resume_at까지 남은 시간 + 유예) 동안
    계속 "활성"으로 남아, 그 cwd에 대한 workflow-arm 가드 자체가 그 구간만큼 잠든다 —
    thaw.sh가 그 예약을 끝내 못 살려도(진짜 고아여도) 스테일 판정이 나기 전까지는
    Workflow 호출이 그냥 통과한다.
    """
    status = data.get("status", "")
    alive = _pid_alive(_sleeper_pid(res_path))
    if alive:
        return False
    if status == "running":
        return True
    if status == "frozen":
        try:
            resume_at = float(data.get("resume_at"))
        except (TypeError, ValueError):
            return True  # resume_at 도 없고 슬리퍼도 죽음 — 스테일
        return (now - resume_at) > _STALE_GRACE_SECONDS
    # 알려지지 않은 상태값 — 보수적으로 활성 취급(스테일 아님)
    return False


def _has_active_reservation(state_root: Path, cwd: str) -> bool:
    """cwd가 일치하고, 종료 상태가 아니며, 스테일도 아닌 reservation.json이 하나라도 있으면 True."""
    target = _normalize(cwd)
    now = time.time()
    for res_path in state_root.glob("*/reservation.json"):
        try:
            data = json.loads(res_path.read_text(encoding="utf-8"))
        except Exception:
            continue
        if not isinstance(data, dict):
            continue
        if _normalize(str(data.get("cwd", ""))) != target:
            continue
        status = data.get("status", "")
        if status in _TERMINAL_STATUSES:
            continue
        if _is_stale(data, res_path, now):
            continue
        return True
    return False


def _session_marker_dir(state_root: Path) -> Path:
    # freeze.sh의 job 디렉토리(<STATE_ROOT>/<job>/reservation.json)와 겹치지 않는
    # 별도 하위 디렉토리. reservation.json이 없으므로 위 glob에도 걸리지 않는다.
    return state_root / "workflow-arm-sessions"


def _cleanup_old_markers(marker_dir: Path) -> None:
    try:
        if not marker_dir.exists():
            return
        now = time.time()
        for f in marker_dir.iterdir():
            try:
                if now - f.stat().st_mtime > _MARKER_MAX_AGE:
                    f.unlink()
            except Exception:
                continue
    except Exception:
        pass


def _mark_denied(marker_dir: Path, session_id: str, cwd: str) -> str:
    """세션 마커를 원자적으로(O_EXCL) 만들어 "이 턴에서 deny할 차례가 누구인지"를 정한다.

    반환값 셋 중 하나:
      "first"   — 이번 호출이 마커를 새로 만들었다 → 이번 호출이 deny한다.
      "already" — 마커가 이미 있었다(이전 호출이 이미 deny했거나, 같은 턴에서 병렬로
                  나간 다른 Workflow 호출이 방금 먼저 만들었다) → 통과.
      "error"   — 상태 디렉토리에 아예 쓸 수 없다(읽기 전용 마운트, 디스크 풀, 권한
                  문제) → 통과. deny하면 이후 어떤 세션도 마커를 남길 수 없어 Workflow가
                  영구히 막힌다 — 훅 때문에 작업이 멈추는 것이 가장 나쁜 실패다.

    O_EXCL로 "마커 부재 확인"과 "마커 생성"을 한 시스템 콜로 합치는 이유: 두 단계로
    나뉘어 있으면(있는지 보고 → 없으면 쓴다) 한 턴에서 병렬로 나간 Workflow 호출 두
    개가 둘 다 부재를 보고 둘 다 deny해버린다("세션당 한 번" 계약 위반).

    마커 내용은 타임스탬프 하나가 아니라 {"ts", "cwd", "unarmed"} JSON이다. cwd를
    같이 심어야 나중에 "이 cwd에서 예약 없이 통과된 적이 있는가"를 다른 세션의 마커까지
    훑어 판정할 수 있다(_has_prior_unarmed_passthrough 참고). "unarmed"는 처음엔
    False로 시작해 _record_unarmed_passthrough가 필요할 때만 True로 덮어쓴다.
    """
    try:
        marker_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        _err(f"세션 마커 디렉토리 생성 실패: {exc}")
        return "error"

    marker_path = marker_dir / session_id
    try:
        fd = os.open(str(marker_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    except FileExistsError:
        return "already"
    except Exception as exc:
        _err(f"세션 마커 기록 실패: {exc}")
        return "error"

    payload = json.dumps({"ts": time.time(), "cwd": _normalize(cwd), "unarmed": False})
    try:
        os.write(fd, payload.encode("utf-8"))
    finally:
        os.close(fd)
    return "first"


def _record_unarmed_passthrough(marker_dir: Path, session_id: str) -> None:
    """"이미 한 번 막힌 세션인데도 여전히 활성 예약이 없다"를 마커에 남긴다.

    major 재현: deny 사유의 2번 명령(`freeze.sh arm ... `, --at 기본값 auto)이
    cmd_estimate UNKNOWN(리셋 경계, HUD 캐시 없음)에서 exit 1 하고 reservation.json을
    하나도 안 만든다. 하지만 이 훅은 이미 첫 호출에서 세션 마커를 찍어뒀으므로, 다음
    Workflow 호출은 "already"로 그냥 통과한다 — 훅이 막으려던 무예약 실행이 조건부로
    되살아난다.

    정공법(마커를 deny 시점이 아니라 절차가 실제로 끝난 뒤 찍는 것)은 이 훅의 구조상
    안 된다: 이 훅은 PreToolUse:Workflow에만 걸리고, 그 사이에 에이전트가 실행하는
    `freeze.sh arm` 같은 Bash 호출은 전혀 못 본다. arm이 성공했는지 실패했는지 알 수
    있는 유일한 관측 지점은 "다음 Workflow 호출 시점의 _has_active_reservation() 값"
    뿐이고, 그마저도 그 다음 Workflow 호출이 언제 올지(혹은 영영 안 올지) 훅이 정할 수
    없다. 그래서 정공법 대신 이 차선책을 쓴다: 세션당 한 번만 deny하는 계약은 유지하되
    (그래야 훅 자체 오판으로 Workflow가 영구히 막히는 사고를 피한다), 통과시키는 이
    순간을 마커에 기록해 "다음에 이 cwd를 다시 볼 deny 사유"(대개 다음 세션의 첫
    호출)에 경고를 보탠다 — _has_prior_unarmed_passthrough 참고.

    베스트에포트 — 실패해도 무시한다. 이 훅은 항상 exit 0이어야 한다.
    """
    marker_path = marker_dir / session_id
    try:
        data = json.loads(marker_path.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return
        data["unarmed"] = True
        marker_path.write_text(json.dumps(data), encoding="utf-8")
    except Exception:
        pass


def _has_prior_unarmed_passthrough(marker_dir: Path, cwd: str) -> bool:
    """이 cwd에 대해 "예약 없이 통과된" 마커가 하나라도 있으면 True.

    session_id별로 나뉜 마커 파일들을 전부 훑는다 — 이번 호출은 아직 자기 마커를
    만들기 전(첫 deny 시도)이므로 여기서 걸리는 건 전부 다른(대개 이전) 세션의 기록이다.
    """
    target = _normalize(cwd)
    try:
        if not marker_dir.exists():
            return False
        for f in marker_dir.iterdir():
            try:
                data = json.loads(f.read_text(encoding="utf-8"))
            except Exception:
                continue
            if not isinstance(data, dict):
                continue
            if data.get("unarmed") and _normalize(str(data.get("cwd", ""))) == target:
                return True
    except Exception:
        pass
    return False


def _deny(reason: str) -> None:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(payload, ensure_ascii=False))


def _build_reason(cwd: str, marker_dir: Path | None = None, scale_reason: str = "") -> str:
    ledger = f"{cwd}/.omc/handoffs/wfledger-<job>.md"
    scale = f"[workflow-arm] {scale_reason}\n" if scale_reason else ""
    warn = ""
    if marker_dir is not None and _has_prior_unarmed_passthrough(marker_dir, cwd):
        warn = (
            "[workflow-arm] 주의: 이 작업 디렉토리는 이전 세션에서 2번이 실패해 "
            "예약 없이 Workflow가 통과된 적이 있다. 이번엔 2번 명령이 실제로 성공했는지"
            "(reservation.json 생성)까지 확인한 뒤에 Workflow를 다시 불러라.\n"
        )
    return (
        scale
        + warn
        + "[workflow-arm] 큰 Workflow를 돌리기 전에 재개 예약부터 걸어라. "
        "<job> 자리에는 이번 작업을 가리킬 이름 하나를 정해 아래 두 명령에 동일하게 써라.\n"
        f"1) 원장 작성: bash ~/.claude/skills/freeze/scripts/wfledger.sh init --cwd \"{cwd}\" "
        "--job <job> --summary \"<이번 작업을 한 줄로 요약>\"\n"
        "2) 예약: bash ~/.claude/skills/freeze/scripts/freeze.sh arm --mode ledger "
        f"--cwd \"{cwd}\" --handoff \"{ledger}\" --waker codex\n"
        "   2번이 \"땡 시각 추정 실패\"로 exit 1 하면(리셋 경계 등 --at auto가 UNKNOWN을 "
        "내는 경우) 예약이 하나도 안 걸린 채로 끝난다 — --at HH:MM 을 추가해 시각을 "
        "직접 지정해라. 예: --at 18:00\n"
        "3) 예약이 걸린 뒤에 Workflow를 다시 호출해라.\n"
        # 4) 없이 끝내면 Workflow가 정상 종료돼도 예약이 살아있는 채로 남는다 —
        # 완료 신호(done)를 안 남기면 리셋 시각에 이미 끝난 작업을 헤드리스로
        # 다시 열어버린다. 이 훅이 절차를 1~3으로만 안내한 탓에, 훅에 막혀 예약을
        # 건 세션은 해제 방법을 안내받은 적이 아예 없었다(2026-08-28 코드 감사).
        "4) Workflow가 끝나고 작업이 완료되면 반드시 완료 신호를 남겨라 — 안 남기면 예약이 "
        "살아남아 땡 시각에 이미 끝난 작업을 다시 연다:\n"
        f"   bash ~/.claude/skills/freeze/scripts/freeze.sh done --handoff \"{ledger}\"\n"
        "이 가드가 필요 없으면 FREEZE_HOOK_OFF=1 로 꺼라."
    )


def main() -> None:
    # 킬스위치 — 전역 DISABLE_OMC, 이 훅 전용 FREEZE_HOOK_OFF=1
    if os.environ.get("DISABLE_OMC") or os.environ.get("FREEZE_HOOK_OFF") == "1":
        sys.exit(0)

    try:
        raw = sys.stdin.read()
        inp = json.loads(raw)
    except Exception as exc:
        _err(f"stdin parse failed: {exc}")
        sys.exit(0)

    try:
        if not isinstance(inp, dict):
            sys.exit(0)

        if inp.get("tool_name", "") != "Workflow":
            sys.exit(0)

        tool_input = inp.get("tool_input", {})
        if not isinstance(tool_input, dict) or not _is_execution_call(tool_input):
            # runId만 있는 조회·제어 호출이거나 형식을 알 수 없는 입력 — 통과
            sys.exit(0)

        session_id = str(inp.get("session_id", ""))
        cwd = str(inp.get("cwd", "") or tool_input.get("cwd", ""))
        if not cwd or not session_id:
            sys.exit(0)

        # 규모 판정을 활성 예약 확인보다 먼저 한다 — 작은 워크플로우는 예약 여부를 볼
        # 필요도 없고, 세션 마커도 찍지 않는다(작은 워크플로우 한 번이 그 세션의
        # "한 번만 막기" 기회를 태워버리면 안 된다).
        script_text = _get_script_text(tool_input, cwd)
        if script_text is None:
            # script 없음 / scriptPath 읽기 실패 / name 워크플로우 못 찾음 — 예상 밖
            # 상황에서는 절대 막지 않는다.
            sys.exit(0)

        is_large, scale_reason = _estimate_scale(script_text)
        if not is_large:
            sys.exit(0)

        state_root = _state_root()
        # 상태 디렉토리 부재는 "예약 없음"으로 다룬다 — freeze 를 한 번도 안 쓴 환경이
        # 바로 이 훅이 막아야 할 대상이므로 여기서 통과시키면 훅이 첫 사용자에게는
        # 영원히 발동하지 않는다. 반대로 디렉토리는 있는데 읽을 수 없는 경우(권한 오류,
        # 읽기 전용 마운트 등)는 부재와 다르게 취급해 통과시킨다 — 부재와 오류를 구분한다.
        if state_root.exists():
            try:
                os.listdir(state_root)
            except OSError as exc:
                _err(f"상태 디렉토리 접근 실패: {exc}")
                sys.exit(0)

        if _has_active_reservation(state_root, cwd):
            sys.exit(0)

        marker_dir = _session_marker_dir(state_root)
        _cleanup_old_markers(marker_dir)

        mark_result = _mark_denied(marker_dir, session_id, cwd)
        if mark_result != "first":
            # "already"(이 세션은 이미 한 번 막혔다 / 병렬 호출 중 다른 쪽이 먼저 막았다)
            # 이거나 "error"(마커를 못 남김) — 어느 쪽이든 이번 호출은 통과시킨다.
            # "already"인 경우 위의 _has_active_reservation() 검사를 이미 통과 못했다는
            # 뜻(그랬으면 여기까지 오지 않고 먼저 return했다) — 즉 지금 이 통과는 여전히
            # 무예약 상태라는 뜻이다. 그 사실을 마커에 남겨 다음에 이 cwd를 볼 deny
            # 사유에 경고를 보탠다.
            if mark_result == "already":
                _record_unarmed_passthrough(marker_dir, session_id)
            sys.exit(0)

        _deny(_build_reason(cwd, marker_dir, scale_reason))
    except SystemExit:
        raise
    except Exception as exc:  # noqa: BLE001
        _err(f"internal error: {exc}")
        sys.exit(0)

    sys.exit(0)


if __name__ == "__main__":
    main()
