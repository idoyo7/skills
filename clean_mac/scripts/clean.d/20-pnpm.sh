#!/usr/bin/env bash
# 20-pnpm.sh — pnpm store prune + pnpm 캐시 디렉토리 삭제.
# 단독 실행: bash clean.d/20-pnpm.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="20-pnpm"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v pnpm >/dev/null 2>&1; then
    skip "$MODULE_NAME: pnpm 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

PNPM_STORE_DIR="$HOME/Library/pnpm"
PNPM_CACHE_DIR="$HOME/Library/Caches/pnpm"

before=$(size_kb "$PNPM_STORE_DIR" "$PNPM_CACHE_DIR")
log "$MODULE_NAME: 대상 = $PNPM_STORE_DIR, $PNPM_CACHE_DIR (현재 $(human "$before"))"

if [ "$DRY_RUN" = "1" ]; then
    log "$MODULE_NAME: [dry-run] pnpm store prune (참조 없는 패키지만 지우므로 실제 확보량은 이 값보다 작을 수 있음)"
    log "$MODULE_NAME: [dry-run] rm -rfx $PNPM_CACHE_DIR"
    log "$MODULE_NAME: 예상 확보량 상한 <= $(human "$before")"
    emit_result "$MODULE_NAME" "$before" dry
    exit 0
fi

# cwd의 package.json/pnpm-workspace.yaml에 영향받지 않도록 "/"에서 실행.
(cd / && with_timeout 180 pnpm store prune) 2>&1 | sed "s/^/$MODULE_NAME: /"
safe_rm "$PNPM_CACHE_DIR" "$HOME/Library/Caches"

after=$(size_kb "$PNPM_STORE_DIR" "$PNPM_CACHE_DIR")
freed=$((before - after))
[ "$freed" -lt 0 ] && freed=0
log "$MODULE_NAME: 확보 $(human "$freed")"
emit_result "$MODULE_NAME" "$freed" ok
