#!/usr/bin/env bash
# freeze — 세션 예약. 얼음(reserve)과 상태 관리(status/cancel/check/estimate)를 담당한다.
# 재개(땡) 실행은 thaw.sh 가 한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

usage() {
  cat <<'EOF'
freeze.sh <command> [args]

  estimate                          현재 5시간 윈도우의 땡(리셋) 시각을 epoch 로 출력. 추정 불가면 UNKNOWN.
  reserve --at <시각> --cwd <dir> --handoff <path> [--session <uuid>] [--job <name>]
                                    예약을 등록하고 슬리퍼를 기동한다.
                                    <시각>: auto | epoch | +30m | +2h | +90s | HH:MM | ISO8601
  status                            예약 목록과 상태.
  cancel <job>                      예약 취소 (슬리퍼 종료).
  check                             시각이 지났는데 슬리퍼가 죽어 있는 예약을 지금 실행 (캐치업).
EOF
}

# 현재 5시간 사용량 윈도우의 끝(땡)을 구한다.
# 1순위: OMC HUD 가 캐시한 statusline stdin payload 의 rate_limits.five_hour.resets_at (정확값).
# 폴백: transcript 타임스탬프 역산 — ccusage 와 같은 모델(블록 시작 = 첫 활동 정시 내림 + 5h,
# 활동이 블록 끝을 넘으면 다음 블록이 바로 이어진다). 근사라 수 시간 어긋날 수 있다.
cmd_estimate() {
  local hud_cache="${FREEZE_HUD_CACHE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/cache}"
  node - "$PROJECTS_DIR" "$hud_cache" <<'JS'
const fs = require('fs'), path = require('path');
const root = process.argv[2];
const hudCache = process.argv[3];
const nowSec = Date.now() / 1000;

// ---- 1순위: HUD 캐시의 resets_at (Claude Code 가 준 정확값) ----
try {
  const cands = fs.readdirSync(hudCache)
    .filter(f => f.startsWith('stdin.') && f.endsWith('.json'))
    .map(f => path.join(hudCache, f))
    .map(p => ({ p, mtime: fs.statSync(p).mtimeMs / 1000 }))
    .filter(c => c.mtime > nowSec - 6 * 3600)   // 6시간 넘게 묵은 payload 는 다른 윈도우일 수 있음
    .sort((a, b) => b.mtime - a.mtime);
  for (const c of cands) {
    try {
      const at = JSON.parse(fs.readFileSync(c.p, 'utf8'))?.rate_limits?.five_hour?.resets_at;
      if (Number.isFinite(at) && at > nowSec) { console.log(String(Math.floor(at))); process.exit(0); }
    } catch { /* skip */ }
  }
} catch { /* HUD 캐시 없음 → 폴백 */ }

// ---- 폴백: transcript 역산 ----
const now = Date.now() / 1000;
const TS = /"timestamp"\s*:\s*"([^"]+)"/g;

// 파일 앞/뒤 64KB 만 읽어 첫/마지막 timestamp 를 뽑는다 — 대형 transcript 전체 파싱 회피
function edgeTs(file, tail) {
  const size = fs.statSync(file).size;
  const len = Math.min(size, 65536);
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, 'r');
  fs.readSync(fd, buf, 0, len, tail ? size - len : 0);
  fs.closeSync(fd);
  const hits = [...buf.toString('utf8').matchAll(TS)];
  if (!hits.length) return null;
  const t = Date.parse(hits[tail ? hits.length - 1 : 0][1]) / 1000;
  return Number.isFinite(t) ? t : null;
}

const intervals = [];
let dirs = [];
try { dirs = fs.readdirSync(root); } catch { console.log('UNKNOWN'); process.exit(0); }
for (const d of dirs) {
  const dir = path.join(root, d);
  let files = [];
  try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }
  for (const f of files) {
    const p = path.join(dir, f);
    try {
      if (fs.statSync(p).mtimeMs / 1000 < now - 26 * 3600) continue;
      const s = edgeTs(p, false), e = edgeTs(p, true);
      if (s && e && e >= s) intervals.push([s, e]);
    } catch { /* skip */ }
  }
}

if (!intervals.length) { console.log('UNKNOWN'); process.exit(0); }
intervals.sort((a, b) => a[0] - b[0]);
const FIVE_H = 5 * 3600;
let blockStart = null, blockEnd = null;
for (const [s, e] of intervals) {
  if (blockStart === null || s >= blockEnd) {
    blockStart = s - (s % 3600);              // 정시로 내림
    blockEnd = blockStart + FIVE_H;
  }
  while (e >= blockEnd && now >= blockEnd) {  // 연속 사용 → 다음 블록이 바로 이어짐
    blockStart = blockEnd;
    blockEnd += FIVE_H;
  }
}
console.log(blockEnd && now < blockEnd ? String(Math.floor(blockEnd)) : 'UNKNOWN');
JS
}

# --at 인자를 epoch 로 변환
resolve_at() {
  local at="$1" epoch
  case "$at" in
    auto)
      epoch=$(cmd_estimate)
      [ "$epoch" = "UNKNOWN" ] && { echo "ERROR: 땡 시각 추정 실패 — --at 으로 직접 지정 필요" >&2; return 1; }
      ;;
    +*[smh])
      local n=${at#+}; local unit=${n: -1}; n=${n%?}
      case "$unit" in s) epoch=$(( $(date +%s) + n ));; m) epoch=$(( $(date +%s) + n*60 ));; h) epoch=$(( $(date +%s) + n*3600 ));; esac
      ;;
    [0-9][0-9]:[0-9][0-9])
      epoch=$(date -d "$at" +%s)
      [ "$epoch" -le "$(date +%s)" ] && epoch=$(date -d "tomorrow $at" +%s)  # 이미 지난 시각이면 내일
      ;;
    ''|*[!0-9]*)
      epoch=$(date -d "$at" +%s) || { echo "ERROR: 시각 해석 실패: $at" >&2; return 1; }
      ;;
    *)
      epoch="$at"
      ;;
  esac
  echo "$epoch"
}

