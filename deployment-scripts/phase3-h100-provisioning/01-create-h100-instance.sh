#!/bin/bash
################################################################################
# Phase 3: Create H100 GPU Instance
# Purpose: Provision H100 instance with VPC management network
# Time: ~10 minutes
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

print_info "✅ Environment loaded"

################################################################################
# Get RHCOS Image
################################################################################

print_section "Finding RHCOS Image"

print_info "Searching for RHCOS images..."

# Try to find most recent RHCOS image
IMAGE_ID=$(ibmcloud is images --output json | \
    jq -r '.[] | select(.name | contains("rhcos")) | select(.status == "available") | .id' | \
    head -1)

if [[ -z "$IMAGE_ID" ]]; then
    print_error "No RHCOS image found"
    print_error ""
    print_error "Please import RHCOS image manually:"
    print_error "1. Download RHCOS from: https://mirror.openshift.com/pub/openshift-v4/dependencies/rhcos/"
    print_error "2. Upload to IBM Cloud Object Storage"
    print_error "3. Import as VPC custom image"
    print_error ""
    print_error "Or use a generic RHEL-based image and configure later"
    print_error ""
    read -p "Enter image ID manually: " IMAGE_ID

    if [[ -z "$IMAGE_ID" ]]; then
        print_error "Image ID required. Exiting."
        exit 1
    fi
fi

IMAGE_INFO=$(ibmcloud is image "$IMAGE_ID" --output json)
IMAGE_NAME=$(echo "$IMAGE_INFO" | jq -r '.name')

print_info "✅ Using image: $IMAGE_NAME"
print_info "   Image ID: $IMAGE_ID"

################################################################################
# Check H100 Instance Doesn't Already Exist
################################################################################

print_section "Checking for Existing H100 Instance"

EXISTING_INSTANCE=$(ibmcloud is instances --output json | \
    jq -r ".[] | select(.name == \"ocp-h100-worker\") | .id" || true)

if [[ -n "$EXISTING_INSTANCE" ]]; then
    print_warn "Instance 'ocp-h100-worker' already exists"
    print_warn "Instance ID: $EXISTING_INSTANCE"
    print_warn ""
    read -p "Delete and recreate? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deleting existing instance..."
        ibmcloud is instance-delete "$EXISTING_INSTANCE" --force

        print_info "Waiting for deletion to complete..."
        sleep 30
    else
        print_info "Using existing instance: $EXISTING_INSTANCE"
        echo "export H100_INSTANCE_ID=$EXISTING_INSTANCE" >> "$ENV_FILE"
        print_warn "⏭️  Skip to next step: ./phase3-h100-provisioning/02-attach-cluster-networks.sh"
        exit 0
    fi
fi

################################################################################
# Create H100 Instance
################################################################################

print_section "Creating H100 GPU Instance"

print_info "Instance configuration:"
echo "   Name:           ocp-h100-worker"
echo "   Profile:        $GPU_PROFILE"
echo "   VPC:            $VPC_NAME"
echo "   Subnet:         $MGMT_SUBNET_ID"
echo "   Security Group: $SG_ID"
echo "   SSH Key:        $KEY_ID"
echo "   Image:          $IMAGE_NAME"
echo ""

print_warn "⏱️  This will take 5-10 minutes"
print_warn "💰  H100 cost: ~\$30-40 per hour"
echo ""

read -p "Proceed with H100 instance creation? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Instance creation cancelled"
    exit 0
fi

print_info "Creating H100 instance..."

INSTANCE_OUTPUT=$(ibmcloud is instance-create \
    ocp-h100-worker \
    "$VPC_ID" \
    "$IBMCLOUD_ZONE" \
    "$GPU_PROFILE" \
    "$MGMT_SUBNET_ID" \
    --image "$IMAGE_ID" \
    --keys "$KEY_ID" \
    --security-groups "$SG_ID" \
    --output json)

H100_INSTANCE_ID=$(echo "$INSTANCE_OUTPUT" | jq -r '.id')

if [[ -z "$H100_INSTANCE_ID" ]]; then
    print_error "Failed to create instance"
    echo "$INSTANCE_OUTPUT"
    exit 1
fi

print_info "✅ Instance created"
print_info "   Instance ID: $H100_INSTANCE_ID"

# Save to environment
echo "" >> "$ENV_FILE"
echo "# H100 Instance (created $(date))" >> "$ENV_FILE"
echo "export H100_INSTANCE_ID=$H100_INSTANCE_ID" >> "$ENV_FILE"

################################################################################
# Wait for Instance to Start
################################################################################

print_section "Waiting for Instance to Start"

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
# Get Instance Details
################################################################################

print_section "Instance Information"

INSTANCE_INFO=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json)

INSTANCE_NAME=$(echo "$INSTANCE_INFO" | jq -r '.name')
INSTANCE_STATUS=$(echo "$INSTANCE_INFO" | jq -r '.status')
INSTANCE_ZONE=$(echo "$INSTANCE_INFO" | jq -r '.zone.name')

# Get primary network interface IP
PRIMARY_NIC=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface')
PRIVATE_IP=$(echo "$PRIMARY_NIC" | jq -r '.primary_ip.address')

print_info "Instance details:"
echo "   Name:       $INSTANCE_NAME"
echo "   ID:         $H100_INSTANCE_ID"
echo "   Status:     $INSTANCE_STATUS"
echo "   Zone:       $INSTANCE_ZONE"
echo "   Profile:    $GPU_PROFILE"
echo "   Private IP: $PRIVATE_IP"
echo ""

# Check if public IP exists (for SSH access)
FLOATING_IP=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface.floating_ips[0].address // empty')

if [[ -n "$FLOATING_IP" ]]; then
    print_info "   Public IP:  $FLOATING_IP"
    print_info "   SSH:        ssh root@$FLOATING_IP"
else
    print_warn "No public IP assigned"
    print_warn "SSH access requires VPN or bastion host"
fi

################################################################################
# Stop Instance for Cluster Network Attachment
################################################################################

print_section "Preparing for Cluster Network Attachment"

print_warn "⚠️  Instance must be STOPPED to attach cluster networks"
print_info "The instance will be stopped in the next step"

################################################################################
# Summary
################################################################################

print_section "H100 Instance Creation Complete"

print_info "✅ H100 instance created and running"
print_info ""
print_info "Instance ID: $H100_INSTANCE_ID"
print_info "Private IP:  $PRIVATE_IP"

print_info ""
print_warn "⏭️  Next Step: Attach Cluster Network Interfaces"
echo "   This requires STOPPING the instance"
echo "   Run: ./phase3-h100-provisioning/02-attach-cluster-networks.sh"

print_info ""
print_info "To view instance details:"
echo "   ibmcloud is instance $H100_INSTANCE_ID"
