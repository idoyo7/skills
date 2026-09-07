#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARMUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_BIN="$HOME/.local/bin/ai-session-warmup.sh"
OS="$(uname -s)"
ACTION="${1:-install}"

install_common() {
  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required" >&2
    exit 1
  }
  mkdir -p "$HOME/.local/bin" "$HOME/.local/log" "$HOME/.cache/ai-session-warmup/cwd"
  cp "$SCRIPT_DIR/ai-session-warmup.sh" "$INSTALL_BIN"
  chmod 755 "$INSTALL_BIN"
}

render() {
  python3 - "$1" "$2" "$HOME" <<'PY'
from pathlib import Path
import sys

source, target, home = map(Path, sys.argv[1:])
target.write_text(source.read_text().replace("__HOME__", str(home)), encoding="utf-8")
PY
}

mac_install() {
  local agents="$HOME/Library/LaunchAgents" uid
  uid="$(id -u)"
  mkdir -p "$agents"
  local name
  for name in claude codex keepawake; do
    render "$WARMUP_DIR/templates/macos/io.github.idoyo7.ai-session-warmup.$name.plist" \
      "$agents/io.github.idoyo7.ai-session-warmup.$name.plist"
    plutil -lint "$agents/io.github.idoyo7.ai-session-warmup.$name.plist"
    launchctl bootout "gui/$uid" "$agents/io.github.idoyo7.ai-session-warmup.$name.plist" 2>/dev/null || true
    launchctl bootstrap "gui/$uid" "$agents/io.github.idoyo7.ai-session-warmup.$name.plist"
  done
  echo "installed: Claude and Codex launchd warmups at weekdays 08:00, 13:01, 18:02"
}

linux_install() {
  command -v systemctl >/dev/null 2>&1 || {
    echo "error: systemctl is required on Linux" >&2
    exit 1
  }
  local units="$HOME/.config/systemd/user"
  mkdir -p "$units"
  cp "$WARMUP_DIR/templates/linux/ai-session-warmup-claude.service" "$units/"
  cp "$WARMUP_DIR/templates/linux/ai-session-warmup-claude.timer" "$units/"
  cp "$WARMUP_DIR/templates/linux/ai-session-warmup-codex.service" "$units/"
  cp "$WARMUP_DIR/templates/linux/ai-session-warmup-codex.timer" "$units/"
  systemctl --user daemon-reload
  systemctl --user enable --now ai-session-warmup-claude.timer ai-session-warmup-codex.timer
  echo "installed: Claude and Codex systemd user timers at weekdays 08:00, 13:01, 18:02"
}

status() {
  case "$OS" in
    Darwin)
      launchctl print "gui/$(id -u)/io.github.idoyo7.ai-session-warmup.claude"
      launchctl print "gui/$(id -u)/io.github.idoyo7.ai-session-warmup.codex"
      launchctl print "gui/$(id -u)/io.github.idoyo7.ai-session-warmup.keepawake"
      ;;
    Linux)
      systemctl --user status ai-session-warmup-claude.timer ai-session-warmup-codex.timer --no-pager
      systemctl --user list-timers 'ai-session-warmup-*.timer' --no-pager
      ;;
    *) echo "error: unsupported OS: $OS" >&2; exit 1 ;;
  esac
}

uninstall() {
  case "$OS" in
    Darwin)
      local agents="$HOME/Library/LaunchAgents" uid
      uid="$(id -u)"
      local name
      for name in claude codex keepawake; do
        launchctl bootout "gui/$uid" "$agents/io.github.idoyo7.ai-session-warmup.$name.plist" 2>/dev/null || true
        rm -f "$agents/io.github.idoyo7.ai-session-warmup.$name.plist"
      done
      ;;
    Linux)
      systemctl --user disable --now ai-session-warmup-claude.timer ai-session-warmup-codex.timer 2>/dev/null || true
      rm -f "$HOME/.config/systemd/user/ai-session-warmup-claude.service" \
        "$HOME/.config/systemd/user/ai-session-warmup-claude.timer" \
        "$HOME/.config/systemd/user/ai-session-warmup-codex.service" \
        "$HOME/.config/systemd/user/ai-session-warmup-codex.timer"
      systemctl --user daemon-reload
      ;;
    *) echo "error: unsupported OS: $OS" >&2; exit 1 ;;
  esac
  rm -f "$INSTALL_BIN"
  echo "uninstalled: schedule and runner removed; logs retained"
}

case "$ACTION" in
  install)
    install_common
    case "$OS" in
      Darwin) mac_install ;;
      Linux) linux_install ;;
      *) echo "error: unsupported OS: $OS" >&2; exit 1 ;;
    esac
    ;;
  --status|status) status ;;
  --run|run)
    runner="$INSTALL_BIN"
    [ -x "$runner" ] || runner="$SCRIPT_DIR/ai-session-warmup.sh"
    "$runner" claude
    "$runner" codex
    ;;
  --uninstall|uninstall) uninstall ;;
  *)
    echo "usage: $0 [install|--status|--run|--uninstall]" >&2
    exit 2
    ;;
esac
