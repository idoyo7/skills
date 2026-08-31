#!/usr/bin/env bash
# freeze 스킬 통합 테스트 — estimate 역산, reserve 세션 자동탐지, thaw 재개 호출까지.
# 실제 claude 를 부르지 않는다 (FREEZE_CLAUDE_BIN 목 사용).
set -eEuo pipefail   # -E: 함수 안 실패도 ERR 트랩에 걸린다(없으면 죽은 지점이 '?' 로 퇴화)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../scripts/_node.sh"
FZ="$HERE/../scripts/freeze.sh"
WFL="$HERE/../scripts/wfledger.sh"
TMP=$(mktemp -d)

# 순서 주의: 아래 트랩(cleanup)이 $FREEZE_STATE_DIR·$PASS·$SECTION 을 읽으므로, 이 변수들은
# `trap ... EXIT` 보다 반드시 먼저 정의돼야 한다. 나중에 두면 트랩이 그 사이에 발동할 때
# set -u 가 트랩 안에서 unbound variable 로 죽어 진짜 실패 원인이 가려진다.
export FREEZE_STATE_DIR="$TMP/state"
export CLAUDE_PROJECTS_DIR="$TMP/projects"
export FREEZE_HUD_CACHE="$TMP/hud"   # 실환경 HUD 캐시 격리 (기본값은 ~/.claude/hud/cache)

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
fail() { FAIL=$((FAIL+1)); echo "  FAIL: $1"; }
skip() { SKIP=$((SKIP+1)); echo "  skip: $1"; }

# ---- 외부 명령의 stdout 을 파이프 없이 단언한다 ----
#
#   assert_out <고정문자열 패턴> <ok 문구> <fail 문구> -- <명령...>
#
# 이 파일에는 `<명령> | grep -q <패턴> && ok ... || fail ...` 형태가 11곳 있었다.
# 그 형태는 단언 내용과 무관하게 뒤집힐 수 있다 — grep -q 는 첫 일치에서 즉시 exit 해
# 파이프의 읽는 쪽을 닫고, 그 순간 프로듀서에 아직 쓸 게 남아 있으면 EPIPE/SIGPIPE 를
# 맞는다(rc=141). pipefail 이 그 141 을 파이프라인 rc 로 올리므로 `&& ok` 를 건너뛰고
# `|| fail` 이 뜬다. 근거와 실측은 아래 usage 섹션 주석에 모아 뒀다. 여기서는 결론만:
# **크기로 안전을 논증할 수 없다. 그래서 파이프를 아예 쓰지 않는다.**
#
# 등가성(강화도 약화도 아님)이 이 함수의 핵심 계약이다. 옛 파이프 형태는 pipefail
# 아래에서 **프로듀서의 rc 까지** 판정에 섞고 있었다 — 명령이 비영 종료하면 패턴이
# 맞아도 `|| fail` 이 떴다. 캡처로 바꾸면 그 rc 판정이 사라지므로(대입의 rc 는
# `&&/||` 로 삼켜야 set -e 가 스위트를 끊지 않는다) rc 를 따로 받아 단언에 다시
# 접어넣는다. 파일의 다른 곳(CHECK_RC / NO_TARGET_RC / STRIPPED_RC)과 같은 관용구다.
#
# 패턴을 `*"$pat"*` 로 감싼 건 필수다 — 겹따옴표 안이라 글롭 메타문자(`*`·`?`·`[`)가
# 리터럴로 매칭되고, 옛 grep 고정 문자열과 정확히 등가가 된다.
# 정규식이 필요한 패턴에는 쓰지 마라 — 그 자리는 herestring(`grep -q -- pat <<<"$VAR"`)이다.
# 패턴에 빈 문자열을 넘기지 마라 — `*""*` 는 무조건 일치해 단언이 항상 통과한다
# (옛 `grep -q ""` 는 빈 출력에서 rc=1 이었으므로 이건 등가가 아니다).
assert_out() {
  local pat="$1" okmsg="$2" failmsg="$3"; shift 3
  # `[ ... ] && shift` 로 쓰지 않는다 — 실패하는 `[` 가 set -e 아래에서 ERR 트랩을
  # 건드려 ERR_LINE/ERR_CMD 를 무관한 값으로 덮을 여지를 만들지 않는다.
  if [ "${1:-}" = -- ]; then shift; fi
  local out rc
  out=$("$@") && rc=0 || rc=$?
  case "$out" in
    *"$pat"*)
      # `&& ok || fail` 로 쓰지 않는다 — `ok` 의 rc 는 echo 의 rc 라, stdout 이 닫히거나
      # 디스크가 차면 `ok` 가 실패해 `|| fail` 까지 돈다(한 사이트가 단언 2개로 세어져
      # PASS+FAIL 이 어긋나고, rc=0 인데 "비영 종료" 라는 자기모순 문구가 찍힌다).
      if [ "$rc" = 0 ]; then
        ok "$okmsg"
      else
        fail "$failmsg — 패턴 '$pat' 은 나왔지만 명령이 비영 종료 (rc=$rc): $out"
      fi;;
    *) fail "$failmsg (rc=$rc): $out";;
  esac
}

# ---- 공유 폴링 예산 ----
#
# 예약 status 가 기대값으로 전이하기를 기다리는 폴링 루프가 26곳 있고, 전부 같은
# 관용구(`for i in $(seq 1 N); do ST=$(node ... status); [ 조건 ] && break; sleep 1; done`)
# 를 쓴다. 예산이 20(=20초)일 때 26-way 부하에서 "handoff 재사용 … created_at 필터 회귀"
# 섹션이 52회 중 1회 status=frozen 으로 빨개졌다 — 본문은 HEAD 와 바이트 동일했으므로
# 코드 결함이 아니라 관측 창 부족이다. 26곳이 같은 숫자를 각자 박고 있으면 개별 땜질이
# 계속 반복되므로 한 곳으로 뽑는다.
#
# 예산을 늘려도 **정상 경로의 스위트 시간은 1초도 늘지 않는다** — 각 루프는 기대 상태를
# 보는 즉시 break 하므로 예산은 상한일 뿐이다. 비용이 실제로 드는 건 단언이 실패하는
# 실행뿐이고(사이트당 최대 POLL_TRIES 초), 그건 이미 빨간 실행이다. 그래서 기본값을
# 20 → 40 으로 올렸다(관측된 초과가 20 을 갓 넘긴 수준이라 2배 여유).
# 부하 하 검증에서 더 늘리려면 FREEZE_TEST_POLL_TRIES 로 덮어쓴다.
#
# 예산을 늘리는 것이 이빨을 죽이지 않는 이유: 이 루프들이 기다리는 상태는 모두 **흡수
# 상태**(done / failed / completed_early / cancelled)다. 회귀는 "느리게 도달"이 아니라
# "다른 흡수 상태에 도달"로 나타나므로, 더 오래 기다려도 틀린 상태가 맞는 상태로 바뀌지
# 않는다 — 판정이 늦어질 뿐 뒤집히지 않는다. 제품 코드 변이 6종으로 실측 확인했다
# (변이별로 어떤 단언이 빨개지는지는 이 라운드의 검증 기록 참고).
POLL_TRIES="${FREEZE_TEST_POLL_TRIES:-40}"

# 프로세스 사망을 기다리는 루프(`... dup_alive/alive ... || break; sleep 0.2`) 4곳은
# 일부러 이 변수를 쓰지 않는다 — 시행 횟수만 우연히 같고 관용구가 다르다(기다리는 대상이
# 상태 전이가 아니라 프로세스 소멸이고, sleep 단위가 0.2 라 예산의 뜻이 20초가 아니라
# 4초다). 같은 변수로 묶으면 상태 폴링 예산을 늘릴 때 kill 대기가 8초로 함께 늘어나
# 무관한 지연이 생긴다. 그쪽이 부하 하에서 모자라는 게 관측되면 별도 변수를 뽑아라.

# 폴링 실패를 두 갈래로 갈라 진단 문구를 만든다. 예전엔 예산 초과와 진짜 회귀가 똑같이
# `FAIL: ... status=frozen` 한 줄로 뭉개져, 다음 사람이 부하 하 거짓 실패를 회귀로
# 오진하거나 그 반대로 회귀를 "또 플레이키겠지" 로 넘길 수 있었다.
#   poll_diag <관측된 마지막 상태> <기대했던 상태...>
#
# 갈래 1 — frozen/running/빈 문자열: 아직 진행 중인 상태다. 예산 안에 전이를 못 봤다는
#   뜻이고, 원인이 하나가 아니라서 문구에 둘을 함께 적는다. 실측 대조로 둘 다 실재함을
#   확인했다: 부하 26-way 에서 예산 20 이 모자라 나온 거짓 실패가 있었고(플레이키),
#   반대로 캐치업 spawn 을 지운 변이(M5)와 완료 신호를 못 보게 한 변이(M6)는 예약이
#   **영구히** frozen 에 머물러 같은 갈래로 떨어졌다(진짜 회귀). 그래서 "플레이키니까
#   무시" 로 읽히지 않게 확인할 것을 둘 다 지시한다.
# 갈래 2 — 그 밖의 값: 이미 흡수 상태에 도달했는데 기대와 다르다. 예산과 무관하다 —
#   더 기다려도 바뀌지 않으므로 예산을 올려도 이 갈래는 절대 초록이 되지 않는다.
#   변이 M1~M4·M6 이 이 갈래로 떨어져 예산 40 에서도 전부 빨개졌다(이빨 유지 증거).
poll_diag() {
  local got="$1"; shift
  case "$got" in
    frozen|running|'')
      echo "관측 예산 초과 — ${POLL_TRIES}회 × sleep 1 안에 [$*] 를 못 봤다. 마지막 관측=[${got:-빈 값/읽기 실패}] (아직 진행 중인 상태). 원인 둘 중 하나다: (a) 부하로 관측 창이 모자랐다 → FREEZE_TEST_POLL_TRIES 를 늘려 재확인, (b) 이 예약이 애초에 전이하지 못하고 있다(슬리퍼 미기동·대기 루프 미탈출 같은 회귀) → 그 job 의 thaw.log 를 봐라";;
    *)
      echo "회귀 — 기대 [$*] 가 아니라 흡수 상태 [$got] 로 끝났다(예산과 무관하다: 더 기다려도 바뀌지 않는 상태다)";;
  esac
}

# ---- 중단을 큰 소리로 실패시키는 장치 ----
#
# 이 스위트는 set -euo pipefail 로 돌고 요약줄("PASS=... FAIL=... SKIP=...")은 맨 끝에서
# 딱 한 번 찍힌다. 그래서 중간의 어떤 명령이 비영 종료하면 요약줄에 닿기 전에 죽는데,
# 출력만 보면 "ok: N개, FAIL: 0개" 로 끝나 정상 완주와 구분이 안 됐다 — 다른 점은 종료코드
# 하나뿐이었다. 실측 사고: 병렬 부하 21회 중 3회에서 `freeze.sh done` 이 "완료 신호 기록
# 대상 없음"으로 비영 종료해 51개 섹션 중 37개만 돌고 끊겼고(ok 83개 FAIL 0개), 사람도 CI 도
# 그걸 통과로 읽었다. 그 fail-open 을 막는 게 아래 세 조각이다:
#   1) section()  — 지금 어느 섹션에 있는지 기록한다(중단 지점을 사람이 찾을 수 있게).
#   2) ERR 트랩   — 죽인 명령의 줄 번호와 명령문을 잡아둔다.
#   3) EXIT 트랩  — 요약줄에 닿았음을 표시하는 SUITE_COMPLETED 가 없으면 ABORTED 배너를
#                   찍고 반드시 비영 종료한다.
# 정상 완주 시 출력은 예전과 한 글자도 다르지 않다 — 기존 호출자·CI 가 "PASS=" 줄을
# 파싱하므로 그 형식과 위치를 그대로 유지한다.
SUITE_COMPLETED=0
SECTION="(픽스처 준비 — 첫 섹션 이전)"
ERR_LINE=""
ERR_CMD=""
ERR_RC=""

section() { SECTION="$1"; echo "== $1 =="; }

on_err() { ERR_RC="$1"; ERR_LINE="$2"; ERR_CMD="$3"; }
trap 'on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR

