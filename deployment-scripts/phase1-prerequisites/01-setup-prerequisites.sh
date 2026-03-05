#!/bin/bash
################################################################################
# Phase 1: Prerequisites Setup
# Purpose: Install required tools and configure environment
# Time: ~30 minutes
################################################################################

set -e  # Exit on error
set -u  # Exit on undefined variable

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_section() {
    echo ""
    echo "=========================================="
    echo "$1"
    echo "=========================================="
    echo ""
}

################################################################################
# Step 1: Verify prerequisites
################################################################################

print_section "Step 1: Verifying Prerequisites"

# Check for macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    print_error "This script is designed for macOS. Detected OS: $OSTYPE"
    exit 1
fi
print_info "✅ Running on macOS"

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    print_warn "Homebrew not found. Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
    print_info "✅ Homebrew installed"
fi

# Check for IBM Cloud CLI
if ! command -v ibmcloud &> /dev/null; then
    print_error "IBM Cloud CLI not found. Please install from:"
    print_error "https://cloud.ibm.com/docs/cli?topic=cli-install-ibmcloud-cli"
    exit 1
fi
print_info "✅ IBM Cloud CLI installed: $(ibmcloud version | head -1)"

# Check for VPC plugin
if ! ibmcloud plugin list | grep -q vpc-infrastructure; then
    print_warn "VPC infrastructure plugin not found. Installing..."
    ibmcloud plugin install vpc-infrastructure -f
else
    print_info "✅ VPC infrastructure plugin installed"
fi

################################################################################
# Step 2: Install jq (JSON processor)
################################################################################

print_section "Step 2: Installing jq (JSON processor)"

if ! command -v jq &> /dev/null; then
    print_info "Installing jq via Homebrew..."
    brew install jq
else
    print_info "✅ jq already installed: $(jq --version)"
fi

################################################################################
# Step 3: Install Helm 3
################################################################################

print_section "Step 3: Installing Helm 3"

if ! command -v helm &> /dev/null; then
    print_info "Installing Helm 3 via Homebrew..."
    brew install helm
else
    HELM_VERSION=$(helm version --short)
    if [[ $HELM_VERSION == v3* ]]; then
        print_info "✅ Helm 3 already installed: $HELM_VERSION"
    else
        print_warn "Helm 2 detected. Upgrading to Helm 3..."
        brew upgrade helm
    fi
fi

################################################################################
# Step 4: Install OpenShift Installer
################################################################################

print_section "Step 4: Installing OpenShift Installer"

INSTALLER_PATH="/usr/local/bin/openshift-install"

if command -v openshift-install &> /dev/null; then
    CURRENT_VERSION=$(openshift-install version | head -1)
    print_info "OpenShift installer already installed: $CURRENT_VERSION"

    read -p "Do you want to reinstall/update? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Skipping installer installation"
    else
        INSTALL_INSTALLER=true
    fi
else
    INSTALL_INSTALLER=true
fi

if [[ "${INSTALL_INSTALLER:-false}" == "true" ]]; then
    # Look for downloaded installer in Downloads folder
    INSTALLER_TARBALL=$(find ~/Downloads -name "openshift-install-mac-*.tar.gz" -type f 2>/dev/null | sort -r | head -1)

    if [[ -z "$INSTALLER_TARBALL" ]]; then
        print_error "OpenShift installer tarball not found in ~/Downloads"
        print_error ""
        print_error "Please download OpenShift installer for macOS:"
        print_error "1. Visit: https://console.redhat.com/openshift/install"
        print_error "2. Select: IBM Cloud → Installer-Provisioned Infrastructure"
        print_error "3. Download: OpenShift Installer for macOS (4.20+)"
        print_error "4. Save to: ~/Downloads/"
        print_error ""
        print_error "Then run this script again."
        exit 1
    fi

    print_info "Found installer: $INSTALLER_TARBALL"

    # Extract to temporary directory
    TEMP_DIR=$(mktemp -d)
    tar -xzf "$INSTALLER_TARBALL" -C "$TEMP_DIR"

    # Install to /usr/local/bin
    print_info "Installing to $INSTALLER_PATH (requires sudo)"
    sudo mv "$TEMP_DIR/openshift-install" "$INSTALLER_PATH"
    sudo chmod +x "$INSTALLER_PATH"

    # Cleanup
    rm -rf "$TEMP_DIR"

    print_info "✅ OpenShift installer installed: $(openshift-install version | head -1)"
fi

################################################################################
# Step 5: Install OpenShift CLI (oc)
################################################################################

print_section "Step 5: Installing OpenShift CLI (oc)"

OC_PATH="/usr/local/bin/oc"

