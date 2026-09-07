#!/usr/bin/env bash
# systemd / cron / launchd 가 없는 호스트(코드서버 pod 등)용 사용자 권한 cron.
# supercronic(단일 바이너리)을 ~/.local/bin 에, crontab 을 ~/.config/ai-session-warmup/crontab 에 두고 detached 로 돌린다.
# 둘 다 PVC(홈)에 있으니 pod 가 재시작돼도 ~/.workspace-init.sh 훅이 `start` 를 다시 부르면 그대로 살아난다.
#
#   ai-session-warmup-cron.sh start        # 안 떠 있으면 띄운다. 기동 시 최근 WARMUP_CATCHUP_MIN 안에 놓친 슬롯은 한 번 보충
#   ai-session-warmup-cron.sh stop
#   ai-session-warmup-cron.sh status
#   ai-session-warmup-cron.sh render <providers...>   # crontab 을 다시 써서 stdout 에도 보여준다 (WARMUP_TIMES 반영)
#   ai-session-warmup-cron.sh ensure-binary           # supercronic 이 없으면 받아 sha1 검증 후 설치
#   ai-session-warmup-cron.sh install-hook            # ~/.workspace-init.sh 에 start 블록을 (한 번만) 넣는다
set -uo pipefail

ACTION="${1:-status}"; shift || true
BIN_DIR="$HOME/.local/bin"
SUPERCRONIC="$BIN_DIR/supercronic"
CONF_DIR="${WARMUP_CONF_DIR:-$HOME/.config/ai-session-warmup}"
CRONTAB="$CONF_DIR/crontab"
STATE_DIR="${WARMUP_STATE_DIR:-$HOME/.local/state/ai-session-warmup}"
LOG_DIR="${WARMUP_LOG_DIR:-$HOME/.local/log}"
PIDFILE="$STATE_DIR/supercronic.pid"
LOG="$LOG_DIR/ai-session-warmup-cron.log"
RUNNER="${WARMUP_RUNNER:-$BIN_DIR/ai-session-warmup.sh}"
TIMES="${WARMUP_TIMES:-08:00 13:01 18:02}"
CATCHUP_MIN="${WARMUP_CATCHUP_MIN:-60}"
HOOK="$HOME/.workspace-init.sh"
SUPERCRONIC_VERSION="${SUPERCRONIC_VERSION:-v0.2.49}"
SUPERCRONIC_SHA1="${SUPERCRONIC_SHA1:-e63c11a9726b775a6a11801e81af4f3fb926aa68}"   # linux-amd64
mkdir -p "$BIN_DIR" "$CONF_DIR" "$STATE_DIR" "$LOG_DIR"

