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

# reservation.json 을 읽을 수 없으면 fail-closed 로 죽는다.
#
# 이 스크립트에서 가장 위험한 실패는 "예약이 안 도는 것"이 아니라 "안 부른 세션이 지금
# 뜨는 것"이다 — 사용자가 그 시각에 그 세션에서 일하는 중이고, 쿼터도 지금 태운다.
# 예전 field() 는 JSON.parse 예외를 stderr 로만 흘리고 빈 문자열을 성공으로 돌려줬고,
# 아래 대기 루프가 빈 RESUME_AT 을 산술 확장에서 0 으로 읽어 remain<=0 → 즉시 재개로
# 샜다(blocker. 레이스 자체와 원자적 쓰기는 _node.sh (d) 주석 참고).
# 그래서 (a) field() 는 실패를 비영 종료코드로 알리고(짧은 재시도는 공용 JS 안에 있다),
# (b) 필수 필드는 전부 `|| die` 로 받고, (c) 정수여야 하는 값은 산술 확장에 맡기지 않고
# 정규식으로 직접 확인한다.
die() { echo "[$(date '+%F %T')] ERROR: $* — 즉시 재개하지 않고 종료한다. job=$JOB" >&2; exit 1; }

field() { node -e "$FREEZE_JS_FIELD" "$RES" "$1"; }
set_status() {
  node -e "$FREEZE_JS_ATOMIC"'
const fs = require("fs"), [p, s] = process.argv.slice(1);
const d = JSON.parse(fs.readFileSync(p));
d.status = s; d.updated_at = Math.floor(Date.now()/1000);
writeJsonAtomic(p, d);
' "$RES" "$1" || echo "[$(date '+%F %T')] WARN: status 갱신 실패 ($1) — $RES" >&2
}

# `X=$(field ...) || die` 는 성립한다 — 대입만 있는 명령의 종료코드는 명령 치환의
# 종료코드다. 이 스크립트엔 set -e 가 없으므로(백그라운드 슬리퍼라 의도된 선택) 이
# 명시적 || 없이는 실패가 조용히 지나간다.
RESUME_AT=$(field resume_at) || die "reservation.json 을 읽지 못했다(resume_at): $RES"
# 산술 확장은 빈 문자열도, 쓰레기도 조용히 0 으로 만든다 — 그게 곧 "지금 재개"다.
[[ "$RESUME_AT" =~ ^[0-9]+$ ]] || die "resume_at 이 정수가 아니다: '$RESUME_AT' ($RES)"
SESSION=$(field session_id) || die "reservation.json 을 읽지 못했다(session_id): $RES"
CWD=$(field cwd) || die "reservation.json 을 읽지 못했다(cwd): $RES"
# 빈 cwd 로 내려가면 `cd ""` 가 조용히 성공해 엉뚱한 디렉토리에서 재개된다.
# reserve/arm 은 --cwd 를 필수로 받으므로 비어 있다는 건 파일이 깨졌다는 뜻이다.
[ -n "$CWD" ] || die "cwd 가 비었다 ($RES)"
HANDOFF=$(field handoff) || die "reservation.json 을 읽지 못했다(handoff): $RES"
[ -n "$HANDOFF" ] || die "handoff 가 비었다 ($RES)"
PERM=$(field permission_mode) || die "reservation.json 을 읽지 못했다(permission_mode): $RES"
[ -n "$PERM" ] || PERM="bypassPermissions"   # 구버전 reservation 호환
MODE=$(field mode) || die "reservation.json 을 읽지 못했다(mode): $RES"
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
JOB_CREATED_AT=$(field created_at) || die "reservation.json 을 읽지 못했다(created_at): $RES"
# 구버전 reservation 호환 — 필드가 없으면 0(항상 신호를 받아들인다). 아래 is_done_signaled
# 가 이 값을 `-ge` 로 비교하므로, 값이 정수임을 여기서 확정해 둔다.
[[ "$JOB_CREATED_AT" =~ ^[0-9]+$ ]] || JOB_CREATED_AT=0

