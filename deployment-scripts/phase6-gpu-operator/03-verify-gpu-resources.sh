#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

if [[ -z "${H100_NODE_NAME:-}" ]]; then
    H100_NODE_NAME=$(oc get nodes -l node-role.kubernetes.io/gpu=true --no-headers | awk '{print $1}' | head -1)
fi

print_info "Verifying GPU resources on H100 node..."
echo ""

print_info "GPU operator pods:"
oc get pods -n nvidia-gpu-operator | grep -E "(NAME|$H100_NODE_NAME|nvidia)"

echo ""
print_info "Node GPU resources:"
oc get node "$H100_NODE_NAME" -o json | jq '.status.allocatable | with_entries(select(.key | contains("nvidia")))'

GPU_COUNT=$(oc get node "$H100_NODE_NAME" -o json | jq -r '.status.allocatable."nvidia.com/gpu" // "0"')

if [[ "$GPU_COUNT" == "0" ]]; then
    print_error "No GPU resources found on node"
    echo "GPU operator may still be deploying. Check:"
    echo "  oc get pods -n nvidia-gpu-operator"
    echo "  oc logs -n nvidia-gpu-operator <pod-name>"
    exit 1
else
    print_info "✅ GPU resources available: $GPU_COUNT"
fi

print_info "✅ GPU Operator verification complete"
print_warn "⏭️  Next Phase: Validation Testing"
print_warn "    Run: ./phase7-validation/01-verify-cluster-health.sh"
