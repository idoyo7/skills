#!/usr/bin/env bash
# ~/.claude/skills/ 에 이 레포의 스킬들을 심링크로 걸고,
# hooks/*/hook.conf 에 선언된 훅들(reply-check의 Stop 훅, workflow-arm의
# PreToolUse 훅 등)을 ~/.claude/hooks/ 에 설치하며 ~/.claude/settings.json 에 등록한다.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# readlink -f 는 GNU 확장이라 구형 macOS/BSD readlink 가 거부한다. 이 저장소는
# 이미 node 에 전면 의존하므로(스크립트 전반이 JSON 처리를 node 로 한다) node 로 폴백한다.
resolve_path() {
  if readlink -f / >/dev/null 2>&1; then
    readlink -f "$1"
  else
    node -e 'console.log(require("fs").realpathSync(process.argv[1]))' -- "$1" 2>/dev/null || printf '%s' "$1"
  fi
}
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"

# ── 옵션 파싱 ──────────────────────────────────────────────────────────────
NO_HOOKS=0
for arg in "$@"; do
  case "$arg" in
    --no-hooks) NO_HOOKS=1 ;;
  esac
done

# ── 1. 스킬 심링크 ──────────────────────────────────────────────────────────
for skill_md in "$REPO_DIR"/*/SKILL.md; do
  [ -f "$skill_md" ] || continue
  src="$(dirname "$skill_md")"
  name="$(basename "$src")"
  dest="$SKILLS_DIR/$name"

  if [ -L "$dest" ]; then
    current="$(resolve_path "$dest")"
    if [ "$current" = "$src" ]; then
      echo "ok:   $name (이미 연결됨)"
    else
      ln -sfn "$src" "$dest"
      echo "fix:  $name → $src (다른 곳을 가리키던 링크 교체)"
    fi
  elif [ -e "$dest" ]; then
    echo "skip: $name — $dest 가 실디렉토리/파일로 존재. 치운 뒤 다시 실행"
  else
    ln -s "$src" "$dest"
    echo "new:  $name → $src"
  fi
done

# ── 2. 훅 설치 ─────────────────────────────────────────────────────────────
# 훅마다 어느 이벤트(Stop/PreToolUse 등)·matcher 에 등록되는지는 각 훅
# 디렉토리 안의 hook.conf 에 선언한다(중앙 표 대신 분산 메타 파일을 택한 이유:
# 훅을 새로 추가할 때 install.sh 자체를 건드릴 필요가 없어 충돌·누락이 줄어든다).
# hook.conf 형식: EVENT=Stop 처럼 KEY=VALUE 한 줄씩, 값은 EVENT/MATCHER/ENTRY.
if [ "$NO_HOOKS" -eq 1 ]; then
  echo "skip: --no-hooks 플래그 — 훅 설치 단계 건너뜀"
  exit 0
fi

HOOKS_DIR="$HOME/.claude/hooks"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOOKS_DIR"

# settings.json 백업은 "이번 실행 시작 전에 이미 있던 내용"을 한 번만 지키면 된다.
# PRE_EXISTED 는 루프 시작 전에 딱 한 번 정하고(이후 훅이 새로 만들어도 안 바뀜),
# BACKUP_DONE 은 그 내용을 실제로 한 번 백업했는지를 훅 반복 사이에 이어 나른다 —
# 훅마다 파이썬을 새로 띄우므로 bash 변수로는 못 넘기고 임시 파일로 신호를 주고받는다.
PRE_EXISTED=0
[ -f "$SETTINGS" ] && PRE_EXISTED=1
BACKUP_DONE=0

for hook_conf in "$REPO_DIR"/hooks/*/hook.conf; do
  [ -f "$hook_conf" ] || continue
  hook_dir="$(dirname "$hook_conf")"
  name="$(basename "$hook_dir")"

  # hook.conf 를 깨끗한 상태에서 읽는다 — 이전 반복의 값이 새지 않게 매번 초기화
  EVENT=""
  MATCHER=""
  ENTRY=""
  # shellcheck source=/dev/null
  source "$hook_conf"

  if [ -z "$EVENT" ] || [ -z "$ENTRY" ]; then
    echo "skip: $name — hook.conf 에 EVENT/ENTRY 누락"
    continue
  fi

  HOOK_SRC="$hook_dir/$ENTRY"
  HOOK_DEST="$HOOKS_DIR/$ENTRY"

  # 2-a. 심링크 설치
  if [ -L "$HOOK_DEST" ]; then
    current_target="$(resolve_path "$HOOK_DEST")"
    if [ "$current_target" = "$HOOK_SRC" ]; then
      echo "ok:   $ENTRY (심링크 이미 올바름)"
    else
      ln -sfn "$HOOK_SRC" "$HOOK_DEST"
      echo "fix:  $ENTRY → $HOOK_SRC (다른 곳을 가리키던 링크 교체)"
    fi
  elif [ -f "$HOOK_DEST" ]; then
    # 실파일이 있으면 내용 비교 후 처리
    if cmp -s "$HOOK_DEST" "$HOOK_SRC"; then
      # 내용이 같으면 조용히 심링크로 교체
      rm "$HOOK_DEST"
      ln -s "$HOOK_SRC" "$HOOK_DEST"
      echo "ok:   $ENTRY (실파일→심링크 교체, 내용 동일)"
    else
      # 다르면 백업 후 교체
      TS="$(date +%Y%m%dT%H%M%S)"
      cp "$HOOK_DEST" "${HOOK_DEST}.bak.${TS}"
      rm "$HOOK_DEST"
      ln -s "$HOOK_SRC" "$HOOK_DEST"
      echo "fix:  $ENTRY — 기존 파일을 ${HOOK_DEST}.bak.${TS} 로 백업 후 심링크 설치"
    fi
  else
    ln -s "$HOOK_SRC" "$HOOK_DEST"
    echo "new:  $ENTRY → $HOOK_SRC"
  fi

  # 2-b. settings.json 등록
  HOOK_CMD="python3 \$HOME/.claude/hooks/$ENTRY"
  BACKUP_FLAG="$(mktemp)"

  # settings.json 이 깨져 있어도(파싱 불가) 이 훅 하나만 실패로 보고하고 나머지
  # 훅은 계속 설치한다 — 파이썬이 예외로 죽지 않도록 내부에서 전부 잡는다.
  # (set -e 아래에서도 이 호출 자체는 성공 종료해야 하므로 실패를 문자열로만 보고한다)
  if ! python3 - "$SETTINGS" "$EVENT" "$MATCHER" "$HOOK_CMD" "$name" "$PRE_EXISTED" "$BACKUP_DONE" "$BACKUP_FLAG" <<'PYEOF'
