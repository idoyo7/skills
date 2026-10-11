#!/usr/bin/env bash
# clean.d/lib.sh — 공통 헬퍼. 각 모듈이 source 한다.
# macOS 기본 bash 3.2 호환: 연관배열/mapfile/${var,,} 사용 금지.

# ---- 출력 ----------------------------------------------------------------

log() {
    printf '%s\n' "$*"
}

warn() {
    printf '[경고] %s\n' "$*" >&2
}

skip() {
    printf '[skip] %s\n' "$*"
}

# 모듈이 마지막에 반드시 한 번 호출: clean.sh가 이 줄을 grep 해서 표를 만든다.
# status: ok(정리함) | dry(dry-run) | skip(설치 안 됨/조건 미충족)
emit_result() {
    printf 'RESULT:%s:%s:%s\n' "$1" "$2" "$3"
}

# is_nonneg_int <value> — 0 이상의 정수인지(비숫자/음수/빈문자열은 거부).
is_nonneg_int() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# age_value_ok <값> <상한> — 나이 임계값(일/시간) env로 쓸 수 있는 값인지.
# is_nonneg_int만으로는 모자랐다. 이 값은 $(( ))에 들어가는데 bash 산술은
# 앞자리 0을 8진수로 읽는다 — "010"(10시간을 뜻한 값)이 8시간이 되고, "08"은
# 산술 오류다. bash 3.2는 그 오류 뒤에도 스크립트를 계속 돌려서, '최근 수정
# 보호' find가 깨진 인자로 실패하고 보호가 통째로 꺼진 채 삭제 후보가 됐다
# (fail-open — 가짜 트리 dry-run으로 재현됨). 아주 큰 값도 분 환산에서 넘쳐
# 같은 결과였다. 그래서 앞자리 0(단독 "0"은 허용)과 상한 초과를 거부한다.
# 호출부는 RESULT 없이 exit 1 한다(clean.sh 표에 FAIL).
age_value_ok() {
    local v="$1"
    local max="$2"
    is_nonneg_int "$v" || return 1
    case "$v" in
        0) return 0 ;;
        0*) return 1 ;;
    esac
    # 자릿수부터 본다 — 정수 범위를 넘는 값은 [ -le ] 비교부터 실패한다.
    if [ "${#v}" -gt "${#max}" ]; then
        return 1
    fi
    [ "$v" -le "$max" ]
}

# ---- 크기/용량 -------------------------------------------------------------

# human <kb>  — KB 정수를 사람이 읽는 단위로.
human() {
    local kb="${1:-0}"
    case "$kb" in
        ''|*[!0-9-]*) kb=0 ;;
    esac
    awk -v kb="$kb" 'BEGIN {
        if (kb < 0) kb = 0;
        if (kb < 1024) { printf "%dKB", kb; }
        else if (kb < 1024*1024) { printf "%.1fMB", kb/1024; }
        else { printf "%.2fGB", kb/1024/1024; }
    }'
}

