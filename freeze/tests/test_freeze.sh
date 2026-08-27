#!/usr/bin/env bash
# freeze 스킬 통합 테스트 — estimate 역산, reserve 세션 자동탐지, thaw 재개 호출까지.
# 실제 claude 를 부르지 않는다 (FREEZE_CLAUDE_BIN 목 사용).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FZ="$HERE/../scripts/freeze.sh"
WFL="$HERE/../scripts/wfledger.sh"
TMP=$(mktemp -d)
# 실패로 스크립트가 중간에 죽어도(set -e) 살아있는 슬리퍼(thaw.sh)를 남기지
# 않는다 — rm -rf "$TMP" 로 상태 파일이 먼저 사라지면 슬리퍼는 자기 상태를
# 잃어 스스로 취소도 못 하고 최대 몇 시간(프로브 재시도 포함) 떠 있는다.
# 반드시 죽이고 나서 지운다.
cleanup() {
  local f pid
  for f in "$FREEZE_STATE_DIR"/*/sleeper.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
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

# GNU/BSD 양립 — date -u -d 대신 node 로. toISOString() 이 정확히 같은 포맷(....000Z)을 낸다.
iso() { node -e 'console.log(new Date(Number(process.argv[1])*1000).toISOString())' "$1"; }
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

echo "== usage: --mode / --pad 가 도움말에 반영돼 있다 =="
USAGE_OUT=$(bash "$FZ" 2>&1) || true   # usage() 는 exit 1 — pipefail 오염 피하려고 먼저 변수로 받는다
echo "$USAGE_OUT" | grep -q -- "--mode" && ok "usage 에 --mode 있음" || fail "usage 에 --mode 없음"
echo "$USAGE_OUT" | grep -q -- "--pad" && ok "usage 에 --pad 있음" || fail "usage 에 --pad 없음"

echo "== reserve + thaw (mock claude) =="
MOCK="$TMP/mock-claude"; CALLS="$TMP/calls.log"
export CALLS_FILE="$CALLS"
# 단순 echo 외에, 아래 체인/블로커 재현 테스트가 켜는 조건부 동작을 지원한다
# (평소엔 관련 환경변수가 비어 있어 기존 테스트 동작에 영향 없음):
#   MOCK_DONE_MARK           - haiku 프로브 호출 "도중"에 이 경로에 완료 마커를 남긴다
#                              (실제 작업 세션이 프로브 구간에 done 을 부른 상황 재현)
#   MOCK_MAKE_TRANSCRIPT_DIR - 호출될 때마다 이 디렉토리에 새 일회용 transcript 를 만든다
#                              (haiku 프로브가 실제로 새 세션 transcript 를 남기는 것 재현)
#   MOCK_EXPECT_FILE         - haiku 프로브가 아닌 호출(=재개 호출) 시점에 이 파일이 이미
#                              존재하는지를 CALLS_FILE 에 기록한다 — "선무장이 재개보다
#                              먼저 끝났는가" 를 스텁 스스로 기록하게 하는 순서 단언 장치
cat > "$MOCK" <<'MOCKEOF'
#!/usr/bin/env bash
echo "$@" >> "$CALLS_FILE"
if [ -n "${MOCK_DONE_MARK:-}" ] && [[ "$*" == *"--model haiku"* ]]; then
  date '+%F %T 완료' > "$MOCK_DONE_MARK"
fi
if [ -n "${MOCK_MAKE_TRANSCRIPT_DIR:-}" ]; then
  mkdir -p "$MOCK_MAKE_TRANSCRIPT_DIR"
  echo '{"type":"queue-operation","content":"ok"}' > "$MOCK_MAKE_TRANSCRIPT_DIR/probe-$$-$RANDOM.jsonl"
fi
if [ -n "${MOCK_EXPECT_FILE:-}" ] && [[ "$*" != *"--model haiku"* ]]; then
  if [ -f "$MOCK_EXPECT_FILE" ]; then echo "MOCK_EXPECT_FILE=present" >> "$CALLS_FILE"; else echo "MOCK_EXPECT_FILE=absent" >> "$CALLS_FILE"; fi
fi
exit 0
MOCKEOF
chmod +x "$MOCK"
export FREEZE_CLAUDE_BIN="$MOCK"

HANDOFF="$FAKE_CWD/handoff.md"; echo "# test handoff" > "$HANDOFF"
OUT=$(bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job testjob)
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
grep -q -- "--permission-mode bypassPermissions" "$CALLS" && ok "기본 권한 bypassPermissions" || fail "권한 모드: $(grep resume "$CALLS")"

echo "== reserve --permission-mode 오버라이드 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job permjob --permission-mode acceptEdits > /dev/null
for i in $(seq 1 20); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/permjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
grep -q -- "--permission-mode acceptEdits" "$CALLS" && ok "오버라이드 반영" || fail "오버라이드 미반영: $(grep resume "$CALLS")"

echo "== reserve: 같은 job 이름을 재예약하면 이전 슬리퍼를 정리한다 (major 1 회귀) =="
# 재현: 같은 job 이름으로 reserve 를 짧은 간격으로 두 번 부르면, 예전 코드는
# sleeper.pid 파일을 마지막 것으로 덮어쓸 뿐 이전 슬리퍼는 안 죽여서 둘 다
# 살아남는다 — 8초 뒤 재개 호출이 서로 다른 pid 로 두 줄 찍힌다. thaw 가
# 선무장 끝~running 전환 전에 죽으면 job 은 frozen 으로 남아 check 캐치업 대상이
# 되므로, 실제 도달 경로가 있다.
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +8s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job dupjob > /dev/null
OLD_SLEEPER_PID=$(cat "$FREEZE_STATE_DIR/dupjob/sleeper.pid")
sleep 1
OUT=$(bash "$FZ" reserve --at +8s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job dupjob 2>&1)
NEW_SLEEPER_PID=$(cat "$FREEZE_STATE_DIR/dupjob/sleeper.pid")
[ "$OLD_SLEEPER_PID" != "$NEW_SLEEPER_PID" ] && ok "재예약으로 새 슬리퍼 pid 발급 ($OLD_SLEEPER_PID -> $NEW_SLEEPER_PID)" || fail "pid 가 갱신되지 않음"
echo "$OUT" | grep -q "이전 슬리퍼 종료" && ok "이전 슬리퍼 종료 로그 확인" || fail "이전 슬리퍼 종료 로그 없음: $OUT"
sleep 1
dup_alive() { s=$(ps -o state= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s:0:1}" != "Z" ]; }
dup_alive "$OLD_SLEEPER_PID" && fail "이전 슬리퍼가 여전히 살아있음 (pid=$OLD_SLEEPER_PID)" || ok "이전 슬리퍼가 실제로 종료됨"
for i in $(seq 1 20); do
  DUPST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/dupjob/reservation.json')).status)")
  [ "$DUPST" = "done" ] && break
  sleep 1
done
[ "$DUPST" = "done" ] && ok "재예약 후 정상 완주" || fail "재예약 후 status=$DUPST"
# 위 폴링 루프는 "먼저 done 이 되는 슬리퍼"를 보는 즉시 break 한다. reap 이 깨져
# 있으면(mutation 검증 참고) 그게 OLD 슬리퍼다 — OLD 는 t=0 에 --at +8s 로 떴고
# NEW 는 1초 뒤(t=1)에 같은 +8s 로 떴으므로 NEW 의 절대 완료 시각은 OLD 보다 딱
# 1초 늦다. 그 순간 바로 grep -c 를 하면 NEW 의 --resume 은 아직(최대 1초 뒤)
# 로그에 도착하지 않아 이 assertion 이 버그가 있어도 그냥 통과해버린다(헛도는
# assertion — 같은 섹션의 "이전 슬리퍼 종료 로그"/"프로세스 생존" 두 assertion
# 만 대신 빨개져 회귀 자체는 잡히지만 가장 중요한 이 assertion 은 안 잡힘).
# 두 슬리퍼의 완료 시각 차이(1초)보다 넉넉한 여유를 두고 카운트해야 NEW 의
# --resume 호출까지 로그에 반영된 뒤에 판정한다. mock claude 는 즉시 반환하므로
# 이 여유는 순수 대기 시간이고 정상 경로(reap 정상 동작)에서는 OLD 가 애초에
# 재개를 부르지 못하므로 카운트에 영향이 없다.
sleep 3
DUP_RESUME_COUNT=$(grep -c -- "--resume $SESSION" "$CALLS" || true)
[ "$DUP_RESUME_COUNT" = 1 ] && ok "재개 호출이 정확히 1번만 발생 — 이전 슬리퍼로 인한 이중 재개 없음" || fail "재개 호출 횟수=$DUP_RESUME_COUNT (기대 1)"

echo "== reserve: 재예약 시점에 이전 슬리퍼가 이미 죽어있으면 조용히 넘어간다 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job deadreapjob > /dev/null
DEADREAP_PID=$(cat "$FREEZE_STATE_DIR/deadreapjob/sleeper.pid")
kill -9 "$DEADREAP_PID" 2>/dev/null || true
for i in $(seq 1 20); do dup_alive "$DEADREAP_PID" || break; sleep 0.2; done
OUT2=$(bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job deadreapjob)
echo "$OUT2" | grep -q "이전 슬리퍼 종료" && fail "이미 죽은 슬리퍼인데 종료 로그가 찍힘" || ok "이미 죽은 슬리퍼는 조용히 넘어감"
echo "$OUT2" | grep -q "얼음" && ok "재예약 자체는 정상 성공" || fail "재예약 실패: $OUT2"
bash "$FZ" cancel deadreapjob > /dev/null 2>&1 || true

echo "== arm: 선예약 + 체인 정보 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
# 완료 마커는 이제 job 디렉토리 안에 스코프돼 있다(freeze.sh:cmd_reserve/cmd_done 참고).
# "이전 회차의 스테일 마커 제거"가 여전히 의미 있는 유일한 경우는 같은 job 이름을
# 재사용하는 경우뿐이다 — 그래서 armjob 자신의 디렉토리에 미리 스테일 마커를 심는다.
mkdir -p "$FREEZE_STATE_DIR/armjob"
touch "$FREEZE_STATE_DIR/armjob/done"
OUT=$(bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job armjob --chain-left 2)
echo "$OUT" | grep -q "무장 완료" && ok "arm 등록" || fail "arm 출력: $OUT"
[ -f "$FREEZE_STATE_DIR/armjob/done" ] && fail "같은 job 재사용 시 스테일 완료 마커 미제거" || ok "같은 job 재사용 시 스테일 완료 마커 제거"
RES="$FREEZE_STATE_DIR/armjob/reservation.json"
CHAIN=$(node -e "const d=JSON.parse(require('fs').readFileSync('$RES'));console.log(d.chain, d.chain_left, d.via)")
[ "$CHAIN" = "1 2 arm" ] && ok "체인 정보 기록 ($CHAIN)" || fail "체인 정보: $CHAIN"
MODE_DEFAULT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$RES')).mode)")
[ "$MODE_DEFAULT" = "resume" ] && ok "mode 기본값 resume" || fail "mode 기본값: $MODE_DEFAULT"
# 땡 시각은 auto — HUD/역산 값이므로 미래여야 한다
AT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$RES')).resume_at)")
[ "$AT" -gt "$(date +%s)" ] && ok "auto 땡 시각이 미래" || fail "땡 시각 과거: $AT"
bash "$FZ" cancel armjob > /dev/null

echo "== done: 완료 신호로 재개 없이 종료 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job donejob --chain-left 1 > /dev/null
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/donejob/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.resume_at=Math.floor(Date.now()/1000)+3;
fs.writeFileSync(p, JSON.stringify(d,null,2));"   # 곧 깨어나도록 당긴다
bash "$FZ" done --handoff "$HANDOFF" | grep -q "완료 신호" && ok "done 마커 기록" || fail "done 출력"
# 플레이크 수정 (제품 코드는 건드리지 않는 쪽으로 결정): donejob 은 위에서 arm
# --at 기본값(auto) 그대로 떴다 — RESUME_AT 이 몇 시간 뒤라 thaw.sh 의 대기
# 루프(thaw.sh:27 에서 RESUME_AT 을 한 번만 읽고, 이후 60초 단위 sleep+재확인 을
# 반복)는 매 반복 min(remain,60)=60 으로 계속 돈다. 방금 위에서 resume_at 을
# 앞당긴 건 "곧 깨어나게" 하려는 의도지만 thaw 는 그 필드를 다시 읽지 않으므로
# 대기 chunk 크기엔 전혀 영향을 못 준다 — done 마커가 실제로 언제 반영되는지는
# "마커가 써진 시점이 60초 체크 경계에서 얼마나 떨어져 있었는가"에만 좌우된다.
# 즉 지연은 0~60초 사이에서 실행마다 달라지는 정렬(alignment) 문제이지 진짜
# 레이스가 아니다(실측: 58초 뒤 completed_early 전이). 그래서 15초 폴링은 정렬이
# 나쁘게 걸리는 실행에서 확률적으로 빨개진다.
#
# thaw.sh 의 대기 chunk(60초)를 환경변수로 뺴는 안(기본값은 60 그대로 유지)도
# 검토했다 — 그러면 이 테스트만 chunk 를 1초 같은 값으로 낮춰 정렬 문제 자체를
# 없앨 수 있다. 하지만 이는 thaw.sh(제품 코드) 수정이고, 이번 작업 범위는
# "제품 코드는 건드리지 마라 — 결함은 테스트에 있다"로 명시돼 있어 채택하지
# 않았다. 대신 폴링 창을 60초 worst-case 보다 넉넉히(약 20초 여유) 늘려 정렬과
# 무관하게 항상 감지되도록 한다. 스위트 전체 실행 시간에 미치는 영향은 이
# 섹션 하나의 worst-case 증가분(구 15초 → 신 80초, 최대 +65초)뿐이며, 실측상
# 이 섹션은 매 실행 0~60초 사이에서 끝나므로 평균 증가분은 이보다 작다.
for i in $(seq 1 80); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/donejob/reservation.json')).status)")
  [ "$ST" = "completed_early" ] && break
  sleep 1
done
[ "$ST" = "completed_early" ] && ok "완료 신호로 조기 종료" || fail "상태=$ST"
grep -q -- "--resume" "$CALLS" && fail "완료 신호에도 재개가 돌았다" || ok "재개 호출 없음"

echo "== done: 활성 예약이 없으면 대상 없음을 알리고 비영 종료코드를 낸다 (major 2 회귀) =="
# pipefail 로 묶어 grep 결과와 종료코드를 동시에 판정하면 안 된다 — done 자체의
# 종료코드가 이제 실패(1)이므로 파이프라인 판정에 섞으면 메시지가 맞아도 FAIL 로
# 잘못 뒤집힌다. 메시지와 종료코드를 따로 확인한다.
NO_TARGET_OUT=$(bash "$FZ" done --handoff "$FAKE_CWD/no-such-handoff.md" 2>&1) && NO_TARGET_RC=0 || NO_TARGET_RC=$?
echo "$NO_TARGET_OUT" | grep -q "대상 없음" && ok "무대상 done 은 경고로 알림" || fail "무대상 done 이 조용히 성공만 함: $NO_TARGET_OUT"
[ "$NO_TARGET_RC" -ne 0 ] && ok "무대상 done 은 비영 종료코드 (rc=$NO_TARGET_RC)" || fail "무대상 done 의 종료코드가 0 — 자동 호출자가 실패를 못 본다"

echo "== done: handoff 경로를 절대 realpath 로 정규화해 비교한다 (major 2 회귀) =="
# SKILL.md 안내대로 상대경로로 예약하고, 절대경로로 done 을 부른다 — 예전엔
# 문자열만 비교해 둘이 서로 다른 handoff 로 보여 완료 신호가 유실됐다.
: > "$CALLS"
( cd "$FAKE_CWD" && echo "# rel" > relhandoff.md && bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff relhandoff.md --job relnormjob > /dev/null )
STORED_HANDOFF=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/relnormjob/reservation.json')).handoff)")
[[ "$STORED_HANDOFF" = /* ]] && ok "저장된 handoff 가 절대경로로 정규화됨 ($STORED_HANDOFF)" || fail "handoff 가 절대경로로 정규화되지 않음: $STORED_HANDOFF"
bash "$FZ" done --handoff "$FAKE_CWD/relhandoff.md" > /dev/null && ok "상대경로로 예약해도 절대경로 done 이 대상을 찾음" || fail "정규화 실패 — done 이 대상을 못 찾음"
[ -f "$FREEZE_STATE_DIR/relnormjob/done" ] && ok "job 완료 마커 기록됨" || fail "job 완료 마커 없음"
bash "$FZ" cancel relnormjob > /dev/null 2>&1 || true
rm -f "$FAKE_CWD/relhandoff.md"

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

echo "== --pad: 사용자가 명시하면 해석된 epoch 에 그대로 더해진다 =="
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +10s --pad 100 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job padjob > /dev/null
PAD_AT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/padjob/reservation.json')).resume_at)")
PAD_NOW=$(date +%s)
PAD_DIFF=$(( PAD_AT - PAD_NOW ))
[ "$PAD_DIFF" -ge 95 ] && [ "$PAD_DIFF" -le 130 ] && ok "pad 반영 (diff=${PAD_DIFF}s, 기대 ~110s)" || fail "pad 미반영: diff=$PAD_DIFF"
bash "$FZ" cancel padjob > /dev/null

echo "== --at 명시 시각은 --pad 를 직접 주지 않으면 패딩되지 않는다 (회귀 방지) =="
echo "# h" > "$HANDOFF"
REQ_EPOCH=$(( $(date +%s) + 1000 ))
bash "$FZ" reserve --at "$REQ_EPOCH" --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job nopadjob > /dev/null
GOT_EPOCH=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob/reservation.json')).resume_at)")
[ "$GOT_EPOCH" = "$REQ_EPOCH" ] && ok "명시 epoch 는 패딩 없음 (got=$GOT_EPOCH)" || fail "명시 epoch 에 기본 패딩이 붙음: want=$REQ_EPOCH got=$GOT_EPOCH"
STORED_PAD=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob/reservation.json')).pad)")
[ "$STORED_PAD" = "0" ] && ok "저장된 pad 필드도 0" || fail "저장된 pad: $STORED_PAD"
bash "$FZ" cancel nopadjob > /dev/null
# +30s 같은 상대 지정도 동일 계약이어야 한다
bash "$FZ" reserve --at +30s --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job nopadjob2 > /dev/null
REL_AT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob2/reservation.json')).resume_at)")
REL_DIFF=$(( REL_AT - $(date +%s) ))
[ "$REL_DIFF" -ge 28 ] && [ "$REL_DIFF" -le 32 ] && ok "+30s 도 패딩 없이 그대로 (diff=${REL_DIFF}s)" || fail "+30s 에 패딩 붙음: diff=$REL_DIFF"
bash "$FZ" cancel nopadjob2 > /dev/null

echo "== mode=ledger: --resume 미사용, 원장 경로가 프롬프트에 실린다 =="
# 가짜 한 줄짜리 handoff 가 아니라 wfledger.sh init 이 실제로 만드는 원장을 쓴다 —
# 아래 섹션명 일치 검증이 진짜 원장 내용을 봐야 의미가 있다.
: > "$CALLS"
LEDGER_HANDOFF=$(bash "$WFL" init --job ledgerjob --cwd "$FAKE_CWD" --summary "ledger 재개 테스트" \
  --session "$SESSION" --goal "테스트 목표" --done-when "테스트 완료 기준")
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$LEDGER_HANDOFF" --job ledgerjob --mode ledger > /dev/null
for i in $(seq 1 20); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/ledgerjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "ledger 모드 재개 완주" || fail "ledger 재개 status=$STATUS"
grep -q -- "--resume" "$CALLS" && fail "ledger 모드인데 --resume 을 썼다" || ok "ledger 모드는 --resume 미사용"
grep -qF -- "$LEDGER_HANDOFF" "$CALLS" && ok "원장 경로가 프롬프트에 실림" || fail "원장 경로 프롬프트 누락: $(cat "$CALLS" 2>/dev/null)"
grep -q -- "set-session" "$CALLS" && ok "재개 프롬프트가 wfledger set-session 을 지시함" || fail "set-session 안내 누락"

echo "== mode=ledger: 재개 프롬프트가 가리키는 섹션명이 원장의 실제 섹션명과 맞는다 (minor 회귀) =="
# 예전엔 가짜 handoff("# ledger placeholder" 한 줄)를 써서 실제 원장 내용과
# thaw.sh 프롬프트가 아예 무관했다 — '## 워크플로우 런' 섹션명을 어느 한쪽만
# 바꿔도(오타·리팩터) 테스트가 계속 초록이었다. 여기서는 위에서 실제로 만든
# 원장 파일을 직접 열어, thaw.sh 프롬프트가 지시하는 섹션명이 그 안에 정말
# 있는지 확인한다.
THAW_SRC="$HERE/../scripts/thaw.sh"
SECTION_NAME=$(sed -n "s/.*읽고 '\(## [^']*\)' 에 등록된.*/\1/p" "$THAW_SRC")
[ -n "$SECTION_NAME" ] && ok "thaw.sh 프롬프트에서 섹션명 추출: $SECTION_NAME" || fail "thaw.sh 에서 섹션명 추출 실패 — 프롬프트 문구가 바뀌었을 수 있음"
grep -qxF "$SECTION_NAME" "$LEDGER_HANDOFF" && ok "원장에 그 섹션명이 실제로 있음" || fail "섹션명 불일치 — 원장에 '$SECTION_NAME' 없음: $(grep '^##' "$LEDGER_HANDOFF")"

echo "== mode=ledger: 프로젝트 transcript 디렉토리가 없어도 reserve 가 죽지 않는다 =="
LEDGER_NEW_CWD="$TMP/ledger-fresh-cwd"; mkdir -p "$LEDGER_NEW_CWD"
echo "# fresh" > "$LEDGER_NEW_CWD/h.md"
OUT=$(bash "$FZ" reserve --at +1h --cwd "$LEDGER_NEW_CWD" --handoff "$LEDGER_NEW_CWD/h.md" --job freshledgerjob --mode ledger)
echo "$OUT" | grep -q "얼음" && ok "세션 미탐지에도 ledger reserve 성공" || fail "ledger reserve 실패: $OUT"
bash "$FZ" cancel freshledgerjob > /dev/null

echo "== mode=resume: 기존 계약(--resume <SESSION>) 유지 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job resumejob > /dev/null
for i in $(seq 1 20); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/resumejob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
grep -q -- "--resume $SESSION" "$CALLS" && ok "resume 모드는 --resume 유지" || fail "resume 계약 깨짐: $(cat "$CALLS" 2>/dev/null)"

echo "== 완료 마커는 job 단위로 격리된다 (다른 job 의 신호를 arm 이 지우지 않는다) =="
# 회귀 재현: 같은 handoff 를 우연히 공유하는 서로 무관한 두 job. 예전 코드는
# cmd_arm 이 handoff 경로 기준 마커를 무조건 rm 해서, 먼저 끝난 세션의 신호가
# 뒤이은 무관한 세션의 arm 에 지워졌다(freeze.sh:271 재현 — 위 리뷰 기록 참고).
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job isoA > /dev/null
bash "$FZ" done --handoff "$HANDOFF" > /dev/null
[ -f "$FREEZE_STATE_DIR/isoA/done" ] && ok "isoA 완료 마커 기록됨" || fail "isoA 마커 기록 실패"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job isoB --chain-left 1 --at +1h > /dev/null
[ -f "$FREEZE_STATE_DIR/isoA/done" ] && ok "무관한 job(isoB) 의 arm 이 isoA 마커를 건드리지 않음" || fail "격리 실패 — isoA 마커가 지워짐"
bash "$FZ" cancel isoA > /dev/null 2>&1 || true
bash "$FZ" cancel isoB > /dev/null 2>&1 || true

echo "== status: 체인 선무장 실패 경고가 눈에 띄게 나온다 =="
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job warnjob > /dev/null
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/warnjob/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.chain_warning='다음 창 선무장 실패 — 체인이 끊겼다';
fs.writeFileSync(p, JSON.stringify(d,null,2));"
bash "$FZ" status | grep -q "경고: 다음 창 선무장 실패" && ok "status 가 chain_warning 을 노출" || fail "status 에 경고 미노출"
bash "$FZ" cancel warnjob > /dev/null

echo "== 체인: 선무장이 실제 재개 호출 '전에' 끝난다 (순서 단언) =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB=orderjob
# 이 env var 는 arm 이 만드는 백그라운드 슬리퍼(thaw.sh)의 fork 시점에 이미
# 심어져 있어야 그 프로세스가 물려받는다 — arm 을 부르기 "전에" export 해야 한다.
export MOCK_EXPECT_FILE="$FREEZE_STATE_DIR/${CHAINJOB}-c0/reservation.json"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$CHAINJOB" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
unset MOCK_EXPECT_FILE
[ "$ST" = "done" ] && ok "orderjob 완주" || fail "orderjob status=$ST"
[ -f "$FREEZE_STATE_DIR/${CHAINJOB}-c0/reservation.json" ] && ok "다음 창 선무장 확인" || fail "선무장 안됨"
grep -q "MOCK_EXPECT_FILE=present" "$CALLS" && ok "재개 호출 시점에 이미 다음 창 예약 파일이 존재함(선무장이 먼저 끝남)" || fail "순서 위반 — 재개 호출 시점에 다음 창 예약이 아직 없었다: $(grep MOCK_EXPECT_FILE "$CALLS" || echo 없음)"
bash "$FZ" cancel "${CHAINJOB}-c0" > /dev/null 2>&1 || true

echo "== 체인: 프로브가 실제 CLI 처럼 자기 transcript 를 남겨도 선무장 세션이 오염되지 않는다 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB2=sessisojob
export MOCK_MAKE_TRANSCRIPT_DIR="$PROJ"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$CHAINJOB2" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB2/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
unset MOCK_MAKE_TRANSCRIPT_DIR
[ "$ST" = "done" ] && ok "sessisojob 완주" || fail "sessisojob status=$ST"
NEXTSESS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${CHAINJOB2}-c0/reservation.json')).session_id)")
[ "$NEXTSESS" = "$SESSION" ] && ok "선무장된 다음 창의 session_id 가 원래 세션과 일치 ($NEXTSESS)" || fail "선무장 세션이 프로브로 오염됨: got=$NEXTSESS want=$SESSION"
bash "$FZ" cancel "${CHAINJOB2}-c0" > /dev/null 2>&1 || true

echo "== 체인: 원래 예약의 pad 가 다음 창에도 그대로 전달된다 =="
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB3=padchainjob
# --pad 는 --at 이 무엇이든 그 해석된 시각에 그대로 더해진다(새 계약) — 그래서
# 여기서 --pad 777 을 직접 arm 에 주면 이 job 자신의 실제 대기 시간도 777초
# 늘어나 테스트가 오래 걸린다. 검증하려는 건 "이 job 이 얼마나 기다리느냐"가
# 아니라 "이 job 의 pad 필드가 다음 창에 그대로 전달되느냐"이므로, 대기 시각은
# 짧게 유지하고 pad 필드만 사후에 심는다(thaw 는 이 필드를 체인 구간에서만,
# 즉 sleep+probe 를 다 지난 뒤에 읽으므로 이 패치가 늦게 도착할 걱정이 없다).
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$CHAINJOB3" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/$CHAINJOB3/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.pad=777;
fs.writeFileSync(p, JSON.stringify(d,null,2));"
for i in $(seq 1 20); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB3/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
[ "$ST" = "done" ] && ok "padchainjob 완주" || fail "padchainjob status=$ST"
NEXTPAD=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${CHAINJOB3}-c0/reservation.json')).pad)")
[ "$NEXTPAD" = "777" ] && ok "선무장된 다음 창이 pad 를 물려받음 ($NEXTPAD)" || fail "pad 유실: got=$NEXTPAD want=777"
bash "$FZ" cancel "${CHAINJOB3}-c0" > /dev/null 2>&1 || true

echo "== 체인: 리셋 경계에서 auto 추정이 UNKNOWN 이어도 선무장은 끊기지 않는다 (--at auto 미사용 확인) =="
# 옛 코드는 thaw 가 chain 재무장 때 'freeze.sh arm --at auto'(기본값)를 그대로 썼다 —
# 그러면 이 순간 cmd_estimate 가 UNKNOWN 을 내는 환경에서 선무장이 그대로 죽는다.
# CLAUDE_PROJECTS_DIR 을 통째로 비워 auto 추정이 반드시 실패하게 만든 뒤에도
# 체인이 끊기지 않아야 새 코드가 --at 을 명시 epoch 로 넘긴다는 게 증명된다.
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB4=boundaryjob
EMPTY_PROJ="$TMP/empty_projects_boundary"; mkdir -p "$EMPTY_PROJ"
CLAUDE_PROJECTS_DIR="$EMPTY_PROJ" bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" \
  --job "$CHAINJOB4" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  ST=$(CLAUDE_PROJECTS_DIR="$EMPTY_PROJ" node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB4/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
[ "$ST" = "done" ] && ok "boundaryjob 완주(auto 추정이 죽는 환경에서도)" || fail "boundaryjob status=$ST"
[ -f "$FREEZE_STATE_DIR/${CHAINJOB4}-c0/reservation.json" ] && ok "estimate=UNKNOWN 환경에서도 선무장 성공 (--at auto 를 안 씀)" || fail "선무장 실패 — 여전히 --at auto 에 의존 중"
WARN4=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB4/reservation.json')).chain_warning ?? '')")
[ -z "$WARN4" ] && ok "chain_warning 없음(성공)" || fail "예상 밖 chain_warning: $WARN4"
bash "$FZ" cancel "${CHAINJOB4}-c0" > /dev/null 2>&1 || true

echo "== 체인: 프로브 구간에 도착한 완료 신호는 재개를 생략시킨다 (이중 재개 방지) =="
# 재현: haiku 프로브가 실행되는 바로 그 순간(프로브 루프의 매 시도 시작 '전' 체크는
# 통과한 뒤) 실제 작업 세션이 done 을 부른 상황. 예전 코드는 (a) 완료 마커가
# handoff 경로 기준이라 곧이어 선무장이 지웠고, (b) 설령 마커가 남아도 재개를
# 부르기 전에 다시 확인하는 코드 자체가 없어 이미 끝난 작업을 --resume 으로
# 통째로 다시 열었다(thaw.sh:79-81 주석이 "불가능"이라 단언한 이중 재개).
: > "$CALLS"; echo "# h" > "$HANDOFF"
PROBEJOB=probesignaljob
export MOCK_DONE_MARK="$FREEZE_STATE_DIR/$PROBEJOB/done"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$PROBEJOB" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$PROBEJOB/reservation.json')).status)" 2>/dev/null || echo "")
  { [ "$ST" = "completed_early" ] || [ "$ST" = "done" ]; } && break
  sleep 1
