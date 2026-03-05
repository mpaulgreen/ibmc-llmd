#!/bin/bash
################################################################################
# Phase 4: Label and Configure H100 Worker Node
# Purpose: Apply appropriate labels and taints to H100 node
# Time: ~5 minutes
################################################################################

set -e
set -u

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo ""; echo "=========================================="; echo "$1"; echo "=========================================="; echo ""; }

################################################################################
# Load Environment
################################################################################

print_section "Loading Environment Configuration"

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"

export KUBECONFIG

# Check if H100_NODE_NAME is set
if [[ -z "${H100_NODE_NAME:-}" ]]; then
    print_warn "H100_NODE_NAME not set in environment"
    print_info "Attempting to detect worker node..."

    WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | awk '{print $1}')
    WORKER_COUNT=$(echo "$WORKER_NODES" | wc -l | tr -d ' ')

    if [[ $WORKER_COUNT -eq 0 ]]; then
        print_error "No worker nodes found"
        print_error "Run: ./phase4-worker-integration/02-approve-csrs.sh"
        exit 1
    elif [[ $WORKER_COUNT -eq 1 ]]; then
        H100_NODE_NAME="$WORKER_NODES"
        print_info "✅ Detected single worker node: $H100_NODE_NAME"

        # Save to environment
        echo "export H100_NODE_NAME=$H100_NODE_NAME" >> "$ENV_FILE"
    else
        print_error "Multiple worker nodes found:"
        echo "$WORKER_NODES"
        echo ""
        read -p "Enter the H100 node name: " H100_NODE_NAME

        if [[ -z "$H100_NODE_NAME" ]]; then
            print_error "Node name required"
            exit 1
        fi

        # Save to environment
        echo "export H100_NODE_NAME=$H100_NODE_NAME" >> "$ENV_FILE"
    fi
fi

print_info "✅ Environment loaded"
print_info "   H100 Node: $H100_NODE_NAME"

################################################################################
# Verify Node Exists and is Ready
################################################################################

print_section "Verifying Node Status"

if ! oc get node "$H100_NODE_NAME" &>/dev/null; then
    print_error "Node not found: $H100_NODE_NAME"
    exit 1
fi

NODE_STATUS=$(oc get node "$H100_NODE_NAME" --no-headers | awk '{print $2}')
print_info "Node status: $NODE_STATUS"

if [[ "$NODE_STATUS" != "Ready" ]]; then
    print_warn "Node is not Ready: $NODE_STATUS"
    print_warn "Labeling can proceed, but node may not be fully functional"
    echo ""
    read -p "Continue with labeling? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

################################################################################
# Display Current Labels
################################################################################

print_section "Current Node Labels"

print_info "Existing labels on $H100_NODE_NAME:"
oc get node "$H100_NODE_NAME" --show-labels | tr ',' '\n' | head -20

################################################################################
# Apply Labels
################################################################################

print_section "Applying Labels to H100 Node"

print_info "Applying GPU-specific labels..."

# Core GPU labels
oc label node "$H100_NODE_NAME" \
    node-role.kubernetes.io/gpu=true \
    --overwrite

print_info "✅ GPU role label applied"

# NVIDIA-specific labels
oc label node "$H100_NODE_NAME" \
    nvidia.com/gpu.product=H100-SXM5 \
    nvidia.com/gpu.memory=80GB \
    nvidia.com/gpu.count=8 \
    --overwrite

print_info "✅ NVIDIA GPU labels applied"

# RDMA labels
oc label node "$H100_NODE_NAME" \
    ibm-cloud.kubernetes.io/rdma=enabled \
    ibm-cloud.kubernetes.io/cluster-network=rdma-cluster \
    ibm-cloud.kubernetes.io/cluster-network-profile=hopper-1 \
    --overwrite

print_info "✅ RDMA labels applied"

# IBM Cloud labels
oc label node "$H100_NODE_NAME" \
    ibm-cloud.kubernetes.io/instance-id="$H100_INSTANCE_ID" \
    ibm-cloud.kubernetes.io/instance-profile="$GPU_PROFILE" \
    ibm-cloud.kubernetes.io/zone="$IBMCLOUD_ZONE" \
    --overwrite

