#!/usr/bin/env bash
# do-resume.sh <job> — 실제 claude 재개 호출을 소유하는 단일 신뢰 wrapper.
#
# 배경(codex 리뷰 BLOCKER 2) — 예전 codex-wake.sh 는 CLAUDE_BIN·SESSION·PERM·프롬프트를
# 문자열로 이어붙여 그 텍스트를 codex(danger-full-access)에게 "실행해라"라고 넘겼다.
# 이 값들 중 하나에라도 따옴표·백틱·개행이 섞이면 codex 쪽 셸에서 인자 경계가 깨져
# 오동작하거나 임의 명령이 실행될 위험이 있었다. 이 스크립트는 그 조립을 완전히
# 없앤다 — codex 는 이제 `do-resume.sh <job>` 딱 두 토큰만 아는 채로 이 스크립트를
# 부르고, 실제 claude 호출에 쓰이는 값들은 전부 이 스크립트 "안에서" reservation.json
# 을 읽어 배열형 argv 로 조립한다. codex 에게 넘어가는 텍스트에는 애초에 위험한
# 값이 섞일 자리가 없다.
#
# 배경(codex 리뷰 BLOCKER 1) — claude 재개가 실제로 성공한 "직후", 그 사실을 판정
# 파일에 적기 "전"에 codex 가 죽으면, 예전 설계는 그 실행을 실패로 오판해 thaw.sh 가
# 같은 세션을 한 번 더 재개했다(이중 재개). 이 스크립트는 그 창을 최대한 좁힌다 —
# claude 를 부르기 "전"에 이번 실행의 nonce 를 resume-attempt.json 에 먼저 남겨두고,
# claude 호출이 끝나면 "곧바로" 같은 nonce 를 담아 wake-verdict.json 을 쓴다. 호출자
# (thaw.sh)는 두 파일의 nonce 가 일치하는지로 "이번 실행의 결과를 실제로 안다"와
# "결과를 알 수 없다(ambiguous)"를 구분한다 — freeze/scripts/thaw.sh 의 codex 분기,
# freeze/SKILL.md 의 "codex waker" 절 참고.
#
# 재시도하지 않는다 — 한 번 실행하고 attempt/verdict 파일만 원자적으로(임시 파일 +
# rename) 남긴다. 언제·몇 번 다시 부를지는 codex 의 판단(런북)에 맡긴다.
set -uo pipefail

JOB="${1:?usage: do-resume.sh <job>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
source "$SCRIPT_DIR/_claude.sh"
source "$SCRIPT_DIR/_donecheck.sh"

STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
DIR="$STATE_ROOT/$JOB"
RES="$DIR/reservation.json"
[ -f "$RES" ] || { echo "reservation 없음: $RES" >&2; exit 1; }

field() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1]))[process.argv[2]] ?? "")' "$RES" "$1"; }

CWD=$(field cwd)
SESSION=$(field session_id)
PERM=$(field permission_mode); [ -n "$PERM" ] || PERM="bypassPermissions"
MODE=$(field mode); [ -n "$MODE" ] || MODE="resume"
HANDOFF=$(field handoff)
CREATED_AT=$(field created_at)

# MINOR J — 이 스크립트가 claude 호출을 소유하니, cwd 이동도 스스로 책임진다.
# 지금은 thaw.sh(cd "$CWD")와 codex-wake.sh(codex exec -C "$CWD")가 항상 먼저
# 이동해줘서 정상 경로는 무사했지만, --resume 은 프로젝트 디렉토리 기준으로 세션을
# 찾으므로 이 스크립트를 다른 경로에서 직접 불러도(테스트·수동 호출 등) 안전해야 한다.
cd "$CWD" || { echo "cwd 이동 실패: $CWD" >&2; exit 1; }

ATTEMPT="$DIR/resume-attempt.json"
VERDICT="$DIR/wake-verdict.json"

# 원자적 쓰기 — 임시 파일 후 rename. 쓰다 만 파일을 다른 프로세스(thaw.sh)가
# 읽는 사고를 막는다. mv -f 는 같은 파일시스템 안에서 원자적이다(POSIX rename(2)).
atomic_write() {  # atomic_write <경로> <본문>
  local path="$1" body="$2" tmp
  tmp="${path}.tmp.$$"
  printf '%s' "$body" > "$tmp" || return 1
  mv -f "$tmp" "$path"
}

