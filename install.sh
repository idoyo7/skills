#!/usr/bin/env bash
# ~/.claude/skills/ 에 이 레포의 스킬들을 심링크로 건다.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"
mkdir -p "$SKILLS_DIR"

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
