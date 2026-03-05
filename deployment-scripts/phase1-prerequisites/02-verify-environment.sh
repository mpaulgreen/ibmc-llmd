#!/bin/bash
################################################################################
# Phase 1: Verify Environment Configuration
# Purpose: Validate all prerequisites are met before deployment
# Time: ~5 minutes
################################################################################

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo ""; echo "==========================================" ; echo "$1"; echo "=========================================="; echo ""; }

ERRORS=0

################################################################################
# Check Environment File
################################################################################

print_section "Step 1: Checking Environment Configuration"

ENV_FILE="$HOME/.ibmcloud-h100-env"

if [[ ! -f "$ENV_FILE" ]]; then
    print_error "Environment file not found: $ENV_FILE"
    print_error "Run: ./phase1-prerequisites/01-setup-prerequisites.sh"
    exit 1
fi

print_info "Loading environment from: $ENV_FILE"
source "$ENV_FILE"

# Verify API key is set
if [[ -z "$IBMCLOUD_API_KEY" || "$IBMCLOUD_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
    print_error "IBMCLOUD_API_KEY not set in $ENV_FILE"
    print_error "Edit the file and set your actual API key"
    ((ERRORS++))
else
    print_info "✅ IBM Cloud API key configured"
fi

# Verify all required variables
REQUIRED_VARS=(
    "IBMCLOUD_REGION"
    "IBMCLOUD_ZONE"
    "VPC_ID"
    "VPC_NAME"
    "CN_ID"
    "MGMT_SUBNET_ID"
    "SG_ID"
    "KEY_ID"
    "GPU_PROFILE"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var}" ]]; then
        print_error "Variable $var not set"
        ((ERRORS++))
    else
        print_info "✅ $var = ${!var}"
    fi
done

################################################################################
# Check Tools Installation
################################################################################

print_section "Step 2: Verifying Tool Installation"

# Check each required tool
REQUIRED_TOOLS=(
    "ibmcloud:IBM Cloud CLI"
    "jq:JSON processor"
    "helm:Helm package manager"
    "openshift-install:OpenShift installer"
    "oc:OpenShift CLI"
)

for tool_entry in "${REQUIRED_TOOLS[@]}"; do
    IFS=':' read -r tool desc <<< "$tool_entry"

    if command -v "$tool" &> /dev/null; then
        VERSION=$($tool version 2>&1 | head -1 || echo "unknown")
        print_info "✅ $desc: $VERSION"
    else
        print_error "$desc not found: $tool"
        ((ERRORS++))
    fi
done

# Check IBM Cloud VPC plugin
if ibmcloud plugin list | grep -q vpc-infrastructure; then
    VPC_PLUGIN_VERSION=$(ibmcloud plugin list | grep vpc-infrastructure | awk '{print $2}')
    print_info "✅ IBM Cloud VPC plugin: $VPC_PLUGIN_VERSION"
else
    print_error "IBM Cloud VPC plugin not installed"
    ((ERRORS++))
fi

################################################################################
# Check Credentials
################################################################################

print_section "Step 3: Verifying Credentials"

# Check pull secret
if [[ -f "$PULL_SECRET_PATH" ]]; then
    if jq empty "$PULL_SECRET_PATH" 2>/dev/null; then
        PULL_SECRET_SIZE=$(wc -c < "$PULL_SECRET_PATH" | tr -d ' ')
        print_info "✅ Pull secret valid: $PULL_SECRET_PATH ($PULL_SECRET_SIZE bytes)"
    else
        print_error "Pull secret is not valid JSON: $PULL_SECRET_PATH"
        ((ERRORS++))
    fi
else
    print_error "Pull secret not found: $PULL_SECRET_PATH"
    ((ERRORS++))
fi

# Check SSH key
if [[ -f "$SSH_KEY_PATH" ]]; then
    KEY_TYPE=$(ssh-keygen -lf "$SSH_KEY_PATH" 2>&1 | awk '{print $NF}' || echo "unknown")
    print_info "✅ SSH public key: $SSH_KEY_PATH ($KEY_TYPE)"
else
    print_error "SSH public key not found: $SSH_KEY_PATH"
    ((ERRORS++))
fi

################################################################################
# Check IBM Cloud Access
################################################################################

print_section "Step 4: Verifying IBM Cloud Access"

if [[ $ERRORS -eq 0 ]]; then
    print_info "Logging into IBM Cloud..."

    if ibmcloud login --apikey "$IBMCLOUD_API_KEY" -r "$IBMCLOUD_REGION" -g "$IBMCLOUD_RESOURCE_GROUP" &>/dev/null; then
        print_info "✅ Successfully authenticated to IBM Cloud"

        # Verify target
        TARGET_INFO=$(ibmcloud target)
        echo "$TARGET_INFO"

        # Verify VPC access
        print_info "Verifying VPC access..."
        if ibmcloud is vpc "$VPC_ID" &>/dev/null; then
            VPC_INFO=$(ibmcloud is vpc "$VPC_ID" --output json)
            VPC_STATUS=$(echo "$VPC_INFO" | jq -r '.status')
            print_info "✅ VPC accessible: $VPC_NAME (status: $VPC_STATUS)"
        else
            print_error "Cannot access VPC: $VPC_ID"
            ((ERRORS++))
        fi

        # Verify cluster network access
        print_info "Verifying cluster network access..."
        if ibmcloud is cluster-network "$CN_ID" &>/dev/null; then
            CN_INFO=$(ibmcloud is cluster-network "$CN_ID" --output json)
            CN_STATUS=$(echo "$CN_INFO" | jq -r '.lifecycle_state')
            print_info "✅ Cluster network accessible: $CN_NAME (state: $CN_STATUS)"
        else
            print_error "Cannot access cluster network: $CN_ID"
            ((ERRORS++))
        fi

        # Verify management subnet
        print_info "Verifying management subnet..."
        if ibmcloud is subnet "$MGMT_SUBNET_ID" &>/dev/null; then
            SUBNET_INFO=$(ibmcloud is subnet "$MGMT_SUBNET_ID" --output json)
            SUBNET_NAME=$(echo "$SUBNET_INFO" | jq -r '.name')
            SUBNET_CIDR=$(echo "$SUBNET_INFO" | jq -r '.ipv4_cidr_block')
            print_info "✅ Management subnet accessible: $SUBNET_NAME ($SUBNET_CIDR)"
        else
            print_error "Cannot access management subnet: $MGMT_SUBNET_ID"
            ((ERRORS++))
        fi

        # Verify security group
        print_info "Verifying security group..."
        if ibmcloud is security-group "$SG_ID" &>/dev/null; then
            SG_INFO=$(ibmcloud is security-group "$SG_ID" --output json)
            SG_NAME=$(echo "$SG_INFO" | jq -r '.name')
            print_info "✅ Security group accessible: $SG_NAME"
        else
            print_error "Cannot access security group: $SG_ID"
            ((ERRORS++))
        fi

        # Verify SSH key
        print_info "Verifying SSH key in IBM Cloud..."
        if ibmcloud is key "$KEY_ID" &>/dev/null; then
            KEY_INFO=$(ibmcloud is key "$KEY_ID" --output json)
            KEY_NAME=$(echo "$KEY_INFO" | jq -r '.name')
            print_info "✅ SSH key accessible: $KEY_NAME"
        else
            print_error "Cannot access SSH key: $KEY_ID"
            ((ERRORS++))
        fi

        # Verify cluster network subnets
        print_info "Verifying cluster network subnets..."
        CN_SUBNET_ERRORS=0
        for i in {0..7}; do
            SUBNET_VAR="CN_SUBNET_ID_$i"
            SUBNET_ID="${!SUBNET_VAR}"

            if ibmcloud is cluster-network-subnet "$CN_ID" "$SUBNET_ID" &>/dev/null; then
                print_info "  ✅ Cluster network subnet $i accessible"
            else
                print_error "  ❌ Cannot access cluster network subnet $i: $SUBNET_ID"
                ((CN_SUBNET_ERRORS++))
            fi
        done

        if [[ $CN_SUBNET_ERRORS -eq 0 ]]; then
            print_info "✅ All 8 cluster network subnets accessible"
        else
            print_error "Failed to access $CN_SUBNET_ERRORS cluster network subnets"
            ((ERRORS++))
        fi

    else
        print_error "Failed to authenticate to IBM Cloud"
        print_error "Check your API key in $ENV_FILE"
        ((ERRORS++))
    fi
else
    print_warn "Skipping IBM Cloud access check due to previous errors"
fi

################################################################################
# Check Available Resources
################################################################################

print_section "Step 5: Checking Available Resources"

if [[ $ERRORS -eq 0 ]]; then
    # Check H100 profile availability
    print_info "Checking H100 instance profile availability..."
    if ibmcloud is instance-profiles --output json | jq -e ".[] | select(.name == \"$GPU_PROFILE\")" &>/dev/null; then
        print_info "✅ H100 profile available: $GPU_PROFILE"

        # Show profile details
        PROFILE_INFO=$(ibmcloud is instance-profile "$GPU_PROFILE" --output json)
        VCPU=$(echo "$PROFILE_INFO" | jq -r '.vcpu_count.value')
        MEMORY=$(echo "$PROFILE_INFO" | jq -r '.memory.value')
        GPU_COUNT=$(echo "$PROFILE_INFO" | jq -r '.gpu_count.value // "N/A"')

        print_info "  Profile specs: ${VCPU} vCPU, ${MEMORY} GB RAM, ${GPU_COUNT} GPUs"
    else
        print_error "H100 profile not available: $GPU_PROFILE"
        print_error "Check profile availability in region $IBMCLOUD_REGION zone $IBMCLOUD_ZONE"
        ((ERRORS++))
    fi

    # Check for available images
    print_info "Checking for RHCOS images..."
    RHCOS_IMAGES=$(ibmcloud is images --output json | jq -r '.[] | select(.name | contains("rhcos")) | .name' | head -3)
    if [[ -n "$RHCOS_IMAGES" ]]; then
        print_info "✅ RHCOS images available:"
        echo "$RHCOS_IMAGES" | while read -r img; do
            echo "     - $img"
        done
    else
        print_warn "No RHCOS images found - OpenShift installer will import one"
    fi
fi

################################################################################
# Summary
################################################################################

print_section "Environment Verification Summary"

if [[ $ERRORS -eq 0 ]]; then
    print_info "✅ All checks passed!"
    print_info ""
    print_info "Your environment is ready for OpenShift deployment."
    print_info ""
    print_info "Next steps:"
    echo "   1. Review deployment plan: cat deployment-scripts/README.md"
    echo "   2. Generate install config: ./phase2-ipi-control-plane/01-generate-install-config.sh"
    echo "   3. Deploy control plane: ./phase2-ipi-control-plane/02-deploy-cluster.sh"
    print_info ""
    print_warn "⚠️  REMINDER: OpenShift IPI on IBM Cloud VPC is a Technology Preview"
    print_warn "    Not supported for production use with Red Hat SLAs"

    exit 0
else
    print_error "❌ Verification failed with $ERRORS error(s)"
    print_error ""
    print_error "Please fix the errors above before proceeding."
    print_error "For help, see: deployment-scripts/docs/TROUBLESHOOTING.md"

    exit 1
fi
