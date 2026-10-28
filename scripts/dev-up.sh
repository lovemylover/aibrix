#!/usr/bin/env bash
# Start the full AIBrix stack on a local Kind cluster OR an existing
# Kubernetes cluster.
#
# What this script does:
#   1. Ensure a cluster is reachable (create Kind cluster if --cluster=kind;
#      otherwise assume an existing cluster is already configured in kubeconfig)
#   2. Build all AIBrix container images (optional, --skip-build to skip)
#   3. Install CRDs + dependencies + aibrix components
#   4. Make built images available to the cluster:
#        - kind mode: `kind load docker-image` to inject into Kind nodes
#        - existing mode: push to a registry via --registry=<reg>
#      (also pull dependent images: envoy-gateway, redis, etc.)
#   5. Apply monitoring + vLLM mock configurations
#   6. Wait for core pods to become Ready
#   7. Start kubectl port-forward to Envoy Gateway (and Redis/Prometheus/Grafana
#      if available) in the background
#
# Usage:
#   scripts/dev-up.sh [flags]
#
# Flags:
#   --cluster kind|existing     Cluster mode:
#                                  kind     = create/use a local Kind cluster
#                                             (default; prereqs: docker + kind)
#                                  existing = use the cluster already configured
#                                             in ~/.kube/config (prereq: kubectl
#                                             can already reach the cluster)
#   --registry <url>            When --cluster=existing, push aibrix images to
#                               this registry. e.g. --registry=docker.io/myuser
#                               or --registry=registry.internal:5000/aibrix
#   --skip-build                Skip `make docker-build-all` (use cached images)
#   --mock <engine>             Only deploy the specified engine's mock
#                               StormService. Supported: sglang, vllm,
#                               vllm-nixl, vllm-bucket, trtllm, none.
#                               Default (no flag) = deploy all mocks.
#                               --mock none is equivalent to the old --skip-mock.
#   --no-port-forward           Do not start kubectl port-forward sessions.
#                               (Use this on a remote server where you'll
#                               access via Service LB / Ingress instead.)
#   --kube-context <name>       Override the kube context to use. Default:
#                               auto-detected (current-context if existing mode,
#                               "kind-<name>" if kind mode).
#
# Environment variables that affect behavior:
#   CLUSTER_NAME       Kind cluster name (default: kind)
#   K8S_VERSION        Kind node k8s version (default: v1.32.0)
#   KIND_CONFIG        Kind config yaml (default: hack/ci/kind-config.yaml)
#   GATEWAY_LOCAL_PORT Local port for envoy gateway port-forward (default: 8888)
#   GOTOOLCHAIN        Go toolchain selection. Set to "local" if your host Go is
#                      newer than the toolchain pinned in go.mod.
#   IMAGE_TAG          Docker image tag to build/push (default: git commit hash
#                      + 'nightly' alias)
#   HTTPS_PROXY / HTTP_PROXY / NO_PROXY
#                      Standard proxy env vars. Honored by `docker pull` on the
#                      host. Kind nodes will inherit these too, BUT in kind mode
#                      127.0.0.1 proxies cannot be reached from inside a node,
#                      so this script also pulls dependent images on the host
#                      and `kind load`s them.
#
# Prereqs (kind mode):
#   - docker, kind, kubectl, make, go (1.22+ or 1.26 with GOTOOLCHAIN=local)
#
# Prereqs (existing mode):
#   - docker, kubectl, make, go (1.22+ or 1.26 with GOTOOLCHAIN=local)
#   - Push access to the registry specified via --registry
#   - kubectl already configured to talk to the cluster (kubeconfig)
#
# Notes:
#   - The script is idempotent on the cluster: re-running it will reconcile
#     resources in-place.
#   - For Linux + an existing cluster, see docs/quickstart-linux.md.
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

