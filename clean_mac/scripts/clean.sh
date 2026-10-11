#!/usr/bin/env bash
# clean.sh — 로컬 디스크 정리 중앙 스크립트. clean.d/ 안의 모듈을 번호 순서로 실행한다.
# macOS 기본 bash 3.2 호환. 실제 삭제 전에 항상 확인을 받는다(--dry-run/-y 제외).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD_DIR="$SCRIPT_DIR/clean.d"

# shellcheck source=clean.d/lib.sh
. "$MOD_DIR/lib.sh"

# ---- 모듈 목록(번호 순) -----------------------------------------------------
MODULE_FILES="10-go.sh 20-pnpm.sh 21-npm.sh 22-pip.sh 23-brew.sh 30-app-caches.sh 40-tmp-builds.sh 50-claude-tmp.sh 60-node-modules.sh 70-docker.sh 90-report.sh"

module_desc() {
    case "$1" in
        10-go.sh) echo "Go 빌드 캐시 / 모듈 캐시 정리" ;;
        20-pnpm.sh) echo "pnpm store prune + pnpm 캐시 삭제" ;;
        21-npm.sh) echo "npm 캐시 정리" ;;
        22-pip.sh) echo "pip 캐시 정리" ;;
        23-brew.sh) echo "brew cleanup -s" ;;
        30-app-caches.sh) echo "앱 캐시(Google, opencode) 삭제" ;;
        40-tmp-builds.sh) echo "/private/tmp 최상위 오래된 verify/_site 빌드 정리" ;;
        50-claude-tmp.sh) echo "Claude 세션 스크래치패드 정리 (위험 모듈, 안전장치 다수)" ;;
        60-node-modules.sh) echo "방치된 프로젝트의 node_modules 정리" ;;
        70-docker.sh) echo "Docker 빌더/이미지 캐시 정리 (볼륨/컨테이너는 건드리지 않음)" ;;
        90-report.sh) echo "삭제 없이 대형 경로 크기만 보고" ;;
        *) echo "" ;;
    esac
}

# 파일명(예: 10-go.sh)에서 확장자를 뗀 stem(10-go)을 얻는다.
module_stem() {
    printf '%s' "${1%.sh}"
}

# stem에서 번호와 대시 접두를 뗀 짧은 이름(예: 10-go -> go, 50-claude-tmp -> claude-tmp).
module_short() {
    printf '%s' "$1" | sed -E 's/^[0-9]+-//'
}

usage() {
    cat <<'EOF'
사용법: clean.sh [옵션]

옵션:
  --dry-run          실제로 지우지 않고 무엇을 지울지 / 예상 확보량만 출력
  -y, --yes          실행 전 확인(y/N) 없이 바로 진행
  --only a,b,...      지정한 모듈만 실행 (예: --only go,pnpm 또는 --only 10-go,claude-tmp)
  --skip a,b,...      지정한 모듈만 제외하고 실행
  --list              모듈 목록만 출력하고 종료
  -h, --help          이 도움말 출력

--only/--skip 토큰은 번호 붙은 이름(10-go), 번호 없는 짧은 이름(go,
claude-tmp) 또는 그 부분문자열로 매칭된다. 매칭이 0개면 에러, 2개 이상이면
"모호함" 에러로 중단한다(예: --only tmp는 40-tmp-builds/50-claude-tmp 둘
다에 걸려 에러).

모듈 목록:
EOF
    local f
    for f in $MODULE_FILES; do
        printf '  %-22s %s\n' "$(module_stem "$f")" "$(module_desc "$f")"
    done
}