# 실패로 스크립트가 중간에 죽어도(set -e) 살아있는 슬리퍼(thaw.sh)를 남기지
# 않는다 — rm -rf "$TMP" 로 상태 파일이 먼저 사라지면 슬리퍼는 자기 상태를
# 잃어 스스로 취소도 못 하고 최대 몇 시간(프로브 재시도 포함) 떠 있는다.
# 반드시 죽이고 나서 지운다.
cleanup() {
  local rc=$?
  local f pid
  for f in "$FREEZE_STATE_DIR"/*/sleeper.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f" 2>/dev/null || true)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$TMP"
  [ "$SUITE_COMPLETED" = 1 ] && return
  # 요약줄에 못 닿았다 — 위의 ok: 개수와 무관하게 이 실행은 실패다.
  echo
  echo "############################################################"
  echo "ABORTED — 스위트가 요약줄에 닿기 전에 중단됐다 (종료코드 $rc)"
  echo "  마지막 섹션: $SECTION"
  echo "  죽은 지점: 줄 ${ERR_LINE:-?} — ${ERR_CMD:-?} (rc=${ERR_RC:-?})"
  # 여기에 PASS=/FAIL=/SKIP= 토큰을 쓰면 안 된다 — 앵커 없이 "FAIL=0" 을 grep 하는
  # 호출자가 중단을 통과로 읽는다.
  #
  # 정확히 말하면: **확장된 값**(`FAIL=0` 처럼 숫자가 붙은 형태)을 갖는 건 요약줄뿐이다.
  # 배너 자신은 그 토큰을 안 쓰지만, 바로 위 "죽은 지점" 줄이 ${ERR_CMD} 를 찍으므로
  # 죽은 명령이 맨 아래 요약줄 echo 자신이면 `echo PASS=$PASS FAIL=$FAIL SKIP=$SKIP`
  # 이라는 **미확장 문자열**이 배너에 실린다($BASH_COMMAND 는 확장 전 원문이다).
  # 그 형태는 `FAIL=0` grep 에 걸리지 않으므로(달러 기호가 붙은 `FAIL=$FAIL` 이다)
  # 위험하지 않다 — 그래서 배너 소독은 하지 않는다. 다만 이 주석이 "요약줄만이 그
  # 토큰을 갖는다" 라고 적혀 있으면 문자 그대로는 거짓이라, 다음 사람이 배너를
  # 읽다가 근거를 잘못 짚는다. 새 토큰을 배너에 넣고 싶으면 확장된 값이 실리지
  # 않는지를 그때 다시 확인해라.
  echo "  그 시점까지 통과 $PASS / 실패 $FAIL / 건너뜀 $SKIP  (중간 집계 — 요약줄 아님)"
  echo "  위의 'ok:' 개수만으로는 정상 완주와 구분되지 않는다. 이 실행은 통과가 아니다."
  echo "############################################################"
  exit $(( rc == 0 ? 1 : rc ))
}
trap cleanup EXIT

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

section "estimate"
EXPECT=$(( START - START % 3600 + 5*3600 ))
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$EXPECT" ] && ok "5h 윈도우 역산 ($GOT)" || fail "estimate: got=$GOT want=$EXPECT"

section "estimate: 활동 없음 → UNKNOWN"
GOT=$(CLAUDE_PROJECTS_DIR="$TMP/empty" bash "$FZ" estimate)
[ "$GOT" = "UNKNOWN" ] && ok "UNKNOWN 반환" || fail "empty estimate: got=$GOT"

section "estimate: HUD 캐시가 있으면 정확값 우선"
mkdir -p "$FREEZE_HUD_CACHE"
HUD_AT=$(( NOW + 1234 ))
echo "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":38,\"resets_at\":$HUD_AT}}}" > "$FREEZE_HUD_CACHE/stdin.$SESSION.json"
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$HUD_AT" ] && ok "HUD resets_at 우선 ($GOT)" || fail "HUD estimate: got=$GOT want=$HUD_AT"

section "estimate: HUD resets_at 이 과거면 폴백"
echo "{\"rate_limits\":{\"five_hour\":{\"resets_at\":$(( NOW - 10 ))}}}" > "$FREEZE_HUD_CACHE/stdin.$SESSION.json"
GOT=$(bash "$FZ" estimate)
[ "$GOT" = "$EXPECT" ] && ok "과거값 무시하고 역산 폴백" || fail "stale HUD: got=$GOT want=$EXPECT"
rm -f "$FREEZE_HUD_CACHE/stdin.$SESSION.json"

section "usage: --mode / --pad 가 도움말에 반영돼 있다"
USAGE_OUT=$(bash "$FZ" 2>&1) || true   # usage() 는 exit 1 — pipefail 오염 피하려고 먼저 변수로 받는다
# 왜 grep 이 아니라 case 인가 — 되돌리지 마라. (이 파일의 `| grep -q` 단언 정책 원본.
# 다른 사이트의 주석은 여기를 가리킨다.)
#
# ---- 실패 양식 ----
#   `echo "$USAGE_OUT" | grep -q -- "--mode"` 는 내용이 멀쩡해도 빨개질 수 있다. grep -q 는
#   첫 일치에서 즉시 exit 해 파이프의 읽는 쪽을 닫고, 그 순간 좌변에 아직 쓸 게
#   남아 있으면 EPIPE/SIGPIPE 를 맞는다(rc=141, stderr 에 "echo: write error: Broken pipe").
#   pipefail 이 그 141 을 파이프라인 rc 로 올리므로 `&& ok` 를 건너뛰고 `|| fail` 이 뜬다 —
#   단언 내용과 무관한 거짓 실패다. case 는 파이프도 프로세스도 만들지 않아 그 실패
#   양식이 구조적으로 존재하지 않는다.
#   극성이 부정인 자리(`... && fail || ok`)에서는 같은 사고가 **거짓 실패가 아니라 조용한
#   거짓 통과**로 나타난다 — grep 이 아니라 좌변이 죽어도 파이프라인 rc 가 비영이 되어
#   `&& fail` 을 건너뛰고 `|| ok` 가 뜬다. 회귀가 심어져 있어도 초록이다.
#   (`|| true` 로 rc 를 삼키는 방향은 금지 — 진짜 실패까지 같이 숨는다.)
#
# ---- 크기로 안전을 논증하지 마라. 그 논증은 실측으로 반증됐다 ----
#   예전 이 주석은 "bash 내장 `echo "$VAR"` 는 한 번의 write 로 끝나니 파이프 용량
#   65536바이트 아래면 141 이 나지 않는다" 고 적고, 그 규칙으로 사이트를 골라 남겼다.
#   **둘 다 틀렸다.** 이 머신 실측(2026-08-31):
#
#   (1) 임계값이 상수가 아니다. macOS 커널은 파이프가 많아지면 큰 버퍼 할당에 실패해
#       새 파이프를 강등한다. 구동변수는 파이프 **개수**가 아니라 커널이 실제로 할당한
#       파이프 버퍼 **총 바이트**(~16MiB)다 — macOS 는 첫 write 때 버퍼를 lazy 할당하므로
#       비어 있는 파이프 3000개를 들고 있어도 용량은 65536 그대로다. 데이터를 채운 파이프
#       200개(12.5MiB)에선 아직 65536, 800개에서 **512** 로 떨어졌다(별 프로세스에서
#       측정해도 512 — 시스템 전역 효과다).
#       그래서 "지금 재보니 여유가 N배" 라는 논증은 성립하지 않는다.
#
#   (2) 애초에 크기가 문제가 아니다. bash 내장 echo 는 여러 줄 문자열을 한 번의 write 로
#       내보내지 않는다. 아래 dupjob 섹션의 실제 페이로드(2줄, 파이프에 실리는 양 166바이트)
#       로 대조군을 갈라 각 20000회 돌렸다 — **무압력, 용량 65536**:
#         - 패턴이 **첫 줄**에 있음(일치 뒤에 쓸 게 남는다)  → 45/20000 뒤집힘
#           단, 이 비율은 조건 없이 인용하면 안 된다 — 실측 범위가 [0%, 0.505%] 다:
#             · 단일 프로세스·무압력      → 0/20000      (0%)
#             · 10병렬·무압력            → 45/20000, 82/20000, 117/50000 (0.22~0.41%)
#             · 10병렬 + 파이프압력(512) → 101/20000    (0.505%)
#           즉 45/20000 은 "10병렬·무압력" 의 대표값이다. 아래 세 곳(check·status·
#           ARM_BODY 섹션)이 이 수치를 인용하는데, 전부 이 조건부로 읽어라.
#         - 같은 페이로드, 패턴을 **마지막 줄**로 옮김(남는 쓰기 없음) → 0/20000
#         - 같은 페이로드, `case`                              → 0/20000
#       166바이트가 65536바이트 버퍼에서 터진다. 여유는 395배였다. 노출을 정하는 건
#       크기가 아니라 **일치하는 줄 뒤에 프로듀서의 write 가 더 남아 있는가** 다.
#
#   (3) 실제 사이트에서도 재현된다. dupjob 섹션(아래 "이전 슬리퍼 종료" 단언, 페이로드
#       131자 = 166바이트)만 뽑은 하네스를 10병렬 × 60회 = 600회 돌린 결과:
#         옛 파이프 형태 — 무압력 3/600, 파이프 압력 하 6/600 (전부 stderr 에 Broken pipe)
#         새 case 형태   — 파이프 압력 하 0/600
#       스위트 전체로도 10병렬 60회 중 2회 이 단언만 빨개진 적이 있다.
#
#   결론: 크기 근거를 다시 재지 마라. 여유를 3배로 재든 300배로 재든 근거가 서지 않는다.
#   **판정 기준을 바꾸는 게 아니라 판정할 필요가 없게 만든다 — 파이프를 아예 안 쓴다.**
#
# ---- 그래서 이 파일의 불변식: 단언에 파이프를 쓰지 않는다 ----
#   `| grep -q` 형태의 단언은 이 파일에 **하나도 없다**. 다음 명령의 출력이 비어야 한다
#   (뒤쪽 grep -v 는 이 주석 자신처럼 그 형태를 인용하는 주석 줄을 걸러낸다):
#     grep -nE '\|[[:space:]]*grep([[:space:]]+-[^[:space:]]*)*[[:space:]]*(-[a-zA-Z]*q|--quiet)' \
#       freeze/tests/test_freeze.sh | grep -vE ':[[:space:]]*#'
#   (좁게 `grep -q` 만 찾으면 `| grep -E -q`·`| grep --quiet`·`| grep -Fq`·공백 2개를
#   놓친다 — 실측 확인. 가드를 좁히지 마라.)
#   (예전 이 자리에는 "어느 파이프를 남겼고 왜 안전한가" 를 적은 감사 표가 있었다.
#   남긴 파이프가 없으니 표도 없앴다 — 표를 되살리는 건 크기 논증을 되살리는 것이다.
#   그 표에는 "부정 극성으로 남아 있는 `| grep` 은 하나도 없다" 는 문장도 있었는데,
#   그건 당시에도 거짓이었다. 실제로 3곳(deadreapjob 종료 로그 / remaining 완료 단계 /
#   journal 미완료 호출) 이 부정 극성 파이프였고, 위 (2)의 조용한 거짓 통과 위험에
#   그대로 노출돼 있었다. 지금은 전부 case 다.)
#
# ---- 전환 규칙 ----
#   - 고정 문자열 → 캡처 + `case "$VAR" in *패턴*) ... ;; *) ... ;; esac`.
#     case 글롭은 정규식이 아니다. 패턴에 셸 메타문자(공백·`$`·`*`·`[`)가 있으면
#     겹따옴표로 감싸 리터럴화해라(예: `*"session=$SESSION"*`, `*'--chain-left "$chain_left"'*`).
#   - 정규식이 필요한 패턴(교대 `|`, 앵커 `^$`, 문자클래스) → case 로 옮기면 의미가 바뀐다.
#     herestring `grep -q -- "pat" <<<"$VAR"` 을 써라 — 파이프가 아니라 bash 가 만드는
#     임시 입력이므로 쓰는 쪽 프로세스가 없고 SIGPIPE 도 없다(선례: ARM_BODY, EXPORT_CHECK).
#   - 좌변이 외부 명령이면 → 위쪽 `assert_out` 을 써라. 캡처 + rc 별도 수신 + case 다.
#     옛 파이프에서 pipefail 이 하던 프로듀서 rc 판정을 잃지 않게 그 rc 를 단언에 접어넣는다.
#   - 파일을 읽는 검사는 파일 인자 grep(`grep -q pat "$CALLS"`)으로 남겨라 — 파이프가 없다.
#   - `grep -v` / `grep -c` / `grep -n | head` 는 이 문제의 대상이 아니다: 앞의 둘은 입력을
#     끝까지 읽어야 결과를 낼 수 있어 조기 exit 이 없고, 셋째는 `head -1` 이 조기 exit 하지만
#     첫 줄은 이미 전달된 뒤라 **추출값이 옳고** rc 는 `|| true` 로 이미 처리돼 판정에 안 쓴다.
#     (이 파일의 해당 사이트: ARM_BODY / RESERVE_BODY / WRITE_COUNT / WRITE_LINE /
#     SPAWN_LINE / ORDER*_LN / STRIPPED)
case "$USAGE_OUT" in *--mode*) ok "usage 에 --mode 있음";; *) fail "usage 에 --mode 없음";; esac
case "$USAGE_OUT" in *--pad*)  ok "usage 에 --pad 있음";;  *) fail "usage 에 --pad 없음";;  esac

section "reserve + thaw (mock claude)"
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
#   MOCK_DONE_MARK_ON_RESUME - 프로브가 아닌 호출(=재개 호출) "도중"에 이 경로에 완료
#                              마커를 남긴다 (재개 세션이 작업을 끝내고 done 을 부른 상황
#                              재현 — 재개 이후 분기의 순서 단언에 쓴다)
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
if [ -n "${MOCK_DONE_MARK_ON_RESUME:-}" ] && [[ "$*" != *"--model haiku"* ]]; then
  date '+%F %T 완료' > "$MOCK_DONE_MARK_ON_RESUME"
fi
exit 0
MOCKEOF
chmod +x "$MOCK"
export FREEZE_CLAUDE_BIN="$MOCK"

HANDOFF="$FAKE_CWD/handoff.md"; echo "# test handoff" > "$HANDOFF"
OUT=$(bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job testjob)
case "$OUT" in *job=testjob*)          ok "reserve 등록";;    *) fail "reserve 출력: $OUT";;  esac
case "$OUT" in *"session=$SESSION"*)   ok "세션 자동탐지";;   *) fail "세션 탐지: $OUT";;    esac

for i in $(seq 1 "$POLL_TRIES"); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/testjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "thaw 완주 (status=done)" || fail "thaw 완주 실패 — $(poll_diag "$STATUS" done)"
grep -q -- "--resume $SESSION" "$CALLS" && ok "resume 호출 (세션 id 일치)" || fail "resume 호출 없음: $(cat "$CALLS" 2>/dev/null)"
grep -q -- "--model haiku" "$CALLS" && ok "haiku 프로브 선행" || fail "프로브 없음"
grep -q -- "--permission-mode bypassPermissions" "$CALLS" && ok "기본 권한 bypassPermissions" || fail "권한 모드: $(grep resume "$CALLS")"

section "reserve --permission-mode 오버라이드"
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job permjob --permission-mode acceptEdits > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/permjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
grep -q -- "--permission-mode acceptEdits" "$CALLS" && ok "오버라이드 반영" || fail "오버라이드 미반영 — permjob $(poll_diag "$STATUS" done): $(grep resume "$CALLS")"

section "reserve: 같은 job 이름을 재예약하면 이전 슬리퍼를 정리한다 (major 1 회귀)"
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
# 이 자리가 이 파일에서 실제로 거짓 실패를 낸 유일한 `echo | grep -q` 사이트다
# (실측: 스위트 10병렬 60회 중 2회, dupjob 섹션만 뽑은 최소 하네스 10병렬 600회 중
# 3~6회. 페이로드는 2줄 131자 = 166바이트 — 파이프 용량과 무관하다. 위 usage 섹션 참고).
case "$OUT" in
  *"이전 슬리퍼 종료"*) ok "이전 슬리퍼 종료 로그 확인";;
  *) fail "이전 슬리퍼 종료 로그 없음: $OUT";;
esac
sleep 1
dup_alive() { s=$(ps -o state= -p "$1" 2>/dev/null | tr -d ' '); [ -n "$s" ] && [ "${s:0:1}" != "Z" ]; }
dup_alive "$OLD_SLEEPER_PID" && fail "이전 슬리퍼가 여전히 살아있음 (pid=$OLD_SLEEPER_PID)" || ok "이전 슬리퍼가 실제로 종료됨"
for i in $(seq 1 "$POLL_TRIES"); do
  DUPST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/dupjob/reservation.json')).status)")
  [ "$DUPST" = "done" ] && break
  sleep 1
done
[ "$DUPST" = "done" ] && ok "재예약 후 정상 완주" || fail "재예약 후 완주 실패 — $(poll_diag "$DUPST" done)"
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

section "reserve: 재예약 시점에 이전 슬리퍼가 이미 죽어있으면 조용히 넘어간다"
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job deadreapjob > /dev/null
DEADREAP_PID=$(cat "$FREEZE_STATE_DIR/deadreapjob/sleeper.pid")
kill -9 "$DEADREAP_PID" 2>/dev/null || true
for i in $(seq 1 20); do dup_alive "$DEADREAP_PID" || break; sleep 0.2; done
OUT2=$(bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job deadreapjob 2>&1)
# 부정 극성 1/3 — 여기서 파이프를 걷는 건 거짓 실패가 아니라 **조용한 거짓 통과**를
# 막는 일이다. 옛 형태 `echo "$OUT2" | grep -q pat && fail || ok` 에서 grep 이 아니라
# 좌변 echo 가 SIGPIPE 로 죽으면 파이프라인 rc 가 비영이 되어 `&& fail` 을 건너뛰고
# `|| ok` 가 뜬다 — 회귀가 심어져 있어도 초록이다. 위 usage 섹션 주석의 실측 참고.
#
# 위 캡처의 `2>&1` 은 필수다 — 떼면 아래 첫 단언(부정 극성)이 이빨을 잃는다.
#     reap_stale_sleeper(freeze.sh)의 "재예약 — 이전
#     슬리퍼 종료" 는 `>&2` 로 나간다. 즉 제품이 무슨 짓을 해도 그 문구가 OUT2 에 실릴
#     수 없다. 실측(2026-08-31): freeze.sh 의 pid_alive 가드 앞에 그 echo 를 무조건
#     찍는 회귀를 심어 스위트를 돌렸더니 메시지는 스위트 stderr 에 실제로 나왔는데
#     (deadreapjob 1건) 이 단언은 그대로 `ok` 였다 — PASS=150 FAIL=0.
#     같은 문구를 보는 위쪽 dupjob 단언은 처음부터 `2>&1` 이 있어서 이빨이 있었다.
#     2026-08-31 에 `2>&1` 을 붙여 고쳤다: 정상 제품에서는 PASS/FAIL 무변화이고,
#     같은 회귀를 심으면 정확히 이 단언만 빨개진다(부수효과 0, 실측 확인).
case "$OUT2" in
  *"이전 슬리퍼 종료"*) fail "이미 죽은 슬리퍼인데 종료 로그가 찍힘: $OUT2";;
  *) ok "이미 죽은 슬리퍼는 조용히 넘어감";;
esac
case "$OUT2" in
  *얼음*) ok "재예약 자체는 정상 성공";;
  *) fail "재예약 실패: $OUT2";;
esac
bash "$FZ" cancel deadreapjob > /dev/null 2>&1 || true

section "arm: 선예약 + 체인 정보"
: > "$CALLS"; echo "# h" > "$HANDOFF"
# 완료 마커는 이제 job 디렉토리 안에 스코프돼 있다(freeze.sh:cmd_reserve/cmd_done 참고).
# "이전 회차의 스테일 마커 제거"가 여전히 의미 있는 유일한 경우는 같은 job 이름을
# 재사용하는 경우뿐이다 — 그래서 armjob 자신의 디렉토리에 미리 스테일 마커를 심는다.
mkdir -p "$FREEZE_STATE_DIR/armjob"
touch "$FREEZE_STATE_DIR/armjob/done"
OUT=$(bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job armjob --chain-left 2)
case "$OUT" in *"무장 완료"*) ok "arm 등록";; *) fail "arm 출력: $OUT";; esac
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

section "done: 완료 신호로 재개 없이 종료"
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job donejob --chain-left 1 > /dev/null
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/donejob/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.resume_at=Math.floor(Date.now()/1000)+3;
fs.writeFileSync(p, JSON.stringify(d,null,2));"   # 곧 깨어나도록 당긴다
assert_out "완료 신호" "done 마커 기록" "done 출력에 완료 신호가 없다" -- bash "$FZ" done --handoff "$HANDOFF"
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
# 않았다. 대신 폴링 창을 60초 worst-case 보다 넉넉히 늘려 정렬과 무관하게 항상
# 감지되도록 한다. 스위트 전체 실행 시간에 미치는 영향은 이 섹션 하나의 worst-case
# 증가분뿐이며, 실측상 이 섹션은 매 실행 0~60초 사이에서 끝나므로 평균 증가분은
# 이보다 작다.
#
# 이 자리의 예산만 다른 25곳과 다르게 잡는 건 의도다(상태 폴링 루프는 이 자리를 포함해
# 모두 26곳이다 — 위 POLL_TRIES 주석의 26 은 총계, 여기 25 는 나머지다) — POLL_TRIES(기본 40) 를 그대로
# 쓰면 60초 정렬 worst-case 를 못 덮는다. 필요한 값이 "일반 예산" 이 아니라 "thaw 의
# 60초 대기 chunk + 일반 예산" 이므로 그 구조를 식으로 적어 둔다. 이렇게 두면
# FREEZE_TEST_POLL_TRIES 로 부하 하 여유를 늘릴 때 이 자리도 함께 늘어난다
# (예전엔 리터럴 80 이라 늘 수 없었다). 정상 경로 소요는 예산과 무관하다 —
# completed_early 를 보는 즉시 break 한다.
for i in $(seq 1 $(( 60 + POLL_TRIES )) ); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/donejob/reservation.json')).status)")
  [ "$ST" = "completed_early" ] && break
  sleep 1
done
[ "$ST" = "completed_early" ] && ok "완료 신호로 조기 종료" || fail "조기 종료 안 됨 — $(poll_diag "$ST" completed_early) (이 자리의 예산은 60 + POLL_TRIES = $(( 60 + POLL_TRIES ))회다)"
grep -q -- "--resume" "$CALLS" && fail "완료 신호에도 재개가 돌았다" || ok "재개 호출 없음"

section "done: 활성 예약이 없으면 대상 없음을 알리고 비영 종료코드를 낸다 (major 2 회귀)"
# pipefail 로 묶어 grep 결과와 종료코드를 동시에 판정하면 안 된다 — done 자체의
# 종료코드가 이제 실패(1)이므로 파이프라인 판정에 섞으면 메시지가 맞아도 FAIL 로
# 잘못 뒤집힌다. 메시지와 종료코드를 따로 확인한다.
NO_TARGET_OUT=$(bash "$FZ" done --handoff "$FAKE_CWD/no-such-handoff.md" 2>&1) && NO_TARGET_RC=0 || NO_TARGET_RC=$?
case "$NO_TARGET_OUT" in
  *"대상 없음"*) ok "무대상 done 은 경고로 알림";;
  *) fail "무대상 done 이 조용히 성공만 함: $NO_TARGET_OUT";;
esac
[ "$NO_TARGET_RC" -ne 0 ] && ok "무대상 done 은 비영 종료코드 (rc=$NO_TARGET_RC)" || fail "무대상 done 의 종료코드가 0 — 자동 호출자가 실패를 못 본다"

section "done: handoff 경로를 절대 realpath 로 정규화해 비교한다 (major 2 회귀)"
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

section "cancel"
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job canceljob > /dev/null
assert_out "취소됨" "cancel" "cancel 출력에 취소됨이 없다" -- bash "$FZ" cancel canceljob
STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/canceljob/reservation.json')).status)")
[ "$STATUS" = "cancelled" ] && ok "상태 cancelled" || fail "cancel status=$STATUS"

section "check (죽은 슬리퍼 캐치업)"
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
# 여기도 파이프를 걷었다 — 그리고 이 자리는 파일 안에서 **결정적으로** 터지던 유일한
# 파이프였다(다른 사이트들은 확률적으로 터졌다).
# 왜 파이프가 아닌가 / 되돌리지 마라:
#   cmd_check(freeze.sh)는 캐치업 대상마다 echo 를 따로 찍고, 그 echo 사이에
#   spawn_sleeper(fork bash + node)가 끼어 각 echo 가 곧바로 flush 된다. 그래서 대상이
#   둘 이상이면 **일치하는 줄 뒤에 쓰기가 남고**, grep -q 가 첫 일치에서 exit 해 파이프
#   읽는 쪽을 닫는 순간 남은 echo 가 EPIPE/SIGPIPE 를 맞는다(rc=141). pipefail 이 그
#   141 을 파이프라인 rc 로 올리므로 `&& ok` 를 건너뛰고 `|| fail` 이 뜬다 — 단언
#   내용과 무관한 거짓 실패다.
#   실측(이 머신, 전용 재현 하네스 — 예약을 N개 심고 같은 파이프라인을 반복 실행):
#     캐치업 대상 1개 → 옛 형태 rc=141 0/40,  2개 → 40/40,  3개 → 60/60.
#     같은 조건에서 아래 캡처 형태는 1개 0/40, 2개 0/40, 3개 0/60.
#   즉 노출을 결정하는 건 페이로드 크기가 아니라 **일치하는 줄 뒤에 프로듀서의 write 가
#   남아 있는가** 다. 여기서 그 답이 "대상 2개 이상이면 남는다" 이고, 페이로드는 512바이트급
#   이었다. 위 usage 섹션 주석의 일반론과 같은 결론이며, 거기에는 파이프 용량 자체가
#   상수가 아니라는 실측(3000개 보유 시 65536 → 512 강등)도 적어 뒀다.
#
#   지금까지 초록이던 이유는 코드가 안전해서가 아니라 **이 시점의 캐치업 대상이 정확히
#   1개(deadjob)** 라서다. 이 섹션 앞쪽에서 frozen + 땡 경과 + 슬리퍼 사망 상태로 남는
#   예약이 하나만 더 늘면 이 단언은 내용과 무관하게 결정적으로(40/40) 빨개진다.
#   주의: 위 "1개 → 0/40" 을 "1개면 안전" 으로 읽지 마라. 40회 표본에서 안 봤다는 뜻일
#   뿐이다 — usage 섹션 주석의 실측에서 단일 write 로 보이던 bash 내장 echo 조차
#   20000회에 45회 터졌다(10병렬·무압력 조건 — usage 섹션의 조건표 참고).
#   그래서 "대상이 1개니까 파이프를 남긴다" 는 판단은 하지 않는다.
#   그 함정을 없앤다. 패턴이 고정 문자열이라 case 글롭은 grep -q 와 등가다.
#
# rc 를 따로 받아 단언에 접어 넣는다 — 파이프를 걷으면서 이 대입이 `&&/||` 문맥 밖으로
# 나왔으므로, 그냥 두면 check 가 비영 종료하는 날 set -e 가 단언 대신 스위트를 끊는다.
# (옛 파이프 형태에서도 pipefail 이 check 의 rc 를 이미 판정에 섞고 있었으므로 이건
# 계약 강화가 아니라 그 계약을 명시로 옮긴 것이다.) 파일의 다른 곳(STATUS_RC /
# ISOA_DONE_RC / BROKEN_RC)과 같은 관용구다.
CHECK_OUT=$(bash "$FZ" check) && CHECK_RC=0 || CHECK_RC=$?
case "$CHECK_OUT" in
  *캐치업*)
    [ "$CHECK_RC" = 0 ] && ok "check 가 재기동" || fail "캐치업은 찍혔지만 check 가 비영 종료 (rc=$CHECK_RC): $CHECK_OUT";;
  *) fail "check 미동작 (rc=$CHECK_RC): $CHECK_OUT";;
esac
for i in $(seq 1 "$POLL_TRIES"); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/deadjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "캐치업 완주" || fail "캐치업 완주 실패 — $(poll_diag "$STATUS" done)"

section "--pad: 사용자가 명시하면 해석된 epoch 에 그대로 더해진다"
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +10s --pad 100 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job padjob > /dev/null
PAD_AT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/padjob/reservation.json')).resume_at)")
PAD_NOW=$(date +%s)
PAD_DIFF=$(( PAD_AT - PAD_NOW ))
[ "$PAD_DIFF" -ge 95 ] && [ "$PAD_DIFF" -le 130 ] && ok "pad 반영 (diff=${PAD_DIFF}s, 기대 ~110s)" || fail "pad 미반영: diff=$PAD_DIFF"
bash "$FZ" cancel padjob > /dev/null

section "--at 명시 시각은 --pad 를 직접 주지 않으면 패딩되지 않는다 (회귀 방지)"
echo "# h" > "$HANDOFF"
REQ_EPOCH=$(( $(date +%s) + 1000 ))
bash "$FZ" reserve --at "$REQ_EPOCH" --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job nopadjob > /dev/null
GOT_EPOCH=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob/reservation.json')).resume_at)")
[ "$GOT_EPOCH" = "$REQ_EPOCH" ] && ok "명시 epoch 는 패딩 없음 (got=$GOT_EPOCH)" || fail "명시 epoch 에 기본 패딩이 붙음: want=$REQ_EPOCH got=$GOT_EPOCH"
STORED_PAD=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob/reservation.json')).pad)")
[ "$STORED_PAD" = "0" ] && ok "저장된 pad 필드도 0" || fail "저장된 pad: $STORED_PAD"
bash "$FZ" cancel nopadjob > /dev/null
# +30s 같은 상대 지정도 동일 계약이어야 한다.
#
# 판정 기준을 "지금 시각 기준 고정 창([28,32])" 으로 두면 안 된다 — reserve 가 시계를 읽는
# 순간과 이 스크립트가 date 를 읽는 순간 사이의 경과 시간이 그대로 오차로 들어온다. 부하가
# 걸리면 그 사이(fork bash + node 쓰기 + 슬리퍼 spawn)가 3초를 넘고, 그러면 REL_AT 는 멀쩡한데
# diff=27 로 창을 벗어나 빨개졌다(실측: 스위트 20회 병렬에서 6회. 이 단언만 실패).
# 대신 reserve 를 감싸 시계를 두 번 읽어 구간으로 판정한다. reserve 가 시계를 읽은 순간 t 는
# T0 ≤ t ≤ T1 이 확실하므로, 패딩이 없다면 REL_AT = t+30 ∈ [T0+30, T1+30] 이다.
# 이 구간 검사는 고정 창보다 **더 엄격하다** — 경과가 0초면 허용값이 정확히 한 개
# (T0+30)로 좁혀진다. 반대로 기본 패딩(pad=300)이 붙으면 REL_AT 는 상한보다 300초 위로
# 튀므로 회귀 검출력은 그대로다. 창을 넓혀 무마한 게 아니라 오차원을 제거한 것이다.
T0=$(date +%s)
bash "$FZ" reserve --at +30s --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job nopadjob2 > /dev/null
T1=$(date +%s)
REL_AT=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/nopadjob2/reservation.json')).resume_at)")
{ [ "$REL_AT" -ge $(( T0 + 30 )) ] && [ "$REL_AT" -le $(( T1 + 30 )) ]; } \
  && ok "+30s 도 패딩 없이 그대로 (resume_at-T0=$(( REL_AT - T0 ))s, reserve 경과 $(( T1 - T0 ))s)" \
  || fail "+30s 에 패딩 붙음: resume_at-T0=$(( REL_AT - T0 ))s, 허용 구간 [30, $(( T1 - T0 + 30 ))]"
bash "$FZ" cancel nopadjob2 > /dev/null

section "mode=ledger: --resume 미사용, 원장 경로가 프롬프트에 실린다"
# 가짜 한 줄짜리 handoff 가 아니라 wfledger.sh init 이 실제로 만드는 원장을 쓴다 —
# 아래 섹션명 일치 검증이 진짜 원장 내용을 봐야 의미가 있다.
: > "$CALLS"
LEDGER_HANDOFF=$(bash "$WFL" init --job ledgerjob --cwd "$FAKE_CWD" --summary "ledger 재개 테스트" \
  --session "$SESSION" --goal "테스트 목표" --done-when "테스트 완료 기준")
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$LEDGER_HANDOFF" --job ledgerjob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/ledgerjob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
[ "$STATUS" = "done" ] && ok "ledger 모드 재개 완주" || fail "ledger 재개 완주 실패 — $(poll_diag "$STATUS" done)"
grep -q -- "--resume" "$CALLS" && fail "ledger 모드인데 --resume 을 썼다" || ok "ledger 모드는 --resume 미사용"
grep -qF -- "$LEDGER_HANDOFF" "$CALLS" && ok "원장 경로가 프롬프트에 실림" || fail "원장 경로 프롬프트 누락: $(cat "$CALLS" 2>/dev/null)"
grep -q -- "set-session" "$CALLS" && ok "재개 프롬프트가 wfledger set-session 을 지시함" || fail "set-session 안내 누락"

section "mode=ledger: 재개 프롬프트가 가리키는 섹션명이 원장의 실제 섹션명과 맞는다 (minor 회귀)"
# 예전엔 가짜 handoff("# ledger placeholder" 한 줄)를 써서 실제 원장 내용과
# thaw.sh 프롬프트가 아예 무관했다 — '## 워크플로우 런' 섹션명을 어느 한쪽만
# 바꿔도(오타·리팩터) 테스트가 계속 초록이었다. 여기서는 위에서 실제로 만든
# 원장 파일을 직접 열어, thaw.sh 프롬프트가 지시하는 섹션명이 그 안에 정말
# 있는지 확인한다.
THAW_SRC="$HERE/../scripts/thaw.sh"
SECTION_NAME=$(sed -n "s/.*읽고 '\(## [^']*\)' 에 등록된.*/\1/p" "$THAW_SRC")
[ -n "$SECTION_NAME" ] && ok "thaw.sh 프롬프트에서 섹션명 추출: $SECTION_NAME" || fail "thaw.sh 에서 섹션명 추출 실패 — 프롬프트 문구가 바뀌었을 수 있음"
grep -qxF "$SECTION_NAME" "$LEDGER_HANDOFF" && ok "원장에 그 섹션명이 실제로 있음" || fail "섹션명 불일치 — 원장에 '$SECTION_NAME' 없음: $(grep '^##' "$LEDGER_HANDOFF")"

section "mode=ledger: 프로젝트 transcript 디렉토리가 없어도 reserve 가 죽지 않는다"
LEDGER_NEW_CWD="$TMP/ledger-fresh-cwd"; mkdir -p "$LEDGER_NEW_CWD"
echo "# fresh" > "$LEDGER_NEW_CWD/h.md"
OUT=$(bash "$FZ" reserve --at +1h --cwd "$LEDGER_NEW_CWD" --handoff "$LEDGER_NEW_CWD/h.md" --job freshledgerjob --mode ledger)
case "$OUT" in *얼음*) ok "세션 미탐지에도 ledger reserve 성공";; *) fail "ledger reserve 실패: $OUT";; esac
bash "$FZ" cancel freshledgerjob > /dev/null

