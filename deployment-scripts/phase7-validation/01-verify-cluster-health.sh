#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

ERRORS=0

print_info "=== Cluster Health Verification ==="
echo ""

print_info "Cluster nodes:"
oc get nodes || ((ERRORS++))

echo ""
print_info "Cluster operators:"
oc get co | grep -v "True.*False.*False" || true

DEGRADED=$(oc get co --no-headers | grep -v "True.*False.*False" | wc -l | tr -d ' ')
if [[ "$DEGRADED" -gt 0 ]]; then
    print_error "$DEGRADED operators degraded"
    ((ERRORS++))
else
    print_info "✅ All cluster operators healthy"
fi

echo ""
print_info "H100 node status:"
H100_NODE=$(oc get nodes -l node-role.kubernetes.io/gpu=true --no-headers | awk '{print $1}' | head -1)
oc get node "$H100_NODE" || ((ERRORS++))

if [[ $ERRORS -eq 0 ]]; then
    print_info "✅ Cluster health check passed"
    print_info "⏭️  Next: ./phase7-validation/02-test-rdma.sh"
    exit 0
else
    print_error "Cluster health check failed with $ERRORS error(s)"
    exit 1
fi