done
unset MOCK_DONE_MARK
[ "$ST" = "completed_early" ] && ok "프로브 구간 완료 신호 → completed_early (재개 안 함)" || fail "기대: completed_early, 실제: $ST"
grep -q -- "--resume" "$CALLS" && fail "완료된 작업인데 --resume 이 호출됐다(이중 재개)" || ok "이중 재개 없음 — --resume 미호출"
NEXTST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${PROBEJOB}-c0/reservation.json')).status)" 2>/dev/null || echo MISSING)
[ "$NEXTST" = "cancelled" ] && ok "선무장돼 있던 다음 창도 함께 해제됨 (cancelled)" || fail "다음 창이 해제되지 않음: $NEXTST"

echo "== 체인: handoff 로 키잉된 완료 신호는 job 마커를 못 받은 자식도 나중에 스스로 본다 (major 3 회귀) =="
# 재현 경로: thaw 가 선무장(NEXT_JOB 생성) 직후~재확인 사이에서 죽으면, 그 job
# 마커는 done 호출 시점에 존재하던 예약에만 남으므로 NEXT_JOB 은 아무 마커도
# 못 받은 채 나중에 스스로 깨어나 이미 끝난 작업을 --resume 으로 다시 연다.
# 죽는 타이밍 자체를 흉내내는 대신(타이밍 레이스는 신뢰할 수 없다 — 실측으로도
# 프로세스 종료가 재확인보다 먼저 끝나는 경우가 드물었다), 그 죽음이 남기는
# "정확한 최종 상태" 를 직접 구성한다: 정상적으로 자식을 낳게 한 뒤, 자식의
# job 마커만 지워서 "job 마커는 없고 handoff 마커만 있다" 는 동일한 조건을 만든다.
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job m3chainjob --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  M3ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob/reservation.json')).status)")
  [ "$M3ST" = "done" ] && break
  sleep 1
