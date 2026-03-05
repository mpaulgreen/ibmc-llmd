#!/bin/bash
################################################################################
# Phase 4: Prepare H100 for OpenShift Integration
# Purpose: Configure H100 instance to join OpenShift cluster
# Time: ~20-30 minutes
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
print_instruction() { echo -e "${BLUE}[INSTRUCTION]${NC} $1"; }
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
print_info "   H100 Instance: $H100_INSTANCE_ID"

################################################################################
# Get H100 Instance Information
################################################################################

print_section "Getting H100 Instance Information"

# Login to IBM Cloud
if ! ibmcloud target &>/dev/null; then
    ibmcloud_login
fi

INSTANCE_INFO=$(ibmcloud is instance "$H100_INSTANCE_ID" --output json)
INSTANCE_NAME=$(echo "$INSTANCE_INFO" | jq -r '.name')
PRIVATE_IP=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface.primary_ip.address')
FLOATING_IP=$(echo "$INSTANCE_INFO" | jq -r '.primary_network_interface.floating_ips[0].address // empty')
INSTANCE_STATUS=$(echo "$INSTANCE_INFO" | jq -r '.status')

print_info "Instance details:"
echo "   Name:       $INSTANCE_NAME"
echo "   Status:     $INSTANCE_STATUS"
echo "   Private IP: $PRIVATE_IP"

if [[ -n "$FLOATING_IP" ]]; then
    echo "   Public IP:  $FLOATING_IP"
    H100_IP="$FLOATING_IP"
else
    print_warn "No public IP - using private IP"
    H100_IP="$PRIVATE_IP"
fi

if [[ "$INSTANCE_STATUS" != "running" ]]; then
    print_error "Instance is not running: $INSTANCE_STATUS"
    exit 1
fi

################################################################################
# Get Cluster Information
################################################################################

print_section "Getting Cluster Information"

# Get cluster API endpoint
API_URL=$(oc whoami --show-server)
print_info "Cluster API: $API_URL"

# Extract API hostname and port
API_HOSTNAME=$(echo "$API_URL" | sed -e 's|https://||' -e 's|:.*||')
API_PORT=$(echo "$API_URL" | sed -e 's|.*:||')

print_info "API Hostname: $API_HOSTNAME"
print_info "API Port: $API_PORT"

################################################################################
# Generate Worker Ignition or Cloud-Init
################################################################################

print_section "Generating Worker Node Configuration"

print_warn "⚠️  CRITICAL DECISION REQUIRED"
echo ""
echo "To integrate the H100 as an OpenShift worker, you need to choose one approach:"
echo ""
echo "Option A: RHCOS with Ignition (Recommended)"
echo "   - Best OpenShift integration"
echo "   - Requires reinstalling H100 with RHCOS image"
echo "   - Cluster networks must be reattached after reinstall"
echo "   - More complex initial setup"
echo ""
echo "Option B: RHEL with Manual Configuration"
echo "   - Works with existing RHEL installation"
echo "   - Requires manual kubelet configuration"
echo "   - More ongoing maintenance"
echo "   - Simpler if instance already has RHEL"
echo ""

read -p "Select option (A/B): " -n 1 -r
echo
INTEGRATION_OPTION="$REPLY"

################################################################################
# Option A: RHCOS with Ignition
################################################################################

