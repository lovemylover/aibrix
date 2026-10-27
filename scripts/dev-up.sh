#!/usr/bin/env bash
# Start the full AIBrix stack on a local Kind cluster.
#
# What this script does:
#   1. Ensure a Kind cluster exists (create if missing)
#   2. Build all AIBrix container images
#   3. Install CRDs + dependencies + aibrix components
#   4. Pull dependent images on the host (using host proxy) and load into Kind
#      nodes (Kind nodes cannot use the host's 127.0.0.1 proxy)
#   5. Apply monitoring + vLLM mock configurations
#   6. Wait for core pods to become Ready
#   7. Start kubectl port-forward to Envoy Gateway (and Redis/Prometheus/Grafana
#      if available) in the background
#
# Usage:
#   scripts/dev-up.sh [--skip-build] [--mock <engine>]
#     --mock <engine>: only deploy the specified engine's mock StormService.
#                      Supported values: sglang, vllm, vllm-nixl, vllm-bucket,
#                      trtllm, none. Default (no flag) = deploy all mocks.
#                      --mock none is equivalent to the old --skip-mock.
#
# Prereqs:
#   - docker, kind, kubectl, go (1.22+ or 1.26 with GOTOOLCHAIN=local)
#   - Host proxy (e.g. clash on :7897) reachable from the host shell
#
# Notes:
#   - This script is idempotent on the cluster: it will reuse an existing Kind
#     cluster named "kind" if present.
#   - Set GOTOOLCHAIN=local in env if your host Go is newer than the toolchain
#     pinned in go.mod (avoids macOS dyld LC_UUID issues with old toolchains).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CLUSTER_NAME="${CLUSTER_NAME:-kind}"
K8S_VERSION="${K8S_VERSION:-v1.32.0}"
KIND_CONFIG="${KIND_CONFIG:-hack/ci/kind-config.yaml}"
ENVOY_GATEWAY_IMAGE="envoyproxy/gateway:v1.2.8"
ENVOY_IMAGE="envoyproxy/envoy:v1.33.2"
REDIS_IMAGE="redis:7.4"
BUSYBOX_IMAGE="busybox:stable"
KUBERAY_IMAGE="aibrix/kuberay-operator:v1.2.1-patch-20250726"
GATEWAY_LOCAL_PORT="${GATEWAY_LOCAL_PORT:-8888}"

SKIP_BUILD=0
MOCK_FILTER=""  # "" = all; or a single engine name (sglang/vllm/vllm-nixl/...); "none" = skip
while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-mock)  MOCK_FILTER="none" ;;  # back-compat
    --mock)       MOCK_FILTER="${2:-sglang}"; shift ;;
    --mock=*)     MOCK_FILTER="${arg#--mock=}" ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
  shift
done

# Validate MOCK_FILTER
case "$MOCK_FILTER" in
  ""|none|sglang|vllm|vllm-nixl|vllm-bucket|trtllm) ;;
  *) echo "Invalid --mock value: $MOCK_FILTER" >&2; exit 2 ;;
esac

log()  { echo -e "\033[1;34m[dev-up]\033[0m $*"; }
warn() { echo -e "\033[1;33m[dev-up] WARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[dev-up] FAIL:\033[0m $*" >&2; exit 1; }

# ---- 1. Kind cluster --------------------------------------------------------
log "Checking Kind cluster '$CLUSTER_NAME'..."
if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "Creating Kind cluster '$CLUSTER_NAME' (k8s $K8S_VERSION)..."
  kind create cluster --name "$CLUSTER_NAME" \
    --image "kindest/node:$K8S_VERSION" \
    --config "$KIND_CONFIG"
fi
kubectl cluster-info --context "kind-$CLUSTER_NAME" >/dev/null

# ---- 2. Build images --------------------------------------------------------
if [[ "$SKIP_BUILD" -eq 0 ]]; then
  log "Building AIBrix images (make docker-build-all)..."
  # Retry once on transient apt 502 (Debian CDN flakiness seen in CN networks)
  if ! GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make docker-build-all; then
    warn "First build attempt failed (likely transient apt 502). Retrying..."
    GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make docker-build-all
  fi