section "ledger 게이트 발동: 원장에 남은 단계가 없으면 재개를 생략한다 (수정 B)"
# 원장의 유일한 단계를 체크(=remaining 이 비어짐)한 뒤 ledger 모드로 예약하면,
# thaw 는 재개를 부르지 않고 completed_early 로 조용히 끝나야 한다.
: > "$CALLS"
GATE_HANDOFF=$(bash "$WFL" init --job gatejob --cwd "$FAKE_CWD" --summary "게이트 테스트" --session "$SESSION" --goal "게이트 목표" --done-when "게이트 완료 기준")
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "- [ ] 1. 유일한 단계");
fs.writeFileSync(p, s);
' "$GATE_HANDOFF"
bash "$WFL" mark --ledger "$GATE_HANDOFF" --step 1 > /dev/null
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$GATE_HANDOFF" --job gatejob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  GATEST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/gatejob/reservation.json')).status)")
  [ "$GATEST" = "completed_early" ] && break
  sleep 1
done
[ "$GATEST" = "completed_early" ] && ok "원장 완료 상태 → completed_early (재개 생략)" || fail "게이트 미발동 — $(poll_diag "$GATEST" completed_early)"
# 재개 호출의 고유 표지는 --permission-mode 다 — haiku 프로브는 이 플래그를 안 쓴다.
# ledger 모드는 --resume 을 안 쓰므로 기존 케이스처럼 "--resume" 문자열로는 판정할 수 없다.
grep -q -- "--permission-mode" "$CALLS" && fail "게이트가 발동했는데도 재개 호출이 실행됨" || ok "재개 호출 없음 (haiku 프로브는 찍힐 수 있음)"

section "ledger 게이트: 원장 파일이 사라지면 완료로 오판정하지 않는다 (수정 B 회귀 — ledger_complete 의 [ -f \$HANDOFF ] 가드 경로. remaining 은 이 가드에 먼저 막혀 아예 불리지 않는다)"
: > "$CALLS"
LOST_HANDOFF=$(bash "$WFL" init --job lostledgerjob --cwd "$FAKE_CWD" --summary "분실 테스트" --session "$SESSION" --goal "g" --done-when "d")
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$LOST_HANDOFF" --job lostledgerjob --mode ledger > /dev/null
rm -f "$LOST_HANDOFF"
for i in $(seq 1 "$POLL_TRIES"); do
  LOSTST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/lostledgerjob/reservation.json')).status)")
  [ "$LOSTST" = "done" ] && break
  sleep 1
done
[ "$LOSTST" = "done" ] && ok "원장 분실에도 게이트가 오판정하지 않고 정상 재개" || fail "원장 분실 시 — $(poll_diag "$LOSTST" done)"
grep -q -- "--permission-mode" "$CALLS" && ok "재개 호출이 실제로 실행됨" || fail "재개 호출 누락: $(cat "$CALLS" 2>/dev/null)"

