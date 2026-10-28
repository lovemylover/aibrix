#!/usr/bin/env bash
# AIBrix one-click installer.
#
# This script is a thin wrapper around scripts/dev-up.sh that auto-detects
# the environment and gives first-time users a guided install. It is intended
# to be the single entrypoint for a Linux user who wants AIBrix running on
# their own Kubernetes cluster without reading any docs.
#
# Quick start (most users):
#   ./install.sh                                                # Kind on local Docker
#   ./install.sh --cluster existing --registry docker.io/myuser # push to your Docker Hub
#   ./install.sh --cluster existing --registry registry.internal:5000/aibrix
#
# What it does:
#   1. Checks for required tools (docker, kubectl, make, go) and tells you
#      how to install the missing ones.
#   2. Honors --cluster=kind (default) or --cluster=existing. In existing
#      mode, validates that kubectl can already reach your cluster.
#   3. Hands off to scripts/dev-up.sh with the same flags, so everything
#      documented in scripts/dev-up.sh applies here too.
#
# Stop a previously-started stack:
#   ./uninstall.sh                      # mirror of scripts/dev-down.sh --undeploy
#   ./uninstall.sh --delete-cluster     # also delete the Kind cluster
#
# See:
#   - scripts/dev-up.sh     for full flag reference
#   - scripts/dev-down.sh   for teardown
#   - docs/quickstart-linux.md  for a step-by-step walkthrough with prereq
#                                install commands and troubleshooting
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

log()  { echo -e "\033[1;34m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[install] WARN:\033[0m $*" >&2; }
die()  { echo -e "\033[1;31m[install] FAIL:\033[0m $*" >&2; exit 1; }

# Defaults — pass through to dev-up.sh
CLUSTER_MODE="kind"
REGISTRY=""
MOCK_FILTER=""
SKIP_BUILD=0
EXTRA_FLAGS=()

while [[ $# -gt 0 ]]; do
  arg="$1"
  case "$arg" in
    --cluster)       CLUSTER_MODE="${2:-kind}"; shift ;;
    --cluster=*)     CLUSTER_MODE="${arg#--cluster=}" ;;
    --registry)      REGISTRY="${2:-}"; shift ;;
    --registry=*)    REGISTRY="${arg#--registry=}" ;;
    --mock)          MOCK_FILTER="${2:-sglang}"; shift ;;
    --mock=*)        MOCK_FILTER="${arg#--mock=}" ;;
    --skip-build)    SKIP_BUILD=1; EXTRA_FLAGS+=("--skip-build") ;;
    --no-port-forward) EXTRA_FLAGS+=("--no-port-forward") ;;
    --kube-context)  EXTRA_FLAGS+=("--kube-context" "${2:-}"); shift ;;
    --kube-context=*) EXTRA_FLAGS+=("$arg") ;;
    -h|--help)
      sed -n '1,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//'
      echo
      echo "All flags not listed here are passed to scripts/dev-up.sh."
      echo "Run scripts/dev-up.sh --help for the full list."
      exit 0
      ;;
    *) EXTRA_FLAGS+=("$arg") ;;
  esac
  shift
done

# ---- 1. Preflight checks ---------------------------------------------------
log "Preflight checks..."

check_tool() {
  local tool="$1" hint="$2"
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo
    echo "Missing required tool: $tool"
    echo "Install with:"
    echo "  $hint"
    echo
    return 1
  fi
}

os_hint() {
  local tool="$1"
  case "$(uname -s)" in
    Linux)
      case "$tool" in
        docker)  echo "  curl -fsSL https://get.docker.com/ | sh && sudo systemctl enable --now docker" ;;
        kubectl) echo "  curl -LO https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl && sudo install -m 0755 kubectl /usr/local/bin/kubectl" ;;
        kind)    echo "  curl -Lo ./kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64 && sudo install -m 0755 kind /usr/local/bin/kind" ;;
        go)      echo "  sudo apt install -y golang-go   # or: download from https://go.dev/dl/" ;;
        make)    echo "  sudo apt install -y make" ;;
        jq)      echo "  sudo apt install -y jq" ;;
      esac ;;
    Darwin)
      case "$tool" in
        docker)  echo "  brew install --cask docker   # then launch Docker Desktop" ;;
        kubectl) echo "  brew install kubectl" ;;
        kind)    echo "  brew install kind" ;;
        go)      echo "  brew install go" ;;
        make)    echo "  brew install make" ;;
        jq)      echo "  brew install jq" ;;
      esac ;;
  esac
}

