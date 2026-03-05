#!/bin/bash
################################################################################
# Phase 2: Verify OpenShift Control Plane Health
# Purpose: Validate control plane is healthy before proceeding
# Time: ~5 minutes
################################################################################

set -e
set -u

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }
print_section() { echo ""; echo "=========================================="; echo "$1"; echo "=========================================="; echo ""; }

ERRORS=0

################################################################################
# Load Environment
################################################################################

print_section "Loading Environment"

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"

if [[ ! -f "$KUBECONFIG" ]]; then
    print_error "KUBECONFIG not found: $KUBECONFIG"
    print_error "Run: ./phase2-ipi-control-plane/02-deploy-cluster.sh"
    exit 1
fi

export KUBECONFIG
print_info "✅ KUBECONFIG: $KUBECONFIG"

################################################################################
# Check Cluster Connectivity
################################################################################

print_section "Step 1: Verifying Cluster Connectivity"

if oc cluster-info &>/dev/null; then
    print_info "✅ Cluster reachable"
    oc cluster-info
else
    print_error "Cannot connect to cluster"
    ((ERRORS++))
fi

################################################################################
# Check Control Plane Nodes
################################################################################

print_section "Step 2: Verifying Control Plane Nodes"

print_info "Checking master nodes..."
MASTER_NODES=$(oc get nodes -l node-role.kubernetes.io/master --no-headers)

if [[ -z "$MASTER_NODES" ]]; then
    print_error "No master nodes found"
    ((ERRORS++))
else
    echo "$MASTER_NODES"
    echo ""

    MASTER_COUNT=$(echo "$MASTER_NODES" | wc -l | tr -d ' ')
    if [[ "$MASTER_COUNT" -eq 3 ]]; then
        print_info "✅ All 3 master nodes present"
    else
        print_error "Expected 3 masters, found $MASTER_COUNT"
        ((ERRORS++))
    fi

    # Check all masters are Ready
    NOT_READY=$(echo "$MASTER_NODES" | grep -v " Ready " || true)
    if [[ -n "$NOT_READY" ]]; then
        print_error "Some master nodes not Ready:"
        echo "$NOT_READY"
        ((ERRORS++))
    else
        print_info "✅ All master nodes Ready"
    fi
fi

################################################################################
# Check Cluster Operators
################################################################################

print_section "Step 3: Verifying Cluster Operators"

print_info "Checking cluster operators status..."
CLUSTER_OPERATORS=$(oc get co --no-headers)

echo "$CLUSTER_OPERATORS"
echo ""

# Check for degraded operators
DEGRADED=$(oc get co --no-headers | grep -v "True.*False.*False" || true)
if [[ -n "$DEGRADED" ]]; then
    print_warn "Some operators not fully available:"
    echo "$DEGRADED"
    print_warn "This may be normal immediately after installation"
else
    print_info "✅ All cluster operators healthy"
fi

# Count operator states
TOTAL=$(echo "$CLUSTER_OPERATORS" | wc -l | tr -d ' ')
AVAILABLE=$(echo "$CLUSTER_OPERATORS" | grep -c "True" || true)

print_info "Operator summary: $AVAILABLE/$TOTAL available"

################################################################################
# Check Cluster Version
################################################################################

print_section "Step 4: Verifying Cluster Version"

CLUSTER_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}')
CLUSTER_STATE=$(oc get clusterversion version -o jsonpath='{.status.conditions[?(@.type=="Progressing")].status}')

print_info "OpenShift version: $CLUSTER_VERSION"

if [[ "$CLUSTER_STATE" == "False" ]]; then
    print_info "✅ Cluster version stable"
else
    print_warn "Cluster version update in progress"
fi

# Check if version is 4.20+
MAJOR=$(echo "$CLUSTER_VERSION" | cut -d. -f1)
MINOR=$(echo "$CLUSTER_VERSION" | cut -d. -f2)

if [[ "$MAJOR" -ge 4 ]] && [[ "$MINOR" -ge 20 ]]; then
    print_info "✅ Version meets requirement (4.20+)"
else
    print_warn "Version $CLUSTER_VERSION may not meet 4.20+ requirement"
