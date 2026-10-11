#!/usr/bin/env bash
# 22-pip.sh — pip 캐시 정리.
# 단독 실행: bash clean.d/22-pip.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="22-pip"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v pip3 >/dev/null 2>&1; then
    skip "$MODULE_NAME: pip3 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

PIP_CACHE_DIR="$(pip3 cache dir 2>/dev/null)"
[ -z "$PIP_CACHE_DIR" ] && PIP_CACHE_DIR="$HOME/Library/Caches/pip"

before=$(size_kb "$PIP_CACHE_DIR")
log "$MODULE_NAME: 대상 = $PIP_CACHE_DIR (현재 $(human "$before"))"

if [ "$DRY_RUN" = "1" ]; then
    log "$MODULE_NAME: [dry-run] pip3 cache purge"
    log "$MODULE_NAME: 예상 확보량 <= $(human "$before")"
    emit_result "$MODULE_NAME" "$before" dry
    exit 0
fi

with_timeout 60 pip3 cache purge 2>&1 | sed "s/^/$MODULE_NAME: /"

after=$(size_kb "$PIP_CACHE_DIR")
freed=$((before - after))
[ "$freed" -lt 0 ] && freed=0
log "$MODULE_NAME: 확보 $(human "$freed")"
emit_result "$MODULE_NAME" "$freed" ok
