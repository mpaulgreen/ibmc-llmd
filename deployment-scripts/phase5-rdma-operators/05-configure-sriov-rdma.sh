#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "Configuring SR-IOV for RDMA devices..."

if [[ -z "${H100_NODE_NAME:-}" ]]; then
    print_warn "H100_NODE_NAME not set, attempting to detect..."
    H100_NODE_NAME=$(oc get nodes -l node-role.kubernetes.io/gpu=true --no-headers | awk '{print $1}' | head -1)
fi

print_info "Creating SriovNetworkNodePolicy for RDMA..."
cat <<EOF | oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: rdma-cluster-network-policy
  namespace: openshift-sriov-network-operator
spec:
  nodeSelector:
    ibm-cloud.kubernetes.io/rdma: "enabled"
  resourceName: rdma_mlx5
  priority: 10
  numVfs: 0
  nicSelector:
    vendor: "15b3"
    deviceID: "2344"
  deviceType: netdevice
  isRdma: true
EOF

print_warn "⏳ Waiting 5 minutes for SR-IOV policy to apply..."
sleep 300

print_info "Creating NetworkAttachmentDefinition..."
cat <<EOF | oc apply -f -
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: rdma-cluster-network
  namespace: default
spec:
  config: '{
    "cniVersion": "0.3.1",
    "type": "sriov",
    "ipam": {
      "type": "whereabouts",
      "range": "10.0.0.0/9"
    }
  }'
EOF

print_info "✅ SR-IOV RDMA configuration complete"
print_info "⏭️  Next: ./phase5-rdma-operators/06-verify-rdma-resources.sh"