done
[ "$M3ST" = "done" ] && ok "부모(m3chainjob) 정상 완주" || fail "부모 상태=$M3ST"
[ -f "$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json" ] && ok "자식(m3chainjob-c0) 선무장 확인" || fail "자식 선무장 실패"

PARENT_CREATED=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob/reservation.json')).created_at)")
CHILD_CREATED=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json')).created_at)")
[ "$PARENT_CREATED" = "$CHILD_CREATED" ] && ok "자식이 부모의 created_at 을 그대로 물려받음 ($CHILD_CREATED) — cmd_arm --created-at 전달 확인" || fail "created_at 상속 안됨: 부모=$PARENT_CREATED 자식=$CHILD_CREATED"

# 이제 완료 신호를 남긴다 — 부모는 이미 status=done 이라 매칭 안 되고, 자식(frozen)만
# job 마커를 받는다. 그 job 마커를 곧바로 지워서 "job 마커는 못 받았지만 handoff
# 마커는 남아있다"는 major 3 이 겨냥하는 조건을 정확히 재현한다.
bash "$FZ" done --handoff "$HANDOFF" > /dev/null
rm -f "$FREEZE_STATE_DIR/m3chainjob-c0/done"
[ -f "$FREEZE_STATE_DIR/m3chainjob-c0/done" ] && fail "job 마커 제거 실패(테스트 전제 오류)" || ok "job 마커 제거 — handoff 마커만 남은 상태 재현"

