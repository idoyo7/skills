#!/usr/bin/env bash
# freeze — 세션 예약. 얼음(reserve)과 상태 관리(status/cancel/check/estimate)를 담당한다.
# 재개(땡) 실행은 thaw.sh 가 한다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
source "$SCRIPT_DIR/_claude.sh"
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
                                    [--waker bash|codex] 기본 bash — 땡 이후 프로브·재개를 누가 맡는지.
                                                 codex 는 폴백이 있다. 아래 "codex waker" 절 참고.
  arm --cwd <dir> --handoff <path> [--chain-left <n>] [--job <name>]
      [--at <시각>] [--mode resume|ledger] [--pad <초>] [--permission-mode <mode>] [--waker bash|codex]
                                    선예약(얼음 대기). 작업 시작 시점에 걸어두고 남은 쿼터를 끝까지 태운다.
                                    한도로 막히면 예약분이 알아서 잇고, 먼저 끝나면 `done` 으로 해제한다.
                                    --chain-left 는 창을 넘겨가며 이어붙일 최대 횟수(기본 2).
                                    --at 기본값은 auto(직접 arm 할 때). 체인 내부 재무장(thaw.sh)은
                                    리셋 경계에서 auto 추정이 UNKNOWN 이 되는 것을 피하려고 명시 epoch 를 넘긴다.
  snap [--cwd <dir>] [--at <시각>] [--job <name>] [--mode resume|ledger]
       [--chain-left <n>] [--permission-mode <mode>] [--pad <초>] [--waker bash|codex]
       [--out <handoff 경로>]
                                    즉발 예약 — handoff 작성까지 스크립트가 맡는다. 한도 90%대처럼
                                    LLM 이 handoff 를 손으로 쓰다가 끊겨 예약 자체가 날아가는 사고를
                                    막으려는 명령. transcript 를 못 읽거나 <cwd> 가 git 이 아니어도
                                    예약은 반드시 걸린다. --cwd 기본 $(pwd), --at 기본 auto.
                                    --out 없으면 <cwd>/.omc/handoffs/freeze-snap-<시각>.md.
                                    --chain-left 를 주면 arm(선예약) 경로, 안 주면 reserve 경로를 탄다.
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

