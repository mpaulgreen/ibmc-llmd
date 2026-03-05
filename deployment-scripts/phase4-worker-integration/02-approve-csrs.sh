#!/bin/bash
################################################################################
# Phase 4: Approve Certificate Signing Requests
# Purpose: Approve CSRs for H100 worker node to join cluster
# Time: ~5-10 minutes
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

if [[ ! -f "$KUBECONFIG" ]]; then
    print_error "KUBECONFIG not found: $KUBECONFIG"
    exit 1
fi

export KUBECONFIG

print_info "✅ Environment loaded"
print_info "   Cluster: $CLUSTER_NAME"

################################################################################
# Check Cluster Access
################################################################################

print_section "Verifying Cluster Access"

if ! oc cluster-info &>/dev/null; then
    print_error "Cannot connect to cluster"
    print_error "Check KUBECONFIG: $KUBECONFIG"
    exit 1
fi

print_info "✅ Connected to cluster"

################################################################################
# Check Current Nodes
################################################################################

print_section "Current Cluster Nodes"

print_info "Existing nodes:"
oc get nodes

NODE_COUNT=$(oc get nodes --no-headers | wc -l | tr -d ' ')
print_info "Total nodes: $NODE_COUNT (3 masters expected)"

################################################################################
# Check for Pending CSRs
################################################################################

print_section "Checking for Pending CSRs"

print_info "Looking for pending certificate signing requests..."
echo ""

PENDING_CSRS=$(oc get csr --no-headers 2>/dev/null | grep " Pending " || true)

if [[ -z "$PENDING_CSRS" ]]; then
    print_warn "No pending CSRs found"
    print_warn ""
    print_warn "This means either:"
    echo "   1. The worker node hasn't started the join process yet"
    echo "   2. The worker node cannot reach the cluster API"
    echo "   3. The worker configuration is incorrect"
    echo ""
    print_warn "Troubleshooting steps:"
    echo "   1. Check if H100 instance is running: ibmcloud is instance $H100_INSTANCE_ID"
    echo "   2. Check H100 logs (kubelet, systemd)"
    echo "   3. Verify network connectivity from H100 to cluster API"
    echo "   4. Review H100 configuration from previous step"
    echo ""

    read -p "Wait for CSRs to appear? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        exit 0
    fi

    print_info "Watching for CSRs (Ctrl+C to exit)..."
    echo ""
    print_warn "In another terminal, monitor with: watch oc get csr"
    echo ""

    # Wait for CSRs to appear
    MAX_WAIT=600  # 10 minutes
    ELAPSED=0
    INTERVAL=15

    while true; do
        PENDING_CSRS=$(oc get csr --no-headers 2>/dev/null | grep " Pending " || true)

        if [[ -n "$PENDING_CSRS" ]]; then
            print_info "✅ Pending CSRs detected!"
            break
        fi

        printf "   Waiting for CSRs... (%d/%d seconds)\r" $ELAPSED $MAX_WAIT
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))

        if [[ $ELAPSED -ge $MAX_WAIT ]]; then
            print_error "Timeout waiting for CSRs"
            print_error "Worker node may not be configured correctly"
            exit 1
        fi
    done

    echo ""
fi

################################################################################
# Display Pending CSRs
################################################################################

print_section "Pending CSRs"

print_info "Pending certificate signing requests:"
echo ""
oc get csr | grep -E "(NAME|Pending)"

PENDING_COUNT=$(echo "$PENDING_CSRS" | wc -l | tr -d ' ')
print_info ""
print_info "Found $PENDING_COUNT pending CSR(s)"

################################################################################
# Approve CSRs
################################################################################

print_section "Approving CSRs"

print_warn "⚠️  You are about to approve CSRs for worker node(s) to join the cluster"
echo ""
echo "CSRs to approve:"
echo "$PENDING_CSRS"
echo ""

read -p "Approve these CSRs? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "CSR approval cancelled"
    exit 0
fi

print_info "Approving all pending CSRs..."

# Approve all pending CSRs
CSR_NAMES=$(oc get csr --no-headers | grep " Pending " | awk '{print $1}')

for csr in $CSR_NAMES; do
    print_info "Approving CSR: $csr"
    oc adm certificate approve "$csr"
done

print_info "✅ CSRs approved"

################################################################################
# Wait for Node to Appear
################################################################################

print_section "Waiting for Node to Join"

print_info "Waiting for new worker node to appear..."
echo ""

