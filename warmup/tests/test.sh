#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/home"
ORIGINAL_PATH="$PATH"

make_mock() {
  local name="$1"
  printf '%s\n' '#!/usr/bin/env bash' \
    'printf '\''%s\n'\'' "$*" >>"$MOCK_ARGS"' \
    'printf '\''ok\n'\''' >"$TMP/bin/$name"
  chmod +x "$TMP/bin/$name"
}

make_mock claude
make_mock codex

for provider in claude codex; do
  args="$TMP/$provider.args"
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" MOCK_ARGS="$args" \
    WARMUP_RETRY_DELAY=0 bash "$ROOT/scripts/ai-session-warmup.sh" "$provider"
  grep -q "Reply with the single word: ok" "$args"
  grep -q "provider=$provider rc=0" "$TMP/home/.local/log/ai-session-warmup-$provider.log"
done

grep -q -- '--no-session-persistence' "$TMP/claude.args"
grep -q -- '--safe-mode' "$TMP/claude.args"
grep -q -- '--ephemeral' "$TMP/codex.args"
grep -q -- '--ignore-user-config' "$TMP/codex.args"
grep -q -- '--sandbox read-only' "$TMP/codex.args"

# Installer tests shadow state-changing OS commands, so no live launchd/systemd jobs are touched.
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$MOCK_UNAME"' >"$TMP/bin/uname"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" >>"$MOCK_SYSTEM_LOG"' >"$TMP/bin/launchctl"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" >>"$MOCK_SYSTEM_LOG"' >"$TMP/bin/systemctl"
chmod +x "$TMP/bin/uname" "$TMP/bin/launchctl" "$TMP/bin/systemctl"

mac_home="$TMP/mac-home"
mkdir -p "$mac_home"
HOME="$mac_home" PATH="$TMP/bin:$ORIGINAL_PATH" MOCK_UNAME=Darwin \
  MOCK_SYSTEM_LOG="$TMP/launchctl.args" bash "$ROOT/scripts/install.sh"
plutil -lint "$mac_home"/Library/LaunchAgents/*.plist >/dev/null
grep -q 'bootstrap' "$TMP/launchctl.args"

linux_home="$TMP/linux-home"
mkdir -p "$linux_home"
HOME="$linux_home" PATH="$TMP/bin:$ORIGINAL_PATH" MOCK_UNAME=Linux \
  MOCK_SYSTEM_LOG="$TMP/systemctl.args" bash "$ROOT/scripts/install.sh"
test -f "$linux_home/.config/systemd/user/ai-session-warmup-claude.timer"
test -f "$linux_home/.config/systemd/user/ai-session-warmup-codex.timer"
grep -q 'enable --now' "$TMP/systemctl.args"

echo "PASS: runners and macOS/Linux installers"
