#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Installing NVIDIA Network Operator via Helm..."

if ! command -v helm &>/dev/null; then
    echo "ERROR: Helm not found"
    exit 1
fi

helm repo add nvidia https://helm.ngc.nvidia.com/nvidia || helm repo update nvidia

print_info "Installing operator (this may take 5-10 minutes)..."
helm install --wait --generate-name \
  -n nvidia-network-operator --create-namespace \
  nvidia/network-operator \
  --version=24.10.1

print_info "✅ NVIDIA Network Operator installed"
print_info "⏭️  Next: ./phase5-rdma-operators/05-configure-sriov-rdma.sh"
