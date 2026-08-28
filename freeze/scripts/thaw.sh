#!/usr/bin/env bash
# thaw — 땡. 예약 시각까지 자고, haiku 프로브로 한도 해제를 확인한 뒤 세션을 헤드리스로 재개한다.
# freeze.sh reserve 가 node spawn(detached:true) 으로 기동한다. 직접 부를 일은 캐치업(check) 정도.
set -uo pipefail

JOB="${1:?usage: thaw.sh <job>}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
CLAUDE_BIN="${FREEZE_CLAUDE_BIN:-$HOME/.local/bin/claude}"
PROBE_INTERVAL="${FREEZE_PROBE_INTERVAL:-900}"   # 한도 미해제 시 재시도 간격(초)
PROBE_MAX="${FREEZE_PROBE_MAX:-12}"              # 최대 재시도 횟수

DIR="$STATE_ROOT/$JOB"
RES="$DIR/reservation.json"
[ -f "$RES" ] || { echo "reservation 없음: $RES"; exit 1; }

# GNU/BSD 양립 — epoch → 사람이 읽는 포맷 (freeze.sh 의 fmt_epoch 와 같은 로직, 독립 프로세스라 중복 정의).
if date -d @0 +%s >/dev/null 2>&1; then _DATE_GNU=1; else _DATE_GNU=0; fi
fmt_epoch() { if [ "$_DATE_GNU" = 1 ]; then date -d "@$1" "$2"; else date -r "$1" "$2"; fi; }

# sha256 hex — GNU coreutils 는 sha256sum, macOS/BSD 는 shasum -a 256, 둘 다 없으면
# node crypto. freeze.sh 와 thaw.sh 가 반드시 같은 값을 내야 하므로(마커 경로를 서로
# 맞춰 찾는다) 두 파일에 같은 폴백 순서를 둔다.
sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    node -e 'console.log(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' -- "$1"
  fi
}

field() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1]))[process.argv[2]] ?? "")' "$RES" "$1"; }
set_status() {
  node -e '
const fs = require("fs"), [p, s] = process.argv.slice(1);
const d = JSON.parse(fs.readFileSync(p));
d.status = s; d.updated_at = Math.floor(Date.now()/1000);
fs.writeFileSync(p, JSON.stringify(d, null, 2));
' "$RES" "$1"
}

RESUME_AT=$(field resume_at)
SESSION=$(field session_id)
CWD=$(field cwd)
HANDOFF=$(field handoff)
PERM=$(field permission_mode)
[ -n "$PERM" ] || PERM="bypassPermissions"   # 구버전 reservation 호환
MODE=$(field mode)
[ -n "$MODE" ] || MODE="resume"              # 구버전 reservation 호환

# 완료 신호 — arm 으로 미리 걸어둔 예약은, 작업이 먼저 끝나면 헛돌지 않고 조용히 종료해야 한다.
# 메인 세션이 `freeze.sh done --handoff <경로>` 로 남긴 마커를 본다. 두 종류가 있다:
#   1) DONE_MARK — 이 job 자신의 상태 디렉토리 안(job 으로 스코프). done 호출 시점에
#      이미 존재하던 예약에만 남는다.
#   2) HANDOFF_MARK — handoff 해시로 키잉된 신호(freeze.sh:cmd_done). done 호출
#      시점에 아직 태어나지도 않았던 예약(체인의 다음 창 등)도 나중에 이 파일을
#      찾아서 본다 — major 3. 같은 handoff 를 재사용하는 완전히 새 예약이 옛
#      신호에 걸리지 않도록, 이 예약 자신의 created_at 보다 오래된(더 이전
#      타임스탬프의) 신호는 무시한다. 체인 재무장은 자식에게 부모의 created_at 을
#      그대로 물려주므로(cmd_arm --created-at), 부모가 실행 중 받은 신호를 자식도
#      그대로 본다 — freeze.sh:cmd_done 주석에 상태 전이 근거가 적혀 있다.
#      비교는 밀리초(Date.now()) 단위다 — 초 단위였을 때는 같은 handoff 를 짧은
#      간격으로 재사용하는 서로 무관한 예약들이 같은 초에 만들어져 신호와
#      created_at 이 우연히 같은 값으로 뭉개지는 오판정이 실측됐다.
DONE_MARK="$DIR/done"
HANDOFF_MARK="$STATE_ROOT/done-by-handoff/$(sha256_hex "$HANDOFF")"
JOB_CREATED_AT=$(field created_at)
[ -n "$JOB_CREATED_AT" ] || JOB_CREATED_AT=0   # 구버전 reservation 호환 — 항상 신호를 받아들인다

