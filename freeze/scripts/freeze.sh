#!/usr/bin/env bash
# freeze — 세션 예약. 얼음(reserve)과 상태 관리(status/cancel/check/estimate)를 담당한다.
# 재개(땡) 실행은 thaw.sh 가 한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
STATE_ROOT="${FREEZE_STATE_DIR:-$HOME/.local/state/freeze}"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

# GNU/BSD 양립 — epoch → 사람이 읽는 포맷. BSD 는 `date -r <epoch>`, GNU 는 `date -d @<epoch>`.
# (GNU 의 `-r` 은 "파일 mtime" 이라 의미가 달라 반드시 분기해야 한다.)
if date -d @0 +%s >/dev/null 2>&1; then _DATE_GNU=1; else _DATE_GNU=0; fi
fmt_epoch() {  # fmt_epoch <epoch> <+strftime>
  if [ "$_DATE_GNU" = 1 ]; then date -d "@$1" "$2"; else date -r "$1" "$2"; fi
}

# handoff 경로를 절대 realpath 로 정규화한다. reserve/arm/done 모두 이 정규화를
# 거쳐 저장·비교하므로, SKILL.md 가 안내하는 상대경로 예약과 절대경로 done 호출이
# 문자열만 달라 서로 못 알아보는 사고를 막는다(major 2). -m 은 대상이 아직 없거나
# 이미 지워졌어도 정규화된 경로를 낸다 — done 이 그런 handoff 도 "대상 없음"으로
# 안전하게 판정할 수 있게.
# realpath 의 -m 은 GNU 확장이라 BSD/macOS realpath 가 거부한다(illegal option -- m).
# 존재하지 않는 경로도 정규화해야 하므로(위 주석) 존재하는 최장 접두부만 realpathSync
# 로 심링크를 풀고 남은 조각을 다시 붙여 -m 과 같은 결과를 낸다.
normalize_handoff() {
  node -e '
const fs = require("fs"), path = require("path");
const abs = path.resolve(process.argv[1]);
let p = abs;
const rest = [];
for (;;) {
  try {
    const real = fs.realpathSync(p);
    console.log(rest.length ? path.join(real, ...rest.slice().reverse()) : real);
    break;
  } catch {
    const parent = path.dirname(p);
    if (parent === p) { console.log(abs); break; }   // 루트까지 못 찾음 — resolve 결과로 만족
    rest.push(path.basename(p));
    p = parent;
  }
}
' -- "$1"
}

# handoff 경로 하나를 하나의 파일명으로 접는다 — done-by-handoff 마커 경로에 쓴다.
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

handoff_hash() { sha256_hex "$1"; }