import json, pathlib, sys, time

settings_path = pathlib.Path(sys.argv[1])
event = sys.argv[2]
matcher = sys.argv[3]  # 빈 문자열이면 matcher 없는 이벤트(Stop 등)
hook_cmd = sys.argv[4]
hook_name = sys.argv[5]
pre_existed = sys.argv[6] == "1"   # install.sh 실행 "시작 전"에 settings.json 이 있었는가
backup_done = sys.argv[7] == "1"   # 이번 install.sh 실행 중 이미 한 번 백업했는가
backup_flag_path = pathlib.Path(sys.argv[8])

exists_now = settings_path.exists()
raw = settings_path.read_text(encoding="utf-8") if exists_now else ""

backup_path = None


def _backup_once():
    """이번 실행 시작 전 내용을 딱 한 번만 백업한다. 이후 호출은 아무것도 안 한다 —
    훅을 여러 개 등록해도 .bak 파일이 훅 개수만큼 쌓이지 않게 하기 위해서다."""
    global backup_path, backup_done
    if backup_done or backup_path is not None:
        return backup_path
    ts = time.strftime("%Y%m%dT%H%M%S")
    bak = f"{settings_path}.bak.{ts}"
    pathlib.Path(bak).write_text(raw, encoding="utf-8")
    backup_path = bak
    backup_done = True
    return bak


data = None
broken = False
if exists_now:
    try:
        parsed = json.loads(raw)
        if isinstance(parsed, dict):
            data = parsed
        else:
            broken = True  # 최상위가 객체가 아님 — settings.json 형식이 아니다
    except json.JSONDecodeError:
        broken = True

if broken:
    # 파싱 불가 — 트레이스백으로 install.sh 전체를 죽이는 대신 이 파일만 백업하고
    # 빈 구조로 다시 시작한다. 이 훅의 등록은 그대로 계속 진행한다.
    bak = _backup_once() if pre_existed else None
    note = f" — 손상된 settings.json 을 {bak} 로 백업 후 새로 만듦" if bak else (
        " — 손상된 settings.json 을 이번 실행에서 이미 백업함, 새로 만듦"
    )
    print(f"fix:  settings.json{note}")
    data = {}
    pre_existed = False  # 이제부터는 "이번 실행이 새로 만든 파일"로 취급

if data is None:
    data = {}  # 파일이 원래 없었던 정상 경로

hooks = data.setdefault("hooks", {})
event_hooks = hooks.setdefault(event, [])


def _matches(entry: dict) -> bool:
    # matcher 문자열까지 정확히 같아야 한다고 보면, 사용자가 matcher 를 손봐 둔
    # 기존 등록을 "다른 등록"으로 오판해 같은 명령을 중복 등록한다. 같은 커맨드가
    # 이 이벤트 아래 이미 있으면(matcher 값과 무관하게) 등록된 것으로 본다.
    return any(h.get("command", "").strip() == hook_cmd for h in entry.get("hooks", []))


if any(_matches(e) for e in event_hooks):
    print(f"ok:   settings.json — {hook_name} 이미 등록됨 ({event})")
else:
    backup_note = ""
    if pre_existed:
        bak = _backup_once()
        if bak:
            backup_note = f" (백업: {bak})"

    new_entry = {"hooks": [{"type": "command", "command": hook_cmd}]}
    if matcher:
        new_entry = {"matcher": matcher, **new_entry}
    event_hooks.append(new_entry)

    settings_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    verb = "new" if not exists_now else "add"
    print(f"{verb}:  settings.json — {hook_name} 등록 ({event}){backup_note}")

if backup_done:
    backup_flag_path.write_text("1", encoding="utf-8")
PYEOF
  then
    echo "skip: settings.json — $name 등록 실패(내부 오류) — 다른 훅은 계속 설치함" >&2
  fi

  if [ "$(cat "$BACKUP_FLAG" 2>/dev/null || true)" = "1" ]; then
    BACKUP_DONE=1
  fi
  rm -f "$BACKUP_FLAG"
done