# resolve_at 의 auto 실패 진단. cmd_estimate 자신의 출력 계약(epoch 한 줄 또는 UNKNOWN,
# 다른 곳에서 파싱한다)은 절대 건드리지 않고, cmd_estimate 가 이미 보는 두 데이터
# 소스(HUD 캐시, transcript)를 다시 훑어 "왜 UNKNOWN 이 나왔는지"만 별도로 두 줄 낸다.
# OMC HUD 가 안 깔린 환경(예: 맥)에서 원인을 알 길이 없어서 추가했다 — 호출한 쪽이
# stderr 로 돌려 사용자에게 보여준다.
estimate_diag() {
  local hud_cache="${FREEZE_HUD_CACHE:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hud/cache}"
  node - "$PROJECTS_DIR" "$hud_cache" <<'JS'
const fs = require('fs'), path = require('path');
const root = process.argv[2];
const hudCache = process.argv[3];
const nowSec = Date.now() / 1000;

// ---- HUD 캐시 진단 ----
try {
  const files = fs.readdirSync(hudCache).filter(f => f.startsWith('stdin.') && f.endsWith('.json'));
  if (!files.length) {
    console.log(`  HUD 캐시 ${hudCache}: 없음`);
  } else {
    const mtimes = files.map(f => fs.statSync(path.join(hudCache, f)).mtimeMs / 1000);
    const ageMin = Math.round((nowSec - Math.max(...mtimes)) / 60);
    let hasResets = false;
    for (const f of files) {
      try {
        const at = JSON.parse(fs.readFileSync(path.join(hudCache, f), 'utf8'))?.rate_limits?.five_hour?.resets_at;
        if (Number.isFinite(at)) { hasResets = true; break; }
      } catch { /* skip */ }
    }
    console.log(`  HUD 캐시 ${hudCache}: stdin.*.json ${files.length}개, 최신 ${ageMin}분 전, ${hasResets ? 'resets_at 있음' : 'resets_at 없음'}`);
  }
} catch {
  console.log(`  HUD 캐시 ${hudCache}: 없음`);
}

// ---- transcript 진단 ----
let count = 0;
try {
  for (const d of fs.readdirSync(root)) {
    const dir = path.join(root, d);
    let files = [];
    try { files = fs.readdirSync(dir).filter(f => f.endsWith('.jsonl')); } catch { continue; }
    for (const f of files) {
      try { if (fs.statSync(path.join(dir, f)).mtimeMs / 1000 >= nowSec - 26 * 3600) count++; } catch { /* skip */ }
    }
  }
  console.log(`  transcript ${root}: 최근 26시간 내 ${count}개`);
} catch {
  console.log(`  transcript ${root}: 없음`);
}
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
      if [ "$epoch" = "UNKNOWN" ]; then
        {
          echo "ERROR: 땡 시각 추정 실패 — --at 으로 직접 지정 필요 (예: --at 15:00, --at +5h)"
          estimate_diag
        } >&2
        return 1
      fi
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
  local at="" cwd="" handoff="" session="" job="" perm="bypassPermissions" pad="" mode="resume" created_at="" waker="bash"
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
      --waker) waker="$2"; shift 2;;
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
  case "$waker" in bash|codex) ;; *) echo "ERROR: --waker 는 bash|codex 만 지원: $waker" >&2; return 1;; esac
  # MINOR L — 사용자가 명시로 준 job 이름만 검증한다(비었으면 몇 줄 아래에서 자동
  # 생성되는데, 그 값은 항상 안전한 문자로만 조합된다). codex-wake.sh 가 이 이름을
  # printf %q 로 이스케이프해 런북에 심는 전제는 "codex 가 그 텍스트를 셸에 그대로
  # 붙여넣는다"는 것이다 — job 이름을 애초에 이 안전한 문자셋으로만 제한하면 그
  # 전제가 깨지는 상황 자체가 생기지 않는다. 이미 만들어진 예약(job 디렉토리)은
  # 여기서 새로 만드는 게 아니라서 건드리지 않는다.
  if [ -n "$job" ]; then
    case "$job" in
      *[!A-Za-z0-9._-]*)
        echo "ERROR: --job 이름은 영문자·숫자·점(.)·밑줄(_)·하이픈(-) 만 허용한다: $job" >&2
        return 1
        ;;
    esac
  fi

  # claude 실행 파일 사전 검증 — 지금까진 땡이 돼서야(thaw.sh 안에서) 실패를 알게
  # 됐는데, 그땐 이미 무인 상태라 아무도 못 고친다. 예약을 만들기 전에 확인해
  # 사용자가 그 자리에서 고칠 기회를 준다. FREEZE_SKIP_CLAUDE_CHECK=1 은 이 검증
  # 로직 자체가 의심스러울 때 쓰는 탈출구 — 실제 재개는 thaw.sh 가 어차피 한 번
  # 더 resolve_claude_bin 을 부르므로, 여기서 건너뛰어도 조용히 죽지는 않는다.
  if [ "${FREEZE_SKIP_CLAUDE_CHECK:-}" = "1" ]; then
    echo "경고: FREEZE_SKIP_CLAUDE_CHECK=1 — claude 실행 파일 검증을 건너뛴다" >&2
  else
    resolve_claude_bin >/dev/null || return 1
  fi

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
  # resume-attempt.json/wake-verdict.json/wake-prompt.txt 도 같이 지운다(BLOCKER A
  # 의 다른 얼굴) — 같은 job 이름을 재사용하면 codex-wake.sh 가 이번 실행 전에
  # 스스로 정리하기 전까지 옛 판정 파일이 이 디렉토리에 남아있는 창이 생기고,
  # 그 창에서 thaw.sh 나 사람이 상태를 들여다보면 이전 창의 결과를 이번 예약
  # 결과로 오인할 수 있다.
  rm -f "$dir/done" "$dir/resume-attempt.json" "$dir/wake-verdict.json" "$dir/wake-prompt.txt"
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
const [p, job, session, cwd, handoff, epoch, perm, mode, pad, createdAt, chain, chainLeft, via, waker] = process.argv.slice(1);
const d = {
  job, session_id: session, cwd, handoff,
  resume_at: parseInt(epoch), created_at: createdAt ? parseInt(createdAt) : Date.now(),
  permission_mode: perm, mode, pad: parseInt(pad), waker, status: "frozen"
};
// 빈 문자열이면 필드를 아예 만들지 않는다 — reserve 로 걸린 예약에는 예전처럼 chain 계열
// 필드가 없어야 한다(thaw.sh 가 그 부재로 "체인 아님"을 판정한다).
// "0" 은 빈 문자열이 아니므로 --chain-left 0 은 그대로 0 으로 들어간다.
if (chain) d.chain = parseInt(chain);
if (chainLeft) d.chain_left = parseInt(chainLeft);
if (via) d.via = via;
writeJsonAtomic(p, d);
' "$dir/reservation.json" "$job" "$session" "$cwd" "$handoff" "$epoch" "$perm" "$mode" "$effective_pad" \
  "$created_at" "$chain" "$chain_left" "$via" "$waker"

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

  # 체인 전체를 따라간다 — thaw.sh 가 다음 창을 선무장하는 데 성공하면 부모
  # reservation.json 에 next_job 을 남겨둔다. 이 job 만 취소하고 이어붙은 자식을
  # 그대로 두면(예: codex waker 실패 후 bash 폴백 도중 취소된 경우), 그 자식은
  # 고아로 남아 다음 창에서 이미 끝난 작업을 다시 연다(MAJOR 2 회귀). 최대 50단계까지만
  # 따라간다 — 오염된 데이터로 순환에 빠지는 것을 막는 안전판이다(정상 체인은
  # chain_left 로 이미 짧게 묶여 있어 이 한도에 걸릴 일이 없다).
  local cur="$job" curdir="$dir" depth=0 pid next
  while [ -n "$cur" ] && [ "$depth" -lt 50 ]; do
    depth=$((depth + 1))
    [ -f "$curdir/reservation.json" ] || break
    pid=$(cat "$curdir/sleeper.pid" 2>/dev/null || true)
    # 프로세스 그룹째 죽인다(BLOCKER C item 3) — spawn_sleeper 가 detached:true(setsid)
    # 로 띄운 thaw.sh 는 자기 프로세스 그룹의 리더다. 단일 pid 에 TERM 을 보내면 thaw
    # 자신만 죽고, 그 자식인 codex exec → do-resume.sh → claude 는 안 닿아 고아로
    # 남아 런북대로 재개를 계속 실행한다("--waker codex 예약은 사실상 취소가 안 됨").
    # "-$pid" 로 그룹 전체에 보내고, 실패하면(그룹 리더가 아닌 예외적 상황 등)
    # 단일 pid kill 로 폴백한다.
    [ -n "$pid" ] && { kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true; }
    next=$(node -e "$FREEZE_JS_ATOMIC"'
const fs = require("fs"), p = process.argv[1];
const d = JSON.parse(fs.readFileSync(p));
d.status = "cancelled";
writeJsonAtomic(p, d);
console.log(d.next_job ?? "");
' "$curdir/reservation.json")
    echo "취소됨: $cur"
    cur="$next"
    curdir="$STATE_ROOT/$cur"
  done
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
  local cwd="" handoff="" job="" chain_left="2" perm="bypassPermissions" pad="" mode="resume" at="auto" session="" created_at="" waker="bash"
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
      --waker) waker="$2"; shift 2;;
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
    --job "$job" --mode "$mode" --waker "$waker" --chain 1 --chain-left "$chain_left" --via arm \
    ${extra[@]+"${extra[@]}"} || return 1
  echo "무장 완료 — job=$job 남은 쿼터를 계속 쓰다가 막히면 예약분이 잇는다 (체인 ${chain_left}회). 먼저 끝나면: freeze.sh done --handoff $handoff"
}