# ---- 옵션 파싱 ---------------------------------------------------------------
OPT_DRY_RUN=0
OPT_YES=0
OPT_ONLY=""
OPT_SKIP=""
OPT_LIST=0

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) OPT_DRY_RUN=1 ;;
        -y|--yes) OPT_YES=1 ;;
        --only)
            shift
            if [ $# -eq 0 ] || [ -z "${1:-}" ]; then
                warn "--only 에는 값이 필요합니다 (예: --only go,pnpm)"
                exit 1
            fi
            OPT_ONLY="$1"
            ;;
        --only=*)
            OPT_ONLY="${1#--only=}"
            if [ -z "$OPT_ONLY" ]; then
                warn "--only= 값이 비어 있습니다"
                exit 1
            fi
            ;;
        --skip)
            shift
            if [ $# -eq 0 ] || [ -z "${1:-}" ]; then
                warn "--skip 에는 값이 필요합니다 (예: --skip docker)"
                exit 1
            fi
            OPT_SKIP="$1"
            ;;
        --skip=*)
            OPT_SKIP="${1#--skip=}"
            if [ -z "$OPT_SKIP" ]; then
                warn "--skip= 값이 비어 있습니다"
                exit 1
            fi
            ;;
        --list) OPT_LIST=1 ;;
        -h|--help) usage; exit 0 ;;
        *) warn "알 수 없는 옵션: $1"; usage; exit 1 ;;
    esac
    shift
done

# resolve_token <token> — token과 매칭되는 모듈 stem들을 개행으로 출력.
# 우선순위: (1) stem 또는 short 이름과 정확히 일치하는 것이 있으면 그것만
# 반환. (2) 없으면 stem 또는 short 이름에 부분문자열로 포함되는 모든
# 모듈을 반환(0개/여러개일 수 있음 — 호출부가 개수를 보고 에러 처리).
resolve_token() {
    local tok="$1"
    local f stem short
    local exact="" subs=""
    for f in $MODULE_FILES; do
        stem="$(module_stem "$f")"
        short="$(module_short "$stem")"
        if [ "$tok" = "$stem" ] || [ "$tok" = "$short" ]; then
            case "$exact" in
                *"|${stem}|"*) : ;;
                *) exact="${exact}|${stem}|" ;;
            esac
        fi
        case "$stem" in
            *"$tok"*)
                case "$subs" in
                    *"|${stem}|"*) : ;;
                    *) subs="${subs}|${stem}|" ;;
                esac
                ;;
        esac
        case "$short" in
            *"$tok"*)
                case "$subs" in
                    *"|${stem}|"*) : ;;
                    *) subs="${subs}|${stem}|" ;;
                esac
                ;;
        esac
    done
    if [ -n "$exact" ]; then
        printf '%s' "$exact" | tr '|' '\n' | sed '/^$/d'
    else
        printf '%s' "$subs" | tr '|' '\n' | sed '/^$/d'
    fi
}

# resolve_filter_tokens <csv> <label> <outvar> — csv의 각 토큰을 정확히
# 하나의 모듈로 해석하지 못하면(매칭 0개 또는 모호함) 에러 메시지를 내고
# exit 1로 스크립트를 중단한다. 성공하면 매칭된 stem들을(공백 구분)
# outvar 이름의 변수에 담는다.
#
# 주의: 반드시 command substitution($(...)) 없이 "직접" 호출해야 한다.
# $(...) 안에서 부르면 exit 1이 그 서브셸만 끝내고 메인 스크립트는
# 빈 결과를 든 채 계속 진행해버린다(실제로 이 버그로 --only tmp 같은
# 모호한 토큰이 조용히 무시되고 전체 모듈이 선택되는 사고가 있었다).
resolve_filter_tokens() {
    local csv="$1"
    local label="$2"
    local outvar="$3"
    local tok matches count result=""
    # ','로만 나눈다. "for tok in $(...)" 식(단어분리+글롭 확장)은 쓰지
    # 않는다 — cwd에 토큰과 이름이 겹치는 파일이 있으면(예: --only '*'
    # 인데 cwd에 "docker"라는 파일이 있는 경우) 그 파일명이 끼어들어와
    # 전혀 다른 모듈이 선택되는 사고가 재현됐다. read -ra는 글롭을
    # 하지 않으므로 안전하다.
    local -a toks
    IFS=',' read -ra toks <<< "$csv"
    for tok in "${toks[@]}"; do
        [ -z "$tok" ] && continue
        matches="$(resolve_token "$tok")"
        count=$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')
        if [ "$count" -eq 0 ]; then
            warn "$label: '$tok' 에 매칭되는 모듈이 없음"
            exit 1
        elif [ "$count" -gt 1 ]; then
            warn "$label: '$tok' 이 여러 모듈에 매칭되어 모호함: $(printf '%s' "$matches" | tr '\n' ' ')"
            exit 1
        fi
        result="${result}${matches} "
    done
    # "--only ," 처럼 토큰이 전부 비면 빈 결과가 "필터 없음"으로 해석되어
    # 전체 모듈이 선택된다 — 에러로 막는다.
    if [ -z "$result" ]; then
        warn "$label: 유효한 모듈 이름이 없음 ('$csv')"
        exit 1
    fi
    eval "$outvar=\"\$result\""
}

