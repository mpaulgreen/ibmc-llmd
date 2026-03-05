#!/bin/bash
################################################################################
# Phase 3: Attach Cluster Network Interfaces to H100
# Purpose: Attach 8 RDMA network interfaces for GPU Direct communication
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
# Verify Cluster Network Configuration
################################################################################

print_section "Verifying Cluster Network Configuration"

print_info "Checking cluster network: $CN_NAME"

CN_INFO=$(ibmcloud is cluster-network "$CN_ID" --output json)
CN_STATE=$(echo "$CN_INFO" | jq -r '.lifecycle_state')
CN_PROFILE=$(echo "$CN_INFO" | jq -r '.profile.name')

print_info "  Cluster Network: $CN_NAME"
print_info "  State:           $CN_STATE"
print_info "  Profile:         $CN_PROFILE"

if [[ "$CN_STATE" != "stable" && "$CN_STATE" != "pending" ]]; then
    print_error "Cluster network state is not stable: $CN_STATE"
    exit 1
fi

if [[ "$CN_PROFILE" != "hopper-1" ]]; then
    print_warn "Profile is $CN_PROFILE, expected hopper-1"
fi

print_info "✅ Cluster network ready"

# Verify all 8 subnets exist
print_info "Verifying cluster network subnets..."
for i in {0..7}; do
    SUBNET_VAR="CN_SUBNET_ID_$i"
    SUBNET_ID="${!SUBNET_VAR}"

    if ibmcloud is cluster-network-subnet "$CN_ID" "$SUBNET_ID" &>/dev/null; then
        print_info "  ✅ Subnet $i: $SUBNET_ID"
    else
        print_error "  ❌ Subnet $i not found: $SUBNET_ID"
        exit 1
    fi
done

print_info "✅ All 8 cluster network subnets verified"

################################################################################
# Check Current Instance Status
################################################################################

print_section "Checking Instance Status"

CURRENT_STATUS=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json | jq -r '.status')
print_info "Current instance status: $CURRENT_STATUS"

################################################################################
# Stop H100 Instance
################################################################################

print_section "Stopping H100 Instance"

if [[ "$CURRENT_STATUS" == "running" ]]; then
    print_warn "⚠️  Cluster network interfaces can only be attached when instance is STOPPED"
    print_warn "This will stop the H100 instance"
    echo ""
    read -p "Proceed with stopping instance? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_warn "Operation cancelled"
        exit 0
    fi

    print_info "Stopping instance..."
    ibmcloud is instance-stop "$H100_INSTANCE_ID" --force

    print_info "Waiting for instance to stop..."
    MAX_WAIT=300  # 5 minutes
    ELAPSED=0

    while true; do
        STATUS=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json | jq -r '.status')

        if [[ "$STATUS" == "stopped" ]]; then
            print_info "✅ Instance stopped"
            break
        else
            echo -n "."
            sleep 10
            ELAPSED=$((ELAPSED + 10))

            if [[ $ELAPSED -ge $MAX_WAIT ]]; then
                print_error "Timeout waiting for instance to stop"
                exit 1
            fi
        fi
    done
    echo ""

elif [[ "$CURRENT_STATUS" == "stopped" ]]; then
    print_info "✅ Instance already stopped"
else
    print_error "Unexpected instance status: $CURRENT_STATUS"
    print_error "Instance must be 'running' or 'stopped'"
    exit 1
fi

################################################################################
# Create and Attach Cluster Network Interfaces
################################################################################

print_section "Creating and Attaching Cluster Network Interfaces"

print_info "Creating 8 cluster network interfaces (one per GPU rail)..."
echo ""

# Array to store created interface IDs
declare -a INTERFACE_IDS

