#!/usr/bin/env bash
set -uo pipefail

PROVIDER="${1:-}"
case "$PROVIDER" in
  claude|codex) ;;
  *) echo "usage: $0 <claude|codex>" >&2; exit 2 ;;
esac

LOG_DIR="${WARMUP_LOG_DIR:-$HOME/.local/log}"
LOG="$LOG_DIR/ai-session-warmup-$PROVIDER.log"
WORKDIR="${WARMUP_WORKDIR:-$HOME/.cache/ai-session-warmup/cwd}"

mkdir -p "$LOG_DIR" "$WORKDIR"

find_binary() {
  local command_name override override_name candidate version found
  case "$PROVIDER" in
    claude) command_name=claude; override="${CLAUDE_BIN:-}"; override_name=CLAUDE_BIN ;;
    codex) command_name=codex; override="${CODEX_BIN:-}"; override_name=CODEX_BIN ;;
  esac

  if [ -n "$override" ]; then
    [ -x "$override" ] || {
      echo "$command_name override is not executable: $override" >&2
      return 1
    }
    printf '%s\n' "$override"
    return 0
  fi

  found="$(command -v "$command_name" 2>/dev/null || true)"
  if [ -n "$found" ] && [ -x "$found" ]; then
    printf '%s\n' "$found"
    return 0
  fi

  for candidate in \
    "$HOME/.local/bin/$command_name" \
    "$HOME/.claude/local/$command_name" \
    "$HOME/.bun/bin/$command_name" \
    "$HOME/.npm-global/bin/$command_name" \
    "/opt/homebrew/bin/$command_name" \
    "/usr/local/bin/$command_name"; do
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  for version in "$HOME"/.nvm/versions/node/*; do
    candidate="$version/bin/$command_name"
    if [ -x "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  echo "$command_name executable not found; set $override_name to an absolute path" >&2
  return 1
}

BIN="$(find_binary)" || exit 127
cd "$WORKDIR" || exit 1

run_once() {
  case "$PROVIDER" in
    claude)
      "$BIN" -p "Reply with the single word: ok" \
        --safe-mode \
        --model "${CLAUDE_WARMUP_MODEL:-haiku}" \
        --tools "" \
        --no-session-persistence \
        --system-prompt "You are a minimal health-check responder. Answer in as few words as possible." \
        --output-format json
      ;;
    codex)
      "$BIN" exec \
        --ephemeral \
        --ignore-user-config \
        --ignore-rules \
        --skip-git-repo-check \
        --sandbox read-only \
        --ask-for-approval never \
        --model "${CODEX_WARMUP_MODEL:-gpt-5.6-luna}" \
        "Reply with the single word: ok"
      ;;
  esac
}

attempt=0
rc=1
out=""
while [ "$attempt" -lt 3 ]; do
  attempt=$((attempt + 1))
  out="$(run_once 2>&1)"
  rc=$?
  [ "$rc" -eq 0 ] && break
  [ "$attempt" -lt 3 ] && sleep "${WARMUP_RETRY_DELAY:-20}"
done

compact="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-500)"
printf '%s  provider=%s rc=%s attempt=%s output=%q\n' \
  "$(date +%Y-%m-%dT%H:%M:%S%z)" "$PROVIDER" "$rc" "$attempt" "$compact" >>"$LOG"

exit "$rc"
