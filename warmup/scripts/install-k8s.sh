#!/usr/bin/env bash
# Kubernetes 워크스페이스 pod(코드서버 등) 안에서 실행한다. systemd/cron 없이도 pod 재시작에 살아남는
# CronJob 을 클러스터에 건다 — 같은 PVC(홈)를 마운트해 ~/.local/bin/ai-session-warmup.sh 를 부른다.
#
#   install-k8s.sh [install]   # 현재 pod 에서 image/PVC/namespace 를 읽어 CronJob 을 apply
#   install-k8s.sh --render    # apply 없이 렌더한 manifest 만 stdout 으로
#   install-k8s.sh --status
#   install-k8s.sh --run       # 지금 바로 Job 하나 띄워 로그까지 보여준다 (사용량을 조금 쓴다)
#   install-k8s.sh --uninstall
#
# 환경변수 (자동 감지 값을 덮는다): WARMUP_PROVIDERS="claude codex"  WARMUP_TZ=Asia/Seoul
#   WARMUP_K8S_NAMESPACE  WARMUP_K8S_IMAGE  WARMUP_K8S_PVC  WARMUP_K8S_POD (기본 $HOSTNAME)
#   WARMUP_K8S_AFFINITY=key=value (기본: pod 의 app 레이블)  WARMUP_TIMES="08:00 13:01 18:02"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WARMUP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$WARMUP_DIR/templates/k8s/ai-session-warmup-cronjob.yaml"
INSTALL_BIN="$HOME/.local/bin/ai-session-warmup.sh"
ACTION="${1:-install}"
WHOAMI="$(id -un)"
PROVIDERS="${WARMUP_PROVIDERS:-claude codex}"
TIMES="${WARMUP_TIMES:-08:00 13:01 18:02}"
SELECTOR="app.kubernetes.io/name=ai-session-warmup,app.kubernetes.io/instance=${WARMUP_K8S_INSTANCE:-$WHOAMI}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "error: $1 is required" >&2; exit 1; }; }
need kubectl; need python3

NS="${WARMUP_K8S_NAMESPACE:-}"
[ -n "$NS" ] || NS="$(cat /var/run/secrets/kubernetes.io/serviceaccount/namespace 2>/dev/null || true)"
[ -n "$NS" ] || NS="$(kubectl config view --minify -o jsonpath='{..namespace}' 2>/dev/null || true)"
[ -n "$NS" ] || { echo "error: namespace unknown; set WARMUP_K8S_NAMESPACE" >&2; exit 1; }

detect_from_pod() {
  local pod="${WARMUP_K8S_POD:-$HOSTNAME}"
  kubectl get pod "$pod" -n "$NS" -o json | python3 -c '
import json, sys
p = json.load(sys.stdin); s = p["spec"]; c = s["containers"][0]
home = __import__("os").environ["HOME"]
pvc = next((v["persistentVolumeClaim"]["claimName"] for v in s.get("volumes", []) if "persistentVolumeClaim" in v
            and any(m["mountPath"] == home for m in c.get("volumeMounts", []) if m["name"] == v["name"])), "")
labels = p["metadata"].get("labels", {})
key = next((k for k in ("app.kubernetes.io/name", "app") if k in labels), "")
print(c["image"]); print(pvc); print(key); print(labels.get(key, ""))
'
}

render() {
  local image="${WARMUP_K8S_IMAGE:-}" pvc="${WARMUP_K8S_PVC:-}" akey="" aval=""
  if [ -n "${WARMUP_K8S_AFFINITY:-}" ]; then akey="${WARMUP_K8S_AFFINITY%%=*}"; aval="${WARMUP_K8S_AFFINITY#*=}"; fi
  if [ -z "$image" ] || [ -z "$pvc" ] || [ -z "$akey" ]; then
    local d_image d_pvc d_key d_val
    { read -r d_image; read -r d_pvc; read -r d_key; read -r d_val; } < <(detect_from_pod)
    image="${image:-$d_image}"; pvc="${pvc:-$d_pvc}"
    [ -n "$akey" ] || { akey="$d_key"; aval="$d_val"; }
  fi
  [ -n "$image" ] && [ -n "$pvc" ] && [ -n "$akey" ] || {
    echo "error: could not detect image/PVC/affinity label from pod; set WARMUP_K8S_IMAGE, WARMUP_K8S_PVC, WARMUP_K8S_AFFINITY" >&2
    exit 1
  }
  local tz="${WARMUP_TZ:-${TZ:-$(cat /etc/timezone 2>/dev/null || echo Asia/Seoul)}}"
  local provider t hh mm name
  for provider in $PROVIDERS; do
    for t in $TIMES; do
      hh="${t%%:*}"; mm="${t#*:}"
      name="ai-session-warmup-${provider}-${hh}${mm}"
      python3 - "$TEMPLATE" <<PY
from pathlib import Path
import sys
subs = {
  "__NAME__": "$name", "__NAMESPACE__": "$NS", "__INSTANCE__": "${WARMUP_K8S_INSTANCE:-$WHOAMI}",
  "__PROVIDER__": "$provider", "__SCHEDULE__": "$((10#$mm)) $((10#$hh)) * * 1-5", "__TIMEZONE__": "$tz",
  "__UID__": "$(id -u)", "__GID__": "$(id -g)", "__AFFINITY_KEY__": "$akey", "__AFFINITY_VALUE__": "$aval",
  "__PVC__": "$pvc", "__IMAGE__": "$image", "__HOME__": "$HOME", "__USER__": "$WHOAMI",
}
s = Path(sys.argv[1]).read_text()
for k, v in subs.items():
    s = s.replace(k, v)
print("---"); print(s, end="")
PY
    done
  done
}

install_runner() {
  mkdir -p "$HOME/.local/bin" "$HOME/.local/log" "$HOME/.cache/ai-session-warmup/cwd"
  cp "$SCRIPT_DIR/ai-session-warmup.sh" "$INSTALL_BIN"
  chmod 755 "$INSTALL_BIN"
}

case "$ACTION" in
  install)
    install_runner
    render | kubectl apply -f -
    echo "installed: CronJobs in namespace $NS for providers [$PROVIDERS] at weekdays $TIMES — survive pod restarts; check with $0 --status"
    ;;
  --render|render) render ;;
  --status|status)
    kubectl get cronjob,job -n "$NS" -l "$SELECTOR" -o wide
    ;;
  --run|run)
    for provider in $PROVIDERS; do
      first="$(set -- $TIMES; echo "$1")"; hh="${first%%:*}"; mm="${first#*:}"
      cj="ai-session-warmup-${provider}-${hh}${mm}"
      job="${cj}-manual-$(date +%H%M%S)"
      kubectl create job -n "$NS" --from="cronjob/$cj" "$job"
      kubectl wait -n "$NS" --for=condition=complete --timeout=300s "job/$job" || true
      kubectl logs -n "$NS" "job/$job" --tail=20 || true
    done
    ;;
  --uninstall|uninstall)
    kubectl delete cronjob,job -n "$NS" -l "$SELECTOR" --ignore-not-found
    echo "uninstalled: CronJobs removed; runner and logs on the PVC retained"
    ;;
  *)
    echo "usage: $0 [install|--render|--status|--run|--uninstall]" >&2
    exit 2
    ;;
esac
