#!/usr/bin/env bash
# wfledger — freeze 의 ledger 재개 모드가 쓰는 원장(ledger) 관리 스크립트.
# 원장은 <cwd>/.omc/handoffs/wfledger-<job>.md 에 만들어지는 마크다운 한 장이다.
# 결과 본문은 절대 담지 않는다 — journal.jsonl 과 산출물 파일의 "경로"만 담아
# 원장 크기를 작업 규모와 무관하게 10k 토큰 이하로 묶어둔다.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_node.sh"
PROJECTS_DIR="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"

usage() {
  cat <<'EOF'
wfledger.sh <command> [args]

  init --job <name> --cwd <dir> --summary <text>
       [--session <uuid>] [--goal <text>] [--done-when <text>]
                                    원장 스켈레톤 생성, 경로 출력.
                                    이미 있으면 덮어쓰지 않고 경로만 출력.
  run --ledger <path> --run-id <wf_...> [--session <uuid>]
                                    방금 띄운 워크플로우 런을 "## 워크플로우 런" 절에 등록한다.
                                    script/journal 절대경로는 runId 로부터 계산한다.
                                    같은 runId 를 두 번 등록하면 조용히 무시한다(멱등).
                                    런 디렉토리 자체가 없으면 runId 오타로 보고 실패한다.
  set-session --ledger <path> [--session <uuid> | --cwd <dir>]
                                    원장 헤더의 session: 필드를 갱신한다. --session 을 안 주면
                                    --cwd(기본: 원장의 cwd: 필드)의 최신 세션을 자동 탐지한다.
                                    ledger 모드 재개는 매번 새 세션 UUID 로 뜨는데, run/journal/link
                                    는 기본으로 이 필드를 읽어 경로를 계산하므로 재개 세션이 새
                                    워크플로우를 등록하기 전에 반드시 호출해야 한다.
  mark --ledger <path> --step <n> [--artifact <path>]
                                    단계 체크박스를 [x] 로 바꾸고 산출물 경로를 덧붙인다.
  remaining --ledger <path>        체크 안 된 단계를 그대로 출력.
  journal --ledger <path>          등록된 모든 런의 journal.jsonl 에서
                                    완료된(result 줄이 있는) 호출을 "<agentId> <key>" 로 나열.
  link --ledger <path> --run-id <wf_...> --session <새 세션 UUID>
                                    옵트인 가속: 원본 런 디렉토리를 새 세션의 기대 경로에 symlink.
EOF
}

slug_of() { echo "$1" | sed 's/[^A-Za-z0-9-]/-/g'; }

# 원장 헤더의 "key: value" 한 줄을 뽑는다.
ledger_field() {
  local path="$1" key="$2"
  sed -n "s/^${key}: //p" "$path" | head -1
}

touch_updated() {
  local path="$1" now tmp
  now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  tmp=$(mktemp)
  sed "s/^updated: .*/updated: $now/" "$path" > "$tmp" && mv "$tmp" "$path"
}

