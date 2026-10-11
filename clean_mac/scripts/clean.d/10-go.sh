#!/usr/bin/env bash
# 10-go.sh — Go 빌드 캐시 / 모듈 캐시 정리.
# 단독 실행: bash clean.d/10-go.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="10-go"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v go >/dev/null 2>&1; then
    skip "$MODULE_NAME: go 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

GOCACHE_DIR="$(go env GOCACHE 2>/dev/null)"
GOMODCACHE_DIR="$(go env GOMODCACHE 2>/dev/null)"
[ -z "$GOCACHE_DIR" ] && GOCACHE_DIR="$HOME/Library/Caches/go-build"
[ -z "$GOMODCACHE_DIR" ] && GOMODCACHE_DIR="$HOME/go/pkg/mod"

before=$(size_kb "$GOCACHE_DIR" "$GOMODCACHE_DIR")
log "$MODULE_NAME: 대상 = $GOCACHE_DIR, $GOMODCACHE_DIR (현재 $(human "$before"))"

if [ "$DRY_RUN" = "1" ]; then
    log "$MODULE_NAME: [dry-run] go clean -cache"
    log "$MODULE_NAME: [dry-run] go clean -modcache"
    log "$MODULE_NAME: 예상 확보량 <= $(human "$before")"
    emit_result "$MODULE_NAME" "$before" dry
    exit 0
fi

# cwd에 있는 go.mod가 툴체인 다운로드를 유발하거나 동작을 바꾸는 걸
# 막기 위해 항상 "/"에서, 로컬 툴체인만 쓰도록 실행.
(cd / && GOTOOLCHAIN=local go clean -cache) 2>&1 | sed "s/^/$MODULE_NAME: /"
(cd / && GOTOOLCHAIN=local go clean -modcache) 2>&1 | sed "s/^/$MODULE_NAME: /"

after=$(size_kb "$GOCACHE_DIR" "$GOMODCACHE_DIR")
freed=$((before - after))
[ "$freed" -lt 0 ] && freed=0
log "$MODULE_NAME: 확보 $(human "$freed")"
emit_result "$MODULE_NAME" "$freed" ok