usage() {
  cat <<'EOF'
freeze.sh <command> [args]

  estimate                          현재 5시간 윈도우의 땡(리셋) 시각을 epoch 로 출력. 추정 불가면 UNKNOWN.
  reserve --at <시각> --cwd <dir> --handoff <path> [--session <uuid>] [--job <name>]
                                    예약을 등록하고 슬리퍼를 기동한다.
                                    <시각>: auto | epoch | +30m | +2h | +90s | HH:MM | ISO8601
                                    [--permission-mode <mode>] 기본 bypassPermissions
                                    [--mode resume|ledger] 기본 resume — 재개 방식(아래 참고)
                                    [--pad <초>] auto 추정에만 기본 300 적용. 명시 시각(epoch/+N/HH:MM/ISO)엔
                                                 --pad 를 직접 줘야만 더해진다(계약 보존).
  arm --cwd <dir> --handoff <path> [--chain-left <n>] [--job <name>]
      [--at <시각>] [--mode resume|ledger] [--pad <초>] [--permission-mode <mode>]
                                    선예약(얼음 대기). 작업 시작 시점에 걸어두고 남은 쿼터를 끝까지 태운다.
                                    한도로 막히면 예약분이 알아서 잇고, 먼저 끝나면 `done` 으로 해제한다.
                                    --chain-left 는 창을 넘겨가며 이어붙일 최대 횟수(기본 2).
                                    --at 기본값은 auto(직접 arm 할 때). 체인 내부 재무장(thaw.sh)은
                                    리셋 경계에서 auto 추정이 UNKNOWN 이 되는 것을 피하려고 명시 epoch 를 넘긴다.
  done --handoff <path>             완료 신호. 이 handoff 로 걸린 활성 예약 전체(체인 중이면 현재 창 +
                                    선무장된 다음 창 모두)에 조용히 종료하라는 신호를 남긴다.
                                    handoff 경로는 절대 realpath 로 정규화해 비교하므로 reserve/arm 때
                                    상대경로를 썼어도 여기선 절대경로로 불러도 된다(그 반대도 동일).
                                    이 handoff 로 걸린 활성 예약이 하나도 없으면 stderr 로 알리고
                                    비영(非零) 종료코드를 낸다 — 자동 호출자가 실패를 감지할 수 있게.
  status                            예약 목록과 상태 (체인 선무장 실패 경고 포함).
  cancel <job>                      예약 취소 (슬리퍼 종료).
  check                             시각이 지났는데 슬리퍼가 죽어 있는 예약을 지금 실행 (캐치업).

두 가지 재개 모드(--mode):
  resume  (기본) — claude -p --resume <세션> 으로 대화 전체를 복원해 이어간다.
  ledger  — 대화를 복원하지 않고, wfledger.sh 로 만든 원장 한 장만 실은 신선한 세션을 띄운다.
            5시간 창을 넘겨 재개하면 캐시 TTL(최대 1시간)이 이미 끝나 대화 전체를
            콜드 리드해야 하는 비용을 피하려는 모드 — freeze/SKILL.md 의 "두 재개 모드" 참고.
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

# --at 인자를 epoch 로 변환.
# pad(초) 계약 — auto 로 추정한 시각에만 기본 300(5분)을 적용한다: 리셋 직후엔
# 아직 한도가 실제로 안 풀렸을 수 있어 추정 오차를 흡수할 여유가 필요해서다.
# epoch/+N/HH:MM/ISO 처럼 사용자가 시각을 직접 지정했을 때는 그 시각 자체가
# 계약이므로 기본 패딩을 붙이지 않는다 — 사용자가 --pad 를 명시로 줬을 때만 더한다.
# (2026-08-24 결정. 이전엔 case 분기 밖에서 무조건 + pad 를 해서 --at 15:00 이
# 15:05 에 뜨는 회귀가 있었다 — freeze/tests/test_freeze.sh 의 "명시 --at 은 pad 미적용" 참고.)
# stdout 에 "epoch effective_pad" 두 값을 공백으로 구분해 낸다 — effective_pad 는
# 호출자가 reservation.json 의 pad 필드(체인 재무장 때 그대로 물려줄 값)로 저장한다.
resolve_at() {
  local at="$1" pad_given="$2" epoch pad
  case "$at" in
    auto)
      epoch=$(cmd_estimate)
      [ "$epoch" = "UNKNOWN" ] && { echo "ERROR: 땡 시각 추정 실패 — --at 으로 직접 지정 필요" >&2; return 1; }
      pad="${pad_given:-300}"
      ;;
    +*[smh])
      local n=${at#+}; local unit=${n: -1}; n=${n%?}
      case "$unit" in s) epoch=$(( $(date +%s) + n ));; m) epoch=$(( $(date +%s) + n*60 ));; h) epoch=$(( $(date +%s) + n*3600 ));; esac
      pad="${pad_given:-0}"
      ;;
    [0-9][0-9]:[0-9][0-9])
      # GNU/BSD 양립 — date -d 대신 node 로 파싱. 오늘 그 시각, 이미 지났으면 다음 날(setDate 로 넘겨 DST 안전).
      epoch=$(node -e '
const [hhmm] = process.argv.slice(1);
const [h, m] = hhmm.split(":").map(Number);
if (h > 23 || m > 59) process.exit(1);   // setHours 는 99:99 를 조용히 롤오버하므로 직접 거른다
const d = new Date();
d.setHours(h, m, 0, 0);
if (d.getTime() <= Date.now()) d.setDate(d.getDate() + 1);
console.log(Math.floor(d.getTime() / 1000));
' -- "$at") || { echo "ERROR: 시각 해석 실패: $at" >&2; return 1; }
      pad="${pad_given:-0}"
      ;;
    ''|*[!0-9]*)
      # GNU/BSD 양립 — date -d 대신 node Date.parse 로 임의 문자열/ISO8601 파싱.
      epoch=$(node -e '
const t = Date.parse(process.argv[1]);
if (!Number.isFinite(t)) process.exit(1);
console.log(Math.floor(t / 1000));
' -- "$at") || { echo "ERROR: 시각 해석 실패: $at" >&2; return 1; }
      pad="${pad_given:-0}"
      ;;
    *)
      epoch="$at"
      pad="${pad_given:-0}"
      ;;
  esac
  # 해석 결과 sanity 검사 — 파싱 사고로 엉뚱한 epoch 가 예약에 박히는 것을 막는다.
  # (Date.parse("-5") → 2001년, 숫자 오타 "5" → 1970년. 둘 다 조용히 통과하면 thaw 가 즉시 깨거나 영원히 잔다.)
  case "$epoch" in ''|*[!0-9]*) echo "ERROR: 시각 해석 실패: $at" >&2; return 1;; esac
  local now; now=$(date +%s)
  if [ "$epoch" -lt $(( now - 300 )) ] || [ "$epoch" -gt $(( now + 30*86400 )) ]; then
    echo "ERROR: 땡 시각이 비정상 — $at → $(fmt_epoch "$epoch" '+%F %T'). 지금부터 30일 이내여야 한다" >&2
    return 1
  fi
  echo "$(( epoch + pad )) $pad"
}