# cwd 로 현재 세션 uuid 자동 탐지 (해당 프로젝트 디렉토리의 최신 jsonl)
detect_session() {
  local cwd="$1"
  local slug; slug=$(echo "$cwd" | sed 's/[^A-Za-z0-9-]/-/g')
  local dir="$PROJECTS_DIR/$slug"
  [ -d "$dir" ] || { echo "ERROR: 프로젝트 transcript 디렉토리 없음: $dir" >&2; return 1; }
  local latest; latest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$latest" ] || { echo "ERROR: transcript 없음: $dir" >&2; return 1; }
  basename "$latest" .jsonl
}

cmd_reserve() {
  # 기본 bypassPermissions — 무인 재개엔 승인자가 없어 acceptEdits 로는 Bash 가 전부 거부된다(E2E 실측).
  # 사용자 명시 결정(2026-08-17). --permission-mode 로 건별 하향 가능.
  local at="" cwd="" handoff="" session="" job="" perm="bypassPermissions"
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) at="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --handoff) handoff="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      --job) job="$2"; shift 2;;
      --permission-mode) perm="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$at" ] && [ -n "$cwd" ] && [ -n "$handoff" ] || { usage; return 1; }
  [ -f "$handoff" ] || { echo "ERROR: handoff 파일 없음: $handoff" >&2; return 1; }

  local epoch; epoch=$(resolve_at "$at") || return 1
  [ -n "$session" ] || session=$(detect_session "$cwd") || return 1
  [ -n "$job" ] || job="freeze-$(date +%Y%m%d-%H%M%S)"

  local dir="$STATE_ROOT/$job"
  mkdir -p "$dir"
  node -e '
const [p, job, session, cwd, handoff, epoch, perm] = process.argv.slice(1);
require("fs").writeFileSync(p, JSON.stringify({
  job, session_id: session, cwd, handoff,
  resume_at: parseInt(epoch), created_at: Math.floor(Date.now()/1000),
  permission_mode: perm, status: "frozen"
}, null, 2));
' "$dir/reservation.json" "$job" "$session" "$cwd" "$handoff" "$epoch" "$perm"

  setsid nohup "$SCRIPT_DIR/thaw.sh" "$job" >> "$dir/thaw.log" 2>&1 < /dev/null &
  echo $! > "$dir/sleeper.pid"
  echo "얼음 — job=$job session=$session 땡=$(date -d "@$epoch" '+%m/%d %H:%M') ($(( (epoch - $(date +%s)) / 60 ))분 후)"
}

job_field() { node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1]))[process.argv[2]] ?? "")' "$1" "$2"; }

# 프로세스 생존 판정 — kill -0 은 좀비(미리핑)도 살아있다고 답하므로 ps 상태로 본다
pid_alive() {
  local pid="$1" state
  [ -n "$pid" ] || return 1
  state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$state" ] && [ "${state:0:1}" != "Z" ]
}

cmd_status() {
  local found=0
  for r in "$STATE_ROOT"/*/reservation.json; do
    [ -f "$r" ] || continue
    found=1
    local job status epoch pid alive="dead"
    job=$(job_field "$r" job); status=$(job_field "$r" status); epoch=$(job_field "$r" resume_at)
    pid=$(cat "$(dirname "$r")/sleeper.pid" 2>/dev/null || true)
    pid_alive "$pid" && alive="alive"
    printf '%-24s %-8s 땡=%s sleeper=%s\n' "$job" "$status" "$(date -d "@$epoch" '+%m/%d %H:%M')" "$alive"
  done
  [ "$found" = 0 ] && echo "예약 없음"
}

cmd_cancel() {
  local job="$1" dir="$STATE_ROOT/$1"
  [ -f "$dir/reservation.json" ] || { echo "ERROR: 예약 없음: $job" >&2; return 1; }
  local pid; pid=$(cat "$dir/sleeper.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  node -e '
const fs = require("fs"), p = process.argv[1];
const d = JSON.parse(fs.readFileSync(p)); d.status = "cancelled";
fs.writeFileSync(p, JSON.stringify(d, null, 2));
' "$dir/reservation.json"
  echo "취소됨: $job"
}

cmd_check() {
  local now; now=$(date +%s)
  for r in "$STATE_ROOT"/*/reservation.json; do
    [ -f "$r" ] || continue
    local dir status epoch pid
    dir=$(dirname "$r"); status=$(job_field "$r" status); epoch=$(job_field "$r" resume_at)
    [ "$status" = "frozen" ] || continue
    pid=$(cat "$dir/sleeper.pid" 2>/dev/null || true)
    if [ "$now" -ge "$epoch" ] && ! pid_alive "$pid"; then
      echo "캐치업 실행: $(job_field "$r" job)"
      setsid nohup "$SCRIPT_DIR/thaw.sh" "$(job_field "$r" job)" >> "$dir/thaw.log" 2>&1 < /dev/null &
      echo $! > "$dir/sleeper.pid"
    fi
  done
}

case "${1:-}" in
  estimate) cmd_estimate;;
  reserve) shift; cmd_reserve "$@";;
  status) cmd_status;;
  cancel) shift; cmd_cancel "$@";;
  check) cmd_check;;
  *) usage; exit 1;;
esac