if command -v oc &> /dev/null; then
    print_info "✅ oc CLI already installed: $(oc version --client | head -1)"
else
    print_info "Extracting oc from openshift-install..."

    # The openshift-install binary contains oc
    TEMP_DIR=$(mktemp -d)

    # Download oc client from Red Hat mirror
    print_info "Downloading oc client for macOS..."
    curl -L -o "$TEMP_DIR/oc.tar.gz" \
        "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-mac.tar.gz"

    tar -xzf "$TEMP_DIR/oc.tar.gz" -C "$TEMP_DIR"

    print_info "Installing to $OC_PATH (requires sudo)"
    sudo mv "$TEMP_DIR/oc" "$OC_PATH"
    sudo chmod +x "$OC_PATH"

    # Also install kubectl symlink
    sudo ln -sf "$OC_PATH" /usr/local/bin/kubectl

    # Cleanup
    rm -rf "$TEMP_DIR"

    print_info "✅ oc CLI installed: $(oc version --client | head -1)"
fi

################################################################################
# Step 6: Verify Red Hat Pull Secret
################################################################################

print_section "Step 6: Verifying Red Hat Pull Secret"

PULL_SECRET_PATH="$HOME/.pull-secret.json"

if [[ -f "$PULL_SECRET_PATH" ]]; then
    # Verify it's valid JSON
    if jq empty "$PULL_SECRET_PATH" 2>/dev/null; then
        print_info "✅ Pull secret found and valid: $PULL_SECRET_PATH"
    else
        print_error "Pull secret exists but is not valid JSON: $PULL_SECRET_PATH"
        exit 1
    fi
else
    # Look for downloaded pull secret
    PULL_SECRET_DOWNLOAD=$(find ~/Downloads -name "pull-secret*" -type f 2>/dev/null | head -1)

    if [[ -n "$PULL_SECRET_DOWNLOAD" ]]; then
        print_info "Found pull secret: $PULL_SECRET_DOWNLOAD"
        print_info "Moving to $PULL_SECRET_PATH"
        cp "$PULL_SECRET_DOWNLOAD" "$PULL_SECRET_PATH"
        chmod 600 "$PULL_SECRET_PATH"
        print_info "✅ Pull secret configured"
    else
        print_error "Red Hat pull secret not found"
        print_error ""
        print_error "Please download your pull secret:"
        print_error "1. Visit: https://console.redhat.com/openshift/install/pull-secret"
        print_error "2. Click: Download pull secret"
        print_error "3. Save to: ~/Downloads/"
        print_error ""
        print_error "Then run this script again."
        exit 1
    fi
fi

################################################################################
# Step 7: Verify SSH Key
################################################################################

print_section "Step 7: Verifying SSH Key"

SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

if [[ -f "$SSH_KEY_PATH" ]]; then
    print_info "✅ SSH public key found: $SSH_KEY_PATH"
    print_info "Key fingerprint:"
    ssh-keygen -lf "$SSH_KEY_PATH"
else
    print_warn "SSH key not found at $SSH_KEY_PATH"
    read -p "Generate new SSH key pair? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        ssh-keygen -t rsa -b 4096 -f "$HOME/.ssh/id_rsa" -N ""
        print_info "✅ SSH key pair generated"
    else
        print_error "SSH key required for deployment. Exiting."
        exit 1
    fi
fi

################################################################################
# Step 8: Create Environment Configuration
################################################################################

print_section "Step 8: Creating Environment Configuration"

ENV_FILE="$HOME/.ibmcloud-h100-env"

if [[ -f "$ENV_FILE" ]]; then
    print_warn "Environment file already exists: $ENV_FILE"
    read -p "Overwrite? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Keeping existing environment file"
        print_warn "Remember to source it: source $ENV_FILE"
        exit 0
    fi
fi

cat > "$ENV_FILE" << 'EOF'
#!/bin/bash
################################################################################
# IBM Cloud H100 OpenShift Deployment Environment
# Generated by: setup-prerequisites.sh
# Date: 2026-02-28
################################################################################

# IBM Cloud Configuration
export IBMCLOUD_API_KEY="YOUR_API_KEY_HERE"  # ⚠️ REPLACE THIS
export IBMCLOUD_REGION="eu-de"
export IBMCLOUD_ZONE="eu-de-2"
export IBMCLOUD_RESOURCE_GROUP="Default"

# Existing Infrastructure IDs (from user's setup)
export VPC_ID="r010-39a1b8f9-0c94-4fea-9842-54635fb079e9"
export VPC_NAME="rdma-pvc-eude"
export CN_ID="02c7-20a6fc6c-33f1-461a-b69b-f36f83255022"
export CN_NAME="rdma-cluster"
export MGMT_SUBNET_ID="02c7-67b188b3-1981-4454-bc7b-1417f8cdee5d"
export SG_ID="r010-25a67700-a8a2-48d4-a837-573734fca8e4"
export KEY_ID="r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8"

