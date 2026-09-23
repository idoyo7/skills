#!/usr/bin/env bash
# _donecheck.sh — 예약이 이미 취소됐거나 완료됐는지 판정하는 공용 함수. source 전용,
# 단독 실행하지 않는다. _node.sh 가 먼저 source 돼 있어야 한다(sha256 폴백이 node 를 쓴다).
#
# 배경(codex 리뷰 BLOCKER C) — bash 경로(thaw.sh 의 run_probe)는 매 시도 앞에서 취소와
# 완료 신호를 둘 다 본다. codex 경로(codex-wake.sh → do-resume.sh)는 그걸 보지 않아서,
# codex 안에서 기본 최대 3시간을 보내는 동안 취소·완료된 예약이 그대로 재개를 강행했다
# (--waker codex 예약은 사실상 취소가 안 됨). 이 파일은 do-resume.sh 가 claude 를,
# codex-wake.sh 가 codex 를 부르기 "직전에" 같은 규칙으로 검사할 수 있게 함수를 공유한다.
#
# 판정 규칙은 thaw.sh 의 is_done_signaled 와 반드시 같아야 한다(별도 프로세스로 나뉘어
# 있어 자동으로 동기화되지 않는다 — thaw.sh 쪽을 고치면 여기도 같이 고쳐야 한다):
#   - done 마커(job 자신의 상태 디렉토리 안 <dir>/done) 가 있으면 완료.
#   - handoff 해시로 키잉된 완료 신호(<state_root>/done-by-handoff/<sha256>) 가 있고,
#     그 신호 시각이 이 예약의 created_at 보다 오래되지 않았으면 완료.
# 취소 판정(status=cancelled)은 reservation.json 을 그 자리에서 다시 읽어 확인한다 —
# codex-wake.sh/do-resume.sh 는 이미 각자 reservation.json 을 읽어뒀지만, 시간이 걸리는
# codex exec 호출 전후로 최신 상태를 다시 확인해야 하므로 캐시된 값을 쓰지 않는다.

freeze_sha256_hex() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | cut -d' ' -f1
  else
    node -e 'console.log(require("crypto").createHash("sha256").update(process.argv[1]).digest("hex"))' -- "$1"
  fi
}

# freeze_reservation_blocked <dir> <state_root> <handoff> <created_at>
# 반환값 0 이면 취소되었거나 완료된 상태(=재개를 부르면 안 됨) — stdout 에 "cancelled"
# 또는 "done" 을 남겨 호출자가 verdict 의 reason 필드 등에 그대로 쓸 수 있게 한다.
# 반환값 1 이면 진행해도 안전한 상태.
freeze_reservation_blocked() {
  local dir="$1" state_root="$2" handoff="$3" created_at="$4"
  local res="$dir/reservation.json"
  if [ -f "$res" ]; then
    local status
    status=$(node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1])).status ?? "")}catch{console.log("")}' "$res")
    if [ "$status" = "cancelled" ]; then
      echo "cancelled"
      return 0
    fi
  fi
  [ -f "$dir/done" ] && { echo "done"; return 0; }
  local handoff_mark="$state_root/done-by-handoff/$(freeze_sha256_hex "$handoff")"
  [ -f "$handoff_mark" ] || return 1
  local sig_ts
  sig_ts=$(head -1 "$handoff_mark" 2>/dev/null || true)
  [[ "$sig_ts" =~ ^[0-9]+$ ]] || return 1
  [ -n "$created_at" ] || created_at=0
  if [ "$sig_ts" -ge "$created_at" ]; then
    echo "done"
    return 0
  fi
  return 1
}
