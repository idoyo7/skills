#!/usr/bin/env bash
# clean_mac 스크립트 회귀 테스트. LLM·네트워크·실제 도구 호출 없음. bash 3.2 호환.
#
# 이 스크립트가 시험하는 대상은 rm -rfx 로 복구 불가능하게 지운다. 2026-09-29에
# 가짜 트리로 시험하려던 real 실행이 실제 루트(/private/tmp/claude-<uid>)에서
# 돌아 다른 세션의 스크래치패드를 지운 사고가 있었다. 그래서 real 모드는 아래가
# 전부 성립할 때만 돈다 — 하나라도 어긋나면 아무것도 실행하지 않고 중단한다(99).
#
#   1) 모든 실행은 sbx() 를 거친다. sbx 는 env -i 로 환경을 비우고 HOME·TMPDIR·
#      스캔/삭제 루트(TMP_BUILDS_ROOT, CLAUDE_TMP_ROOT, NODE_MODULES_ROOTS)를
#      mktemp 샌드박스 아래로만 준다. 밖을 가리키는 값이 끼면 중단한다.
#      50-claude-tmp 가 읽기만 하는 대화 기록 디렉터리(CLAUDE_TMP_PROJECTS_DIR)도
#      샌드박스 안의 가짜 트리로 준다 — 실제 ~/.claude/projects 는 읽지도 않는다.
#   2) PATH 는 샌드박스 안의 두 디렉터리뿐이다. bin/ 은 가짜 go·pnpm·npm·pip3·
#      brew·docker, sysbin/ 은 가짜 lsof·pgrep 과 시스템 도구 심링크다. 실제
#      go/npm/docker/brew 는 PATH 에 아예 없다.
#   3) CLEAN_SANDBOX_ROOT 를 항상 설정한다(lib.sh safe_rm 이 그 밖을 거부).
#   4) sysbin/rm 은 래퍼다. 샌드박스 밖 경로가 인자로 오면 지우지 않고 기록한다.
#      끝에서 그 기록이 비어 있는지 본다.
#   5) 시험 대상 스크립트에 루트 오버라이드와 샌드박스 가드가 실제로 들어 있는지
#      먼저 확인한다(없는 사본을 가리키면 env 를 줘도 실제 루트를 훑는다).
#
# 다른 사본을 시험하려면 CLEAN_MAC_SCRIPTS=<scripts 디렉터리> 로 준다(회귀 테스트가
# 수정 전 로직에서 실제로 실패하는지 확인할 때 쓴다).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
SCRIPTS="${CLEAN_MAC_SCRIPTS:-$HERE/../scripts}"
SCRIPTS="$(cd "$SCRIPTS" 2>/dev/null && pwd -P)" || { echo "ABORT: scripts 디렉터리 없음" >&2; exit 99; }
CLEAN="$SCRIPTS/clean.sh"
MOD="$SCRIPTS/clean.d"

REAL_HOME="$HOME"
REAL_USER="$(/usr/bin/id -un)"
PASS=0; FAIL=0; SKIPPED=0; DONE=0
SB=""

ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
note() { SKIPPED=$((SKIPPED+1)); echo "  skip: $1"; }

# abort 는 반드시 메인 셸에서 불려야 한다($(...) 안이면 그 서브셸만 끝난다).
# 그래서 sbx 를 $(...) 로 감싸 부르지 않고 run() 이 파일로 출력을 받는다. 혹시
# 서브셸에서 불려도 메인이 멈추도록 TERM 도 보낸다.
abort() {
    echo "ABORT: $*" >&2
    echo "ABORT: 안전 조건이 어긋나 아무것도 더 실행하지 않고 중단합니다." >&2
    kill -TERM $$ 2>/dev/null
    exit 99
}

cleanup() {
    local rc=$?
    case "$SB" in
        */clean_mac-test.??????)
            if [ -d "$SB" ]; then
                # find 실패 시험이 chmod 000 디렉터리를 만든다. 시험 도중에 끊겨도
                # 치울 수 있게 권한부터 되돌린다(chmod -R u+w 는 r·x 가 없는
                # 디렉터리 아래로 못 내려간다).
                /usr/bin/find "$SB" -type d ! -perm -u+rwx -exec /bin/chmod u+rwx {} \; 2>/dev/null
                /bin/chmod -R u+w "$SB" 2>/dev/null
                /bin/rm -rf "$SB"
            fi
            ;;
    esac
    if [ "$DONE" != "1" ] && [ "$rc" -eq 0 ]; then
        echo "FAIL: 하네스가 끝까지 돌지 못했습니다." >&2
        rc=1
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 99' TERM

# ---- 샌드박스 ---------------------------------------------------------------
# macOS 사용자별 임시 디렉터리(/var/folders/...)에 만든다. $TMPDIR 를 그대로 믿지
# 않는다 — /private/tmp/claude-<uid> 아래를 가리키는 세션이 있을 수 있다.
BASE="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR 2>/dev/null)"
[ -d "$BASE" ] || BASE="${TMPDIR:-/tmp}"
SB="$(/usr/bin/mktemp -d "${BASE%/}/clean_mac-test.XXXXXX")" || abort "mktemp 실패"
SB="$(cd "$SB" && pwd -P)" || abort "샌드박스 실경로 확인 실패"

SBHOME="$SB/home"
TMPB="$SB/tmproot"
CT="$SB/claude-tmp"
PJ="$SB/projects"             # 가짜 대화 기록 디렉터리(~/.claude/projects 자리)
NM="$SB/nmroot"
CFG="$SB/shimcfg"
SHIMLOG="$SB/shim.log"
OUTF="$SB/out.txt"
RMREFUSED="$SB/rm-refused.log"
P_FULL="$SB/bin:$SB/sysbin"   # 가짜 도구 있음
P_BARE="$SB/sysbin"           # go/pnpm/npm/pip3/brew/docker 없음
RC=0