section "ledger 게이트: 체크박스가 없는 원장은 판정 불가로 다뤄 재개를 진행한다 (수정 B 회귀)"
: > "$CALLS"
NOBOX_HANDOFF="$FAKE_CWD/nobox-handoff.md"
{
  echo "# 원장"
  echo "체크박스 섹션을 지운 원장"
} > "$NOBOX_HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$NOBOX_HANDOFF" --job noboxjob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  NOBOXST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/noboxjob/reservation.json')).status)")
  [ "$NOBOXST" = "done" ] && break
  sleep 1
done
[ "$NOBOXST" = "done" ] && ok "체크박스 없는 원장은 게이트 미발동, 정상 재개" || fail "체크박스 없는 원장에서 — $(poll_diag "$NOBOXST" done)"
grep -q -- "--permission-mode" "$CALLS" && ok "재개 호출이 실제로 실행됨" || fail "재개 호출 누락: $(cat "$CALLS" 2>/dev/null)"

section "ledger 게이트: 상위 단계는 체크됐고 들여쓴 하위 미체크 항목만 남으면 게이트가 발동하지 않는다 (절 스코프+들여쓰기 인식 판정 회귀)"
# 이 단언이 판별하는 대상은 "파일 전체를 보는 체크박스 판정"(= remaining 단독 판정과
# 같은 형태)이다. 그 형태에서는 여기가 실패한다(실측 확인). 게이트가 아예 없던 시절의
# 코드에서는 항상 재개하므로 그냥 통과한다 — 판별 대상이 아니다. 파일 전체에 '- [x]' 가
# 있는지만 보는 존재 확인은 통과하고, remaining 의 '^- ' 앵커(wfledger.sh:258)는
# 들여쓴 "  - [ ] 1a. 미완" 을 못 잡아 출력이 비어 게이트가 잘못 발동했다(오발동
# 2번, thaw.sh ledger_complete 주석 참고). 지금은 '## 단계' 절 스코프 안에서
# 들여쓴 미체크 항목도 세므로 total=2 unchecked=1 → 게이트 미발동 → 정상 재개.
: > "$CALLS"
INDENT_HANDOFF=$(bash "$WFL" init --job indentjob --cwd "$FAKE_CWD" --summary "들여쓰기 테스트" --session "$SESSION" --goal "g" --done-when "d")
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "- [x] 1. 상위 완료\n  - [ ] 1a. 미완");
fs.writeFileSync(p, s);
' "$INDENT_HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$INDENT_HANDOFF" --job indentjob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  INDENTST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/indentjob/reservation.json')).status)")
  [ "$INDENTST" = "done" ] && break
  sleep 1
done
[ "$INDENTST" = "done" ] && ok "들여쓴 미체크 하위 항목이 있으면 게이트 미발동, 정상 재개" || fail "들여쓴 미체크 항목에서 — $(poll_diag "$INDENTST" done) (기대와 다르면 게이트 오발동 의심)"
grep -q -- "--permission-mode" "$CALLS" && ok "재개 호출이 실제로 실행됨" || fail "재개 호출 누락: $(cat "$CALLS" 2>/dev/null)"

section "ledger 게이트: 하이픈이 아닌 불릿의 미체크 항목도 남은 단계로 센다 (불릿 표기 회귀)"
# 원장의 단계 절을 편집하는 건 스크립트가 아니라 재개 LLM 이라(재개 프롬프트가 "원장의
# 단계 체크박스를 갱신하고" 라고 지시한다), 마크다운에서 합법인 '* [ ]' 나 불릿 뒤 공백이
# 없는 '-[ ]' 가 섞여 들어올 여지가 실재한다. 이 표기들은 remaining 의 '^- ' 앵커에도,
# 처음 구현한 '^[[:space:]]*-[[:space:]]\[' 패턴에도 안 걸려서 나머지가 전부 '- [x]' 이면
# 게이트가 오발동했다(실측 확인) — 남은 작업이 조용히 버려지는 가장 위험한 방향이다.
: > "$CALLS"
BULLET_HANDOFF=$(bash "$WFL" init --job bulletjob --cwd "$FAKE_CWD" --summary "불릿 표기 테스트" --session "$SESSION" --goal "g" --done-when "d")
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "- [x] 1. 상위 완료\n* [ ] 2. 별표 불릿 미완\n-[ ] 3. 공백 없는 미완");
fs.writeFileSync(p, s);
' "$BULLET_HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$BULLET_HANDOFF" --job bulletjob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  BULLETST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/bulletjob/reservation.json')).status)")
  [ "$BULLETST" = "done" ] && break
  sleep 1
done
[ "$BULLETST" = "done" ] && ok "비하이픈·공백없는 불릿의 미체크 항목도 세어 게이트 미발동" || fail "비하이픈 불릿에서 — $(poll_diag "$BULLETST" done) (기대와 다르면 게이트 오발동)"
grep -q -- "--permission-mode" "$CALLS" && ok "재개 호출이 실제로 실행됨" || fail "재개 호출 누락: $(cat "$CALLS" 2>/dev/null)"

section "ledger 게이트: '## 단계' 절 밖(예: 재개 결과)의 체크박스는 판정에 섞이지 않는다 (절 스코프 판정 회귀)"
# 위와 같이 "파일 전체를 보는 판정"을 판별하는 단언이다(게이트가 없던 코드에서는
# 통과한다). '## 단계' 절엔 체크박스가
# 하나도 없는데(=원래는 판정 불가여야 함) 파일 전체 존재 확인이 '## 재개 결과' 의
# '- [x] 끝' 을 보고 통과하고, '## 단계' 에 미체크 항목이 없으니 remaining 도 비어
# 게이트가 잘못 발동했다(오발동 1번). 지금은 '## 단계' 절만 스코프하므로 그 절 안엔
# 체크박스가 없어 total=0 → 판정 불가 → 안전한 방향(재개 진행)으로 넘어간다.
: > "$CALLS"
OUTSIDE_HANDOFF=$(bash "$WFL" init --job outsidejob --cwd "$FAKE_CWD" --summary "절 밖 체크박스 테스트" --session "$SESSION" --goal "g" --done-when "d")
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "(단계는 아직 안 적었다 — 체크박스 없음)");
s += "\n## 재개 결과\n- [x] 끝\n";
fs.writeFileSync(p, s);
' "$OUTSIDE_HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$OUTSIDE_HANDOFF" --job outsidejob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  OUTSIDEST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/outsidejob/reservation.json')).status)")
  [ "$OUTSIDEST" = "done" ] && break
  sleep 1
done
[ "$OUTSIDEST" = "done" ] && ok "'## 단계' 절 밖의 체크박스는 무시되고 판정 불가로 정상 재개" || fail "절 밖 체크박스에서 — $(poll_diag "$OUTSIDEST" done) (기대와 다르면 게이트 오발동 의심)"
grep -q -- "--permission-mode" "$CALLS" && ok "재개 호출이 실제로 실행됨" || fail "재개 호출 누락: $(cat "$CALLS" 2>/dev/null)"

section "mode=resume: 기존 계약(--resume <SESSION>) 유지"
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job resumejob > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/resumejob/reservation.json')).status)")
  [ "$STATUS" = "done" ] && break
  sleep 1
done
grep -q -- "--resume $SESSION" "$CALLS" && ok "resume 모드는 --resume 유지" || fail "resume 계약 깨짐 — resumejob $(poll_diag "$STATUS" done): $(cat "$CALLS" 2>/dev/null)"

section "DONE_NOTE: reserve(체인 없음) 로 건 재개 프롬프트에도 done 안내가 실린다 (수정 A 회귀)"
# 바로 위 resumejob 은 reserve(체인 필드 자체가 없음)로 걸려 이미 재개까지 완주했다 —
# CHAIN_NOTE 안에서만 done 안내가 나가던 예전 코드라면 이 경로엔 안내가 전혀 없었다.
grep -qF -- "freeze.sh done --handoff" "$CALLS" && ok "reserve(체인 없음) 프롬프트에 done 안내 포함" || fail "done 안내 누락: $(cat "$CALLS" 2>/dev/null)"

section "DONE_NOTE: ledger 모드 프롬프트에도 done 안내가 실린다 (수정 A 회귀)"
: > "$CALLS"
LEDGER_DONE_HANDOFF=$(bash "$WFL" init --job ledgerdonejob --cwd "$FAKE_CWD" --summary "done 안내 확인" --session "$SESSION" --goal "g" --done-when "d")
bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$LEDGER_DONE_HANDOFF" --job ledgerdonejob --mode ledger > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  LDONEST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/ledgerdonejob/reservation.json')).status)")
  [ "$LDONEST" = "done" ] && break
  sleep 1
done
[ "$LDONEST" = "done" ] && ok "ledgerdonejob 완주" || fail "ledgerdonejob 완주 실패 — $(poll_diag "$LDONEST" done)"
grep -qF -- "freeze.sh done --handoff" "$CALLS" && ok "ledger 모드 프롬프트에 done 안내 포함" || fail "ledger 모드 done 안내 누락: $(cat "$CALLS" 2>/dev/null)"

section "완료 마커는 job 단위로 격리된다 (다른 job 의 신호를 arm 이 지우지 않는다)"
# 회귀 재현: 같은 handoff 를 우연히 공유하는 서로 무관한 두 job. 예전 코드는
# cmd_arm 이 handoff 경로 기준 마커를 무조건 rm 해서, 먼저 끝난 세션의 신호가
# 뒤이은 무관한 세션의 arm 에 지워졌다(freeze.sh:271 재현 — 위 리뷰 기록 참고).
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job isoA > /dev/null
# 여기선 isoA(frozen)가 대상이므로 done 은 rc=0 이어야 한다 — 그 계약을 아래 마커
# 단언에 함께 접어 넣는다(rc 를 그냥 흘리면 비영 종료가 set -e 로 스위트를 끊는다).
ISOA_DONE_RC=0; bash "$FZ" done --handoff "$HANDOFF" > /dev/null || ISOA_DONE_RC=$?
{ [ "$ISOA_DONE_RC" = 0 ] && [ -f "$FREEZE_STATE_DIR/isoA/done" ]; } && ok "isoA 완료 마커 기록됨" || fail "isoA 마커 기록 실패 (done rc=$ISOA_DONE_RC)"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job isoB --chain-left 1 --at +1h > /dev/null
[ -f "$FREEZE_STATE_DIR/isoA/done" ] && ok "무관한 job(isoB) 의 arm 이 isoA 마커를 건드리지 않음" || fail "격리 실패 — isoA 마커가 지워짐"
bash "$FZ" cancel isoA > /dev/null 2>&1 || true
bash "$FZ" cancel isoB > /dev/null 2>&1 || true

section "status: 체인 선무장 실패 경고가 눈에 띄게 나온다"
echo "# h" > "$HANDOFF"
bash "$FZ" reserve --at +1h --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job warnjob > /dev/null
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/warnjob/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.chain_warning='다음 창 선무장 실패 — 체인이 끊겼다';
fs.writeFileSync(p, JSON.stringify(d,null,2));"
# 여기도 파이프를 걷었다 — 그리고 이 자리는 위 usage 쌍보다 위험했다. cmd_status 는 예약
# 하나당 printf 를 따로 부르고(그 사이사이 job_field 가 node 를 fork 한다) 각 printf 가
# 곧바로 flush 되므로, "일치하는 줄 뒤에도 쓰기가 남아 있으면" grep -q 가 먼저 exit 해
# 남은 printf 가 EPIPE 를 맞는다. 실측: 그런 모양의 프로듀서는 512바이트에서도 200회 중
# 187회(93%) rc=141 이었다 — 페이로드 크기와 무관하다.
# (예전 이 주석은 괄호 안에 "bash 내장 echo 는 한 번의 write 라 64KB 아래에서 노출이 0" 이라고
# 덧붙였다. 그 부분은 폐기했다 — 위 usage 섹션 주석의 실측대로 내장 echo 도 여러 줄이면
# write 를 여러 번 하고, 166바이트가 65536 버퍼에서 45/20000 터졌다(10병렬·무압력
# 조건 — usage 섹션의 조건표 참고). 노출률만 낮고
# 구조는 같다.)
#
# 지금까지 이 단언이 초록이던 이유는 코드가 안전해서가 아니라 **알파벳 순서 운**이다:
# 글롭이 job 디렉토리를 사전순으로 훑고 warnjob('w')이 이 시점 마지막 job 이라, 경고 줄
# 뒤에 쓰기가 남지 않았다. 'w' 뒤로 정렬되는 job 이름(z...)을 이 섹션 앞에 하나만
# 추가하면 이 단언은 내용과 무관하게 거의 100% 빨개진다. 그 함정을 없앤다.
# 패턴이 고정 문자열이라 case 글롭은 grep -q 와 등가다.
# rc 를 따로 받아 단언에 접어 넣는다 — 파이프를 걷으면서 이 대입이 `&&/||` 문맥 밖으로
# 나왔으므로, 그냥 두면 status 가 비영 종료하는 날 set -e 가 단언 대신 스위트를 끊는다.
# (cmd_status 는 지금 명시적으로 return 0 이지만, 그 계약이 바뀌어도 여긴 FAIL 로 보고해야
# 한다.) 파일의 다른 곳(ISOA_DONE_RC / BROKEN_RC)과 같은 관용구다.
STATUS_OUT=$(bash "$FZ" status) && STATUS_RC=0 || STATUS_RC=$?
case "$STATUS_OUT" in
  *"경고: 다음 창 선무장 실패"*)
    [ "$STATUS_RC" = 0 ] && ok "status 가 chain_warning 을 노출" || fail "경고는 나왔지만 status 가 비영 종료 (rc=$STATUS_RC)";;
  *) fail "status 에 경고 미노출 (rc=$STATUS_RC): $STATUS_OUT";;
esac
bash "$FZ" cancel warnjob > /dev/null

section "체인: 선무장이 실제 재개 호출 '전에' 끝난다 (순서 단언)"
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB=orderjob
# 이 env var 는 arm 이 만드는 백그라운드 슬리퍼(thaw.sh)의 fork 시점에 이미
# 심어져 있어야 그 프로세스가 물려받는다 — arm 을 부르기 "전에" export 해야 한다.
export MOCK_EXPECT_FILE="$FREEZE_STATE_DIR/${CHAINJOB}-c0/reservation.json"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$CHAINJOB" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
unset MOCK_EXPECT_FILE
[ "$ST" = "done" ] && ok "orderjob 완주" || fail "orderjob 완주 실패 — $(poll_diag "$ST" done)"
[ -f "$FREEZE_STATE_DIR/${CHAINJOB}-c0/reservation.json" ] && ok "다음 창 선무장 확인" || fail "선무장 안됨"
grep -q "MOCK_EXPECT_FILE=present" "$CALLS" && ok "재개 호출 시점에 이미 다음 창 예약 파일이 존재함(선무장이 먼저 끝남)" || fail "순서 위반 — 재개 호출 시점에 다음 창 예약이 아직 없었다: $(grep MOCK_EXPECT_FILE "$CALLS" || echo 없음)"
bash "$FZ" cancel "${CHAINJOB}-c0" > /dev/null 2>&1 || true

section "체인: 프로브가 실제 CLI 처럼 자기 transcript 를 남겨도 선무장 세션이 오염되지 않는다"
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB2=sessisojob
export MOCK_MAKE_TRANSCRIPT_DIR="$PROJ"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$CHAINJOB2" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB2/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
unset MOCK_MAKE_TRANSCRIPT_DIR
[ "$ST" = "done" ] && ok "sessisojob 완주" || fail "sessisojob 완주 실패 — $(poll_diag "$ST" done)"
NEXTSESS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${CHAINJOB2}-c0/reservation.json')).session_id)")
[ "$NEXTSESS" = "$SESSION" ] && ok "선무장된 다음 창의 session_id 가 원래 세션과 일치 ($NEXTSESS)" || fail "선무장 세션이 프로브로 오염됨: got=$NEXTSESS want=$SESSION"
bash "$FZ" cancel "${CHAINJOB2}-c0" > /dev/null 2>&1 || true

section "체인: 원래 예약의 pad 가 다음 창에도 그대로 전달된다"
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
for i in $(seq 1 "$POLL_TRIES"); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB3/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
[ "$ST" = "done" ] && ok "padchainjob 완주" || fail "padchainjob 완주 실패 — $(poll_diag "$ST" done)"
NEXTPAD=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${CHAINJOB3}-c0/reservation.json')).pad)")
[ "$NEXTPAD" = "777" ] && ok "선무장된 다음 창이 pad 를 물려받음 ($NEXTPAD)" || fail "pad 유실: got=$NEXTPAD want=777"
bash "$FZ" cancel "${CHAINJOB3}-c0" > /dev/null 2>&1 || true

