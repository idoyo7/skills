#!/usr/bin/env bash
# codex-wake.sh <job> — 땡 이후 구간(프로브·재개 시점·재시도 판단)을 codex 에게 맡긴다.
# thaw.sh 가 reservation.json 의 waker=codex 일 때만 부른다. 대기(sleep)는 여전히
# thaw.sh 의 detached 슬리퍼가 맡고 있고, 이 스크립트는 땡이 온 "이후"만 담당한다.
#
# 재개 실행 자체는 이 스크립트가 아니라 do-resume.sh 가 소유한다(codex 리뷰 BLOCKER 1/2
# 대응) — 이 스크립트가 하는 일은 codex 에게 (1) do-resume.sh 를 언제·몇 번 부를지
# 판단하게 하는 런북을 써주고 (2) codex 를 실행한 뒤 (3) do-resume.sh 가 남긴
# attempt/verdict 파일의 nonce 가 일치하는지로 "이번 실행이 확실히 성공했는가"만
# 판정하는 것이다. codex 에게 넘기는 명령 텍스트에는 CLAUDE_BIN·SESSION·PERM 같은
# 값이 전혀 섞이지 않는다 — 그 값들은 do-resume.sh 가 자기 안에서 reservation.json
# 을 다시 읽어 배열형 argv 로 조립한다.
#
# 계약 — thaw.sh 가 exit code 로 성공/폴백을 가른다:
#   0        재개 완료(attempt/verdict nonce 가 일치하고 resumed:true) — thaw.sh 는
#            이 결과를 최종 재개 결과로 받아들이고 haiku 프로브·재개 호출을 하지 않는다.
#   1        확실한 성공을 확인하지 못함 — codex 실행 자체가 실패했을 수도, do-resume.sh
#            가 명확한 실패를 남겼을 수도, 결과가 불명확(ambiguous)할 수도 있다. 이 셋을
#            가르는 건 thaw.sh 의 몫이다 — thaw.sh 가 resume-attempt.json/wake-verdict.json
#            을 직접 다시 읽어 "폴백해도 안전한지"를 판단한다(이중 재개 방지, BLOCKER 1).
#   2        codex 실행 파일 자체를 못 찾음, 또는 준비 단계(이전 판정 정리·프롬프트/런북
#            기록)가 실패해 codex 를 아예 부르지 못함.
#   3        예약이 이미 취소됐거나(cancelled) 다른 경로로 이미 완료됐다(done) — codex 를
#            아예 부르지 않았다(BLOCKER C). thaw.sh 는 이 경우도 attempt/verdict 를 직접
#            다시 읽어(resumed:false, reason: "cancelled"|"done") 폴백하지 않고 조용히
#            끝내야 한다 — 취소·완료된 예약을 폴백으로 다시 재개하면 안 된다.
# 어느 경우든 이 스크립트가 죽어서 thaw.sh 전체가 죽는 일은 없어야 한다(set -e 를 안 쓰는 이유).
set -uo pipefail

JOB="${1:?usage: codex-wake.sh <job>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
source "$SCRIPT_DIR/_claude.sh"
source "$SCRIPT_DIR/_donecheck.sh"

STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
DIR="$STATE_ROOT/$JOB"
RES="$DIR/reservation.json"
[ -f "$RES" ] || { echo "reservation 없음: $RES" >&2; exit 2; }

# 이전 판정/시도 파일 정리 — reservation 존재를 확인한 직후, claude/codex 실행 파일
# 탐색보다 먼저 지운다(BLOCKER A). 예전엔 이 정리가 실행 파일 탐색(아래) 뒤에 있어서,
# 탐색이 실패해 exit 2 로 빠지는 경로들이 이전 창의 resume-attempt.json/wake-verdict.json
# 을 그대로 남긴 채 나갔다 — 그 뒤 thaw.sh 의 check_resume_attempt 가 남아있는 옛 쌍을
# "이번 실행의 결과"로 오인해 claude 를 한 번도 안 부르고 성공(done)으로 끝내는 사고가
# 났다. 반환값을 검사하는 이유(codex 리뷰 MAJOR 1)는 그대로다 — 여기서 실패하면
# do-resume.sh 를 아예 부르지 않으므로, thaw.sh 입장에서는 "시도 흔적 없음"으로 보여
# 안전하게 bash 경로로 폴백한다.
ATTEMPT="$DIR/resume-attempt.json"
VERDICT="$DIR/wake-verdict.json"
rm -f "$VERDICT" "$ATTEMPT" || { echo "이전 판정/시도 파일 정리 실패 — 폴백 필요" >&2; exit 2; }

field() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1]))[process.argv[2]] ?? "")' "$RES" "$1"; }

CWD=$(field cwd)
HANDOFF=$(field handoff)
MODE=$(field mode); [ -n "$MODE" ] || MODE="resume"
CREATED_AT=$(field created_at)

PROBE_INTERVAL="${FREEZE_PROBE_INTERVAL:-900}"
PROBE_MAX="${FREEZE_PROBE_MAX:-12}"

# 취소·완료 여부를 codex 를 부르기 "전에" 확인한다(BLOCKER C item 2). codex exec 는
# 기본 최대 3시간(PROBE_MAX × PROBE_INTERVAL)을 안에서 보낼 수 있는데, 그 안에서는
# 아무도 취소·완료 신호를 보지 않는다 — 여기서 막아두지 않으면 이미 취소된 예약도
# codex 를 그대로 부르게 된다. do-resume.sh 도 claude 를 부르기 직전에 같은 검사를
# 한 번 더 하지만(그 사이 취소될 수 있으므로), 여기서 걸러두면 애초에 codex 실행
# 자체(비용)를 아낀다. attempt/verdict 를 do-resume.sh 와 같은 모양으로 직접 남겨야
# thaw.sh 의 check_resume_attempt 가 이 경우도 "블록됨"으로 읽는다.
BLOCK_REASON=""
if BLOCK_REASON=$(freeze_reservation_blocked "$DIR" "$STATE_ROOT" "$HANDOFF" "$CREATED_AT"); then
  echo "재개 대상이 취소·완료됨($BLOCK_REASON) — codex 를 부르지 않는다" >&2
  echo "[$(date '+%F %T')] 취소·완료 감지($BLOCK_REASON) — codex 호출 생략" >> "$DIR/codex-wake.log"
  NONCE="$(date +%s)-$$-$RANDOM"
  atomic_write() {  # atomic_write <경로> <본문> — do-resume.sh 의 같은 이름 함수와 동일 계약.
    local path="$1" body="$2" tmp
    tmp="${path}.tmp.$$"
    printf '%s' "$body" > "$tmp" || return 1
    mv -f "$tmp" "$path"
  }
  ATTEMPT_JSON=$(node -e '
const [nonce, startedAt, mode] = process.argv.slice(1);
console.log(JSON.stringify({nonce, started_at: parseInt(startedAt), mode, session: null}, null, 2));
' "$NONCE" "$(date +%s)" "$MODE")
  atomic_write "$ATTEMPT" "$ATTEMPT_JSON" || true
  VERDICT_JSON=$(node -e '
const [nonce, reason] = process.argv.slice(1);
console.log(JSON.stringify({resumed: false, attempts: 0, rc: null, reason, nonce}, null, 2));
' "$NONCE" "$BLOCK_REASON")
  atomic_write "$VERDICT" "$VERDICT_JSON" || true
  exit 3
fi

# claude 실행 파일 존재는 여기서도 한 번 확인해둔다 — 없으면 do-resume.sh 를 아무리
# 불러도 매번 실패할 뿐이니, codex 를 부르기 전에 곧장 폴백시키는 편이 낫다.
resolve_claude_bin >/dev/null || { echo "claude 실행 파일을 찾지 못함 — 폴백 필요" >&2; exit 2; }

# codex 실행 파일 탐색 — FREEZE_CLAUDE_BIN 과 같은 원칙(_claude.sh 참고): 명시로
# 지정했으면 그 값만 검증하고, 없으면 PATH → 잘 알려진 설치 경로 순으로 찾는다.
if [ -n "${FREEZE_CODEX_BIN:-}" ]; then
  if [ -x "$FREEZE_CODEX_BIN" ]; then
    CODEX_BIN="$FREEZE_CODEX_BIN"
  else
    echo "FREEZE_CODEX_BIN 이 실행 불가 — $FREEZE_CODEX_BIN" >&2
    exit 2
  fi
elif c=$(command -v codex 2>/dev/null) && [ -x "$c" ]; then
  CODEX_BIN="$c"
else
  CODEX_BIN=""
  for ver in $(ls -1 "$HOME/.nvm/versions/node" 2>/dev/null | sort -r); do
    if [ -x "$HOME/.nvm/versions/node/$ver/bin/codex" ]; then
      CODEX_BIN="$HOME/.nvm/versions/node/$ver/bin/codex"
      break
    fi
  done
  if [ -z "$CODEX_BIN" ] && [ -x /opt/homebrew/bin/codex ]; then
    CODEX_BIN=/opt/homebrew/bin/codex
  fi
  if [ -z "$CODEX_BIN" ] && [ -x /usr/local/bin/codex ]; then
    CODEX_BIN=/usr/local/bin/codex
  fi
fi
if [ -z "${CODEX_BIN:-}" ] || [ ! -x "$CODEX_BIN" ]; then
  echo "codex 실행 파일을 찾지 못함 — 폴백 필요" >&2
  exit 2
fi

RUNBOOK="$DIR/wake-runbook.md"
PROMPT_FILE="$DIR/wake-prompt.txt"
DO_RESUME="$SCRIPT_DIR/do-resume.sh"

# 재개 프롬프트 — thaw.sh 의 프롬프트들과 반드시 같은 텍스트를 써야 한다(thaw.sh 의
# run_resume()·is_real_wfledger() 참고). 별도 프로세스로 나뉘어 있어 자동으로
# 동기화되지 않으니 thaw.sh 의 프롬프트를 고치면 이쪽도 같이 고쳐야 한다.
# FREEZE_CHAIN_NOTE 는 thaw.sh 가 체인 선무장 결과(성공/실패 안내문)를 이미 계산해
# 넘겨주는 값이다 — 체인 로직 자체는 thaw.sh 가 계속 소유하고, 여기서는 그 결과 문구만
# 프롬프트 끝에 그대로 붙인다.
#
# ledger 모드 안에서도 handoff 가 진짜 wfledger 원장인지로 갈린다(MAJOR B, thaw.sh
# 의 is_real_wfledger 와 같은 판정 — <!-- freeze-ledger v1 --> 마커 유무). snap 이
# 세션 탐지 실패로 mode 를 ledger 로 자동 강등했을 때의 handoff 는 원장이 아니라서,
# "## 워크플로우 런" 섹션을 찾거나 wfledger.sh set-session 을 부르라는 지시가 맞지 않는다.
CHAIN_NOTE="${FREEZE_CHAIN_NOTE:-}"
# 완료 안내는 체인 유무와 무관하게 항상 싣는다 — bash 경로(thaw.sh 의 DONE_NOTE)와
# 같은 문구를 받아 codex 가 띄우는 재개 세션도 done 신호를 남기게 한다.
DONE_NOTE="${FREEZE_DONE_NOTE:-}"

# MAJOR H — thaw.sh 가 다음 창을 이미 선무장했으면 그 땡 시각을 넘겨서까지 codex
# 내부에서 재시도하면 안 된다(넘기면 부모·자식이 같은 세션에 동시에 --resume 을
# 건다). thaw.sh 의 run_probe() 는 이 시각을 결정적으로 지키지만, codex 자신의
# 재시도 루프는 bash 코드가 아니라 codex 의 판단이라 런북에 명시 지시로 넣는
# 수밖에 없다 — 이 스크립트가 codex exec 를 "한 번" 부르고 그 안에서 codex 가
# 스스로 재시도 여부를 정하는 구조이기 때문이다.
RETRY_DEADLINE="${FREEZE_RETRY_DEADLINE:-}"
DEADLINE_CLAUSE=""
if [ -n "$RETRY_DEADLINE" ]; then
  DEADLINE_HUMAN=$(node -e 'console.log(new Date(parseInt(process.argv[1])*1000).toString())' "$RETRY_DEADLINE" 2>/dev/null || echo "epoch $RETRY_DEADLINE")
  DEADLINE_CLAUSE="- **위 재시도 정책과 별개로**, 지금까지 몇 번을 재시도했든 $DEADLINE_HUMAN 을 넘기면 더 이상 재시도하지 말고 즉시 포기해라 — 이미 선무장된 다음 창이 그 시각에 깨어나 같은 세션에 --resume 을 다시 걸려고 하므로, 그 전에 반드시 멈춰야 한다(같은 세션이 동시에 두 번 열리는 사고를 막기 위함)."
fi

IS_REAL_LEDGER=0
[ -f "$HANDOFF" ] && head -5 "$HANDOFF" 2>/dev/null | grep -qF '<!-- freeze-ledger v1 -->' && IS_REAL_LEDGER=1
if [ "$MODE" = "ledger" ] && [ "$IS_REAL_LEDGER" = 1 ]; then
  RESUME_PROMPT="땡 — freeze 스킬(ledger 모드)로 예약된 재개다. 대화 문맥이 전혀 없다 — $HANDOFF (wf ledger) 가 유일한 명세다. 이 파일을 읽고 '## 워크플로우 런' 에 등록된 journal.jsonl 을 확인해 이미 끝난(result 줄이 있는) agent 호출은 건너뛰고, 남은 단계를 이어서 완료하는 연속 스크립트를 새로 작성해 돌려라. 새 워크플로우를 등록하기 전에 먼저 'bash ~/.claude/skills/freeze/scripts/wfledger.sh set-session --ledger $HANDOFF --cwd $CWD' 로 원장의 session 필드를 지금 이 세션으로 갱신해라 — 원장의 session 은 이전(한도에 막힌) 세션 UUID 로 고정돼 있어서, 갱신 없이 wfledger.sh run 을 부르면 journal/script 경로가 존재하지 않는 옛 세션 디렉토리로 계산된다. 끝나면 원장의 단계 체크박스를 갱신하고 '## 재개 결과' 섹션에 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}${DONE_NOTE}"
elif [ "$MODE" = "ledger" ]; then
  RESUME_PROMPT="땡 — freeze 스킬(ledger 모드)로 예약된 재개다. 대화 문맥이 전혀 없다 — $HANDOFF 가 유일한 명세다. 이 문서는 wfledger 원장이 아니다(워크플로우 런 등록·wfledger.sh 호출 불필요) — 파일을 읽고 중단된 작업을 이어서 완료해줘. 끝나면 같은 파일 하단에 '## 재개 결과' 섹션으로 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}${DONE_NOTE}"
else
  RESUME_PROMPT="땡 — freeze 스킬로 예약된 재개다. $HANDOFF 를 읽고 중단된 작업을 이어서 완료해줘. 끝나면 같은 파일 하단에 '## 재개 결과' 섹션으로 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}${DONE_NOTE}"
fi
printf '%s' "$RESUME_PROMPT" > "$PROMPT_FILE" || { echo "프롬프트 파일 기록 실패 — 폴백 필요" >&2; exit 2; }

# 런북에 넣을 실행 명령 — do-resume.sh 경로와 job 이름을 printf %q 로 셸-안전하게
# 이스케이프해 넣는다(codex 리뷰 BLOCKER 2). job 이름·경로에 따옴표·공백·개행이
# 있어도 codex 가 이 텍스트를 그대로 셸에 붙여넣었을 때 인자 경계가 깨지지 않는다 —
# do-resume.sh 자신은 job 하나만 받고 나머지 값(CLAUDE_BIN·SESSION·PERM·프롬프트)은
# reservation.json/wake-prompt.txt 를 다시 읽어 자기 안에서 배열형 argv 로 조립하므로,
# 애초에 위험한 값이 이 명령줄 텍스트 자체에는 나타나지 않는다.
printf -v DO_RESUME_Q '%q' "$DO_RESUME"
printf -v JOB_Q '%q' "$JOB"
RESUME_CMD_LINE="$DO_RESUME_Q $JOB_Q"

gen_runbook() {
  cat > "$RUNBOOK" <<RUNBOOKEOF
# freeze 예약 재개 런북 (codex waker)

이 문서는 freeze 스킬이 5시간 사용량 한도 리셋(땡) 시점에 세션을 헤드리스로
재개하기 위해 codex 에게 넘기는 절차서다. **아래 적힌 절차만 그대로 수행해라.
다른 파일을 고치거나 다른 작업을 시작하지 마라.**

## 실행할 명령

다음 명령을 정확히 그대로(변형하지 말고) 실행해라 — 이미 셸-안전하게 이스케이프돼
있으니 따옴표를 더하거나 빼지 마라:

\`\`\`bash
$RESUME_CMD_LINE
\`\`\`

이 명령이 실제 claude 재개 호출을 전부 수행하고 결과를 판정 파일에 남긴다. **너는
언제·몇 번 이 명령을 다시 부를지만 판단해라 — 명령 자체의 인자를 바꾸거나, 프롬프트를
직접 만들어 다른 방식으로 재개를 시도하지 마라.** 이 명령은 매번 재시도 없이 딱 한 번만
시도하고 끝난다.

## 재시도 정책

**재시도 여부는 오직 \`outcome\` 필드로만 판단해라 — 출력 파일(resume-output.*.txt)
을 직접 읽고 스스로 "한도 문구가 있나" 를 판단하지 마라.** do-resume.sh 가 이미
그 판단을 마쳐 \`outcome\` 에 적어뒀다 — 같은 판단을 네가 또 하면 서로 다른 결론이
나올 수 있고, 그 어긋남이 바로 같은 세션을 두 번 여는 사고로 이어진다.

- 위 명령을 실행한 뒤 \`$VERDICT\` 를 읽어라(스키마는 아래 참고).
- \`resumed\` 가 \`true\` 면 끝난 것이다. 더 부르지 마라.
- \`reason\` 이 \`cancelled\`(예약이 취소됨) 또는 \`done\`(다른 경로로 이미 완료됨)이면
  재시도하지 말고 즉시 중단해라 — 예약 자체가 더 이상 유효하지 않다는 뜻이라 다시
  불러도 매번 같은 결과만 나온다.
- \`outcome\` 이 \`preflight_fail\` 이면(claude 가 일을 시작하기도 전에 사용량 한도·
  인증 문제로 거절당함) ${PROBE_INTERVAL}초 쉬었다가 같은 명령을 다시 실행해라.
  최대 ${PROBE_MAX}회까지 반복한다. ${PROBE_MAX}회를 다 써도 안 풀리면 포기해라
  (마지막 \`$VERDICT\` 를 그대로 둔다).
- \`outcome\` 이 \`ambiguous\` 면 — claude 가 이미 세션을 열어 일을 하다가 실패했을
  수 있다는 뜻이다. **절대 다시 부르지 마라.** 같은 세션을 두 번 여는 사고가 재시도
  한 번 놓치는 것보다 훨씬 나쁘다. 즉시 중단해라(마지막 \`$VERDICT\` 를 그대로 둔다).
${DEADLINE_CLAUSE:+$DEADLINE_CLAUSE}

## 판정 파일

위 명령이 실행할 때마다 \`$VERDICT\` 를 스스로 남긴다(너는 이 파일을 직접 쓰지 않는다,
읽기만 한다):

\`\`\`json
{"resumed": true, "attempts": 1, "rc": 0, "reason": "정상 재개", "outcome": "success", "nonce": "..."}
\`\`\`

- \`resumed\`: 이번 실행이 성공(rc=0)했으면 \`true\`, 실패했으면 \`false\`.
- \`rc\`: 이번 실행의 종료코드.
- \`reason\`: 왜 이 판정이 나왔는지 한 줄 설명.
- \`outcome\`: \`success\`(성공) | \`preflight_fail\`(재시도 대상) | \`ambiguous\`(재시도
  금지) — 재시도 여부는 이 필드만 보고 판단해라. \`reason\` 이 \`cancelled\`/\`done\`
  일 때는 이 필드가 아예 없을 수 있다(그땐 위 취소·완료 규칙이 우선한다).
- \`nonce\`: 이번 한 번의 실행을 식별하는 값(너는 신경 쓸 필요 없다 — 호출자가 내부적으로만 쓴다).
RUNBOOKEOF
}
gen_runbook || { echo "런북 기록 실패 — 폴백 필요" >&2; exit 2; }

echo "[$(date '+%F %T')] codex-wake 시작 — job=$JOB runbook=$RUNBOOK" >> "$DIR/codex-wake.log"

# codex 실행 — 프롬프트는 짧게, 실제 지시는 런북에 있다. 이 텍스트에는 CLAUDE_BIN·
# SESSION·PERM 같은 동적 값이 전혀 섞이지 않는다(런북 경로 하나뿐).
"$CODEX_BIN" exec -s danger-full-access --skip-git-repo-check -C "$CWD" \
  -o "$DIR/codex-last-message.txt" \
  "freeze 스킬의 예약 재개(땡)다. $RUNBOOK 를 읽고 거기 적힌 대로만 수행해라. 다른 작업은 하지 마라." \
  >> "$DIR/codex-wake.log" 2>&1
CODEX_RC=$?
echo "[$(date '+%F %T')] codex exec 종료 rc=$CODEX_RC" >> "$DIR/codex-wake.log"

# 최종 판정 — attempt/verdict 의 nonce 가 일치하고 resumed:true 일 때만 성공으로
# 본다. resumed:false 이면서 reason 이 cancelled/done 이면 "취소·완료로 의도적으로
# 건너뜀"(blocked)으로 따로 가른다 — do-resume.sh 가 claude 호출 직전에 이 상태를
# 만났을 때도 같은 모양으로 남기므로(BLOCKER C item 1) 여기서 같이 잡힌다. 그 외
# resumed:false 는 outcome 필드로 한 번 더 가른다(MAJOR G) — outcome 이
# preflight_fail 일 때만 clean_fail(폴백 가능)로 보고, 그 외(파일 없음·파싱 실패·
# nonce 불일치·outcome 이 ambiguous 이거나 아예 없음)는 전부 ambiguous 로 묶어
# exit 1 로 통일한다 — "왜" 실패로 봤는지 세분화하는 건 thaw.sh 의 몫이다(BLOCKER 1
# 대응: ambiguous 와 확실한 실패를 가르려면 attempt 파일까지 봐야 하는데, 그 판단은
# thaw.sh 가 폴백 여부를 정하는 바로 그 자리에서 하는 게 자연스럽다).
JUDGED=$(node -e '
const fs = require("fs");
const dir = process.argv[1];
let attempt = null, verdict = null;
try { attempt = JSON.parse(fs.readFileSync(dir + "/resume-attempt.json")); } catch {}
if (!attempt) { console.log("none"); process.exit(0); }
try { verdict = JSON.parse(fs.readFileSync(dir + "/wake-verdict.json")); } catch {}
if (!verdict || verdict.nonce !== attempt.nonce) { console.log("ambiguous"); process.exit(0); }
if (verdict.resumed === true) { console.log("success"); process.exit(0); }
if (verdict.reason === "cancelled" || verdict.reason === "done") { console.log("blocked:" + verdict.reason); process.exit(0); }
console.log(verdict.outcome === "preflight_fail" ? "clean_fail" : "ambiguous");
' "$DIR")

case "$JUDGED" in
  success)
    echo "[$(date '+%F %T')] codex-wake 성공 — do-resume.sh 가 확정된 성공 판정을 남김" >> "$DIR/codex-wake.log"
    exit 0
    ;;
  ambiguous)
    echo "결과 불명확(ambiguous) — 시도는 있었으나 판정을 확정할 수 없음: $DIR" >&2
    exit 1
    ;;
  blocked:*)
    echo "재개 대상이 취소·완료됨(${JUDGED#blocked:}) — claude 를 부르지 않고 끝남" >&2
    exit 3
    ;;
  clean_fail)
    echo "do-resume.sh 가 명확한 실패를 남김 — 폴백 가능" >&2
    exit 1
    ;;
  *)
    echo "재개 시도 흔적 없음(codex exec rc=$CODEX_RC) — 폴백 필요" >&2
    exit 1
    ;;
esac