# 자식을 즉시 캐치업시킨다(5시간 뒤 예약을 그대로 기다릴 수 없으므로 죽이고 당긴다).
CHILD_PID=$(cat "$FREEZE_STATE_DIR/m3chainjob-c0/sleeper.pid" 2>/dev/null || true)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.resume_at=Math.floor(Date.now()/1000);
fs.writeFileSync(p, JSON.stringify(d,null,2));"
: > "$CALLS"
bash "$FZ" check > /dev/null
for i in $(seq 1 20); do
  M3ST2=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json')).status)")
  { [ "$M3ST2" = "completed_early" ] || [ "$M3ST2" = "done" ]; } && break
  sleep 1
done
[ "$M3ST2" = "completed_early" ] && ok "job 마커 없이도 handoff 신호만으로 재개 없이 종료 (major 3 수정 확인)" || fail "자식 상태=$M3ST2 (기대 completed_early)"
grep -q -- "--resume" "$CALLS" && fail "job 마커 없이도 자식이 이중 재개를 실행함" || ok "이중 재개 없음 — --resume 미호출"

echo "== handoff 재사용: 완료 신호보다 나중에 시작한 새 예약은 옛 신호에 안 걸린다 (major 3 — created_at 필터 회귀) =="
# 위에서 이미 이 handoff 로 done 신호가 남아있다. 초 단위 타임스탬프 충돌을
# 피하려고 1초 이상 벌린 뒤, 완전히 새로운(체인과 무관한) 예약을 건다 —
# 이 예약의 created_at 은 옛 신호보다 나중이므로 신호를 무시하고 정상 재개해야 한다.
sleep 1
: > "$CALLS"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job m3freshjob --chain-left 0 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 20); do
  M3ST3=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3freshjob/reservation.json')).status)")
  [ "$M3ST3" = "done" ] && break
  sleep 1
