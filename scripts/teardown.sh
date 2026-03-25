#!/usr/bin/env bash
# teardown.sh — Deletes the kind cluster
set -euo pipefail
CLUSTER_NAME="ingress2gateway-demo"
echo "Deleting kind cluster '${CLUSTER_NAME}'..."
kind delete cluster --name "${CLUSTER_NAME}"
echo "Done."
