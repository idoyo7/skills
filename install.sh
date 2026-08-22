#!/usr/bin/env bash
# ~/.claude/skills/ 에 이 레포의 스킬들을 심링크로 걸고,
# Stop 훅(reply-check.py)을 ~/.claude/hooks/ 에 설치하며
# ~/.claude/settings.json 에 등록한다.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
    current="$(readlink -f "$dest")"
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
if [ "$NO_HOOKS" -eq 1 ]; then
  echo "skip: --no-hooks 플래그 — 훅 설치 단계 건너뜀"
  exit 0
fi

HOOKS_DIR="$HOME/.claude/hooks"
mkdir -p "$HOOKS_DIR"

HOOK_SRC="$REPO_DIR/hooks/reply-check/reply-check.py"
HOOK_DEST="$HOOKS_DIR/reply-check.py"

# 2-a. 심링크 설치
if [ -L "$HOOK_DEST" ]; then
  current_target="$(readlink -f "$HOOK_DEST")"
  if [ "$current_target" = "$HOOK_SRC" ]; then
    echo "ok:   reply-check.py (심링크 이미 올바름)"
  else
    ln -sfn "$HOOK_SRC" "$HOOK_DEST"
    echo "fix:  reply-check.py → $HOOK_SRC (다른 곳을 가리키던 링크 교체)"
  fi
elif [ -f "$HOOK_DEST" ]; then
  # 실파일이 있으면 내용 비교 후 처리
  if cmp -s "$HOOK_DEST" "$HOOK_SRC"; then
    # 내용이 같으면 조용히 심링크로 교체
    rm "$HOOK_DEST"
    ln -s "$HOOK_SRC" "$HOOK_DEST"
    echo "ok:   reply-check.py (실파일→심링크 교체, 내용 동일)"
  else
    # 다르면 백업 후 교체
    TS="$(date +%Y%m%dT%H%M%S)"
    cp "$HOOK_DEST" "${HOOK_DEST}.bak.${TS}"
    rm "$HOOK_DEST"
    ln -s "$HOOK_SRC" "$HOOK_DEST"
    echo "fix:  reply-check.py — 기존 파일을 ${HOOK_DEST}.bak.${TS} 로 백업 후 심링크 설치"
  fi
else
  ln -s "$HOOK_SRC" "$HOOK_DEST"
  echo "new:  reply-check.py → $HOOK_SRC"
fi

# 2-b. settings.json 등록
SETTINGS="$HOME/.claude/settings.json"
HOOK_CMD="python3 \$HOME/.claude/hooks/reply-check.py"

if [ ! -f "$SETTINGS" ]; then
  # 파일이 없으면 새로 생성
  python3 - <<PYEOF
import json, pathlib
s = {"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "$HOOK_CMD"}]}]}}
pathlib.Path("$SETTINGS").write_text(json.dumps(s, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print("new:  settings.json 생성 및 reply-check 등록")
PYEOF
else
  # 이미 존재하면 파이썬으로 읽고 확인/추가
  python3 - <<PYEOF
import json, pathlib, time

settings_path = pathlib.Path("$SETTINGS")
hook_cmd = "$HOOK_CMD"

data = json.loads(settings_path.read_text(encoding="utf-8"))
hooks = data.setdefault("hooks", {})
stop_hooks = hooks.setdefault("Stop", [])

# 이미 등록돼 있는지 확인
for entry in stop_hooks:
    for h in entry.get("hooks", []):
        if h.get("command", "").strip() == hook_cmd:
            print("ok:   settings.json — reply-check 이미 등록됨")
            raise SystemExit(0)

# 없으면 추가 (백업 먼저)
ts = time.strftime("%Y%m%dT%H%M%S")
bak = str(settings_path) + ".bak." + ts
pathlib.Path(bak).write_text(settings_path.read_text(encoding="utf-8"), encoding="utf-8")

stop_hooks.append({"hooks": [{"type": "command", "command": hook_cmd}]})
settings_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"add:  settings.json — reply-check 등록 (백업: {bak})")
PYEOF
fi
