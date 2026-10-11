#!/usr/bin/env bash
# 70-docker.sh — Docker 빌더/이미지 캐시 정리. 볼륨과 컨테이너는 건드리지 않는다.
# 데몬이 무응답이면 절대 자동으로 kill 하지 않고 안내만 한다.
# docker context/DOCKER_HOST가 로컬 유닉스 소켓이 아니면(원격 데몬) 아예
# skip한다 — 원격 데몬에 prune을 날리는 사고를 막기 위함.
# 단독 실행: bash clean.d/70-docker.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="70-docker"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

if ! command -v docker >/dev/null 2>&1; then
    skip "$MODULE_NAME: docker 미설치"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

# docker size 문자열(예: "1.2GB", "512MB", "3.4kB", "0B")을 KB(정수)로 변환.
_docker_size_to_kb() {
    awk -v s="$1" '
    BEGIN {
        val = s;
        unit = "";
        if (match(val, /[A-Za-z]+$/)) {
            unit = substr(val, RSTART, RLENGTH);
            num = substr(val, 1, RSTART - 1);
        } else {
            num = val; unit = "B";
        }
        num = num + 0;
        u = tolower(unit);
        if (u == "b") kb = num / 1024;
        else if (u == "kb") kb = num;
        else if (u == "mb") kb = num * 1024;
        else if (u == "gb") kb = num * 1024 * 1024;
        else if (u == "tb") kb = num * 1024 * 1024 * 1024;
        else kb = 0;
        printf "%d", kb;
    }'
}

# docker 데몬 접속 대상이 로컬 유닉스 소켓인지 확인. DOCKER_HOST가 설정돼
# 있으면 그 값을, 없으면 현재 context의 엔드포인트를 본다. 판단 불가하면
# 안전하게 "로컬 아님"(=skip)으로 취급한다.
_docker_is_local() {
    local host="${DOCKER_HOST:-}"
    if [ -n "$host" ]; then
        case "$host" in
            unix://*) return 0 ;;
            *) return 1 ;;
        esac
    fi
    local ctx_host
    ctx_host=$(with_timeout 10 docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null)
    if [ -z "$ctx_host" ]; then
        return 1
    fi
    case "$ctx_host" in
        unix://*) return 0 ;;
        *) return 1 ;;
    esac
}

if ! with_timeout 15 docker info >/dev/null 2>&1; then
    warn "$MODULE_NAME: 도커 데몬이 응답하지 않음"
    pids=$(pgrep -f 'com.docker.backend' 2>/dev/null)
    if [ -n "$pids" ]; then
        log "$MODULE_NAME: 멈춘 것으로 보이는 프로세스 (자동 kill 하지 않음):"
        for pid in $pids; do
            info=$(ps -o pid=,lstart=,command= -p "$pid" 2>/dev/null)
            log "$MODULE_NAME:   $info"
        done
        log "$MODULE_NAME: 필요하면 직접 실행: kill -9 <pid>; open /Applications/Docker.app"
    else
        log "$MODULE_NAME: com.docker.backend 프로세스를 찾지 못함 — Docker Desktop이 아예 안 떠 있을 수 있음"
    fi
    skip "$MODULE_NAME: 데몬 무응답이라 skip"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

if ! _docker_is_local; then
    log "$MODULE_NAME: 현재 docker 대상이 로컬 유닉스 소켓이 아님(원격 데몬으로 보임) — 안전하게 skip"
    skip "$MODULE_NAME: 원격 데몬이라 skip"
    emit_result "$MODULE_NAME" 0 skip
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    fmt_out=$(with_timeout 20 docker system df --format '{{.Type}}\t{{.Reclaimable}}' 2>/dev/null)
    if [ -n "$fmt_out" ]; then
        display_out="$fmt_out"
    else
        display_out=$(with_timeout 20 docker system df 2>/dev/null)
    fi
    log "$MODULE_NAME: [dry-run] docker system df (RECLAIMABLE):"
    printf '%s\n' "$display_out" | sed "s/^/$MODULE_NAME:   /"

    # 예상 확보량은 실제로 지우는 대상(Images, Build Cache)만 합산한다.
    # Containers/Local Volumes는 이 모듈이 건드리지 않으므로 제외.
    dry_kb_total=0
    if [ -n "$fmt_out" ]; then
        while IFS="$(printf '\t')" read -r typ reclaim; do
            [ -z "$reclaim" ] && continue
            case "$typ" in
                Images|"Build Cache") : ;;
                *) continue ;;
            esac
            val=$(printf '%s' "$reclaim" | awk '{print $1}')
            kb=$(_docker_size_to_kb "$val")
            dry_kb_total=$((dry_kb_total + kb))
        done <<EOF
$fmt_out
EOF
    fi
    log "$MODULE_NAME: 예상 확보량 <= $(human "$dry_kb_total") (Images + Build Cache만)"
    emit_result "$MODULE_NAME" "$dry_kb_total" dry
    exit 0
fi

log "$MODULE_NAME: 정리 전 docker system df"
with_timeout 20 docker system df 2>&1 | sed "s/^/$MODULE_NAME:   /"

builder_out=$(with_timeout 120 docker builder prune -a -f 2>&1)
image_out=$(with_timeout 120 docker image prune -a -f 2>&1)

builder_line=$(printf '%s\n' "$builder_out" | grep -i 'Total reclaimed space' | tail -1)
image_line=$(printf '%s\n' "$image_out" | grep -i 'Total reclaimed space' | tail -1)

[ -n "$builder_line" ] && log "$MODULE_NAME: builder prune -> $builder_line"
[ -n "$image_line" ] && log "$MODULE_NAME: image prune -> $image_line"

freed_total=0
for line in "$builder_line" "$image_line"; do
    [ -z "$line" ] && continue
    size_str=$(printf '%s' "$line" | sed -n 's/.*[Ss]pace:[[:space:]]*//p')
    [ -z "$size_str" ] && continue
    kb=$(_docker_size_to_kb "$size_str")
    freed_total=$((freed_total + kb))
done

log "$MODULE_NAME: 확보 $(human "$freed_total")"
emit_result "$MODULE_NAME" "$freed_total" ok