section "체인: 리셋 경계에서 auto 추정이 UNKNOWN 이어도 선무장은 끊기지 않는다 (--at auto 미사용 확인)"
# 옛 코드는 thaw 가 chain 재무장 때 'freeze.sh arm --at auto'(기본값)를 그대로 썼다 —
# 그러면 이 순간 cmd_estimate 가 UNKNOWN 을 내는 환경에서 선무장이 그대로 죽는다.
# CLAUDE_PROJECTS_DIR 을 통째로 비워 auto 추정이 반드시 실패하게 만든 뒤에도
# 체인이 끊기지 않아야 새 코드가 --at 을 명시 epoch 로 넘긴다는 게 증명된다.
: > "$CALLS"; echo "# h" > "$HANDOFF"
CHAINJOB4=boundaryjob
EMPTY_PROJ="$TMP/empty_projects_boundary"; mkdir -p "$EMPTY_PROJ"
CLAUDE_PROJECTS_DIR="$EMPTY_PROJ" bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" \
  --job "$CHAINJOB4" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  ST=$(CLAUDE_PROJECTS_DIR="$EMPTY_PROJ" node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB4/reservation.json')).status)")
  [ "$ST" = "done" ] && break
  sleep 1
done
[ "$ST" = "done" ] && ok "boundaryjob 완주(auto 추정이 죽는 환경에서도)" || fail "boundaryjob 완주 실패 — $(poll_diag "$ST" done)"
[ -f "$FREEZE_STATE_DIR/${CHAINJOB4}-c0/reservation.json" ] && ok "estimate=UNKNOWN 환경에서도 선무장 성공 (--at auto 를 안 씀)" || fail "선무장 실패 — 여전히 --at auto 에 의존 중"
WARN4=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$CHAINJOB4/reservation.json')).chain_warning ?? '')")
[ -z "$WARN4" ] && ok "chain_warning 없음(성공)" || fail "예상 밖 chain_warning: $WARN4"
bash "$FZ" cancel "${CHAINJOB4}-c0" > /dev/null 2>&1 || true

section "체인: 프로브 구간에 도착한 완료 신호는 재개를 생략시킨다 (이중 재개 방지)"
# 재현: haiku 프로브가 실행되는 바로 그 순간(프로브 루프의 매 시도 시작 '전' 체크는
# 통과한 뒤) 실제 작업 세션이 done 을 부른 상황. 예전 코드는 (a) 완료 마커가
# handoff 경로 기준이라 곧이어 선무장이 지웠고, (b) 설령 마커가 남아도 재개를
# 부르기 전에 다시 확인하는 코드 자체가 없어 이미 끝난 작업을 --resume 으로
# 통째로 다시 열었다(thaw.sh:79-81 주석이 "불가능"이라 단언한 이중 재개).
: > "$CALLS"; echo "# h" > "$HANDOFF"
PROBEJOB=probesignaljob
export MOCK_DONE_MARK="$FREEZE_STATE_DIR/$PROBEJOB/done"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job "$PROBEJOB" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$PROBEJOB/reservation.json')).status)" 2>/dev/null || echo "")
  { [ "$ST" = "completed_early" ] || [ "$ST" = "done" ]; } && break
  sleep 1
done
unset MOCK_DONE_MARK
[ "$ST" = "completed_early" ] && ok "프로브 구간 완료 신호 → completed_early (재개 안 함)" || fail "프로브 구간 완료 신호가 재개를 생략시키지 못했다 — $(poll_diag "$ST" completed_early)"
grep -q -- "--resume" "$CALLS" && fail "완료된 작업인데 --resume 이 호출됐다(이중 재개)" || ok "이중 재개 없음 — --resume 미호출"
# 위 폴링은 부모의 status 가 completed_early 가 되는 순간 break 한다 — 그 순간 자식은
# 이미 해제돼 있어야 한다. thaw.sh 가 다음 창 cancel 을 부모 status 전환보다 **먼저**
# 하도록 고쳤기 때문이다(thaw.sh:release_next_job 주석). 그래서 여기엔 대기가 없다.
#
# 예전엔 순서가 반대여서(status 먼저, cancel 나중) "부모는 completed_early 인데 자식은
# 아직 frozen" 인 창이 관측 가능하게 열렸고, 이 자리에 "부모 thaw 프로세스가 죽기를
# 기다리는" 12줄이 우회로 들어가 있었다. 우회를 지운 건 의도적이다 — 대기가 다시
# 필요해졌다면 그건 순서 불변식이 깨졌다는 신호이므로, 대기를 넣지 말고 thaw.sh 를 봐라.
#
# 다만 아래 단언 자체는 그 순서 불변식의 게이트가 못 된다 — 순서를 예전으로 되돌린
# 변이로 스위트를 부하 하 8회 돌려 1회(12.5%)만 빨개졌다. 게이트는 바로 다음 두
# 섹션이 맡는다(상태 폴링이 아니라 두 쓰기의 node 호출 순서를 직접 관측한다).
NEXTST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/${PROBEJOB}-c0/reservation.json')).status)" 2>/dev/null || echo MISSING)
[ "$NEXTST" = "cancelled" ] && ok "선무장돼 있던 다음 창도 함께 해제됨 (cancelled)" || fail "다음 창이 해제되지 않음: $NEXTST"

section "체인: 다음 창 cancel 이 부모 status 전환보다 먼저 일어난다 (순서 불변식 결정적 게이트)"
# 지키려는 불변식: "부모가 완료(completed_early / done)로 보이면 선무장된 자식은 이미
# 해제돼 있다"(thaw.sh:release_next_job 주석). 위 섹션처럼 상태를 폴링해 "중간 상태를
# 목격"하는 방식은 이 불변식의 게이트로 쓸 수 없다 — 순서를 되돌린 변이에서 재현율이
# 12.5% 였다(폴링 간격 1초 안에 cancel 이 대개 먼저 끝나버린다). 확률 게이트는 이빨이 없다.
#
# 그래서 목격을 포기하고 순서를 직접 관측한다. 두 쓰기 모두 node 를 거친다 —
# 자식 cancel 은 freeze.sh:cmd_cancel 의 `d.status = "cancelled"` 쓰기, 부모 전환은
# thaw.sh:set_status 의 `d.status = s` 쓰기. FREEZE_NODE_BIN 래퍼(아래 _node.sh
# NODE_WRAP3 계열과 같은 기법 — 슬리퍼가 이 값을 물려받는다는 건 그 섹션이 단언한다)로
# 그 두 호출만 한 줄씩 남기면 로그의 줄 순서가 곧 실행 순서다. 두 호출은 같은
# 프로세스에서 동기적으로 차례로 일어나므로(thaw 는 `bash freeze.sh cancel` 이 반환할
# 때까지 블록한다) 레이스가 없다 — 순서를 되돌린 변이에서 20/20 빨개진다.
ORDER_LOG="$TMP/cancel-order.log"
ORDER_WRAP="$TMP/cancel-order-node.sh"
: > "$ORDER_LOG"
# $FREEZE_NODE_BIN 을 쓴다(command -v node 대신) — 이 스크립트가 _node.sh 를 source 해
# `node` 는 함수이고, command -v 는 실행파일 경로가 아니라 함수 이름을 돌려준다.
cat > "$ORDER_WRAP" <<ORDEREOF
#!/usr/bin/env bash
# node -e <스크립트> <인자...> 중 reservation.json 의 status 를 쓰는 두 종류만 짧은 한
# 줄로 남긴다. 짧게 유지하는 게 중요하다 — 부모·자식 슬리퍼가 같은 파일에 append 하므로
# 긴 줄은 서로 섞일 수 있다(짧은 한 줄 write 는 O_APPEND 로 원자적이다).
# 패턴이 스크립트 본문을 물고 있는 건 의도적이다: 호출 지점의 JS 를 고쳐 패턴이 안
# 맞게 되면 해당 줄이 사라져 아래 단언이 "관측 장치가 깨졌다"로 빨개진다(fail-closed).
if [ "\${1:-}" = "-e" ]; then
  case "\${2:-}" in
    *'d.status = "cancelled"'*) echo "CANCEL \${*:3}" >> "$ORDER_LOG";;
    *'d.status = s;'*)          echo "STATUS \${*:3}" >> "$ORDER_LOG";;
  esac
fi
exec "$FREEZE_NODE_BIN" "\$@"
ORDEREOF
chmod +x "$ORDER_WRAP"

: > "$CALLS"; echo "# h" > "$HANDOFF"
ORDERJOB=cancelorderjob
export MOCK_DONE_MARK="$FREEZE_STATE_DIR/$ORDERJOB/done"
FREEZE_NODE_BIN="$ORDER_WRAP" bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" \
  --job "$ORDERJOB" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  OST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$ORDERJOB/reservation.json')).status)" 2>/dev/null || echo "")
  { [ "$OST" = "completed_early" ] || [ "$OST" = "done" ]; } && break
  sleep 1
done
unset MOCK_DONE_MARK
[ "$OST" = "completed_early" ] && ok "전제: 프로브 구간 완료 신호로 부모가 completed_early 에 도달" || fail "전제 불성립 — $(poll_diag "$OST" completed_early)"
ORDER_CANCEL_LN=$(grep -nF "CANCEL $FREEZE_STATE_DIR/${ORDERJOB}-c0/reservation.json" "$ORDER_LOG" | head -1 | cut -d: -f1 || true)
ORDER_STATUS_LN=$(grep -nF "STATUS $FREEZE_STATE_DIR/$ORDERJOB/reservation.json completed_early" "$ORDER_LOG" | head -1 | cut -d: -f1 || true)
if [ -z "$ORDER_CANCEL_LN" ]; then
  fail "자식 cancel 의 node 쓰기가 로그에 없다 — cancel 이 아예 안 불렸거나 관측 장치가 깨졌다: [$(tr '\n' '|' < "$ORDER_LOG")]"
elif [ -z "$ORDER_STATUS_LN" ]; then
  fail "부모 completed_early 쓰기가 로그에 없다 — 관측 장치가 깨졌다(set_status 의 JS 를 고쳤나?): [$(tr '\n' '|' < "$ORDER_LOG")]"
elif [ "$ORDER_CANCEL_LN" -lt "$ORDER_STATUS_LN" ]; then
  ok "자식 cancel 쓰기(${ORDER_CANCEL_LN}행)가 부모 completed_early 쓰기(${ORDER_STATUS_LN}행)보다 먼저 — 순서 불변식 성립"
else
  fail "순서 위반 — 부모 status 전환(${ORDER_STATUS_LN}행)이 자식 cancel(${ORDER_CANCEL_LN}행)보다 먼저다. '부모가 완료로 보이면 자식은 이미 해제됨' 이 깨졌다(thaw.sh:release_next_job 주석)"
fi
bash "$FZ" cancel "${ORDERJOB}-c0" > /dev/null 2>&1 || true

section "체인: 재개를 끝낸 뒤 분기에서도 cancel 이 부모 status 전환보다 먼저다 (같은 불변식, 다른 호출 지점)"
# 위 섹션이 잡는 건 프로브 구간 분기(is_done_signaled → release_next_job → completed_early).
# release_next_job 호출 지점은 셋이고, 재개가 실제로 끝난 뒤의 마지막 지점
# (`is_done_signaled && release_next_job` → set_status done)도 같은 불변식을 주장한다
# (thaw.sh 주석: "원래도 그랬다 ... 한 가지 규칙으로 읽히게"). 그 주장도 게이트가 필요하다 —
# 여기만 순서를 뒤집는 변이는 위 섹션이 못 잡는다.
# 재현: 재개 호출 도중에 재개 세션이 done 을 부른 상황(MOCK_DONE_MARK_ON_RESUME).
ORDER_LOG2="$TMP/cancel-order2.log"
ORDER_WRAP2="$TMP/cancel-order2-node.sh"
: > "$ORDER_LOG2"
sed "s#$ORDER_LOG#$ORDER_LOG2#g" "$ORDER_WRAP" > "$ORDER_WRAP2"
chmod +x "$ORDER_WRAP2"

: > "$CALLS"; echo "# h" > "$HANDOFF"
ORDERJOB2=cancelorder2job
export MOCK_DONE_MARK_ON_RESUME="$FREEZE_STATE_DIR/$ORDERJOB2/done"
FREEZE_NODE_BIN="$ORDER_WRAP2" bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" \
  --job "$ORDERJOB2" --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  OST2=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$ORDERJOB2/reservation.json')).status)" 2>/dev/null || echo "")
  { [ "$OST2" = "done" ] || [ "$OST2" = "failed" ] || [ "$OST2" = "completed_early" ]; } && break
  sleep 1
done
unset MOCK_DONE_MARK_ON_RESUME
[ "$OST2" = "done" ] && ok "전제: 재개를 실제로 실행하고 부모가 done 에 도달" || fail "전제 불성립 — $(poll_diag "$OST2" done)"
grep -q -- "--resume $SESSION" "$CALLS" && ok "전제: 재개가 호출됨(이 분기는 재개 이후여야 의미가 있다)" || fail "전제 불성립 — 재개 미호출: $(cat "$CALLS" 2>/dev/null)"
ORDER2_CANCEL_LN=$(grep -nF "CANCEL $FREEZE_STATE_DIR/${ORDERJOB2}-c0/reservation.json" "$ORDER_LOG2" | head -1 | cut -d: -f1 || true)
ORDER2_DONE_LN=$(grep -nF "STATUS $FREEZE_STATE_DIR/$ORDERJOB2/reservation.json done" "$ORDER_LOG2" | head -1 | cut -d: -f1 || true)
if [ -z "$ORDER2_CANCEL_LN" ]; then
  fail "자식 cancel 의 node 쓰기가 로그에 없다 — 재개 후 완료 신호를 보고도 자식을 해제하지 않았다: [$(tr '\n' '|' < "$ORDER_LOG2")]"
elif [ -z "$ORDER2_DONE_LN" ]; then
  fail "부모 done 쓰기가 로그에 없다 — 관측 장치가 깨졌다: [$(tr '\n' '|' < "$ORDER_LOG2")]"
elif [ "$ORDER2_CANCEL_LN" -lt "$ORDER2_DONE_LN" ]; then
  ok "자식 cancel 쓰기(${ORDER2_CANCEL_LN}행)가 부모 done 쓰기(${ORDER2_DONE_LN}행)보다 먼저 — 재개 이후 분기에서도 불변식 성립"
else
  fail "순서 위반 — 부모 done 전환(${ORDER2_DONE_LN}행)이 자식 cancel(${ORDER2_CANCEL_LN}행)보다 먼저다(thaw.sh 의 마지막 release_next_job 호출 지점)"
fi
bash "$FZ" cancel "${ORDERJOB2}-c0" > /dev/null 2>&1 || true

section "체인: ledger 완료 게이트 분기에서도 cancel 이 부모 status 전환보다 먼저다 (세 번째 호출 지점, 결정적 게이트)"
# release_next_job 호출 지점은 셋인데 위 두 섹션이 잡는 건 둘이다 — 프로브 구간 완료 신호
# 분기와 재개 이후 분기. 남은 하나(ledger 완료 게이트 분기)는 무보호였다: 그 분기만
# 순서를 되돌린 변이가 스위트 20회 중 0회 잡혔다.
#
# 이유는 재현율이 낮아서가 아니라 **어떤 테스트도 그 분기에 자식이 있는 상태로 도달하지
# 않았기 때문**이다. 유일한 ledger 게이트 테스트(위 "ledger 게이트 발동" 섹션)가 arm 이
# 아니라 reserve 로 예약을 건다 → reservation 에 chain 필드가 없어 CHAIN≠1 → thaw 의 체인
# 블록을 건너뛰어 NEXT_JOB 이 빈 문자열 → release_next_job 은 첫 줄
# `[ -n "$NEXT_JOB" ] || return 0` 에서 그냥 돌아온다. 취소할 자식이 애초에 없으니 순서를
# 뒤집어도 관측되는 차이가 없다. 확률 문제가 아니라 도달 문제였다.
#
# 그래서 여기서는 자식이 실재하는 상태로 게이트를 발동시킨다. 도달 조건 셋을 모두 세워야
# 이 분기에 닿고, 셋 중 하나라도 어긋나면 이 섹션은 조용히 아무것도 검증하지 않게 되므로
# 전제를 각각 단언으로 고정해 뒀다(전제가 깨지면 초록으로 지나가지 않고 빨개진다):
#   (1) MODE=ledger + CHAIN=1 + CHAIN_LEFT>0  → arm --mode ledger --chain-left 1
#   (2) 앞선 완료 신호 분기가 먼저 낚아채지 않아야 한다 → done 을 부르지 않고, handoff 도
#       이 섹션 전용 새 경로를 쓴다. handoff 마커는 설계상 지워지지 않으므로(freeze.sh:
#       cmd_done) 다른 섹션이 done 을 부른 handoff 를 재사용하면 그 옛 신호에 걸려 게이트
#       분기에 닿기 전에 completed_early 가 되고, 관측 대상이 조용히 바뀐다.
#   (3) ledger_complete 가 참 → '## 단계' 절의 유일한 항목을 mark 로 체크
# 관측 방식은 위 두 섹션과 같다 — 상태 폴링(=중간 상태 목격)이 아니라 FREEZE_NODE_BIN
# 래퍼로 cancel·set_status 두 node 쓰기의 호출 순서를 직접 본다. 두 쓰기는 같은
# 프로세스에서 동기적으로 차례로 일어나므로 레이스가 없다.
ORDER_LOG3="$TMP/cancel-order3.log"
ORDER_WRAP3="$TMP/cancel-order3-node.sh"
: > "$ORDER_LOG3"
sed "s#$ORDER_LOG#$ORDER_LOG3#g" "$ORDER_WRAP" > "$ORDER_WRAP3"
chmod +x "$ORDER_WRAP3"

