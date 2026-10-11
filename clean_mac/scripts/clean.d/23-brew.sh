#!/usr/bin/env bash
# 23-brew.sh — Homebrew 캐시/오래된 버전 정리.
# 단독 실행: bash clean.d/23-brew.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="23-brew"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v brew >/dev/null 2>&1; then
    skip "$MODULE_NAME: brew 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

BREW_CACHE_DIR="$(brew --cache 2>/dev/null)"
[ -z "$BREW_CACHE_DIR" ] && BREW_CACHE_DIR="$HOME/Library/Caches/Homebrew"

before=$(size_kb "$BREW_CACHE_DIR")
log "$MODULE_NAME: 대상 = $BREW_CACHE_DIR (현재 $(human "$before"))"

if [ "$DRY_RUN" = "1" ]; then
    log "$MODULE_NAME: [dry-run] brew cleanup -s"
    with_timeout 60 brew cleanup -ns 2>&1 | sed "s/^/$MODULE_NAME: /"
    log "$MODULE_NAME: 예상 확보량 <= $(human "$before")"
    emit_result "$MODULE_NAME" "$before" dry
    exit 0
fi

with_timeout 300 brew cleanup -s 2>&1 | sed "s/^/$MODULE_NAME: /"

after=$(size_kb "$BREW_CACHE_DIR")
freed=$((before - after))
[ "$freed" -lt 0 ] && freed=0
log "$MODULE_NAME: 확보 $(human "$freed")"
emit_result "$MODULE_NAME" "$freed" ok
