#!/usr/bin/env bash
# 50-claude-tmp.sh — Claude Code 세션 스크래치패드
# (/private/tmp/claude-<uid>/<project>/<session-uuid>/) 정리.
#
# 이 모듈이 가장 위험하다. 아래 안전장치를 절대 건너뛰지 않는다:
#   1) 세션 디렉터리 내부(하위 어디든)에 마운트 포인트가 있으면 세션 전체를
#      skip 한다. NFS로 마운트된 NAS 위로 재귀 rm -rf 가 나가면 안 된다.
#      마운트 판정은 mount(8) 문자열 파싱이 아니라 디바이스 번호 비교로
#      한다(has_mount_under, lib.sh) — 경로 이름에 " on "이 들어가는
#      마운트(예: dmg 볼륨)도 놓치지 않는다.
#   2) 어떤 프로세스든 그 안에 cwd 또는 열린 파일이 있으면 skip 한다.
#      lsof 확보 자체가 실패/타임아웃하면 판단 불가 상태를 "사용 중 아님"
#      으로 오인하지 않고 무조건 "사용 중"으로 처리한다(fail-safe, lib.sh
#      의 fetch_lsof_cache/_LSOF_OK 참고).
#   3) 최상위 mtime은 믿지 않는다 — 세션 디렉터리 자신과 그 하위의 파일·
#      디렉터리 중 최근 N시간 내 변경이 있으면 skip 한다(마운트는 넘지
#      않음, -xdev). 일반 파일만 보던 때는 방금 만들어져 빈 디렉터리만 있는
#      세션, 하위 디렉터리 mtime만 바뀐 세션이 후보가 됐다. 이 find가 오류로
#      끝나면 "변경 없음"이 아니라 판정 불가로 보고 skip 한다(lib.sh
#      recent_mtime_state).
#   4) 현재 실행 중인 세션은 추가로 보호한다. 실제 환경변수 이름은
#      CLAUDE_CODE_SESSION_ID이고 CLAUDE_SESSION_ID는 존재하지 않는 경우가
#      있어 둘 다 본다.
#   5) 크기 측정(du)은 마운트/busy 판정이 끝난 뒤에 하고, du 자체도
#      -skx(마운트 안 넘음)로만 부른다 — NFS가 응답 없을 때 크기 재려다
#      멈추는 사고를 막기 위함.
#   6) 그 세션의 대화 기록이 최근 N시간 내 수정됐으면 skip 한다. 스크래치
#      패드는 조용한데 대화는 이어지고 있는 세션이 있다 — 2026-10-09 실제
#      dry-run에서 당일 12:35·13:14에 대화한 세션들이 후보(합계 4.30GB)에
#      들어 있었다. 2)의 lsof는 스크래치패드를 cwd로 쓰거나 그 안의 파일을
#      열어 둔 프로세스만 잡으므로 "실행 중인 세션"을 알아보지 못한다.
#      대화 기록을 조회하지 못하면 "기록 없음"이 아니라 판정 불가로 보고
#      skip 한다(아래 transcript_activity). 프로젝트 디렉터리 하나를 볼 수
#      없으면(읽기 권한 없음, 끊어진 심볼릭 링크) 어느 세션의 기록이 거기
#      있는지 모르므로 그 실행의 모든 세션이 판정 불가다(projects_precheck).
#
# 6)으로도 못 막는 경우가 남는다. 실행 중이지만 대화 기록과 스크래치패드가
# 모두 N시간 넘게 조용한 세션, 대화 기록이 없는 세션은 여전히 후보다. 그래서
# 이 모듈은 계속 사람이 후보를 보고 따로 승인해야 도는 모듈이다(SKILL.md §1).
#
# 단독 실행: bash clean.d/50-claude-tmp.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="50-claude-tmp"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

