#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap '[ -x "$TMP/cron-home/.local/bin/ai-session-warmup-cron.sh" ] && HOME="$TMP/cron-home" "$TMP/cron-home/.local/bin/ai-session-warmup-cron.sh" stop >/dev/null 2>&1; rm -rf "$TMP"' EXIT
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
case "$(cat "$TMP/codex.args")" in
  *"--ask-for-approval never --sandbox read-only --model "*" exec --ephemeral"*) ;;
  *) echo "FAIL: Codex global options must precede exec" >&2; exit 1 ;;
esac

# Installer tests shadow state-changing OS commands, so no live launchd/systemd jobs are touched.
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$MOCK_UNAME"' >"$TMP/bin/uname"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" >>"$MOCK_SYSTEM_LOG"' >"$TMP/bin/launchctl"
printf '%s\n' '#!/usr/bin/env bash' 'printf '\''%s\n'\'' "$*" >>"$MOCK_SYSTEM_LOG"' >"$TMP/bin/systemctl"
chmod +x "$TMP/bin/uname" "$TMP/bin/launchctl" "$TMP/bin/systemctl"

if command -v plutil >/dev/null 2>&1; then
  mac_home="$TMP/mac-home"
  mkdir -p "$mac_home"
  HOME="$mac_home" PATH="$TMP/bin:$ORIGINAL_PATH" MOCK_UNAME=Darwin \
    MOCK_SYSTEM_LOG="$TMP/launchctl.args" bash "$ROOT/scripts/install.sh"
  plutil -lint "$mac_home"/Library/LaunchAgents/*.plist >/dev/null
  grep -q 'bootstrap' "$TMP/launchctl.args"
else
  echo "skip: macOS installer test needs plutil"
fi

linux_home="$TMP/linux-home"
mkdir -p "$linux_home"
HOME="$linux_home" PATH="$TMP/bin:$ORIGINAL_PATH" MOCK_UNAME=Linux \
  MOCK_SYSTEM_LOG="$TMP/systemctl.args" bash "$ROOT/scripts/install.sh"
test -f "$linux_home/.config/systemd/user/ai-session-warmup-claude.timer"
test -f "$linux_home/.config/systemd/user/ai-session-warmup-codex.timer"
grep -q 'enable --now' "$TMP/systemctl.args"

# systemd 사용자 세션이 없는 Linux(코드서버 pod 등)는 supercronic 사용자 cron 으로 떨어져야 한다.
# supercronic 은 다운로드 대신 모킹한다 (-test 는 통과, 실행 시엔 잠들어 있는다).
printf '%s\n' '#!/usr/bin/env bash' 'exit 1' >"$TMP/bin/systemctl"
cron_home="$TMP/cron-home"
mkdir -p "$cron_home/.local/bin"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in -version) echo mock;; -test) exit 0;; *) exec sleep 300;; esac' >"$cron_home/.local/bin/supercronic"
chmod +x "$cron_home/.local/bin/supercronic"
cron_out="$(HOME="$cron_home" PATH="$TMP/bin:$ORIGINAL_PATH" MOCK_UNAME=Linux MOCK_ARGS="$TMP/cron.args" \
  WARMUP_PROVIDERS=claude WARMUP_CATCHUP_MIN=0 WARMUP_TZ=Asia/Seoul bash "$ROOT/scripts/install.sh")"
grep -q 'no systemd' <<<"$cron_out"
cron_bin="$cron_home/.local/bin/ai-session-warmup-cron.sh"
test -x "$cron_bin"
test ! -e "$cron_home/.config/systemd/user/ai-session-warmup-claude.timer"
crontab_file="$cron_home/.config/ai-session-warmup/crontab"
grep -q "^1 13 \* \* 1-5 $cron_home/.local/bin/ai-session-warmup.sh claude$" "$crontab_file"
[ "$(grep -v '^#' "$crontab_file" | grep -vc '^[A-Z_]*=')" -eq 3 ]
grep -q '^CRON_TZ=Asia/Seoul$' "$crontab_file"
grep -q '^TZ=Asia/Seoul$' "$crontab_file"
grep -q "^PATH=.*$cron_home/.local/bin:/usr/local/bin:/usr/bin:/bin$" "$crontab_file"
! grep -q ' codex$' "$crontab_file"
grep -q 'ai-session-warmup-cron.sh" start' "$cron_home/.workspace-init.sh"
HOME="$cron_home" "$cron_bin" install-hook >/dev/null
[ "$(grep -c '>>> ai-session-warmup' "$cron_home/.workspace-init.sh")" -eq 1 ]
cron_status="$(HOME="$cron_home" "$cron_bin" status)"
grep -q '^running pid=' <<<"$cron_status"
grep -q '^hook: ' <<<"$cron_status"
HOME="$cron_home" "$cron_bin" stop | grep -q '^stopped'
cron_status="$(HOME="$cron_home" "$cron_bin" status)"
grep -q '^not running' <<<"$cron_status"

# Kubernetes CronJob 렌더: kubectl 을 모킹해 pod 에서 image/PVC/레이블을 읽어 채우는지 본다.
k8s_home="$TMP/k8s-home"
mkdir -p "$k8s_home"
cat >"$TMP/bin/kubectl" <<'MOCK'
#!/usr/bin/env bash
case "$*" in
  *"get pod"*) printf '%s\n' '{"metadata":{"labels":{"app":"code-server"}},"spec":{"containers":[{"image":"example/ws:1","volumeMounts":[{"name":"ws","mountPath":"'"$K8S_HOME"'"}]}],"volumes":[{"name":"ws","persistentVolumeClaim":{"claimName":"ws-pvc"}}]}}' ;;
  *) printf '%s\n' "$*" >>"$MOCK_SYSTEM_LOG" ;;
esac
MOCK
chmod +x "$TMP/bin/kubectl"
k8s_out="$(HOME="$k8s_home" K8S_HOME="$k8s_home" PATH="$TMP/bin:$ORIGINAL_PATH" HOSTNAME=ws-pod \
  WARMUP_K8S_NAMESPACE=ns1 WARMUP_PROVIDERS=claude WARMUP_TZ=Asia/Seoul bash "$ROOT/scripts/install-k8s.sh" --render)"
[ "$(grep -c '^kind: CronJob' <<<"$k8s_out")" -eq 3 ]
grep -q 'name: ai-session-warmup-claude-1301' <<<"$k8s_out"
grep -q 'schedule: "1 13 \* \* 1-5"' <<<"$k8s_out"
grep -q 'claimName: ws-pvc' <<<"$k8s_out"
grep -q 'image: example/ws:1' <<<"$k8s_out"
grep -q 'app: code-server' <<<"$k8s_out"
grep -q 'sidecar.istio.io/inject: "false"' <<<"$k8s_out"
grep -q 'fsGroupChangePolicy: OnRootMismatch' <<<"$k8s_out"
! grep -q '__' <<<"$k8s_out"

echo "PASS: runners, macOS/Linux installers (systemd + supercronic user cron), k8s render"