under_sb() {
    case "/$1/" in */../*|*/./*) return 1 ;; esac
    case "$1" in "$SB"/*) return 0 ;; *) return 1 ;; esac
}

colon_all_under_sb() {
    local raw="$1" old_ifs="$IFS" p
    [ -z "$raw" ] && return 0
    IFS=':'
    # shellcheck disable=SC2086
    set -- $raw
    IFS="$old_ifs"
    for p in "$@"; do
        under_sb "$p" || return 1
    done
    return 0
}

# 샌드박스 자체가 믿을 만한 위치인지. sbx 가 부를 때마다 다시 본다.
guard_static() {
    case "$SB" in
        */clean_mac-test.??????) : ;;
        *) abort "샌드박스 경로 형태가 다름: '$SB'" ;;
    esac
    case "$SB" in
        *[!A-Za-z0-9._/-]*) abort "샌드박스 경로에 예상 밖 문자: '$SB'" ;;
    esac
    case "$SB/" in
        "$REAL_HOME"/*) abort "샌드박스가 실제 HOME 아래: $SB" ;;
        /private/tmp/claude-*|/tmp/claude-*) abort "샌드박스가 Claude 세션 임시 루트 아래: $SB" ;;
    esac
    [ -d "$SB" ] || abort "샌드박스 디렉터리 없음: $SB"
    [ "$SBHOME" = "$SB/home" ] || abort "HOME 이 샌드박스 밖: $SBHOME"
    if ! under_sb "$TMPB" || ! under_sb "$CT" || ! under_sb "$NM" || ! under_sb "$PJ"; then
        abort "스캔 루트가 샌드박스 밖"
    fi
    case "$SCRIPTS" in
        "$REAL_HOME/src") abort "원본 스크립트(~/src)는 시험 대상이 아님" ;;
    esac
}

# sbx [VAR=값 ...] <명령...> — 비운 환경 + 샌드박스 값으로만 실행한다.
sbx() {
    guard_static
    local a v
    for a in "$@"; do
        case "$a" in
            HOME=*|TMPDIR=*|TMP_BUILDS_ROOT=*|CLAUDE_TMP_ROOT=*)
                under_sb "${a#*=}" || abort "sbx: 샌드박스 밖 값: $a"
                ;;
            CLEAN_SANDBOX_ROOT=*)
                # 가드 자체를 시험할 때만 바꾼다. 절대경로면 샌드박스 안이어야 한다.
                # (상대경로는 가드가 전부 거부하는지 보는 용도다.)
                v="${a#*=}"
                case "$v" in
                    /*) [ "$v" = "$SB" ] || under_sb "$v" || abort "sbx: 샌드박스 밖 값: $a" ;;
                esac
                ;;
            CLAUDE_TMP_PROJECTS_DIR=*|CLAUDE_CONFIG_DIR=*)
                # 읽기만 하는 경로지만 실제 ~/.claude/projects 를 읽을 이유가 없다.
                # 절대경로면 샌드박스 안이어야 한다(상대경로는 모듈이 거부하는지
                # 보는 용도다). CLAUDE_CONFIG_DIR 은 모듈이 그 아래 projects 를
                # 대화 기록 디렉터리로 같이 읽는다 — 기본 환경에는 넣지 않는다.
                v="${a#*=}"
                case "$v" in
                    /*) under_sb "$v" || abort "sbx: 샌드박스 밖 값: $a" ;;
                esac
                ;;
            NODE_MODULES_ROOTS=*|PATH=*)
                colon_all_under_sb "${a#*=}" || abort "sbx: 샌드박스 밖 값: $a"
                ;;
            [A-Za-z_]*=*) : ;;
            *) break ;;
        esac
    done
    /usr/bin/env -i \
        PATH="$P_FULL" HOME="$SBHOME" USER="$REAL_USER" LOGNAME="$REAL_USER" \
        TMPDIR="$SB/tmp" LANG=en_US.UTF-8 \
        CLEAN_SANDBOX_ROOT="$SB" TMP_BUILDS_ROOT="$TMPB" \
        CLAUDE_TMP_ROOT="$CT" NODE_MODULES_ROOTS="$NM" \
        CLAUDE_TMP_PROJECTS_DIR="$PJ" \
        "$@"
}

# run [VAR=값 ...] <명령...> — stdin 은 /dev/null(비TTY). 결과: RC, $OUTF(stdout+stderr).
run() {
    sbx "$@" >"$OUTF" 2>&1 </dev/null
    RC=$?
}
run_in() {
    local inf="$1"
    shift
    sbx "$@" >"$OUTF" 2>&1 <"$inf"
    RC=$?
}
# run_nowrite <스크립트> VAR=값 [VAR=값 ...] — 파일에 한 바이트도 못 쓰는 상태로
# 스크립트를 돌린다(SIGXFSZ 무시 + ulimit -f 0). 꽉 찬 디스크에서 write 가 실패하는
# 것과 같은 분기다. bash 3.2 는 here-document 를 임시 파일에 쓰므로, 이 상태에서는
# here-document 로 읽는 루프가 한 번도 돌지 않는다. 출력은 파이프로 받는다 — 제한은
# 자식에만 걸리고 파이프 건너편의 cat 은 평소대로 쓴다. clean.sh 는 결과 임시 파일을
# 써야 해서 이 상태로는 못 돌린다. 모듈 파일을 직접 부른다(DRY_RUN 을 안 주면 real).
run_nowrite() {
    local script="$1"
    shift
    # shellcheck disable=SC2016
    sbx "$@" bash -c 'trap "" XFSZ; ulimit -f 0 || exit 98; exec bash "$1"' _ "$script" 2>&1 </dev/null | /bin/cat > "$OUTF"
    RC=${PIPESTATUS[0]}
}

# ---- 단언 -------------------------------------------------------------------
# 파이프 뒤 grep -q 로 판정하지 않는다(pipefail + SIGPIPE 로 결과가 뒤집히거나
# 앞 명령의 실패가 묻힌다). 출력은 파일로 받고 파일에 직접 grep 한다.
out_has() { /usr/bin/grep -qF -- "$1" "$OUTF"; }
out_re()  { /usr/bin/grep -qE -- "$1" "$OUTF"; }
t_has()    { if out_has "$2"; then ok "$1"; else fail "$1 — 출력에 없음: $2"; fi; }
t_hasnt()  { if out_has "$2"; then fail "$1 — 출력에 있으면 안 됨: $2"; else ok "$1"; fi; }
t_re()     { if out_re "$2"; then ok "$1"; else fail "$1 — 출력에 패턴 없음: $2"; fi; }
t_rc()     { if [ "$RC" = "$2" ]; then ok "$1"; else fail "$1 — rc=$RC (기대 $2)"; fi; }
t_exists() { if [ -e "$2" ] || [ -L "$2" ]; then ok "$1"; else fail "$1 — 없음: $2"; fi; }
t_gone()   { if [ ! -e "$2" ] && [ ! -L "$2" ]; then ok "$1"; else fail "$1 — 남아 있음: $2"; fi; }
t_eq()     { if [ "$2" = "$3" ]; then ok "$1"; else fail "$1 — 실제 '$2' / 기대 '$3'"; fi; }
# t_line <이름> <조각1> <조각2> — 두 조각이 출력의 "같은 줄"에 있는가(후보 줄에 붙는
# 대화 기록 시각처럼, 어느 대상의 정보인지가 중요한 경우).
t_line() {
    local l
    l="$(/usr/bin/grep -F -- "$2" "$OUTF")"
    case "$l" in
        *"$3"*) ok "$1" ;;
        *) fail "$1 — '$2' 줄에 없음: $3" ;;
    esac
}
shim_has()   { if /usr/bin/grep -qF -- "$2" "$SHIMLOG"; then ok "$1"; else fail "$1 — 호출 기록에 없음: $2"; fi; }
shim_hasnt() { if /usr/bin/grep -qF -- "$2" "$SHIMLOG"; then fail "$1 — 호출되면 안 됨: $2"; else ok "$1"; fi; }
shim_reset() { : > "$SHIMLOG"; }

DESTRUCTIVE=":: clean -cache|:: clean -modcache|:: store prune|:: cache clean --force|:: cache purge|:: cleanup -s|:: builder prune|:: image prune"
no_destructive_calls() {
    local old_ifs="$IFS" pat bad=""
    IFS='|'
    # shellcheck disable=SC2086
    set -- $DESTRUCTIVE
    IFS="$old_ifs"
    for pat in "$@"; do
        if /usr/bin/grep -qF -- "$pat" "$SHIMLOG"; then bad="$bad [$pat]"; fi
    done
    if [ -z "$bad" ]; then ok "$LABEL"; else fail "$LABEL — 정리 명령이 호출됨:$bad"; fi
}

# ---- 시각 조작 ---------------------------------------------------------------
stamp() { /bin/date -v-"$1"H +%Y%m%d%H%M.%S; }                     # N시간 전
age_tree() { /usr/bin/find "$2" -depth -exec /usr/bin/touch -h -t "$(stamp "$1")" {} +; }
age_one()  { /usr/bin/touch -h -t "$(stamp "$1")" "$2"; }

# unlock_tree <경로> — chmod 000 으로 잠근 디렉터리의 권한을 되돌린다. 심링크는
# 따라가지 않는다(find 기본 동작). -exec ... \; 라서 내려가기 전에 풀린다.
unlock_tree() {
    under_sb "$1" || abort "unlock_tree: 샌드박스 밖: $1"
    [ -d "$1" ] && [ ! -L "$1" ] || return 0
    /usr/bin/find "$1" -type d ! -perm -u+rwx -exec /bin/chmod u+rwx {} \; 2>/dev/null
    return 0
}

reset_dir() {
    under_sb "$1" || abort "reset_dir: 샌드박스 밖: $1"
    if [ -e "$1" ] || [ -L "$1" ]; then
        unlock_tree "$1"
        /bin/chmod -R u+w "$1" 2>/dev/null
        "$SB/sysbin/rm" -rf "$1" || abort "reset_dir 실패: $1"
    fi
    /bin/mkdir -p "$1"
}

snapshot() {
    (cd "$SB" && /usr/bin/find home tmproot claude-tmp projects nmroot keep-target \
        -exec /usr/bin/stat -f '%N|%m|%z|%Lp|%HT' {} + 2>/dev/null | LC_ALL=C /usr/bin/sort)
}

# ---- 샌드박스 구성 ------------------------------------------------------------
guard_static
/bin/mkdir -p "$SB/bin" "$SB/sysbin" "$SB/tmp" "$SB/cwd" "$CFG" "$SBHOME" "$TMPB" "$CT" "$PJ" "$NM" "$SB/keep-target"
: > "$SHIMLOG"
: > "$RMREFUSED"

# 시스템 도구는 고정된 시스템 디렉터리에서만 찾아 심링크한다(homebrew 등은 안 본다).
for t in bash sh sed awk grep tr wc cat tee mktemp find du df stat perl id dirname \
         basename head tail xargs chmod sort ls date touch mkdir ln cp mv cut sleep; do
    src=""
    for d in /bin /usr/bin /sbin /usr/sbin; do
        if [ -x "$d/$t" ]; then src="$d/$t"; break; fi
    done
    [ -n "$src" ] || abort "시스템 도구 없음: $t"
    /bin/ln -s "$src" "$SB/sysbin/$t"
done

mkshim() {  # mkshim <디렉터리> <이름>  (본문은 stdin)
    {
        printf '#!/bin/bash\n'
        printf "SB='%s'\n" "$SB"
        # shellcheck disable=SC2016
        printf 'CFG="$SB/shimcfg"\nLOG="$SB/shim.log"\n'
        /bin/cat
    } > "$1/$2"
    /bin/chmod +x "$1/$2"
}

# rm 래퍼 — 샌드박스 밖 경로면 지우지 않고 기록만 남긴다.
mkshim "$SB/sysbin" rm <<'EOF'
for a in "$@"; do
    case "$a" in
        -*) continue ;;
    esac
    case "/$a/" in
        */../*|*/./*) printf 'REFUSED rm %s\n' "$*" >> "$SB/rm-refused.log"; exit 97 ;;
    esac
    case "$a" in
        "$SB"/*) : ;;
        *) printf 'REFUSED rm %s\n' "$*" >> "$SB/rm-refused.log"; exit 97 ;;
    esac
done
exec /bin/rm "$@"
EOF

mkshim "$SB/sysbin" lsof <<'EOF'
printf 'lsof cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
[ -e "$CFG/lsof_fail" ] && exit 1
printf 'p1\nfcwd\nn/\n'
[ -f "$CFG/lsof_extra" ] && /bin/cat "$CFG/lsof_extra"
exit 0
EOF

mkshim "$SB/sysbin" pgrep <<'EOF'
printf 'pgrep cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
case "$*" in
    "-x Google Chrome") if [ -e "$CFG/chrome_running" ]; then echo 4242; exit 0; fi; exit 1 ;;
    *) exit 1 ;;
esac
EOF

mkshim "$SB/bin" go <<'EOF'
printf 'go cwd=%s GOTOOLCHAIN=%s :: %s\n' "$PWD" "${GOTOOLCHAIN:-}" "$*" >> "$LOG"
case "$*" in
    "env GOCACHE") echo "$SB/home/Library/Caches/go-build" ;;
    "env GOMODCACHE") echo "$SB/home/go/pkg/mod" ;;
    "clean -cache") /bin/rm -rf "$SB/home/Library/Caches/go-build" ;;
    "clean -modcache") /bin/rm -rf "$SB/home/go/pkg/mod" ;;
esac
exit 0
EOF

mkshim "$SB/bin" pnpm <<'EOF'
printf 'pnpm cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
exit 0
EOF

mkshim "$SB/bin" npm <<'EOF'
printf 'npm cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
if [ -e "$CFG/npm_fail" ]; then echo "npm ERR! 가짜 실패" >&2; exit 1; fi
case "$*" in
    "cache clean --force") /bin/rm -rf "$SB/home/.npm/_cacache" ;;
esac
exit 0
EOF

mkshim "$SB/bin" pip3 <<'EOF'
printf 'pip3 cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
case "$*" in
    "cache dir") echo "$SB/home/Library/Caches/pip" ;;
esac
exit 0
EOF

mkshim "$SB/bin" brew <<'EOF'
printf 'brew cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
case "$*" in
    "--cache") echo "$SB/home/Library/Caches/Homebrew" ;;
    "cleanup -ns") echo "Would remove: 가짜 항목 (1 files, 1MB)" ;;
esac
exit 0
EOF

mkshim "$SB/bin" docker <<'EOF'
printf 'docker cwd=%s :: %s\n' "$PWD" "$*" >> "$LOG"
case "${1:-} ${2:-}" in
    "info "*) [ -e "$CFG/docker_info_fail" ] && exit 1; exit 0 ;;
    "context inspect")
        if [ -f "$CFG/docker_ctx_host" ]; then /bin/cat "$CFG/docker_ctx_host"; else echo "unix:///var/run/docker.sock"; fi
        ;;
    "system df")
        case "$*" in
            *--format*) printf 'Images\t1.5GB (50%%)\nContainers\t10MB (100%%)\nLocal Volumes\t2GB (100%%)\nBuild Cache\t512MB\n' ;;
            *) printf 'TYPE TOTAL ACTIVE SIZE RECLAIMABLE\nImages 3 1 3GB 1.5GB (50%%)\n' ;;
        esac
        ;;
    "builder prune") echo "Total reclaimed space: 512MB" ;;
    "image prune") echo "Total reclaimed space: 1.5GB" ;;
esac
exit 0
EOF

# stat 래퍼 — 평소 PATH 에는 없다. 마운트 가드를 시험할 때만 PATH 앞에 둔다.
# 샌드박스 안에서는 다른 디바이스(dmg·NFS)를 만들 수 없어서, 장치번호 조회
# (stat -f %d)에 한해 $CFG/fake_mounts 에 적힌 경로만 가짜 번호를 돌려준다.
/bin/mkdir -p "$SB/statbin"
mkshim "$SB/statbin" stat <<'EOF'
if [ "${1:-}" = "-f" ] && [ "${2:-}" = "%d" ] && [ -f "$CFG/fake_mounts" ]; then
    shift 2
    for p in "$@"; do
        if /usr/bin/grep -qxF -- "$p" "$CFG/fake_mounts"; then
            echo 99999999
        else
            /usr/bin/stat -f '%d' "$p" || exit 1
        fi
    done
    exit 0
fi
exec /usr/bin/stat "$@"
EOF
P_STAT="$SB/statbin:$P_FULL"  # 가짜 stat 을 앞에 둔 PATH

cd "$SB/cwd" || abort "cwd 이동 실패"

# ---- 하네스 자가 검사 ----------------------------------------------------------
echo "== 하네스 자가 검사 =="

# (a) 시험 대상에 루트 오버라이드와 샌드박스 가드가 들어 있는가. 없으면 env 를 줘도
#     실제 루트(/private/tmp, /private/tmp/claude-<uid>)를 훑는다 — 곧바로 중단.
if [ ! -f "$CLEAN" ] || [ ! -f "$MOD/lib.sh" ]; then abort "시험 대상 스크립트 없음: $SCRIPTS"; fi
/usr/bin/grep -q 'CLEAN_SANDBOX_ROOT' "$MOD/lib.sh" || abort "lib.sh 에 샌드박스 가드(CLEAN_SANDBOX_ROOT)가 없음"
/usr/bin/grep -q 'TMP_BUILDS_ROOT:-' "$MOD/40-tmp-builds.sh" || abort "40-tmp-builds 에 TMP_BUILDS_ROOT 오버라이드가 없음"
/usr/bin/grep -q 'CLAUDE_TMP_ROOT:-' "$MOD/50-claude-tmp.sh" || abort "50-claude-tmp 에 CLAUDE_TMP_ROOT 오버라이드가 없음"
ok "시험 대상에 루트 오버라이드·샌드박스 가드가 들어 있음"

# (b) 자식 프로세스가 실제로 받는 환경.
# shellcheck disable=SC2016
run bash -c '
    printf "HOME=%s\nTMPDIR=%s\nSBROOT=%s\nTMPB=%s\nCT=%s\nPJ=%s\nNM=%s\nPATH=%s\n" \
        "$HOME" "$TMPDIR" "$CLEAN_SANDBOX_ROOT" "$TMP_BUILDS_ROOT" "$CLAUDE_TMP_ROOT" "$CLAUDE_TMP_PROJECTS_DIR" "$NODE_MODULES_ROOTS" "$PATH"
    for t in go pnpm npm pip pip3 brew docker lsof pgrep rm; do
        printf "TOOL:%s=%s\n" "$t" "$(command -v "$t")"
    done
    printf "SESSION=%s%s\n" "${CLAUDE_CODE_SESSION_ID:-}" "${CLAUDE_SESSION_ID:-}"
    printf "DOCKER_HOST=%s\n" "${DOCKER_HOST:-}"
    printf "CLAUDE_CONFIG_DIR=%s\n" "${CLAUDE_CONFIG_DIR:-}"
'
[ "$RC" = "0" ] || abort "자식 환경 조사 실패(rc=$RC)"
while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
        HOME) [ "$val" = "$SBHOME" ] || abort "자식 HOME 이 샌드박스가 아님: $val" ;;
        TMPDIR) under_sb "$val" || abort "자식 TMPDIR 이 샌드박스 밖: $val" ;;
        SBROOT) [ "$val" = "$SB" ] || abort "자식 CLEAN_SANDBOX_ROOT 불일치: $val" ;;
        TMPB|CT|PJ) under_sb "$val" || abort "자식 스캔 루트가 샌드박스 밖: $line" ;;
        NM|PATH) colon_all_under_sb "$val" || abort "자식 $key 에 샌드박스 밖 경로: $val" ;;
        TOOL:pip) [ -z "$val" ] || under_sb "$val" || abort "실제 pip 이 PATH 에 있음: $val" ;;
        TOOL:*) under_sb "$val" || abort "가짜가 아닌 도구가 잡힘: $line" ;;
        SESSION|DOCKER_HOST|CLAUDE_CONFIG_DIR) [ -z "$val" ] || abort "자식 환경에 $key 가 새어 들어옴" ;;
        *) abort "자식 환경 조사 출력이 예상과 다름: $line" ;;
    esac
done < "$OUTF"
[ "$(/usr/bin/grep -c '' "$OUTF")" = "21" ] || abort "자식 환경 조사 줄 수가 다름"
ok "자식 환경: HOME·TMPDIR·스캔 루트·대화 기록 디렉터리·PATH 가 전부 샌드박스 안, 외부 도구는 전부 가짜"

# (c) rm 래퍼가 샌드박스 밖을 거부하는가(없는 경로로 확인 — 래퍼가 고장 나도 무해).
"$SB/sysbin/rm" -f "/clean_mac-test-probe-nonexistent/x" 2>/dev/null
rc=$?
if [ "$rc" != "97" ] || [ ! -s "$RMREFUSED" ]; then abort "rm 래퍼가 샌드박스 밖 경로를 거부하지 않음(rc=$rc)"; fi
: > "$RMREFUSED"
ok "rm 래퍼가 샌드박스 밖 경로를 거부"

# (d) 가드와 오버라이드가 실제로 듣는가 — dry-run 으로만 확인한다(안 들어도 삭제 없음).
/bin/mkdir -p "$SB/probe-in" "$SB/probe-out"
echo x > "$SB/probe-out/f"
# shellcheck disable=SC2016
run CLEAN_SANDBOX_ROOT="$SB/probe-in" DRY_RUN=1 bash -c '. "$1"; safe_rm "$2" "$3"' _ "$MOD/lib.sh" "$SB/probe-out/f" "$SB/probe-out"
if [ "$RC" = "0" ] || ! out_has "샌드박스" || [ ! -e "$SB/probe-out/f" ]; then
    abort "safe_rm 샌드박스 가드가 동작하지 않음"
fi
PROBE_UUID="aaaaaaaa-0000-0000-0000-000000000000"
/bin/mkdir -p "$TMPB/probe-verify" "$CT/proj/$PROBE_UUID"
echo x > "$TMPB/probe-verify/f"
echo x > "$CT/proj/$PROBE_UUID/f"
age_tree 240 "$TMPB"
age_tree 240 "$CT"
run DRY_RUN=1 bash "$MOD/40-tmp-builds.sh" --dry-run
out_has "[dry-run] rm -rfx $TMPB/probe-verify" || abort "40-tmp-builds 가 TMP_BUILDS_ROOT 를 따르지 않음"
run DRY_RUN=1 bash "$MOD/50-claude-tmp.sh" --dry-run
out_has "[dry-run] rm -rfx $CT/proj/$PROBE_UUID" || abort "50-claude-tmp 가 CLAUDE_TMP_ROOT 를 따르지 않음"
t_exists "오버라이드·가드 탐침은 dry-run 이라 아무것도 지우지 않음" "$CT/proj/$PROBE_UUID/f"
reset_dir "$TMPB"; reset_dir "$CT"; reset_dir "$PJ"; reset_dir "$SB/probe-in"; reset_dir "$SB/probe-out"

# (e) 단언 함수가 실패를 실패로 세는가(fail-open 방지).
echo "abc" > "$OUTF"
before_fail=$FAIL
t_has "x" "zzz" >/dev/null
t_hasnt "x" "abc" >/dev/null
t_exists "x" "$SB/없는-파일" >/dev/null
t_gone "x" "$SB/cwd" >/dev/null
RC=1; t_rc "x" 0 >/dev/null
t_eq "x" "a" "b" >/dev/null
caught=$((FAIL - before_fail))
FAIL=$before_fail
t_eq "단언 함수 6종이 어긋난 입력을 전부 실패로 센다" "$caught" "6"

# (f) run_nowrite 가 만드는 "파일을 못 쓰는 상태"에서 here-document 가 실제로
#     실패하는가. 이 조건이 안 서면(here-document 를 파이프로 넘기는 bash 등) 아래
#     run_nowrite 시험이 수정 전 코드에서도 통과해 버린다.
/bin/cat > "$SB/nowrite-probe.sh" <<'EOF'
n=0
while IFS= read -r _; do n=$((n + 1)); done <<EOT
a
b
EOT
echo "PROBE_LINES=$n"
echo x > "$CLEAN_SANDBOX_ROOT/nowrite-probe.out"
EOF
NOWRITE_OK=0
run_nowrite "$SB/nowrite-probe.sh" PROBE=1
if out_has "PROBE_LINES=0" && [ ! -s "$SB/nowrite-probe.out" ]; then
    NOWRITE_OK=1
    ok "run_nowrite: 파일 쓰기가 막히고 here-document 루프가 한 번도 돌지 않는다"
else
    note "이 bash 는 파일을 못 써도 here-document 가 실패하지 않아 run_nowrite 시험은 건너뜀"
fi

# ---- 픽스처 ------------------------------------------------------------------
mk_home_fixture() {
    reset_dir "$SBHOME"
    /bin/mkdir -p "$SBHOME/Library/Caches/go-build" "$SBHOME/go/pkg/mod" \
        "$SBHOME/Library/pnpm/store" "$SBHOME/Library/Caches/pnpm" \
        "$SBHOME/.npm/_cacache" "$SBHOME/Library/Caches/pip" \
        "$SBHOME/Library/Caches/Homebrew" "$SBHOME/Library/Caches/Google/Chrome" \
        "$SBHOME/.cache/opencode" "$SBHOME/Downloads"
    local d
    for d in Library/Caches/go-build go/pkg/mod Library/pnpm/store Library/Caches/pnpm \
             .npm/_cacache Library/Caches/pip Library/Caches/Homebrew \
             Library/Caches/Google/Chrome .cache/opencode Downloads; do
        /usr/bin/perl -e 'print "x" x 65536' > "$SBHOME/$d/blob"
    done
}

mk_tmp_fixture() {
    reset_dir "$TMPB"; reset_dir "$SB/keep-target"
    local d
    for d in old-verify recent2h-verify recent70h-verify aged80h-verify _site-old \
             claude-verify-old unrelated-old busy-verify fresh-verify top2d-verify; do
        /bin/mkdir -p "$TMPB/$d/sub"
        echo x > "$TMPB/$d/sub/f.txt"
    done
    echo keep > "$SB/keep-target/keep.txt"
    /bin/ln -s "$SB/keep-target" "$TMPB/link-verify"
    age_tree 240 "$TMPB"                             # 전부 10일 전
    age_one 2  "$TMPB/recent2h-verify/sub/f.txt"     # 최상위는 10일 전, 안의 파일은 2시간 전
    age_one 70 "$TMPB/recent70h-verify/sub/f.txt"    # 3일(72시간) 창 안
    age_one 80 "$TMPB/aged80h-verify/sub/f.txt"      # 창 밖
    # 최상위 디렉터리만 2일 전이고 안의 것은 전부 10일 전이다(오래된 파일을 옮겨
    # 넣은 경우). 안쪽 '최근 수정' 검사로는 못 걸러지고, 바깥 -mtime +N 필터가
    # 있어야만 후보에서 빠진다.
    age_one 48 "$TMPB/top2d-verify"
    age_tree 0 "$TMPB/fresh-verify"                  # 방금 만든 것
    printf 'n%s\n' "$TMPB/busy-verify/sub/f.txt" > "$CFG/lsof_extra"
}

U_CUR="11111111-1111-1111-1111-111111111111"   # 현재 세션(오래됨)
U_OLD="22222222-2222-2222-2222-222222222222"   # 오래된 다른 세션
U_REC="33333333-3333-3333-3333-333333333333"   # 1시간 전 수정
U_BSY="44444444-4444-4444-4444-444444444444"   # 프로세스가 사용 중
U_23H="55555555-5555-5555-5555-555555555555"   # 23시간 전 수정(24시간 창 안)
U_25H="66666666-6666-6666-6666-666666666666"   # 25시간 전 수정(창 밖)
mk_claude_fixture() {
    reset_dir "$CT"
    reset_dir "$PJ"     # 대화 기록 없음 — 아래 세션들은 스크래치패드 검사만으로 갈린다
    local u
    for u in "$U_CUR" "$U_OLD" "$U_REC" "$U_BSY" "$U_23H" "$U_25H"; do
        /bin/mkdir -p "$CT/-Users-x-proj/$u/scratchpad"
        echo x > "$CT/-Users-x-proj/$u/scratchpad/f.txt"
    done
    /bin/mkdir -p "$CT/-Users-x-proj/notes"
    echo x > "$CT/-Users-x-proj/notes/f.txt"
    age_tree 120 "$CT"                                              # 전부 5일 전
    age_one 1  "$CT/-Users-x-proj/$U_REC/scratchpad/f.txt"
    age_one 23 "$CT/-Users-x-proj/$U_23H/scratchpad/f.txt"
    age_one 25 "$CT/-Users-x-proj/$U_25H/scratchpad/f.txt"
    printf 'n%s\n' "$CT/-Users-x-proj/$U_BSY/scratchpad" > "$CFG/lsof_extra"
}

# 대화 기록·디렉터리 변경으로 "활동 중"을 알아보는지 보는 세션들. 스크래치패드의
# 일반 파일은 전부 5일 전이다 — 수정 전 판정(-type f -mmin)으로는 전부 후보였다.
U_TRC="77777777-7777-7777-7777-777777777777"   # 대화 기록 1시간 전
U_TRO="88888888-8888-8888-8888-888888888888"   # 대화 기록 3일 전(창 밖)
U_T23="99999999-9999-9999-9999-999999999999"   # 대화 기록 23시간 전(다른 프로젝트 디렉터리에 있음)
U_T25="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"   # 대화 기록 25시간 전(창 밖)
U_SUB="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"   # 본 기록은 3일 전, 서브에이전트 기록만 1시간 전
U_LNK="cccccccc-cccc-cccc-cccc-cccccccccccc"   # 심링크된 프로젝트 디렉터리 안의 1시간 전 기록
U_EMP="dddddddd-dddd-dddd-dddd-dddddddddddd"   # 방금 생긴 빈 디렉터리뿐
U_DIR="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"   # 하위 디렉터리 mtime 만 1시간 전
U_ERR="ffffffff-ffff-ffff-ffff-ffffffffffff"   # 읽을 수 없는 하위 디렉터리(find 실패)
mk_claude_activity_fixture() {
    mk_claude_fixture
    reset_dir "$SB/pj-elsewhere"
    local p="$CT/-Users-x-proj" j="$PJ/-Users-x-proj" u
    /bin/mkdir -p "$p/$U_DIR/scratchpad/newdir"
    for u in "$U_TRC" "$U_TRO" "$U_T23" "$U_T25" "$U_SUB" "$U_LNK" "$U_DIR"; do
        /bin/mkdir -p "$p/$u/scratchpad"
        echo x > "$p/$u/scratchpad/f.txt"
        age_tree 120 "$p/$u"                                        # 전부 5일 전
    done
    age_one 1  "$p/$U_DIR/scratchpad/newdir"                        # 디렉터리 mtime 만 최근
    /bin/mkdir "$p/$U_EMP"                                          # 방금 생긴 빈 세션

    /bin/mkdir -p "$j/$U_SUB/subagents" "$PJ/-Users-y-other"
    for u in "$U_TRC" "$U_TRO" "$U_T25" "$U_SUB"; do
        echo '{}' > "$j/$u.jsonl"
    done
    echo '{}' > "$PJ/-Users-y-other/$U_T23.jsonl"
    echo '{}' > "$j/$U_SUB/subagents/agent-a1.jsonl"
    echo '{}' > "$SB/pj-elsewhere/$U_LNK.jsonl"
    /bin/ln -s "$SB/pj-elsewhere" "$PJ/-Users-z-linked"
    # UUID 가 이름에 들어 있을 뿐인 다른 파일은 그 세션의 대화 기록이 아니다.
    echo '{}' > "$j/$U_OLD.jsonl.bak"
    echo '{}' > "$j/x$U_OLD.jsonl"
    age_tree 120 "$PJ"; age_tree 120 "$SB/pj-elsewhere"
    age_one 1  "$j/$U_TRC.jsonl"
    age_one 72 "$j/$U_TRO.jsonl"
    age_one 23 "$PJ/-Users-y-other/$U_T23.jsonl"
    age_one 25 "$j/$U_T25.jsonl"
    age_one 72 "$j/$U_SUB.jsonl"
    age_one 1  "$j/$U_SUB/subagents/agent-a1.jsonl"
    age_one 1  "$SB/pj-elsewhere/$U_LNK.jsonl"
    age_one 1  "$j/$U_OLD.jsonl.bak"
    age_one 1  "$j/x$U_OLD.jsonl"
}

mk_nm_fixture() {
    reset_dir "$NM"
    local p
    # 단일 프로젝트들
    for p in stale active day28 day31 gitonly nmrecent busy next; do
        /bin/mkdir -p "$NM/$p/src" "$NM/$p/node_modules/pkg"
        echo '{"name":"x"}' > "$NM/$p/package.json"
        echo x > "$NM/$p/src/a.js"
        echo x > "$NM/$p/node_modules/pkg/index.js"
    done
    /bin/mkdir -p "$NM/gitonly/.git" "$NM/next/.next/standalone/node_modules/pkg"
    echo x > "$NM/gitonly/.git/HEAD"
    echo x > "$NM/next/.next/standalone/server.js"
    echo x > "$NM/next/.next/standalone/node_modules/pkg/index.js"
    # 워크스페이스: 루트 기준으로 최근 수정을 본다
    /bin/mkdir -p "$NM/mono/node_modules/pkg" "$NM/mono/packages/a/node_modules/pkg" "$NM/mono/packages/b/node_modules/pkg"
    echo 'packages: ["packages/*"]' > "$NM/mono/pnpm-workspace.yaml"
    echo x > "$NM/mono/packages/a/index.js"
    echo x > "$NM/mono/packages/b/index.js"
    /bin/mkdir -p "$NM/monostale/node_modules/pkg" "$NM/monostale/packages/x/node_modules/pkg"
    echo '{"name":"m","workspaces":["packages/*"]}' > "$NM/monostale/package.json"
    echo x > "$NM/monostale/packages/x/index.js"
    # find -maxdepth 5 밖(깊이 6)
    /bin/mkdir -p "$NM/deep/a/b/c/d/node_modules/pkg"
    echo x > "$NM/deep/a/b/c/d/index.js"

    age_tree 1440 "$NM"                               # 전부 60일 전
    age_one 24  "$NM/active/src/a.js"                 # 하루 전 수정
    age_one 672 "$NM/day28/src/a.js"                  # 28일 전(30일 창 안)
    age_tree 744 "$NM/day31"                          # 31일 전(창 밖)
    age_one 1   "$NM/gitonly/.git/HEAD"               # .git 안의 최근 파일은 판정에서 빠진다
    age_one 1   "$NM/nmrecent/node_modules/pkg/index.js"  # node_modules 안도 빠진다
    age_one 24  "$NM/next/src/a.js"                   # next 프로젝트 자체는 활동 중
    age_one 24  "$NM/mono/packages/b/index.js"        # 워크스페이스의 한 패키지만 최근
    printf 'n%s\n' "$NM/busy/src" > "$CFG/lsof_extra"
}

clear_cfg() { reset_dir "$CFG"; }

BASIC="go,pnpm,npm,pip,brew,app-caches,tmp-builds,docker"   # SKILL.md 의 기본 세트

# ---- 옵션 파싱 ----------------------------------------------------------------
echo "== 옵션 파싱 =="
mk_home_fixture; mk_tmp_fixture; mk_claude_fixture; mk_nm_fixture; clear_cfg
SNAP0="$(snapshot)"
shim_reset

run bash "$CLEAN" --list
t_rc "--list 는 0 으로 끝난다" 0
n=$(/usr/bin/grep -cE '^  [0-9]{2}-[a-z-]+ ' "$OUTF")
t_eq "--list 가 모듈 11개를 보여준다" "$n" "11"
run bash "$CLEAN" -h
t_rc "-h 는 0 으로 끝난다" 0
t_has "-h 가 사용법을 보여준다" "사용법: clean.sh"

run bash "$CLEAN" --bogus
t_rc "알 수 없는 옵션은 1" 1
t_has "알 수 없는 옵션 메시지" "알 수 없는 옵션: --bogus"

run bash "$CLEAN" -y --only
t_rc "--only 값 누락은 1" 1
t_has "--only 값 누락 메시지" "--only 에는 값이 필요합니다"

run bash "$CLEAN" -y --only nosuch
t_rc "매칭 0개는 1" 1
t_has "매칭 0개 메시지" "'nosuch' 에 매칭되는 모듈이 없음"

run bash "$CLEAN" -y --only tmp
t_rc "모호한 토큰(--only tmp)은 1" 1
t_has "모호함 메시지" "'tmp' 이 여러 모듈에 매칭되어 모호함"
t_hasnt "모호한 토큰이면 아무 모듈도 시작하지 않는다" "=== 실행 시작 ==="

run bash "$CLEAN" -y --only ,
t_rc "--only , 는 1" 1
t_has "--only , 메시지" "유효한 모듈 이름이 없음"

run bash "$CLEAN" -y --skip nosuch
t_rc "--skip 매칭 0개도 1" 1

# cwd 에 토큰과 같은 이름의 파일이 있어도 글롭이 끼어들지 않는다.
: > "$SB/cwd/docker"; : > "$SB/cwd/10-go"
run bash "$CLEAN" -y --only '*'
t_rc "--only '*' 는 cwd 파일명으로 확장되지 않고 1" 1
t_has "--only '*' 메시지" "'*' 에 매칭되는 모듈이 없음"
t_hasnt "--only '*' 로 docker 가 선택되지 않는다" "70-docker"
/bin/rm -f "$SB/cwd/docker" "$SB/cwd/10-go"

LABEL="에러로 끝난 호출들은 정리 명령을 하나도 부르지 않았다"; no_destructive_calls
t_eq "에러로 끝난 호출들(-y 포함)은 파일을 하나도 건드리지 않았다" "$(snapshot)" "$SNAP0"

run bash "$CLEAN" --dry-run --skip docker
t_rc "--skip docker --dry-run 은 0" 0
t_has "--skip: 다른 모듈은 돈다" "--- 60-node-modules ---"
t_hasnt "--skip: 지정한 모듈은 빠진다" "70-docker"

run bash "$CLEAN" --dry-run --only=go --skip=docker
t_rc "--only=값 형태도 받는다" 0
t_has "--only=go 는 10-go 만" "--- 10-go ---"
t_hasnt "--only=go 에 pnpm 은 없다" "20-pnpm"

# SKILL.md 가 적는 기본 세트 토큰이 각각 한 모듈에만 걸리는가.
run bash "$CLEAN" --dry-run --only "$BASIC"
t_rc "기본 세트 토큰이 전부 유일하게 해석된다" 0
sel=$(/usr/bin/sed -n 's/^--- \(.*\) ---$/\1/p' "$OUTF" | /usr/bin/tr '\n' ' ')
t_eq "기본 세트 = 8개 모듈" "$sel" "10-go 20-pnpm 21-npm 22-pip 23-brew 30-app-caches 40-tmp-builds 70-docker "

# ---- RESULT 계약과 dry-run --------------------------------------------------------
echo "== RESULT 계약 / dry-run =="
for f in 10-go 20-pnpm 21-npm 22-pip 23-brew 30-app-caches 40-tmp-builds 50-claude-tmp 60-node-modules 70-docker 90-report; do
    for p in "$P_FULL" "$P_BARE"; do
        run PATH="$p" bash "$MOD/$f.sh" --dry-run
        n=$(/usr/bin/grep -c '^RESULT:' "$OUTF")
        if [ "$n" = "1" ] && out_re "^RESULT:${f}:[0-9]+:(dry|skip|ok)$"; then
            :
        else
            fail "$f: dry-run RESULT 가 정확히 한 줄이 아님(PATH=${p#"$SB"/}, ${n}줄)"
        fi
    done
done
ok "모듈 11개가 dry-run 에서 RESULT 를 정확히 한 줄 낸다(도구 있음/없음 모두)"

shim_reset
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run
t_rc "전체 dry-run 은 0" 0
t_eq "전체 dry-run 은 샌드박스의 파일을 하나도 바꾸지 않는다" "$(snapshot)" "$SNAP0"
LABEL="전체 dry-run 은 정리 명령을 부르지 않는다"; no_destructive_calls
shim_has "dry-run 에서도 brew cleanup -ns 는 실제로 실행된다" ":: cleanup -ns"
shim_has "dry-run 에서도 go env 는 실제로 실행된다" ":: env GOCACHE"
shim_has "dry-run 에서도 docker info 는 실제로 실행된다" "docker cwd=$SB/cwd :: info"
shim_has "dry-run 에서도 lsof 전체 덤프는 실제로 실행된다" ":: -b -w -Fn"
t_has "dry-run 요약 표 제목" "=== 모듈별 예상 확보량"
t_has "dry-run 이 현재 여유공간을 낸다" "=== 현재 여유공간 ==="
t_hasnt "dry-run 표에 FAIL 이 없다" "FAIL"
n=$(/usr/bin/sed -n '/=== 모듈별 예상 확보량/,/=== 현재 여유공간/p' "$OUTF" | /usr/bin/grep -cE '^  [0-9]{2}-[a-z-]+ +([0-9.]+(KB|MB|GB)|skip)$')
t_eq "dry-run 표에 모듈 11개가 전부 있다" "$n" "11"
t_re "dry-run 표: docker 예상치 = Images + Build Cache (2.00GB)" '^  70-docker +2\.00GB$'
t_has "dry-run: 현재 세션은 skip 으로 보고" "현재 실행 중인 세션이라 skip: $CT/-Users-x-proj/$U_CUR"

run PATH="$P_BARE" TMP_BUILDS_MIN_AGE_D=abc bash "$CLEAN" --dry-run --only go,tmp-builds
t_re "dry-run 표: 도구 없는 모듈은 skip" '^  10-go +skip$'
t_re "dry-run 표: RESULT 를 못 남긴 모듈은 FAIL" '^  40-tmp-builds +FAIL '

# ---- 비TTY 기본 모드 ------------------------------------------------------------
echo "== 비TTY 기본 모드 =="
shim_reset
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN"
t_rc "stdin 이 /dev/null 이면 0 으로 끝난다" 0
t_has "stdin 이 /dev/null 이면 취소로 끝난다" "취소했습니다."
t_hasnt "취소되면 실행 단계로 가지 않는다" "=== 실행 시작 ==="
t_eq "취소되면 아무것도 지우지 않는다" "$(snapshot)" "$SNAP0"
LABEL="취소되면 정리 명령을 부르지 않는다"; no_destructive_calls

echo n > "$SB/answer.txt"
run_in "$SB/answer.txt" bash "$CLEAN" --only tmp-builds
t_has "n 응답도 취소" "취소했습니다."
t_exists "n 응답이면 남는다" "$TMPB/old-verify"
echo y > "$SB/answer.txt"
run_in "$SB/answer.txt" bash "$CLEAN" --only tmp-builds
t_has "y 응답이면 실행한다" "=== 실행 시작 ==="
t_gone "y 응답이면 지운다" "$TMPB/old-verify"

# ---- safe_rm 가드 ---------------------------------------------------------------
echo "== safe_rm 가드 =="
SR="$SB/sr"
srm() { # srm [VAR=값 ...] -- <대상> [허용 접두]
    local envs=""
    while [ "$1" != "--" ]; do envs="$envs $1"; shift; done
    shift
    # shellcheck disable=SC2016,SC2086
    run $envs bash -c '. "$1"; shift; safe_rm "$@"' _ "$MOD/lib.sh" "$@"
}
mk_sr() {
    reset_dir "$SR"
    /bin/mkdir -p "$SR/allowed/dir/sub" "$SR/outside" "$SR/inner" "$SR/elsewhere" "$SR/linktarget" "$SBHOME/src" "$SB/cwd/rel"
    echo x > "$SR/allowed/f"; echo x > "$SR/allowed/dir/sub/g"; echo x > "$SR/outside/f"
    echo x > "$SR/inner/f"; echo x > "$SR/elsewhere/victim"; echo x > "$SR/linktarget/keep"
    echo x > "$SB/cwd/rel/f"; echo x > "$SBHOME/src/f"
    /bin/ln -s "$SR/linktarget" "$SR/allowed/lnk"
    /bin/ln -s "$SR/elsewhere" "$SR/inner/esc"
}
mk_sr

srm -- "rel/f" "rel"
t_rc "상대경로 거부" 1; t_exists "상대경로: 남는다" "$SB/cwd/rel/f"
srm -- "$SR/allowed/../allowed/f" "$SR/allowed"
t_rc "'..' 포함 경로 거부" 1; t_exists "'..': 남는다" "$SR/allowed/f"
srm -- "$SR/allowed/./f" "$SR/allowed"
t_rc "'.' 포함 경로 거부" 1
srm -- "$SBHOME" "$SB"
t_rc "\$HOME 자체 거부" 1; t_exists "\$HOME: 남는다" "$SBHOME/src/f"
srm -- "$SBHOME/" "$SB"
t_rc "\$HOME/ (후행 슬래시) 거부" 1
srm -- "$SBHOME/src" "$SB"
t_rc "\$HOME/src 거부" 1; t_exists "\$HOME/src: 남는다" "$SBHOME/src/f"
srm -- "$SR/outside/f" "$SR/allowed"
t_rc "허용 접두 밖 거부" 1; t_exists "허용 접두 밖: 남는다" "$SR/outside/f"
srm -- "$SR/allowed" "$SR/allowed"
t_rc "허용 접두 자신 거부" 1
srm -- "$SR/allowed/" "$SR/allowed/"
t_rc "허용 접두 자신(후행 슬래시) 거부" 1; t_exists "접두 자신: 남는다" "$SR/allowed/f"
srm -- "$SR/allowed-sibling" "$SR/allowed"
t_rc "접두와 이름만 겹치는 형제 경로 거부" 1
srm -- "$SR/allowed/f"
t_rc "허용 접두 없이는 거부" 1
srm -- "$SR/allowed/f" "/"
t_rc "허용 접두 '/' 거부" 1
srm -- "$SBHOME/src/f" "$SBHOME"
t_rc "허용 접두 \$HOME 거부" 1; t_exists "넓은 접두: 남는다" "$SBHOME/src/f"
srm -- "" "$SR/allowed"
t_rc "빈 경로 거부" 1

srm DRY_RUN=1 -- "$SR/allowed/f" "$SR/allowed"
t_rc "DRY_RUN=1 이면 0" 0; t_has "DRY_RUN=1 은 출력만" "[dry-run] rm -rfx $SR/allowed/f"
t_exists "DRY_RUN=1 은 지우지 않는다" "$SR/allowed/f"

srm DRY_RUN=1 -- "$SR/allowed/lnk" "$SR/allowed"
t_rc "심링크 dry-run 은 0" 0
t_has "심링크 dry-run 은 링크만 지운다고 알린다" "[dry-run] rm -f $SR/allowed/lnk (symlink)"
t_hasnt "심링크 dry-run 은 재귀 삭제(rm -rfx)로 알리지 않는다" "rm -rfx"
t_exists "심링크 dry-run 은 링크를 지우지 않는다" "$SR/allowed/lnk"
srm -- "$SR/allowed/lnk" "$SR/allowed"
t_rc "심링크 삭제는 0" 0
t_gone "심링크: 링크는 사라진다" "$SR/allowed/lnk"
t_exists "심링크: 대상 디렉터리의 내용은 남는다" "$SR/linktarget/keep"

# 샌드박스 가드
srm CLEAN_SANDBOX_ROOT="$SR/inner" -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: 밖의 대상 거부(허용 접두는 통과했어도)" 1
t_has "샌드박스 가드 메시지" "샌드박스"
t_exists "샌드박스 가드: 남는다" "$SR/allowed/f"
srm CLEAN_SANDBOX_ROOT="$SR/inner" -- "$SR/inner/esc/victim" "$SR/inner"
t_rc "샌드박스 가드: 안에 놓인 심링크 디렉터리를 거쳐 밖으로 나가는 경로 거부" 1
t_exists "샌드박스 가드(심링크 경유): 남는다" "$SR/elsewhere/victim"
srm CLEAN_SANDBOX_ROOT="$SR/inner" -- "$SR/inner" "$SR"
t_rc "샌드박스 가드: 샌드박스 루트 자신 거부" 1
srm CLEAN_SANDBOX_ROOT="$SR/inner" DRY_RUN=1 -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: dry-run 에서도 거부" 1
srm CLEAN_SANDBOX_ROOT="$SR/nope" -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: 없는 디렉터리가 값이면 전부 거부" 1
srm CLEAN_SANDBOX_ROOT="relative/dir" -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: 상대경로가 값이면 전부 거부" 1
t_exists "샌드박스 가드(잘못된 값): 남는다" "$SR/allowed/f"
# 빈 값으로 "설정된" 경우(mktemp 실패, 변수 이름 오타)에 가드가 꺼지면 안 된다.
srm CLEAN_SANDBOX_ROOT= -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: 빈 값으로 설정되면 전부 거부(가드가 꺼지지 않는다)" 1
t_has "샌드박스 가드(빈 값) 메시지" "CLEAN_SANDBOX_ROOT가 절대경로가 아니라 전부 거부"
t_exists "샌드박스 가드(빈 값): 남는다" "$SR/allowed/f"
srm CLEAN_SANDBOX_ROOT= DRY_RUN=1 -- "$SR/allowed/f" "$SR/allowed"
t_rc "샌드박스 가드: 빈 값이면 dry-run 에서도 거부" 1
srm CLEAN_SANDBOX_ROOT="$SR/inner" -- "$SR/inner/f" "$SR/inner"
t_rc "샌드박스 가드: 안의 대상은 지운다" 0; t_gone "샌드박스 가드: 안의 대상 삭제됨" "$SR/inner/f"

# 마운트 포인트 독립 가드(대상과 부모의 장치번호 비교). 가짜 stat 으로 대상만 다른
# 디바이스처럼 보이게 한다.
/bin/mkdir -p "$SR/allowed/vol/data"
echo x > "$SR/allowed/vol/data/f"
printf '%s\n' "$SR/allowed/vol" > "$CFG/fake_mounts"
srm PATH="$P_STAT" -- "$SR/allowed/vol" "$SR/allowed"
t_rc "마운트 가드: 대상의 장치번호가 부모와 다르면 거부" 1
t_has "마운트 가드 메시지" "마운트 포인트로 보여 거부(장치번호 불일치): $SR/allowed/vol"
t_exists "마운트 가드: 볼륨 내용이 남는다" "$SR/allowed/vol/data/f"
/bin/rm -f "$CFG/fake_mounts"
srm PATH="$P_STAT" -- "$SR/allowed/vol" "$SR/allowed"
t_rc "마운트 가드: 장치번호가 같으면 같은 대상을 지운다(대조군)" 0
t_gone "마운트 가드 대조군: 삭제됨" "$SR/allowed/vol"

# 정상 경로
/bin/chmod -R a-w "$SR/allowed/dir"
srm -- "$SR/allowed/dir" "$SR/allowed"
t_rc "쓰기 권한 없는 디렉터리도 지운다" 0; t_gone "읽기 전용 트리 삭제됨" "$SR/allowed/dir"
srm -- "$SR/allowed/f" "$SR/allowed/"
t_rc "허용 접두 아래 파일은 지운다" 0; t_gone "파일 삭제됨" "$SR/allowed/f"
srm -- "$SR/allowed/없는것" "$SR/allowed"
t_rc "없는 대상은 0(할 일 없음)" 0

# resolve_root_override (루트 오버라이드 검사)
rro() {
    # shellcheck disable=SC2016
    run bash -c '. "$1"; resolve_root_override TEST_ROOT "$2"' _ "$MOD/lib.sh" "$1"
}
bad=""
for v in "" "/" "rel/dir" "/a/../b" "/a/./b" "$SBHOME" "$SBHOME/" "$SBHOME/src" "/Users" "/Users/$REAL_USER" "/ab"; do
    rro "$v"
    [ "$RC" = "1" ] || bad="$bad [$v]"
done
if [ -z "$bad" ]; then ok "루트 오버라이드: 빈값·/·상대·'..'·\$HOME·\$HOME/src·/Users·짧은 경로 전부 거부"; else fail "루트 오버라이드가 받아들임:$bad"; fi
# 같은 디렉터리를 다르게 적은 값. 글자 비교로는 전부 통과했다.
/bin/ln -s "$SBHOME" "$SB/homelink"
/bin/ln -s "$SBHOME/src" "$SB/evelink"
bad=""
for v in "$SB//home" "$SB/homelink" "$SB/homelink/" "$SB/evelink"; do
    rro "$v"
    [ "$RC" = "1" ] || bad="$bad [$v]"
done
if [ -z "$bad" ]; then ok "루트 오버라이드: 연속 슬래시·\$HOME 을 가리키는 심링크·\$HOME/src 를 가리키는 심링크 거부"; else fail "루트 오버라이드가 받아들임:$bad"; fi
rro "$SB/homelink"
t_has "루트 오버라이드: 같은 디렉터리 판정 메시지" "와 같은 디렉터리라 거부"
if [ -d "$SB/HOME" ]; then   # 대소문자를 구분하지 않는 볼륨
    rro "$SB/HOME"
    t_rc "루트 오버라이드: 대소문자만 다른 \$HOME 거부" 1
else
    note "대소문자를 구분하는 볼륨이라 대소문자 변형 검사는 건너뜀"
fi
if [ -d "/System/Volumes/Data$SBHOME" ]; then   # firmlink 로 보이는 같은 디렉터리(stat 만 한다)
    rro "/System/Volumes/Data$SBHOME"
    t_rc "루트 오버라이드: /System/Volumes/Data 를 거친 \$HOME 거부" 1
else
    note "/System/Volumes/Data 경유 경로가 없어 firmlink 변형 검사는 건너뜀"
fi
/bin/ln -s "$TMPB" "$SB/tmplink"
rro "$SB/tmplink"
t_rc "루트 오버라이드: 위험하지 않은 디렉터리를 가리키는 심링크는 통과" 0
rro "$SB/없는-루트"
t_rc "루트 오버라이드: 없는 경로는 통과(모듈이 '없음'으로 skip)" 0
rro "$SB//없는-루트"
t_rc "루트 오버라이드: 연속 슬래시는 없는 경로여도 거부" 1
t_has "루트 오버라이드: 연속 슬래시 메시지" "연속 슬래시(//)가 있어 거부"
run TMP_BUILDS_ROOT="$SB/homelink" CLAUDE_TMP_ROOT="$SB/evelink" bash "$CLEAN" --dry-run --only tmp-builds,claude-tmp
t_re "모듈: \$HOME 을 가리키는 심링크 루트는 FAIL" '^  40-tmp-builds +FAIL '
t_re "모듈: \$HOME/src 를 가리키는 심링크 루트는 FAIL" '^  50-claude-tmp +FAIL '
/bin/rm -f "$SB/homelink" "$SB/evelink" "$SB/tmplink"

# age_value_ok (나이 임계값 env 검사)
avo() {
    # shellcheck disable=SC2016
    run bash -c '. "$1"; age_value_ok "$2" "$3"' _ "$MOD/lib.sh" "$1" "$2"
}
bad=""
for v in "" abc -1 1.5 " 3" 08 09 010 00 0x10 36501 99999 99999999999999999999 9223372036854775808; do
    avo "$v" 36500
    [ "$RC" = "1" ] || bad="$bad [$v]"
done
if [ -z "$bad" ]; then ok "나이 값: 빈값·비숫자·음수·앞자리 0(08, 010)·상한 초과·정수 범위 밖 전부 거부"; else fail "나이 값을 받아들임:$bad"; fi
bad=""
for v in 0 1 3 24 30 100 36500; do
    avo "$v" 36500
    [ "$RC" = "0" ] || bad="$bad [$v]"
done
if [ -z "$bad" ]; then ok "나이 값: 0 과 상한 이하의 10진 정수는 통과"; else fail "나이 값을 거부함:$bad"; fi

rro "/private/tmp"
t_rc "루트 오버라이드: 기본값 /private/tmp 통과" 0
t_eq "루트 오버라이드: 값을 그대로 돌려준다" "$(/bin/cat "$OUTF")" "/private/tmp"
rro "/private/tmp///"
t_eq "루트 오버라이드: 후행 슬래시를 뗀다" "$(/bin/cat "$OUTF")" "/private/tmp"

run TMP_BUILDS_ROOT="$SBHOME" CLAUDE_TMP_ROOT="$SBHOME/src" bash "$CLEAN" --dry-run --only tmp-builds,claude-tmp
t_re "모듈: 위험한 TMP_BUILDS_ROOT 는 FAIL 로 표시" '^  40-tmp-builds +FAIL '
t_re "모듈: 위험한 CLAUDE_TMP_ROOT 는 FAIL 로 표시" '^  50-claude-tmp +FAIL '

# ---- 40-tmp-builds ---------------------------------------------------------------
echo "== 40-tmp-builds: 보호 창(3일) =="
clear_cfg; mk_tmp_fixture
SNAP="$(snapshot)"
run bash "$CLEAN" --dry-run --only tmp-builds
t_has "dry-run: 2시간 전 수정 파일이 있으면 skip 으로 보고" "최근 3일 내 수정된 파일이 있어 skip: $TMPB/recent2h-verify"
t_has "dry-run: 70시간 전 수정도 창 안" "최근 3일 내 수정된 파일이 있어 skip: $TMPB/recent70h-verify"
t_has "dry-run: 오래된 것은 후보" "[dry-run] rm -rfx $TMPB/old-verify"
t_hasnt "dry-run: 최상위가 2일 전이면(안은 10일 전이어도) 후보 목록에 없다" "$TMPB/top2d-verify"
t_eq "dry-run 은 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

# 보호 창 값이 깨지면 보호 없이 도는 대신 FAIL 로 끝난다(예전에는 08 이 산술 오류를
# 내고도 계속 돌아 방금 수정한 디렉터리까지 후보가 됐다).
bad=""
for v in 08 010 36501 99999999999999999999; do
    run TMP_BUILDS_MIN_AGE_D="$v" bash "$CLEAN" --dry-run --only tmp-builds
    if out_re '^  40-tmp-builds +FAIL ' && ! out_has "[dry-run] rm -rfx"; then :; else bad="$bad [$v]"; fi
done
if [ -z "$bad" ]; then ok "TMP_BUILDS_MIN_AGE_D 가 08·010·상한 초과면 후보를 하나도 내지 않고 FAIL"; else fail "TMP_BUILDS_MIN_AGE_D 를 받아들였거나 후보를 냄:$bad"; fi
run TMP_BUILDS_MIN_AGE_D=08 bash "$CLEAN" -y --only tmp-builds
t_re "TMP_BUILDS_MIN_AGE_D=08 은 real 에서도 FAIL" '^  40-tmp-builds +FAIL '
t_eq "TMP_BUILDS_MIN_AGE_D=08 real 은 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
run TMP_BUILDS_MIN_AGE_D=4 bash "$CLEAN" --dry-run --only tmp-builds
t_has "TMP_BUILDS_MIN_AGE_D=4: 80시간 전 수정도 창(96시간) 안" "최근 4일 내 수정된 파일이 있어 skip: $TMPB/aged80h-verify"

run bash "$CLEAN" -y --only tmp-builds
t_rc "real 실행은 0" 0
t_exists "회귀: 2시간 전에 수정된 파일이 있는 빌드는 3일 창에서 보호된다(수정 전에는 72분 창이라 지워졌다)" "$TMPB/recent2h-verify/sub/f.txt"
t_exists "70시간 전 수정은 보호(72시간 창 안)" "$TMPB/recent70h-verify/sub/f.txt"
t_gone "80시간 전 수정은 삭제(창 밖)" "$TMPB/aged80h-verify"
t_gone "10일 된 verify 는 삭제" "$TMPB/old-verify"
t_gone "10일 된 _site 는 삭제" "$TMPB/_site-old"
t_exists "claude-* 는 이 모듈이 건드리지 않는다" "$TMPB/claude-verify-old/sub/f.txt"
t_exists "이름이 안 맞는 것은 남는다" "$TMPB/unrelated-old/sub/f.txt"
t_exists "프로세스가 쓰는 중이면 남는다" "$TMPB/busy-verify/sub/f.txt"
t_exists "방금 만든 것은 남는다" "$TMPB/fresh-verify/sub/f.txt"
t_exists "최상위가 2일 전이면 안의 파일이 전부 10일 전이어도 real 에서 남는다" "$TMPB/top2d-verify/sub/f.txt"
t_gone "최상위 심링크는 링크만 지운다" "$TMPB/link-verify"
t_exists "심링크가 가리키던 디렉터리는 남는다" "$SB/keep-target/keep.txt"
t_has "real 표 제목" "=== 모듈별 확보량 ==="
t_re "real 표: 확보량이 찍힌다" '^  40-tmp-builds +[0-9.]+(KB|MB|GB)$'
t_has "real: 이전 여유공간" "이전: "
t_has "real: 이후 여유공간" "이후: "

clear_cfg; mk_tmp_fixture
: > "$CFG/lsof_fail"
run bash "$CLEAN" -y --only tmp-builds
t_exists "lsof 가 실패하면 전부 사용 중으로 보고 지우지 않는다" "$TMPB/old-verify/sub/f.txt"
t_has "lsof 실패 경고" "lsof 실패/타임아웃/빈 출력"

# 내부에 마운트 포인트가 있으면 통째로 skip(has_mount_under). 가짜 stat 으로 하위
# 디렉터리 하나만 다른 디바이스처럼 보이게 한다.
clear_cfg; mk_tmp_fixture
printf '%s\n' "$TMPB/old-verify/sub" > "$CFG/fake_mounts"
run PATH="$P_STAT" bash "$CLEAN" -y --only tmp-builds
t_has "내부에 마운트 포인트가 있으면 skip 으로 보고" "내부에 마운트 포인트가 있어 skip: $TMPB/old-verify"
t_exists "내부에 마운트 포인트가 있는 디렉터리는 남는다" "$TMPB/old-verify/sub/f.txt"
t_gone "마운트가 없는 다른 후보는 지운다" "$TMPB/_site-old"

# '최근 수정' 판정의 find 가 실패하면(읽을 수 없는 하위 디렉터리) 판정 불가로 보고
# 남긴다. 예전에는 find 의 종료 상태를 안 봐서 "최근 수정 없음"과 구분하지 못했고,
# 읽지 못한 디렉터리 안에 방금 쓴 파일이 있어도 후보가 됐다.
if [ "$(/usr/bin/id -u)" != "0" ]; then
    clear_cfg; mk_tmp_fixture
    /bin/mkdir -p "$TMPB/locked-verify/sub/locked"
    echo x > "$TMPB/locked-verify/sub/f.txt"
    echo x > "$TMPB/locked-verify/sub/locked/fresh.txt"     # 방금 쓴 파일(읽을 수 없는 곳)
    age_one 240 "$TMPB/locked-verify/sub/f.txt"
    age_one 240 "$TMPB/locked-verify/sub/locked"
    age_one 240 "$TMPB/locked-verify/sub"
    age_one 240 "$TMPB/locked-verify"
    /bin/chmod 000 "$TMPB/locked-verify/sub/locked"
    run bash "$CLEAN" --dry-run --only tmp-builds
    t_has "find 실패: dry-run 이 판정 불가 skip 으로 보고" "최근 수정 여부를 판정할 수 없어(find 실패) skip: $TMPB/locked-verify"
    t_hasnt "find 실패: dry-run 후보 목록에 없다" "[dry-run] rm -rfx $TMPB/locked-verify"
    run bash "$CLEAN" -y --only tmp-builds
    t_exists "find 실패: 읽을 수 없는 하위 디렉터리가 있는 빌드는 real 에서 남는다" "$TMPB/locked-verify/sub/f.txt"
    t_gone "find 실패: 판정할 수 있는 다른 후보는 그대로 지운다(대조군)" "$TMPB/old-verify"
    unlock_tree "$TMPB/locked-verify"
    t_exists "find 실패: 권한을 되돌리면 안의 파일이 그대로 있다" "$TMPB/locked-verify/sub/locked/fresh.txt"
else
    note "root 로 돌고 있어 find 권한 실패 시험은 건너뜀"
fi

# CLEAN_SANDBOX_ROOT 가 빈 값이면 모듈 수준에서도 아무것도 지워지지 않는다.
clear_cfg; mk_tmp_fixture
run CLEAN_SANDBOX_ROOT= bash "$CLEAN" -y --only tmp-builds
t_exists "CLEAN_SANDBOX_ROOT= (빈 값): 오래된 후보도 남는다" "$TMPB/old-verify/sub/f.txt"
t_has "CLEAN_SANDBOX_ROOT= (빈 값): 거부 경고" "CLEAN_SANDBOX_ROOT가 절대경로가 아니라 전부 거부"

# ---- 50-claude-tmp ---------------------------------------------------------------
echo "== 50-claude-tmp: 세션 보호 =="
clear_cfg; mk_claude_fixture
P="$CT/-Users-x-proj"
SNAP="$(snapshot)"
run CLAUDE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
t_has "CLAUDE_SESSION_ID 로도 현재 세션을 알아본다" "현재 실행 중인 세션이라 skip: $P/$U_CUR"
t_has "dry-run: 후보 목록에 오래된 세션" "[dry-run] rm -rfx $P/$U_OLD"
t_eq "dry-run 은 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
t_rc "real 실행은 0" 0
t_exists "현재 세션(CLAUDE_CODE_SESSION_ID)은 오래됐어도 real 에서 남는다" "$P/$U_CUR/scratchpad/f.txt"
t_gone "오래된 다른 세션은 삭제" "$P/$U_OLD"
t_gone "25시간 전 수정 세션은 삭제(24시간 창 밖)" "$P/$U_25H"
t_exists "1시간 전 수정 세션은 남는다" "$P/$U_REC/scratchpad/f.txt"
t_exists "23시간 전 수정 세션은 남는다(24시간 창 안)" "$P/$U_23H/scratchpad/f.txt"
t_exists "프로세스가 쓰는 세션은 남는다" "$P/$U_BSY/scratchpad/f.txt"
t_exists "UUID 가 아닌 디렉터리는 대상이 아니다" "$P/notes/f.txt"

# 보호 창 값이 깨지면 FAIL 로 끝난다. 예전에는 08(산술 오류)·넘치는 큰 값에서 방금
# 수정한 세션까지 후보가 됐고, 010 은 8시간으로 읽혔다.
clear_cfg; mk_claude_fixture
SNAP="$(snapshot)"
bad=""
for v in 08 010 876001 200000000000000000 99999999999999999999; do
    run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_MIN_AGE_H="$v" bash "$CLEAN" --dry-run --only claude-tmp
    if out_re '^  50-claude-tmp +FAIL ' && ! out_has "[dry-run] rm -rfx"; then :; else bad="$bad [$v]"; fi
done
if [ -z "$bad" ]; then ok "CLAUDE_TMP_MIN_AGE_H 가 08·010·상한 초과·오버플로 값이면 후보를 하나도 내지 않고 FAIL"; else fail "CLAUDE_TMP_MIN_AGE_H 를 받아들였거나 후보를 냄:$bad"; fi
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_MIN_AGE_H=08 bash "$CLEAN" -y --only claude-tmp
t_re "CLAUDE_TMP_MIN_AGE_H=08 은 real 에서도 FAIL" '^  50-claude-tmp +FAIL '
t_eq "CLAUDE_TMP_MIN_AGE_H=08 real 은 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_MIN_AGE_H=26 bash "$CLEAN" --dry-run --only claude-tmp
t_has "CLAUDE_TMP_MIN_AGE_H=26: 25시간 전 수정도 창 안" "최근 26시간 내 수정된 파일·디렉터리가 있어 skip: $P/$U_25H"

clear_cfg; mk_claude_fixture
: > "$CFG/lsof_fail"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
t_exists "lsof 가 실패하면 오래된 세션도 지우지 않는다" "$P/$U_OLD/scratchpad/f.txt"

# 활동 중인 다른 세션. 2026-10-09 실제 dry-run 에서 당일 대화한 세션들이 후보로
# 나왔다 — 스크래치패드의 일반 파일 mtime 만 봤기 때문이다. 대화 기록
# (<projects>/*/<uuid>.jsonl 과 <projects>/*/<uuid>/)과 디렉터리 변경도 본다.
echo "== 50-claude-tmp: 대화 기록·디렉터리 변경으로 활동 중인 세션 보호 =="
J="$PJ/-Users-x-proj"
clear_cfg; mk_claude_activity_fixture
SNAP="$(snapshot)"
exp_tro="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$J/$U_TRO.jsonl")"
exp_trc="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$J/$U_TRC.jsonl")"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
t_rc "dry-run 은 0" 0
t_has "dry-run: 대화 기록이 1시간 전이면 skip 으로 보고" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_TRC"
t_line "dry-run: skip 줄에 대화 기록 마지막 수정 시각" "수정돼 skip: $P/$U_TRC" "대화 기록 마지막 수정 $exp_trc"
t_has "dry-run: 다른 프로젝트 디렉터리에 있는 23시간 전 대화 기록도 찾는다" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_T23"
t_has "dry-run: 서브에이전트 기록만 최근이어도 skip" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_SUB"
t_has "dry-run: 심링크된 프로젝트 디렉터리 안의 대화 기록도 찾는다" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_LNK"
t_has "dry-run: 방금 생긴 빈 세션 디렉터리는 skip" "최근 24시간 내 수정된 파일·디렉터리가 있어 skip: $P/$U_EMP"
t_has "dry-run: 하위 디렉터리 mtime 만 최근이어도 skip" "최근 24시간 내 수정된 파일·디렉터리가 있어 skip: $P/$U_DIR"
t_has "dry-run: 대화 기록이 3일 전이면 후보" "[dry-run] rm -rfx $P/$U_TRO"
t_line "dry-run: 후보 줄에 대화 기록 마지막 수정 시각" "[dry-run] rm -rfx $P/$U_TRO" "대화 기록 마지막 수정 $exp_tro"
t_has "dry-run: 대화 기록이 25시간 전이면 후보(24시간 창 밖)" "[dry-run] rm -rfx $P/$U_T25"
t_line "dry-run: 대화 기록이 없는 후보는 '대화 기록 없음'" "[dry-run] rm -rfx $P/$U_OLD" "대화 기록 없음"
n=$(/usr/bin/grep -cF -- "[dry-run] rm -rfx $P/" "$OUTF")
t_eq "dry-run: 후보는 넷뿐이다(오래된 세션·25시간 전 수정·대화 기록 3일 전·25시간 전)" "$n" "4"
t_eq "dry-run 은 스크래치패드도 대화 기록도 바꾸지 않는다(디렉터리 mtime 포함)" "$(snapshot)" "$SNAP"
cands1="$(/usr/bin/grep -F -- '[dry-run] rm -rfx' "$OUTF")"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
t_eq "dry-run 을 다시 돌려도 후보가 같다(스캔이 세션 디렉터리 mtime 을 바꾸지 않는다)" "$(/usr/bin/grep -F -- '[dry-run] rm -rfx' "$OUTF")" "$cands1"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_MIN_AGE_H=26 bash "$CLEAN" --dry-run --only claude-tmp
t_has "CLAUDE_TMP_MIN_AGE_H=26: 25시간 전 대화 기록도 창 안" "대화 기록이 최근 26시간 안에 수정돼 skip: $P/$U_T25"

SNAP_PJ="$(cd "$SB" && /usr/bin/find projects pj-elsewhere -exec /usr/bin/stat -f '%N|%m|%z|%Lp|%HT' {} + | LC_ALL=C /usr/bin/sort)"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
t_rc "real 실행은 0" 0
t_exists "대화 기록이 1시간 전에 수정된 세션은 스크래치패드가 5일 전이어도 real 에서 남는다" "$P/$U_TRC/scratchpad/f.txt"
t_exists "대화 기록이 23시간 전(창 안)이면 남는다" "$P/$U_T23/scratchpad/f.txt"
t_exists "서브에이전트 기록만 1시간 전이어도 남는다" "$P/$U_SUB/scratchpad/f.txt"
t_exists "심링크된 프로젝트 디렉터리 안의 대화 기록으로도 남는다" "$P/$U_LNK/scratchpad/f.txt"
t_exists "방금 생긴 빈 세션 디렉터리는 남는다" "$P/$U_EMP"
t_exists "하위 디렉터리 mtime 만 최근인 세션은 남는다" "$P/$U_DIR/scratchpad/f.txt"
t_gone "대화 기록이 3일 전이고 스크래치패드도 오래된 세션은 삭제" "$P/$U_TRO"
t_gone "대화 기록이 25시간 전(창 밖)이면 삭제" "$P/$U_T25"
t_gone "대화 기록이 없는 오래된 세션은 삭제(이름만 비슷한 최근 파일은 대화 기록이 아니다)" "$P/$U_OLD"
t_exists "현재 세션은 남는다" "$P/$U_CUR/scratchpad/f.txt"
t_eq "real 실행도 대화 기록 디렉터리는 건드리지 않는다(읽기 전용)" \
    "$(cd "$SB" && /usr/bin/find projects pj-elsewhere -exec /usr/bin/stat -f '%N|%m|%z|%Lp|%HT' {} + | LC_ALL=C /usr/bin/sort)" "$SNAP_PJ"

# 최근 파일이 아주 많은 세션. '최근 수정' 판정을 find | head -1 로 하고 파이프의
# 종료 상태를 보면, head 가 먼저 닫을 때 find 가 SIGPIPE(141)로 죽어 "판정 불가"로
# 잘못 읽힌다(pipefail). 찾은 것은 찾은 것으로 보고해야 한다.
U_BIG="12121212-1212-1212-1212-121212121212"
clear_cfg; mk_claude_activity_fixture
/bin/mkdir -p "$P/$U_BIG/scratchpad/a-rather-long-directory-name-to-fill-the-pipe-buffer-quickly"
/usr/bin/perl -e 'for my $i (1..3000) { open(my $f, ">", "$ARGV[0]/recent-file-number-$i.txt") or die; close($f); }' \
    "$P/$U_BIG/scratchpad/a-rather-long-directory-name-to-fill-the-pipe-buffer-quickly"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
t_has "최근 파일이 3000개인 세션은 '최근 수정'으로 skip" "최근 24시간 내 수정된 파일·디렉터리가 있어 skip: $P/$U_BIG"
t_hasnt "최근 파일이 많아도 '판정 불가'로 읽지 않는다(SIGPIPE 오인 없음)" "판정할 수 없어(find 실패) skip: $P/$U_BIG"

# 기본 경로($HOME/.claude/projects). 오버라이드를 빼고 돌린다 — HOME 은 샌드박스다.
clear_cfg; mk_claude_activity_fixture
/bin/mkdir -p "$SBHOME/.claude/projects/-Users-x-proj"
echo '{}' > "$SBHOME/.claude/projects/-Users-x-proj/$U_OLD.jsonl"     # 방금 쓴 대화 기록
run CLAUDE_CODE_SESSION_ID="$U_CUR" /usr/bin/env -u CLAUDE_TMP_PROJECTS_DIR bash "$CLEAN" -y --only claude-tmp
t_exists "기본 경로: \$HOME/.claude/projects 의 최근 대화 기록으로 세션이 남는다" "$P/$U_OLD/scratchpad/f.txt"
t_gone "기본 경로: 그 디렉터리에 대화 기록이 없는 오래된 세션은 삭제(대조군)" "$P/$U_TRO"
/bin/rm -rf "$SBHOME/.claude"

# 이름에 개행이 든 프로젝트 디렉터리 안의 최근 대화 기록. 목록을 줄 단위로 읽어
# 경로가 깨지는데, 깨진 줄을 "기록 없음"으로 치지 않고 판정 불가로 남긴다.
clear_cfg; mk_claude_activity_fixture
NLDIR="$PJ/$(printf 'nl-a\nnl-b')"
/bin/mkdir -p "$NLDIR"
echo '{}' > "$NLDIR/$U_OLD.jsonl"                                     # 방금 쓴 대화 기록
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
t_exists "개행이 든 프로젝트 디렉터리의 최근 대화 기록: 그 세션은 남는다" "$P/$U_OLD/scratchpad/f.txt"
t_gone "개행이 든 프로젝트 디렉터리: 다른 후보는 그대로 지운다(대조군)" "$P/$U_TRO"

# 대화 기록 디렉터리를 못 읽으면 "활동 없음"으로 치지 않는다.
clear_cfg; mk_claude_activity_fixture
SNAP="$(snapshot)"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_PROJECTS_DIR="$SB/없는-projects" bash "$CLEAN" -y --only claude-tmp
t_has "대화 기록 디렉터리가 없으면 이유를 알린다" "대화 기록 디렉터리가 없어 세션 활동을 판정할 수 없음"
t_re "대화 기록 디렉터리가 없으면 모듈은 skip" '^  50-claude-tmp +skip$'
t_eq "대화 기록 디렉터리가 없으면 real 에서도 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_TMP_PROJECTS_DIR="rel/projects" bash "$CLEAN" -y --only claude-tmp
t_re "CLAUDE_TMP_PROJECTS_DIR 가 상대경로면 FAIL" '^  50-claude-tmp +FAIL '
t_eq "CLAUDE_TMP_PROJECTS_DIR 가 상대경로면 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

if [ "$(/usr/bin/id -u)" != "0" ]; then
    # (1) 스크래치패드 안에 읽을 수 없는 디렉터리 — '최근 수정' find 가 실패한다.
    clear_cfg; mk_claude_activity_fixture
    /bin/mkdir -p "$P/$U_ERR/scratchpad/locked"
    echo x > "$P/$U_ERR/scratchpad/f.txt"
    age_tree 120 "$P/$U_ERR"
    echo x > "$P/$U_ERR/scratchpad/locked/fresh.txt"        # 방금 쓴 파일(읽을 수 없는 곳)
    age_one 120 "$P/$U_ERR/scratchpad/locked"
    /bin/chmod 000 "$P/$U_ERR/scratchpad/locked"
    run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
    t_has "find 실패: dry-run 이 판정 불가 skip 으로 보고" "최근 수정 여부를 판정할 수 없어(find 실패) skip: $P/$U_ERR"
    t_hasnt "find 실패: dry-run 후보 목록에 없다" "[dry-run] rm -rfx $P/$U_ERR"
    run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
    t_exists "find 실패: 읽을 수 없는 하위 디렉터리가 있는 세션은 real 에서 남는다" "$P/$U_ERR/scratchpad/f.txt"
    t_gone "find 실패: 판정할 수 있는 다른 후보는 그대로 지운다(대조군)" "$P/$U_TRO"
    unlock_tree "$P/$U_ERR"
    t_exists "find 실패: 권한을 되돌리면 안의 파일이 그대로 있다" "$P/$U_ERR/scratchpad/locked/fresh.txt"

    # (2) 서브에이전트 기록 디렉터리를 읽을 수 없다 — 그 세션만 판정 불가.
    clear_cfg; mk_claude_activity_fixture
    /bin/mkdir -p "$J/$U_TRO/subagents"
    echo '{}' > "$J/$U_TRO/subagents/agent-b1.jsonl"        # 방금 쓴 기록(읽을 수 없는 곳)
    age_one 120 "$J/$U_TRO/subagents"; age_one 120 "$J/$U_TRO"
    /bin/chmod 000 "$J/$U_TRO/subagents"
    run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
    t_has "대화 기록 조회 실패: 판정 불가 skip 으로 보고" "대화 기록을 조회할 수 없어(판정 불가) skip: $P/$U_TRO"
    t_exists "대화 기록 조회 실패: 그 세션은 real 에서 남는다" "$P/$U_TRO/scratchpad/f.txt"
    t_gone "대화 기록 조회 실패: 다른 후보는 그대로 지운다(대조군)" "$P/$U_T25"
    unlock_tree "$PJ"

    # (3) 프로젝트 디렉터리 하나를 읽을 수 없다 — 어느 세션의 기록이 거기 있는지 모르므로
    #     전부 판정 불가.
    clear_cfg; mk_claude_activity_fixture
    /bin/mkdir -p "$PJ/-Users-locked"
    echo '{}' > "$PJ/-Users-locked/$U_OLD.jsonl"            # 방금 쓴 대화 기록(읽을 수 없는 곳)
    age_one 120 "$PJ/-Users-locked"
    /bin/chmod 000 "$PJ/-Users-locked"
    run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
    t_has "프로젝트 디렉터리를 못 읽으면 판정 불가 skip 으로 보고" "대화 기록을 조회할 수 없어(판정 불가) skip: $P/$U_OLD"
    t_exists "프로젝트 디렉터리를 못 읽으면 대화 기록이 없어 보이는 세션도 남는다" "$P/$U_OLD/scratchpad/f.txt"
    t_exists "프로젝트 디렉터리를 못 읽으면 대화 기록이 오래된 세션도 남는다" "$P/$U_TRO/scratchpad/f.txt"
    # 예전에는 세션 수만큼 같은 skip 줄만 나오고 어느 디렉터리 탓인지 로그에 없었다.
    t_has "프로젝트 디렉터리를 못 읽으면 어느 디렉터리인지 이름을 찍는다" "대화 기록을 볼 수 없는 항목(읽을 수 없는 디렉터리): $PJ/-Users-locked"
    t_has "프로젝트 디렉터리를 못 읽으면 모든 세션이 남는다고 알린다" "이번 실행은 모든 세션을 판정 불가로 남김"
    n=$(/usr/bin/grep -cF -- "대화 기록을 볼 수 없는 항목(" "$OUTF")
    t_eq "못 읽는 항목 경고는 세션마다가 아니라 한 번만 나온다" "$n" "1"
    unlock_tree "$PJ"
else
    note "root 로 돌고 있어 find 권한 실패 시험(claude-tmp)은 건너뜀"
fi

# 끊어진 심링크 프로젝트 디렉터리. 다른 볼륨을 가리키는 링크인데 그 볼륨이 빠진
# 경우다. find -L 은 끊어진 링크를 오류 없이 지나가서, 그 안에 최근 대화 기록이
# 있던 세션이 "대화 기록 없음" 후보가 됐다. 링크 안을 볼 수 없으니 전부 판정 불가다.
clear_cfg; mk_claude_activity_fixture
/bin/mv "$SB/pj-elsewhere" "$SB/pj-unplugged"            # -Users-z-linked 의 대상이 사라진다
SNAP="$(snapshot)"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" --dry-run --only claude-tmp
t_has "끊어진 링크: 어느 항목인지 이름을 찍는다" "대화 기록을 볼 수 없는 항목(끊어졌거나 대상을 볼 수 없는 심볼릭 링크): $PJ/-Users-z-linked"
t_has "끊어진 링크: 그 안에 최근 기록이 있던 세션은 판정 불가 skip" "대화 기록을 조회할 수 없어(판정 불가) skip: $P/$U_LNK"
t_hasnt "끊어진 링크: dry-run 이 후보를 하나도 내지 않는다" "[dry-run] rm -rfx"
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only claude-tmp
t_exists "끊어진 링크: 그 안에 최근 대화 기록이 있던 세션은 real 에서 남는다" "$P/$U_LNK/scratchpad/f.txt"
t_exists "끊어진 링크: 대화 기록이 없어 보이는 세션도 남는다" "$P/$U_OLD/scratchpad/f.txt"
t_eq "끊어진 링크가 있으면 real 에서도 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
reset_dir "$SB/pj-unplugged"

# CLAUDE_CONFIG_DIR. Claude Code 는 이 값이 있으면 대화 기록을 그 아래 projects 에
# 쓴다. 기본 경로만 보던 때는 예전 ~/.claude/projects 가 남아 있으면 skip 도 경고도
# 없이 "대화 기록 없음" 후보가 됐다. 기본 경로에 더해 같이 본다(합집합).
clear_cfg; mk_claude_activity_fixture
/bin/mkdir -p "$SBHOME/.claude/projects/-Users-x-proj" "$SB/cfgdir/projects/-Users-x-proj"
echo '{}' > "$SB/cfgdir/projects/-Users-x-proj/$U_OLD.jsonl"         # 방금 쓴 기록(옮긴 설정 디렉터리)
echo '{}' > "$SBHOME/.claude/projects/-Users-x-proj/$U_25H.jsonl"    # 방금 쓴 기록(기본 경로)
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_CONFIG_DIR="$SB/cfgdir" /usr/bin/env -u CLAUDE_TMP_PROJECTS_DIR bash "$CLEAN" -y --only claude-tmp
t_rc "CLAUDE_CONFIG_DIR: real 실행은 0" 0
t_exists "CLAUDE_CONFIG_DIR: 그 아래 projects 의 최근 대화 기록으로 세션이 남는다" "$P/$U_OLD/scratchpad/f.txt"
t_exists "CLAUDE_CONFIG_DIR: 기본 경로의 최근 대화 기록도 같이 본다(합집합)" "$P/$U_25H/scratchpad/f.txt"
t_gone "CLAUDE_CONFIG_DIR: 두 곳 어디에도 기록이 없는 오래된 세션은 삭제(대조군)" "$P/$U_TRO"

clear_cfg; mk_claude_activity_fixture
/bin/rm -rf "$SB/cfgdir/projects"
SNAP="$(snapshot)"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_CONFIG_DIR="$SB/cfgdir" /usr/bin/env -u CLAUDE_TMP_PROJECTS_DIR bash "$CLEAN" -y --only claude-tmp
t_has "CLAUDE_CONFIG_DIR 아래 projects 가 없으면 이유를 알린다" "CLAUDE_CONFIG_DIR 의 대화 기록 디렉터리가 없어 세션 활동을 판정할 수 없음"
t_re "CLAUDE_CONFIG_DIR 아래 projects 가 없으면 모듈은 skip" '^  50-claude-tmp +skip$'
t_eq "CLAUDE_CONFIG_DIR 아래 projects 가 없으면 real 에서도 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_CONFIG_DIR="rel/cfgdir" /usr/bin/env -u CLAUDE_TMP_PROJECTS_DIR bash "$CLEAN" -y --only claude-tmp
t_re "CLAUDE_CONFIG_DIR 가 상대경로면 FAIL" '^  50-claude-tmp +FAIL '
t_eq "CLAUDE_CONFIG_DIR 가 상대경로면 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"
# CLAUDE_TMP_PROJECTS_DIR 를 직접 준 실행은 그 값만 쓴다(하네스의 다른 시험이 전부 이 경로다).
run CLAUDE_CODE_SESSION_ID="$U_CUR" CLAUDE_CONFIG_DIR="$SB/cfgdir" bash "$CLEAN" --dry-run --only claude-tmp
t_hasnt "CLAUDE_TMP_PROJECTS_DIR 를 주면 CLAUDE_CONFIG_DIR 은 보지 않는다" "CLAUDE_CONFIG_DIR 의 대화 기록 디렉터리가 없어"
t_has "CLAUDE_TMP_PROJECTS_DIR 를 주면 그 디렉터리로 판정한다" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_TRC"
/bin/rm -rf "$SBHOME/.claude"
reset_dir "$SB/cfgdir"

# 임시 파일을 못 쓰는 상태(꽉 찬 디스크 — 이 스킬을 부르는 대표 상황). 대화 기록
# 판정 루프가 here-document 로 목록을 읽던 때는, 임시 파일 쓰기가 실패하면 루프가
# 한 번도 돌지 않은 채 "기록은 있고 전부 창 밖"(quiet)이 돼서 대화 기록이 1시간
# 전인 세션이 지워졌다. has_mount_under 도 같은 꼴이라 "마운트 없음"을 돌려줬다.
echo "== 임시 파일을 못 쓰는 상태(here-document 실패): 50-claude-tmp, 40-tmp-builds =="
if [ "$NOWRITE_OK" = "1" ]; then
    clear_cfg; mk_claude_activity_fixture
    exp_trc="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$J/$U_TRC.jsonl")"
    exp_tro="$(/usr/bin/stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$J/$U_TRO.jsonl")"
    run_nowrite "$MOD/50-claude-tmp.sh" CLAUDE_CODE_SESSION_ID="$U_CUR"
    t_rc "쓰기 불가: 모듈은 0 으로 끝난다" 0
    t_has "쓰기 불가: RESULT 줄을 남긴다" "RESULT:50-claude-tmp:"
    t_hasnt "쓰기 불가: here-document 에 기대는 코드가 이 모듈 경로에 없다" "here document"
    t_has "쓰기 불가: 대화 기록이 1시간 전인 세션은 skip 으로 보고" "대화 기록이 최근 24시간 안에 수정돼 skip: $P/$U_TRC"
    t_line "쓰기 불가: skip 줄의 대화 기록 시각도 그대로 찍힌다" "수정돼 skip: $P/$U_TRC" "대화 기록 마지막 수정 $exp_trc"
    t_line "쓰기 불가: 삭제 줄의 대화 기록 시각도 그대로 찍힌다" "삭제 $P/$U_TRO" "대화 기록 마지막 수정 $exp_tro"
    t_exists "쓰기 불가: 대화 기록이 1시간 전인 세션은 real 에서 남는다" "$P/$U_TRC/scratchpad/f.txt"
    t_exists "쓰기 불가: 대화 기록이 23시간 전인 세션은 남는다" "$P/$U_T23/scratchpad/f.txt"
    t_exists "쓰기 불가: 서브에이전트 기록만 최근인 세션은 남는다" "$P/$U_SUB/scratchpad/f.txt"
    t_exists "쓰기 불가: 심링크된 프로젝트 디렉터리 안의 기록으로도 남는다" "$P/$U_LNK/scratchpad/f.txt"
    t_gone "쓰기 불가: 대화 기록이 3일 전인 세션은 그대로 지운다(대조군)" "$P/$U_TRO"
    t_gone "쓰기 불가: 대화 기록이 없는 오래된 세션은 그대로 지운다(대조군)" "$P/$U_OLD"

    clear_cfg; mk_claude_fixture
    printf '%s\n' "$P/$U_OLD/scratchpad" > "$CFG/fake_mounts"
    run_nowrite "$MOD/50-claude-tmp.sh" CLAUDE_CODE_SESSION_ID="$U_CUR" PATH="$P_STAT"
    t_has "쓰기 불가: 내부의 마운트 포인트를 그대로 알아본다" "내부에 마운트 포인트가 있어 skip: $P/$U_OLD"
    t_exists "쓰기 불가: 내부에 마운트 포인트가 있는 세션은 real 에서 남는다" "$P/$U_OLD/scratchpad/f.txt"
    t_gone "쓰기 불가: 마운트가 없는 다른 후보는 지운다(대조군)" "$P/$U_25H"

    # has_mount_under 는 lib.sh 공용이다. 40-tmp-builds 쪽에서도 같은지 본다.
    clear_cfg; mk_tmp_fixture
    printf '%s\n' "$TMPB/old-verify/sub" > "$CFG/fake_mounts"
    run_nowrite "$MOD/40-tmp-builds.sh" PATH="$P_STAT"
    t_hasnt "쓰기 불가(tmp-builds): here-document 에 기대는 코드가 이 모듈 경로에 없다" "here document"
    t_has "쓰기 불가(tmp-builds): 내부의 마운트 포인트를 그대로 알아본다" "내부에 마운트 포인트가 있어 skip: $TMPB/old-verify"
    t_exists "쓰기 불가(tmp-builds): 내부에 마운트 포인트가 있는 디렉터리는 real 에서 남는다" "$TMPB/old-verify/sub/f.txt"
    t_gone "쓰기 불가(tmp-builds): 마운트가 없는 다른 후보는 지운다(대조군)" "$TMPB/_site-old"
else
    note "here-document 가 실패하지 않는 bash 라 쓰기 불가 시험은 건너뜀"
fi

# ---- 60-node-modules -------------------------------------------------------------
echo "== 60-node-modules: 방치 판정 =="
clear_cfg; mk_nm_fixture
SNAP="$(snapshot)"
run bash "$CLEAN" --dry-run --only node-modules
t_has "dry-run: 방치된 프로젝트가 후보" "[dry-run] rm -rfx $NM/stale/node_modules"
t_has "dry-run: 최근 수정 프로젝트는 skip 으로 보고" "최근 30일 내 수정 있어 skip: $NM/active"
t_eq "dry-run 은 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

run bash "$CLEAN" -y --only node-modules
t_rc "real 실행은 0" 0
t_gone "60일 방치 프로젝트의 node_modules 는 삭제" "$NM/stale/node_modules"
t_exists "방치 프로젝트의 소스는 남는다" "$NM/stale/src/a.js"
t_exists "방치 프로젝트의 package.json 은 남는다" "$NM/stale/package.json"
t_exists "하루 전에 수정한 프로젝트는 남는다" "$NM/active/node_modules/pkg/index.js"
t_exists "28일 전 수정은 남는다(30일 창 안)" "$NM/day28/node_modules/pkg/index.js"
t_gone "31일 전 수정은 삭제(창 밖)" "$NM/day31/node_modules"
t_gone ".git 안의 최근 파일은 판정에 안 들어간다" "$NM/gitonly/node_modules"
t_gone "node_modules 안의 최근 파일은 판정에 안 들어간다" "$NM/nmrecent/node_modules"
t_exists "프로세스가 쓰는 프로젝트는 남는다" "$NM/busy/node_modules/pkg/index.js"
t_exists "워크스페이스: 한 패키지만 최근이어도 루트 node_modules 가 남는다" "$NM/mono/node_modules/pkg"
t_exists "워크스페이스: 오래된 형제 패키지의 node_modules 도 남는다" "$NM/mono/packages/a/node_modules/pkg"
t_exists "워크스페이스: 최근 패키지의 node_modules 도 남는다" "$NM/mono/packages/b/node_modules/pkg"
t_gone "방치된 워크스페이스(package.json workspaces)의 루트 node_modules 는 삭제" "$NM/monostale/node_modules"
t_gone "방치된 워크스페이스의 패키지 node_modules 도 삭제" "$NM/monostale/packages/x/node_modules"
t_exists "활동 중인 next 프로젝트의 node_modules 는 남는다" "$NM/next/node_modules/pkg/index.js"
t_gone ".next/standalone 아래 사본은 그 디렉터리만 보고 판정해 삭제" "$NM/next/.next/standalone/node_modules"
t_exists "깊이 5 를 넘는 node_modules 는 찾지 않는다" "$NM/deep/a/b/c/d/node_modules/pkg"

clear_cfg; mk_nm_fixture
run NODE_MODULES_ROOTS="$SBHOME" bash "$CLEAN" -y --only node-modules
t_has "NODE_MODULES_ROOTS 가 \$HOME 이면 거부" "NODE_MODULES_ROOTS 값이 너무 넓어서 거부"
t_re "너무 넓은 루트는 skip 으로 끝난다" '^  60-node-modules +skip$'

# ---- 외부 도구 모듈 ----------------------------------------------------------------
echo "== 외부 도구 모듈 =="
clear_cfg; mk_home_fixture; mk_tmp_fixture; mk_claude_fixture; mk_nm_fixture; clear_cfg
SNAP="$(snapshot)"
shim_reset
run PATH="$P_BARE" bash "$CLEAN" -y --only go,pnpm,npm,pip,brew,docker
t_rc "도구가 없어도 0" 0
n=$(/usr/bin/sed -n '/=== 모듈별 확보량/,$p' "$OUTF" | /usr/bin/grep -cE '^  (10-go|20-pnpm|21-npm|22-pip|23-brew|70-docker) +skip$')
t_eq "도구가 없으면 6개 모듈 전부 skip" "$n" "6"
t_eq "도구가 없으면 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

shim_reset
run CLAUDE_CODE_SESSION_ID="$U_CUR" bash "$CLEAN" -y --only "$BASIC"
t_rc "기본 세트 real 실행은 0" 0
shim_has "go clean -cache 를 / 에서 GOTOOLCHAIN=local 로 부른다" "go cwd=/ GOTOOLCHAIN=local :: clean -cache"
shim_has "go clean -modcache 를 / 에서 GOTOOLCHAIN=local 로 부른다" "go cwd=/ GOTOOLCHAIN=local :: clean -modcache"
shim_has "pnpm store prune 을 / 에서 부른다" "pnpm cwd=/ :: store prune"
shim_has "npm cache clean --force 를 / 에서 부른다" "npm cwd=/ :: cache clean --force"
shim_has "pip3 cache purge 를 부른다" ":: cache purge"
shim_has "brew cleanup -s 를 부른다" ":: cleanup -s"
shim_hasnt "real 에서는 brew cleanup -ns 를 부르지 않는다" ":: cleanup -ns"
shim_has "docker builder prune -a -f 를 부른다" "docker cwd=$SB/cwd :: builder prune -a -f"
shim_has "docker image prune -a -f 를 부른다" "docker cwd=$SB/cwd :: image prune -a -f"
calls=$(/usr/bin/sed -n 's/^docker cwd=[^ ]* :: //p' "$SHIMLOG" | LC_ALL=C /usr/bin/sort -u | /usr/bin/tr '\n' '|')
t_eq "docker 호출은 다섯 가지뿐이다" "$calls" "builder prune -a -f|context inspect --format {{.Endpoints.docker.Host}}|image prune -a -f|info|system df|"
if /usr/bin/grep -qE '^docker .* :: .*(volume|container|system prune|rmi?( |$)|kill|stop)' "$SHIMLOG"; then
    fail "docker 볼륨·컨테이너 삭제 명령이 호출됨"
else
    ok "docker 볼륨·컨테이너 삭제 명령은 호출되지 않는다"
fi
t_gone "go 빌드 캐시가 비워진다" "$SBHOME/Library/Caches/go-build"
t_gone "go 모듈 캐시가 비워진다" "$SBHOME/go/pkg/mod"
t_gone "pnpm 캐시 디렉터리는 스크립트가 직접 지운다" "$SBHOME/Library/Caches/pnpm"
t_exists "pnpm store 디렉터리는 스크립트가 직접 지우지 않는다" "$SBHOME/Library/pnpm/store/blob"
t_gone "npm 캐시가 비워진다" "$SBHOME/.npm/_cacache"
t_gone "Chrome 이 꺼져 있으면 Google 캐시를 지운다" "$SBHOME/Library/Caches/Google"
t_gone "opencode 캐시를 지운다" "$SBHOME/.cache/opencode"
t_exists "기본 세트는 Downloads 를 건드리지 않는다" "$SBHOME/Downloads/blob"
t_re "real 표: docker = builder 512MB + image 1.5GB" '^  70-docker +2\.00GB$'
t_hasnt "기본 세트에 claude-tmp 는 없다" "50-claude-tmp"
t_hasnt "기본 세트에 node-modules 는 없다" "60-node-modules"
t_exists "기본 세트는 오래된 다른 세션을 지우지 않는다" "$CT/-Users-x-proj/$U_OLD/scratchpad/f.txt"
t_exists "기본 세트는 방치된 node_modules 를 지우지 않는다" "$NM/stale/node_modules/pkg/index.js"

# RESULT 가 ok 여도 정리 명령의 성공을 뜻하지 않는다(SKILL.md "숫자 읽는 법"의 근거).
mk_home_fixture
: > "$CFG/npm_fail"
run bash "$CLEAN" -y --only npm
t_exists "npm 이 실패하면 캐시는 남는다" "$SBHOME/.npm/_cacache/blob"
t_re "npm 이 실패해도 표에는 0KB 로 찍힌다(FAIL 이 아님)" '^  21-npm +0KB$'
t_has "실패 메시지는 로그에 남는다" "npm ERR!"

# docker: 데몬 무응답 / 원격 데몬
clear_cfg; shim_reset
: > "$CFG/docker_info_fail"
run bash "$CLEAN" -y --only docker
t_has "docker 데몬이 응답하지 않으면 안내만 한다" "도커 데몬이 응답하지 않음"
t_re "데몬 무응답은 skip" '^  70-docker +skip$'
LABEL="데몬 무응답이면 prune 을 부르지 않는다"; no_destructive_calls

clear_cfg; shim_reset
echo "tcp://10.0.0.1:2376" > "$CFG/docker_ctx_host"
run bash "$CLEAN" -y --only docker
t_has "context 가 원격이면 skip" "원격 데몬이라 skip"
LABEL="context 가 원격이면 prune 을 부르지 않는다"; no_destructive_calls

clear_cfg; shim_reset
run DOCKER_HOST="ssh://user@host" bash "$CLEAN" -y --only docker
t_has "DOCKER_HOST 가 유닉스 소켓이 아니면 skip" "원격 데몬이라 skip"
LABEL="DOCKER_HOST 가 원격이면 prune 을 부르지 않는다"; no_destructive_calls

# 30-app-caches: Chrome 실행 중
clear_cfg; mk_home_fixture
: > "$CFG/chrome_running"
run bash "$CLEAN" -y --only app-caches
t_exists "Chrome 이 켜져 있으면 Google 캐시는 남는다" "$SBHOME/Library/Caches/Google/Chrome/blob"
t_gone "Chrome 이 켜져 있어도 opencode 캐시는 지운다" "$SBHOME/.cache/opencode"

# 90-report: 삭제 없음
clear_cfg; mk_home_fixture; mk_claude_fixture; clear_cfg
SNAP="$(snapshot)"
run bash "$CLEAN" -y --only report
t_has "report 는 Downloads 크기를 보고한다" "90-report: $SBHOME/Downloads — "
t_has "report 는 CLAUDE_TMP_ROOT 크기를 보고한다" "90-report: $CT — "
t_eq "report 는 real 모드에서도 아무것도 지우지 않는다" "$(snapshot)" "$SNAP"

# ---- 심링크 디렉터리 경유 실행 -------------------------------------------------------
echo "== 심링크 디렉터리 경유(~/.claude/skills/clean_mac 형태) =="
/bin/mkdir -p "$SB/skills-link/clean_mac"
/bin/ln -s "$SCRIPTS" "$SB/skills-link/clean_mac/scripts"
run bash "$SB/skills-link/clean_mac/scripts/clean.sh" --list
t_rc "심링크 경유 --list" 0
run bash "$SB/skills-link/clean_mac/scripts/clean.sh" --dry-run --only go,report
t_rc "심링크 경유 --dry-run" 0
t_re "심링크 경유: 모듈이 lib.sh 를 찾아 RESULT 를 낸다" '^  10-go +[0-9.]+(KB|MB|GB)$'
t_hasnt "심링크 경유: FAIL 없음" "FAIL"

# ---- shellcheck ------------------------------------------------------------------
echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
    if shellcheck -S error "$CLEAN" "$MOD"/*.sh "$SELF" > "$SB/shellcheck.txt" 2>&1; then
        ok "shellcheck error 등급 없음(scripts/ 13개 파일 + 이 테스트)"
    else
        fail "shellcheck error 등급 발견"
        /bin/cat "$SB/shellcheck.txt"
    fi
else
    note "shellcheck 가 PATH 에 없어 건너뜀"
fi

# ---- 마무리 ----------------------------------------------------------------------
echo "== 마무리 =="
if [ -s "$RMREFUSED" ]; then
    fail "rm 이 샌드박스 밖 경로로 호출된 적이 있음(래퍼가 막았다):"
    /bin/cat "$RMREFUSED"
else
    ok "시험 내내 rm 이 샌드박스 밖 경로로 호출된 적이 없다"
fi

echo
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIPPED"
DONE=1
[ "$FAIL" = "0" ]