# size_kb_1 <path> — 단일 경로의 du -skx(마운트 넘지 않음) 결과(KB).
# 실패/타임아웃/권한 문제면 아무것도 출력하지 않고 1을 반환한다 — 0KB와
# "측정 불가"를 호출부가 구분할 수 있게 하기 위함(90-report 등).
# du의 출력은 "<크기><TAB><경로>" 한 줄인데, 경로 자체에 개행이 들어있는
# 이름(예: "verify\n_injected")이면 그 개행 때문에 출력이 겉보기에 여러
# "줄"로 보인다 — NR==1만 보고 즉시 멈춰서 뒤에 섞여드는 것을 숫자로
# 잘못 더하는 사고(산술식이 "0\n0" 같은 값 때문에 깨짐)를 막는다.
size_kb_1() {
    local p="$1"
    local out rc
    out=$(with_timeout 20 du -skx "$p" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$out" ]; then
        return 1
    fi
    printf '%s\n' "$out" | awk 'NR==1{print $1+0; exit}'
    return 0
}

# size_kb <path...> — 존재하는 경로들의 du -skx 합(KB). 없거나 측정 실패한
# 경로는 0으로 취급(총합 용도). 개별 경로의 측정 성공 여부가 필요하면
# size_kb_1을 직접 써라.
size_kb() {
    local total=0
    local p kb
    for p in "$@"; do
        if [ -e "$p" ]; then
            kb=$(size_kb_1 "$p") || kb=0
            total=$((total + kb))
        fi
    done
    printf '%d\n' "$total"
}

# free_kb — /System/Volumes/Data 여유 공간(KB).
free_kb() {
    df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2{print $4+0}'
}

# ---- 실행 -----------------------------------------------------------------

# run <cmd...> — DRY_RUN=1이면 실행하지 않고 무엇을 실행할지만 출력.
run() {
    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '[dry-run]'
        printf ' %q' "$@" 2>/dev/null
        printf '\n'
    else
        "$@"
    fi
}

# with_timeout <sec> <cmd...> — macOS에는 timeout(1)이 없어 perl로 구현.
# - 타임아웃이면 반드시 124를 반환한다(예전 버전은 시그널로 죽인 자식의
#   종료상태를 >>8 해버려서 0으로 뭉개지는 버그가 있었음 — 이 때문에
#   70-docker의 무응답 감지가 무력화됐었다).
# - 자식을 새 프로세스 그룹으로 분리(setpgid)한 뒤, 타임아웃 시 그 그룹
#   전체에 TERM/KILL을 보낸다 — 손자 프로세스가 파이프의 쓰기 쪽을 쥐고
#   있어도(예: sh -c 'sleep 8') 함께 죽어서 파이프가 막히지 않는다.
with_timeout() {
    local secs="$1"
    shift
    if [ "$#" -eq 0 ]; then
        return 0
    fi
    if ! command -v perl >/dev/null 2>&1; then
        warn "perl이 없어 타임아웃 없이 실행: $*"
        "$@"
        return $?
    fi
    # 타임아웃 핸들러는 kill을 보낸 뒤 waitpid로 돌아가지 않고 핸들러
    # 안에서 곧바로 exit() 한다. NFS 등에서 D-state로 멈춰 SIGKILL도
    # 안 먹는 자식이 있으면(실제로 재현됐다) 그 뒤의 waitpid가 영원히
    # 안 끝나서 with_timeout 자체가 무력화되기 때문 — reap을 못 해도
    # 상관없다, 우리 프로세스가 빠져나가면 그 자식은 launchd로 재부모화돼
    # 알아서 처리된다.
    #
    # 자식은 setpgid로 별도 프로세스 그룹이라 터미널의 Ctrl-C(SIGINT)가
    # 그 그룹까지 전달되지 않는다(고아로 남을 수 있었다) — 그래서
    # INT/TERM/HUP도 ALRM과 똑같이 잡아서 자식 그룹에 그대로 넘긴다.
    # 자식의 stdin은 /dev/null로 돌린다: 별도 그룹이 된 자식이 터미널을
    # 읽으려 하면 SIGTTIN으로 멈출 수 있어서다. y/N 확인 프롬프트는
    # with_timeout 밖(메인 clean.sh)에서 그 스크립트 자신의 stdin으로
    # read하므로 이 리다이렉션과 무관하다.
    perl -e '
        use POSIX ();
        my $secs = shift(@ARGV);
        my $pid = fork();
        if (!defined $pid) { exit 1; }
        if ($pid == 0) {
            eval { POSIX::setpgid(0, 0); };
            open(STDIN, "<", "/dev/null");
            exec(@ARGV) or exit 127;
        }
        my $kill_and_exit = sub {
            my $code = shift;
            kill("TERM", -$pid);
            kill("TERM", $pid);
            select(undef, undef, undef, 0.3);
            kill("KILL", -$pid);
            kill("KILL", $pid);
            close(STDOUT);
            close(STDERR);
            exit $code;
        };
        local $SIG{ALRM} = sub { $kill_and_exit->(124); };
        local $SIG{INT}  = sub { $kill_and_exit->(130); };
        local $SIG{TERM} = sub { $kill_and_exit->(143); };
        local $SIG{HUP}  = sub { $kill_and_exit->(129); };
        alarm($secs);
        waitpid($pid, 0);
        alarm(0);
        my $status = $?;
        if (($status & 127) != 0) {
            exit(128 + ($status & 127));
        }
        exit($status >> 8);
    ' "$secs" "$@"
}

# ---- 안전한 삭제 ------------------------------------------------------------

# resolve_root_override <env 이름> <값> — 모듈의 스캔/삭제 루트로 쓸 값을
# 검사하고, 후행 슬래시를 뗀 값을 stdout으로 돌려준다. 통과하지 못하면
# 경고를 내고 1을 반환한다(호출부는 RESULT 없이 exit 1 — clean.sh 표에
# FAIL로 찍힌다).
#
# 40-tmp-builds / 50-claude-tmp 의 루트는 원래 하드코딩이었다. 그래서
# 2026-09-29에 가짜 트리로 시험하려던 실행이 실제 루트
# (/private/tmp/claude-<uid>)에서 real 모드로 돌아 다른 세션의
# 스크래치패드를 지운 사고가 있었다 — env로 루트를 바꿀 수 있어야 가짜
# 트리 시험이 실제 경로를 건드리지 않는다.
#
# 이 값은 그대로 safe_rm의 허용 접두가 되므로, 오버라이드가 삭제 범위를
# 넓히는 구멍이 되지 않게 safe_rm이 "대상"에 적용하는 위험 경로 목록과
# 같은 목록을 루트에도 적용한다(safe_rm의 허용 접두 검사보다 좁다). 이
# 함수는 걸러내기만 하고, 실제 삭제는 여전히 safe_rm의 검사를 전부 거친다.
#
# 위험 경로는 글자뿐 아니라 "같은 디렉터리인가"(장치번호:inode)로도 본다.
# 글자 비교만 하던 때는 $HOME을 다르게 적은 값이 그대로 통과했다 —
# /Users//sample, /users/sample(대소문자 무시 볼륨), /System/Volumes/Data/Users/sample
# (firmlink), $HOME을 가리키는 심볼릭 링크가 전부 $HOME과 같은 inode인데
# 루트로 받아들여졌고, safe_rm의 허용 접두 검사도 글자 비교라 두 겹이 같이
# 뚫렸다(재현됨). 연속 슬래시는 따로 거부한다 — 없는 경로라 inode를 못
# 구할 때도 표기가 하나로 정해지게.
resolve_root_override() {
    local name="$1"
    local value="$2"

    case "$value" in
        /*) : ;;
        *)
            warn "$name: 절대경로가 아니라 거부: '$value'"
            return 1
            ;;
    esac
    case "/$value/" in
        */../*|*/./*)
            warn "$name: '.'/'..' 경로 성분이 있어 거부: '$value'"
            return 1
            ;;
    esac
    while :; do
        case "$value" in
            */) value="${value%/}" ;;
            *) break ;;
        esac
    done
    case "$value" in
        *//*)
            warn "$name: 연속 슬래시(//)가 있어 거부: '$value'"
            return 1
            ;;
    esac
    case "$value" in
        ""|"/"|"$HOME"|"$HOME/src"|"/Users"|"/Users/${USER:-$(id -un)}")
            warn "$name: 루트로 쓰기엔 너무 넓거나 위험한 경로라 거부: '$value'"
            return 1
            ;;
    esac
    if [ ${#value} -lt 4 ]; then
        warn "$name: 경로가 너무 짧아 안전을 위해 거부: '$value'"
        return 1
    fi
    if [ -e "$value" ] || [ -L "$value" ]; then
        local value_id danger danger_id
        # -L: 심볼릭 링크면 가리키는 대상의 번호를 본다.
        value_id=$(stat -L -f '%d:%i' "$value" 2>/dev/null)
        if [ -z "$value_id" ]; then
            warn "$name: 경로를 stat 할 수 없어 안전을 위해 거부: '$value'"
            return 1
        fi
        for danger in "/" "$HOME" "$HOME/src" "/Users" "/Users/${USER:-$(id -un)}"; do
            danger_id=$(stat -L -f '%d:%i' "$danger" 2>/dev/null)
            [ -z "$danger_id" ] && continue
            if [ "$value_id" = "$danger_id" ]; then
                warn "$name: 위험 경로($danger)와 같은 디렉터리라 거부: '$value'"
                return 1
            fi
        done
    fi
    printf '%s\n' "$value"
}

# _in_sandbox <path> — CLEAN_SANDBOX_ROOT 아래의 경로면 0. safe_rm 전용.
# 글자 그대로의 경로가 아니라 부모 디렉터리의 실경로(pwd -P)로 비교한다 —
# 샌드박스 안에 놓인 심볼릭 링크 디렉터리를 거쳐 밖으로 나가는 경로
# (<샌드박스>/link/victim, link -> 샌드박스 밖)를 글자 비교는 못 걸러낸다.
# CLEAN_SANDBOX_ROOT 값 자체가 이상하면(빈 값, 상대경로, 없는 디렉터리,
# "/", $HOME) 가드가 무의미해지므로 전부 거부한다(fail-closed).
_in_sandbox() {
    local target="$1"
    local sb="${CLEAN_SANDBOX_ROOT:-}"
    local sb_phys parent parent_phys

    case "$sb" in
        /*) : ;;
        *)
            warn "safe_rm: CLEAN_SANDBOX_ROOT가 절대경로가 아니라 전부 거부('$sb'): $target"
            return 1
            ;;
    esac
    sb_phys=$(CDPATH='' cd "$sb" 2>/dev/null && pwd -P)
    case "$sb_phys" in
        ""|"/"|"$HOME")
            warn "safe_rm: CLEAN_SANDBOX_ROOT가 없는 디렉터리거나 너무 넓어서 전부 거부('$sb'): $target"
            return 1
            ;;
    esac

    parent="$(dirname "$target")"
    if [ -d "$parent" ]; then
        parent_phys=$(CDPATH='' cd "$parent" 2>/dev/null && pwd -P)
        case "$parent_phys/" in
            "$sb_phys"/*) return 0 ;;
        esac
        warn "safe_rm: 샌드박스($sb_phys) 밖이라 거부(실경로 부모: ${parent_phys:-확인 불가}): $target"
        return 1
    fi
    # 부모 디렉터리가 없으면 대상도 없다(지울 게 없음) — 글자 비교만 한다.
    case "$target" in
        "$sb"/*|"$sb_phys"/*) return 0 ;;
    esac
    warn "safe_rm: 샌드박스($sb_phys) 밖이라 거부: $target"
    return 1
}

# safe_rm <path> <allowed_prefix> — 존재 확인 -> chmod u+w(마운트 안 넘음)
# -> rm -rfx(마운트 안 넘음). 위험 경로/상대경로/"."·".." 포함 경로/허용
# 접두 밖의 경로는 전부 거부. path가 심볼릭 링크면 링크 자체만 지운다
# (대상을 따라가 지우지 않는다).
#
# allowed_prefix는 필수다 — 호출부가 "이 밑에서만 지운다"를 매번 명시해야
# 한다(예: /private/tmp/claude-<uid>, /private/tmp, NODE_MODULES_ROOTS의
# 각 root, $HOME/Library/Caches 등). path는 allowed_prefix "자신"이 아니라
# 반드시 그 아래(prefix/뭔가)여야 한다.
#
# CLEAN_SANDBOX_ROOT가 설정돼 있으면 그 밖의 대상은 추가로 거부한다
# (아래 "샌드박스 가드").
safe_rm() {
    local target="$1"
    local allowed_prefix="${2:-}"

    if [ -z "$target" ]; then
        warn "safe_rm: 빈 경로는 거부"
        return 1
    fi

    case "$target" in
        /*) : ;;
        *)
            warn "safe_rm: 절대경로가 아니라 거부: $target"
            return 1
            ;;
    esac

    case "/$target/" in
        */../*|*/./*)
            warn "safe_rm: '.'/'..' 경로 성분이 있어 거부: $target"
            return 1
            ;;
    esac

    # 후행 슬래시 전부 제거(여러 개 있어도).
    while :; do
        case "$target" in
            */) target="${target%/}" ;;
            *) break ;;
        esac
    done

    case "$target" in
        ""|"/"|"$HOME"|"$HOME/src"|"/Users"|"/Users/${USER:-$(id -un)}")
            warn "safe_rm: 위험 경로라 거부: $target"
            return 1
            ;;
    esac
    if [ ${#target} -lt 4 ]; then
        warn "safe_rm: 경로가 너무 짧아 안전을 위해 거부: $target"
        return 1
    fi

    if [ -z "$allowed_prefix" ]; then
        warn "safe_rm: 허용 접두(allowed_prefix) 없이는 삭제 거부: $target"
        return 1
    fi
    while :; do
        case "$allowed_prefix" in
            */) allowed_prefix="${allowed_prefix%/}" ;;
            *) break ;;
        esac
    done
    # allowed_prefix가 빈 값/'/'/ $HOME 처럼 너무 넓으면(예: 후행 슬래시
    # 제거 후 "/"가 ""가 돼서 "$target" 이 사실상 "/*" 패턴에 걸려 전부
    # 허용되는 회귀가 있었다) 거부한다 — 호출부가 항상 실질적인 하위
    # 경로를 줘야 한다.
    case "$allowed_prefix" in
        ""|"/"|"$HOME")
            warn "safe_rm: 허용 접두가 너무 넓어서 거부('$allowed_prefix'): $target"
            return 1
            ;;
    esac
    case "$target" in
        "$allowed_prefix"/*) : ;;
        *)
            warn "safe_rm: 허용 접두($allowed_prefix) 밖이라 거부: $target"
            return 1
            ;;
    esac

    # 샌드박스 가드(선택, 심층 방어): CLEAN_SANDBOX_ROOT가 설정돼 있으면
    # 위 검사를 다 통과한 대상이라도 그 디렉터리 밖이면 무조건 거부한다.
    # 테스트 하네스가 항상 이 값을 자기 mktemp 디렉터리로 설정한다 —
    # 루트 오버라이드(TMP_BUILDS_ROOT 등)를 빠뜨리거나 잘못 줘도 실제
    # 머신의 경로는 지워지지 않게 하는 두 번째 겹이다. 미설정이면 동작은
    # 예전과 같다. dry-run에서도 똑같이 거부한다(미리보기와 실제가 어긋나지
    # 않게).
    # "값이 비었는가"가 아니라 "설정됐는가"로 켠다. 빈 값으로 설정된 경우
    # (SB=$(mktemp -d)가 실패했거나 변수 이름을 틀려 CLEAN_SANDBOX_ROOT=""가
    # 된 경우)에 가드가 조용히 꺼지면, 가드가 막으려던 바로 그 실수에서
    # 가드가 없는 셈이다(재현됨). 빈 값은 _in_sandbox가 "절대경로가 아님"
    # 으로 전부 거부한다.
    if [ -n "${CLEAN_SANDBOX_ROOT+set}" ]; then
        if ! _in_sandbox "$target"; then
            return 1
        fi
    fi

    if [ ! -e "$target" ] && [ ! -L "$target" ]; then
        return 0
    fi

    # 심볼릭 링크면 링크 자체만 지운다(대상을 따라가 재귀 삭제하지 않음).
    if [ -L "$target" ]; then
        if [ "${DRY_RUN:-0}" = "1" ]; then
            printf '[dry-run] rm -f %s (symlink)\n' "$target"
            return 0
        fi
        rm -f "$target"
        return $?
    fi

    if [ "${DRY_RUN:-0}" = "1" ]; then
        printf '[dry-run] rm -rfx %s\n' "$target"
        return 0
    fi

    # 독립 가드: has_mount_under() 판정과 별개로, 실제 rm 직전에 다시 한 번
    # target 자신과 그 부모의 디바이스 번호를 비교한다. target 자신이
    # 마운트 포인트면(has_mount_under 호출을 빼먹었거나 그 판정에 구멍이
    # 있어도) 여기서 거부한다 — rm -rfx의 -x는 "시작점 기준" 마운트만
    # 안 넘기 때문에, 시작점 자체가 마운트면 그 볼륨 내용을 전부
    # 지워버리는 사고를 막기 위함(실제로 dmg로 재현됨).
    local target_dev parent_dev
    target_dev=$(stat -f '%d' "$target" 2>/dev/null)
    parent_dev=$(stat -f '%d' "$(dirname "$target")" 2>/dev/null)
    if [ -z "$target_dev" ] || [ -z "$parent_dev" ] || [ "$target_dev" != "$parent_dev" ]; then
        warn "safe_rm: 대상 자체가 마운트 포인트로 보여 거부(장치번호 불일치): $target"
        return 1
    fi

    # 마운트를 넘지 않고(-xdev) 쓰기 권한 없는 것만 chmod, 그다음 rm도
    # 마운트를 넘지 않는 -x로. has_mount_under() 판정에 구멍이 있어도
    # 이 두 겹이 실제 삭제가 마운트를 넘는 걸 막는다.
    with_timeout 60 find "$target" -xdev ! -perm -u+w -exec chmod u+w {} + >/dev/null 2>&1
    rm -rfx "$target"
}

# ---- 마운트/프로세스 점유 확인 -----------------------------------------------

# has_mount_under <path> — path 자신이 마운트 포인트이거나, path 하위
# 어딘가에 다른 파일시스템(마운트 포인트)이 있으면 0. mount(8) 출력
# 문자열 파싱에 의존하지 않고 디바이스 번호(stat -f %d)를 비교한다 —
# 경로에 " on "이 포함된 마운트(예: dmg 볼륨 이름)가 있어도 놓치지 않는다.
# stat 실패나 find 타임아웃 시에는 안전하게 "마운트 있음"(0)으로 간주한다.
#
# 중요: 기준 디바이스 번호(base_dev)는 target "자신"이 아니라 target의
# 부모에서 구한다. target 자신을 기준으로 잡으면 target 자체가 마운트
# 포인트인 경우(예: 세션 디렉터리 자체가 dmg 마운트 지점, node_modules
# 자체가 마운트 지점) 그 안의 모든 것이 "같은 디바이스"로 보여 마운트가
# 없다고 오판하는 회귀가 있었다(실제로 dmg로 재현됨) — 그래서 target
# 자신의 디바이스도 반드시 부모와 비교 대상에 넣는다.
has_mount_under() {
    local target="$1"
    case "$target" in */) target="${target%/}" ;; esac
    if [ ! -e "$target" ]; then
        return 1
    fi

    local parent base_dev
    parent="$(dirname "$target")"
    base_dev=$(stat -f '%d' "$parent" 2>/dev/null)
    if [ -z "$base_dev" ]; then
        warn "has_mount_under: 부모 stat 실패, 안전하게 마운트 있음으로 간주: $target"
        return 0
    fi

    # target 자신이 마운트 포인트인지부터 확인(부모와 디바이스가 다르면 0).
    local target_dev
    target_dev=$(stat -f '%d' "$target" 2>/dev/null)
    if [ -z "$target_dev" ]; then
        warn "has_mount_under: 대상 stat 실패, 안전하게 마운트 있음으로 간주: $target"
        return 0
    fi
    if [ "$target_dev" != "$base_dev" ]; then
        return 0
    fi

    # 하위 디렉터리들도 확인. -xdev로 마운트를 넘어가서까지 순회하지
    # 않는다(마운트 지점 디렉터리 항목 자체는 여전히 나열되므로 비교는
    # 그대로 동작한다 — find -xdev는 "지나서" 내려가지 않을 뿐, 그
    # 경계 디렉터리 자체는 보여준다).
    local devs rc
    # $1은 바깥 쉘이 아니라 이 bash -c 안에서 세 번째 인자("$target")로
    # 확장돼야 해서 일부러 홑따옴표로 감쌌다.
    # shellcheck disable=SC2016
    devs=$(with_timeout 60 bash -c '
        find "$1" -xdev -type d -print0 2>/dev/null | xargs -0 stat -f "%d" 2>/dev/null
    ' bash "$target")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        warn "has_mount_under: find/stat 타임아웃(또는 실패), 안전하게 마운트 있음으로 간주: $target"
        return 0
    fi

    # 목록을 here-document(<<EOF)로 읽지 않는다. bash 3.2는 here-document를
    # 임시 파일(/var/tmp/sh-thd-*)에 쓰는데, 그 쓰기가 실패하면(디스크가 꽉 찬
    # 상태 — 이 스크립트를 부르는 대표 상황이다) 루프가 한 번도 돌지 않고
    # 그대로 "마운트 없음"(1)이 됐다(재현됨: ulimit -f 0). 파이프로 읽으면
    # 임시 파일이 없다. 그리고 목록 끝에 표지 줄을 붙여, 그 줄까지 읽었을
    # 때만 "마운트 없음"으로 답한다 — 어떤 이유로든 목록을 끝까지 못 읽으면
    # "마운트 있음"이다. 장치번호는 숫자뿐이라 표지("end")와 겹치지 않는다.
    local d complete=0
    while IFS= read -r d; do
        if [ "$d" = "end" ]; then
            complete=1
            continue
        fi
        complete=0
        [ -z "$d" ] && continue
        if [ "$d" != "$base_dev" ]; then
            return 0
        fi
    done < <(printf '%s\nend\n' "$devs")
    if [ "$complete" != "1" ]; then
        warn "has_mount_under: 장치번호 목록을 끝까지 읽지 못함, 안전하게 마운트 있음으로 간주: $target"
        return 0
    fi
    return 1
}