done
[ "$M3ST3" = "done" ] && ok "같은 handoff 를 재사용한 새 예약은 옛 신호와 무관하게 정상 재개함" || fail "새 예약이 옛 신호에 잘못 걸림: status=$M3ST3"
grep -q -- "--resume $SESSION" "$CALLS" && ok "새 예약이 실제로 재개를 실행함(옛 신호로 인한 오취소 없음)" || fail "새 예약이 재개를 못함: $(cat "$CALLS" 2>/dev/null)"

echo "== wfledger: init/mark/remaining/journal/run 왕복 =="
LEDGER_CWD="$TMP/wfwork"; mkdir -p "$LEDGER_CWD"
LPATH=$(bash "$WFL" init --job wtest --cwd "$LEDGER_CWD" --summary "테스트 잡" --session "$SESSION")
[ -f "$LPATH" ] && ok "init 원장 생성 ($LPATH)" || fail "init 실패"
OUT2=$(bash "$WFL" init --job wtest --cwd "$LEDGER_CWD" --summary "다시" --session "$SESSION")
[ "$OUT2" = "$LPATH" ] && ok "init 재호출은 덮어쓰지 않고 경로만 출력" || fail "init 재호출: $OUT2"

node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "- [ ] 1. 첫 단계\n- [ ] 2. 둘째 단계");
fs.writeFileSync(p, s);
' "$LPATH"