# GPU Instance Configuration
export GPU_PROFILE="gx3d-160x1792x8h100"

# Cluster Network Subnet IDs (8 subnets for 8 GPU rails)
export CN_SUBNET_ID_0="02c7-8da7dc5a-da5b-4897-80c2-5d8dc5215faf"
export CN_SUBNET_ID_1="02c7-967ea5f3-ad7b-4a70-bb96-ce89d54e4a90"
export CN_SUBNET_ID_2="02c7-b206ced4-b1e6-4e55-ab21-634b8e2e41e5"
export CN_SUBNET_ID_3="02c7-394be494-ebc1-4c9b-82b6-19cc4e2284da"
export CN_SUBNET_ID_4="02c7-99c4357f-d349-482a-b85b-78edab8a50c7"
export CN_SUBNET_ID_5="02c7-78b5d725-1aff-4dda-a093-44e25cf2e321"
export CN_SUBNET_ID_6="02c7-5fc1a6d7-dd0b-4860-a6fb-b25bad65fd22"
export CN_SUBNET_ID_7="02c7-faf2bb3c-a499-4441-9cb5-693fe09130e0"

# Cluster Configuration
export CLUSTER_NAME="ocp-h100-cluster"
export INSTALL_DIR="$HOME/ocp-h100-ipi-install"

# Paths
export PULL_SECRET_PATH="$HOME/.pull-secret.json"
export SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

# Runtime Variables (set during deployment)
export H100_INSTANCE_ID=""  # Set by phase3 scripts
export H100_NODE_NAME=""    # Set by phase4 scripts
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"

################################################################################
# Helper Functions
################################################################################

# Function to verify environment is loaded
verify_environment() {
    if [[ -z "$IBMCLOUD_API_KEY" || "$IBMCLOUD_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
        echo "ERROR: IBMCLOUD_API_KEY not set"
        echo "Please edit $HOME/.ibmcloud-h100-env and set your API key"
        return 1
    fi

    echo "✅ Environment loaded successfully"
    return 0
}

# Function to login to IBM Cloud
ibmcloud_login() {
    echo "Logging into IBM Cloud..."
    ibmcloud login --apikey "$IBMCLOUD_API_KEY" \
        -r "$IBMCLOUD_REGION" \
        -g "$IBMCLOUD_RESOURCE_GROUP"
}

# Function to verify cluster access
verify_cluster_access() {
    if [[ ! -f "$KUBECONFIG" ]]; then
        echo "ERROR: KUBECONFIG not found at $KUBECONFIG"
        return 1
    fi

    oc version --client
    oc cluster-info
}

################################################################################

echo "IBM Cloud H100 Environment loaded"
echo "Run 'verify_environment' to check configuration"
echo "Run 'ibmcloud_login' to authenticate to IBM Cloud"
EOF

chmod 600 "$ENV_FILE"

print_info "✅ Environment file created: $ENV_FILE"
print_warn ""
print_warn "⚠️  IMPORTANT: Edit the environment file and set your IBM Cloud API key:"
print_warn "    vim $ENV_FILE"
print_warn ""
print_warn "Then source it:"
print_warn "    source $ENV_FILE"

################################################################################
# Step 9: Summary
################################################################################

print_section "Prerequisites Setup Complete"

print_info "✅ Installed/Verified Tools:"
echo "   - IBM Cloud CLI: $(ibmcloud version | head -1)"
echo "   - VPC Plugin: $(ibmcloud plugin list | grep vpc-infrastructure | awk '{print $2}')"
echo "   - jq: $(jq --version)"
echo "   - Helm: $(helm version --short)"
echo "   - openshift-install: $(openshift-install version | head -1)"
echo "   - oc: $(oc version --client 2>&1 | head -1)"

print_info ""
print_info "✅ Verified Credentials:"
echo "   - Pull Secret: $PULL_SECRET_PATH"
echo "   - SSH Key: $SSH_KEY_PATH"
echo "   - Environment: $ENV_FILE"

print_info ""
print_warn "📝 Next Steps:"
echo "   1. Edit environment file: vim $ENV_FILE"
echo "   2. Set your IBM Cloud API key"
echo "   3. Source the environment: source $ENV_FILE"
echo "   4. Run verification: ./phase1-prerequisites/02-verify-environment.sh"
echo "   5. Proceed to Phase 2: ./phase2-ipi-control-plane/01-generate-install-config.sh"

print_info ""
print_info "For questions, see: deployment-scripts/README.md"