is_done_signaled() {
  [ -f "$DONE_MARK" ] && return 0
  [ -f "$HANDOFF_MARK" ] || return 1
  local sig_ts
  sig_ts=$(head -1 "$HANDOFF_MARK" 2>/dev/null || true)
  [[ "$sig_ts" =~ ^[0-9]+$ ]] || return 1
  [ "$sig_ts" -ge "$JOB_CREATED_AT" ]
}

# ledger 모드 결정적 완료 게이트 — done 마커처럼 누가 명시로 불러줘야 하는 신호가
# 아니라, 원장 '## 단계' 체크박스 자체를 기계적으로 읽어 "남은 단계가 있는가"를 판정한다.
# wfledger.sh remaining 은 미체크 항목(grep -E '^- \[ \] ')을 그대로 뱉으므로
# (wfledger.sh:248-259) 출력이 비면 남은 단계 0 이라는 뜻이다. 세 조건을 전부 요구하는
# 게 핵심이고, 하나라도 빼면 오판정이 난다:
#   - rc 확인이 필요한 이유: wfledger.sh remaining 은 원장 파일이 없으면 stdout 이 비고
#     rc=1 이다(wfledger.sh:257 의 [ -f "$ledger" ] 가드). 출력이 비었다는 것만 보면
#     "원장 분실"을 "완료"로 오독한다 — rc=0 까지 확인해야 진짜 빈 출력과 구분된다.
#   - 체크박스 존재 확인이 필요한 이유: 단계 섹션 자체를 지워버린 원장은 그 섹션 안에
#     체크박스가 없으니 판정 대상이 없다 — 그건 "완료"가 아니라 "판정 불가"다.
#     예전엔 이 확인을 파일 전체 대상 `grep -qE '^- \[[ xX]\] '` 로 했는데, 파일
#     전체 스코프가 바로 아래 오발동·미발동 사례들이 새는 원인이라 제거했다 — 지금은
#     아래 절 스코프 판정의 `[ "$total" -gt 0 ]` 이 같은 역할을 "## 단계" 절 기준으로
#     더 정확하게 한다. mark 가 체크박스를 [x] 로 바꾸는 치환은
#     `sub(/^- \[ \]/, "- [x]", line)`(wfledger.sh:229) 다 — `print line`(wfledger.sh:231)
#     이 아니다, 이전 주석의 인용 행번호가 틀렸었다.
#   - MODE 확인이 필요한 이유: ledger 모드가 아니면 이 신호 자체가 대응하는 게 없다
#     (resume 모드는 원장을 쓰지 않는다) — 항상 거짓으로 둔다.
#
# ↑ 다만 위 세 조건("파일 어딘가에 체크박스가 하나라도 있다" + "remaining 이 비어
# 있다")만으로는 세 방향으로 샌다 — remaining 의 grep(wfledger.sh:258)이 보고용으로
# 느슨하게 짜였을 뿐인데, 그 느슨함을 "재개 생략 + 선무장한 다음 창 취소"라는
# 되돌릴 수 없는 제어 결정의 유일한 근거로 썼기 때문이다:
#   1) 오발동(위험): 재개 세션이 '## 재개 결과' 절에 `- [x] 테스트 통과` 같은
#      체크리스트를 남기고 '## 단계' 절은 편집 중 사라진 원장 — 파일 전체 존재
#      확인이 그 `- [x]` 로 통과하고, 단계 섹션이 없으니 remaining 도 비어 게이트가
#      발동한다. "판정 불가로 막는다"던 위 방어가 새는 경로다.
#   2) 오발동(가장 위험): 상위 단계는 다 체크됐고 들여쓴 하위 미체크 항목만 남은
#      상태(`- [x] 1. ...` 아래 `  - [ ] 1a. 미완`) — remaining 의 `^- ` 앵커는
#      들여쓴 줄을 못 잡아 출력이 비고, 존재 확인은 상위 `- [x]` 로 통과 → 게이트가
#      발동해 남은 작업이 조용히 버려지고 재무장 체인까지 끊긴다. `* [ ] 2. 미완`
#      처럼 하이픈이 아닌 불릿, `-[ ] 2.` 처럼 불릿 뒤 공백이 없는 표기도 같은
#      앵커에 걸려 똑같이 샌다.
#   3) 미발동(무해하지만 기능 무력화): '## 검증' 절에 미체크 `- [ ]` 가 하나라도
#      있으면 '## 단계' 가 전부 체크돼도 remaining 이 비지 않아 게이트가 영구히
#      안 걸린다.
#
# 대응 — ledger_complete() 안에 '## 단계' 절만 스코프하는 들여쓰기 인식 직접 판정을
# 추가하고, 기존 remaining 호출은 그대로 남겨 **양쪽이 합의할 때만** 발동시킨다:
#   - 왜 절 스코프인가: 파일 전체 판정은 위 1·3번 두 방향으로 샌다. awk 로 '## 단계'
#     절만 잘라 그 안에서만 체크박스를 센다. 절 이름이 바뀌거나 통째로 사라지면
#     total=0 이 되어 곧이어 나오는 `[ "$total" -gt 0 ]` 에서 즉시 "판정 불가"로
#     빠진다 — 안전한 방향(재개 진행)으로 넘어간다.
#   - 왜 들여쓰기를 보는가: remaining 의 `^- ` 앵커는 들여쓴 하위 미체크 항목을 못
#     본다(wfledger.sh:258). 보고용으로 관대하게 짠 grep 을 되돌릴 수 없는 제어
#     결정의 유일한 근거로 쓸 수 없으므로, 여기서는 선행 공백을 허용하는
#     `^[[:space:]]*[-*+][[:space:]]*\[...\]` 로 들여쓴 줄도 잡는다. 미체크 판정은
#     최대한 관대하게(앞 들여쓰기, 불릿 문자 종류, 불릿 뒤 공백 유무를 전부 상관하지
#     않고 대괄호 안이 스페이스 한 칸이기만 하면 매칭) 잡는다 — 미체크를 놓치는
#     방향이 유일하게 위험한 오류이기 때문이다.
#   - 왜 하이픈 말고 `*`·`+` 까지 보는가: 원장의 단계 절을 편집하는 건 스크립트가
#     아니라 재개 LLM 이다(재개 프롬프트가 "원장의 단계 체크박스를 갱신하고" 라고
#     지시한다). 마크다운에서 합법인 `* [ ] 2. 미완` 이 섞여 들어오면 이 awk 도,
#     remaining 의 `^- ` 앵커도 그 줄을 못 잡는다 — 나머지가 전부 `- [x]` 이면
#     total>0·unchecked=0 이 되어 게이트가 오발동한다(실측 확인). 불릿 뒤 공백이 없는
#     `-[ ] 2.` 도 같은 이유로 `[[:space:]]*` 로 넓혔다. 위의 "미체크를 놓치는 방향만
#     위험하다"는 원칙을 이 패턴 자신이 어기고 있었다.
#   - 왜 remaining 을 계속 부르는가: 원장 체크박스 계약의 SSOT 를 wfledger 쪽에
#     남겨두고, 게이트는 두 판정이 합의할 때만 발동해 오발동 방향으로만 더 엄격해
#     진다. 3번(미발동)은 이 조합에서도 여전히 남지만, 그건 "게이트가 안 걸려
#     예전처럼 대화 전체로 재개된다"는 뜻이라 손해가 아니라 손실 없는 퇴화다.
#   - rc 검사를 남기는 이유: 지금은 바로 위 `[ -f "$HANDOFF" ]` 가드가 먼저 걸러내므로
#     remaining 이 rc=1 을 내는 경로(원장 부재, wfledger.sh:257)엔 사실상 도달하지
#     않는다. 그래도 방어 깊이로 남긴다 — `-f` 가드가 "중복"이라는 이유로 지워지거나
#     remaining 에 새 실패 경로가 생기면 이 rc 검사가 유일한 방어선이 된다.
#
# awk 이식성: macOS 기본 awk("one true awk", 20200816)에서 `[[:space:]xX]` 처럼
# POSIX 문자클래스를 다른 문자와 섞은 bracket expression 이 실제로 동작하는지 실행해
# 확인했다 — `printf '## 단계\n- [x] 1. a\n  - [ ] 1a. b\n' | awk '...'` 가 그대로
# total=2 unchecked=1 을 낸다. 쪼개거나 match() 로 바꿀 필요가 없었다. 불릿 문자
# 클래스 `[-*+]` 는 대괄호 안 첫 자리의 `-` 라 리터럴로 읽힌다(범위 표기가 아니다).
ledger_complete() {
  [ "$MODE" = "ledger" ] || return 1
  [ -f "$HANDOFF" ] || return 1
  local counts total unchecked
  # '## 단계' 절만 스코프 — in_steps 는 다른 '## ' 헤딩을 만나면 즉시 꺼진다(다음
  # 섹션으로 넘어갔다는 뜻). 헤딩 줄 자체는 항상 next 로 건너뛰어 헤딩이 체크박스
  # 패턴에 우연히 걸릴 일이 없게 한다.
  counts=$(awk '
    /^## / { in_steps = ($0 ~ /^## 단계[[:space:]]*$/); next }
    !in_steps { next }
    /^[[:space:]]*[-*+][[:space:]]*\[[[:space:]xX]\]/ {
      total++
      if ($0 ~ /^[[:space:]]*[-*+][[:space:]]*\[[[:space:]]\]/) unchecked++
    }
    END { printf "%d %d\n", total+0, unchecked+0 }
  ' "$HANDOFF") || return 1
  total=${counts%% *}; unchecked=${counts##* }
  # total=0 → '## 단계' 절이 없거나 그 안에 체크박스가 하나도 없다 = 판정 불가.
  # 판정 불가는 안전한 쪽(재개 진행)으로 넘어가야 하므로 여기서 return 1.
  [ "$total" -gt 0 ] || return 1
  [ "$unchecked" = 0 ] || return 1
  local out rc
  out=$(bash "$SCRIPT_DIR/wfledger.sh" remaining --ledger "$HANDOFF" 2>/dev/null)
  rc=$?
  [ "$rc" = 0 ] || return 1
  [ -z "$out" ]
}

echo "[$(date '+%F %T')] thaw 시작 — job=$JOB 땡=$(fmt_epoch "$RESUME_AT" '+%F %T')"

# 1) 예약 시각까지 대기 (60초 단위로 끊어 자며 취소·완료 여부 확인)
# sleep 은 백그라운드 + wait 로 돌린다 — 포그라운드 sleep 은 bash 의 TERM 처리를 막아 kill 이 최대 60초 늦어진다.
#
# 이 구간(과 아래 프로브 구간)의 completed_early 전이 앞에는 release_next_job 이 없다 —
# 다음 창 선무장은 프로브를 다 지난 뒤(3번 구간)에야 일어나므로 여기엔 해제할 자식이
# 아직 존재하지 않는다. release_next_job 이 세우는 불변식의 범위는 "이 thaw 프로세스가
# 스스로 선무장한 NEXT_JOB" 까지다(캐치업으로 다시 뜬 프로세스는 이전 화신이 낳은 자식을
# 모른다 — 그 경우는 자식 자신의 완료 신호 검사(is_done_signaled)가 받아낸다. 그 검사에서
# 실제로 버티는 마커가 무엇인지는 아래 release_next_job 주석에 적어뒀다 — job 마커가 아니다).
while :; do
  cur_status=$(field status) || die "대기 중 reservation.json 을 읽지 못했다(status): $RES"
  [ "$cur_status" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
  is_done_signaled && { set_status "completed_early"; echo "완료 신호 감지 — 재개 없이 종료"; exit 0; }
  now=$(date +%s)
  remain=$(( RESUME_AT - now ))
  [ "$remain" -le 0 ] && break
  sleep $(( remain < 60 ? remain : 60 )) & wait $!
done

# 2) haiku 프로브 — 한도가 실제로 풀렸는지 몇 토큰으로 확인
probe_ok=0
for i in $(seq 1 "$PROBE_MAX"); do
  cur_status=$(field status) || die "프로브 중 reservation.json 을 읽지 못했다(status): $RES"
  [ "$cur_status" = "cancelled" ] && { echo "취소됨 — 종료"; exit 0; }
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
#      루프(위 1번 섹션)가 깨어날 때마다 is_done_signaled 를 검사하므로 스스로 조용히
#      종료한다. 여기서 실제로 버티는 마커는 HANDOFF_MARK 다 — 자식의 job 마커
#      (DONE_MARK)가 아니다. 근거는 아래 release_next_job 주석.
# 즉 cancel 은 status 를 깨끗하게 유지하기 위한 것이고, 이중 재개 방지의 근거는 2) 다.
# 그래서 아래 release_next_job 은 실패해도 계약을 깨지 않는다 — 경고만 남기고 넘어간다.
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
CHAIN=$(field chain) || die "reservation.json 을 읽지 못했다(chain): $RES"
CHAIN_LEFT=$(field chain_left) || die "reservation.json 을 읽지 못했다(chain_left): $RES"
# reserve 로 걸린 예약엔 이 필드가 없다(빈 문자열). 아래에서 `-gt` 로 비교하므로 정수로
# 확정해 둔다 — 빈 값을 그대로 두면 test 가 rc=2 를 내고 판정이 우연에 맡겨진다.
[[ "$CHAIN_LEFT" =~ ^[0-9]+$ ]] || CHAIN_LEFT=0
PAD=$(field pad) || die "reservation.json 을 읽지 못했다(pad): $RES"
[[ "$PAD" =~ ^[0-9]+$ ]] || PAD=300   # 구버전 reservation 호환

# done 안내는 예전엔 CHAIN_NOTE 안에서만 채워졌다 — 그런데 CHAIN_NOTE 는 선무장이
# "성공"한 체인 분기(바로 아래 if)에서만 값이 들어간다. 그래서 (a) reserve 로 걸린
# 예약(chain 필드 자체가 없음) (b) 선무장이 실패해 CHAIN_NOTE="" 로 남는 분기, 이 둘은
# 재개 세션에게 done 을 부르라고 알려준 적이 한 번도 없었다 — 작업을 완벽히 끝내도
# 마커가 안 생겨 예약이 영원히 살아남는다. done 안내를 체인 전제와 무관하게 무조건
# 싣도록 CHAIN_NOTE 에서 떼어내 별도 변수로 둔다.
DONE_NOTE="

작업을 다 끝냈으면 반드시 완료 신호를 남겨라 — 그래야 걸어둔 예약이 헛돌지 않고 조용히 해제된다:
  bash ~/.claude/skills/freeze/scripts/freeze.sh done --handoff \"$HANDOFF\""

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

다음 창은 이미 자동으로 예약해 뒀다(job=$NEXT_JOB, 남은 체인 ${NEXT_CHAIN_LEFT}회) — 직접 arm 을 걸 필요는 없다."
  else
    NEXT_JOB=""
    echo "[$(date '+%F %T')] !!! 다음 창 선무장 실패 — 체인이 여기서 끊긴다. 수동으로 arm 필요: $DIR/thaw.log 확인" >&2
    node -e "$FREEZE_JS_ATOMIC"'
const fs = require("fs"), [p, msg] = process.argv.slice(1);
const d = JSON.parse(fs.readFileSync(p));
d.chain_warning = msg;
writeJsonAtomic(p, d);
' "$RES" "다음 창 선무장 실패 — 체인이 끊겼다. bash $SCRIPT_DIR/freeze.sh status 로 확인, 수동 arm 필요: $DIR/thaw.log"
  fi
fi

# 선무장해 둔 다음 창을 해제한다.
#
# 반드시 부모의 status 를 완료(completed_early / done)로 바꾸기 **전에** 부른다. 순서를
# 뒤집으면 "부모는 이미 완료인데 자식은 아직 frozen" 인 중간 상태가 관측 가능하게 열린다
# (cancel 은 fork bash + node 라 부하가 걸리면 수백 ms). 실측: 테스트가 부모 status 만 보고
# 곧바로 자식 status 를 읽어 frozen 을 보고 빨개졌다. 이 순서로 두면
# "부모가 완료로 보인다 ⇒ 자식은 이미 해제됐다" 가 불변식이 되어 그 창이 사라진다.
# 이 불변식의 게이트는 test_freeze.sh 의 "체인: ... cancel 이 부모 status 전환보다 먼저"
# 세 섹션이다 — 아래 호출 지점 셋에 하나씩 대응한다(프로브 구간 분기 / ledger 완료 게이트
# 분기 / 재개 이후 분기). status 를 폴링해 중간 상태를 목격하려는 방식은 게이트로 쓸 수
# 없다(순서를 되돌린 변이로 스위트를 부하 하 8회 돌려 1회만 빨개졌다. 12.5%). 그래서 세
# 섹션 모두 cancel 과 set_status 두 쓰기의 node 호출 순서를 직접 관측한다.
# 호출 지점을 넷째로 늘리면 게이트 섹션도 같이 늘려라 — 지점만 늘리면 그 지점은 무보호가
# 된다. ledger 게이트 분기가 정확히 그렇게 한 라운드 동안 무보호로 남아 있었다.
#
# 실패·지연이 부모 status 를 영구히 frozen 으로 남기지 않게, 실패는 경고로만 남기고
# 항상 rc=0 으로 돌아온다 — 호출자는 그 뒤에 무조건 set_status 를 부른다. 이중 재개
# 방지는 이 cancel 이 아니라 자식 자신의 완료 신호 검사(is_done_signaled)에 근거하므로
# (위 2번 안전장치) 이 순서 교환은 그 계약을 건드리지 않는다.
#
# cancel 과 set_status 사이에서 죽으면 남는 상태는 "자식 cancelled + 부모 = 그 시점의
# status" 다. 그 뒤가 어떻게 되는지는 호출 지점마다 다르다 — 예전 주석이 한 문장으로
# 묶어 "부모 frozen 이라 check 캐치업이 다시 띄우고, 새 화신이 대기 루프 첫 바퀴에서
# 완료 신호를 보고 completed_early 로 수렴한다" 고 일반화했는데, 그 문장은 세 지점을
# 하나로 뭉갠다. 종착점(completed_early)은 앞의 두 지점에서 같지만 **거기 도달하는
# 기전이 다르고, 한쪽은 쿼터를 태운다** — 이 스킬이 아끼려는 바로 그 자원이다:
#   - 프로브 구간 분기(아래 `is_done_signaled` → completed_early): 부모가 아직 frozen
#     이라(`set_status "running"` 앞) cmd_check 가 캐치업한다(freeze.sh 의 cmd_check 는
#     `[ "$status" = "frozen" ] || continue`). 새 화신은 **대기 루프 첫 바퀴에서**
#     is_done_signaled 가 참이라 즉시 completed_early 로 수렴한다 — 프로브를 태우지
#     않는다(실측: claude 호출 0회). 위 일반화가 맞는 유일한 지점이다.
#   - ledger 완료 게이트 분기(아래 `ledger_complete` → completed_early): 부모가 frozen
#     이라 캐치업되는 것까지는 같지만, **대기 루프에서 수렴하지 않는다**. 이 게이트는
#     의도적으로 done 마커를 쓰지 않으므로(바로 아래 게이트 주석 참고) 새 화신에게
#     is_done_signaled 는 거짓이고, 대기 루프가 조기 종료할 근거가 아예 없다.
#     실제 경로는 이렇다(실측 확인 — 크래시 직후 상태를 직접 구성해 thaw 를 다시 띄웠다):
#       땡이 이미 지났으므로 대기 루프를 첫 바퀴에 그냥 통과(remain<=0 → break)
#         → **haiku 프로브를 1회 태운다**(프로브 루프도 신호를 못 보므로 정상 진행)
#         → 체인 블록이 다음 창을 다시 선무장한다(그리고 곧 다시 cancel 한다)
#         → 그 다음에야 ledger_complete 가 다시 참이 되어 completed_early.
#     종착점은 같지만 프로브 1회 + 재무장 1회가 추가로 든다. 재개(전체 대화 복원)를
#     막는 게 이 게이트의 목적이고 그건 지켜지므로 손해는 프로브 몇 토큰에 그친다 —
#     다만 "대기 루프 첫 바퀴에서 수렴한다" 는 서술을 이 분기에 적용하면 거짓이다.
#   - 재개 이후 지점(맨 아래 `is_done_signaled && release_next_job` → done/failed):
#     부모가 이미 running 이다. cmd_check 는 running 을 재기동하지 않으므로 부모는
#     영구히 running 으로 남는다 — 캐치업 자체가 일어나지 않는 지점이다. 동작 위험은
#     없다: 재개는 이미 끝났고 자식은 cancelled 라 아무도 다시 뜨지 않는다. 남는 손해는
#     status 표시가 영구히 부정확해지는 것뿐이다.
#
# is_done_signaled 에서 실제로 버티는 마커는 자식의 job 마커(DONE_MARK)가 아니라 handoff
# 로 키잉된 마커(HANDOFF_MARK)다 — 이 문장을 job 마커로 적어두면 다음 사람이 근거를
# 잘못 짚는다(그래서 고쳤다). 근거는 job 마커의 쓰기 범위다: job 마커는 `freeze.sh done`
# 호출 시점에 이미 활성(frozen|running)이던 예약에만 쓰인다(freeze.sh:cmd_done 의 루프).
# 그래서 done 이 NEXT_JOB 이 태어나기 "전"에 불린 경우 자식에겐 job 마커가 아예 없고,
# 남는 건 handoff 마커 하나뿐이다.
#
# 코드 사실로서 cmd_done 은 handoff 마커를 (a) 활성 예약 매칭 여부와 무관하게 `if` 밖에서,
# (b) 매칭 0건일 때 내는 `return 1` 보다 먼저 쓴다. 그 위치는 그대로 두는 게 맞다.
# 다만 절 (a) 는 **지금 도달 가능한 파손 경로의 방어가 아니라 방어적 여유분**이다.
# 예전 주석은 "이 두 가지가 깨지면 이중 재개가 조용히 살아난다" 고 단언했는데 그 시나리오는
# 재현되지 않았다 — 계약 위반 변이 2종(E: 마커를 marked>0 일 때만 쓴다, F: 마커를
# return 1 뒤로 옮긴다)을 만들어 프로브 구간에서 done 을 부르게 했더니, 그 시점 부모가
# 아직 frozen 이라(thaw 는 그 뒤에야 running 으로 간다) done 이 언제나 활성 예약 1건을
# 매칭해 marked=1 을 냈다. control/E/F 세 조건의 동작이 동일했고(--resume 0회) 전체
# 스위트도 E·F 모두 녹색이었다. 즉 절 (a) 가 load-bearing 인 도달 가능한 상태를 구성하지
# 못했다. 이 반증 기록을 남기는 이유는 하나다 — 다음 사람이 같은 검증을 처음부터 다시
# 하지 않도록. 절 (a) 를 지우고 싶으면 먼저 그 도달 가능한 상태를 실제로 구성해 보여라.
release_next_job() {
  [ -n "$NEXT_JOB" ] || return 0
  if bash "$SCRIPT_DIR/freeze.sh" cancel "$NEXT_JOB" >> "$DIR/thaw.log" 2>&1; then
    echo "[$(date '+%F %T')] 선무장한 다음 창 해제: $NEXT_JOB"
  else
    echo "[$(date '+%F %T')] WARN: 다음 창 해제 실패 — job=$NEXT_JOB. 자식은 자기 대기 루프에서 완료 마커를 보고 스스로 종료한다: $DIR/thaw.log" >&2
  fi
  return 0
}

# 프로브를 지나오는 동안(위 2번 구간) 완료 신호가 도착했을 수 있다 — 프로브 루프는
# 매 시도 "시작 전"에만 신호를 보므로, 마지막 시도가 성공해 루프를 빠져나온
# 바로 그 순간에 도착한 신호는 아직 아무도 확인하지 않았다. 여기서 재개를 부르기
# 직전에 한 번 더 확인해, 이미 끝난 작업을 전체 대화 재개로 다시 여는 사고를 막는다.
if is_done_signaled; then
  release_next_job          # status 전환보다 먼저 — release_next_job 주석 참고
  set_status "completed_early"
  echo "[$(date '+%F %T')] 완료 신호 감지(프로브 구간) — 재개 생략"
  exit 0
fi

# ledger 완료 게이트는 여기(재개 직전) 딱 한 곳에만 건다 — 대기 루프(1번)나 프로브
# 루프(2번)에는 일부러 넣지 않았다. 그 구간은 원 세션이 아직 일하는 중일 수 있고,
# 1단계 항목을 다 체크한 뒤 2단계 항목을 아직 적지 않은 순간이 "남은 항목 0" 으로
# 보인다 — 그 타이밍에 예약을 풀면 정작 한도에 막히는 순간 예약이 없어져, 이 스킬이
# 존재하는 이유 자체가 무너진다. 반면 여기는 대기·프로브를 다 지나 원 세션이 이미
# 끝났거나 죽은 시점이라, 남은 항목이 없으면 재개는 순전한 낭비다.
# done 마커는 일부러 쓰지 않는다 — 오판정이면 그 handoff 를 참조하는 모든 예약이
# 영구히 무력화된다(마커를 지우지 않는 설계, freeze.sh:cmd_done 참고). 영향 범위를
# 자기 자신의 상태와 자기가 선무장한 다음 창(NEXT_JOB)까지로만 묶어둔다.
if ledger_complete; then
  release_next_job          # status 전환보다 먼저 — 위 완료 신호 분기와 같은 이유
  set_status "completed_early"
  echo "[$(date '+%F %T')] 원장에 남은 단계 없음 — 재개 생략 (ledger 완료 게이트)"
  exit 0
fi

set_status "running"
echo "[$(date '+%F %T')] 재개: session=$SESSION cwd=$CWD mode=$MODE chain_left=$CHAIN_LEFT"
cd "$CWD" || { set_status "failed"; exit 1; }

if [ "$MODE" = "ledger" ]; then
  # ledger 모드 — 대화 전체를 복원하는 대신, 원장 한 장만 실은 신선한 세션을 띄운다.
  # 프롬프트는 짧게 유지한다: 실제 지시 내용은 원장 파일 안에 있다.
  "$CLAUDE_BIN" -p --permission-mode "$PERM" \
    "땡 — freeze 스킬(ledger 모드)로 예약된 재개다. 대화 문맥이 전혀 없다 — $HANDOFF (wf ledger) 가 유일한 명세다. 이 파일을 읽고 '## 워크플로우 런' 에 등록된 journal.jsonl 을 확인해 이미 끝난(result 줄이 있는) agent 호출은 건너뛰고, 남은 단계를 이어서 완료하는 연속 스크립트를 새로 작성해 돌려라. 새 워크플로우를 등록하기 전에 먼저 'bash ~/.claude/skills/freeze/scripts/wfledger.sh set-session --ledger $HANDOFF --cwd $CWD' 로 원장의 session 필드를 지금 이 세션으로 갱신해라 — 원장의 session 은 이전(한도에 막힌) 세션 UUID 로 고정돼 있어서, 갱신 없이 wfledger.sh run 을 부르면 journal/script 경로가 존재하지 않는 옛 세션 디렉토리로 계산된다. 끝나면 원장의 단계 체크박스를 갱신하고 '## 재개 결과' 섹션에 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}${DONE_NOTE}" \
    > "$DIR/resume-output.txt" 2>&1
  rc=$?
else
  "$CLAUDE_BIN" -p --resume "$SESSION" --permission-mode "$PERM" \
    "땡 — freeze 스킬로 예약된 재개다. $HANDOFF 를 읽고 중단된 작업을 이어서 완료해줘. 끝나면 같은 파일 하단에 '## 재개 결과' 섹션으로 한 일과 검증 결과를 기록해줘.${CHAIN_NOTE}${DONE_NOTE}" \
    > "$DIR/resume-output.txt" 2>&1
  rc=$?
fi

# 완료 신호가 보이면 미리 걸어둔 다음 창은 필요 없다 — 조용히 해제한다.
# 여기도 아래 set_status 보다 먼저다(원래도 그랬다 — release_next_job 주석의 불변식이
# 이 지점에서도 성립해야 "부모가 done ⇒ 자식은 이미 해제됨" 이 한 가지 규칙으로 읽힌다).
# (release_next_job 은 NEXT_JOB 이 비면 아무것도 하지 않고 바로 돌아온다)
is_done_signaled && release_next_job

if [ "$rc" = 0 ]; then set_status "done"; else set_status "failed"; fi
echo "[$(date '+%F %T')] 재개 종료 rc=$rc — 출력: $DIR/resume-output.txt"
exit "$rc"
