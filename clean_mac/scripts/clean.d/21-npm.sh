#!/usr/bin/env bash
# 21-npm.sh — npm 캐시 정리.
# 단독 실행: bash clean.d/21-npm.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="21-npm"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v npm >/dev/null 2>&1; then
    skip "$MODULE_NAME: npm 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

NPM_CACHE_DIR="$HOME/.npm/_cacache"

before=$(size_kb "$NPM_CACHE_DIR")
log "$MODULE_NAME: 대상 = $NPM_CACHE_DIR (현재 $(human "$before"))"

if [ "$DRY_RUN" = "1" ]; then
    log "$MODULE_NAME: [dry-run] npm cache clean --force"
    log "$MODULE_NAME: 예상 확보량 <= $(human "$before")"
    emit_result "$MODULE_NAME" "$before" dry
    exit 0
fi

# cwd의 package.json/.npmrc에 영향받지 않도록 "/"에서 실행.
(cd / && with_timeout 120 npm cache clean --force) 2>&1 | sed "s/^/$MODULE_NAME: /"

after=$(size_kb "$NPM_CACHE_DIR")
freed=$((before - after))
[ "$freed" -lt 0 ] && freed=0
log "$MODULE_NAME: 확보 $(human "$freed")"
emit_result "$MODULE_NAME" "$freed" ok