print_info "✅ IBM Cloud labels applied"

# Workload type labels
oc label node "$H100_NODE_NAME" \
    workload.openshift.io/ai-ml=true \
    workload.openshift.io/hpc=true \
    --overwrite

print_info "✅ Workload labels applied"

################################################################################
# Apply Taints (Optional)
################################################################################

print_section "Node Taints Configuration"

print_warn "⚠️  Node Taints (Optional)"
echo ""
echo "Taints prevent non-GPU workloads from being scheduled on the H100 node."
echo "This is recommended to reserve expensive GPU resources for GPU workloads only."
echo ""
echo "Recommended taint:"
echo "  nvidia.com/gpu=present:NoSchedule"
echo ""
echo "Pods must have matching tolerations to be scheduled on this node."
echo ""

read -p "Apply GPU taint to reserve node for GPU workloads? (Y/n): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    print_info "Applying GPU taint..."

    oc adm taint node "$H100_NODE_NAME" \
        nvidia.com/gpu=present:NoSchedule \
        --overwrite

    print_info "✅ GPU taint applied"
    print_warn "Pods must include this toleration to schedule on H100:"
    cat << 'EOF'

      tolerations:
      - key: nvidia.com/gpu
        operator: Equal
        value: present
        effect: NoSchedule
EOF
else
    print_info "Skipping taint - any pod can schedule on H100"
    print_warn "This may cause non-GPU workloads to consume H100 resources"
fi

################################################################################
# Display Updated Labels and Taints
################################################################################

print_section "Updated Node Configuration"

print_info "Final labels:"
oc get node "$H100_NODE_NAME" --show-labels | tr ',' '\n' | grep -E "(gpu|nvidia|rdma|ibm-cloud|workload)" || true

echo ""

print_info "Final taints:"
oc get node "$H100_NODE_NAME" -o json | jq -r '.spec.taints // [] | .[] | "\(.key)=\(.value):\(.effect)"' || echo "No taints"

echo ""

print_info "Node capacity and allocatable:"
oc get node "$H100_NODE_NAME" -o json | jq '{
  capacity: .status.capacity,
  allocatable: .status.allocatable
}'

################################################################################
# Verify Node is Ready for GPU Workloads
################################################################################

print_section "Node Readiness Check"

print_info "Checking node conditions..."
oc get node "$H100_NODE_NAME" -o json | jq -r '.status.conditions[] | "\(.type): \(.status) - \(.message)"'

echo ""

# Check if node has any pods
PODS_ON_NODE=$(oc get pods --all-namespaces --field-selector spec.nodeName="$H100_NODE_NAME" --no-headers 2>/dev/null | wc -l | tr -d ' ')

print_info "Pods currently running on node: $PODS_ON_NODE"

if [[ "$PODS_ON_NODE" -gt 0 ]]; then
    print_info "Pods on $H100_NODE_NAME:"
    oc get pods --all-namespaces --field-selector spec.nodeName="$H100_NODE_NAME"
fi

################################################################################
# Summary
################################################################################

print_section "H100 Worker Node Configuration Complete"

print_info "✅ H100 node labeled and configured"
print_info ""
print_info "Node: $H100_NODE_NAME"
print_info "Status: $NODE_STATUS"
print_info ""

print_info "Applied labels:"
echo "   - node-role.kubernetes.io/gpu=true"
echo "   - nvidia.com/gpu.product=H100-SXM5"
echo "   - nvidia.com/gpu.count=8"
echo "   - ibm-cloud.kubernetes.io/rdma=enabled"
echo "   - ibm-cloud.kubernetes.io/cluster-network=rdma-cluster"
echo "   - workload.openshift.io/ai-ml=true"

echo ""

print_warn "⏭️  Next Phase: Install RDMA Operators"
echo "   The H100 node is ready for operator installation"
echo "   Run: ./phase5-rdma-operators/01-install-nfd.sh"

echo ""

print_info "To view node details:"
echo "   oc describe node $H100_NODE_NAME"
echo "   oc get node $H100_NODE_NAME -o yaml"