# recent_mtime_state [-H] <path> <분> [find 조건...] — path 자신이나 그 하위에
# 최근 <분> 안에 mtime이 바뀐 항목이 있는지. 마운트는 넘지 않는다(-xdev).
# 뒤에 붙인 find 조건(예: -type f)은 그대로 -mmin 앞에 들어간다. -H를 주면
# path 자신이 심볼릭 링크일 때 그 대상을 본다(하위의 링크는 따라가지 않는다).
#
# 종료 상태가 세 갈래다:
#   0 — 최근 변경 있음
#   1 — 없음. find가 끝까지 정상 종료했을 때만 이 값이다
#   2 — 판정 불가(find가 오류로 끝남: 권한 거부, 경로 사라짐, 잘못된 인자)
# 삭제로 이어지는 값은 1 하나뿐이다. 호출부는 `if`로 받지 말고 case로 받아
# 1이 아닌 값은 전부 "지우지 않는다"로 처리한다 — `if ! recent_mtime_state`
# 처럼 쓰면 2가 "변경 없음"과 합쳐진다.
#
# 예전 판정은 `recent=$(find ... 2>/dev/null | head -1)` 이 비었는지만 봤다.
# find가 읽지 못한 디렉터리가 있어도, 인자가 깨져 아예 못 돌아도 출력이
# 비므로 "최근 변경 없음"과 구분되지 않았다(fail-open). 그렇다고 파이프의
# 종료 상태를 볼 수도 없었다 — pipefail이 켜져 있어서 head가 먼저 닫으면
# find가 SIGPIPE(141)로 죽고, 그것은 오류가 아니라 "찾았다"는 뜻이다. 그래서
# 파이프를 없앴다. find가 첫 항목을 찍고 스스로 끝나므로(-print -quit) head가
# 필요 없고, 종료 상태는 find의 것 그대로다. 찾은 뒤의 종료 상태는 보지
# 않는다(출력이 있으면 이미 "지우지 않는다"다).
recent_mtime_state() {
    local follow=""
    if [ "${1:-}" = "-H" ]; then
        follow="-H"
        shift
    fi
    local target="${1:-}"
    local mins="${2:-}"
    if [ -z "$target" ] || ! is_nonneg_int "$mins"; then
        return 2
    fi
    shift 2
    local out rc
    out=$(find ${follow:+-H} "$target" -xdev "$@" -mmin "-${mins}" -print -quit 2>/dev/null)
    rc=$?
    if [ -n "$out" ]; then
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        return 2
    fi
    return 1
}

