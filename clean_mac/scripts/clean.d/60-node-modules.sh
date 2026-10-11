#!/usr/bin/env bash
# 60-node-modules.sh — 방치된 프로젝트의 node_modules 정리.
# 기본 루트: ~/src. NODE_MODULES_ROOTS(':' 구분, 경로에 공백이 있어도
# 안전)로 덮어쓸 수 있음.
#
# 안전장치:
#   - 마운트 포함 시 skip(has_mount_under), find는 전부 -xdev.
#   - 프로세스 cwd뿐 아니라 열린 파일(예: mmap된 .node 애드온)도 확인
#     (cwd_busy + path_busy).
#   - 모노레포 워크스페이스(pnpm-workspace.yaml 또는 package.json의
#     "workspaces")에 속한 node_modules는 그 node_modules의 바로 위
#     디렉터리가 아니라 워크스페이스 루트를 기준으로 "최근 수정" 여부를
#     판단한다 — 워크스페이스 루트가 최근에 건드려졌으면 그 안의 모든
#     패키지 node_modules도 같이 skip. .next 산출물 아래(예:
#     .next/standalone/node_modules)는 이 워크스페이스 판정에서 제외하고
#     바로 위 디렉터리만 본다(빌드 산출물 복사본일 뿐 실제 워크스페이스
#     멤버가 아님).
#   - safe_rm에 항상 root 경로를 허용 접두로 넘긴다.
#
# 단독 실행: bash clean.d/60-node-modules.sh [--dry-run]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

MODULE_NAME="60-node-modules"
DRY_RUN="${DRY_RUN:-0}"
parse_dry_run_arg "$@"

ROOTS_RAW="${NODE_MODULES_ROOTS:-$HOME/src}"
MIN_AGE_D="${NODE_MODULES_MIN_AGE_D:-30}"
if ! is_nonneg_int "$MIN_AGE_D"; then
    warn "$MODULE_NAME: NODE_MODULES_MIN_AGE_D 값이 정수가 아님: '$MIN_AGE_D'"
    exit 1
fi

# ':' 구분자로 분리(경로에 공백이 있어도 안전 — IFS를 잠깐 ':'만으로 바꿔
# 단어분리를 시킨다. 기본값엔 ':'가 없으니 한 개짜리 리스트가 된다).
split_roots() {
    local raw="$1"
    local old_ifs="$IFS"
    IFS=':'
    # 의도적 단어분리: IFS를 ':'로 좁혀서 콜론 기준으로만 나누기 위함
    # (경로 안의 공백은 IFS에 없으니 보존됨).
    # shellcheck disable=SC2086
    set -- $raw
    IFS="$old_ifs"
    printf '%s\n' "$@"
}

# find_workspace_root <project_dir> <root_boundary>
# project_dir에서 위로 올라가며 pnpm-workspace.yaml 또는 package.json의
# "workspaces" 필드를 찾아 그 디렉터리를 반환한다. root_boundary를 벗어나면
# 중단하고 project_dir 자신을 반환. .next 아래에 있으면 탐색하지 않고
# project_dir을 그대로 반환한다(빌드 산출물 복사본이라 워크스페이스
# 판정 대상이 아님).
find_workspace_root() {
    local dir="$1"
    local boundary="$2"
    case "$dir" in
        */.next|*/.next/*)
            printf '%s\n' "$dir"
            return 0
            ;;
    esac
    local cur="$dir"
    while :; do
        if [ -f "$cur/pnpm-workspace.yaml" ]; then
            printf '%s\n' "$cur"
            return 0
        fi
        if [ -f "$cur/package.json" ] && grep -q '"workspaces"' "$cur/package.json" 2>/dev/null; then
            printf '%s\n' "$cur"
            return 0
        fi
        if [ "$cur" = "$boundary" ]; then
            break
        fi
        case "$cur" in
            "$boundary"/*) : ;;
            *) break ;;
        esac
        cur="$(dirname "$cur")"
    done
    printf '%s\n' "$dir"
}

fetch_lsof_cache

found_any=0
before_total=0
freed_total=0
skipped_total=0

while IFS= read -r root; do
    [ -z "$root" ] && continue

    # 후행 슬래시 제거 후 root가 빈값/'/'/ $HOME 처럼 너무 넓으면
    # 거부한다(safe_rm도 같은 걸 막지만, 여기서 먼저 걸러야 "/" 전체를
    # find로 훑는 것 자체를 안 한다). NODE_MODULES_ROOTS=/ 같은 입력에
    # 대한 방어.
    while :; do
        case "$root" in
            */) root="${root%/}" ;;
            *) break ;;
        esac
    done
    case "$root" in
        ""|"/"|"$HOME")
            warn "$MODULE_NAME: NODE_MODULES_ROOTS 값이 너무 넓어서 거부: '$root'"
            continue
            ;;
    esac

    if [ ! -d "$root" ]; then
        continue
    fi

    while IFS= read -r -d '' nm; do
        [ -z "$nm" ] && continue
        found_any=1
        project="$(dirname "$nm")"

        # 마운트 포함 시 skip(크기 측정 전에 판단 — du가 마운트에 닿기 전에).
        if has_mount_under "$nm"; then
            kb=$(size_kb "$nm")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 내부에 마운트 포인트가 있어 skip: $nm ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
        fi

        check_dir="$(find_workspace_root "$project" "$root")"

        # 프로세스 cwd 또는 열린 파일(mmap된 .node 애드온 등)이 있으면 skip.
        if cwd_busy "$check_dir" || path_busy "$check_dir"; then
            kb=$(size_kb "$nm")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 프로세스가 사용 중이라 skip: $check_dir ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
        fi

        # check_dir(워크스페이스 루트 또는 프로젝트) 안에서 node_modules/.git/.next를
        # 건너뛰고(-prune) 최근 수정 파일이 있는지 확인.
        recent=$(find "$check_dir" -xdev \
            \( -name node_modules -o -name .git -o -name .next \) -prune -o \
            -type f -mtime "-${MIN_AGE_D}" -print 2>/dev/null | head -1)
        if [ -n "$recent" ]; then
            kb=$(size_kb "$nm")
            before_total=$((before_total + kb))
            skip "$MODULE_NAME: 최근 ${MIN_AGE_D}일 내 수정 있어 skip: $check_dir ($(human "$kb"))"
            skipped_total=$((skipped_total + kb))
            continue
        fi

        kb=$(size_kb "$nm")
        before_total=$((before_total + kb))

        if [ "$DRY_RUN" = "1" ]; then
            log "$MODULE_NAME: [dry-run] rm -rfx $nm ($(human "$kb"), 프로젝트: $project)"
        else
            log "$MODULE_NAME: 삭제 $nm ($(human "$kb"), 프로젝트: $project)"
            safe_rm "$nm" "$root"
            if [ ! -e "$nm" ]; then
                freed_total=$((freed_total + kb))
            fi
        fi
    done < <(find "$root" -xdev -maxdepth 5 -name node_modules -type d -prune -print0 2>/dev/null)
done < <(split_roots "$ROOTS_RAW")

if [ "$found_any" = "0" ]; then
    skip "$MODULE_NAME: 대상 node_modules 없음 (루트: $ROOTS_RAW)"
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