MISSING=()
for tool in docker kubectl make go jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    MISSING+=("$tool")
  fi
done
if [[ "$CLUSTER_MODE" == "kind" ]]; then
  if ! command -v kind >/dev/null 2>&1; then
    MISSING+=("kind")
  fi
fi

if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo
  echo "Missing required tools: ${MISSING[*]}"
  echo
  echo "Install them on $(uname -s) with:"
  for t in "${MISSING[@]}"; do
    hint="$(os_hint "$t")"
    [[ -n "$hint" ]] && echo "$hint"
  done
  echo
  echo "After installing, re-run: $0 $*"
  exit 1
fi

# Go version sanity (1.22+)
GOVER="$(go version 2>/dev/null | awk '{print $3}' | sed 's/go//')"
GOVER_MAJ="$(echo "$GOVER" | cut -d. -f1)"
GOVER_MIN="$(echo "$GOVER" | cut -d. -f2)"
if [[ "$GOVER_MAJ" -lt 1 || ( "$GOVER_MAJ" -eq 1 && "$GOVER_MIN" -lt 22 ) ]]; then
  warn "Go version $GOVER is older than 1.22. Some build steps may fail."
  warn "Consider upgrading: https://go.dev/dl/"
fi
if [[ "$GOVER_MAJ" -gt 1 || ( "$GOVER_MAJ" -eq 1 && "$GOVER_MIN" -gt 25 ) ]]; then
  # On Go 1.26+ the project's pinned toolchain (go1.22.6) cannot build
  # controller-gen. Pin to local toolchain to avoid the auto-download path.
  export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"
  log "Detected Go $GOVER (>= 1.26); setting GOTOOLCHAIN=local for compatibility."
fi

# ---- 2. Cluster reachability probe -----------------------------------------
case "$CLUSTER_MODE" in
  kind)
    log "Mode: Kind on local Docker (no existing cluster required)"
    ;;
  existing)
    log "Mode: existing Kubernetes cluster"
    if ! kubectl cluster-info >/dev/null 2>&1; then
      die "kubectl cannot reach any cluster. Set KUBECONFIG or pass --kube-context."
    fi
    log "  Context: $(kubectl config current-context 2>/dev/null || echo '?')"
    log "  Server:  $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || echo '?')"

    if [[ -z "$REGISTRY" && "$SKIP_BUILD" -eq 0 ]]; then
      die "--cluster=existing without --skip-build requires --registry=URL"
    fi
    if [[ -n "$REGISTRY" ]]; then
      log "  Registry: $REGISTRY"
      # Sanity check: can we docker login or push? Best-effort.
      if ! docker info >/dev/null 2>&1; then
        warn "docker daemon not reachable; image push will fail later if not fixed."
      fi
    fi
    ;;
  *)
    die "Invalid --cluster value: $CLUSTER_MODE (expected: kind|existing)"
    ;;
esac

# ---- 3. Cluster mode: existing → also ensure kubectl context survives ------
if [[ "$CLUSTER_MODE" == "existing" ]]; then
  # If the user passed --kube-context, dev-up.sh uses it; otherwise dev-up.sh
  # honors current-context. We just pass it through.
  :
fi

# ---- 4. Hand off to dev-up.sh ----------------------------------------------
log "Handing off to scripts/dev-up.sh..."

DEVUP_ARGS=(
  --cluster "$CLUSTER_MODE"
)
if [[ -n "$REGISTRY" ]]; then
  DEVUP_ARGS+=("--registry" "$REGISTRY")
fi
if [[ -n "$MOCK_FILTER" ]]; then
  DEVUP_ARGS+=("--mock" "$MOCK_FILTER")
fi
# Append any extra flags the user passed (e.g. --kube-context, --no-port-forward,
# --skip-build, etc.).
DEVUP_ARGS+=("${EXTRA_FLAGS[@]}")

log "Final command: scripts/dev-up.sh ${DEVUP_ARGS[*]}"
exec scripts/dev-up.sh "${DEVUP_ARGS[@]}"
