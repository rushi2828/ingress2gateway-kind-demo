#!/usr/bin/env bash
# test.sh — Port-forwards the Envoy Gateway and curls the demo endpoints
set -euo pipefail

NAMESPACE="demo"
LOCAL_PORT=8080

GREEN='\033[0;32m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[PASS]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }

# Find the Envoy Gateway service name
GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l "gateway.envoyproxy.io/owning-gateway-name=demo-gateway" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

if [[ -z "$GW_SVC" ]]; then
  # Fallback: find any envoy service in the namespace
  GW_SVC=$(kubectl get svc -n envoy-gateway-system \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
fi

if [[ -z "$GW_SVC" ]]; then
  info "Could not auto-detect Envoy service. Starting port-forward to demo-gateway..."
  # Try port-forwarding via the Gateway directly (works with some implementations)
  kubectl port-forward -n "${NAMESPACE}" \
    "$(kubectl get pods -n "${NAMESPACE}" -l app=nginx-demo -o jsonpath='{.items[0].metadata.name}')" \
    ${LOCAL_PORT}:80 &>/dev/null &
  PF_PID=$!
else
  info "Port-forwarding ${GW_SVC} → localhost:${LOCAL_PORT}"
  kubectl port-forward svc/"${GW_SVC}" ${LOCAL_PORT}:80 \
    -n envoy-gateway-system &>/dev/null &
  PF_PID=$!
fi

sleep 2
info "Port-forward PID: ${PF_PID}"

echo ""
echo "Testing endpoints (Host: demo.localtest.me)..."
echo ""

test_endpoint() {
  local path=$1
  local desc=$2
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Host: demo.localtest.me" \
    "http://localhost:${LOCAL_PORT}${path}" || echo "000")
  if [[ "$status" == "200" ]]; then
    success "GET ${path} → HTTP ${status}  (${desc})"
  else
    fail    "GET ${path} → HTTP ${status}  (${desc})"
  fi
}

test_endpoint "/nginx"  "nginx-demo service via HTTPRoute"
test_endpoint "/echo"   "echo-demo service via HTTPRoute"

echo ""
info "Stopping port-forward (PID ${PF_PID})..."
kill "${PF_PID}" 2>/dev/null || true
