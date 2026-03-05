#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Installing SR-IOV Network Operator..."
oc create namespace openshift-sriov-network-operator --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

print_info "Waiting for SR-IOV operator..."
timeout 300 bash -c 'until oc get csv -n openshift-sriov-network-operator 2>/dev/null | grep -q Succeeded; do echo -n "."; sleep 5; done' || true
echo ""

print_info "✅ SR-IOV Network Operator installed"
print_info "⏭️  Next: ./phase5-rdma-operators/04-install-nvidia-network-operator.sh"