if [[ "$INTEGRATION_OPTION" =~ ^[Aa]$ ]]; then
    print_section "Option A: RHCOS with Ignition Configuration"

    print_warn "This approach requires:"
    echo "   1. Creating worker ignition configuration"
    echo "   2. Reinstalling H100 with RHCOS + ignition"
    echo "   3. Reattaching cluster networks"
    echo ""

    # Create worker ignition configuration
    print_info "Creating worker ignition configuration..."

    WORKER_IGNITION_DIR="$INSTALL_DIR/worker-ignition"
    mkdir -p "$WORKER_IGNITION_DIR"

    # Generate worker ignition using openshift-install
    print_info "Generating ignition files..."

    # Note: This requires the original install-config.yaml
    if [[ ! -f "$INSTALL_DIR/install-config.yaml.backup" ]]; then
        print_error "install-config.yaml.backup not found"
        print_error "Cannot generate ignition without original config"
        exit 1
    fi

    # Copy install-config for ignition generation
    cp "$INSTALL_DIR/install-config.yaml.backup" "$WORKER_IGNITION_DIR/install-config.yaml"

    # Generate manifests and ignition
    cd "$WORKER_IGNITION_DIR"

    print_info "This will generate ignition files. Do not run 'create cluster' again!"
    print_warn "Running: openshift-install create ignition-configs"

    # Note: create ignition-configs doesn't deploy anything, just generates files
    if ! openshift-install create ignition-configs --dir "$WORKER_IGNITION_DIR" --log-level=info; then
        print_error "Failed to generate ignition configs"
        exit 1
    fi

    cd - > /dev/null

    WORKER_IGNITION_FILE="$WORKER_IGNITION_DIR/worker.ign"

    if [[ ! -f "$WORKER_IGNITION_FILE" ]]; then
        print_error "Worker ignition file not created: $WORKER_IGNITION_FILE"
        exit 1
    fi

    print_info "✅ Worker ignition file created: $WORKER_IGNITION_FILE"

    print_section "Next Steps for Option A"

    print_instruction "Manual steps required:"
    echo ""
    echo "1. Upload worker.ign to accessible location (HTTP server or Object Storage):"
    echo "   - Upload: $WORKER_IGNITION_FILE"
    echo "   - Get URL for ignition file"
    echo ""
    echo "2. Reinstall H100 instance with RHCOS:"
    echo "   - Find RHCOS image matching your OpenShift version"
    echo "   - Delete current H100 instance (preserve cluster network interfaces)"
    echo "   - Create new instance with RHCOS image"
    echo "   - Use ignition URL in user data"
    echo ""
    echo "3. Reattach cluster networks:"
    echo "   - Stop new instance"
    echo "   - Attach the 8 cluster network interfaces"
    echo "   - Start instance"
    echo ""
    echo "4. Wait for node to appear and run:"
    echo "   ./phase4-worker-integration/02-approve-csrs.sh"
    echo ""

    print_warn "Option A requires significant manual work. Consider Option B for faster integration."

################################################################################
# Option B: RHEL with Manual Configuration
################################################################################

elif [[ "$INTEGRATION_OPTION" =~ ^[Bb]$ ]]; then
    print_section "Option B: RHEL Manual Configuration"

    print_info "This approach configures the existing H100 instance to join OpenShift"
    echo ""

    # Test SSH connectivity
    print_info "Testing SSH connectivity to H100..."

    if ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 root@$H100_IP "echo 'SSH OK'" &>/dev/null; then
        print_info "✅ SSH connection successful"
        SSH_AVAILABLE=true
    else
        print_error "Cannot SSH to H100 instance at $H100_IP"
        print_error "Ensure:"
        echo "   - Instance is running"
        echo "   - Security group allows SSH (port 22)"
        echo "   - SSH key is correct"
        echo "   - Network connectivity exists"
        SSH_AVAILABLE=false
    fi

    if [[ "$SSH_AVAILABLE" == "false" ]]; then
        print_warn "Continue without SSH? You'll need console access. (y/N): "
        read -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Create configuration script for H100
    REMOTE_CONFIG_SCRIPT="/tmp/configure-h100-worker.sh"

    print_info "Generating configuration script for H100..."

    cat > "$REMOTE_CONFIG_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
################################################################################
# H100 Worker Node Configuration Script
# Run this ON THE H100 INSTANCE (as root)
################################################################################

set -e

echo "Configuring H100 as OpenShift worker node..."

# Check we're running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Set variables (will be replaced by main script)
CLUSTER_API="__CLUSTER_API__"
CLUSTER_NAME="__CLUSTER_NAME__"

echo "Target cluster: $CLUSTER_NAME"
echo "API endpoint: $CLUSTER_API"

