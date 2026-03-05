#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Creating ClusterPolicy for GPU configuration..."

cat <<EOF | oc apply -f -
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
  driver:
    enabled: true
    rdma:
      enabled: true
      useHostMofed: false
  toolkit:
    enabled: true
  devicePlugin:
    enabled: true
  dcgmExporter:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: false
EOF

print_info "✅ ClusterPolicy created"
print_warn "⏳ GPU operator components will deploy (10-20 minutes)"
print_warn "    Monitor with: oc get pods -n nvidia-gpu-operator"
print_warn "⏭️  Next: ./phase6-gpu-operator/03-verify-gpu-resources.sh"
