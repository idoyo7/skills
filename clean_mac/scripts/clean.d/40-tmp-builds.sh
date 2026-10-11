#!/usr/bin/env bash
# 40-tmp-builds.sh — /private/tmp 최상위의 오래된 verify/_site 빌드 산출물 정리.
# claude-* 로 시작하는 항목은 50-claude-tmp.sh 전용이라 여기서는 제외한다.
#
# 50-claude-tmp.sh와 같은 안전장치를 적용한다: 마운트 포함 시 skip,
# 프로세스가 사용 중이면 skip, 하위 파일이 최근에 수정됐으면 skip, 그 판정을
# 못 하면(find 실패) skip.
#
# 단독 실행: bash clean.d/40-tmp-builds.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="40-tmp-builds"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

# 스캔/삭제 루트. 기본값은 /private/tmp 그대로다. TMP_BUILDS_ROOT로 덮어쓸
# 수 있는데, 평소에 쓰라는 값이 아니라 테스트 하네스가 가짜 트리를 가리키게
# 하려는 것이다(루트가 하드코딩이던 시절의 사고는 lib.sh
# resolve_root_override 주석 참고). 검사를 못 넘으면 RESULT 없이 끝낸다.
TMP_ROOT=$(resolve_root_override TMP_BUILDS_ROOT "${TMP_BUILDS_ROOT:-/private/tmp}") || exit 1
MIN_AGE_DAYS="${TMP_BUILDS_MIN_AGE_D:-3}"
# 0~36500(100년)의 10진 정수만 받는다. 앞자리 0이 붙은 값("08")은 아래
# 산술에서 8진수 오류가 나고 보호 창이 꺼진 채 계속 돌았다(lib.sh
# age_value_ok 주석 참고).
if ! age_value_ok "$MIN_AGE_DAYS" 36500; then
    warn "$MODULE_NAME: TMP_BUILDS_MIN_AGE_D 값을 쓸 수 없음(0~36500의 정수, 앞자리 0 불가): '$MIN_AGE_DAYS'"
    exit 1
fi
# find -mmin은 "분" 단위다. 예전에는 일수*24(시간)를 그대로 -mmin에 넘겨서
# "최근 3일 내 수정 보호"가 실제로는 72분 보호였다 — 2시간 전에 쓰던 빌드
# 디렉터리가 최상위 mtime만 오래됐으면 지워질 수 있었다. 분으로 환산한다.
MIN_AGE_MIN=$((MIN_AGE_DAYS * 24 * 60))
# 환산 결과가 숫자가 아니면 보호 창 없이 도는 대신 여기서 끝낸다.
if ! is_nonneg_int "${MIN_AGE_MIN:-}"; then
    warn "$MODULE_NAME: 보호 창(분) 계산 실패: '${MIN_AGE_MIN:-}'"
    exit 1
fi
ME="$(id -un)"

if [ ! -d "$TMP_ROOT" ]; then
    skip "$MODULE_NAME: $TMP_ROOT 없음"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

found_any=0
before_total=0
freed_total=0
skipped_total=0

# 개행 포함 파일명이 있어도 깨지지 않도록 -print0 + process substitution +
# read -d ''로 처리한다(NUL은 bash 변수에 담을 수 없어서 변수 캡처를 거치지
# 않고 바로 읽는다). 최상위(1단계)에서만, 내 소유, claude-* 제외,
# verify/_site 이름, mtime +N일.
while IFS= read -r -d '' p; do
    [ -z "$p" ] && continue
    found_any=1

    # find 결과가 정말 TMP_ROOT 바로 밑인지 재확인(방어적 이중 검사).
    case "$p" in
        "$TMP_ROOT"/*) : ;;
        *)
            warn "$MODULE_NAME: 예상 밖의 경로라 skip: $p"
            continue
            ;;
    esac

    kb=$(size_kb "$p")
    before_total=$((before_total + kb))

    # 1) 마운트 포인트 포함 여부
    if has_mount_under "$p"; then
        skip "$MODULE_NAME: 내부에 마운트 포인트가 있어 skip: $p ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
        continue
    fi

    # 2) 프로세스 사용 중 여부(cwd 또는 열린 파일)
    if path_busy "$p"; then
        skip "$MODULE_NAME: 프로세스가 사용 중이라 skip: $p ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
        continue
    fi

    # 3) 최근 수정된 파일이 하위에 있는지(마운트는 넘지 않음). 삭제로 내려가는
    #    값은 1(find가 정상 종료했고 최근 수정 없음) 하나뿐이다. find가 오류로
    #    끝나면 판정 불가로 보고 남긴다(lib.sh recent_mtime_state 주석 참고).
    recent_mtime_state "$p" "$MIN_AGE_MIN" -type f
    case $? in
        1) : ;;
        0)
            skip "$MODULE_NAME: 최근 ${MIN_AGE_DAYS}일 내 수정된 파일이 있어 skip: $p ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
        *)
            skip "$MODULE_NAME: 최근 수정 여부를 판정할 수 없어(find 실패) skip: $p ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
            ;;
    esac

    if [ "$DRY_RUN" = "1" ]; then
        log "$MODULE_NAME: [dry-run] rm -rfx $p ($(human "$kb"))"
    else
        log "$MODULE_NAME: 삭제 $p ($(human "$kb"))"
        safe_rm "$p" "$TMP_ROOT"
        if [ ! -e "$p" ]; then
            freed_total=$((freed_total + kb))
        fi
    fi
done < <(find "$TMP_ROOT" -mindepth 1 -maxdepth 1 -user "$ME" \
    \( -name '*verify*' -o -name '_site*' \) \
    ! -name 'claude-*' \
    -mtime "+${MIN_AGE_DAYS}" -print0 2>/dev/null)

if [ "$found_any" = "0" ]; then
    skip "$MODULE_NAME: 대상 없음 (mtime +${MIN_AGE_DAYS}일 기준)"
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