CLUSTER_MODE="kind"        # kind | existing
REGISTRY=""                # for existing mode
SKIP_BUILD=0
MOCK_FILTER=""             # "" = all; or one of: sglang/vllm/vllm-nixl/vllm-bucket/trtllm/none
NO_PORT_FORWARD=0
KUBE_CONTEXT=""

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --cluster)       CLUSTER_MODE="${2:-kind}"; shift ;;
    --cluster=*)     CLUSTER_MODE="${arg#--cluster=}" ;;
    --registry)      REGISTRY="${2:-}"; shift ;;
    --registry=*)    REGISTRY="${arg#--registry=}" ;;
    --skip-build)    SKIP_BUILD=1 ;;
    --skip-mock)     MOCK_FILTER="none" ;;  # back-compat
    --mock)          MOCK_FILTER="${2:-sglang}"; shift ;;
    --mock=*)        MOCK_FILTER="${arg#--mock=}" ;;
    --no-port-forward) NO_PORT_FORWARD=1 ;;
    --kube-context)  KUBE_CONTEXT="${2:-}"; shift ;;
    --kube-context=*) KUBE_CONTEXT="${arg#--kube-context=}" ;;
    -h|--help)       sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown arg: $arg" >&2; exit 2 ;;
  esac
  shift
done

# Validate flags
case "$CLUSTER_MODE" in
  kind|existing) ;;
  *) echo "Invalid --cluster value: $CLUSTER_MODE (expected: kind|existing)" >&2; exit 2 ;;
esac
case "$MOCK_FILTER" in
  ""|none|sglang|vllm|vllm-nixl|vllm-bucket|trtllm) ;;
  *) echo "Invalid --mock value: $MOCK_FILTER" >&2; exit 2 ;;
esac
if [[ "$CLUSTER_MODE" == "existing" && -z "$REGISTRY" && "$SKIP_BUILD" -eq 0 ]]; then
  echo "ERROR: --cluster=existing requires --registry=<url> when building images" >&2
  echo "       (or pass --skip-build if images are already in the registry)" >&2
  exit 2
fi

log()  { echo -e "\033[1;34m[dev-up]\033[0m $*"; }
warn() { echo -e "\033[1;33m[dev-up] WARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[dev-up] FAIL:\033[0m $*" >&2; exit 1; }

# Resolve kube context
if [[ -n "$KUBE_CONTEXT" ]]; then
  KUBECTL="kubectl --context=$KUBE_CONTEXT"
elif [[ "$CLUSTER_MODE" == "kind" ]]; then
  KUBECTL="kubectl --context=kind-$CLUSTER_NAME"
else
  KUBECTL="kubectl"  # use current-context
fi

# ---- 1. Cluster reachability ------------------------------------------------
if [[ "$CLUSTER_MODE" == "kind" ]]; then
  log "Checking Kind cluster '$CLUSTER_NAME'..."
  if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "Creating Kind cluster '$CLUSTER_NAME' (k8s $K8S_VERSION)..."
    kind create cluster --name "$CLUSTER_NAME" \
      --image "kindest/node:$K8S_VERSION" \
      --config "$KIND_CONFIG"
  fi
  $KUBECTL cluster-info >/dev/null
else
  log "Using existing Kubernetes cluster (context: $(kubectl config current-context 2>/dev/null || echo 'unknown'))..."
  $KUBECTL cluster-info >/dev/null \
    || die "kubectl cannot reach the cluster. Set KUBECONFIG or pass --kube-context."
fi

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

# Make built images available to the cluster.
AIBRIX_IMAGES=(controller-manager gateway-plugins runtime metadata-service kvcache-watcher)
if [[ "$CLUSTER_MODE" == "kind" ]]; then
  log "Loading AIBrix images into Kind nodes..."
  for img in "${AIBRIX_IMAGES[@]}"; do
    kind load docker-image --name "$CLUSTER_NAME" "aibrix/$img:nightly" \
      || die "Failed to load aibrix/$img:nightly into kind"
  done
