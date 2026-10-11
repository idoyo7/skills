#!/usr/bin/env bash
# 30-app-caches.sh — 앱 캐시 디렉토리 삭제 (Google Chrome, opencode).
# Chrome이 실행 중이면 Chrome 캐시만 skip하고(재실행 중 캐시를 건드리면
# 이상해질 수 있어서), opencode 캐시는 Chrome 상태와 무관하게 계속 지운다.
# 단독 실행: bash clean.d/30-app-caches.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="30-app-caches"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

GOOGLE_CACHE_DIR="$HOME/Library/Caches/Google"
OPENCODE_CACHE_DIR="$HOME/.cache/opencode"

if [ ! -e "$GOOGLE_CACHE_DIR" ] && [ ! -e "$OPENCODE_CACHE_DIR" ]; then
    skip "$MODULE_NAME: 대상 경로 없음"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

chrome_running=0
if pgrep -x "Google Chrome" >/dev/null 2>&1; then
    chrome_running=1
fi

before_total=0
freed_total=0
skipped_total=0

# --- Google Chrome 캐시 ---
if [ -e "$GOOGLE_CACHE_DIR" ]; then
    kb=$(size_kb "$GOOGLE_CACHE_DIR")
    before_total=$((before_total + kb))
    if [ "$chrome_running" = "1" ]; then
        skip "$MODULE_NAME: Chrome 실행 중이라 캐시 skip: $GOOGLE_CACHE_DIR ($(human "$kb"))"
        skipped_total=$((skipped_total + kb))
    elif [ "$DRY_RUN" = "1" ]; then
        log "$MODULE_NAME: [dry-run] rm -rfx $GOOGLE_CACHE_DIR ($(human "$kb"))"
    else
        log "$MODULE_NAME: 삭제 $GOOGLE_CACHE_DIR ($(human "$kb"))"
        safe_rm "$GOOGLE_CACHE_DIR" "$HOME/Library/Caches"
        if [ ! -e "$GOOGLE_CACHE_DIR" ]; then
            freed_total=$((freed_total + kb))
        fi
    fi
fi

# --- opencode 캐시 (Chrome 상태와 무관하게 처리) ---
if [ -e "$OPENCODE_CACHE_DIR" ]; then
    kb=$(size_kb "$OPENCODE_CACHE_DIR")
    before_total=$((before_total + kb))
    if [ "$DRY_RUN" = "1" ]; then
        log "$MODULE_NAME: [dry-run] rm -rfx $OPENCODE_CACHE_DIR ($(human "$kb"))"
    else
        log "$MODULE_NAME: 삭제 $OPENCODE_CACHE_DIR ($(human "$kb"))"
        safe_rm "$OPENCODE_CACHE_DIR" "$HOME/.cache"
        if [ ! -e "$OPENCODE_CACHE_DIR" ]; then
            freed_total=$((freed_total + kb))
        fi
    fi
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
