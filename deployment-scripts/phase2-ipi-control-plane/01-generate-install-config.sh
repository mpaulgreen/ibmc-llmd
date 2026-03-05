#!/bin/bash
################################################################################
# Phase 2: Generate OpenShift Install Configuration
# Purpose: Create install-config.yaml for IPI deployment
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

if [[ ! -f "$ENV_FILE" ]]; then
    print_error "Environment file not found: $ENV_FILE"
    print_error "Run: ./phase1-prerequisites/01-setup-prerequisites.sh"
    exit 1
fi

source "$ENV_FILE"

# Verify environment
if ! verify_environment &>/dev/null; then
    print_error "Environment verification failed"
    print_error "Run: ./phase1-prerequisites/02-verify-environment.sh"
    exit 1
fi

print_info "✅ Environment loaded"

################################################################################
# Login to IBM Cloud
################################################################################

print_section "Authenticating to IBM Cloud"

ibmcloud_login

################################################################################
# Create Installation Directory
################################################################################

print_section "Creating Installation Directory"

if [[ -d "$INSTALL_DIR" ]]; then
    print_warn "Installation directory already exists: $INSTALL_DIR"
    read -p "Delete and recreate? This will destroy any existing cluster! (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_warn "Removing existing installation directory..."
        rm -rf "$INSTALL_DIR"
    else
        print_error "Installation directory must be empty. Exiting."
        exit 1
    fi
fi

mkdir -p "$INSTALL_DIR"
print_info "✅ Created: $INSTALL_DIR"

################################################################################
# Gather Required Information
################################################################################

print_section "Gathering Infrastructure Information"

# Get management subnet name (required by install-config.yaml)
print_info "Fetching management subnet details..."
MGMT_SUBNET_INFO=$(ibmcloud is subnet "$MGMT_SUBNET_ID" --output json)
MGMT_SUBNET_NAME=$(echo "$MGMT_SUBNET_INFO" | jq -r '.name')
MGMT_SUBNET_CIDR=$(echo "$MGMT_SUBNET_INFO" | jq -r '.ipv4_cidr_block')

print_info "  Management subnet: $MGMT_SUBNET_NAME"
print_info "  CIDR: $MGMT_SUBNET_CIDR"

# Read pull secret
print_info "Reading pull secret..."
PULL_SECRET=$(cat "$PULL_SECRET_PATH" | jq -c .)
print_info "  ✅ Pull secret loaded"

# Read SSH public key
print_info "Reading SSH public key..."
SSH_PUBLIC_KEY=$(cat "$SSH_KEY_PATH")
print_info "  ✅ SSH key loaded"

################################################################################
# Generate install-config.yaml
################################################################################

print_section "Generating install-config.yaml"

cat > "$INSTALL_DIR/install-config.yaml" << EOF
apiVersion: v1
baseDomain: ibm-cloud.local
metadata:
  name: ${CLUSTER_NAME}

compute:
- name: worker
  replicas: 0  # No workers initially - H100 will be added manually
  platform:
    ibmcloud: {}

controlPlane:
  name: master
  replicas: 3  # High availability control plane
  platform:
    ibmcloud:
      type: bx2-8x32  # 8 vCPU, 32GB RAM per master

platform:
  ibmcloud:
    region: ${IBMCLOUD_REGION}
    resourceGroupName: ${IBMCLOUD_RESOURCE_GROUP}
    networkResourceGroupName: ${IBMCLOUD_RESOURCE_GROUP}
    vpcName: ${VPC_NAME}
    subnets:
    - ${MGMT_SUBNET_NAME}

# CRITICAL: Required for IBM Cloud VPC IPI
credentialsMode: Manual

pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
EOF

print_info "✅ install-config.yaml created"

# Create backup (install process consumes the file)
cp "$INSTALL_DIR/install-config.yaml" "$INSTALL_DIR/install-config.yaml.backup"
print_info "✅ Backup created: install-config.yaml.backup"

################################################################################
# Display Configuration
################################################################################

print_section "Installation Configuration Summary"

cat << EOF
Cluster Name:        ${CLUSTER_NAME}
Region:              ${IBMCLOUD_REGION}
Zone:                ${IBMCLOUD_ZONE}
Resource Group:      ${IBMCLOUD_RESOURCE_GROUP}

VPC:                 ${VPC_NAME}
Management Subnet:   ${MGMT_SUBNET_NAME} (${MGMT_SUBNET_CIDR})

Control Plane:       3 masters (bx2-8x32)
Initial Workers:     0 (H100 will be added in Phase 4)

Installation Dir:    ${INSTALL_DIR}
EOF

################################################################################
# Review Configuration
################################################################################

print_section "Configuration Review"

print_warn "⚠️  Technology Preview Notice"
echo "OpenShift IPI on IBM Cloud VPC is a Technology Preview feature:"
echo "  - Not supported for production workloads"
echo "  - No Red Hat production SLA applies"
echo "  - May have functional limitations"
echo ""

print_info "Generated configuration:"
echo "----------------------------------------"
cat "$INSTALL_DIR/install-config.yaml.backup"
echo "----------------------------------------"
echo ""

read -p "Proceed with this configuration? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Deployment cancelled by user"
    print_info "Configuration saved to: $INSTALL_DIR/install-config.yaml.backup"
    print_info "You can edit it and copy to $INSTALL_DIR/install-config.yaml"
    exit 0
fi

################################################################################
# Summary
################################################################################

print_section "Configuration Generation Complete"

print_info "✅ install-config.yaml ready for deployment"
print_info ""
print_info "Files created:"
echo "   - $INSTALL_DIR/install-config.yaml"
echo "   - $INSTALL_DIR/install-config.yaml.backup"

print_info ""
print_warn "⏱️  Next Phase: Deploy OpenShift Control Plane (45-60 minutes)"
echo "   Run: ./phase2-ipi-control-plane/02-deploy-cluster.sh"

print_info ""
print_info "To review the plan: cat deployment-scripts/README.md"