MIN_AGE_H="${CLAUDE_TMP_MIN_AGE_H:-24}"
# 0~876000(100년)의 10진 정수만 받는다. 앞자리 0이 붙은 값은 8진수로
# 읽혀서 "010"이 8시간이 되고, "08"이나 넘치는 큰 값은 보호 창이 꺼진 채
# 방금 수정한 세션까지 후보가 됐다(lib.sh age_value_ok 주석 참고).
if ! age_value_ok "$MIN_AGE_H" 876000; then
    warn "$MODULE_NAME: CLAUDE_TMP_MIN_AGE_H 값을 쓸 수 없음(0~876000의 정수, 앞자리 0 불가): '$MIN_AGE_H'"
    exit 1
fi
# find -mmin에 넘길 분 값. 루프 안의 find 인자에서 계산하지 않고 여기서 한
# 번 구해 확인한다 — 환산이 실패하면 보호 창 없이 도는 대신 끝낸다.
MIN_AGE_MIN=$((MIN_AGE_H * 60))
if ! is_nonneg_int "${MIN_AGE_MIN:-}"; then
    warn "$MODULE_NAME: 보호 창(분) 계산 실패: '${MIN_AGE_MIN:-}'"
    exit 1
fi
CLAUDE_UID="$(id -u)"
# 스캔/삭제 루트. 기본값은 /private/tmp/claude-<uid> 그대로다.
# CLAUDE_TMP_ROOT로 덮어쓸 수 있는데, 평소에 쓰라는 값이 아니라 테스트
# 하네스가 가짜 트리를 가리키게 하려는 것이다. 이 루트가 하드코딩이라
# 2026-09-29에 가짜 트리 시험이 실제 루트에서 real 모드로 돌아 다른 세션의
# 스크래치패드를 지웠다(lib.sh resolve_root_override 주석 참고). 검사를 못
# 넘으면 RESULT 없이 끝낸다.
CLAUDE_TMP_ROOT=$(resolve_root_override CLAUDE_TMP_ROOT "${CLAUDE_TMP_ROOT:-/private/tmp/claude-${CLAUDE_UID}}") || exit 1
CURRENT_SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CLAUDE_SESSION_ID:-}}"