log() { printf '%s  %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >>"$LOG"; }
alive() { [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

ensure_binary() {
  [ -x "$SUPERCRONIC" ] && return 0
  local found; found="$(command -v supercronic 2>/dev/null || true)"
  if [ -n "$found" ]; then cp "$found" "$SUPERCRONIC"; chmod 755 "$SUPERCRONIC"; return 0; fi
  local arch url tmp
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64; [ -n "${SUPERCRONIC_SHA1_ARM64:-}" ] || { echo "error: set SUPERCRONIC_SHA1_ARM64 for the arm64 build" >&2; return 1; }; SUPERCRONIC_SHA1="$SUPERCRONIC_SHA1_ARM64" ;;
    *) echo "error: unsupported arch $(uname -m)" >&2; return 1 ;;
  esac
  url="https://github.com/aptible/supercronic/releases/download/$SUPERCRONIC_VERSION/supercronic-linux-$arch"
  tmp="$(mktemp)"
  curl -fsSL --max-time 120 -o "$tmp" "$url" || { echo "error: download failed: $url" >&2; rm -f "$tmp"; return 1; }
  if [ "$(sha1sum "$tmp" | cut -d' ' -f1)" != "$SUPERCRONIC_SHA1" ]; then
    echo "error: sha1 mismatch for $url" >&2; rm -f "$tmp"; return 1
  fi
  install -m 755 "$tmp" "$SUPERCRONIC"; rm -f "$tmp"
  log "installed supercronic $SUPERCRONIC_VERSION -> $SUPERCRONIC"
}

render() {
  [ $# -gt 0 ] || set -- claude codex
  local p t hh mm
  {
    echo "# ai-session-warmup — 평일 $TIMES 에 5시간 사용 구간을 앉힌다. 생성: ai-session-warmup-cron.sh render $*"
    echo "# 시각을 바꾸려면 WARMUP_TIMES=\"08:00 13:01 18:02\" ai-session-warmup-cron.sh render $* 뒤 restart"
    for p in "$@"; do
      for t in $TIMES; do
        hh="${t%%:*}"; mm="${t#*:}"
        printf '%d %d * * 1-5 %s %s\n' "$((10#$mm))" "$((10#$hh))" "$RUNNER" "$p"
      done
    done
  } >"$CRONTAB"
  cat "$CRONTAB"
}

providers_from_crontab() { awk -v r="$RUNNER" '$6==r {print $7}' "$CRONTAB" 2>/dev/null | sort -u; }

# 기동 시점에 최근 CATCHUP_MIN 안에 지나간 평일 슬롯이 있고 아직 안 돌았으면 한 번 보충한다 (systemd Persistent=true 대용).
catch_up() {
  local now day t cand best=0 p marker rc
  now="$(date +%s)"
  for day in 0 1 2 3; do
    for t in $TIMES; do
      cand="$(date -d "$(date -d "@$now" +%F) -${day} day $t" +%s)"
      [ "$cand" -le "$now" ] && [ "$(date -d "@$cand" +%u)" -le 5 ] && [ "$cand" -gt "$best" ] && best="$cand"
    done
  done
  [ "$best" -gt 0 ] && [ $(( (now - best) / 60 )) -le "$CATCHUP_MIN" ] || return 0
  for p in $(providers_from_crontab); do
    marker="$STATE_DIR/done-$p-$(date -d "@$best" +%Y%m%d-%H%M)"
    [ -e "$marker" ] && continue
    "$RUNNER" "$p" >/dev/null 2>&1; rc=$?
    : >"$marker"
    log "catch-up provider=$p slot=$(date -d "@$best" +%F' '%H:%M) rc=$rc"
  done
  find "$STATE_DIR" -name 'done-*' -mtime +3 -delete 2>/dev/null
}

install_hook() {
  local begin="# >>> ai-session-warmup (pod 기동 시 사용자 cron 재시작) >>>" end="# <<< ai-session-warmup <<<"
  if [ -f "$HOOK" ] && grep -qF "$begin" "$HOOK"; then echo "hook already present: $HOOK"; return 0; fi
  [ -f "$HOOK" ] || printf '#!/usr/bin/env bash\n# pod 가 뜰 때마다 워크스페이스 유저로 실행되는 사용자 훅 (workspace-entrypoint.sh 6단계)\n' >"$HOOK"
  printf '\n%s\n[ -x "$HOME/.local/bin/ai-session-warmup-cron.sh" ] && "$HOME/.local/bin/ai-session-warmup-cron.sh" start >>"$HOME/.local/log/ai-session-warmup-cron.log" 2>&1\n%s\n' "$begin" "$end" >>"$HOOK"
  chmod 755 "$HOOK"
  echo "hook installed: $HOOK"
}

case "$ACTION" in
  ensure-binary) ensure_binary ;;
  catch-up) catch_up ;;
  render) render "$@" ;;
  install-hook) install_hook ;;
  start)
    [ -x "$RUNNER" ] || { echo "error: runner not found: $RUNNER (run scripts/install.sh first)" >&2; exit 1; }
    [ -s "$CRONTAB" ] || { echo "error: no crontab at $CRONTAB (run: $0 render claude codex)" >&2; exit 1; }
    ensure_binary || exit 1
    if alive; then echo "already running pid=$(cat "$PIDFILE")"; exit 0; fi
    "$SUPERCRONIC" -test "$CRONTAB" >/dev/null 2>&1 || { echo "error: crontab failed supercronic -test: $CRONTAB" >&2; exit 1; }
    setsid nohup "$SUPERCRONIC" -quiet "$CRONTAB" >>"$LOG" 2>&1 < /dev/null &
    echo $! >"$PIDFILE"
    sleep 1
    alive || { echo "error: supercronic did not start; see $LOG" >&2; rm -f "$PIDFILE"; exit 1; }
    log "start pid=$(cat "$PIDFILE") crontab=$CRONTAB"
    echo "started pid=$(cat "$PIDFILE") crontab=$CRONTAB"
    # 보충 실행은 분리해서 돌린다 — ~/.workspace-init.sh 는 엔트리포인트가 포그라운드로 부르므로 여기서 막히면 code-server 기동이 늦어진다
    setsid nohup "$0" catch-up >>"$LOG" 2>&1 < /dev/null &
    ;;
  stop)
    if alive; then kill "$(cat "$PIDFILE")"; log "stop pid=$(cat "$PIDFILE")"; rm -f "$PIDFILE"; echo "stopped"; else rm -f "$PIDFILE"; echo "not running"; fi
    ;;
  restart) "$0" stop >/dev/null; exec "$0" start ;;
  status)
    if alive; then echo "running pid=$(cat "$PIDFILE") supercronic=$("$SUPERCRONIC" -version 2>/dev/null || echo '?')"; else echo "not running"; fi
    [ -f "$CRONTAB" ] && { echo "--- $CRONTAB"; grep -v '^#' "$CRONTAB"; }
    [ -f "$HOOK" ] && grep -q 'ai-session-warmup' "$HOOK" && echo "hook: $HOOK (pod 기동 시 자동 start)" || echo "hook: none — run '$0 install-hook'"
    [ -f "$LOG" ] && { echo "--- $LOG"; tail -n 5 "$LOG"; }
    ;;
  *) echo "usage: $0 start | stop | restart | status | render <providers...> | ensure-binary | install-hook | catch-up" >&2; exit 2 ;;
esac