: > "$CALLS"
ORDERJOB3=ledgergateorderjob
LGATE_HANDOFF=$(bash "$WFL" init --job "$ORDERJOB3" --cwd "$FAKE_CWD" --summary "ledger 게이트 순서 테스트" --session "$SESSION" --goal "g" --done-when "d")
node -e '
const fs = require("fs");
const p = process.argv[1];
let s = fs.readFileSync(p, "utf8");
s = s.replace("- [ ] 1. (여기 채워라)", "- [ ] 1. 유일한 단계");
fs.writeFileSync(p, s);
' "$LGATE_HANDOFF"
bash "$WFL" mark --ledger "$LGATE_HANDOFF" --step 1 > /dev/null
# 전제 (3): 이 원장이 정말 "남은 단계 0" 인가. 아니면 게이트가 안 걸려 부모가 재개까지
# 가고, 그러면 아래 순서 단언은 게이트 분기가 아니라 재개 이후 분기를 보게 된다.
LGATE_REM=$(bash "$WFL" remaining --ledger "$LGATE_HANDOFF") && LGATE_REM_RC=0 || LGATE_REM_RC=$?
{ [ "$LGATE_REM_RC" = 0 ] && [ -z "$LGATE_REM" ]; } && ok "전제(3): 원장에 남은 단계 0 — remaining 이 빈 출력 + rc=0" || fail "전제(3) 불성립 — remaining rc=$LGATE_REM_RC out=[$LGATE_REM]"
FREEZE_NODE_BIN="$ORDER_WRAP3" bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$LGATE_HANDOFF" \
  --job "$ORDERJOB3" --chain-left 1 --mode ledger --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  OST3=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/$ORDERJOB3/reservation.json')).status)" 2>/dev/null || echo "")
  { [ "$OST3" = "completed_early" ] || [ "$OST3" = "done" ] || [ "$OST3" = "failed" ]; } && break
  sleep 1
done
[ "$OST3" = "completed_early" ] && ok "전제: 부모가 completed_early 에 도달(게이트 발동)" || fail "전제 불성립 — $(poll_diag "$OST3" completed_early)"
# 전제 (2): 관측 대상이 정말 게이트 분기인가. 완료 마커가 있으면 그 앞의 완료 신호
# 분기가 먼저 낚아챘다는 뜻이라 같은 completed_early 라도 다른 코드 경로다.
[ -f "$FREEZE_STATE_DIR/$ORDERJOB3/done" ] && fail "전제(2) 불성립 — job 완료 마커가 있다. 게이트 분기가 아니라 완료 신호 분기를 관측 중이다" || ok "전제(2): 완료 마커 없음 — 관측 대상은 ledger 완료 게이트 분기다"
# 재개 호출의 고유 표지는 --permission-mode (haiku 프로브는 이 플래그를 안 쓴다).
grep -q -- "--permission-mode" "$CALLS" && fail "게이트가 발동했는데도 재개 호출이 실행됐다 — 게이트 분기가 아니다" || ok "재개 호출 없음 — 게이트 분기 확인"
# 전제 (1): 자식이 실재하는가. 없으면 release_next_job 이 첫 줄에서 return 0 해서
# 이 섹션은 아무 순서도 검증하지 않는다 — 지난 라운드가 이 분기를 못 잡은 바로 그 이유.
[ -f "$FREEZE_STATE_DIR/${ORDERJOB3}-c0/reservation.json" ] && ok "전제(1): 자식이 실재함(선무장 완료) — 취소할 대상이 있다" || fail "전제(1) 불성립 — 자식이 없다(NEXT_JOB 이 빈 문자열). 이 섹션은 아무것도 검증하지 못한다"
ORDER3_CANCEL_LN=$(grep -nF "CANCEL $FREEZE_STATE_DIR/${ORDERJOB3}-c0/reservation.json" "$ORDER_LOG3" | head -1 | cut -d: -f1 || true)
ORDER3_STATUS_LN=$(grep -nF "STATUS $FREEZE_STATE_DIR/$ORDERJOB3/reservation.json completed_early" "$ORDER_LOG3" | head -1 | cut -d: -f1 || true)
if [ -z "$ORDER3_CANCEL_LN" ]; then
  fail "자식 cancel 의 node 쓰기가 로그에 없다 — 게이트가 발동했는데 자식을 해제하지 않았거나 관측 장치가 깨졌다: [$(tr '\n' '|' < "$ORDER_LOG3")]"
elif [ -z "$ORDER3_STATUS_LN" ]; then
  fail "부모 completed_early 쓰기가 로그에 없다 — 관측 장치가 깨졌다(set_status 의 JS 를 고쳤나?): [$(tr '\n' '|' < "$ORDER_LOG3")]"
elif [ "$ORDER3_CANCEL_LN" -lt "$ORDER3_STATUS_LN" ]; then
  ok "자식 cancel 쓰기(${ORDER3_CANCEL_LN}행)가 부모 completed_early 쓰기(${ORDER3_STATUS_LN}행)보다 먼저 — ledger 게이트 분기에서도 불변식 성립"
else
  fail "순서 위반 — 부모 status 전환(${ORDER3_STATUS_LN}행)이 자식 cancel(${ORDER3_CANCEL_LN}행)보다 먼저다(thaw.sh 의 ledger 완료 게이트 분기)"
fi
bash "$FZ" cancel "${ORDERJOB3}-c0" > /dev/null 2>&1 || true

section "체인: handoff 로 키잉된 완료 신호는 job 마커를 못 받은 자식도 나중에 스스로 본다 (major 3 회귀)"
# 재현 경로: thaw 가 선무장(NEXT_JOB 생성) 직후~재확인 사이에서 죽으면, 그 job
# 마커는 done 호출 시점에 존재하던 예약에만 남으므로 NEXT_JOB 은 아무 마커도
# 못 받은 채 나중에 스스로 깨어나 이미 끝난 작업을 --resume 으로 다시 연다.
# 죽는 타이밍 자체를 흉내내는 대신(타이밍 레이스는 신뢰할 수 없다 — 실측으로도
# 프로세스 종료가 재확인보다 먼저 끝나는 경우가 드물었다), 그 죽음이 남기는
# "정확한 최종 상태" 를 직접 구성한다: 정상적으로 자식을 낳게 한 뒤, 자식의
# job 마커만 지워서 "job 마커는 없고 handoff 마커만 있다" 는 동일한 조건을 만든다.
: > "$CALLS"; echo "# h" > "$HANDOFF"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job m3chainjob --chain-left 1 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  M3ST=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob/reservation.json')).status)")
  [ "$M3ST" = "done" ] && break
  sleep 1
done
[ "$M3ST" = "done" ] && ok "부모(m3chainjob) 정상 완주" || fail "부모(m3chainjob) 완주 실패 — $(poll_diag "$M3ST" done)"
[ -f "$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json" ] && ok "자식(m3chainjob-c0) 선무장 확인" || fail "자식 선무장 실패"

PARENT_CREATED=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob/reservation.json')).created_at)")
CHILD_CREATED=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json')).created_at)")
[ "$PARENT_CREATED" = "$CHILD_CREATED" ] && ok "자식이 부모의 created_at 을 그대로 물려받음 ($CHILD_CREATED) — cmd_arm --created-at 전달 확인" || fail "created_at 상속 안됨: 부모=$PARENT_CREATED 자식=$CHILD_CREATED"

# 이제 완료 신호를 남긴다 — 부모는 이미 status=done 이라 매칭 안 되고, 자식(frozen)만
# job 마커를 받는다. 그 job 마커를 곧바로 지워서 "job 마커는 못 받았지만 handoff
# 마커는 남아있다"는 major 3 이 겨냥하는 조건을 정확히 재현한다.
#
# 이 done 호출의 종료코드는 이 섹션의 전제가 아니다 — 대상이 있을 수도, 없을 수도 있다.
# cmd_done 은 handoff 키잉 마커를 "활성 예약 매칭 여부와 무관하게 항상" 먼저 쓰고
# 그 다음에야 매칭 0건이면 return 1 을 낸다(freeze.sh:cmd_done). 이 섹션이 필요한 건
# 그 handoff 마커 하나뿐이고, job 마커는 어차피 바로 지운다. 그런데 이 자리는 원래
# 무보호였고, 실측 부하에서 "완료 신호 기록 대상 없음"으로 rc=1 이 나 set -e 가
# 스위트를 51개 섹션 중 37개에서 끊었다(출력은 ok 83개 FAIL 0개 — 정상 완주와 구분 불가).
# 그래서 rc 를 변수로 받아 흘리지 않고, 아래 전제 단언 메시지에 실어 눈에 보이게 한다.
# (done 이 rc=0 을 내야 하는 계약 자체는 isoA 섹션과 위 major 2 섹션이 단언한다.)
M3_DONE_RC=0; bash "$FZ" done --handoff "$HANDOFF" > /dev/null || M3_DONE_RC=$?
rm -f "$FREEZE_STATE_DIR/m3chainjob-c0/done"
[ -f "$FREEZE_STATE_DIR/m3chainjob-c0/done" ] && fail "job 마커 제거 실패(테스트 전제 오류)" || ok "job 마커 제거 — handoff 마커만 남은 상태 재현 (done rc=$M3_DONE_RC)"

# 자식을 즉시 캐치업시킨다(5시간 뒤 예약을 그대로 기다릴 수 없으므로 죽이고 당긴다).
CHILD_PID=$(cat "$FREEZE_STATE_DIR/m3chainjob-c0/sleeper.pid" 2>/dev/null || true)
[ -n "$CHILD_PID" ] && kill "$CHILD_PID" 2>/dev/null || true
node -e "
const fs=require('fs'), p='$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json';
const d=JSON.parse(fs.readFileSync(p)); d.resume_at=Math.floor(Date.now()/1000);
fs.writeFileSync(p, JSON.stringify(d,null,2));"
: > "$CALLS"
bash "$FZ" check > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  M3ST2=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3chainjob-c0/reservation.json')).status)")
  { [ "$M3ST2" = "completed_early" ] || [ "$M3ST2" = "done" ]; } && break
  sleep 1
done
[ "$M3ST2" = "completed_early" ] && ok "job 마커 없이도 handoff 신호만으로 재개 없이 종료 (major 3 수정 확인)" || fail "자식이 handoff 신호만으로 조기 종료하지 못했다 — $(poll_diag "$M3ST2" completed_early)"
grep -q -- "--resume" "$CALLS" && fail "job 마커 없이도 자식이 이중 재개를 실행함" || ok "이중 재개 없음 — --resume 미호출"

section "handoff 재사용: 완료 신호보다 나중에 시작한 새 예약은 옛 신호에 안 걸린다 (major 3 — created_at 필터 회귀)"
# 위에서 이미 이 handoff 로 done 신호가 남아있다. 초 단위 타임스탬프 충돌을
# 피하려고 1초 이상 벌린 뒤, 완전히 새로운(체인과 무관한) 예약을 건다 —
# 이 예약의 created_at 은 옛 신호보다 나중이므로 신호를 무시하고 정상 재개해야 한다.
sleep 1
: > "$CALLS"
bash "$FZ" arm --cwd "$FAKE_CWD" --handoff "$HANDOFF" --job m3freshjob --chain-left 0 --at +2s --session "$SESSION" > /dev/null
for i in $(seq 1 "$POLL_TRIES"); do
  M3ST3=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/m3freshjob/reservation.json')).status)")
  [ "$M3ST3" = "done" ] && break
  sleep 1
done
[ "$M3ST3" = "done" ] && ok "같은 handoff 를 재사용한 새 예약은 옛 신호와 무관하게 정상 재개함" || fail "새 예약이 정상 재개하지 못했다 — $(poll_diag "$M3ST3" done). 회귀라면 옛 신호에 잘못 걸린 것이다"
grep -q -- "--resume $SESSION" "$CALLS" && ok "새 예약이 실제로 재개를 실행함(옛 신호로 인한 오취소 없음)" || fail "새 예약이 재개를 못함: $(cat "$CALLS" 2>/dev/null)"

section "blocker: 읽을 수 없는 reservation.json 은 fail-closed — 즉시 재개하지 않고 비영 종료한다"
# 재현하는 결함: cmd_reserve 가 reservation.json 을 쓰고 슬리퍼를 띄운 뒤 cmd_arm 이
# 같은 파일에 두 번째 read-modify-write(chain/chain_left/via)를 했다. writeFileSync 는
# O_TRUNC 후 write 라 그 창이 관측 가능하게 열려 있고(프리미티브 측정: 171,167회 읽기 중
# 971회 = 0.57% JSON.parse 실패), 기동 직후 밀리초 안에 field() 로 resume_at 을 읽는
# thaw.sh 가 그 창에 걸렸다. 예전 field() 는 파싱 예외를 stderr 로만 흘리고 빈 문자열을
# 돌려줬고, 대기 루프가 빈 RESUME_AT 을 산술 확장에서 0 으로 보아 remain<=0 → 즉시 탈출
# → 5시간 뒤에 뜨기로 한 헤드리스 세션이 지금 떴다(사용자가 그 세션에서 일하는 중이고
# 쿼터도 지금 태운다).
#
# 레이스 타이밍을 흉내내는 대신(밀리초 창은 신뢰할 수 없다) 그 창에 걸린 읽기가 보는
# "정확한 파일 상태"를 직접 만든다: 정상 reservation.json 을 중간에서 잘라 깨진 JSON 으로
# 둔다. 예약 시각은 5시간 뒤이므로 정상 코드라면 어떤 경우에도 지금 재개해선 안 된다.
: > "$CALLS"
BROKEN_HANDOFF="$FAKE_CWD/broken-handoff.md"; echo "# broken" > "$BROKEN_HANDOFF"
bash "$FZ" reserve --at +5h --cwd "$FAKE_CWD" --handoff "$BROKEN_HANDOFF" --job brokenjob > /dev/null
BROKEN_PID=$(cat "$FREEZE_STATE_DIR/brokenjob/sleeper.pid")
kill "$BROKEN_PID" 2>/dev/null || true
for i in $(seq 1 20); do dup_alive "$BROKEN_PID" || break; sleep 0.2; done
BROKEN_RES="$FREEZE_STATE_DIR/brokenjob/reservation.json"
node -e '
const fs = require("fs"), p = process.argv[1];
const s = fs.readFileSync(p, "utf8");
fs.writeFileSync(p, s.slice(0, Math.floor(s.length / 2)));
' "$BROKEN_RES"
node -e 'JSON.parse(require("fs").readFileSync(process.argv[1]))' "$BROKEN_RES" 2>/dev/null \
  && fail "테스트 전제 오류 — 자른 파일이 여전히 유효한 JSON 이다" \
  || ok "전제 확인: reservation.json 이 깨진 JSON 상태"
BROKEN_OUT=$(bash "$HERE/../scripts/thaw.sh" brokenjob 2>&1) && BROKEN_RC=0 || BROKEN_RC=$?
[ "$BROKEN_RC" -ne 0 ] && ok "깨진 reservation.json 에 thaw 가 비영 종료 (rc=$BROKEN_RC)" || fail "thaw 가 rc=0 으로 통과함 — fail-open: $BROKEN_OUT"
grep -q -- "--resume" "$CALLS" && fail "깨진 JSON 인데 5시간 뒤 예약을 지금 재개했다(블로커 재현): $(cat "$CALLS")" || ok "즉시 재개 없음 — --resume 미호출"
grep -q -- "--model haiku" "$CALLS" && fail "깨진 JSON 인데 프로브까지 진행했다" || ok "프로브 전에 멈춤"
# "ERROR" 만 찾으면 node 가 뱉는 SyntaxError 스택으로도 통과해버린다(수정 전에도 초록이
# 되는 이빨 없는 단언). 이 스크립트가 스스로 판정해서 남긴 문구를 고정 문자열로 찾는다.
# 파이프를 쓰지 않는 이유는 위 usage 섹션 주석과 같다 — BROKEN_OUT 은 2>&1 로 node 의
# SyntaxError 스택까지 함께 받는 캡처라 크기가 예측되지 않는다(수백 바이트~수 KB).
# 고정 문자열이므로 case 글롭이 grep -qF 와 등가다. 되돌리지 마라.
case "$BROKEN_OUT" in
  *"즉시 재개하지 않고"*) ok "실패 이유와 판정(즉시 재개 안 함)이 로그에 남음";;
  *) fail "판정 로그 없음: $BROKEN_OUT";;
esac