# Install required repositories
echo "Enabling required repositories..."
subscription-manager repos --enable=rhel-8-for-x86_64-baseos-rpms
subscription-manager repos --enable=rhel-8-for-x86_64-appstream-rpms
subscription-manager repos --enable=rhocp-4.20-for-rhel-8-x86_64-rpms

# Install required packages
echo "Installing required packages..."
dnf install -y \
    cri-o \
    openshift-hyperkube \
    NetworkManager \
    iptables

# Enable and start CRI-O
echo "Enabling CRI-O..."
systemctl enable crio
systemctl start crio

# Configure kubelet
echo "Configuring kubelet..."

# Note: This is a simplified configuration
# Production setup requires proper ignition/machine-config

mkdir -p /etc/kubernetes
mkdir -p /var/lib/kubelet

# This is where manual configuration would go
# In a real deployment, you'd need:
# - Bootstrap kubeconfig
# - CA certificates
# - Node certificates
# - Kubelet configuration

echo "⚠️  MANUAL CONFIGURATION REQUIRED"
echo "This script provides framework only."
echo "See OpenShift documentation for adding RHEL compute nodes:"
echo "https://docs.openshift.com/container-platform/latest/machine_management/adding-rhel-compute.html"

EOFSCRIPT

    # Replace placeholders
    sed -i.bak "s|__CLUSTER_API__|$API_URL|g" "$REMOTE_CONFIG_SCRIPT"
    sed -i.bak "s|__CLUSTER_NAME__|$CLUSTER_NAME|g" "$REMOTE_CONFIG_SCRIPT"

    chmod +x "$REMOTE_CONFIG_SCRIPT"

    print_info "✅ Configuration script generated"

    if [[ "$SSH_AVAILABLE" == "true" ]]; then
        print_info "Copying configuration script to H100..."
        scp -o StrictHostKeyChecking=no "$REMOTE_CONFIG_SCRIPT" root@$H100_IP:/tmp/configure-h100-worker.sh

        print_section "Ready to Configure H100"

        print_warn "⚠️  The automatic configuration script has limitations"
        print_warn "For full RHEL worker integration, follow OpenShift documentation"
        echo ""
        print_instruction "Recommended approach:"
        echo "   1. Use Red Hat's official openshift-ansible playbook for RHEL workers"
        echo "   2. Or use MachineConfig to manage the node"
        echo ""
        read -p "Run basic configuration script on H100? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            print_info "Executing on H100..."
            ssh -o StrictHostKeyChecking=no root@$H100_IP "bash /tmp/configure-h100-worker.sh"
        fi
    else
        print_instruction "Configuration script saved to: $REMOTE_CONFIG_SCRIPT"
        echo "Copy this to H100 and run as root"
    fi

else
    print_error "Invalid option selected"
    exit 1
fi

################################################################################
# Summary
################################################################################

print_section "Preparation Summary"

print_warn "⚠️  IMPORTANT: Standard Worker Integration Limitations"
echo ""
echo "The H100 instance has cluster networks attached, which is non-standard."
echo "Standard OpenShift worker join procedures may require adaptation."
echo ""

print_info "Recommended Alternative Approach:"
echo ""
echo "1. Create a MachineSet that references the existing H100 instance"
echo "2. Use Machine Config Operator to manage the node"
echo "3. Let OpenShift's automation handle the join process"
echo ""

print_warn "OR: Consider IBM Cloud ROKS (Managed OpenShift)"
echo "ROKS may have better support for cluster networks with GPU instances"
echo ""

print_info "Documentation to review:"
echo "   - Adding RHEL nodes: https://docs.openshift.com/container-platform/latest/machine_management/adding-rhel-compute.html"
echo "   - Machine Config: https://docs.openshift.com/container-platform/latest/post_installation_configuration/machine-configuration-tasks.html"
echo "   - IBM Cloud considerations: Check with IBM Cloud support for cluster network + OpenShift integration"
echo ""

print_warn "⏭️  Next Step: Approve CSRs (if node starts joining)"
echo "   Run: ./phase4-worker-integration/02-approve-csrs.sh"
echo ""
echo "   Monitor for CSRs with: watch oc get csr"