# nonce — 이번 실행 하나를 식별한다. 초 단위 시각만으로는 같은 초에 재시도가 몰리면
# 충돌할 수 있어 pid·RANDOM 을 더한다(암호학적 강도는 필요 없다 — "이번 실행"과
# "다른 실행"을 구분만 하면 된다).
NONCE="$(date +%s)-$$-$RANDOM"
STARTED_AT=$(date +%s)

ATTEMPT_JSON=$(node -e '
const [nonce, startedAt, mode, session] = process.argv.slice(1);
console.log(JSON.stringify({nonce, started_at: parseInt(startedAt), mode, session}, null, 2));
' "$NONCE" "$STARTED_AT" "$MODE" "$SESSION")
atomic_write "$ATTEMPT" "$ATTEMPT_JSON" || { echo "resume-attempt.json 기록 실패" >&2; exit 1; }

# claude 를 부르기 "직전에" 취소·완료 여부를 확인한다(BLOCKER C). codex 안에서 이
# 스크립트가 불릴 때까지 이미 시간이 걸렸을 수 있으므로(런북 읽기·판단 등) 여기서
# reservation.json 을 다시 읽어 최신 상태를 본다 — codex-wake.sh 가 자기 호출 전에
# 한 번 확인한 것과는 별개의, claude 호출 직전의 마지막 방어선이다. 취소·완료면
# claude 를 아예 부르지 않고 (이미 위에서 남긴 attempt 와 짝이 맞는) verdict 를
# resumed:false 로 남긴 뒤 전용 종료코드 3 으로 나간다 — thaw.sh 는 이 exit code 를
# "이중 재개 위험이 있는 ambiguous/실패"가 아니라 "의도적으로 재개를 건너뜀"으로
# 보고 폴백하지 않아야 한다(아래 thaw.sh/codex-wake.sh 수정 참고).
BLOCK_REASON=""
if BLOCK_REASON=$(freeze_reservation_blocked "$DIR" "$STATE_ROOT" "$HANDOFF" "$CREATED_AT"); then
  echo "재개 대상이 취소·완료됨($BLOCK_REASON) — claude 를 부르지 않는다" >&2
  VERDICT_JSON=$(node -e '
const [nonce, reason] = process.argv.slice(1);
console.log(JSON.stringify({resumed: false, attempts: 0, rc: null, reason, nonce}, null, 2));
' "$NONCE" "$BLOCK_REASON")
  atomic_write "$VERDICT" "$VERDICT_JSON" || true
  exit 3
fi

CLAUDE_BIN=$(resolve_claude_bin) || { echo "claude 실행 파일을 찾지 못함" >&2; exit 1; }

PROMPT_FILE="$DIR/wake-prompt.txt"
[ -f "$PROMPT_FILE" ] || { echo "프롬프트 파일 없음(codex-wake.sh 가 먼저 써둬야 한다): $PROMPT_FILE" >&2; exit 1; }
PROMPT=$(cat "$PROMPT_FILE")

# MINOR K — nonce 로 파일명을 나눈다. 예전엔 세 곳(이 스크립트, thaw.sh 의 ledger/
# resume 두 분기)이 전부 같은 resume-output.txt 를 썼다 — codex 시도가 실패해 thaw.sh
# 가 bash 폴백(run_probe+run_resume)을 돌면, 폴백의 출력이 이 스크립트가 남긴 codex
# 시도의 출력을 덮어써 사람이 "codex 시도에서 정확히 무슨 일이 있었는지"를 잃어버렸다.
OUTPUT="$DIR/resume-output.$NONCE.txt"

# 실제 재개 — 배열형 argv 로만 구성한다. 셸 문자열 조립·재해석이 전혀 없으므로
# SESSION·PERM·PROMPT 에 무엇이 들어있든(따옴표·개행 포함) 인자 경계가 깨지지 않는다.
if [ "$MODE" = "ledger" ]; then
  cmd=("$CLAUDE_BIN" -p --permission-mode "$PERM" "$PROMPT")
else
  cmd=("$CLAUDE_BIN" -p --resume "$SESSION" --permission-mode "$PERM" "$PROMPT")
fi
"${cmd[@]}" > "$OUTPUT" 2>&1
rc=$?
# 사람이 찾기 쉽게 "마지막 것"을 가리키는 포인터를 남긴다 — 실패해도(예: 심링크를
# 지원하지 않는 파일시스템) 본체(OUTPUT)는 이미 안전하게 저장돼 있으니 무시한다.
ln -sf "$(basename "$OUTPUT")" "$DIR/resume-output.txt" 2>/dev/null || true

# 테스트 전용 — claude 호출 자체는 이미 끝났지만(성공이든 실패든) verdict 를 쓰기
# "전"에 이 프로세스가 죽는 상황(BLOCKER 1 이 좁히려는 바로 그 창)을 재현한다.
# 운영 경로에서 이 변수를 설정할 이유는 없다 — freeze/tests/test_freeze.sh 참고.
if [ "${FREEZE_TEST_KILL_AFTER_RESUME:-}" = "1" ]; then
  exit 111
fi

# MAJOR G — resumed(=rc===0) 하나만으로는 "claude 가 아예 시작도 못 했다"와 "세션을
# 열어 일을 하다가 끝에서 실패했다"를 가르지 못한다. 후자를 재시도·폴백 대상(예전의
# clean_fail)으로 취급하면 이미 진행된 세션을 또 여는 사고가 난다("옛 wake-verdict.json
# 이 남아 있어도 성공으로 오판하지 않는다"류의 BLOCKER A 와 증상은 다르지만 뿌리가
# 같다 — "결과를 확실히 모르면 재시도하지 마라"). 그래서 outcome 필드로 한 번 더
# 가른다:
#   preflight_fail — claude 가 일을 시작하기도 전에 거절당했다는 확실한 증거(출력
#                    "앞부분"에서 사용량 한도·인증 배너를 명확히 잡았을 때만)가 있을
#                    때만 이렇게 본다. 이 경우만 재시도·폴백이 안전하다.
#   ambiguous      — 그 외 전부(rc!=0 인데 위 신호를 못 찾음). claude 가 이미 일을
#                    했을 수 있으므로 재시도도 폴백도 하면 안 된다. 판정이 애매하면
#                    반드시 이쪽으로 떨어뜨린다 — 세션을 두 번 여는 게 한 번 놓치는
#                    것보다 훨씬 나쁘다.
# 출력 전체가 아니라 "앞부분"만 보는 이유 — claude 가 도중까지 일을 하다가 뒤에서
# 실패한 세션의 로그 어딘가에 "usage limit" 같은 문자열이 우연히(예: 사용자 요청
# 내용 인용, 도구 출력 일부) 섞여도 preflight_fail 로 오판하지 않기 위해서다.
OUTCOME="ambiguous"
REASON="claude 재개 명령이 rc=$rc 로 종료"
if [ "$rc" = 0 ]; then
  OUTCOME="success"
  REASON="정상 재개"
else
  PREFLIGHT_HEAD=$(head -c 2000 "$OUTPUT" 2>/dev/null || true)
  if printf '%s' "$PREFLIGHT_HEAD" | grep -qiE 'usage limit|rate limit|limit reached|5-hour limit|weekly limit|please run .{0,20}login|not logged in|authentication failed|invalid api key|unauthorized'; then
    OUTCOME="preflight_fail"
    REASON="claude 가 일을 시작하기 전에 거절함(출력 앞부분에서 한도/인증 배너 감지, rc=$rc)"
  else
    REASON="claude 재개 명령이 rc=$rc 로 종료 — 출력 앞부분에서 사전 거절 신호를 못 찾음(claude 가 이미 일을 했을 수 있어 ambiguous 로 남김)"
  fi
fi
VERDICT_JSON=$(node -e '
const [nonce, rc, reason, outcome] = process.argv.slice(1);
console.log(JSON.stringify({resumed: rc === "0", attempts: 1, rc: parseInt(rc), reason, outcome, nonce}, null, 2));
' "$NONCE" "$rc" "$REASON" "$OUTCOME")
atomic_write "$VERDICT" "$VERDICT_JSON" || { echo "wake-verdict.json 기록 실패" >&2; exit 1; }

exit "$rc"
