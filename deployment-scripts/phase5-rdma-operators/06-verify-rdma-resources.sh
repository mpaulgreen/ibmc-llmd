#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

if [[ -z "${H100_NODE_NAME:-}" ]]; then
    H100_NODE_NAME=$(oc get nodes -l node-role.kubernetes.io/gpu=true --no-headers | awk '{print $1}' | head -1)
fi

print_info "Verifying RDMA resources on H100 node..."
echo ""
print_info "Node allocatable resources:"
oc get node "$H100_NODE_NAME" -o json | jq '.status.allocatable | with_entries(select(.key | contains("rdma")))'

RDMA_COUNT=$(oc get node "$H100_NODE_NAME" -o json | jq -r '.status.allocatable."rdma/rdma_mlx5" // "0"')

if [[ "$RDMA_COUNT" == "0" ]]; then
    print_error "No RDMA resources found on node"
    echo "Troubleshooting:"
    echo "  - Check SR-IOV policy: oc get sriovnetworknodepolicy -n openshift-sriov-network-operator"
    echo "  - Check SR-IOV node state: oc get sriovnetworknodestate -n openshift-sriov-network-operator"
    echo "  - View node details: oc describe node $H100_NODE_NAME"
    exit 1
else
    print_info "✅ RDMA resources available: $RDMA_COUNT"
fi

print_info "Checking NetworkAttachmentDefinition..."
oc get network-attachment-definitions -n default

print_info "✅ RDMA configuration verified"
print_info "⏭️  Next Phase: Install GPU Operator"
print_info "    Run: ./phase6-gpu-operator/01-install-gpu-operator.sh"