# 대화 기록 디렉터리. Claude Code는 세션마다 <projects>/<프로젝트>/<세션
# UUID>.jsonl 에 대화를 쓰고, 서브에이전트·워크플로·도구 결과는 같은 자리의
# <세션 UUID>/ 디렉터리에 쓴다. 기본값은 $HOME/.claude/projects 이고
# CLAUDE_TMP_PROJECTS_DIR로 덮어쓸 수 있다(테스트 하네스가 가짜 트리를
# 가리키게 하려는 것이다).
#
# 이 경로는 읽기만 한다. 여기서 찾은 경로는 safe_rm에 넘어가지 않고 허용
# 접두로도 쓰이지 않는다. 그래서 삭제 루트(CLAUDE_TMP_ROOT)에 거는
# resolve_root_override 검사 — "너무 넓은 경로는 거부" — 를 걸지 않는다.
# 걱정이 반대 방향이다. 값이 틀려 대화 기록을 못 찾으면 6)의 보호가 조용히
# 꺼지므로, 절대경로가 아니면 RESULT 없이 끝내고(FAIL) 디렉터리가 없으면
# 아무것도 지우지 않고 끝낸다(아래).
PROJECTS_DIR_RAW="${CLAUDE_TMP_PROJECTS_DIR:-${HOME:-}/.claude/projects}"
case "$PROJECTS_DIR_RAW" in
    /*) : ;;
    *)
        warn "$MODULE_NAME: CLAUDE_TMP_PROJECTS_DIR 값을 쓸 수 없음(절대경로여야 함): '$PROJECTS_DIR_RAW'"
        exit 1
        ;;
esac

# CLAUDE_CONFIG_DIR — Claude Code는 이 값이 있으면 설정 디렉터리를 거기로 옮기고
# 대화 기록도 <CLAUDE_CONFIG_DIR>/projects 에 쓴다. 기본 경로만 보면, 이 값으로
# 띄운 세션의 기록은 "없음"으로 나오고 예전 ~/.claude/projects 가 남아 있는
# 한 skip도 경고도 없이 6)의 보호가 꺼졌다(재현됨). 그래서 이 값이 있으면
# 그 아래 projects 도 같이 찾는다. 기본 경로를 대신하지 않고 더한다 — 두 곳
# 어디서든 최근 기록이 나오면 남기므로 삭제 대상은 줄기만 한다. 그래서 기본
# 경로가 있어야 한다는 조건도 그대로다.
# CLAUDE_TMP_PROJECTS_DIR 를 직접 준 실행은 그 값만 쓴다(찾을 곳을 명시한
# 것이다). 값이 절대경로가 아니면 어디를 가리키는지 알 수 없으므로 RESULT
# 없이 끝낸다. 한계: 이 모듈이 보는 것은 자기 환경의 CLAUDE_CONFIG_DIR 하나다.
# 다른 값으로 띄운 세션의 기록은 여전히 못 본다(SKILL.md §1).
PROJECTS_DIR2_RAW=""
if [ -z "${CLAUDE_TMP_PROJECTS_DIR:-}" ] && [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    case "$CLAUDE_CONFIG_DIR" in
        /*) PROJECTS_DIR2_RAW="${CLAUDE_CONFIG_DIR%/}/projects" ;;
        *)
            warn "$MODULE_NAME: CLAUDE_CONFIG_DIR 값을 쓸 수 없음(절대경로여야 함): '$CLAUDE_CONFIG_DIR'"
            exit 1
            ;;
    esac
fi

# 줄바꿈 한 글자. 목록 변수를 줄 단위로 자를 때 쓴다.
NL='
'

# is_uuid — case 패턴(글롭)으로 정확히 8-4-4-4-12 자리 hex인지 확인한다.
# grep -qE '^...$' 은 줄 단위로 ^/$ 가 앵커링돼서 "x\n<uuid>" 처럼 개행
# 뒤에 진짜 UUID가 오는 이름도 통과시키는 구멍이 있었다(재현됨). case
# 패턴 매칭은 전체 문자열을 한 번에(개행 포함해서) 통째로 보고, 앞뒤에
# '*' 가 없으니 정확히 이 36글자여야만 매칭된다.
is_uuid() {
    case "$1" in
        [0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]-[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F])
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

if [ ! -d "$CLAUDE_TMP_ROOT" ]; then
    skip "$MODULE_NAME: $CLAUDE_TMP_ROOT 없음"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

# 대화 기록 디렉터리가 없거나 들어갈 수 없으면 어느 세션이 활동 중인지 알 수
# 없다. "대화 기록 없음"으로 치고 계속 가면 6)의 보호 없이 도는 셈이라(HOME이
# 다른 값인 환경, ~/.claude 를 옮긴 환경) 아무것도 지우지 않고 끝낸다.
# 실경로로 바꿔 둔다 — find는 시작점이 심볼릭 링크면 따라가지 않아서,
# ~/.claude/projects 가 링크인 환경에서는 기록을 하나도 못 찾는다.
PROJECTS_DIR=$(CDPATH='' cd "$PROJECTS_DIR_RAW" 2>/dev/null && pwd -P)
if [ -z "$PROJECTS_DIR" ] || [ ! -d "$PROJECTS_DIR" ]; then
    skip "$MODULE_NAME: 대화 기록 디렉터리가 없어 세션 활동을 판정할 수 없음 — 아무것도 지우지 않음: $PROJECTS_DIR_RAW (다른 위치면 CLAUDE_TMP_PROJECTS_DIR 로 지정)"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi
# CLAUDE_CONFIG_DIR 쪽(있을 때만). 값은 있는데 그 아래 projects 가 없으면 그
# 설정으로 띄운 세션의 기록을 볼 수 없는 것이므로 같은 이유로 끝낸다. 기본
# 경로와 같은 디렉터리면 한 번만 본다.
PROJECTS_DIR2=""
if [ -n "$PROJECTS_DIR2_RAW" ]; then
    PROJECTS_DIR2=$(CDPATH='' cd "$PROJECTS_DIR2_RAW" 2>/dev/null && pwd -P)
    if [ -z "$PROJECTS_DIR2" ] || [ ! -d "$PROJECTS_DIR2" ]; then
        skip "$MODULE_NAME: CLAUDE_CONFIG_DIR 의 대화 기록 디렉터리가 없어 세션 활동을 판정할 수 없음 — 아무것도 지우지 않음: $PROJECTS_DIR2_RAW (다른 위치면 CLAUDE_TMP_PROJECTS_DIR 로 지정)"
        emit_result "$MODULE_NAME" 0 skip
        exit 0
    fi
    if [ "$PROJECTS_DIR2" = "$PROJECTS_DIR" ]; then
        PROJECTS_DIR2=""
    fi
fi

# under_projects <경로> — 대화 기록 디렉터리(둘 중 하나) 아래의 경로인가.
under_projects() {
    case "$1" in
        "$PROJECTS_DIR"/*) return 0 ;;
    esac
    if [ -n "$PROJECTS_DIR2" ]; then
        case "$1" in
            "$PROJECTS_DIR2"/*) return 0 ;;
        esac
    fi
    return 1
}

# projects_precheck — 대화 기록 디렉터리의 깊이 1 항목(프로젝트 디렉터리)을 한
# 번 훑어, 안을 볼 수 없는 항목이 하나라도 있으면 PROJECTS_BLOCKED=1 로 두고
# 그 항목을 이름과 함께 경고한다. PROJECTS_BLOCKED=1 이면 transcript_activity
# 는 모든 세션에 unknown 을 돌려준다 — 못 본 항목 안에 어느 세션의 기록이
# 있는지 알 수 없어서다. 걸리는 것은 둘이다.
#   끊어진 심볼릭 링크 — 프로젝트 디렉터리가 다른 볼륨을 가리키는 링크인데 그
#       볼륨이 빠진 경우. find -L 은 이런 링크를 오류 없이(종료 상태 0) 지나가서
#       그 안의 기록이 "없음"으로 나왔다(재현됨). 대상을 stat 할 수 없는 링크
#       (중간 경로 권한, 순환)도 [ -e ] 가 거짓이라 같이 걸린다.
#   읽을 수 없는 디렉터리 — 이쪽은 세션마다 find 가 실패해 이미 unknown 이었다.
#       다만 find 의 stderr 를 버려서, 세션 수만큼 같은 skip 줄만 나오고 어느
#       디렉터리 탓인지 로그에 없었다. 여기서 이름을 찍는다.
# 깊이 2(<uuid>.jsonl, <uuid>/)의 끊어진 링크는 여기서 보지 않는다. 이름이
# 맞으면 find 가 그대로 찍고, transcript_activity 가 [ -e ] 로 걸러 그 세션만
# unknown 이 된다.
PROJECTS_BLOCKED=0
projects_precheck() {
    local d e why shown=0 more=0
    for d in "$PROJECTS_DIR" "$PROJECTS_DIR2"; do
        [ -z "$d" ] && continue
        if [ ! -r "$d" ] || [ ! -x "$d" ]; then
            PROJECTS_BLOCKED=1
            warn "$MODULE_NAME: 대화 기록 디렉터리를 읽을 수 없음: $d"
            continue
        fi
        # 글롭이 아무것도 못 찾으면 패턴 글자가 그대로 남는데, 그런 경로는
        # 링크도 디렉터리도 아니라 아래 두 검사에 걸리지 않는다.
        for e in "$d"/* "$d"/.[!.]* "$d"/..?*; do
            why=""
            if [ -L "$e" ] && [ ! -e "$e" ]; then
                why="끊어졌거나 대상을 볼 수 없는 심볼릭 링크"
            elif [ -d "$e" ] && { [ ! -r "$e" ] || [ ! -x "$e" ]; }; then
                why="읽을 수 없는 디렉터리"
            fi
            [ -z "$why" ] && continue
            PROJECTS_BLOCKED=1
            if [ "$shown" -lt 5 ]; then
                warn "$MODULE_NAME: 대화 기록을 볼 수 없는 항목($why): $e"
                shown=$((shown + 1))
            else
                more=$((more + 1))
            fi
        done
    done
    if [ "$more" -gt 0 ]; then
        warn "$MODULE_NAME: 대화 기록을 볼 수 없는 항목이 ${more}개 더 있음"
    fi
    if [ "$PROJECTS_BLOCKED" = "1" ]; then
        warn "$MODULE_NAME: 위 항목 안에 어느 세션의 대화 기록이 있는지 알 수 없어 이번 실행은 모든 세션을 판정 불가로 남김(권한을 고치거나 링크를 치운 뒤 다시 실행)"
    fi
}
projects_precheck

# transcript_activity <세션 UUID> — 그 세션의 대화 기록이 보호 창 안에
# 수정됐는지 본다. 결과는 전역 TR_STATE 에 둔다.
#   recent  — 창 안에 수정된 기록이 있다
#   quiet   — 기록은 있고 전부 창 밖이다
#   none    — 이 UUID의 기록이 없다
#   unknown — 조회하지 못했다
# 삭제로 이어지는 값은 quiet·none 뿐이다. 함수는 unknown으로 시작해서, 끝까지
# 확인을 마친 경우에만 다른 값으로 바꾼다 — 중간에 어디서 빠져나가든 호출부는
# 지우지 않는다. TR_LIST 에는 찾은 기록 경로를 한 줄에 하나씩 둔다.
#
# 보는 것은 둘이다.
#   <projects>/*/<uuid>.jsonl — 대화 본문.
#   <projects>/*/<uuid>/      — 서브에이전트 기록(subagents/), 워크플로 상태
#       (workflows/), 도구 결과(tool-results/). 이 아래의 최근 변경도 활동으로
#       본다. 메인 세션이 서브에이전트나 백그라운드 작업에 일을 맡기고
#       기다리는 동안에는 본문 .jsonl 은 그대로이고 이 디렉터리만 바뀐다.
#       보는 범위를 넓혀도 보호가 늘 뿐 삭제 대상은 늘지 않는다.
# 대화 기록이 없는 세션(none)은 이 검사로는 보호되지 않는다. 나머지 검사에
# 맡긴다.
#
# 프로젝트 디렉터리가 심볼릭 링크여도 따라간다(-L, 깊이 2까지만이라 순환해도
# 끝난다). 이름은 대소문자를 가리지 않고 비교한다(-iname) — is_uuid 가 두
# 표기를 다 받는다. UUID는 16진수와 '-' 뿐이라 글롭 문자가 섞일 일이 없다.
#
# find의 종료 상태를 그대로 본다. 프로젝트 디렉터리 하나라도 읽지 못했으면
# 찾는 기록이 거기 있을 수 있으므로 unknown이다(projects_precheck 가 먼저
# 걸러 이름을 찍지만, 그 뒤에 생긴 것은 여기서 걸린다). 목록을 줄 단위로
# 나누므로 이름에 개행이 든 프로젝트 디렉터리가 있으면 경로가 깨지는데, 깨진
# 줄은 접두·존재 확인에서 걸려 unknown이 된다.
#
# 목록은 변수 안에서 직접 잘라 가며 돈다. here-document(<<EOF)로 읽지 않는다.
# bash 3.2는 here-document를 임시 파일(/var/tmp/sh-thd-*, TMPDIR 과 무관)에
# 쓰는데, 그 쓰기가 실패하면 루프가 한 번도 돌지 않고 다음 줄로 넘어간다.
# 그래서 아무것도 확인하지 않은 채 quiet 가 됐고, 대화 기록이 1시간 전인
# 세션이 후보로 나왔다(재현됨: ulimit -f 0). 디스크가 꽉 찬 상태가 바로 이
# 스크립트를 부르는 상황이다. 변수를 자르는 데는 임시 파일도 파이프도 없다.
# checked 는 그래도 남겨 두는 확인이다 — 목록이 비어 있지 않으니 한 줄 이상
# 확인했어야 quiet 다.
TR_STATE="unknown"
TR_LIST=""
transcript_activity() {
    local uuid="$1"
    local listing rc t rest checked=0
    TR_STATE="unknown"
    TR_LIST=""

    if [ "$PROJECTS_BLOCKED" != "0" ]; then
        return 0
    fi

    listing=$(find -L "$PROJECTS_DIR" ${PROJECTS_DIR2:+"$PROJECTS_DIR2"} -mindepth 2 -maxdepth 2 \
        \( -iname "${uuid}.jsonl" -o -iname "${uuid}" \) -print 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        return 0
    fi
    if [ -z "$listing" ]; then
        TR_STATE="none"
        return 0
    fi
    TR_LIST="$listing"

    rest="$listing"
    while [ -n "$rest" ]; do
        case "$rest" in
            *"$NL"*)
                t="${rest%%"$NL"*}"
                rest="${rest#*"$NL"}"
                ;;
            *)
                t="$rest"
                rest=""
                ;;
        esac
        # 온전한 줄은 전부 "<projects>/..." 꼴이고 실제로 있는 경로다. 아니면
        # 개행이 든 이름 때문에 깨진 줄이다 — unknown으로 둔 채 끝낸다.
        if ! under_projects "$t"; then
            return 0
        fi
        if [ ! -e "$t" ]; then
            return 0
        fi
        recent_mtime_state -H "$t" "$MIN_AGE_MIN"
        case $? in
            1) : ;;
            0)
                TR_STATE="recent"
                return 0
                ;;
            *)
                return 0
                ;;
        esac
        checked=$((checked + 1))
    done
    if [ "$checked" -lt 1 ]; then
        return 0
    fi
    TR_STATE="quiet"
    return 0
}