# cwd 로 현재 세션 uuid 자동 탐지 (해당 프로젝트 디렉토리의 최신 jsonl)
#
# ⚠ 이 함수는 반드시 **명령 치환**(`x=$(detect_session ...)`) 또는 `&&`/`||` 문맥에서만
# 불러라. 평문 statement 로 부르면(예: `detect_session "$cwd" > "$f"`) 큰 프로젝트
# 디렉토리에서 그 자리에서 죽는다 — 실측 10/10, rc=141.
#
# 근거: 아래 `ls -t "$dir"/*.jsonl | head -1` 은 SIGPIPE 를 실제로 맞는다. head -1 은
# 첫 줄을 읽고 즉시 파이프 읽는 쪽을 닫고, ls 는 줄마다 write 하므로 출력이 파이프
# 용량(이 머신 실측 65536바이트)을 넘으면 남은 write 가 EPIPE/SIGPIPE 를 맞는다
# (3000파일·852KB 디렉토리에서 PIPESTATUS[0]=141, 10/10). pipefail 이 그 141 을
# `latest=$(...)` 대입의 rc 로 올린다.
#
# 지금 도달 불가인 이유는 두 겹인데, **둘 다 흔히 오해되는 것과 다르다**:
#   1) 이 파이프라인은 함수의 마지막 명령이 아니다 — 끝은 basename 이라 141 이 함수의
#      rc 로 새어나가지 않는다. wfledger.sh 의 ledger_field() 는 같은 파이프 모양인데
#      파이프가 함수의 마지막이라 141 이 그대로 함수 rc 가 되고, 그쪽은 맨 대입 호출에서
#      실제로 죽는다(30/30). 그 함수에도 같은 성격의 주석을 달아뒀다 — 한쪽만 고치지 마라.
#   2) 호출 지점 둘(아래 cmd_reserve 의 resume/ledger 분기)이 모두 `$( )` 안이고, 이
#      머신의 bash(3.2.57, macOS 시스템 bash)는 **명령 치환 서브셸 안에서 set -e 를
#      강제하지 않는다**(실측 대조: 같은 함수를 평문으로 부르면 errexit 가 걸려 죽고,
#      `$( )` 안에서 부르면 내부 대입 rc 가 141 이어도 본문이 끝까지 돈다). 그래서 141 이
#      서브셸 안에 갇힌다.
#      → 따라서 `session=$(detect_session ...)` 는 뒤에 `|| return 1` 이 있든 없든 죽지
#        않는다(뒤를 떼어낸 변이로 reserve 15/15 rc=0, 현재 형태도 15/15 rc=0).
#        지금 지켜주는 건 `||` 가 아니라 명령 치환 서브셸이다. 이 차이를 헷갈리면
#        "`||` 만 붙여두면 안전하다" 는 잘못된 근거를 믿게 된다.
#   3) 실 데이터 여유도 크다 — 이 머신에서 가장 큰 프로젝트 디렉토리의 `ls -t` 출력이
#      2986바이트, 임계의 4.6% 다.
#
# 그래서 코드는 그대로 둔다. 다만 위 조건 중 하나만 어긋나면 곧바로 도달한다:
#   - 새 호출 지점이 명령 치환 밖(평문 statement)으로 들어온다 → 10/10 사망.
#   - basename 을 걷어내 파이프라인이 함수의 마지막이 된다 → ledger_field 와 같은
#     30/30 사망 경로가 된다.
#   - 명령 치환 안에서도 set -e 를 강제하는 bash 로 올라간다 → 이 머신엔 3.2 뿐이라
#     확인하지 못했다. 그 환경에선 지금의 명령 치환 호출도 위험해진다.
detect_session() {
  local cwd="$1"
  local slug; slug=$(echo "$cwd" | sed 's/[^A-Za-z0-9-]/-/g')
  local dir="$PROJECTS_DIR/$slug"
  [ -d "$dir" ] || { echo "ERROR: 프로젝트 transcript 디렉토리 없음: $dir" >&2; return 1; }
  local latest; latest=$(ls -t "$dir"/*.jsonl 2>/dev/null | head -1)
  [ -n "$latest" ] || { echo "ERROR: transcript 없음: $dir" >&2; return 1; }
  basename "$latest" .jsonl
}

# setsid 대체 — node child_process.spawn 의 detached:true 가 POSIX 에서 setsid(2) 를 호출해
# 세션을 분리한다. macOS 에는 setsid 커맨드가 없어 이 방식으로 통일 (양 플랫폼 공통, PID 도 정확).
# thaw.sh 를 bash 로 명시 실행 — 실행 권한(+x)에 의존하지 않는다.
spawn_sleeper() {  # spawn_sleeper <job> <dir>
  local job="$1" dir="$2"
  node -e '
const { spawn } = require("child_process");
const fs = require("fs");
const [script, job, log] = process.argv.slice(1);
const out = fs.openSync(log, "a");
const child = spawn("bash", [script, job], { detached: true, stdio: ["ignore", out, out] });
child.unref();
console.log(child.pid);
' "$SCRIPT_DIR/thaw.sh" "$job" "$dir/thaw.log" > "$dir/sleeper.pid"
}

cmd_reserve() {
  # 기본 bypassPermissions — 무인 재개엔 승인자가 없어 acceptEdits 로는 Bash 가 전부 거부된다(E2E 실측).
  # 사용자 명시 결정(2026-08-17). --permission-mode 로 건별 하향 가능.
  # pad 기본값은 여기서 정하지 않는다 — auto 냐 명시 시각이냐에 따라 resolve_at 이 결정한다.
  # mode: resume(기본, 대화 전체 --resume) | ledger(원장 한 장만 실은 신선한 세션).
  local at="" cwd="" handoff="" session="" job="" perm="bypassPermissions" pad="" mode="resume" created_at=""
  local chain="" chain_left="" via=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --at) at="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --handoff) handoff="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      --job) job="$2"; shift 2;;
      --permission-mode) perm="$2"; shift 2;;
      --pad) pad="$2"; shift 2;;
      --mode) mode="$2"; shift 2;;
      # 내부 전용(문서화 안 함) — cmd_arm 이 체인 정보를 넘길 때만 쓴다. 예전엔 arm 이
      # reserve 가 돌아온 뒤 같은 파일에 두 번째 read-modify-write 로 이 세 필드를
      # 심었는데, 그 쓰기가 이미 기동한 슬리퍼의 첫 읽기와 겹치는 레이스였다(blocker,
      # _node.sh (d) 주석 참고). 인자로 받아 아래 단일 쓰기에 합친다.
      --chain) chain="$2"; shift 2;;
      --chain-left) chain_left="$2"; shift 2;;
      --via) via="$2"; shift 2;;
      # 내부 전용(문서화 안 함) — thaw.sh 의 체인 재무장이 부모 예약의 created_at 을
      # 자식에게 그대로 물려줄 때만 쓴다. major 3: handoff 로 키잉된 완료 신호를
      # "이 예약의 created_at 보다 오래됐으면 무시" 로 걸러내려면, 체인으로 이어지는
      # 자식 예약도 부모와 같은 created_at 을 가져야 부모가 이미 받은 신호를 본다.
      # 단위는 밀리초(Date.now()) — 초 단위였을 때 같은 handoff 를 빠르게 재사용하는
      # 무관한 예약들이 같은 초에 몰려 오판정을 낸 사고가 있었다(테스트 실측).
      --created-at) created_at="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$at" ] && [ -n "$cwd" ] && [ -n "$handoff" ] || { usage; return 1; }
  [ -f "$handoff" ] || { echo "ERROR: handoff 파일 없음: $handoff" >&2; return 1; }
  case "$mode" in resume|ledger) ;; *) echo "ERROR: --mode 는 resume|ledger 만 지원: $mode" >&2; return 1;; esac
  handoff=$(normalize_handoff "$handoff")

  local resolved epoch effective_pad
  resolved=$(resolve_at "$at" "$pad") || return 1
  read -r epoch effective_pad <<< "$resolved"
  if [ -z "$session" ]; then
    if [ "$mode" = "resume" ]; then
      # resume 모드는 --resume <세션> 이 계약이므로 세션 탐지 실패는 치명적.
      session=$(detect_session "$cwd") || return 1
    else
      # ledger 모드는 대화를 복원하지 않으므로 세션 UUID 가 없어도 재개 자체는 된다
      # (원장의 session: 필드는 wfledger.sh run/journal 의 경로 계산에만 쓰인다 —
      # 없으면 그 필드가 비고, 재개 세션이 wfledger.sh set-session 으로 채우면 된다).
      # 그래서 프로젝트 transcript 디렉토리가 아직 없어도(신규 cwd) reserve 자체는 죽지 않는다.
      session=$(detect_session "$cwd" 2>/dev/null) || session=""
    fi
  fi
  [ -n "$job" ] || job="freeze-$(date +%Y%m%d-%H%M%S)"

  local dir="$STATE_ROOT/$job"
  mkdir -p "$dir"
  # 이전에 같은 job 이름을 썼다가 남은 완료 마커가 있으면 지운다 — done 마커는
  # 이 job 디렉토리 안에만 있으므로(아래 cmd_done 참고) 다른 job 을 건드릴 일이 없다.
  rm -f "$dir/done"
  # major 1 — 같은 job 이름으로 재예약하면 이전 슬리퍼가 살아있는 채로 새 슬리퍼가
  # 하나 더 뜬다(sleeper.pid 는 마지막 것만 남으므로 이전 것은 고아가 되어 나중에
  # 자기 몫의 재개를 따로 부른다 — 재현: reserve 를 짧은 간격으로 두 번 부르면
  # calls.log 에 재개 호출이 서로 다른 pid 로 두 줄 찍힌다). 새 슬리퍼를 띄우기
  # 전에 기존 sleeper.pid 가 살아있으면 정리한다.
  reap_stale_sleeper "$dir" "$job"
  # reservation.json 은 여기서 딱 한 번만 쓴다. 슬리퍼는 이 유일한 쓰기가 끝난 뒤에
  # 띄우고(아래 spawn_sleeper), 체인 필드도 이 쓰기에 함께 싣는다 — 슬리퍼가 기동해서
  # field() 로 이 파일을 읽는 동안 다른 쓰기가 겹칠 창 자체를 없앤다.
  # 필드 이름·값·JSON 키 순서는 예전(reserve 가 쓰고 arm 이 뒤에 세 필드를 덧붙인 형태)과
  # 같게 유지한다 — 기존 테스트가 이 필드들을 단언한다.
  node -e "$FREEZE_JS_ATOMIC"'
const [p, job, session, cwd, handoff, epoch, perm, mode, pad, createdAt, chain, chainLeft, via] = process.argv.slice(1);
const d = {
  job, session_id: session, cwd, handoff,
  resume_at: parseInt(epoch), created_at: createdAt ? parseInt(createdAt) : Date.now(),
  permission_mode: perm, mode, pad: parseInt(pad), status: "frozen"
};
// 빈 문자열이면 필드를 아예 만들지 않는다 — reserve 로 걸린 예약에는 예전처럼 chain 계열
// 필드가 없어야 한다(thaw.sh 가 그 부재로 "체인 아님"을 판정한다).
// "0" 은 빈 문자열이 아니므로 --chain-left 0 은 그대로 0 으로 들어간다.
if (chain) d.chain = parseInt(chain);
if (chainLeft) d.chain_left = parseInt(chainLeft);
if (via) d.via = via;
writeJsonAtomic(p, d);
' "$dir/reservation.json" "$job" "$session" "$cwd" "$handoff" "$epoch" "$perm" "$mode" "$effective_pad" \
  "$created_at" "$chain" "$chain_left" "$via"

  spawn_sleeper "$job" "$dir"
  echo "얼음 — job=$job session=${session:-(미탐지)} mode=$mode 땡=$(fmt_epoch "$epoch" '+%m/%d %H:%M') ($(( (epoch - $(date +%s)) / 60 ))분 후)"
}

# 읽기는 thaw.sh 의 field() 와 같은 공용 스크립트를 쓴다 — 파싱 실패 시 짧게 재시도하고,
# 끝까지 실패하면 빈 문자열이 아니라 비영 종료코드를 낸다(_node.sh (d) 참고).
# set -e 아래라 호출자는 조용한 빈 값 대신 즉시 실패를 본다.
job_field() { node -e "$FREEZE_JS_FIELD" "$1" "$2"; }

# 프로세스 생존 판정 — kill -0 은 좀비(미리핑)도 살아있다고 답하므로 ps 상태로 본다
pid_alive() {
  local pid="$1" state
  [ -n "$pid" ] || return 1
  state=$(ps -o state= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$state" ] && [ "${state:0:1}" != "Z" ]
}

# major 1 — 새 슬리퍼를 띄우기 전에 같은 job 디렉토리의 기존 sleeper.pid 가
# 살아있으면 정리한다. 죽어 있으면(정상 종료·크래시 등) 조용히 넘어간다.
# pid 재사용 오인을 막으려고 죽이기 전에 프로세스의 실제 커맨드라인이
# "thaw.sh <이 job>" 인지 확인한다 — OS 가 그 사이 이 pid 를 무관한 프로세스에
# 재할당했다면(드물지만 가능) 그 프로세스는 건드리지 않는다.
reap_stale_sleeper() {
  local dir="$1" job="$2" old_pid args
  old_pid=$(cat "$dir/sleeper.pid" 2>/dev/null || true)
  [ -n "$old_pid" ] || return 0
  pid_alive "$old_pid" || return 0
  args=$(ps -o args= -p "$old_pid" 2>/dev/null || true)
  case "$args" in
    *thaw.sh*)
      # 마지막 인자가 정확히 이 job 이름인지 확인 — "dj" 재예약이 "dj2" 슬리퍼를
      # 오인해서 죽이는 것을 막는다.
      if [ "${args##* }" = "$job" ]; then
        kill "$old_pid" 2>/dev/null || true
        echo "재예약 — 이전 슬리퍼 종료: job=$job pid=$old_pid" >&2
      fi
      ;;
  esac
}

cmd_status() {
  local found=0
  for r in "$STATE_ROOT"/*/reservation.json; do
    [ -f "$r" ] || continue
    found=1
    local job status epoch pid alive="dead" warn
    job=$(job_field "$r" job); status=$(job_field "$r" status); epoch=$(job_field "$r" resume_at)
    pid=$(cat "$(dirname "$r")/sleeper.pid" 2>/dev/null || true)
    pid_alive "$pid" && alive="alive"
    printf '%-24s %-8s 땡=%s sleeper=%s\n' "$job" "$status" "$(fmt_epoch "$epoch" '+%m/%d %H:%M')" "$alive"
    warn=$(job_field "$r" chain_warning)
    [ -n "$warn" ] && printf '  경고: %s\n' "$warn"
  done
  [ "$found" = 0 ] && echo "예약 없음"
  return 0   # found=1 일 때 && 단락이 exit 1 로 새는 것 방지
}

cmd_cancel() {
  local job="$1" dir="$STATE_ROOT/$1"
  [ -f "$dir/reservation.json" ] || { echo "ERROR: 예약 없음: $job" >&2; return 1; }
  local pid; pid=$(cat "$dir/sleeper.pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
  node -e "$FREEZE_JS_ATOMIC"'
const fs = require("fs"), p = process.argv[1];
const d = JSON.parse(fs.readFileSync(p)); d.status = "cancelled";
writeJsonAtomic(p, d);
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
      spawn_sleeper "$(job_field "$r" job)" "$dir"
    fi
  done
}

# arm — 작업 시작 시점에 미리 거는 예약.
# reserve 와 다른 점은 둘: 땡 시각 기본값이 auto 고(--at 으로 오버라이드 가능 —
# thaw.sh 의 체인 내부 재무장이 리셋 경계의 estimate=UNKNOWN 을 피하려고 쓴다),
# 체인 횟수를 심는다. 이전 완료 마커 제거는 cmd_reserve 가 job 디렉토리 단위로
# 알아서 한다(handoff 가 아니라 job 으로 스코프돼 있어 다른 job 신호를 안 건드린다).
#
# job 이름은 여기서 먼저 정하고 반드시 --job 으로 reserve 에 넘긴다 — reserve 가
# 자체적으로 기본 이름을 생성하게 두면(같은 초에 여러 세션이 동시에 arm 할 때)
# "가장 최근 수정된 reservation.json" 을 ls -t 로 고르는 식의 사후 추정이 필요해지고,
# 그러면 동시에 도는 다른 잡의 reservation.json 을 잘못 골라 체인 정보를 덮어쓸 수 있다.
# job 이름을 먼저 확정해두면 그런 추정 자체가 필요 없다.
cmd_arm() {
  local cwd="" handoff="" job="" chain_left="2" perm="bypassPermissions" pad="" mode="resume" at="auto" session="" created_at=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) cwd="$2"; shift 2;;
      --handoff) handoff="$2"; shift 2;;
      --job) job="$2"; shift 2;;
      --chain-left) chain_left="$2"; shift 2;;
      --permission-mode) perm="$2"; shift 2;;
      --pad) pad="$2"; shift 2;;
      --mode) mode="$2"; shift 2;;
      --at) at="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      --created-at) created_at="$2"; shift 2;;  # 내부 전용 — cmd_reserve 주석 참고
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$cwd" ] && [ -n "$handoff" ] || { usage; return 1; }
  [ -n "$job" ] || job="freeze-$(date +%Y%m%d-%H%M%S)-$$"
  local -a extra=()
  [ -n "$pad" ] && extra+=(--pad "$pad")
  [ -n "$session" ] && extra+=(--session "$session")
  [ -n "$created_at" ] && extra+=(--created-at "$created_at")
  # macOS 기본 bash 는 3.2 — set -u 아래서 빈 배열의 "${extra[@]}" 를 unbound variable 로
  # 터뜨린다(bash 4.4 에서 고쳐진 동작). arm 을 --pad/--session/--created-at 없이 부르면
  # extra 가 비므로 항상 이 경로를 탄다. ${arr[@]+...} 로 "비었으면 아무것도 전개 안 함"을 명시한다.
  # 체인 정보는 reserve 에 인자로 넘겨 reservation.json 의 단일 쓰기에 함께 싣는다.
  # 예전엔 reserve 가 돌아온 뒤(=슬리퍼가 이미 뜬 뒤) 같은 파일에 두 번째
  # read-modify-write 로 심었는데, writeFileSync 의 truncate~write 창이 슬리퍼의 첫
  # field() 읽기와 겹쳐 잘린 JSON 을 읽히는 레이스였다(blocker — arm 회당 재현율 약 3%,
  # _node.sh (d) 주석에 측정치와 파급 경로). 여기서 파일을 다시 열지 않는 것 자체가
  # 그 레이스의 수정이므로, 편의를 이유로 쓰기를 되살리지 마라.
  cmd_reserve --at "$at" --cwd "$cwd" --handoff "$handoff" --permission-mode "$perm" \
    --job "$job" --mode "$mode" --chain 1 --chain-left "$chain_left" --via arm \
    ${extra[@]+"${extra[@]}"} || return 1
  echo "무장 완료 — job=$job 남은 쿼터를 계속 쓰다가 막히면 예약분이 잇는다 (체인 ${chain_left}회). 먼저 끝나면: freeze.sh done --handoff $handoff"
}