else
  log "Skipping image build (--skip-build)"
fi

# ---- 3. Install CRDs + dependencies + aibrix -------------------------------
log "Installing CRDs and dependencies (make install)..."
GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make install

log "Loading AIBrix images into Kind nodes..."
for img in controller-manager gateway-plugins runtime metadata-service kvcache-watcher; do
  kind load docker-image --name "$CLUSTER_NAME" "aibrix/$img:nightly" \
    || die "Failed to load aibrix/$img:nightly"
done

# dev-install-in-kind wraps install + load + apply test/mock/monitoring, but
# several sub-steps fail on missing external images. Run the pieces we control
# directly so the script is robust.
log "Applying aibrix default deployment..."
kubectl apply --server-side -f <(kustomize build config/default) 2>/dev/null \
  || GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make deploy AIBRIX_CONTAINER_REGISTRY_NAMESPACE=aibrix

log "Applying test configurations (config/test)..."
kubectl apply -k config/test || warn "config/test apply had errors"

# ---- 4. Pull dependent images on host, load into Kind ----------------------
# Kind nodes inherit host proxy env (e.g. HTTPS_PROXY=http://127.0.0.1:7897)
# but 127.0.0.1 inside a node is the node itself, so containerd cannot reach
# the host's proxy. Workaround: pull on the host (host proxy works) then
# `kind load` to inject into the node's containerd.
DEP_IMAGES=(
  "$ENVOY_GATEWAY_IMAGE"
  "$ENVOY_IMAGE"
  "$KUBERAY_IMAGE"
  "$REDIS_IMAGE"
  "$BUSYBOX_IMAGE"
)
log "Pulling dependent images on host and loading into Kind..."
for img in "${DEP_IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    log "  docker pull $img"
    docker pull "$img" || die "Failed to pull $img"
  fi
  kind load docker-image --name "$CLUSTER_NAME" "$img" \
    || die "Failed to load $img into Kind"
done

# The config/test deployment references aibrix/external-router-e2e:nightly,
# which is not published on Docker Hub and has no build target in this repo.
# Delete it so it doesn't sit in ImagePullBackOff forever.
log "Removing external-router-e2e deployment (image not published)..."
kubectl delete deploy -n aibrix-system external-router-e2e --ignore-not-found=true

# ---- 5. Mock + monitoring ---------------------------------------------------
if [[ "$MOCK_FILTER" != "none" ]]; then
  log "Building and loading vLLM mock..."
  (cd development/app && docker build -t aibrix/vllm-mock:nightly -f Dockerfile .)
  kind load docker-image --name "$CLUSTER_NAME" aibrix/vllm-mock:nightly

  if [[ -z "$MOCK_FILTER" ]]; then
    log "Applying config/mock (all engines)..."
    kubectl apply -k development/app/config/mock || warn "config/mock apply had errors"
  else
    # kustomize overlay at development/app/config/mock-<engine>-only/ bundles
    # shared components (ServiceAccount/RBAC) + the requested engine's StormService.
    # Use --load-restrictor=LoadRestrictionsNone because the overlay references
    # sibling files under ../mock/.
    overlay_dir="development/app/config/mock-${MOCK_FILTER}-only"
    if [[ ! -d "$overlay_dir" ]]; then
      die "No mock overlay at $overlay_dir; available: $(ls development/app/config/ | grep '^mock-' | tr '\n' ' ')"
    fi
    log "Applying mock overlay: $overlay_dir"
    KUSTOMIZE_BIN="${KUSTOMIZE_BIN:-bin/kustomize-v5.3.0}"
    if [[ ! -x "$KUSTOMIZE_BIN" ]]; then
      GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make kustomize
    fi
    GOTOOLCHAIN="${GOTOOLCHAIN:-local}" "$KUSTOMIZE_BIN" build \
      --load-restrictor=LoadRestrictionsNone "$overlay_dir" \
      | kubectl apply -f - || warn "mock overlay apply had errors"
  fi
