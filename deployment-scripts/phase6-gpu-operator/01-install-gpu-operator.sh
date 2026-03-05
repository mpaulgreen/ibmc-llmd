#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Installing NVIDIA GPU Operator..."
oc create namespace nvidia-gpu-operator --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator-group
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
  - nvidia-gpu-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v24.9
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

print_info "Waiting for GPU Operator (may take 5-10 minutes)..."
timeout 600 bash -c 'until oc get csv -n nvidia-gpu-operator 2>/dev/null | grep -q Succeeded; do echo -n "."; sleep 10; done' || true
echo ""

print_info "✅ GPU Operator installed"
print_warn "⏭️  Next: ./phase6-gpu-operator/02-create-cluster-policy.sh"