INITIAL_NODE_COUNT=$NODE_COUNT
MAX_WAIT=300  # 5 minutes
ELAPSED=0

while true; do
    CURRENT_NODE_COUNT=$(oc get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')

    if [[ $CURRENT_NODE_COUNT -gt $INITIAL_NODE_COUNT ]]; then
        print_info "✅ New node detected!"
        break
    fi

    printf "   Waiting for node... (%d/%d seconds)\r" $ELAPSED $MAX_WAIT
    sleep 10
    ELAPSED=$((ELAPSED + 10))

    if [[ $ELAPSED -ge $MAX_WAIT ]]; then
        print_error "Timeout waiting for node to appear"
        print_warn "Check if additional CSRs need approval"
        oc get csr | grep Pending || true
        exit 1
    fi
done

echo ""
echo ""

################################################################################
# Check for Additional Pending CSRs
################################################################################

print_section "Checking for Additional CSRs"

print_info "Nodes may require a second CSR for serving certificates..."
sleep 5

ADDITIONAL_CSRS=$(oc get csr --no-headers 2>/dev/null | grep " Pending " || true)

if [[ -n "$ADDITIONAL_CSRS" ]]; then
    print_info "Found additional pending CSRs (likely serving certificates)"
    echo ""
    echo "$ADDITIONAL_CSRS"
    echo ""

    print_info "Approving additional CSRs..."
    CSR_NAMES=$(oc get csr --no-headers | grep " Pending " | awk '{print $1}')

    for csr in $CSR_NAMES; do
        print_info "Approving CSR: $csr"
        oc adm certificate approve "$csr"
    done

    print_info "✅ Additional CSRs approved"
else
    print_info "No additional CSRs at this time"
    print_warn "If node stays NotReady, check again in 1-2 minutes"
fi

################################################################################
# Display Updated Node List
################################################################################

print_section "Updated Node List"

sleep 5  # Give nodes time to update

print_info "Current cluster nodes:"
oc get nodes

echo ""

# Identify the new worker node
WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null || true)

if [[ -z "$WORKER_NODES" ]]; then
    print_warn "No worker nodes detected yet"
    print_warn "The new node may need the worker role label applied"
else
    print_info "Worker nodes:"
    echo "$WORKER_NODES"

    # Get the worker node name (assuming only one worker)
    WORKER_NODE_NAME=$(echo "$WORKER_NODES" | head -1 | awk '{print $1}')

    # Save to environment
    echo "" >> "$ENV_FILE"
    echo "# H100 Worker Node (detected $(date))" >> "$ENV_FILE"
    echo "export H100_NODE_NAME=$WORKER_NODE_NAME" >> "$ENV_FILE"

    print_info "✅ Worker node name saved: $WORKER_NODE_NAME"
fi

################################################################################
# Check Node Status
################################################################################

print_section "Node Status Check"

if [[ -n "${WORKER_NODE_NAME:-}" ]]; then
    NODE_STATUS=$(oc get node "$WORKER_NODE_NAME" --no-headers | awk '{print $2}')

    if [[ "$NODE_STATUS" == "Ready" ]]; then
        print_info "✅ Worker node is Ready"
    elif [[ "$NODE_STATUS" == "NotReady" ]]; then
        print_warn "Worker node is NotReady"
        print_warn "This is normal for first few minutes after joining"
        print_warn ""
        print_warn "Possible reasons:"
        echo "   - CNI plugin still initializing"
        echo "   - Container runtime starting"
        echo "   - Node configuration in progress"
        print_warn ""
        print_warn "Wait 2-5 minutes and check again: oc get nodes"
    else
        print_warn "Worker node status: $NODE_STATUS"
    fi

    echo ""
    print_info "Node details:"
    oc describe node "$WORKER_NODE_NAME" | head -30
fi

################################################################################
# Summary
################################################################################

print_section "CSR Approval Complete"

if [[ -n "${WORKER_NODE_NAME:-}" ]]; then
    print_info "✅ Worker node joined: $WORKER_NODE_NAME"
    print_info ""
    print_warn "⏭️  Next Step: Label and Configure Worker Node"
    echo "   Run: ./phase4-worker-integration/03-label-h100-node.sh"
    print_info ""
    print_info "Monitor node status:"
    echo "   watch oc get nodes"
else
    print_warn "Worker node not fully joined yet"
    print_warn "Wait a few minutes and check: oc get nodes"
    print_warn "If CSRs reappear, approve them: oc get csr"
fi
