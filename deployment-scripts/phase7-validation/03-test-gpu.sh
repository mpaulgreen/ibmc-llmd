#!/bin/bash
set -e; set -u
GREEN='\033[0;32m'; NC='\033[0m'
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }

ENV_FILE="$HOME/.ibmcloud-h100-env"
source "$ENV_FILE"; export KUBECONFIG

print_info "=== GPU Functionality Test ==="

print_info "Deploying GPU test pod..."
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-test
  namespace: default
spec:
  nodeSelector:
    node-role.kubernetes.io/gpu: "true"
  containers:
  - name: gpu-test
    image: nvidia/cuda:12.4.0-base-ubi9
    command:
    - nvidia-smi
    resources:
      limits:
        nvidia.com/gpu: 1
  restartPolicy: Never
EOF

print_info "Waiting for pod to complete..."
sleep 10

print_info "GPU test output:"
oc logs gpu-test || oc describe pod gpu-test

oc delete pod gpu-test || true

print_info "✅ GPU test complete"
print_info "⏭️  Optional NCCL test: ./phase7-validation/04-test-nccl-optional.sh"