bash "$WFL" mark --ledger "$LPATH" --step 1 --artifact "$TMP/out1.txt" | grep -q "체크: 단계 1" && ok "mark 1" || fail "mark 1"
REM=$(bash "$WFL" remaining --ledger "$LPATH")
echo "$REM" | grep -q "2\. 둘째 단계" && ok "remaining 은 미완료만 출력" || fail "remaining: $REM"
echo "$REM" | grep -q "1\. 첫 단계" && fail "remaining 에 완료된 단계가 섞임" || ok "완료 단계는 remaining 에서 제외"
grep -qF "[x] 1. 첫 단계 → 산출물: $TMP/out1.txt" "$LPATH" && ok "mark 가 산출물 경로 기록" || fail "mark 산출물 기록 안됨"
bash "$WFL" mark --ledger "$LPATH" --step 9 > /dev/null 2>&1 && fail "없는 단계인데 성공함" || ok "없는 단계는 실패"

RUNID="wf_test123"
SLUG2=$(echo "$LEDGER_CWD" | sed 's/[^A-Za-z0-9-]/-/g')
RUNDIR="$CLAUDE_PROJECTS_DIR/$SLUG2/$SESSION/subagents/workflows/$RUNID"
SCRIPTDIR="$CLAUDE_PROJECTS_DIR/$SLUG2/$SESSION/workflows/scripts"
mkdir -p "$RUNDIR" "$SCRIPTDIR"
touch "$SCRIPTDIR/mytask-$RUNID.js"
{
  echo '{"type":"started","key":"v2:aaa","agentId":"agent1"}'
  echo '{"type":"result","key":"v2:aaa","agentId":"agent1","result":{"ok":true}}'
  echo '{"type":"started","key":"v2:bbb","agentId":"agent2"}'
} > "$RUNDIR/journal.jsonl"

bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID" | grep -q "등록: $RUNID" && ok "run 등록" || fail "run 등록 실패"
grep -q "runId: $RUNID" "$LPATH" && ok "runId 기록" || fail "runId 미기록"
grep -qF "journal: $RUNDIR/journal.jsonl" "$LPATH" && ok "journal 절대경로 기록" || fail "journal 경로 미기록"
grep -qF "script: $SCRIPTDIR/mytask-$RUNID.js" "$LPATH" && ok "script 절대경로 기록" || fail "script 경로 미기록"

echo "== wfledger: run 은 없는 runId 를 오타로 보고 거부한다 (major 회귀) =="
bash "$WFL" run --ledger "$LPATH" --run-id wf_typo_no_such_dir > /dev/null 2>&1 && fail "존재하지 않는 런 디렉토리인데 등록 성공함" || ok "런 디렉토리 없으면 등록 실패"
grep -q "wf_typo_no_such_dir" "$LPATH" && fail "실패한 런이 원장에 남음" || ok "실패한 런은 원장에 안 남음"

echo "== wfledger: run 은 같은 runId 재등록에 멱등이다 (중복 방지) =="
bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID" | grep -q "이미 등록됨" && ok "재등록은 '이미 등록됨' 으로 통과" || fail "재등록 메시지 다름"
DUPCOUNT=$(grep -c -- "- runId: $RUNID" "$LPATH")
[ "$DUPCOUNT" = 1 ] && ok "항목이 중복되지 않음 (1개)" || fail "runId 항목이 중복됨: $DUPCOUNT"

