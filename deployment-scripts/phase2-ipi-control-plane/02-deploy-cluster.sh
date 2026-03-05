#!/bin/bash
################################################################################
# Phase 2: Deploy OpenShift IPI Control Plane
# Purpose: Deploy 3-node control plane using openshift-install
# Time: ~45-60 minutes
################################################################################

set -e
set -u

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_progress() { echo -e "${BLUE}[PROGRESS]${NC} $1"; }
print_section() { echo ""; echo "=========================================="; echo "$1"; echo "=========================================="; echo ""; }

################################################################################
# Load Environment
################################################################################

print_section "Loading Environment Configuration"

ENV_FILE="$HOME/.ibmcloud-h100-env"

if [[ ! -f "$ENV_FILE" ]]; then
    print_error "Environment file not found: $ENV_FILE"
    exit 1
fi

source "$ENV_FILE"
print_info "✅ Environment loaded"

################################################################################
# Pre-flight Checks
################################################################################

print_section "Pre-flight Checks"

# Check install-config.yaml exists
if [[ ! -f "$INSTALL_DIR/install-config.yaml" ]]; then
    print_error "install-config.yaml not found"
    print_error "Run: ./phase2-ipi-control-plane/01-generate-install-config.sh"
    exit 1
fi
print_info "✅ install-config.yaml found"

# Check openshift-install is available
if ! command -v openshift-install &>/dev/null; then
    print_error "openshift-install not found"
    print_error "Run: ./phase1-prerequisites/01-setup-prerequisites.sh"
    exit 1
fi
INSTALLER_VERSION=$(openshift-install version | head -1)
print_info "✅ OpenShift installer: $INSTALLER_VERSION"

# Verify IBM Cloud login
if ! ibmcloud target &>/dev/null; then
    print_warn "Not logged into IBM Cloud. Logging in..."
    ibmcloud_login
fi
print_info "✅ IBM Cloud authenticated"

################################################################################
# Final Confirmation
################################################################################

print_section "Deployment Confirmation"

print_warn "⚠️  IMPORTANT: This will create OpenShift cluster resources in IBM Cloud"
echo ""
echo "Resources that will be created:"
echo "  - 3 master node VPC instances (bx2-8x32)"
echo "  - Bootstrap node (temporary, deleted after cluster ready)"
echo "  - VPC load balancer for API/ingress"
echo "  - Security groups and network ACLs"
echo "  - Public IPs for cluster access"
echo ""
echo "Cluster configuration:"
echo "  Name:              $CLUSTER_NAME"
echo "  Region:            $IBMCLOUD_REGION"
echo "  VPC:               $VPC_NAME"
echo "  Resource Group:    $IBMCLOUD_RESOURCE_GROUP"
echo ""
echo "Installation directory: $INSTALL_DIR"
echo ""

print_warn "⏱️  Estimated time: 45-60 minutes"
print_warn "💰  Estimated cost: ~\$0.50-1.00 per hour for control plane"
echo ""

read -p "Proceed with cluster deployment? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_warn "Deployment cancelled by user"
    exit 0
fi

################################################################################
# Deploy Cluster
################################################################################

print_section "Deploying OpenShift Cluster"

print_info "Starting OpenShift installer..."
print_info "Log output will be saved to: $INSTALL_DIR/installation.log"
echo ""

print_progress "Phase 1/4: Creating infrastructure..."
print_progress "  - Creating VPC resources"
print_progress "  - Provisioning bootstrap node"
print_progress "  - Provisioning master nodes"
echo ""

print_progress "Phase 2/4: Bootstrapping cluster..."
print_progress "  - Waiting for bootstrap to complete"
print_progress "  - Installing OpenShift control plane"
echo ""

print_progress "Phase 3/4: Installing cluster operators..."
print_progress "  - Deploying cluster operators"
print_progress "  - Configuring ingress and API"
echo ""

print_progress "Phase 4/4: Finalizing installation..."
print_progress "  - Removing bootstrap node"
print_progress "  - Waiting for cluster operators"
echo ""

print_warn "⏳ This will take 45-60 minutes. Do not interrupt!"
echo ""

# Run installer with logging
START_TIME=$(date +%s)

if openshift-install create cluster \
    --dir "$INSTALL_DIR" \
    --log-level=info 2>&1 | tee "$INSTALL_DIR/installation.log"; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    MINUTES=$((DURATION / 60))

    print_section "✅ Cluster Deployment Successful"

    print_info "Deployment completed in $MINUTES minutes"

else
    print_error "❌ Cluster deployment failed"
    print_error "Check logs: $INSTALL_DIR/installation.log"
    print_error "Check OpenShift installer logs: $INSTALL_DIR/.openshift_install.log"
    exit 1