else
  # existing mode: retag and push to user's registry
  log "Pushing AIBrix images to registry: $REGISTRY"
  for img in "${AIBRIX_IMAGES[@]}"; do
    docker tag "aibrix/$img:nightly" "$REGISTRY/$img:nightly"
    docker push "$REGISTRY/$img:nightly" \
      || die "Failed to push $REGISTRY/$img:nightly"
  done
  # tell the deployment to use the registry-prefixed image
  log "Patching deployments to use registry $REGISTRY..."
  for img in "${AIBRIX_IMAGES[@]}"; do
    $KUBECTL set image "deployment/aibrix-$img" -n aibrix-system \
      "aibrix-$img=$REGISTRY/$img:nightly" 2>/dev/null || true
  done
fi

# Apply default deployment (for kind mode, this is idempotent; for existing
# mode the patches above will be respected after this apply).
log "Applying aibrix default deployment..."
GOTOOLCHAIN="${GOTOOLCHAIN:-local}" make deploy AIBRIX_CONTAINER_REGISTRY_NAMESPACE=aibrix \
  || warn "make deploy had errors (may already be applied)"

log "Applying test configurations (config/test)..."
$KUBECTL apply -k config/test || warn "config/test apply had errors"

# ---- 4. Pull dependent images on host, load into cluster --------------------
# Kind nodes inherit host proxy env (e.g. HTTPS_PROXY=http://127.0.0.1:7897)
# but 127.0.0.1 inside a node is the node itself, so containerd cannot reach
# the host's proxy. Workaround: pull on the host (host proxy works) then
# `kind load` to inject into the node's containerd.
#
# For existing cluster mode: if the cluster's nodes can reach the registry
# directly (with their own proxy config), this pull is still useful to pre-warm
# the host cache, but the cluster will pull on its own anyway.
DEP_IMAGES=(
  "$ENVOY_GATEWAY_IMAGE"
  "$ENVOY_IMAGE"
  "$KUBERAY_IMAGE"
  "$REDIS_IMAGE"
  "$BUSYBOX_IMAGE"
)
log "Pulling dependent images on host..."
for img in "${DEP_IMAGES[@]}"; do
  if ! docker image inspect "$img" >/dev/null 2>&1; then
    log "  docker pull $img"
    docker pull "$img" || die "Failed to pull $img"
  fi
done

if [[ "$CLUSTER_MODE" == "kind" ]]; then
  log "Loading dependent images into Kind nodes..."
  for img in "${DEP_IMAGES[@]}"; do
    kind load docker-image --name "$CLUSTER_NAME" "$img" \
      || die "Failed to load $img into Kind"
  done
else
  # For existing cluster: nodes pull directly from the registry. If they
  # can't (air-gapped), the user is expected to manually pre-load them or
  # configure imagePullSecrets. We just warn.
  warn "Existing-cluster mode: assuming cluster nodes can pull from docker.io."
  warn "  If your cluster is air-gapped, manually push these images to"
  warn "  your internal registry and update the deployment image refs:"
  for img in "${DEP_IMAGES[@]}"; do
    warn "    - $img"
  done
fi

# The config/test deployment references aibrix/external-router-e2e:nightly,
# which is not published on Docker Hub and has no build target in this repo.
# Delete it so it doesn't sit in ImagePullBackOff forever.
log "Removing external-router-e2e deployment (image not published)..."
$KUBECTL delete deploy -n aibrix-system external-router-e2e --ignore-not-found=true

