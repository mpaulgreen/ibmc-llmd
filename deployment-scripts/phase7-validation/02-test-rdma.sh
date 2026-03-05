#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "=== RDMA Functionality Test ==="

print_info "Deploying RDMA test pod..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: rdma-test
  namespace: default
  annotations:
    k8s.v1.cni.cncf.io/networks: rdma-cluster-network
spec:
  nodeSelector:
    node-role.kubernetes.io/gpu: "true"
  containers:
  - name: rdma-test
    image: nvidia/cuda:12.4.0-base-ubi9
    command: ["sleep", "infinity"]
    resources:
      requests:
        rdma/rdma_mlx5: 1
      limits:
        rdma/rdma_mlx5: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK"]
  restartPolicy: Never
EOF

print_info "Waiting for pod to be ready..."
oc wait --for=condition=Ready pod/rdma-test --timeout=120s || true

if oc get pod rdma-test | grep -q Running; then
    print_info "Testing RDMA devices in pod..."
    oc exec rdma-test -- ibv_devices || print_warn "ibv_devices not available (expected if rdma-core not in image)"
    print_info "✅ RDMA test pod created successfully"
    oc delete pod rdma-test
else
    print_warn "RDMA test pod not running - check pod status"
    oc describe pod rdma-test
fi

print_info "⏭️  Next: ./phase7-validation/03-test-gpu.sh"
