#!/bin/bash
################################################################################
# Phase 3: Start H100 Instance with RDMA Fabric
# Purpose: Start H100 and wait for RDMA fabric initialization
# Time: ~15-20 minutes
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

# Login to IBM Cloud
if ! ibmcloud target &>/dev/null; then
    ibmcloud_login
fi

# Verify H100_INSTANCE_ID is set
if [[ -z "${H100_INSTANCE_ID:-}" ]]; then
    print_error "H100_INSTANCE_ID not set"
    print_error "Run: ./phase3-h100-provisioning/01-create-h100-instance.sh"
    exit 1
fi

print_info "✅ Environment loaded"
print_info "   H100 Instance: $H100_INSTANCE_ID"

################################################################################
# Verify Cluster Network Attachments
################################################################################

print_section "Verifying Cluster Network Attachments"

ATTACHMENTS=$(ibmcloud is instance-cluster-network-attachments "$H100_INSTANCE_ID" --output json)
ATTACHMENT_COUNT=$(echo "$ATTACHMENTS" | jq '. | length')

print_info "Cluster network attachments: $ATTACHMENT_COUNT"

if [[ "$ATTACHMENT_COUNT" -ne 8 ]]; then
    print_error "Expected 8 cluster network attachments, found $ATTACHMENT_COUNT"
    print_error "Run: ./phase3-h100-provisioning/02-attach-cluster-networks.sh"
    exit 1
fi

print_info "✅ All 8 cluster network interfaces attached"

################################################################################
# Check Current Instance Status
################################################################################

print_section "Checking Instance Status"

CURRENT_STATUS=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json | jq -r '.status')
print_info "Current instance status: $CURRENT_STATUS"

if [[ "$CURRENT_STATUS" == "running" ]]; then
    print_warn "Instance is already running"
    read -p "Restart to ensure RDMA fabric initialization? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Stopping instance first..."
        ibmcloud is instance-stop "$H100_INSTANCE_ID" --force

        print_info "Waiting for instance to stop..."
        while true; do
            STATUS=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json | jq -r '.status')
            if [[ "$STATUS" == "stopped" ]]; then
                break
            fi
            echo -n "."
            sleep 10
        done
        echo ""
        print_info "✅ Instance stopped"
    else
        print_info "Keeping instance running. Proceeding to next phase."
        print_warn "⏭️  Next Phase: Integrate H100 as Worker Node"
        echo "   Run: ./phase4-worker-integration/01-prepare-h100-for-openshift.sh"
        exit 0
    fi
elif [[ "$CURRENT_STATUS" != "stopped" ]]; then
    print_error "Unexpected instance status: $CURRENT_STATUS"
    print_error "Expected 'stopped' or 'running'"
    exit 1
fi

################################################################################
# Start H100 Instance
################################################################################

print_section "Starting H100 Instance"

print_warn "⚠️  H100 boot with RDMA fabric initialization"
print_info "This process includes:"
echo "   1. Instance boot (2-3 minutes)"
echo "   2. RDMA fabric initialization (10-15 minutes)"
echo "   3. GPU device initialization"
echo "   4. ConnectX-7 NIC firmware loading"
echo ""
print_warn "⏱️  Total time: 15-20 minutes"
echo ""

read -p "Proceed with starting instance? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Operation cancelled"
    exit 0
fi

print_info "Starting H100 instance..."
ibmcloud is instance-start "$H100_INSTANCE_ID"

print_info "Waiting for instance to reach 'running' state..."

MAX_WAIT=600  # 10 minutes
ELAPSED=0

while true; do
    STATUS=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json | jq -r '.status')

    if [[ "$STATUS" == "running" ]]; then
        print_info "✅ Instance is running"
        break
    elif [[ "$STATUS" == "failed" ]]; then
        print_error "Instance failed to start"
        ibmcloud is instance "$H100_INSTANCE_ID"
        exit 1
    else
        echo -n "."
        sleep 10
        ELAPSED=$((ELAPSED + 10))

        if [[ $ELAPSED -ge $MAX_WAIT ]]; then
            print_error "Timeout waiting for instance to start"
            exit 1
        fi
    fi
done

echo ""

################################################################################
# Wait for RDMA Fabric Initialization
################################################################################

print_section "Waiting for RDMA Fabric Initialization"

print_info "Instance is booting, but RDMA fabric needs additional time..."
print_info "H100 systems require 10-15 minutes for:"
echo "   - ConnectX-7 NIC firmware initialization"
echo "   - RDMA device registration"
echo "   - GPU Direct RDMA capability setup"
echo "   - Network fabric calibration"
echo ""

