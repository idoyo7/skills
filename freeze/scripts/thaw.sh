#!/usr/bin/env bash
# thaw — 땡. 예약 시각까지 자고, haiku 프로브로 한도 해제를 확인한 뒤 세션을 헤드리스로 재개한다.
# freeze.sh reserve 가 setsid nohup 으로 기동한다. 직접 부를 일은 캐치업(check) 정도.
set -uo pipefail

JOB="${1:?usage: thaw.sh <job>}"
STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
CLAUDE_BIN="${FREEZE_CLAUDE_BIN:-$HOME/.local/bin/claude}"
PROBE_INTERVAL="${FREEZE_PROBE_INTERVAL:-900}"   # 한도 미해제 시 재시도 간격(초)
PROBE_MAX="${FREEZE_PROBE_MAX:-12}"              # 최대 재시도 횟수

DIR="$STATE_ROOT/$JOB"
RES="$DIR/reservation.json"
[ -f "$RES" ] || { echo "reservation 없음: $RES"; exit 1; }

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

# 완료 신호 — arm 으로 미리 걸어둔 예약은, 작업이 먼저 끝나면 헛돌지 않고 조용히 종료해야 한다.
# 메인 세션이 `freeze.sh done --handoff <경로>` 로 남긴 마커를 본다.
DONE_MARK="${HANDOFF}.freeze-done"

echo "[$(date '+%F %T')] thaw 시작 — job=$JOB 땡=$(date -d "@$RESUME_AT" '+%F %T')"

# 1) 예약 시각까지 대기 (60초 단위로 끊어 자며 취소·완료 여부 확인)
# sleep 은 백그라운드 + wait 로 돌린다 — 포그라운드 sleep 은 bash 의 TERM 처리를 막아 kill 이 최대 60초 늦어진다.
while :; do
  [ "$(field status)" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
  [ -f "$DONE_MARK" ] && { set_status "completed_early"; echo "완료 신호 감지 — 재개 없이 종료"; exit 0; }
  now=$(date +%s)
  remain=$(( RESUME_AT - now ))
  [ "$remain" -le 0 ] && break
  sleep $(( remain < 60 ? remain : 60 )) & wait $!
done

# 2) haiku 프로브 — 한도가 실제로 풀렸는지 몇 토큰으로 확인
probe_ok=0
for i in $(seq 1 "$PROBE_MAX"); do
  [ "$(field status)" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
  [ -f "$DONE_MARK" ] && { set_status "completed_early"; echo "완료 신호 감지 — 재개 없이 종료"; exit 0; }
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
# 재무장 체인(arm 모드): 이 창 안에 못 끝내면 재개 세션이 스스로 다음 창을 arm 한다.
CHAIN=$(field chain)
CHAIN_LEFT=$(field chain_left)
[ -n "$CHAIN_LEFT" ] || CHAIN_LEFT=0

CHAIN_NOTE=""
if [ "$CHAIN" = "1" ] && [ "$CHAIN_LEFT" -gt 0 ]; then
  CHAIN_NOTE="

이번 창에도 다 못 끝낼 것 같으면, 작업을 멈추기 전에 다음 창을 미리 걸어라(남은 체인 ${CHAIN_LEFT}회):
  bash ~/.claude/skills/freeze/scripts/freeze.sh arm --cwd \"$CWD\" --handoff \"$HANDOFF\" --chain-left $((CHAIN_LEFT - 1))
반대로 작업을 다 끝냈으면 완료 신호를 남겨라 — 걸려 있는 예약이 헛돌지 않는다:
  bash ~/.claude/skills/freeze/scripts/freeze.sh done --handoff \"$HANDOFF\""
fi

set_status "running"
echo "[$(date '+%F %T')] 재개: session=$SESSION cwd=$CWD chain_left=$CHAIN_LEFT"
cd "$CWD" || { set_status "failed"; exit 1; }
"$CLAUDE_BIN" -p --resume "$SESSION" --permission-mode "$PERM" \
  "땡 — freeze 스킬로 예약된 재개다. $HANDOFF 를 읽고 중단된 작업을 이어서 완료해줘. 끝나면 같은 파일 하단에 '## 재개 결과' 섹션으로 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}" \
  > "$DIR/resume-output.txt" 2>&1
rc=$?

if [ "$rc" = 0 ]; then set_status "done"; else set_status "failed"; fi
echo "[$(date '+%F %T')] 재개 종료 rc=$rc — 출력: $DIR/resume-output.txt"
exit "$rc"