cmd_init() {
  local job="" cwd="" summary="" session="" goal="" done_when=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --job) job="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      --summary) summary="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      --goal) goal="$2"; shift 2;;
      --done-when) done_when="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$job" ] && [ -n "$cwd" ] && [ -n "$summary" ] || { usage; return 1; }

  local dir="$cwd/.omc/handoffs"
  mkdir -p "$dir"
  local path="$dir/wfledger-$job.md"
  if [ -f "$path" ]; then
    echo "$path"
    return 0
  fi

  if [ -z "$session" ]; then
    local slug latest
    slug=$(slug_of "$cwd")
    latest=$(ls -t "$PROJECTS_DIR/$slug"/*.jsonl 2>/dev/null | head -1 || true)
    [ -n "$latest" ] && session=$(basename "$latest" .jsonl)
  fi

  local now; now=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  {
    echo "# wf ledger — $summary"
    echo "<!-- freeze-ledger v1 -->"
    echo "job: $job"
    echo "cwd: $cwd"
    echo "session: $session"
    echo "updated: $now"
    echo
    echo "## 목표"
    echo "${goal:-$summary}"
    echo
    echo "## 완료 기준"
    echo "${done_when:-미정 — 재개 세션이 목표를 보고 판단}"
    echo
    echo "## 단계"
    echo "- [ ] 1. (여기 채워라)"
    echo
    echo "## 워크플로우 런"
    echo "(등록된 런 없음)"
    echo
    echo "## 재개 절차"
    echo "1. 이 원장을 읽는다 — 대화 문맥은 없다. 이 파일이 유일한 명세다."
    echo "2. '## 워크플로우 런' 에 등록된 런의 journal.jsonl 을 \`wfledger.sh journal\` 로 확인해 끝난(result 줄이 있는) agent 호출을 건너뛴다."
    echo "3. '## 단계' 의 남은 항목을 이어서 완료한다."
    echo
    echo "## 검증"
    echo "(끝났다고 판단할 테스트·확인 명령을 적어라)"
  } > "$path"
  echo "$path"
}

cmd_run() {
  local ledger="" run_id="" session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      --run-id) run_id="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] && [ -n "$run_id" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }

  # 같은 runId 재등록은 멱등 — 안 그러면 항목이 중복 삽입되고 journal 도 두 번 읽힌다.
  if grep -qxF -- "- runId: $run_id" "$ledger"; then
    echo "이미 등록됨: $run_id"
    return 0
  fi

  [ -n "$session" ] || session=$(ledger_field "$ledger" session)
  [ -n "$session" ] || { echo "ERROR: 세션 UUID 를 알 수 없음 (--session, 또는 wfledger.sh set-session 으로 원장의 session: 필드를 먼저 채워라)" >&2; return 1; }
  local cwd; cwd=$(ledger_field "$ledger" cwd)
  [ -n "$cwd" ] || { echo "ERROR: 원장에 cwd: 필드 없음" >&2; return 1; }

  local slug sess_dir run_dir journal script
  slug=$(slug_of "$cwd")
  sess_dir="$PROJECTS_DIR/$slug/$session"
  run_dir="$sess_dir/subagents/workflows/$run_id"
  journal="$run_dir/journal.jsonl"
  # 런 디렉토리 자체가 없으면 runId 오타이거나 세션이 틀렸다는 강한 신호다 — 여기서
  # 막지 않으면 "잘못 등록된 런" 과 "정상 등록됐지만 완료된 호출이 0건" 을 나중에
  # cmd_journal 출력만 보고는 구분할 수 없다.
  [ -d "$run_dir" ] || { echo "ERROR: 런 디렉토리 없음(runId 오타 또는 세션 불일치 의심): $run_dir" >&2; return 1; }
  script=$(ls "$sess_dir"/workflows/scripts/*-"$run_id".js 2>/dev/null | head -1 || true)
  [ -n "$script" ] || script="(찾지 못함 — $sess_dir/workflows/scripts/*-$run_id.js)"

  local entry
  entry=$(printf -- '- runId: %s\n  script: %s\n  journal: %s' "$run_id" "$script" "$journal")

  local tmp; tmp=$(mktemp)
  # entry 는 여러 줄이다. awk -v 로 넘기면 BSD awk 가 "newline in string" 으로
  # 거부한다(GNU awk 는 통과) — 환경변수로 넘기고 ENVIRON 으로 읽는다. ENVIRON 은
  # POSIX awk 라 두 구현 모두 지원하고 값에 개행이 들어가도 문제없다.
  WFLEDGER_ENTRY="$entry" awk '
    { print }
    !done && $0 ~ /^## 워크플로우 런$/ { print ENVIRON["WFLEDGER_ENTRY"]; done=1 }
  ' "$ledger" > "$tmp"

  # 플레이스홀더 제거는 "## 워크플로우 런" 섹션 안, 그 첫 줄일 때만 한다 — 예전엔
  # 파일 전체를 grep -v 로 훑어 목표·완료 기준 본문에 우연히 같은 문구가 있어도
  # 그 줄을 통째로 지웠다.
  local tmp2; tmp2=$(mktemp)
  awk '
    BEGIN { insec = 0 }
    $0 ~ /^## 워크플로우 런$/ { insec = 1; print; next }
    insec && $0 == "(등록된 런 없음)" { insec = 0; next }
    insec && $0 ~ /^## / { insec = 0 }
    { print }
  ' "$tmp" > "$tmp2"
  mv "$tmp2" "$ledger"
  rm -f "$tmp"

  touch_updated "$ledger"
  echo "등록: $run_id"
}

cmd_set_session() {
  local ledger="" session="" cwd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      --session) session="$2"; shift 2;;
      --cwd) cwd="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }

  if [ -z "$session" ]; then
    [ -n "$cwd" ] || cwd=$(ledger_field "$ledger" cwd)
    [ -n "$cwd" ] || { echo "ERROR: --session 또는 --cwd 필요(원장에 cwd: 필드도 없음)" >&2; return 1; }
    local slug latest
    slug=$(slug_of "$cwd")
    latest=$(ls -t "$PROJECTS_DIR/$slug"/*.jsonl 2>/dev/null | head -1 || true)
    [ -n "$latest" ] || { echo "ERROR: 세션 자동탐지 실패 — transcript 없음: $PROJECTS_DIR/$slug" >&2; return 1; }
    session=$(basename "$latest" .jsonl)
  fi

  local tmp; tmp=$(mktemp)
  sed "s/^session: .*/session: $session/" "$ledger" > "$tmp" && mv "$tmp" "$ledger"
  touch_updated "$ledger"
  echo "세션 갱신: $session"
}