# done — 완료 신호. 이 handoff 를 참조하는 "활성"(frozen|running) 예약 전부에 신호를 남긴다.
# 마커는 handoff 옆이 아니라 각 job 자신의 상태 디렉토리(<job>/done) 안에 쓴다 —
# 체인 중엔 같은 handoff 를 참조하는 예약이 두 개(지금 창 + 선무장된 다음 창)
# 동시에 활성일 수 있는데, 이 둘 다에 신호를 남겨야 "지금 창이 방금 끝났으니
# 다음 창은 필요 없다"는 뜻이 두 안전장치(thaw.sh 의 명시적 cancel + 다음 창
# 자신의 대기 루프)에 전부 전달된다. handoff 를 우연히 공유하는 서로 무관한
# 다른 세션의 예약까지 같이 깨울 위험은 남지만, 이건 job 이 아니라 handoff 만
# 아는 호출자(재개 세션)의 입력 자체가 가진 모호함이지 이 함수가 만드는 버그는
# 아니다 — 예전처럼 "무관한 예약을 지운다" 가 아니라 "무관한 예약에도 완료를
# 알린다" 로 실패 방향이 훨씬 덜 파괴적으로 바뀌었을 뿐이다.
#
# major 3 — 위 job 마커는 "호출 시점에 이미 존재하는" 예약에만 남는다. 체인 재무장은
# thaw.sh 가 재개를 부르기 "전에" 다음 창을 미리 거는데, 그 사이(무장 직후~재개 직전)
# thaw 프로세스가 죽으면 다음 창은 아무 마커도 못 받은 채 자기 차례에 깨어나 이미
# 끝난 작업을 다시 연다. 그래서 handoff 로 키잉된 신호도 함께 남긴다 — job 이 아니라
# handoff 해시로 경로가 정해지므로 "이 job 이 호출 시점에 존재했는가"와 무관하게,
# 나중에 태어난 예약도 자기 대기 루프에서 이 파일을 그냥 찾아서 본다.
#
# 아래 handoff 마커 쓰기의 위치는 이렇게 고정돼 있다 — (a) 활성 예약 매칭 여부와
# 무관하게 `if` 밖에서, (b) 매칭 0건일 때 내는 return 1 보다 **먼저** 쓴다. 이 위치는
# 그대로 두는 게 맞다. 다만 절 (a) 가 무엇을 막는지는 정확히 적어야 한다: 절 (b) 는
# "매칭 0건이어도 아직 태어나지 않은 다음 창에 신호를 남긴다" 는 위 major 3 의 본체지만,
# 절 (a) 는 지금 도달 가능한 파손 경로의 방어가 아니라 방어적 여유분이다. 예전 주석은
# "thaw.sh 의 이중 재개 방지가 이 두 가지에 의존한다" 고 적었는데, 적대적 검증이 그
# 시나리오(계약 위반 변이 E: 마커를 marked>0 일 때만 / F: return 1 뒤로)를 그대로 돌려
# 반증했다 — 프로브 구간에 done 이 도착하는 그 시점에도 부모 예약은 아직 frozen 이라
# 아래 루프가 늘 1건을 매칭해 marked=1 이 된다. 상세와 재현 절차는
# thaw.sh:release_next_job 주석에 있다(같은 검증을 반복하기 전에 먼저 읽어라).
# 2차에서 이 방식을 버린 이유는 arm 이 handoff 마커를 무조건 지워서(재사용 대비)
# 아직 살아있는 다른 예약의 신호까지 날렸기 때문 — 이번엔 지우지 않는다. 대신
# 마커에 타임스탬프를 넣고, 읽는 쪽(thaw.sh)이 "내 예약의 created_at 보다 오래된
# 신호는 무시" 로 걸러낸다. 체인 재무장은 자식에게 부모의 created_at 을 그대로
# 물려주므로(cmd_arm --created-at), 부모가 실행 중 받은 신호를 자식도 그대로 보되,
# 같은 handoff 경로를 재사용하는 완전히 새 예약(항상 새 created_at)은 옛 신호보다
# 나중에 태어나므로 안 걸린다. 지운다는 개념이 필요 없어 다른 예약 신호를 실수로
# 지울 걱정도 없다.
cmd_done() {
  local handoff=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --handoff) handoff="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$handoff" ] || { usage; return 1; }
  handoff=$(normalize_handoff "$handoff")
  local marked=0
  for r in "$STATE_ROOT"/*/reservation.json; do
    [ -f "$r" ] || continue
    [ "$(job_field "$r" handoff)" = "$handoff" ] || continue
    case "$(job_field "$r" status)" in frozen|running) ;; *) continue;; esac
    date '+%F %T 완료' > "$(dirname "$r")/done"
    marked=$((marked + 1))
  done
  # handoff 키잉 신호는 활성 예약 매칭 여부와 무관하게 항상 남긴다 — 이게 바로
  # "아직 태어나지 않은 다음 창"을 구하려는 마커라서, 지금 매칭되는 job 이 있는지는
  # 이 마커의 가치와 상관없다. created_at(아래 참고)과 같은 시계(밀리초, Date.now())를
  # 써야 비교가 성립하므로 date +%s(초) 가 아니라 node 로 찍는다 — 초 단위였을 때
  # 자동화 루프처럼 같은 handoff 로 여러 예약이 1초 안에 오가면 무관한 예약끼리
  # created_at 과 신호 시각이 같은 값으로 뭉개져 오판정이 났다(테스트 스위트 자체가
  # handoff 경로를 재사용하며 이 충돌을 실측으로 드러냈다).
  mkdir -p "$STATE_ROOT/done-by-handoff"
  node -e 'console.log(Date.now())' > "$STATE_ROOT/done-by-handoff/$(handoff_hash "$handoff")"
  if [ "$marked" -gt 0 ]; then
    echo "완료 신호 기록 — 활성 예약 ${marked}건에 전달, 재개 없이 종료한다: $handoff"
  else
    echo "완료 신호 기록 대상 없음 — 이 handoff 로 걸린 활성 예약이 없다: $handoff" >&2
    return 1
  fi
}

case "${1:-}" in
  estimate) cmd_estimate;;
  reserve) shift; cmd_reserve "$@";;
  arm) shift; cmd_arm "$@";;
  done) shift; cmd_done "$@";;
  status) cmd_status;;
  cancel) shift; cmd_cancel "$@";;
  check) cmd_check;;
  *) usage; exit 1;;
esac