if [ "$OPT_LIST" = "1" ]; then
    usage
    exit 0
fi

RESOLVED_ONLY=""
if [ -n "$OPT_ONLY" ]; then
    resolve_filter_tokens "$OPT_ONLY" "--only" RESOLVED_ONLY
fi
RESOLVED_SKIP=""
if [ -n "$OPT_SKIP" ]; then
    resolve_filter_tokens "$OPT_SKIP" "--skip" RESOLVED_SKIP
fi

stem_in_list() {
    local needle="$1"
    local hay="$2"
    case " $hay " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---- 실행할 모듈 목록 결정 -----------------------------------------------------
SELECTED=""
for f in $MODULE_FILES; do
    stem="$(module_stem "$f")"
    if [ -n "$RESOLVED_ONLY" ] && ! stem_in_list "$stem" "$RESOLVED_ONLY"; then
        continue
    fi
    if [ -n "$RESOLVED_SKIP" ] && stem_in_list "$stem" "$RESOLVED_SKIP"; then
        continue
    fi
    SELECTED="${SELECTED}${f} "
done

if [ -z "$SELECTED" ]; then
    warn "선택된 모듈이 없음 (--only/--skip 옵션 확인)"
    exit 1
fi

# ---- 임시 파일 -----------------------------------------------------------------
RESULTS_FILE=$(mktemp "${TMPDIR:-/tmp}/clean-results.XXXXXX") || {
    warn "mktemp 실패 — 임시 결과 파일을 만들 수 없어 중단"
    exit 1
}
trap 'rm -f "$RESULTS_FILE"' EXIT

# ---- dry-run 미리보기(항상 계산: 기본 모드의 확인 문구에 필요) -----------------------
preview() {
    log "실행 대상 모듈:"
    local f stem
    for f in $SELECTED; do
        stem="$(module_stem "$f")"
        printf '  - %-18s %s\n' "$stem" "$(module_desc "$f")"
    done
}

# 모듈을 실행하고, 일반 로그는 실시간으로 화면에 그대로 보여주되(tee) 마지막
# RESULT: 줄은 화면에 띄우지 않고 RESULTS_FILE에만 조용히 적립한다(요약
# 표에서 사용). 모듈이 죽거나 RESULT: 줄을 못 남기면 FAIL로 표시한다 —
# 조용히 표에서 빠지는 것보다 실패가 눈에 보이는 게 안전하다.
run_module() {
    local f="$1"
    local mode="$2" # dryrun | real
    local path="$MOD_DIR/$f"
    local stem
    stem="$(module_stem "$f")"

    if [ ! -f "$path" ]; then
        warn "모듈 파일 없음: $path"
        printf 'RESULT:%s:0:FAIL\n' "$stem" >> "$RESULTS_FILE"
        return 0
    fi

    local mod_out
    mod_out=$(mktemp "${TMPDIR:-/tmp}/clean-mod.XXXXXX") || {
        warn "$stem: mktemp 실패로 실행 못함"
        printf 'RESULT:%s:0:FAIL\n' "$stem" >> "$RESULTS_FILE"
        return 0
    }

    if [ "$mode" = "dryrun" ]; then
        DRY_RUN=1 bash "$path" --dry-run 2>&1 | tee "$mod_out" | grep -v '^RESULT:'
    else
        bash "$path" 2>&1 | tee "$mod_out" | grep -v '^RESULT:'
    fi

    local result_line
    result_line=$(grep '^RESULT:' "$mod_out" | tail -1)
    rm -f "$mod_out"

    if [ -n "$result_line" ]; then
        printf '%s\n' "$result_line" >> "$RESULTS_FILE"
    else
        warn "$stem: RESULT 줄을 남기지 못함 — FAIL로 표시"
        printf 'RESULT:%s:0:FAIL\n' "$stem" >> "$RESULTS_FILE"
    fi
}

# RESULTS_FILE에 모인 RESULT 줄을 모듈별 표로 찍는다. real 모드(확보량)와
# dry-run(예상 확보량)이 같은 표기 규칙을 쓰도록 한 곳에 둔다.
print_result_table() {
    grep '^RESULT:' "$RESULTS_FILE" | while IFS=: read -r _ mod kb status; do
        case "$status" in
            skip) printf '  %-20s skip\n' "$mod" ;;
            FAIL) printf '  %-20s FAIL (모듈이 RESULT를 못 남김 — 위 로그 확인)\n' "$mod" ;;
            *) printf '  %-20s %s\n' "$mod" "$(human "${kb:-0}")" ;;
        esac
    done
}