fi

log "Applying Prometheus configurations (best-effort)..."
kubectl apply -k config/prometheus 2>/dev/null \
  || warn "Prometheus apply failed (non-fatal)"
for f in \
  observability/monitor/envoy_metrics_service.yaml \
  observability/monitor/service_monitor_controller_manager.yaml \
  observability/monitor/service_monitor_gateway_plugin.yaml \
  observability/monitor/service_monitor_gateway.yaml \
  observability/monitor/service_monitor_vllm.yaml; do
  kubectl apply -f "$f" 2>/dev/null || true
done

# ---- 6. Wait for core pods -------------------------------------------------
log "Waiting for aibrix-controller-manager to be Ready..."
kubectl wait --for=condition=Available --timeout=5m \
  deployment/aibrix-controller-manager -n aibrix-system \
  || warn "Controller manager not Ready after 5m"

log "Waiting for envoy-gateway to be Ready..."
kubectl wait --for=condition=Available --timeout=5m \
  deployment/envoy-gateway -n envoy-gateway-system \
  || warn "envoy-gateway not Ready after 5m"

log "Waiting for aibrix-gateway-plugins to be Ready..."
kubectl wait --for=condition=Available --timeout=5m \
  deployment/aibrix-gateway-plugins -n aibrix-system \
  || warn "aibrix-gateway-plugins not Ready after 5m"

# ---- 7. Port forward -------------------------------------------------------
PF_DIR="${PF_DIR:-$REPO_ROOT/.port-forward}"
mkdir -p "$PF_DIR"
start_pf() {
  local name="$1" ns="$2" svc="$3" local_port="$4" remote_port="$5"
  if lsof -i :"$local_port" -t >/dev/null 2>&1; then
    warn "Port $local_port already in use, skipping $name port-forward"
    return 0
  fi
  kubectl port-forward -n "$ns" "$svc" "$local_port:$remote_port" \
    >"$PF_DIR/$name.pf.log" 2>&1 &
  echo $! >"$PF_DIR/$name.pf.pid"
  log "  $name: localhost:$local_port -> $ns/$svc (PID $(cat "$PF_DIR/$name.pf.pid"))"
}

log "Starting port-forwards..."
start_pf envoy envoy-gateway-system \
  "service/envoy-aibrix-system-aibrix-eg-903790dc" \
  "$GATEWAY_LOCAL_PORT" 80
# Best-effort port-forwards for monitoring/redis
start_pf redis aibrix-system service/aibrix-redis-master 6379 6379
start_pf prometheus prometheus \
  service/prometheus-kube-prometheus-prometheus 9090 9090 2>/dev/null || true
start_pf grafana prometheus service/prometheus-grafana 3000 80 2>/dev/null || true

# ---- 8. Smoke test ---------------------------------------------------------
log "Smoke test: GET /v1/models on Envoy Gateway..."
sleep 3
if command -v curl >/dev/null; then
  code=$(curl -s -o /tmp/aibrix-models.json -w "%{http_code}" \
    "http://localhost:$GATEWAY_LOCAL_PORT/v1/models" || true)
  if [[ "$code" == "200" ]]; then
    log "  HTTP 200 — /v1/models returned $(jq -r '.data | length' /tmp/aibrix-models.json 2>/dev/null || echo '?') models"
  else
    warn "  Got HTTP $code (gateway may still be warming up)"
  fi
fi

cat <<EOF

============================================================
✅ AIBrix is up on Kind cluster '$CLUSTER_NAME'

Gateway:    http://localhost:$GATEWAY_LOCAL_PORT
            (e.g. curl http://localhost:$GATEWAY_LOCAL_PORT/v1/models)

Pods:
$(kubectl get pods -A | grep -v kube-system | sed 's/^/  /')

To stop everything: scripts/dev-down.sh
============================================================
EOF