# transcript_label — 직전 transcript_activity 가 찾은 기록(TR_LIST) 중 가장
# 늦은 수정 시각을 "대화 기록 마지막 수정 YYYY-MM-DD HH:MM" 으로 낸다. 기록이
# 없으면 "대화 기록 없음". 로그에 찍는 용도뿐이고 판정에는 쓰지 않는다 —
# 후보를 사용자에게 보일 때 이 시각을 같이 보이게 하려는 것이다. 여기도
# here-document 를 쓰지 않는다(transcript_activity 주석 참고) — 임시 파일을 못
# 쓰는 상태에서 시각이 전부 "확인 불가"로 찍히지 않게.
transcript_label() {
    local t m max=0 rest="$TR_LIST"
    if [ -z "$rest" ]; then
        printf '대화 기록 없음'
        return 0
    fi
    while [ -n "$rest" ]; do
        case "$rest" in
            *"$NL"*)
                t="${rest%%"$NL"*}"
                rest="${rest#*"$NL"}"
                ;;
            *)
                t="$rest"
                rest=""
                ;;
        esac
        [ -z "$t" ] && continue
        # 그 기록(파일이면 자신, 디렉터리면 그 아래 전부)의 mtime 중 가장 큰 값.
        m=$(find -H "$t" -xdev -exec stat -f '%m' {} + 2>/dev/null \
            | awk '/^[0-9]+$/ { if ($1 + 0 > m) m = $1 + 0 } END { printf "%d\n", m + 0 }')
        is_nonneg_int "$m" || continue
        if [ "$m" -gt "$max" ]; then
            max="$m"
        fi
    done
    local when=""
    if [ "$max" -gt 0 ]; then
        when=$(date -r "$max" '+%Y-%m-%d %H:%M' 2>/dev/null)
    fi
    if [ -n "$when" ]; then
        printf '대화 기록 마지막 수정 %s' "$when"
    else
        printf '대화 기록 마지막 수정 시각 확인 불가'
    fi
}