# lsof 캐시: 한 번만 떠서(느리므로) 여러 path_busy 호출에서 재사용.
# _LSOF_OK=1일 때만 캐시를 신뢰한다. lsof가 없거나, 실패/타임아웃했거나,
# 출력이 비었으면 _LSOF_OK=0으로 남고 이후 path_busy/cwd_busy는 무조건
# "사용 중"(busy)으로 답한다 — 판단 불가를 "안 쓰고 있음"으로 오인해서
# 사용 중인 세션을 지우는 사고를 막기 위한 fail-safe.
_LSOF_ALL_CACHE=""
_LSOF_CWD_CACHE=""
_LSOF_FETCHED=0
_LSOF_OK=0

fetch_lsof_cache() {
    if [ "$_LSOF_FETCHED" = "1" ]; then
        return 0
    fi
    _LSOF_FETCHED=1
    if ! command -v lsof >/dev/null 2>&1; then
        _LSOF_OK=0
        warn "lsof 없음 — 이후 busy 판정은 안전하게 전부 '사용 중'으로 처리"
        return 0
    fi
    local all_out cwd_out rc_all rc_cwd
    all_out=$(with_timeout 60 lsof -b -w -Fn 2>/dev/null)
    rc_all=$?
    cwd_out=$(with_timeout 60 lsof -b -w -Fn -d cwd 2>/dev/null)
    rc_cwd=$?
    if [ "$rc_all" -eq 0 ] && [ -n "$all_out" ] && [ "$rc_cwd" -eq 0 ] && [ -n "$cwd_out" ]; then
        _LSOF_ALL_CACHE="$all_out"
        _LSOF_CWD_CACHE="$cwd_out"
        _LSOF_OK=1
    else
        _LSOF_OK=0
        warn "lsof 실패/타임아웃/빈 출력(rc_all=$rc_all rc_cwd=$rc_cwd) — 이후 busy 판정은 안전하게 전부 '사용 중'으로 처리"
    fi
}