is_done_signaled() {
  [ -f "$DONE_MARK" ] && return 0
  [ -f "$HANDOFF_MARK" ] || return 1
  local sig_ts
  sig_ts=$(head -1 "$HANDOFF_MARK" 2>/dev/null || true)
  [[ "$sig_ts" =~ ^[0-9]+$ ]] || return 1
  [ "$sig_ts" -ge "$JOB_CREATED_AT" ]
}

echo "[$(date '+%F %T')] thaw 시작 — job=$JOB 땡=$(fmt_epoch "$RESUME_AT" '+%F %T')"

# 1) 예약 시각까지 대기 (60초 단위로 끊어 자며 취소·완료 여부 확인)
# sleep 은 백그라운드 + wait 로 돌린다 — 포그라운드 sleep 은 bash 의 TERM 처리를 막아 kill 이 최대 60초 늦어진다.
while :; do
  [ "$(field status)" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
  is_done_signaled && { set_status "completed_early"; echo "완료 신호 감지 — 재개 없이 종료"; exit 0; }
  now=$(date +%s)
  remain=$(( RESUME_AT - now ))
  [ "$remain" -le 0 ] && break
  sleep $(( remain < 60 ? remain : 60 )) & wait $!
done

# 2) haiku 프로브 — 한도가 실제로 풀렸는지 몇 토큰으로 확인
probe_ok=0
for i in $(seq 1 "$PROBE_MAX"); do
  [ "$(field status)" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
  is_done_signaled && { set_status "completed_early"; echo "완료 신호 감지 — 재개 없이 종료"; exit 0; }
  if "$CLAUDE_BIN" -p --model haiku "ok" > "$DIR/probe.log" 2>&1; then
    probe_ok=1
    echo "[$(date '+%F %T')] 프로브 통과 (시도 $i)"
    break
  fi
  echo "[$(date '+%F %T')] 프로브 실패 (시도 $i/$PROBE_MAX) — ${PROBE_INTERVAL}s 후 재시도"
  sleep "$PROBE_INTERVAL" & wait $!
done
if [ "$probe_ok" != 1 ]; then
  set_status "probe_failed"
  echo "[$(date '+%F %T')] 프로브 ${PROBE_MAX}회 실패 — 포기. probe.log 확인"
  exit 1
fi

# 3) 땡 — 세션 재개
# 재무장 체인: 이 창 안에 못 끝낼 가능성에 대비해, 재개를 부르기 **전에** thaw 자신이
# 다음 창을 결정적으로 미리 걸어둔다(NEXT_JOB). 예전 방식은 "한도에 막힌 세션이 프롬프트를
# 읽고 스스로 arm 을 다시 건다"였는데, 한도에 막힌 세션은 그 Bash 한 줄 실행할 토큰조차
# 없을 수 있어 신뢰할 수 없었다. 지금은 무조건 먼저 걸어두고, 재개가 실제로 끝나면(완료
# 신호 확인) 그 다음 창을 조용히 취소한다 — 이중 재개는 아래 두 안전장치로 막힌다:
#   1) 여기서 완료 신호를 보고 NEXT_JOB 을 명시적으로 cancel 한다.
#   2) 설령 이 cancel 이 실행되기 전에 thaw 프로세스가 죽어도, NEXT_JOB 자신의 대기
#      루프(위 1번 섹션)가 깨어날 때마다 DONE_MARK 를 검사하므로 스스로 조용히 종료한다.
# 즉 cancel 은 status 를 깨끗하게 유지하기 위한 것이고, 이중 재개 방지의 근거는 2) 다.
#
# 선무장 호출은 세 가지를 반드시 명시로 넘긴다(전부 auto-탐지에 맡기면 리셋 경계에서 깨진다):
#   --at <RESUME_AT + 5시간> — cmd_arm 기본값인 --at auto 를 쓰면 안 된다. 지금 이 순간이
#     바로 리셋 경계라 cmd_estimate 의 transcript 역산이 UNKNOWN 을 내기 쉽다(스크립트로
#     실측: 마지막 활동이 이전 블록 끝자락에 걸리면 while 루프가 다음 블록으로 못 넘어간다).
#     반면 지금 창의 시작 시각(RESUME_AT)은 이미 정확히 알고 있고, 5시간 사용량 창은 고정
#     길이이므로 다음 리셋은 그냥 RESUME_AT + 5h 다 — estimate 를 다시 부를 필요가 없다.
#   --pad "$PAD" — 이 예약의 pad 필드(원래 arm 때 정해진 값)를 그대로 물려준다. 안 넘기면
#     resolve_at 이 "명시 시각엔 --pad 를 직접 줬을 때만 적용" 이라 0 이 되어, 사용자가
#     처음에 크게 잡아둔 여유가 체인 2회차부터 조용히 사라진다.
#   --session "$SESSION" — cmd_reserve 의 자동탐지(ls -t 로 프로젝트 디렉토리 최신 jsonl)에
#     맡기면 안 된다. 방금 위에서 haiku 프로브가 실행되면서 프로젝트 디렉토리에 자기 자신의
#     일회용 transcript 를 새로 만들어(실제 CLI 동작, 실측 확인) 그게 "최신"이 되므로, 자동탐지가
#     프로브 세션을 집어버린다. 지금 이 reservation 이 이미 알고 있는 SESSION 을 그대로 쓴다.
#   --created-at "$JOB_CREATED_AT" — 자식 예약도 이 예약과 같은 created_at 을 가져야
#     handoff 로 키잉된 완료 신호(위 is_done_signaled)를 받을 수 있다 — major 3.
#     새로 Date.now() 를 찍게 두면 자식의 created_at 이 부모가 실행 중 이미 받은
#     신호보다 나중이 되어 "내 created_at 보다 오래된 신호는 무시" 규칙에 걸려
#     신호를 놓친다.
CHAIN=$(field chain)
CHAIN_LEFT=$(field chain_left)
[ -n "$CHAIN_LEFT" ] || CHAIN_LEFT=0
PAD=$(field pad)
[ -n "$PAD" ] || PAD=300   # 구버전 reservation 호환

NEXT_JOB=""
CHAIN_NOTE=""
if [ "$CHAIN" = "1" ] && [ "$CHAIN_LEFT" -gt 0 ]; then
  NEXT_CHAIN_LEFT=$((CHAIN_LEFT - 1))
  NEXT_JOB="${JOB}-c${NEXT_CHAIN_LEFT}"
  NEXT_AT=$((RESUME_AT + 5 * 3600))
  echo "[$(date '+%F %T')] 다음 창 선무장: job=$NEXT_JOB (남은 체인 ${NEXT_CHAIN_LEFT}회) 땡=$(fmt_epoch "$NEXT_AT" '+%F %T')"
  if bash "$SCRIPT_DIR/freeze.sh" arm --cwd "$CWD" --handoff "$HANDOFF" --job "$NEXT_JOB" \
      --chain-left "$NEXT_CHAIN_LEFT" --permission-mode "$PERM" --mode "$MODE" \
      --at "$NEXT_AT" --pad "$PAD" --session "$SESSION" --created-at "$JOB_CREATED_AT" \
      >> "$DIR/thaw.log" 2>&1; then
    CHAIN_NOTE="

다음 창은 이미 자동으로 예약해 뒀다(job=$NEXT_JOB, 남은 체인 ${NEXT_CHAIN_LEFT}회) — 직접 arm 을 걸 필요는 없다.
작업을 다 끝냈으면 반드시 완료 신호를 남겨라 — 그래야 예약해 둔 다음 창이 헛돌지 않고 조용히 해제된다:
  bash ~/.claude/skills/freeze/scripts/freeze.sh done --handoff \"$HANDOFF\""
  else
    NEXT_JOB=""
    echo "[$(date '+%F %T')] !!! 다음 창 선무장 실패 — 체인이 여기서 끊긴다. 수동으로 arm 필요: $DIR/thaw.log 확인" >&2
    node -e '
const fs = require("fs"), [p, msg] = process.argv.slice(1);
const d = JSON.parse(fs.readFileSync(p));
d.chain_warning = msg;
fs.writeFileSync(p, JSON.stringify(d, null, 2));
' "$RES" "다음 창 선무장 실패 — 체인이 끊겼다. bash $SCRIPT_DIR/freeze.sh status 로 확인, 수동 arm 필요: $DIR/thaw.log"
  fi
fi

# 프로브를 지나오는 동안(위 2번 구간) 완료 신호가 도착했을 수 있다 — 프로브 루프는
# 매 시도 "시작 전"에만 신호를 보므로, 마지막 시도가 성공해 루프를 빠져나온
# 바로 그 순간에 도착한 신호는 아직 아무도 확인하지 않았다. 여기서 재개를 부르기
# 직전에 한 번 더 확인해, 이미 끝난 작업을 전체 대화 재개로 다시 여는 사고를 막는다.
if is_done_signaled; then
  set_status "completed_early"
  echo "[$(date '+%F %T')] 완료 신호 감지(프로브 구간) — 재개 생략"
  [ -n "$NEXT_JOB" ] && { bash "$SCRIPT_DIR/freeze.sh" cancel "$NEXT_JOB" >> "$DIR/thaw.log" 2>&1 || true; }
  exit 0
fi

set_status "running"
echo "[$(date '+%F %T')] 재개: session=$SESSION cwd=$CWD mode=$MODE chain_left=$CHAIN_LEFT"
cd "$CWD" || { set_status "failed"; exit 1; }

if [ "$MODE" = "ledger" ]; then
  # ledger 모드 — 대화 전체를 복원하는 대신, 원장 한 장만 실은 신선한 세션을 띄운다.
  # 프롬프트는 짧게 유지한다: 실제 지시 내용은 원장 파일 안에 있다.
  "$CLAUDE_BIN" -p --permission-mode "$PERM" \
    "땡 — freeze 스킬(ledger 모드)로 예약된 재개다. 대화 문맥이 전혀 없다 — $HANDOFF (wf ledger) 가 유일한 명세다. 이 파일을 읽고 '## 워크플로우 런' 에 등록된 journal.jsonl 을 확인해 이미 끝난(result 줄이 있는) agent 호출은 건너뛰고, 남은 단계를 이어서 완료하는 연속 스크립트를 새로 작성해 돌려라. 새 워크플로우를 등록하기 전에 먼저 'bash ~/.claude/skills/freeze/scripts/wfledger.sh set-session --ledger $HANDOFF --cwd $CWD' 로 원장의 session 필드를 지금 이 세션으로 갱신해라 — 원장의 session 은 이전(한도에 막힌) 세션 UUID 로 고정돼 있어서, 갱신 없이 wfledger.sh run 을 부르면 journal/script 경로가 존재하지 않는 옛 세션 디렉토리로 계산된다. 끝나면 원장의 단계 체크박스를 갱신하고 '## 재개 결과' 섹션에 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}" \
    > "$DIR/resume-output.txt" 2>&1
  rc=$?
else
  "$CLAUDE_BIN" -p --resume "$SESSION" --permission-mode "$PERM" \
    "땡 — freeze 스킬로 예약된 재개다. $HANDOFF 를 읽고 중단된 작업을 이어서 완료해줘. 끝나면 같은 파일 하단에 '## 재개 결과' 섹션으로 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}" \
    > "$DIR/resume-output.txt" 2>&1
  rc=$?
fi

# 완료 신호가 보이면 미리 걸어둔 다음 창은 필요 없다 — 조용히 해제한다.
if [ -n "$NEXT_JOB" ] && is_done_signaled; then
  bash "$SCRIPT_DIR/freeze.sh" cancel "$NEXT_JOB" >> "$DIR/thaw.log" 2>&1 || true
  echo "[$(date '+%F %T')] 완료 신호 확인 — 선무장한 다음 창 해제: $NEXT_JOB"
fi

if [ "$rc" = 0 ]; then set_status "done"; else set_status "failed"; fi
echo "[$(date '+%F %T')] 재개 종료 rc=$rc — 출력: $DIR/resume-output.txt"
exit "$rc"