# lsof는 한 번만 뜬다(모듈 전체에서 재사용) — lib.sh의 fetch_lsof_cache/path_busy 참고.
fetch_lsof_cache

found_any=0
before_total=0
freed_total=0
skipped_total=0

# 개행 포함 디렉터리명이 있어도 깨지지 않도록 -print0 + process substitution.
# (NUL은 bash 변수에 못 담기 때문에 변수 캡처를 거치지 않고 바로 읽는다.)
while IFS= read -r -d '' sdir; do
    [ -z "$sdir" ] && continue
    base="$(basename "$sdir")"
    is_uuid "$base" || continue
    found_any=1
    session_uuid="$base"

    # 4) 현재 실행 중인 세션 보호
    if [ -n "$CURRENT_SESSION_ID" ] && [ "$CURRENT_SESSION_ID" = "$session_uuid" ]; then
        kb=$(size_kb "$sdir")
        before_total=$((before_total + kb))
        skip "$MODULE_NAME: 현재 실행 중인 세션이라 skip: $sdir ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
        continue
    fi

    # 1) 마운트 포인트 포함 여부 (크기 측정보다 먼저 — du가 마운트를 만나기 전에 판단)
    if has_mount_under "$sdir"; then
        kb=$(size_kb "$sdir")
        before_total=$((before_total + kb))
        skip "$MODULE_NAME: 내부에 마운트 포인트가 있어 skip: $sdir ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
        continue
    fi

    # 2) 프로세스 사용 중 여부(cwd 또는 열린 파일)
    if path_busy "$sdir"; then
        kb=$(size_kb "$sdir")
        before_total=$((before_total + kb))
        skip "$MODULE_NAME: 프로세스가 사용 중이라 skip: $sdir ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
        continue
    fi

    # 6) 대화 기록이 최근 N시간 내 수정됐는지. 삭제 쪽으로 내려가는 값은
    #    quiet·none 뿐이고, 그 밖의 값(unknown 포함)은 전부 skip 한다.
    transcript_activity "$session_uuid"
    case "$TR_STATE" in
        quiet|none) : ;;
        recent)
            kb=$(size_kb "$sdir")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 대화 기록이 최근 ${MIN_AGE_H}시간 안에 수정돼 skip: $sdir ($(human "$kb"), $(transcript_label))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
        *)
            kb=$(size_kb "$sdir")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 대화 기록을 조회할 수 없어(판정 불가) skip: $sdir ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
    esac

    # 3) 최근 N시간 내 변경된 파일·디렉터리가 있는지(세션 디렉터리 자신 포함,
    #    마운트는 넘지 않음). 삭제 쪽으로 내려가는 값은 1(find가 정상
    #    종료했고 변경 없음) 하나뿐이다. 이 스캔은 읽기만 해서 디렉터리
    #    mtime을 바꾸지 않는다 — find·du·stat 은 atime만 건드린다.
    recent_mtime_state "$sdir" "$MIN_AGE_MIN"
    case $? in
        1) : ;;
        0)
            kb=$(size_kb "$sdir")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 최근 ${MIN_AGE_H}시간 내 수정된 파일·디렉터리가 있어 skip: $sdir ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
        *)
            kb=$(size_kb "$sdir")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 최근 수정 여부를 판정할 수 없어(find 실패) skip: $sdir ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
    esac

    # 여기까지 왔으면 삭제 대상 — 이제 크기를 잰다.
    kb=$(size_kb "$sdir")
    before_total=$((before_total + kb))
    tr_label="$(transcript_label)"

    if [ "$DRY_RUN" = "1" ]; then
        log "$MODULE_NAME: [dry-run] rm -rfx $sdir ($(human "$kb"), $tr_label)"
    else
        log "$MODULE_NAME: 삭제 $sdir ($(human "$kb"), $tr_label)"
        safe_rm "$sdir" "$CLAUDE_TMP_ROOT"
        if [ ! -e "$sdir" ]; then
            freed_total=$((freed_total + kb))
        fi
    fi
done < <(find "$CLAUDE_TMP_ROOT" -mindepth 2 -maxdepth 2 -type d -print0 2>/dev/null)

if [ "$found_any" = "0" ]; then
    skip "$MODULE_NAME: UUID 세션 디렉터리 없음"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

log "$MODULE_NAME: 후보 전체 $(human "$before_total"), skip $(human "$skipped_total")"

if [ "$DRY_RUN" = "1" ]; then
    would_free=$((before_total - skipped_total))
    log "$MODULE_NAME: 예상 확보량 <= $(human "$would_free")"
    emit_result "$MODULE_NAME" "$would_free" dry
    exit 0
fi

log "$MODULE_NAME: 확보 $(human "$freed_total")"
emit_result "$MODULE_NAME" "$freed_total" ok