# path_busy <path> — 캐시된 lsof 결과에서 해당 경로(또는 하위)를 열고 있는
# 프로세스가 있으면 0(=busy). lsof 캐시 확보 자체가 실패했으면 무조건 0.
path_busy() {
    local target="$1"
    case "$target" in */) target="${target%/}" ;; esac
    fetch_lsof_cache
    if [ "$_LSOF_OK" != "1" ]; then
        return 0
    fi
    case "$_LSOF_ALL_CACHE" in
        *"n${target}"*) return 0 ;;
    esac
    case "$_LSOF_CWD_CACHE" in
        *"n${target}"*) return 0 ;;
    esac
    return 1
}

# cwd_busy <path> — 어떤 프로세스의 cwd가 정확히 path 아래인 경우만 확인
# (열려 있는 파일 전체가 아니라 cwd만 보고 싶을 때 사용). lsof 캐시 확보
# 자체가 실패했으면 무조건 0.
cwd_busy() {
    local target="$1"
    case "$target" in */) target="${target%/}" ;; esac
    fetch_lsof_cache
    if [ "$_LSOF_OK" != "1" ]; then
        return 0
    fi
    case "$_LSOF_CWD_CACHE" in
        *"n${target}"*) return 0 ;;
    esac
    return 1
}

# ---- 모듈 진입점 공통 처리 ---------------------------------------------------

# parse_dry_run_arg — 모듈 스크립트가 단독 실행될 때 "--dry-run" 인자를 처리.
parse_dry_run_arg() {
    local a
    for a in "$@"; do
        case "$a" in
            --dry-run) DRY_RUN=1 ;;
        esac
    done
}
