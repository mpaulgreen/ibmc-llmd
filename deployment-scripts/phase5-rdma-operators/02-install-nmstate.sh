#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Installing NMState Operator..."
oc create namespace openshift-nmstate --dry-run=client -o yaml | oc apply -f -

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kubernetes-nmstate-operator
  namespace: openshift-nmstate
spec:
  channel: stable
  name: kubernetes-nmstate-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

print_info "Waiting for NMState operator..."
timeout 300 bash -c 'until oc get csv -n openshift-nmstate 2>/dev/null | grep -q Succeeded; do echo -n "."; sleep 5; done' || true
echo ""

print_info "Creating NMState instance..."
cat <<EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
  namespace: openshift-nmstate
spec: {}
EOF

sleep 10
print_info "✅ NMState Operator installed"
print_info "⏭️  Next: ./phase5-rdma-operators/03-install-sriov.sh"