fi

################################################################################
# Export Kubeconfig
################################################################################

print_section "Configuring Cluster Access"

export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
echo "export KUBECONFIG=$INSTALL_DIR/auth/kubeconfig" >> "$ENV_FILE"

print_info "✅ KUBECONFIG exported"
print_info "   Path: $KUBECONFIG"

################################################################################
# Verify Cluster
################################################################################

print_section "Verifying Cluster Installation"

# Test oc connection
print_info "Testing cluster connection..."
if oc version &>/dev/null; then
    print_info "✅ Connected to cluster"
    oc version
else
    print_error "Failed to connect to cluster"
    exit 1
fi

echo ""

# Check nodes
print_info "Checking control plane nodes..."
oc get nodes

NODE_COUNT=$(oc get nodes --no-headers | wc -l | tr -d ' ')
if [[ "$NODE_COUNT" -eq 3 ]]; then
    print_info "✅ All 3 master nodes ready"
else
    print_warn "Expected 3 nodes, found $NODE_COUNT"
fi

echo ""

# Check cluster operators
print_info "Checking cluster operators..."
oc get co

DEGRADED_COUNT=$(oc get co --no-headers | grep -c "True.*False.*False" || true)
if [[ "$DEGRADED_COUNT" -gt 0 ]]; then
    print_warn "Some cluster operators are degraded"
    print_warn "This may resolve automatically. Monitor with: oc get co"
fi

echo ""

# Get cluster info
print_info "Cluster information:"
CLUSTER_VERSION=$(oc version -o json | jq -r '.openshiftVersion')
API_URL=$(oc whoami --show-server)
CONSOLE_URL=$(oc whoami --show-console 2>/dev/null || echo "Not available yet")

echo "  OpenShift Version: $CLUSTER_VERSION"
echo "  API URL:           $API_URL"
echo "  Console URL:       $CONSOLE_URL"

################################################################################
# Display Credentials
################################################################################

print_section "Cluster Credentials"

KUBEADMIN_PASSWORD=$(cat "$INSTALL_DIR/auth/kubeadmin-password")

echo "Administrator credentials:"
echo "  Username: kubeadmin"
echo "  Password: $KUBEADMIN_PASSWORD"
echo ""
echo "Console URL: $CONSOLE_URL"
echo ""
print_warn "⚠️  Save these credentials securely!"

################################################################################
# Save Cluster Information
################################################################################

print_section "Saving Cluster Information"

CLUSTER_INFO_FILE="$INSTALL_DIR/cluster-info.txt"

cat > "$CLUSTER_INFO_FILE" << EOF
OpenShift Cluster Information
Generated: $(date)
=====================================

Cluster Name:        $CLUSTER_NAME
OpenShift Version:   $CLUSTER_VERSION
Region:              $IBMCLOUD_REGION
Installation Dir:    $INSTALL_DIR

API URL:             $API_URL
Console URL:         $CONSOLE_URL

Credentials:
  Username:          kubeadmin
  Password:          $KUBEADMIN_PASSWORD

Kubeconfig:          $KUBECONFIG

Control Plane Nodes: 3 masters (bx2-8x32)
Worker Nodes:        0 (H100 to be added in Phase 4)

=====================================

Quick Commands:
  Access cluster:    export KUBECONFIG=$KUBECONFIG
  View nodes:        oc get nodes
  View operators:    oc get co
  Web console:       open $CONSOLE_URL

Next Steps:
  1. Verify cluster health: ./phase2-ipi-control-plane/03-verify-control-plane.sh
  2. Provision H100:        ./phase3-h100-provisioning/01-create-h100-instance.sh
EOF

print_info "✅ Cluster info saved: $CLUSTER_INFO_FILE"

################################################################################
# Summary
################################################################################

print_section "Deployment Complete"

print_info "✅ OpenShift control plane deployed successfully"
print_info ""
print_info "Cluster access:"
echo "   export KUBECONFIG=$KUBECONFIG"
echo "   oc get nodes"
echo "   oc whoami --show-console"

print_info ""
print_warn "⏭️  Next Phase: Provision H100 GPU Instance"
echo "   Run: ./phase3-h100-provisioning/01-create-h100-instance.sh"

print_info ""
print_info "To verify cluster health:"
echo "   ./phase2-ipi-control-plane/03-verify-control-plane.sh"

print_info ""
print_warn "⚠️  Technology Preview Reminder:"
echo "   This cluster is running OpenShift IPI on IBM Cloud VPC (Tech Preview)"
echo "   Not supported for production use with Red Hat SLAs"