for i in {0..7}; do
    SUBNET_VAR="CN_SUBNET_ID_$i"
    SUBNET_ID="${!SUBNET_VAR}"

    print_info "[$((i+1))/8] Creating interface for GPU rail $i..."
    print_info "       Subnet: $SUBNET_ID"

    # Create cluster network interface
    INTERFACE_OUTPUT=$(ibmcloud is cluster-network-interface-create \
        --cluster-network "$CN_ID" \
        --subnet "$SUBNET_ID" \
        --name "h100-gpu-rail-${i}" \
        --output json 2>&1)

    if echo "$INTERFACE_OUTPUT" | jq -e . &>/dev/null; then
        INTERFACE_ID=$(echo "$INTERFACE_OUTPUT" | jq -r '.id')

        if [[ -z "$INTERFACE_ID" || "$INTERFACE_ID" == "null" ]]; then
            print_error "Failed to create cluster network interface $i"
            echo "$INTERFACE_OUTPUT"
            exit 1
        fi

        INTERFACE_IDS[$i]="$INTERFACE_ID"
        print_info "       ✅ Interface created: $INTERFACE_ID"

        # Attach interface to instance
        print_info "       Attaching to instance..."

        ATTACHMENT_OUTPUT=$(ibmcloud is instance-cluster-network-attachment-create \
            "$H100_INSTANCE_ID" \
            --cluster-network-interface "$INTERFACE_ID" \
            --name "h100-attachment-${i}" \
            --output json 2>&1)

        if echo "$ATTACHMENT_OUTPUT" | jq -e . &>/dev/null; then
            ATTACHMENT_ID=$(echo "$ATTACHMENT_OUTPUT" | jq -r '.id')
            print_info "       ✅ Attached: $ATTACHMENT_ID"
        else
            print_error "Failed to attach interface $i"
            echo "$ATTACHMENT_OUTPUT"
            exit 1
        fi

    else
        print_error "Failed to create cluster network interface $i"
        echo "$INTERFACE_OUTPUT"
        exit 1
    fi

    echo ""
done

print_info "✅ All 8 cluster network interfaces created and attached"

################################################################################
# Verify Attachments
################################################################################

print_section "Verifying Cluster Network Attachments"

print_info "Listing all cluster network attachments..."
ATTACHMENTS=$(ibmcloud is instance-cluster-network-attachments "$H100_INSTANCE_ID" --output json)

ATTACHMENT_COUNT=$(echo "$ATTACHMENTS" | jq '. | length')

print_info "Total attachments: $ATTACHMENT_COUNT"

if [[ "$ATTACHMENT_COUNT" -ne 8 ]]; then
    print_error "Expected 8 attachments, found $ATTACHMENT_COUNT"
    exit 1
fi

echo ""
print_info "Attachment details:"
echo "$ATTACHMENTS" | jq -r '.[] | "  - \(.name): \(.lifecycle_state)"'

echo ""
print_info "✅ All cluster network attachments verified"

################################################################################
# Save Interface IDs
################################################################################

print_section "Saving Configuration"

# Save interface IDs to environment file
echo "" >> "$ENV_FILE"
echo "# Cluster Network Interface IDs (created $(date))" >> "$ENV_FILE"
for i in {0..7}; do
    echo "export CN_INTERFACE_${i}_ID=${INTERFACE_IDS[$i]}" >> "$ENV_FILE"
done

print_info "✅ Interface IDs saved to environment"

################################################################################
# Summary
################################################################################

print_section "Cluster Network Attachment Complete"

print_info "✅ Successfully created and attached 8 cluster network interfaces"
print_info ""
print_info "Configuration:"
echo "   Cluster Network:  $CN_NAME"
echo "   Profile:          $CN_PROFILE"
echo "   Interfaces:       8 (one per GPU rail)"
echo "   Total Bandwidth:  3.2 Tbps (8× 400 Gbps)"
echo ""

print_info "Instance status: STOPPED"
echo ""

print_warn "⏭️  Next Step: Start H100 Instance"
echo "   This will initialize the RDMA fabric (takes 10-15 minutes)"
echo "   Run: ./phase3-h100-provisioning/03-start-h100-instance.sh"

print_info ""
print_info "To view attachments:"
echo "   ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID"
