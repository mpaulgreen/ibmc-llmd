#!/bin/bash
################################################################################
# Phase 5: Install Node Feature Discovery (NFD) Operator
# Purpose: Detect and label hardware features on nodes
# Time: ~5 minutes
################################################################################

set -e
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo ""; echo "=========================================="; echo "$1"; echo "=========================================="; echo ""; }

################################################################################
# Load Environment
################################################################################

print_section "Installing Node Feature Discovery Operator"

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"
export KUBECONFIG

print_info "Creating openshift-nfd namespace..."
oc create namespace openshift-nfd --dry-run=client -o yaml | oc apply -f -

print_info "Installing NFD Operator..."
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  installPlanApproval: Automatic
EOF

print_info "Waiting for NFD operator to be ready (max 5 minutes)..."
timeout 300 bash -c 'until oc get csv -n openshift-nfd 2>/dev/null | grep -q Succeeded; do echo -n "."; sleep 5; done' || true
echo ""

if oc get csv -n openshift-nfd 2>/dev/null | grep -q Succeeded; then
    print_info "✅ NFD Operator installed successfully"
else
    print_warn "NFD Operator may still be installing. Check: oc get csv -n openshift-nfd"
fi

print_info "Creating NFD instance..."
cat <<EOF | oc apply -f -
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery:v4.20
    servicePort: 12000
EOF

print_info "Waiting for NFD pods..."
sleep 10
oc wait --for=condition=Ready pod -l app=nfd -n openshift-nfd --timeout=120s || print_warn "NFD pods may still be starting"

print_info "✅ NFD Operator installation complete"
print_warn "⏭️  Next: ./phase5-rdma-operators/02-install-nmstate.sh"