section "blocker: resume_at 이 정수가 아니면 산술 확장에 맡기지 않고 죽는다"
# 위 결함이 "재앙"이 된 지점은 field() 의 빈 문자열이 $(( RESUME_AT - now )) 에서 조용히
# 0 으로 읽히는 것이었다. JSON 자체는 멀쩡하고 resume_at 만 비어 있는 상태로 그 판정
# 경로만 따로 고정한다 — 산술 확장이 아니라 명시적 정수 검사여야 통과한다.
: > "$CALLS"
NOAT_HANDOFF="$FAKE_CWD/noat-handoff.md"; echo "# noat" > "$NOAT_HANDOFF"
bash "$FZ" reserve --at +5h --cwd "$FAKE_CWD" --handoff "$NOAT_HANDOFF" --job noatjob > /dev/null
NOAT_PID=$(cat "$FREEZE_STATE_DIR/noatjob/sleeper.pid")
kill "$NOAT_PID" 2>/dev/null || true
for i in $(seq 1 20); do dup_alive "$NOAT_PID" || break; sleep 0.2; done
node -e '
const fs = require("fs"), p = process.argv[1];
const d = JSON.parse(fs.readFileSync(p)); d.resume_at = "";
fs.writeFileSync(p, JSON.stringify(d, null, 2));
' "$FREEZE_STATE_DIR/noatjob/reservation.json"
NOAT_OUT=$(bash "$HERE/../scripts/thaw.sh" noatjob 2>&1) && NOAT_RC=0 || NOAT_RC=$?
[ "$NOAT_RC" -ne 0 ] && ok "빈 resume_at 에 thaw 가 비영 종료 (rc=$NOAT_RC)" || fail "빈 resume_at 이 0 으로 읽혀 통과함: $NOAT_OUT"
grep -q -- "--resume" "$CALLS" && fail "빈 resume_at 을 0 으로 보고 지금 재개했다(블로커 재현)" || ok "즉시 재개 없음 — --resume 미호출"
# 일부러 깨뜨린 두 예약을 치운다. `status`/`check` 는 STATE_ROOT 의 모든
# reservation.json 을 훑고, 읽기 실패는 이제(설계대로) 비영 종료라 set -e 아래에서
# 스위트를 끊는다 — 뒤에 그런 섹션이 추가되면 이 픽스처가 그걸 오염시킨다.
rm -rf "$FREEZE_STATE_DIR/brokenjob" "$FREEZE_STATE_DIR/noatjob"

section "blocker: reservation.json 쓰기는 원자적이다 — 읽기와 겹쳐도 JSON.parse 실패 0"
# 두 번째 겹. 쓰기·읽기 루프를 같은 파일에 겹쳐 돌린다. 예전 writeFileSync(O_TRUNC 후
# write)는 이 루프에서 확실히 실패를 낸다(프리미티브 측정: 171,167회 중 971회 = 0.57%).
# renameSync 방식이면 읽는 쪽은 완전한 옛 내용이나 완전한 새 내용만 보므로 0 이어야 한다.
# 제품 상태 디렉토리를 어지럽히지 않도록 별도 파일에서 돌리되, 쓰기·읽기 모두
# _node.sh 의 공용 조각(FREEZE_JS_ATOMIC)을 그대로 쓴다 — 그게 곧 모든
# reservation.json 쓰기 경로다.
ATOMIC_DIR="$TMP/atomic"; mkdir -p "$ATOMIC_DIR"
ATOMIC_FILE="$ATOMIC_DIR/reservation.json"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({
  job: "atomicjob", resume_at: 1000000, status: "frozen", filler: "x".repeat(4096)
}, null, 2))' "$ATOMIC_FILE"
node -e "$FREEZE_JS_ATOMIC"'
const fs = require("fs"), p = process.argv[1], until = Date.now() + Number(process.argv[2]);
const d = JSON.parse(fs.readFileSync(p));
let n = 0;
while (Date.now() < until) { n++; d.status = "spin" + n; d.resume_at = 1000000 + n; writeJsonAtomic(p, d); }
console.log(n);
' "$ATOMIC_FILE" 2000 > "$TMP/atomic-writes.txt" &
ATOMIC_WPID=$!
node -e '
const fs = require("fs"), p = process.argv[1], until = Date.now() + Number(process.argv[2]);
let good = 0, bad = 0;
while (Date.now() < until) {
  try {
    const d = JSON.parse(fs.readFileSync(p));
    // 파싱만 통과하고 값이 깨진 경우(부분 쓰기)까지 잡는다 — thaw.sh 가 실제로 이 필드를
    // 정수로 신뢰하고 대기 시간을 계산한다.
    if (/^[0-9]+$/.test(String(d.resume_at))) good++; else bad++;
  } catch (e) { bad++; }
}
console.log(good + " " + bad);
' "$ATOMIC_FILE" 2000 > "$TMP/atomic-reads.txt"
wait "$ATOMIC_WPID" || true
read -r ATOMIC_GOOD ATOMIC_BAD < "$TMP/atomic-reads.txt"
ATOMIC_WRITES=$(cat "$TMP/atomic-writes.txt" 2>/dev/null || echo 0)
[ "${ATOMIC_WRITES:-0}" -ge 100 ] && ok "쓰기 루프가 실제로 돌았다 (${ATOMIC_WRITES}회) — 단언에 이빨이 있다" || fail "쓰기가 거의 안 일어남: ${ATOMIC_WRITES}회"
[ "${ATOMIC_GOOD:-0}" -ge 100 ] && ok "읽기 루프가 실제로 겹쳐 돌았다 (${ATOMIC_GOOD}회 정상 읽기)" || fail "읽기가 거의 안 일어남: ${ATOMIC_GOOD}회"
[ "${ATOMIC_BAD:-1}" = 0 ] && ok "동시 쓰기·읽기에서 잘린 JSON 을 한 번도 읽지 않음 (원자적)" || fail "잘린 JSON 을 ${ATOMIC_BAD}회 읽음 (정상 ${ATOMIC_GOOD}회) — 쓰기가 원자적이지 않다"
# field() 가 쓰는 공용 읽기 조각도 같은 조건에서 항상 유효값을 돌려줘야 한다.
FIELD_VAL=$(node -e "$FREEZE_JS_FIELD" "$ATOMIC_FILE" resume_at) && FIELD_RC=0 || FIELD_RC=$?
{ [ "$FIELD_RC" = 0 ] && [[ "$FIELD_VAL" =~ ^[0-9]+$ ]]; } && ok "공용 field 조각이 유효한 정수를 반환 ($FIELD_VAL)" || fail "field 조각 반환값 이상: rc=$FIELD_RC val='$FIELD_VAL'"

section "blocker: cmd_arm 은 reserve 뒤에 reservation.json 을 다시 쓰지 않는다 (레이스 원인 제거)"
# 첫 번째 겹이자 주 수정. 쓰기가 원자적이어도, arm 이 슬리퍼를 띄운 뒤에 같은 파일을
# 다시 여는 구조가 남아 있으면 누가 비원자적 쓰기를 되살릴 여지가 계속 남는다.
# 체인 필드는 reserve 의 단일 쓰기에 인자로 실려야 한다 — 그 구조를 소스에서 고정한다.
# (주석에도 writeFileSync 라는 글자가 들어있으므로 주석 줄은 먼저 걷어낸다.)
FREEZE_SRC="$HERE/../scripts/freeze.sh"
# grep -v 는 출력이 한 줄도 없으면 rc=1 이다(본문이 전부 주석인 경우). 여기서 끊기면
# 아래 소스 검사 단언들이 아예 안 돌므로, 빈 본문 판정도 그 단언들에 맡긴다.
ARM_BODY=$(awk '/^cmd_arm\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$FREEZE_SRC" | grep -v '^[[:space:]]*#' || true)
# 아래 두 단언은 파이프를 쓰지 않는다 — grep -q 가 첫 일치에서 파이프를 닫고 좌변
# echo 가 SIGPIPE(141)를 맞으면 pipefail 이 그걸 올려 단언이 내용과 무관하게
# 뒤집힌다(자세한 근거는 위 usage 섹션 주석). 되돌리지 마라.
# 예전 이 주석은 "ARM_BODY 는 1376바이트라 파이프 용량 65536 의 2% 이므로 좌변이 bash
# 내장 echo 인 지금 이 크기만으로는 141 이 나지 않는다" 고 적었다. **그 논증은 폐기했다** —
# 위 usage 섹션 주석의 실측대로 166바이트 페이로드가 65536 버퍼에서 45/20000(10병렬·
# 무압력 조건) 터졌고,
# 파이프 용량 자체도 상수가 아니다(3000개 보유 시 512로 강등). 여기서 파이프를 걷은
# 이유는 크기가 아니라 **일치하는 줄 뒤에 write 가 남을 수 있다** 는 것 하나다.
# 특히 첫 단언은 부정 극성이라(찾으면 fail) SIGPIPE 가 거짓 실패가 아니라 조용한 거짓
# 통과로 나타난다 — 이빨이 사라지는 쪽이라 더 위험하다.
#   - 첫 단언은 정규식(교대 |)이 필요해 case 글롭으로 못 옮긴다 → herestring.
#     herestring 은 파이프가 아니라 bash 가 만드는 입력이라 쓰는 쪽 프로세스가 없다.
#     극성 주의: 여기서 grep 이 "찾으면" fail 이다(회귀 검출) — 뒤집지 마라.
#   - 둘째 단언은 고정 문자열이라 case 로 옮겼다. 패턴을 홑따옴표로 감싼 건 필수다 —
#     안 감싸면 `$chain_left` 가 이 스위트의 셸에서 빈 문자열로 확장돼 단언이 무력해진다.
grep -qE "writeFileSync|writeJsonAtomic" <<<"$ARM_BODY" && fail "cmd_arm 이 아직 reservation.json 을 두 번째로 쓴다 — 레이스가 남아있다" || ok "cmd_arm 에 쓰기 지점 없음 — 체인 필드는 reserve 의 단일 쓰기에 합쳐졌다"
case "$ARM_BODY" in
  *'--chain-left "$chain_left"'*) ok "체인 정보를 reserve 인자로 전달함";;
  *) fail "reserve 에 --chain-left 를 넘기지 않음: $ARM_BODY";;
esac

section "blocker: cmd_reserve 의 쓰기는 한 번뿐이고 슬리퍼는 그 뒤에 뜬다"
RESERVE_BODY=$(awk '/^cmd_reserve\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$FREEZE_SRC" | grep -v '^[[:space:]]*#' || true)
WRITE_COUNT=$(echo "$RESERVE_BODY" | grep -cE "writeJsonAtomic|writeFileSync" || true)
[ "$WRITE_COUNT" = 1 ] && ok "cmd_reserve 안의 쓰기 지점이 정확히 1곳" || fail "cmd_reserve 의 쓰기 지점이 ${WRITE_COUNT}곳 (기대 1)"
# 매치가 없으면(=회귀) grep 이 rc=1 을 내고 pipefail 이 그걸 파이프라인 rc 로 올린다 —
# 그 rc 로 끊기면 아래 단언의 "write=/spawn= 비어있음" 보고가 사라진다. 빈 값 판정은
# 아래 단언이 이미 하고 있으므로 여기선 rc 를 흘린다.
WRITE_LINE=$(echo "$RESERVE_BODY" | grep -n "writeJsonAtomic" | head -1 | cut -d: -f1 || true)
SPAWN_LINE=$(echo "$RESERVE_BODY" | grep -n "spawn_sleeper \"\$job\"" | head -1 | cut -d: -f1 || true)
{ [ -n "$WRITE_LINE" ] && [ -n "$SPAWN_LINE" ] && [ "$WRITE_LINE" -lt "$SPAWN_LINE" ]; } \
  && ok "유일한 쓰기(줄 $WRITE_LINE) 가 끝난 뒤에 슬리퍼를 띄운다(줄 $SPAWN_LINE)" \
  || fail "쓰기/spawn 순서 확인 실패: write=$WRITE_LINE spawn=$SPAWN_LINE"

section "wfledger: init/mark/remaining/journal/run 왕복"
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

assert_out "체크: 단계 1" "mark 1" "mark 1" -- bash "$WFL" mark --ledger "$LPATH" --step 1 --artifact "$TMP/out1.txt"
REM=$(bash "$WFL" remaining --ledger "$LPATH")
# 옛 형태의 grep 패턴은 `2\. 둘째 단계` / `1\. 첫 단계` 였다 — BRE 의 `\.` 는 리터럴
# 점이므로 두 패턴 모두 고정 문자열이고, 아래 case 글롭은 그와 정확히 등가다.
# 아래 둘째 case 가 부정 극성 2/3 다(찾으면 fail).
case "$REM" in
  *"2. 둘째 단계"*) ok "remaining 은 미완료만 출력";;
  *) fail "remaining: $REM";;
esac
case "$REM" in
  *"1. 첫 단계"*) fail "remaining 에 완료된 단계가 섞임: $REM";;
  *) ok "완료 단계는 remaining 에서 제외";;
esac
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

assert_out "등록: $RUNID" "run 등록" "run 등록 실패" -- bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID"
grep -q "runId: $RUNID" "$LPATH" && ok "runId 기록" || fail "runId 미기록"
grep -qF "journal: $RUNDIR/journal.jsonl" "$LPATH" && ok "journal 절대경로 기록" || fail "journal 경로 미기록"
grep -qF "script: $SCRIPTDIR/mytask-$RUNID.js" "$LPATH" && ok "script 절대경로 기록" || fail "script 경로 미기록"

section "wfledger: run 은 없는 runId 를 오타로 보고 거부한다 (major 회귀)"
bash "$WFL" run --ledger "$LPATH" --run-id wf_typo_no_such_dir > /dev/null 2>&1 && fail "존재하지 않는 런 디렉토리인데 등록 성공함" || ok "런 디렉토리 없으면 등록 실패"
grep -q "wf_typo_no_such_dir" "$LPATH" && fail "실패한 런이 원장에 남음" || ok "실패한 런은 원장에 안 남음"

section "wfledger: run 은 같은 runId 재등록에 멱등이다 (중복 방지)"
assert_out "이미 등록됨" "재등록은 '이미 등록됨' 으로 통과" "재등록 메시지 다름" -- bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID"
# grep -c 는 매치 0건에 rc=1 을 낸다 — 그 rc 로 스위트가 끊기면 정작 "중복됐다/없다"를
# 판정해야 할 다음 줄이 실행되지 못해 회귀가 FAIL 이 아니라 중단으로 나타난다.
DUPCOUNT=$(grep -c -- "- runId: $RUNID" "$LPATH" || true)
[ "$DUPCOUNT" = 1 ] && ok "항목이 중복되지 않음 (1개)" || fail "runId 항목이 중복됨: $DUPCOUNT"

section "wfledger: 플레이스홀더 제거가 '## 워크플로우 런' 섹션에만 스코프된다"
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
assert_out "등록: $RUNID2" "두 번째 run 등록" "두 번째 run 등록 실패" -- bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID2"
# 위와 같은 이유로 rc 를 흘린다 — 이 줄이 재는 건 개수고, 판정은 다음 줄이 한다.
PLACEHOLDER_COUNT=$(grep -c "(등록된 런 없음)" "$LPATH" || true)
[ "$PLACEHOLDER_COUNT" = 1 ] && ok "완료 기준 본문의 우연한 문구는 살아남음 (1개 남음)" || fail "무관한 본문 줄까지 지워짐: 남은 개수=$PLACEHOLDER_COUNT"

section "wfledger: journal 없는 파일은 경고로 구분되고 조용히 사라지지 않는다"
RUNID3="wf_no_journal_yet"
RUNDIR3="$CLAUDE_PROJECTS_DIR/$SLUG2/$SESSION/subagents/workflows/$RUNID3"
mkdir -p "$RUNDIR3"   # 디렉토리는 있지만 journal.jsonl 은 아직 없음(아직 flush 전 재현)
bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID3" > /dev/null
JOUT=$(bash "$WFL" journal --ledger "$LPATH" 2>"$TMP/journal.err")
case "$JOUT" in
  *"agent1 v2:aaa"*) ok "journal: 다른 정상 런의 완료된 호출은 그대로 출력";;
  *) fail "journal 출력: $JOUT";;
esac
# 이 줄은 파일 인자 grep 이라 파이프가 없다 — 정규식(`.*`)도 필요하므로 그대로 둔다.
grep -q "WARN.*journal 파일 없음" "$TMP/journal.err" && ok "journal 없는 등록은 WARN 으로 구분됨" || fail "WARN 안 남음: $(cat "$TMP/journal.err")"
# 부정 극성 3/3.
case "$JOUT" in
  *agent2*) fail "journal 에 미완료 호출이 섞임: $JOUT";;
  *) ok "미완료 호출 제외 확인";;
esac