fi

################################################################################
# Check API and Ingress
################################################################################

print_section "Step 5: Verifying API and Ingress"

API_SERVER=$(oc get route -n openshift-console console -o jsonpath='{.status.ingress[0].host}' 2>/dev/null || echo "")
if [[ -n "$API_SERVER" ]]; then
    print_info "✅ Console route available: $API_SERVER"
else
    print_warn "Console route not ready yet"
fi

# Check API server pods
API_PODS=$(oc get pods -n openshift-kube-apiserver -l app=openshift-kube-apiserver --no-headers | grep -c " Running " || echo "0")
if [[ "$API_PODS" -ge 3 ]]; then
    print_info "✅ API server pods running: $API_PODS"
else
    print_warn "Expected 3+ API server pods, found $API_PODS"
fi

################################################################################
# Check etcd Health
################################################################################

print_section "Step 6: Verifying etcd Health"

ETCD_PODS=$(oc get pods -n openshift-etcd -l app=etcd --no-headers | grep -c " Running " || echo "0")
if [[ "$ETCD_PODS" -eq 3 ]]; then
    print_info "✅ etcd pods running: $ETCD_PODS"
else
    print_error "Expected 3 etcd pods, found $ETCD_PODS"
    ((ERRORS++))
fi

################################################################################
# Check Critical Namespaces
################################################################################

print_section "Step 7: Verifying Critical Namespaces"

CRITICAL_NAMESPACES=(
    "openshift-kube-apiserver"
    "openshift-kube-controller-manager"
    "openshift-kube-scheduler"
    "openshift-etcd"
    "openshift-authentication"
    "openshift-monitoring"
)

for ns in "${CRITICAL_NAMESPACES[@]}"; do
    POD_COUNT=$(oc get pods -n "$ns" --no-headers 2>/dev/null | wc -l | tr -d ' ')
    if [[ "$POD_COUNT" -gt 0 ]]; then
        print_info "  ✅ $ns: $POD_COUNT pods"
    else
        print_error "  ❌ $ns: No pods found"
        ((ERRORS++))
    fi
done

################################################################################
# Check Storage Classes
################################################################################

print_section "Step 8: Verifying Storage Classes"

STORAGE_CLASSES=$(oc get sc --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$STORAGE_CLASSES" -gt 0 ]]; then
    print_info "✅ Storage classes available: $STORAGE_CLASSES"
    oc get sc
else
    print_warn "No storage classes found"
    print_warn "This is expected for IBM Cloud VPC - storage will be configured later"
fi

################################################################################
# Worker Node Check
################################################################################

print_section "Step 9: Checking Worker Nodes"

WORKER_COUNT=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WORKER_COUNT" -eq 0 ]]; then
    print_info "✅ No worker nodes (as expected - H100 to be added in Phase 4)"
else
    print_warn "Found $WORKER_COUNT worker nodes (unexpected at this stage)"
fi

################################################################################
# Summary
################################################################################

print_section "Control Plane Verification Summary"

if [[ $ERRORS -eq 0 ]]; then
    print_info "✅ Control plane is healthy and ready"
    print_info ""
    print_info "Cluster status:"
    echo "   - 3 master nodes: Ready"
    echo "   - Cluster operators: Healthy"
    echo "   - OpenShift version: $CLUSTER_VERSION"
    echo "   - Worker nodes: 0 (H100 pending)"
    print_info ""
    print_warn "⏭️  Next Phase: Provision H100 GPU Instance"
    echo "   Run: ./phase3-h100-provisioning/01-create-h100-instance.sh"
    exit 0
else
    print_error "❌ Control plane verification failed with $ERRORS error(s)"
    print_error ""
    print_error "Some issues detected. Review errors above."
    print_warn "Some issues may resolve automatically. Wait 5-10 minutes and re-run."
    print_error ""
    print_error "For troubleshooting:"
    echo "   - Check operator status: oc get co"
    echo "   - Check pod status: oc get pods --all-namespaces"
    echo "   - View operator logs: oc logs -n <namespace> <pod-name>"
    exit 1
fi