# ---- 모드별 진행 ------------------------------------------------------------

if [ "$OPT_DRY_RUN" = "1" ]; then
    log "=== dry-run 모드: 아무것도 지우지 않습니다 ==="
    preview
    echo
    for f in $SELECTED; do
        log "--- $(module_stem "$f") ---"
        run_module "$f" dryrun
        echo
    done
    # dry-run도 끝에 표를 낸다 — 예전에는 모듈 로그만 흘러가고 끝나서,
    # 실행 전에 "어느 모듈이 얼마나"를 한눈에 볼 방법이 없었다. 값은
    # 모듈이 낸 추정치 그대로이고, 일부 모듈(pnpm, brew 등)은 상한이다.
    log "=== 모듈별 예상 확보량 (dry-run 추정, 일부 모듈은 상한) ==="
    print_result_table
    log ""
    log "=== 현재 여유공간 ==="
    log "  $(human "$(free_kb)")"
    log ""
    log "dry-run 종료. 실제 삭제는 수행하지 않았습니다."
    exit 0
fi

log "=== 디스크 정리 ==="
preview

if [ "$OPT_YES" != "1" ]; then
    echo
    log "먼저 dry-run으로 예상 확보량을 계산합니다..."
    tmp_preview=$(mktemp "${TMPDIR:-/tmp}/clean-preview.XXXXXX") || {
        warn "mktemp 실패 — 중단"
        exit 1
    }
    for f in $SELECTED; do
        line=$(DRY_RUN=1 bash "$MOD_DIR/$f" --dry-run 2>/dev/null | grep '^RESULT:' | tail -1)
        stem="$(module_stem "$f")"
        kb="0"
        status="FAIL"
        if [ -n "$line" ]; then
            kb=$(printf '%s' "$line" | awk -F: '{print $3}')
            status=$(printf '%s' "$line" | awk -F: '{print $4}')
        fi
        if [ "$status" = "FAIL" ]; then
            printf '%-20s FAIL (dry-run에서 RESULT 없음)\n' "$stem" >> "$tmp_preview"
        else
            printf '%-20s 예상 확보량 %s\n' "$stem" "$(human "${kb:-0}")" >> "$tmp_preview"
        fi
    done
    cat "$tmp_preview"
    rm -f "$tmp_preview"
    echo
    printf '위 모듈들을 실제로 실행할까요? [y/N] '
    read -r answer
    case "$answer" in
        y|Y|yes|YES) : ;;
        *) log "취소했습니다."; exit 0 ;;
    esac
fi

before_free=$(free_kb)
echo
log "=== 실행 시작 ==="
for f in $SELECTED; do
    log "--- $(module_stem "$f") ---"
    run_module "$f" real
    echo
done
after_free=$(free_kb)

# ---- 결과 표 -----------------------------------------------------------------
log "=== 모듈별 확보량 ==="
print_result_table

log ""
log "=== 전체 여유공간 ==="
log "  이전: $(human "$before_free")"
log "  이후: $(human "$after_free")"
log "  증가: $(human "$((after_free - before_free))")"
