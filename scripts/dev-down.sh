#!/usr/bin/env bash
# Tear down an AIBrix stack started by scripts/dev-up.sh.
#
# What this script does:
#   1. Stop all kubectl port-forward sessions started by dev-up.sh
#   2. (Optional) Uninstall CRDs and aibrix components from the cluster
#   3. (Optional) Delete the Kind cluster entirely
#
# Usage:
#   scripts/dev-down.sh                # stop port-forwards only (default)
#   scripts/dev-down.sh --undeploy     # also remove aibrix from the cluster
#   scripts/dev-down.sh --delete-cluster  # also delete the Kind cluster
#
# Flags can be combined. Order matters: stop port-forwards, then undeploy,
# then delete cluster.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-kind}"
PF_DIR="${PF_DIR:-$REPO_ROOT/.port-forward}"

UNDEPLOY=0
DELETE_CLUSTER=0
for arg in "$@"; do
  case "$arg" in
    --undeploy)        UNDEPLOY=1 ;;
    --delete-cluster)  DELETE_CLUSTER=1 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
done

log()  { echo -e "\033[1;34m[dev-down]\033[0m $*"; }
warn() { echo -e "\033[1;33m[dev-down] WARN:\033[0m $*" >&2; }

# ---- 1. Stop port-forwards --------------------------------------------------
log "Stopping kubectl port-forward sessions..."
if [[ -d "$PF_DIR" ]]; then
  for pidfile in "$PF_DIR"/*.pf.pid; do
    [[ -e "$pidfile" ]] || continue
    name="$(basename "$pidfile" .pf.pid)"
    pid="$(cat "$pidfile" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      log "  Stopped $name (PID $pid)"
    else
      warn "  $name PID $pid not running (stale pidfile)"
    fi
    rm -f "$pidfile"
  done
fi

# Also clean up pid files that scripts/port-forward.sh writes to repo root
# (in case anyone used `make dev-port-forward`).
for legacy in .envoy-pf.pid .redis-pf.pid .prometheus-pf.pid .grafana-pf.pid; do
  if [[ -f "$legacy" ]]; then
    pid="$(cat "$legacy" 2>/dev/null || true)"
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
    rm -f "$legacy"
  fi
done

# If nothing is left to do, exit. Otherwise we still want to delete/uninstall.
if [[ "$UNDEPLOY" -eq 0 && "$DELETE_CLUSTER" -eq 0 ]]; then
  log "Port-forwards stopped. Cluster and aibrix deployment left intact."
  log "Re-run with --undeploy to remove aibrix from the cluster,"
  log "or --delete-cluster to delete the Kind cluster entirely."
  exit 0
fi

# Make sure kubectl can talk to the cluster before we try to undeploy.
if ! kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null 2>&1; then
  warn "Kind cluster '$CLUSTER_NAME' not reachable — skipping undeploy."
  DELETE_CLUSTER=0
fi

# ---- 2. Undeploy aibrix ----------------------------------------------------
if [[ "$UNDEPLOY" -eq 1 ]]; then
  log "Removing vLLM mock (config/mock)..."
  kubectl delete -k config/mock --ignore-not-found=true 2>/dev/null || true

  log "Removing monitoring configurations..."
  for f in \
    observability/monitor/envoy_metrics_service.yaml \
    observability/monitor/service_monitor_controller_manager.yaml \
    observability/monitor/service_monitor_gateway_plugin.yaml \
    observability/monitor/service_monitor_gateway.yaml \
    observability/monitor/service_monitor_vllm.yaml; do
    kubectl delete -f "$f" --ignore-not-found=true 2>/dev/null || true
  done
  kubectl delete -k config/prometheus --ignore-not-found=true 2>/dev/null || true

  log "Removing test configurations (config/test)..."
  kubectl delete -k config/test --ignore-not-found=true 2>/dev/null || true

  log "Undeploying aibrix controller (make undeploy)..."
  GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make undeploy ignore-not-found=true \
    || warn "make undeploy had errors (continuing)"

  log "Uninstalling CRDs and dependencies (make uninstall)..."
  GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make uninstall ignore-not-found=true \
    || warn "make uninstall had errors (continuing)"

  log "Undeploy complete. Kind cluster '$CLUSTER_NAME' still exists."
fi

# ---- 3. Delete Kind cluster ------------------------------------------------
if [[ "$DELETE_CLUSTER" -eq 1 ]]; then
  log "Deleting Kind cluster '$CLUSTER_NAME'..."
  kind delete cluster --name "$CLUSTER_NAME" \
    || warn "kind delete cluster had errors"
  log "Cluster deleted. All aibrix state is gone."
fi

log "Done."