# snap 이 쓸 handoff 를 결정적으로 생성한다. 사람이 쓰는 handoff 와 달리 의도가 아니라
# transcript·git 의 흔적만 담는다 — LLM 없이 만들어야 하므로 그 이상은 알 도리가 없다.
# transcript(둘째 인자, 없으면 빈 문자열)는 마지막 2MB 만 읽고 줄 단위로 JSON 파싱하며
# 깨진 줄은 건너뛴다 — 대형 transcript 전체 파싱을 피하는 것과 같은 이유(cmd_estimate 의
# edgeTs 주석 참고)다. transcript 를 못 읽거나 <cwd> 가 git 워크트리가 아니어도 이 함수는
# 실패하지 않는다 — 해당 자리에 안내 문구를 넣고 파일을 끝까지 써낸다. handoff 가 걸리는
# 것이 예약 성공의 전제이므로(cmd_reserve 가 --handoff 파일 존재를 검사한다), 여기서
# 죽으면 snap 전체가 죽는다.
gen_snap_handoff() {  # gen_snap_handoff <cwd> <transcript 절대경로 또는 빈 문자열> <out 절대경로>
  node - "$1" "$2" "$3" <<'JS'
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const cwd = process.argv[2];
const transcript = process.argv[3];
const outPath = process.argv[4];

function trunc(s, n) {
  s = String(s);
  return s.length > n ? s.slice(0, n) + '…' : s;
}

// 파일 뒤쪽 2MB 만 읽는다 — 앞부분이 잘려 첫 줄이 깨져도 아래 파서가 그 줄만 건너뛴다.
function readTail(file, cap) {
  const size = fs.statSync(file).size;
  const start = Math.max(0, size - cap);
  const len = size - start;
  const buf = Buffer.alloc(len);
  const fd = fs.openSync(file, 'r');
  fs.readSync(fd, buf, 0, len, start);
  fs.closeSync(fd);
  return buf.toString('utf8');
}

// 사람이 친 user 턴만 고른다 — isMeta(훅 피드백 등 시스템 주입)는 제외하고,
// content 가 문자열이거나 text 파트를 담고 있어야 한다. tool_result 만 담긴
// 턴(도구 실행 결과가 되돌아온 user 턴)은 text 파트가 없어 자동으로 걸러진다.
function extractUserText(o) {
  if (o.isMeta) return null;
  const content = o.message && o.message.content;
  if (typeof content === 'string') return content;
  if (Array.isArray(content)) {
    const texts = content.filter(c => c && c.type === 'text' && typeof c.text === 'string').map(c => c.text);
    if (texts.length) return texts.join('\n');
  }
  return null;
}
function extractAssistantText(o) {
  const content = o.message && o.message.content;
  if (!Array.isArray(content)) return null;
  const texts = content.filter(c => c && c.type === 'text' && typeof c.text === 'string').map(c => c.text);
  return texts.length ? texts.join('\n') : null;
}
function extractTodos(o) {
  const content = o.message && o.message.content;
  if (!Array.isArray(content)) return null;
  for (const c of content) {
    if (c && c.type === 'tool_use' && c.name === 'TodoWrite' && c.input && Array.isArray(c.input.todos)) {
      return c.input.todos;
    }
  }
  return null;
}

let userMsgs = [], lastAssistant = null, lastTodos = null, transcriptReadOk = false;
if (transcript) {
  try {
    const text = readTail(transcript, 2 * 1024 * 1024);
    transcriptReadOk = true;
    for (const raw of text.split('\n')) {
      const line = raw.trim();
      if (!line) continue;
      let o;
      try { o = JSON.parse(line); } catch { continue; }   // 잘린 줄·깨진 줄은 건너뛴다
      if (o.type === 'user') {
        const t = extractUserText(o);
        if (t !== null) userMsgs.push(t);
      } else if (o.type === 'assistant') {
        const at = extractAssistantText(o);
        if (at !== null) lastAssistant = at;
        const td = extractTodos(o);
        if (td !== null) lastTodos = td;
      }
    }
  } catch {
    transcriptReadOk = false;   // 읽기 실패 — 아래에서 "(transcript 없음)" 으로 처리
  }
}

// git 정보 — <cwd> 가 워크트리가 아니거나 git 자체가 없으면 gitInfo 는 null 로 남고,
// 아래 조립부가 각 자리에 안내 문구를 채운다.
let gitInfo = null;
try {
  execFileSync('git', ['-C', cwd, 'rev-parse', '--is-inside-work-tree'], { stdio: 'pipe' });
  const branch = execFileSync('git', ['-C', cwd, 'branch', '--show-current'], { encoding: 'utf8' }).trim() || '(감지 안 됨)';
  const log = execFileSync('git', ['-C', cwd, 'log', '--oneline', '-3'], { encoding: 'utf8' }).trim() || '(커밋 없음)';
  const cap = (lines, n) => lines.length > n ? lines.slice(0, n).join('\n') + `\n…외 ${lines.length - n}줄` : lines.join('\n');
  const statusLines = execFileSync('git', ['-C', cwd, 'status', '--porcelain'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  const diffLines = execFileSync('git', ['-C', cwd, 'diff', '--stat'], { encoding: 'utf8' }).split('\n').filter(Boolean);
  gitInfo = {
    branch,
    log,
    status: statusLines.length ? cap(statusLines, 60) : '(깨끗함)',
    diff: diffLines.length ? cap(diffLines, 40) : '(변경 없음)',
  };
} catch { gitInfo = null; }

// ---- 조립 ----
// 여기까지(transcript 파싱·git 호출)는 이미 각자 try/catch 로 감싸 실패를 흡수했다.
// 이 조립 단계 자체는 문자열 가공뿐이라 던질 일이 거의 없지만, "그럼에도" 던지면
// (예상 못 한 입력 형태 등) 마지막 파일 쓰기 전 단계에서 죽는 것만은 막아야 한다 —
// 그래서 이 블록 전체를 한 번 더 감싼다. 실제 디스크 쓰기(mkdirSync/writeFileSync)
// 만은 이 catch 밖에 남겨 던진 그대로 올려보낸다 — cmd_snap 쪽 폴백(bash 최소 골격
// → STATE_ROOT 대피)이 받아야 할 신호라서다.
let doc;
try {
  let titlePart;
  if (gitInfo) {
    const firstLog = gitInfo.log.split('\n')[0] || '';
    const commitMsg = firstLog ? firstLog.replace(/^[0-9a-f]+\s*/, '') : '(커밋 없음)';
    titlePart = `${gitInfo.branch} / ${commitMsg}`;
  } else {
    titlePart = '(git 아님)';
  }

  let userSection, assistantSection;
  if (!transcript || !transcriptReadOk) {
    userSection = '(transcript 없음)';
    assistantSection = '(transcript 없음)';
  } else {
    userSection = userMsgs.length
      ? userMsgs.slice(-5).map(m => `- ${trunc(m, 400).replace(/\n/g, ' ')}`).join('\n')
      : '(최근 사용자 요청 없음)';
    assistantSection = lastAssistant !== null ? trunc(lastAssistant, 300) : '(직전 어시스턴트 발언 없음)';
  }

  let todoSection;
  if (transcript && transcriptReadOk && lastTodos !== null) {
    todoSection = lastTodos.map(t => {
      const done = t && t.status === 'completed';
      const label = (t && (t.content || t.activeForm)) || '(내용 없음)';
      return `- [${done ? 'x' : ' '}] ${label}`;
    }).join('\n');
  } else {
    todoSection = 'TodoWrite 기록 없음 — 위 최근 사용자 요청과 작업 트리 변경을 근거로 재개 세션이 다음 단계를 직접 정한다.';
  }

  const branchBlock = gitInfo ? `${gitInfo.branch}\n\n${gitInfo.log}` : '(git 워크트리 아님)';
  const statusBlock = gitInfo ? gitInfo.status : '(git 워크트리 아님)';
  const diffBlock = gitInfo ? gitInfo.diff : '(git 워크트리 아님)';

  doc = `# freeze handoff (snap 자동생성) — ${titlePart}

> freeze.sh snap 이 transcript 와 git 에서 기계적으로 뽑은 문서다. LLM 이 쓴 요약이 아니라서
> 의도가 아니라 흔적만 담겨 있다. 재개 세션은 이걸 근거로 직접 판단해라.

## 하던 일
### 최근 사용자 요청 (오래된 것 → 최근)
${userSection}

### 직전 어시스턴트 발언
${assistantSection}

## 완료 지점
### 브랜치 / 최근 커밋
${branchBlock}

### 작업 트리 변경
${statusBlock}

### diffstat
${diffBlock}

## 다음 단계
### 마지막 TodoWrite 상태
${todoSection}

## 검증
(snap 자동생성이라 비어 있다. 재개 세션이 리포의 테스트 관행을 확인해 채운다.)
`;
} catch (e) {
  doc = `# freeze handoff (snap 자동생성 실패) — ${cwd}

> snap 자동생성 중 예기치 않은 오류로 조립 단계가 실패했다: ${String((e && e.message) || e)}
> transcript·git 수집이 실패해 뼈대만 남겼다. 재개 세션은 cwd 의 git 상태를 직접 확인해 이어가라.

## 하던 일
### 최근 사용자 요청 (오래된 것 → 최근)
(자동생성 실패)

### 직전 어시스턴트 발언
(자동생성 실패)

## 완료 지점
### 브랜치 / 최근 커밋
(자동생성 실패)

### 작업 트리 변경
(자동생성 실패)

### diffstat
(자동생성 실패)

## 다음 단계
### 마지막 TodoWrite 상태
(자동생성 실패)

## 검증
(snap 자동생성이라 비어 있다. 재개 세션이 리포의 테스트 관행을 확인해 채운다.)
`;
}

fs.mkdirSync(path.dirname(outPath), { recursive: true });
fs.writeFileSync(outPath, doc);
JS
}

# gen_snap_handoff 가 그래도 실패했을 때(디스크 가득, $out 디렉토리 쓰기 권한 없음 등)
# bash 가 직접 쓰는 최소 골격. node 없이 순수 셸로 쓰므로 gen_snap_handoff 를 죽인
# 원인과 같은 이유로 또 죽을 가능성이 낮다 — 유일하게 공유하는 실패 지점은 디렉토리
# 쓰기 권한 자체뿐이고, 그건 cmd_snap 쪽에서 이 함수가 실패하면 STATE_ROOT 로
# 옮겨 다시 부르는 것으로 흡수한다.
write_snap_fallback_handoff() {  # write_snap_fallback_handoff <out> <cwd>
  local out="$1" cwd="$2"
  mkdir -p "$(dirname "$out")" 2>/dev/null || return 1
  cat > "$out" <<EOF2 || return 1
# freeze handoff (snap 자동생성 실패) — $cwd

> snap 자동생성 실패: transcript·git 수집이 실패해 뼈대만 남겼다. 재개 세션은 cwd 의
> git 상태를 직접 확인해 이어가라. 실패 시각: $(date '+%F %T')

## 하던 일
### 최근 사용자 요청 (오래된 것 → 최근)
(snap 자동생성 실패 — 뽑지 못함)

### 직전 어시스턴트 발언
(snap 자동생성 실패 — 뽑지 못함)

## 완료 지점
### 브랜치 / 최근 커밋
(snap 자동생성 실패 — 뽑지 못함)

### 작업 트리 변경
(snap 자동생성 실패 — 뽑지 못함)

### diffstat
(snap 자동생성 실패 — 뽑지 못함)

## 다음 단계
### 마지막 TodoWrite 상태
(snap 자동생성 실패 — 뽑지 못함)

## 검증
(snap 자동생성이라 비어 있다. 재개 세션이 리포의 테스트 관행을 확인해 채운다.)
EOF2
}

# snap — 즉발 얼음. 지금까지의 얼음 절차는 LLM 이 handoff 를 직접 썼는데, 한도 95~99%
# 에서 부르면 그 작성이 중간에 끊겨 예약 자체가 통째로 날아간다. handoff 작성을
# gen_snap_handoff(결정적 스크립트)로 옮겨 LLM 이 할 일을 이 명령 한 줄로 줄인 것.
# transcript 없음·읽기 실패·git 아님 어느 것도 이 함수를 죽이지 않는다 — 예약이
# 걸리는 것이 handoff 품질보다 우선이라서다.
cmd_snap() {
  local cwd="" at="auto" job="" mode="resume" mode_explicit=0 chain_left="" perm="bypassPermissions" pad="" waker="bash" out=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --cwd) cwd="$2"; shift 2;;
      --at) at="$2"; shift 2;;
      --job) job="$2"; shift 2;;
      --mode) mode="$2"; mode_explicit=1; shift 2;;
      --chain-left) chain_left="$2"; shift 2;;
      --permission-mode) perm="$2"; shift 2;;
      --pad) pad="$2"; shift 2;;
      --waker) waker="$2"; shift 2;;
      --out) out="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$cwd" ] || cwd="$(pwd)"
  case "$mode" in resume|ledger) ;; *) echo "ERROR: --mode 는 resume|ledger 만 지원: $mode" >&2; return 1;; esac
  case "$waker" in bash|codex) ;; *) echo "ERROR: --waker 는 bash|codex 만 지원: $waker" >&2; return 1;; esac

  [ -n "$out" ] || out="$cwd/.omc/handoffs/freeze-snap-$(date +%Y%m%d-%H%M%S).md"
  out=$(normalize_handoff "$out")   # reserve/arm 이 어차피 다시 정규화하지만, 아래 mkdir·출력에
                                     # 절대경로가 필요해 여기서 먼저 확정해 둔다.
  # 이 mkdir 은 순전히 사전 준비용이다 — gen_snap_handoff 의 node 스크립트가 실제
  # 쓰기 직전에 자기 mkdirSync 를 다시 하므로 여기서 실패해도 치명적이지 않다.
  # set -e 아래서 이 줄 자체가 죽는 사고를 막으려고 || true 로 흡수한다 — 진짜
  # "이 디렉토리에 못 쓴다"는 판정은 아래 gen_snap_handoff/write_snap_fallback_handoff
  # 의 실제 쓰기 시도가 내린다.
  mkdir -p "$(dirname "$out")" 2>/dev/null || true

  # 최신 transcript 탐색 — detect_session 과 같은 방식(프로젝트 디렉토리의 최신 .jsonl)
  # 이지만 실패해도 절대 죽지 않는다. 못 찾으면 빈 문자열을 그대로 넘겨
  # gen_snap_handoff 가 "(transcript 없음)" 으로 처리하게 한다.
  local slug proj_dir transcript=""
  slug=$(echo "$cwd" | sed 's/[^A-Za-z0-9-]/-/g')
  proj_dir="$PROJECTS_DIR/$slug"
  if [ -d "$proj_dir" ]; then
    transcript=$(ls -t "$proj_dir"/*.jsonl 2>/dev/null | head -1 || true)
  fi
  # 세션 id 는 transcript 파일명(.jsonl 을 뗀 것)과 같다 — detect_session 이 하는 일을
  # 그대로 반복하는 대신 위에서 이미 찾은 transcript 를 재사용한다(같은 디렉토리를
  # 또 훑을 이유가 없다).
  local session=""
  [ -n "$transcript" ] && session=$(basename "$transcript" .jsonl)

  # resume 모드(기본)는 --resume <세션> 이 계약이라, 세션을 못 찾으면 cmd_reserve/cmd_arm
  # 이 치명적으로 실패시킨다(detect_session 참고) — 그럼 snap 이 예약을 못 건다.
  # snap 은 한도 임박 같은 즉발 상황에 불리는 명령이라 "예약이 아예 안 걸리는 것"보다
  # "ledger 로 자동 강등해서라도 예약은 건다"가 이 기능의 제1원칙("예약이 걸리는 것이
  # 우선")에 맞는다 — snap 이 만든 handoff 는 애초에 대화 문맥 없이도 읽히는 자립적
  # 문서라 ledger 재개와 궁합이 좋다. 단, 사용자가 --mode resume 을 명시로 골랐다면
  # 그 선택 자체가 계약이므로 강등하지 않고 아래 reserve/arm 호출이 그대로 실패하게
  # 둔다(실패해도 handoff 는 이미 만들어져 있다는 안내가 나간다 — 아래 참고).
  if [ -z "$session" ] && [ "$mode" = "resume" ] && [ "$mode_explicit" != 1 ]; then
    echo "경고: transcript 세션을 못 찾아 --mode 를 resume 에서 ledger 로 자동 강등한다" >&2
    mode="ledger"
  fi

  # handoff 생성 — "예약이 걸리는 것이 handoff 품질보다 우선" 이 이 기능의 제1원칙이라,
  # gen_snap_handoff(node) 가 실패해도 여기서 cmd_snap 을 죽이지 않는다. 3중 폴백:
  #   1) gen_snap_handoff 실패 → bash 가 직접 최소 골격을 같은 $out 경로에 쓴다
  #      (write_snap_fallback_handoff — node 없이 순수 셸이라 다른 실패 원인을 안 탄다).
  #   2) 그마저 실패(=$out 디렉토리 자체에 못 쓴다) → 반드시 쓸 수 있다고 기대할 수 있는
  #      STATE_ROOT 아래로 옮겨 다시 쓰고, 이후 예약도 그 경로로 건다. 사용자에게는
  #      원래 경로에 못 썼다는 사실을 stderr 로 남긴다.
  #   3) 그것마저 실패(=STATE_ROOT 조차 못 쓴다=예약 자체가 원천적으로 불가능한 환경)
  #      → 그때만 이유를 명확히 남기고 비영으로 죽는다. 이 지점 이후로는 예약을
  #      만들 방법이 없으므로 죽는 것이 맞다.
  if ! gen_snap_handoff "$cwd" "$transcript" "$out"; then
    echo "경고: handoff 자동생성 실패 — 최소 골격으로 대체한다: $out" >&2
    if ! write_snap_fallback_handoff "$out" "$cwd"; then
      local safe_out="$STATE_ROOT/snap-fallback-$(date +%Y%m%d-%H%M%S).md"
      echo "경고: $out 에 쓸 수 없다 — 대신 $safe_out 에 최소 골격을 남긴다" >&2
      mkdir -p "$STATE_ROOT" 2>/dev/null || true
      if ! write_snap_fallback_handoff "$safe_out" "$cwd"; then
        echo "ERROR: handoff 를 어디에도 쓸 수 없다 — $out, $safe_out 둘 다 실패. 예약을 걸 수 없다" >&2
        return 1
      fi
      out="$safe_out"
    fi
  fi

  # job 이름은 여기서 먼저 정해 reserve/arm 양쪽에 그대로 넘긴다 — cmd_arm 이 자기
  # job 을 스스로 정하는 것과 같은 이유(동시 호출 시 "가장 최근 reservation.json" 을
  # 사후 추정하지 않기 위해서다).
  [ -n "$job" ] || job="freeze-snap-$(date +%Y%m%d-%H%M%S)-$$"

  local -a extra=()
  [ -n "$pad" ] && extra+=(--pad "$pad")
  # 이미 위에서 찾아둔 세션을 그대로 넘긴다 — cmd_reserve 가 detect_session 을
  # 다시 불러 같은 디렉토리를 또 훑게 둘 이유가 없다(ledger 모드로 강등됐어도
  # session_id 필드는 wfledger.sh 가 쓰므로 여전히 유용해 그대로 넘긴다).
  [ -n "$session" ] && extra+=(--session "$session")

  if [ -n "$chain_left" ]; then
    if ! cmd_arm --cwd "$cwd" --handoff "$out" --at "$at" --mode "$mode" \
        --chain-left "$chain_left" --permission-mode "$perm" --job "$job" --waker "$waker" \
        ${extra[@]+"${extra[@]}"} >/dev/null; then
      echo "handoff 는 만들어졌다 — $out (예약 실패, --at 을 직접 지정해 다시 시도: freeze.sh arm --cwd \"$cwd\" --handoff \"$out\" --at <시각> --chain-left $chain_left)" >&2
      return 1
    fi
  else
    if ! cmd_reserve --cwd "$cwd" --handoff "$out" --at "$at" --mode "$mode" \
        --permission-mode "$perm" --job "$job" --waker "$waker" \
        ${extra[@]+"${extra[@]}"} >/dev/null; then
      echo "handoff 는 만들어졌다 — $out (예약 실패, --at 을 직접 지정해 다시 시도: freeze.sh reserve --cwd \"$cwd\" --handoff \"$out\" --at <시각>)" >&2
      return 1
    fi
  fi

  local res="$STATE_ROOT/$job/reservation.json"
  local epoch; epoch=$(job_field "$res" resume_at)
  local handoff_saved; handoff_saved=$(job_field "$res" handoff)
  echo "얼음(즉발) — job=$job mode=$mode 땡=$(fmt_epoch "$epoch" '+%m/%d %H:%M') ($(( (epoch - $(date +%s)) / 60 ))분 후)"
  echo "handoff=$handoff_saved — 토큰이 남았으면 '## 다음 단계' 를 보강해라. 남지 않았으면 그대로 두면 된다."
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
  snap) shift; cmd_snap "$@";;
  done) shift; cmd_done "$@";;
  status) cmd_status;;
  cancel) shift; cmd_cancel "$@";;
  check) cmd_check;;
  *) usage; exit 1;;
esac
