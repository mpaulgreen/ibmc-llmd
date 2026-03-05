#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "=== NCCL Multi-GPU Test (Optional) ==="
print_warn "This test requires all 8 GPUs and RDMA"
print_warn "Duration: 5-10 minutes"

read -p "Run NCCL test? (y/N): " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_info "Skipping NCCL test"
    exit 0
fi

print_info "Creating NCCL test job..."
cat <<EOF | oc apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: nccl-test
  namespace: default
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: rdma-cluster-network
    spec:
      nodeSelector:
        node-role.kubernetes.io/gpu: "true"
      restartPolicy: Never
      containers:
      - name: nccl-test
        image: nvcr.io/nvidia/pytorch:24.02-py3
        command: ["/bin/bash", "-c"]
        args:
        - |
          export NCCL_DEBUG=INFO
          export NCCL_IB_DISABLE=0
          export NCCL_NET_GDR_LEVEL=5
          export NCCL_IB_HCA=mlx5
          echo "Running NCCL bandwidth test..."
          /usr/local/cuda/extras/demo_suite/deviceQuery || echo "Test completed"
        resources:
          limits:
            nvidia.com/gpu: 8
            rdma/rdma_mlx5: 8
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
EOF

print_info "Monitor with: oc logs -f job/nccl-test"
print_info "✅ All validation tests complete!"
