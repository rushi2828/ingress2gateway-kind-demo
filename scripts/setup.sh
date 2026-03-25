#!/usr/bin/env bash
# setup.sh — Bootstraps the full ingress2gateway demo on kind
set -euo pipefail

CLUSTER_NAME="ingress2gateway-demo"
NAMESPACE="demo"
GATEWAY_API_VERSION="v1.2.1"
ENVOY_GATEWAY_VERSION="v1.4.1"

# ─── Colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Prerequisites ──────────────────────────────────────────────────────────
for cmd in kind kubectl helm curl; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is not installed. See README for prerequisites."
done
info "All prerequisites found."

# ─── 1. kind cluster ────────────────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  warn "Cluster '${CLUSTER_NAME}' already exists — skipping creation."
else
  info "Creating kind cluster '${CLUSTER_NAME}'..."
  kind create cluster --config kind-config.yaml
  success "Cluster created."
fi

# ─── 2. Gateway API CRDs ────────────────────────────────────────────────────
info "Installing Gateway API CRDs (${GATEWAY_API_VERSION})..."
kubectl apply -f \
  "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"
success "Gateway API CRDs installed."

# ─── 3. Envoy Gateway (Gateway API implementation) ──────────────────────────
info "Installing Envoy Gateway ${ENVOY_GATEWAY_VERSION} via Helm..."
helm repo add envoy-gateway https://charts.gateway.envoyproxy.io 2>/dev/null || true
helm repo update envoy-gateway
helm upgrade --install envoy-gateway envoy-gateway/gateway-helm \
  --version "${ENVOY_GATEWAY_VERSION}" \
  --namespace envoy-gateway-system \
  --create-namespace \
  --wait \
  --timeout 3m
success "Envoy Gateway installed."

# ─── 4. Demo namespace + apps ────────────────────────────────────────────────
info "Creating namespace '${NAMESPACE}'..."
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

info "Deploying sample applications..."
kubectl apply -f apps/nginx-demo/deployment.yaml
kubectl apply -f apps/echo-demo/deployment.yaml
kubectl rollout status deployment/nginx-demo -n "${NAMESPACE}" --timeout=90s
kubectl rollout status deployment/echo-demo  -n "${NAMESPACE}" --timeout=90s
success "Apps are running."

# ─── 5. Gateway + HTTPRoute ─────────────────────────────────────────────────
info "Applying GatewayClass & Gateway..."
kubectl apply -f gateway/gateway.yaml

info "Waiting for Gateway to be programmed..."
kubectl wait gateway/demo-gateway -n "${NAMESPACE}" \
  --for=condition=Programmed --timeout=120s

info "Applying HTTPRoute..."
kubectl apply -f gateway/httproute.yaml
success "Gateway API resources applied."

# ─── Done ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Demo cluster is ready!                                  ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "  Run the migration demo:"
echo "    ./scripts/demo-migration.sh"
echo ""
echo "  Test endpoints (requires port-forward, see scripts/test.sh):"
echo "    http://demo.localtest.me:8080/nginx"
echo "    http://demo.localtest.me:8080/echo"
echo ""