print_warn "⏳ Waiting 10 minutes for RDMA fabric initialization..."
echo "   This is a safe wait time based on IBM documentation"
echo ""

# Wait with progress indicator
WAIT_TIME=600  # 10 minutes
INTERVAL=30

for ((i=0; i<WAIT_TIME; i+=INTERVAL)); do
    REMAINING=$((WAIT_TIME - i))
    MINUTES=$((REMAINING / 60))
    SECONDS=$((REMAINING % 60))
    printf "   Time remaining: %02d:%02d\r" $MINUTES $SECONDS
    sleep $INTERVAL
done

echo ""
print_info "✅ RDMA fabric initialization period complete"

################################################################################
# Get Instance Information
################################################################################

print_section "Instance Information"

INSTANCE_INFO=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json)

INSTANCE_NAME=$(echo "$INSTANCE_INFO" | jq -r '.name')
INSTANCE_STATUS=$(echo "$INSTANCE_INFO" | jq -r '.status')
INSTANCE_ZONE=$(echo "$INSTANCE_INFO" | jq -r '.zone.name')

# Get network information
PRIMARY_NIC=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface')
PRIVATE_IP=$(echo "$PRIMARY_NIC" | jq -r '.primary_ip.address')
FLOATING_IP=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface.floating_ips[0].address // empty')

print_info "Instance details:"
echo "   Name:       $INSTANCE_NAME"
echo "   ID:         $H100_INSTANCE_ID"
echo "   Status:     $INSTANCE_STATUS"
echo "   Zone:       $INSTANCE_ZONE"
echo "   Profile:    $GPU_PROFILE"
echo "   Private IP: $PRIVATE_IP"

if [[ -n "$FLOATING_IP" ]]; then
    echo "   Public IP:  $FLOATING_IP"
fi

echo ""

# Show cluster network attachments
print_info "Cluster Network Attachments:"
ATTACHMENTS_DETAIL=$(ibmcloud is instance-cluster-network-attachments "$H100_INSTANCE_ID" --output json)
echo "$ATTACHMENTS_DETAIL" | jq -r '.[] | "   - \(.name): \(.lifecycle_state)"'

################################################################################
# Optional: SSH and Verify RDMA Devices
################################################################################

print_section "Optional: Verify RDMA Devices"

if [[ -n "$FLOATING_IP" ]]; then
    print_info "You can SSH to the instance to verify RDMA devices:"
    echo ""
    echo "   ssh root@$FLOATING_IP"
    echo ""
    echo "Then run these commands:"
    echo "   lspci | grep -i mellanox        # Should show 8 ConnectX-7 NICs"
    echo "   ibv_devices                     # Should show mlx5_0 through mlx5_7"
    echo "   rdma link show                  # Should show 8 RDMA links"
    echo "   nvidia-smi                      # Should show 8× H100 GPUs"
    echo ""

    read -p "Open SSH session now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Connecting to instance..."
        print_warn "Note: First boot may still be in progress. If SSH fails, wait 2-3 more minutes."
        echo ""
        ssh -o StrictHostKeyChecking=no root@$FLOATING_IP
    fi
else
    print_warn "No public IP - SSH requires VPN or bastion host"
fi

################################################################################
# Summary
################################################################################

print_section "H100 Instance Ready"

print_info "✅ H100 instance started and RDMA fabric initialized"
print_info ""
print_info "Instance details:"
echo "   ID:         $H100_INSTANCE_ID"
echo "   Private IP: $PRIVATE_IP"

if [[ -n "$FLOATING_IP" ]]; then
    echo "   Public IP:  $FLOATING_IP"
fi

echo ""
print_info "Network configuration:"
echo "   VPC Management:    1× interface"
echo "   Cluster Network:   8× RDMA interfaces (3.2 Tbps total)"
echo "   GPU Rails:         8× ConnectX-7 (400 Gbps each)"

echo ""
print_warn "⏭️  Next Phase: Integrate H100 as OpenShift Worker Node"
echo "   This involves:"
echo "   1. Configuring the instance for OpenShift"
echo "   2. Approving certificate signing requests (CSRs)"
echo "   3. Labeling the node for GPU workloads"
echo ""
echo "   Run: ./phase4-worker-integration/01-prepare-h100-for-openshift.sh"

print_info ""
print_info "H100 provisioning complete!"
