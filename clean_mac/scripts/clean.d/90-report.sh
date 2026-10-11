#!/usr/bin/env bash
# 90-report.sh — 삭제하지 않고 크기만 보고하는 알림 모듈.
# 존재하지 않는 경로는 조용히 생략한다.
# du가 타임아웃/권한 문제로 실패하면 0KB로 보이지 않게 "측정 불가"로 표시한다.
# 단독 실행: bash clean.d/90-report.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="90-report"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

report_one() {
    local path="$1"
    local note="$2"
    if [ -e "$path" ]; then
        local kb
        if kb=$(size_kb_1 "$path"); then
            log "$MODULE_NAME: $path — $(human "$kb")${note:+ ($note)}"
        else
            log "$MODULE_NAME: $path — 측정 불가(권한/타임아웃)${note:+ ($note)}"
        fi
    fi
}

report_one "$HOME/Pictures/Photos Library.photoslibrary" "iCloud 사진 원본을 클라우드로 최적화하면 로컬 용량을 줄일 수 있음, 삭제 대상 아님"
report_one "$HOME/evejuni/istio-io/archive" "git으로 추적 중인 디렉터리, 필요 없으면 sparse-checkout으로 체크아웃만 제외 고려"
report_one "$HOME/k8s-backup" ""
report_one "$HOME/Downloads" ""
report_one "$HOME/Library/Containers/com.kakao.KakaoTalkMac" ""
report_one "$HOME/Library/Containers/com.tinyspeck.slackmacgap" ""

if [ -d "$HOME/.venvs" ]; then
    for venv in "$HOME"/.venvs/*; do
        [ -e "$venv" ] || continue
        report_one "$venv" ""
    done
fi

claude_uid="$(id -u)"
# 50-claude-tmp와 같은 CLAUDE_TMP_ROOT 오버라이드를 따른다(테스트 하네스가
# 가짜 트리만 재게 하려는 것 — 미설정이면 예전과 같은 글롭).
if [ -n "${CLAUDE_TMP_ROOT:-}" ]; then
    set -- "$CLAUDE_TMP_ROOT"
else
    set -- /private/tmp/claude-"${claude_uid}"*
fi
for ct in "$@"; do
    [ -e "$ct" ] || continue
    if kb=$(size_kb_1 "$ct"); then
        log "$MODULE_NAME: $ct — $(human "$kb") (세부 skip 사유는 50-claude-tmp 실행 로그 참고)"
    else
        log "$MODULE_NAME: $ct — 측정 불가(권한/타임아웃) (세부 skip 사유는 50-claude-tmp 실행 로그 참고)"
    fi
done

emit_result "$MODULE_NAME" 0 ok