section "wfledger: set-session 이 원장 헤더의 session 필드를 갱신한다 (major 회귀)"
NEWSESS="22222222-3333-4444-5555-666666666666"
assert_out "세션 갱신" "set-session 실행" "set-session 실패" -- bash "$WFL" set-session --ledger "$LPATH" --session "$NEWSESS"
grep -q "^session: $NEWSESS$" "$LPATH" && ok "원장 헤더 session 필드 갱신 확인" || fail "session 필드 미갱신"
# 갱신 후 run 은 --session 없이도 새 세션 경로로 계산해야 한다
RUNID4="wf_after_set_session"
RUNDIR4="$CLAUDE_PROJECTS_DIR/$SLUG2/$NEWSESS/subagents/workflows/$RUNID4"
mkdir -p "$RUNDIR4"
echo '{"type":"result","key":"v2:ddd","agentId":"agent4"}' > "$RUNDIR4/journal.jsonl"
assert_out "등록: $RUNID4" "set-session 이후 run 이 새 세션 경로로 계산" "새 세션 경로 계산 실패" -- bash "$WFL" run --ledger "$LPATH" --run-id "$RUNID4"
grep -qF "journal: $RUNDIR4/journal.jsonl" "$LPATH" && ok "새 세션 기준 journal 경로 기록" || fail "새 세션 경로 미기록"

section "wfledger: set-session --cwd 로 자동탐지도 된다"
AUTOSESS="33333333-4444-5555-6666-777777777777"
sleep 1.1  # ls -t 의 mtime 해상도 확보 — 이 파일이 확실히 "최신"이 되도록
echo '{}' > "$CLAUDE_PROJECTS_DIR/$SLUG2/$AUTOSESS.jsonl"
assert_out "$AUTOSESS" "cwd 기준 자동탐지 세션 갱신" "자동탐지 세션 갱신 실패" -- bash "$WFL" set-session --ledger "$LPATH" --cwd "$LEDGER_CWD"

JOUT=$(bash "$WFL" journal --ledger "$LPATH")
case "$JOUT" in *"agent1 v2:aaa"*) ok "journal: 완료된 호출만 출력";; *) fail "journal 출력: $JOUT";; esac

section "wfledger link: 성공/폴백"
# 위 set-session 테스트들이 원장의 session: 필드를 바꿔 놨다 — link 는 그 필드로
# "원본" 런 디렉토리를 찾으므로, $RUNID 가 실제로 만들어진 $SESSION 으로 되돌린다.
bash "$WFL" set-session --ledger "$LPATH" --session "$SESSION" > /dev/null
NEWSESSION="99999999-8888-7777-6666-555555555555"
assert_out "링크됨" "link 성공" "link 실패" -- bash "$WFL" link --ledger "$LPATH" --run-id "$RUNID" --session "$NEWSESSION"
NEWDIR="$CLAUDE_PROJECTS_DIR/$SLUG2/$NEWSESSION/subagents/workflows/$RUNID"
[ -L "$NEWDIR" ] && ok "symlink 생성 확인" || fail "symlink 없음"
assert_out "이미 존재" "재호출은 idempotent" "재호출 동작 이상" -- bash "$WFL" link --ledger "$LPATH" --run-id "$RUNID" --session "$NEWSESSION"
bash "$WFL" link --ledger "$LPATH" --run-id "wf_missing" --session "$NEWSESSION" > /dev/null 2>&1 && fail "존재하지 않는 run 인데 성공함" || ok "원본 없으면 실패 코드로 폴백 신호"

section "_node.sh: node 탐색 폴백"

section "_node.sh: FREEZE_NODE_BIN 존중 (테스트 1)"
NODE_WRAP_LOG="$TMP/node-wrap.log"
NODE_WRAP="$TMP/node-wrap.sh"
# $FREEZE_NODE_BIN 을 쓴다(command -v node 대신) — 이 테스트 스크립트 자체가 위에서
# _node.sh 를 이미 source 했으므로 여기선 node 가 함수로 가려져 있어 command -v 는
# 실행파일 경로가 아니라 함수 이름("node")을 돌려준다. $FREEZE_NODE_BIN 은 _node.sh
# 가 탐색해서 export 해둔 실제 절대경로다.
REAL_NODE="$FREEZE_NODE_BIN"
cat > "$NODE_WRAP" <<WRAPEOF
#!/usr/bin/env bash
echo "called \$@" >> "$NODE_WRAP_LOG"
exec "$REAL_NODE" "\$@"
WRAPEOF
chmod +x "$NODE_WRAP"
WRAP_OUT=$(FREEZE_NODE_BIN="$NODE_WRAP" bash "$FZ" estimate 2>&1) || true
[ -f "$NODE_WRAP_LOG" ] && ok "estimate 실행 중 FREEZE_NODE_BIN 래퍼가 호출됨" || fail "래퍼 미호출: $WRAP_OUT ($(cat "$NODE_WRAP_LOG" 2>/dev/null))"

section "_node.sh: PATH 에 node 없어도 동작 (테스트 2)"
NODE_DIR=$(dirname "$FREEZE_NODE_BIN")
STRIPPED=$(printf '%s' "$PATH" | tr ':' '\n' | grep -vx "$NODE_DIR" | paste -sd: -)
# 서브셸 + unset -f 로 확인한다 — 이 프로세스엔 이미 _node.sh 가 정의한 node() 함수가
# 있어서, 그냥 command -v node 를 쓰면 PATH 와 무관하게 함수 이름을 찾아내 버린다.
if (unset -f node; PATH="$STRIPPED" command -v node >/dev/null 2>&1); then
  skip "PATH 에서 node 디렉토리($NODE_DIR)를 빼도 다른 위치의 node 가 여전히 잡힘 — 이 환경에선 재현 불가"
else
  # set -e 아래에서 대입만 있는 명령이 실패하면(예: 이전엔 STRIPPED_OUT=$(...) 다음 줄에서
  # $? 를 읽는 방식) 그 줄에 닿기도 전에 스위트 전체가 죽는다. &&/|| 로 감싸 대입 자체의
  # 실패가 errexit 를 트리거하지 않게 한다(NO_TARGET_RC / CHECK_RC 와 같은 패턴 — 줄 번호는
  # 편집마다 밀리므로 변수명으로 가리킨다).
  STRIPPED_OUT=$(env -u FREEZE_NODE_BIN PATH="$STRIPPED" bash "$FZ" estimate 2>&1) && STRIPPED_RC=0 || STRIPPED_RC=$?
  [ "$STRIPPED_RC" = 0 ] && ok "stripped PATH 에서도 freeze.sh estimate 가 rc=0 으로 완주" || fail "stripped PATH estimate 실패 rc=$STRIPPED_RC: $STRIPPED_OUT"

  section "_node.sh: 슬리퍼가 node 를 물려받는다 (테스트 3, 핵심 회귀)"
  # "완주(status=done)" 만으론 export 가 load-bearing 인지 증명 못 한다 — 후보 3/4/5
  # (/opt/homebrew, /usr/local, nvm 글롭)는 절대경로라 PATH 를 지워도 자식이 자력으로
  # node 를 되찾을 수 있어서다(예: 이 개발기의 nvm). export 를 지운 변이 코드로도
  # 그 경로면 완주해버려 이빨 없는 단언이 된다. 그래서 PATH 뿐 아니라 후보 3/4/5 어디에도
  # 안 걸리는 전용 래퍼를 FREEZE_NODE_BIN 으로 지정하고, thaw.sh 가 그 래퍼를 실제로
  # 물려받아 썼는지를 래퍼 호출 로그로 직접 확인한다.
  export FREEZE_CLAUDE_BIN="$MOCK"
  NODE_WRAP3_LOG="$TMP/node-wrap3.log"
  NODE_WRAP3="$TMP/node-wrap3.sh"
  cat > "$NODE_WRAP3" <<WRAP3EOF
#!/usr/bin/env bash
echo "called \$@" >> "$NODE_WRAP3_LOG"
exec "$REAL_NODE" "\$@"
WRAP3EOF
  chmod +x "$NODE_WRAP3"
  SLEEPER_HANDOFF="$FAKE_CWD/sleeper-handoff.md"; echo "# sleeper handoff" > "$SLEEPER_HANDOFF"
  SLEEPER_OUT=$(FREEZE_NODE_BIN="$NODE_WRAP3" PATH="$STRIPPED" bash "$FZ" reserve --at +2s --pad 0 --cwd "$FAKE_CWD" --handoff "$SLEEPER_HANDOFF" --job stripjob)
  case "$SLEEPER_OUT" in *job=stripjob*) ok "stripped PATH 로도 reserve 등록";; *) fail "stripped PATH reserve 실패: $SLEEPER_OUT";; esac
  STRIP_STATUS=""
  for i in $(seq 1 "$POLL_TRIES"); do
    STRIP_STATUS=$(node -e "console.log(JSON.parse(require('fs').readFileSync('$FREEZE_STATE_DIR/stripjob/reservation.json')).status)")
    [ "$STRIP_STATUS" = "done" ] && break
    sleep 1
  done
  [ "$STRIP_STATUS" = "done" ] && ok "stripped PATH 로 뜬 슬리퍼가 완주 (status=done)" || fail "슬리퍼가 완주 못 함 — $(poll_diag "$STRIP_STATUS" done)"
  # 핵심 단언: thaw.sh 전용 필드(permission_mode — freeze.sh 의 job_field() 는 안 읽는다)
  # 를 읽는 field() 호출이 래퍼 로그에 실제로 찍혔는지. thaw.sh 의 field() 는
  # `node -e '<한 줄 스크립트>' "$RES" "permission_mode"` 형태라 로그 한 줄에
  # reservation.json 경로 바로 뒤에 "permission_mode" 가 붙어 나온다 — 이 인접 패턴을
  # 고정 문자열로 찾는다. (freeze.sh 의 reserve 기록 호출도 스크립트 본문에
  # "permission_mode" 라는 글자는 들어있지만, 그 -e 스크립트는 여러 줄이라 로그에서
  # 줄이 갈리고 reservation.json 경로는 그 스크립트 뒤에 별도 인자로 나와 절대 같은
  # 줄에서 바로 붙어 나오지 않는다 — 인접 검사라 오탐이 안 난다.)
  grep -qF -- "$FREEZE_STATE_DIR/stripjob/reservation.json permission_mode" "$NODE_WRAP3_LOG" \
    && ok "thaw.sh 의 field() 호출이 실제로 FREEZE_NODE_BIN 래퍼를 거쳐감 (export 전파 확인, 변이 테스트로 검증됨)" \
    || fail "래퍼 로그에 thaw.sh 호출(permission_mode 필드 읽기)이 없음 — export 없이도 통과할 수 있는 이빨 없는 테스트: $(cat "$NODE_WRAP3_LOG" 2>/dev/null)"

  # 위 완주(status=done) + 래퍼 로그 검사는 사실 "export FREEZE_NODE_BIN" 한 줄이 빠져도
  # 못 잡는다(변이 테스트로 실측·재확인함) — 이 코드베이스는 PATH/파일시스템이 부모
  # freeze.sh 부터 자식 thaw.sh 까지 어디서도 바뀌지 않아서, export 없이 thaw.sh 에
  # FREEZE_NODE_BIN 이 안 물려가도 thaw.sh 가 자기 _node.sh 소싱에서 candidate 2(PATH)로
  # 부모와 완전히 같은 값을 "독립적으로" 다시 찾아버린다 — FREEZE_NODE_BIN="$NODE_WRAP3"
  # PATH="$STRIPPED" 로 넘겨도 그 값은 이미 bash 의 임시 환경 할당(`VAR=val cmd`)으로
  # freeze.sh 프로세스 시작 시점부터 이미 exported 상태라, _node.sh 내부의 재-export 유무와
  # 무관하게 자식·손자 프로세스까지 그대로 전파된다(3단 중첩 bash -c 로 직접 검증함).
  # 그래서 이 mutation 을 잡으려면 E2E 완주 여부가 아니라 "_node.sh 를 소싱한 뒤
  # FREEZE_NODE_BIN 이 실제로 그 프로세스의 env 에 노출되는가" 를 직접 봐야 한다 —
  # candidate 2~5 로 새로 발견한 값은 원래 로컬 셸 변수라, export 없이는 자식이 볼 수 있는
  # 어떤 채널(env)에도 안 실린다.
  # 이 줄은 이 파일에 마지막까지 남아 있던 `| grep -q` 파이프였다. 예전 주석은 두 가지
  # 근거로 남겨뒀는데, 첫째는 여전히 맞고 둘째는 회피할 수 있다:
  #   1) (여전히 맞다) 여기엔 141 을 올릴 pipefail 이 없다 — 파이프라인이 `bash -c` 안에서
  #      돌고 set 옵션은 새 bash 로 전파되지 않는다(실측: 부모에서 `set -o pipefail` 후
  #      자식 `bash -c` 가 pipefail off 로 보고). 즉 이 자리는 구조적으로 면역이었다.
  #   2) (회피 가능하다) 옛 형태는 bash -c 본문이 **겹따옴표** 안이라, `<<<"$(env)"` 로
  #      바꾸면 `$(env)` 가 바깥 셸에서 먼저 확장돼(=바깥 프로세스의 env 를 보게 돼)
  #      단언이 조용히 무의미해진다. 그래서 본문을 **홑따옴표**로 돌리고 _node.sh 경로만
  #      환경변수로 넘긴다 — 그러면 `$(env)` 도 `$FREEZE_NODE_SH` 도 자식 bash 에서
  #      확장되고, escaping 함정 없이 파이프를 걷을 수 있다.
  # 파이프를 하나도 남기지 않는 편이 낫다: "이 파일에 파이프 단언은 없다" 가 조건 없는
  # 사실이면 다음 사람이 사이트마다 면역 여부를 재판정할 필요가 없다.
  # 앵커(`^`)가 필요한 정규식이라 case 글롭으로는 못 옮긴다 → herestring 을 쓴다.
  # 등가성: 옛 `env | grep -q '^FREEZE_NODE_BIN='` 과 판정이 같다. `$(env)` 는 뒤쪽
  # 개행만 벗기고 줄 구조를 보존하며, 그 안의 명령치환 파이프는 bash 가 EOF 까지 읽어
  # 조기 종료가 없다(= SIGPIPE 없음).
  EXPORT_CHECK=$(FREEZE_NODE_SH="$HERE/../scripts/_node.sh" env -u FREEZE_NODE_BIN bash -c 'source "$FREEZE_NODE_SH"; grep -q "^FREEZE_NODE_BIN=" <<<"$(env)" && echo EXPORTED || echo NOT_EXPORTED')
  [ "$EXPORT_CHECK" = "EXPORTED" ] && ok "_node.sh 소싱 직후 FREEZE_NODE_BIN 이 실제로 export 됨 (env 에 노출 — 핵심 회귀 지점)" || fail "FREEZE_NODE_BIN 이 export 안 됨 — thaw.sh 가 물려받지 못한다: $EXPORT_CHECK"
fi

section "_node.sh: 못 찾으면 명확히 실패 (테스트 4)"
EMPTY_PATH_DIR="$TMP/emptybin"
mkdir -p "$EMPTY_PATH_DIR"
BASH_ABS="$(command -v bash)"   # env -i 로 PATH 를 비우면 "bash" 자체를 못 찾으므로 절대경로로 부른다
if env -i HOME="$TMP/no-such-home" FREEZE_NODE_BIN="" PATH="$EMPTY_PATH_DIR" "$BASH_ABS" -c "source '$HERE/../scripts/_node.sh'" >"$TMP/nonode.out" 2>"$TMP/nonode.err"; then
  NONODE_RC=0
else
  NONODE_RC=$?
fi
if [ "$NONODE_RC" != 0 ] && grep -q "node 를 찾지 못했다" "$TMP/nonode.err"; then
  ok "node 없는 환경에서 _node.sh source 가 명확한 에러 + 비영 종료코드로 실패"
else
  skip "이 머신엔 /opt/homebrew, /usr/local, nvm 후보 중 실제로 잡히는 node 가 있어 탐색이 성공함 (rc=$NONODE_RC): $(cat "$TMP/nonode.err")"
fi

echo
# 아래 두 줄은 반드시 **인접**해야 한다 — 사이에 아무것도(주석조차) 두지 마라.
# 요약줄을 찍은 뒤 SUITE_COMPLETED=1 에 닿기 전에 죽으면 EXIT 트랩이 "진짜 요약줄 +
# ABORTED 배너" 를 함께 내보내고, 그 출력은 사람도 CI 도 읽는 방법이 없다(^PASS= 를
# 보는 호출자는 통과로, 배너를 보는 쪽은 중단으로 읽는다). 예전엔 이 자리에 주석
# 세 줄이 끼어 있었다 — 그 창에 착륙할 수 있는 건 비동기 시그널뿐이라 실제 재현은
# 안 됐지만, 창을 0 으로 만들 수 있는데 남겨둘 이유가 없다.
# 요약줄에 닿으면 여기부터는 ABORTED 배너를 찍지 않는다. 단정이 빨간 실행(FAIL>0)은
# 맨 아래 [ "$FAIL" = 0 ] 이 비영 종료코드로 알린다(그건 중단이 아니라 정상적인 실패다).
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
SUITE_COMPLETED=1
[ "$FAIL" = 0 ]
