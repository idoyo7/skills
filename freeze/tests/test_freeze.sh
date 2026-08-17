#!/usr/bin/env bash
# freeze 스킬 통합 테스트 — estimate 역산, reserve 세션 자동탐지, thaw 재개 호출까지.
# 실제 claude 를 부르지 않는다 (FREEZE_CLAUDE_BIN 목 사용).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FZ="$HERE/../scripts/freeze.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }

export FREEZE_STATE_DIR="$TMP/state"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export FREEZE_HUD_CACHE="$TMP/hud"   # 실환경 HUD 캐시 격리 (기본값은 ~/.claude/hud/cache)

# ---- 픽스처: 가짜 프로젝트 transcript ----
FAKE_CWD="$TMP/work"
mkdir -p "$FAKE_CWD"
SLUG=$(echo "$FAKE_CWD" | sed 's/[^A-Za-z0-9-]/-/g')
PROJ="$CLAUDE_PROJECTS_DIR/$SLUG"
mkdir -p "$PROJ"

iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%S.000Z'; }
NOW=$(date +%s)
START=$(( NOW - 2*3600 ))   # 2시간 전 시작 → 땡 = floor_hour(START)+5h
SESSION="11111111-2222-3333-4444-555555555555"
{
  echo "{\"type\":\"user\",\"timestamp\":\"$(iso "$START")\"}"
  echo "{\"type\":\"assistant\",\"timestamp\":\"$(iso $((NOW-60)))\"}"
} > "$PROJ/$SESSION.jsonl"

echo "== estimate =="
EXPECT=$(( START - START % 3600 + 5*3600 ))
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$EXPECT" ] && ok "5h 윈도우 역산 ($GOT)" || fail "estimate: got=$GOT want=$EXPECT"

echo "== estimate: 활동 없음 → UNKNOWN =="
GOT=$(CLAUDE_PROJECTS_DIR="$TMP/empty" bash "$FZ" estimate)
[ "$GOT" = "UNKNOWN" ] && ok "UNKNOWN 반환" || fail "empty estimate: got=$GOT"

echo "== estimate: HUD 캐시가 있으면 정확값 우선 =="
mkdir -p "$FREEZE_HUD_CACHE"
HUD_AT=$(( NOW + 1234 ))
echo "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":$HUD_AT}}}" > "$FREEZE_HUD_CACHE/stdin.$SESSION.json"
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$HUD_AT" ] && ok "HUD resets_at 우선 ($GOT)" || fail "HUD estimate: got=$GOT want=$HUD_AT"

echo "== estimate: HUD resets_at 이 과거면 폴백 =="
echo "{\"rate_limits\":{\"five_hour\":{\"resets_at\":$(( NOW - 10 ))}}}" > "$FREEZE_HUD_CACHE/stdin.$SESSION.json"
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$EXPECT" ] && ok "과거값 무시하고 역산 폴백" || fail "stale HUD: got=$GOT want=$EXPECT"
rm -f "$FREEZE_HUD_CACHE/stdin.$SESSION.json"

echo "== reserve + thaw (mock claude) =="
MOCK="$TMP/mock-claude"; CALLS="$TMP/calls.log"
cat > "$MOCK" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$CALLS"
exit 0
EOF
chmod +x "$MOCK"
export FREEZE_CLAUDE_BIN="$MOCK"

HANDOFF="$FAKE_CWD/handoff.md"; echo "# test handoff" > "$HANDOFF"
OUT=$(bash "$FZ" reserve --at +2s --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job testjob)
echo "$OUT" | grep -q "job=testjob" && ok "reserve 등록" || fail "reserve 출력: $OUT"
echo "$OUT" | grep -q "session=$SESSION" && ok "세션 자동탐지" || fail "세션 탐지: $OUT"

for i in $(seq 1 20); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/testjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "thaw 완주 (status=done)" || fail "thaw status=$STATUS"
grep -q -- "--resume $SESSION" "$CALLS" && ok "resume 호출 (세션 id 일치)" || fail "resume 호출 없음: $(cat "$CALLS" 2>/dev/null)"
grep -q -- "--model haiku" "$CALLS" && ok "haiku 프로브 선행" || fail "프로브 없음"

echo "== cancel =="
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job canceljob > /dev/null
bash "$FZ" cancel canceljob | grep -q "취소됨" && ok "cancel" || fail "cancel"
STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/canceljob/reservation.json')).status)")
[ "$STATUS" = "cancelled" ] && ok "상태 cancelled" || fail "cancel status=$STATUS"

echo "== check (죽은 슬리퍼 캐치업) =="
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job deadjob > /dev/null
DEADPID=$(cat "$FREEZE_STATE_DIR/deadjob/sleeper.pid")
kill "$DEADPID" 2>/dev/null || true
alive() { s=$(ps -o state= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s:0:1}" != "Z" ]; }  # 좀비는 죽은 것
for i in $(seq 1 20); do alive "$DEADPID" || break; sleep 0.2; done
alive "$DEADPID" && fail "슬리퍼가 죽지 않음 (pid=$DEADPID)" || true
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/deadjob/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.resume_at=0; fs.writeFileSync(p, JSON.stringify(d));"
bash "$FZ" check | grep -q "캐치업" && ok "check 가 재기동" || fail "check 미동작"
for i in $(seq 1 10); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/deadjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "캐치업 완주" || fail "캐치업 status=$STATUS"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