# ---- 5. Mock + monitoring ---------------------------------------------------
if [[ "$MOCK_FILTER" != "none" ]]; then
  log "Building and loading vLLM mock..."
  (cd development/app && docker build -t aibrix/vllm-mock:nightly -f Dockerfile .)
  if [[ "$CLUSTER_MODE" == "kind" ]]; then
    kind load docker-image --name "$CLUSTER_NAME" aibrix/vllm-mock:nightly
  else
    docker tag "aibrix/vllm-mock:nightly" "$REGISTRY/vllm-mock:nightly"
    docker push "$REGISTRY/vllm-mock:nightly" \
      || die "Failed to push $REGISTRY/vllm-mock:nightly"
    # patch the mock StormService image? StormService template's image field
    # is in the role template — simplest is to kubectl edit later if needed.
    warn "Existing-cluster mode: mock image pushed to $REGISTRY/vllm-mock:nightly"
    warn "  StormService mock config uses 'aibrix/vllm-mock:nightly'."
    warn "  If the cluster can't pull from docker.io/aibrix, manually patch"
    warn "  the mock StormService role templates to use $REGISTRY/vllm-mock:nightly."
  fi

  if [[ -z "$MOCK_FILTER" ]]; then
    log "Applying config/mock (all engines)..."
    $KUBECTL apply -k development/app/config/mock || warn "config/mock apply had errors"
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
      | $KUBECTL apply -f - || warn "mock overlay apply had errors"
  fi
fi

log "Applying Prometheus configurations (best-effort)..."
$KUBECTL apply -k config/prometheus 2>/dev/null \
  || warn "Prometheus apply failed (non-fatal)"
for f in \
  observability/monitor/envoy_metrics_service.yaml \
  observability/monitor/service_monitor_controller_manager.yaml \
  observability/monitor/service_monitor_gateway_plugin.yaml \
  observability/monitor/service_monitor_gateway.yaml \
  observability/monitor/service_monitor_vllm.yaml; do
  $KUBECTL apply -f "$f" 2>/dev/null || true
done

# ---- 6. Wait for core pods -------------------------------------------------
log "Waiting for aibrix-controller-manager to be Ready..."
$KUBECTL wait --for=condition=Available --timeout=5m \
  deployment/aibrix-controller-manager -n aibrix-system \
  || warn "Controller manager not Ready after 5m"

log "Waiting for envoy-gateway to be Ready..."
$KUBECTL wait --for=condition=Available --timeout=5m \
  deployment/envoy-gateway -n envoy-gateway-system \
  || warn "envoy-gateway not Ready after 5m"

log "Waiting for aibrix-gateway-plugins to be Ready..."
$KUBECTL wait --for=condition=Available --timeout=5m \
  deployment/aibrix-gateway-plugins -n aibrix-system \
  || warn "aibrix-gateway-plugins not Ready after 5m"

# ---- 7. Port forward -------------------------------------------------------
PF_DIR="${PF_DIR:-$REPO_ROOT/.port-forward}"
mkdir -p "$PF_DIR"
start_pf() {
  local name="$1" ns="$2" svc="$3" local_port="$4" remote_port="$5"
  if [[ "$NO_PORT_FORWARD" -eq 1 ]]; then
    log "  $name: skipping port-forward (--no-port-forward)"
    return 0
  fi
  if command -v lsof >/dev/null 2>&1; then
    if lsof -i :"$local_port" -t >/dev/null 2>&1; then
      warn "Port $local_port already in use, skipping $name port-forward"
      return 0
    fi
  else
    # Linux without lsof: try ss
    if command -v ss >/dev/null 2>&1 && ss -ltn "sport = :$local_port" 2>/dev/null | grep -q ":$local_port"; then
      warn "Port $local_port already in use, skipping $name port-forward"
      return 0
    fi
  fi
  $KUBECTL port-forward -n "$ns" "$svc" "$local_port:$remote_port" \
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
if [[ "$NO_PORT_FORWARD" -eq 0 ]]; then
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
fi

if [[ "$CLUSTER_MODE" == "kind" ]]; then
  cluster_label="Kind cluster '$CLUSTER_NAME'"
else
  cluster_label="existing cluster (context: $(kubectl config current-context 2>/dev/null || echo '?'))"
fi

cat <<EOF

============================================================
✅ AIBrix is up on $cluster_label

Gateway:    http://localhost:$GATEWAY_LOCAL_PORT
            (e.g. curl http://localhost:$GATEWAY_LOCAL_PORT/v1/models)

Pods:
$($KUBECTL get pods -A | grep -v kube-system | sed 's/^/  /')

To stop everything: scripts/dev-down.sh
============================================================
EOF