echo "== wfledger: 플레이스홀더 제거가 '## 워크플로우 런' 섹션에만 스코프된다 =="
# 목표/완료 기준 본문에 플레이스홀더 문구가 우연히 들어 있어도 지워지면 안 된다.
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("## 완료 기준\n", "## 완료 기준\n(등록된 런 없음) 이라는 말이 여기 우연히도 있다\n");
fs.writeFileSync(p, s);
' "$LPATH"
RUNID2="wf_second"
RUNDIR2="$CLAUDE_PROJECTS_DIR/$SLUG2/$SESSION/subagents/workflows/$RUNID2"
mkdir -p "$RUNDIR2"
echo '{"type":"result","key":"v2:ccc","agentId":"agent3"}' > "$RUNDIR2/journal.jsonl"
bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID2" | grep -q "등록: $RUNID2" && ok "두 번째 run 등록" || fail "두 번째 run 등록 실패"
PLACEHOLDER_COUNT=$(grep -c "(등록된 런 없음)" "$LPATH")
[ "$PLACEHOLDER_COUNT" = 1 ] && ok "완료 기준 본문의 우연한 문구는 살아남음 (1개 남음)" || fail "무관한 본문 줄까지 지워짐: 남은 개수=$PLACEHOLDER_COUNT"

echo "== wfledger: journal 없는 파일은 경고로 구분되고 조용히 사라지지 않는다 =="
RUNID3="wf_no_journal_yet"
RUNDIR3="$CLAUDE_PROJECTS_DIR/$SLUG2/$SESSION/subagents/workflows/$RUNID3"
mkdir -p "$RUNDIR3"   # 디렉토리는 있지만 journal.jsonl 은 아직 없음(아직 flush 전 재현)
bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID3" > /dev/null
JOUT=$(bash "$WFL" journal --ledger "$LPATH" 2>"$TMP/journal.err")
echo "$JOUT" | grep -q "agent1 v2:aaa" && ok "journal: 다른 정상 런의 완료된 호출은 그대로 출력" || fail "journal 출력: $JOUT"
grep -q "WARN.*journal 파일 없음" "$TMP/journal.err" && ok "journal 없는 등록은 WARN 으로 구분됨" || fail "WARN 안 남음: $(cat "$TMP/journal.err")"
echo "$JOUT" | grep -q "agent2" && fail "journal 에 미완료 호출이 섞임" || ok "미완료 호출 제외 확인"

echo "== wfledger: set-session 이 원장 헤더의 session 필드를 갱신한다 (major 회귀) =="
NEWSESS="22222222-3333-4444-5555-666666666666"
bash "$WFL" set-session --ledger "$LPATH" --session "$NEWSESS" | grep -q "세션 갱신" && ok "set-session 실행" || fail "set-session 실패"
grep -q "^session: $NEWSESS$" "$LPATH" && ok "원장 헤더 session 필드 갱신 확인" || fail "session 필드 미갱신"
# 갱신 후 run 은 --session 없이도 새 세션 경로로 계산해야 한다
RUNID4="wf_after_set_session"
RUNDIR4="$CLAUDE_PROJECTS_DIR/$SLUG2/$NEWSESS/subagents/workflows/$RUNID4"
mkdir -p "$RUNDIR4"
echo '{"type":"result","key":"v2:ddd","agentId":"agent4"}' > "$RUNDIR4/journal.jsonl"
bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID4" | grep -q "등록: $RUNID4" && ok "set-session 이후 run 이 새 세션 경로로 계산" || fail "새 세션 경로 계산 실패"
grep -qF "journal: $RUNDIR4/journal.jsonl" "$LPATH" && ok "새 세션 기준 journal 경로 기록" || fail "새 세션 경로 미기록"

echo "== wfledger: set-session --cwd 로 자동탐지도 된다 =="
AUTOSESS="33333333-4444-5555-6666-777777777777"
sleep 1.1  # ls -t 의 mtime 해상도 확보 — 이 파일이 확실히 "최신"이 되도록
echo '{}' > "$CLAUDE_PROJECTS_DIR/$SLUG2/$AUTOSESS.jsonl"
bash "$WFL" set-session --ledger "$LPATH" --cwd "$LEDGER_CWD" | grep -q "$AUTOSESS" && ok "cwd 기준 자동탐지 세션 갱신" || fail "자동탐지 세션 갱신 실패"

JOUT=$(bash "$WFL" journal --ledger "$LPATH")
echo "$JOUT" | grep -q "agent1 v2:aaa" && ok "journal: 완료된 호출만 출력" || fail "journal 출력: $JOUT"

echo "== wfledger link: 성공/폴백 =="
# 위 set-session 테스트들이 원장의 session: 필드를 바꿔 놨다 — link 는 그 필드로
# "원본" 런 디렉토리를 찾으므로, $RUNID 가 실제로 만들어진 $SESSION 으로 되돌린다.
bash "$WFL" set-session --ledger "$LPATH" --session "$SESSION" > /dev/null
NEWSESSION="99999999-8888-7777-6666-555555555555"
bash "$WFL" link --ledger "$LPATH" --run-id "$RUNID" --session "$NEWSESSION" | grep -q "링크됨" && ok "link 성공" || fail "link 실패"
NEWDIR="$CLAUDE_PROJECTS_DIR/$SLUG2/$NEWSESSION/subagents/workflows/$RUNID"
[ -L "$NEWDIR" ] && ok "symlink 생성 확인" || fail "symlink 없음"
bash "$WFL" link --ledger "$LPATH" --run-id "$RUNID" --session "$NEWSESSION" | grep -q "이미 존재" && ok "재호출은 idempotent" || fail "재호출 동작 이상"
bash "$WFL" link --ledger "$LPATH" --run-id "wf_missing" --session "$NEWSESSION" > /dev/null 2>&1 && fail "존재하지 않는 run 인데 성공함" || ok "원본 없으면 실패 코드로 폴백 신호"

echo
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