cmd_mark() {
  local ledger="" step="" artifact=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      --step) step="$2"; shift 2;;
      --artifact) artifact="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] && [ -n "$step" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }

  local tmp; tmp=$(mktemp)
  awk -v n="$step" -v art="$artifact" '
    {
      if ($0 ~ ("^- \\[ \\] " n "\\. ")) {
        line = $0
        sub(/^- \[ \]/, "- [x]", line)
        if (art != "") line = line " → 산출물: " art
        print line
      } else {
        print
      }
    }
  ' "$ledger" > "$tmp"

  if diff -q "$ledger" "$tmp" > /dev/null; then
    rm -f "$tmp"
    echo "ERROR: 단계 $step 을 찾지 못함 (이미 체크됐거나 번호 불일치)" >&2
    return 1
  fi
  mv "$tmp" "$ledger"
  touch_updated "$ledger"
  echo "체크: 단계 $step"
}

cmd_remaining() {
  local ledger=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }
  grep -E '^- \[ \] ' "$ledger" || true
}

cmd_journal() {
  local ledger=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }

  local jf
  while IFS= read -r jf; do
    [ -n "$jf" ] || continue
    if [ ! -f "$jf" ]; then
      # 조용히 건너뛰면 "경로가 틀림" 과 "아직 완료된 호출이 없음" 이 똑같이 빈
      # 출력으로 보인다 — stderr 로라도 구분해서 재개 세션이 헛짚지 않게 한다.
      echo "WARN: journal 파일 없음(등록은 됐지만 아직 안 생겼거나 경로가 틀림): $jf" >&2
      continue
    fi
    node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").split("\n");
for (const l of lines) {
  const s = l.trim();
  if (!s) continue;
  let o;
  try { o = JSON.parse(s); } catch { continue; }
  if (o.type === "result") console.log(`${o.agentId} ${o.key}`);
}
' "$jf"
  done < <(sed -n 's/^  journal: //p' "$ledger")
}

cmd_link() {
  # 옵트인 가속 — 미문서화 CLI 내부 동작에 기댄다. resumeFromRunId 는 same-session-only
  # 인데, 내부적으로 runId → 디렉토리 해석 함수가 항상 "현재 세션 UUID" 를 경로에
  # 끼워넣기 때문이다. 다만 CLI 내부에는 백그라운드 포크용으로 원본 런 디렉토리를
  # 새 세션의 기대 경로에 symlink 로 이어붙이는 코드가 있어, 같은 심링크를 여기서
  # 직접 만들면 교차 세션 resume 이 먹을 가능성이 있다 — 검증되지 않은 가설이므로
  # 실패하면 그대로 실패 코드로 끝낸다. 호출자는 실패 시 원장 경로 재생(plain ledger
  # replay) 방식으로 폴백해야 한다. 업그레이드로 CLI 내부 구현이 바뀌면 깨질 수 있다.
  local ledger="" run_id="" new_session=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --ledger) ledger="$2"; shift 2;;
      --run-id) run_id="$2"; shift 2;;
      --session) new_session="$2"; shift 2;;
      *) echo "ERROR: unknown arg $1" >&2; return 1;;
    esac
  done
  [ -n "$ledger" ] && [ -n "$run_id" ] && [ -n "$new_session" ] || { usage; return 1; }
  [ -f "$ledger" ] || { echo "ERROR: 원장 없음: $ledger" >&2; return 1; }

  local cwd session slug orig_dir new_dir
  cwd=$(ledger_field "$ledger" cwd)
  session=$(ledger_field "$ledger" session)
  [ -n "$cwd" ] && [ -n "$session" ] || { echo "ERROR: 원장에 cwd/session 필드 없음" >&2; return 1; }
  slug=$(slug_of "$cwd")
  orig_dir="$PROJECTS_DIR/$slug/$session/subagents/workflows/$run_id"
  new_dir="$PROJECTS_DIR/$slug/$new_session/subagents/workflows/$run_id"

  [ -d "$orig_dir" ] || { echo "ERROR: 원본 런 디렉토리 없음 — 폴백 필요: $orig_dir" >&2; return 1; }
  if [ -e "$new_dir" ] || [ -L "$new_dir" ]; then
    echo "이미 존재: $new_dir"
    return 0
  fi
  mkdir -p "$(dirname "$new_dir")"
  ln -s "$orig_dir" "$new_dir" || { echo "ERROR: symlink 실패" >&2; return 1; }
  echo "링크됨: $new_dir -> $orig_dir"
}

case "${1:-}" in
  init) shift; cmd_init "$@";;
  run) shift; cmd_run "$@";;
  set-session) shift; cmd_set_session "$@";;
  mark) shift; cmd_mark "$@";;
  remaining) shift; cmd_remaining "$@";;
  journal) shift; cmd_journal "$@";;
  link) shift; cmd_link "$@";;
  *) usage; exit 1;;
esac
