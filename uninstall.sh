#!/usr/bin/env bash
# AIBrix one-click uninstaller.
#
# Mirrors scripts/dev-down.sh. By default it only stops port-forwards.
# Pass --undeploy to remove aibrix CRDs/deployments/mock from the cluster
# (cluster itself is preserved). Pass --delete-cluster to delete the
# Kind cluster entirely (Kind mode only).
#
# Usage:
#   ./uninstall.sh                          # stop port-forwards only
#   ./uninstall.sh --undeploy               # also tear down aibrix on cluster
#   ./uninstall.sh --undeploy --delete-cluster  # also delete Kind cluster
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

exec scripts/dev-down.sh "$@"
