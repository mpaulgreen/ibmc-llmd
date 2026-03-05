# Post-Deployment Guide

## Immediate Next Steps

After successful deployment, follow these steps to prepare for workloads.

### 1. Deploy AI/ML Workloads

#### PyTorch Distributed Training

Example DDP (Distributed Data Parallel) job:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pytorch-training
spec:
  template:
    metadata:
      annotations:
        k8s.v1.cni.cncf.io/networks: rdma-cluster-network
    spec:
      nodeSelector:
        node-role.kubernetes.io/gpu: "true"
      containers:
      - name: training
        image: nvcr.io/nvidia/pytorch:24.02-py3
        command: ["/bin/bash", "-c"]
        args:
        - |
          export NCCL_DEBUG=INFO
          export NCCL_IB_DISABLE=0
          export NCCL_NET_GDR_LEVEL=5
          python -m torch.distributed.launch \
            --nproc_per_node=8 \
            --use_env \
            train.py
        resources:
          limits:
            nvidia.com/gpu: 8
            rdma/rdma_mlx5: 8
        securityContext:
          capabilities:
            add: ["IPC_LOCK"]
        volumeMounts:
        - name: training-data
          mountPath: /data
      volumes:
      - name: training-data
        persistentVolumeClaim:
          claimName: training-data-pvc
      tolerations:
      - key: nvidia.com/gpu
        operator: Equal
        value: present
        effect: NoSchedule
```

#### TensorFlow Training

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: tensorflow-training
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/gpu: "true"
      containers:
      - name: training
        image: nvcr.io/nvidia/tensorflow:24.02-tf2-py3
        command: ["python", "train.py"]
        env:
        - name: NCCL_DEBUG
          value: "INFO"
        - name: TF_GPU_THREAD_MODE
          value: "gpu_private"
        resources:
          limits:
            nvidia.com/gpu: 8
```

### 2. Configure Storage

#### OpenShift Data Foundation (ODF)

For persistent storage:

```bash
# Install ODF Operator
oc create namespace openshift-storage
# Follow ODF installation guide
```

#### NFS for Shared Datasets

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: training-data-pv
spec:
  capacity:
    storage: 1Ti
  accessModes:
    - ReadWriteMany
  nfs:
    server: <nfs-server-ip>
    path: /data/training
```

#### IBM Cloud Object Storage

For model artifacts and checkpoints:

```bash
# Install rclone or s3fs in container images
# Mount COS buckets in training pods
```

### 3. Set Up Monitoring

#### Install Prometheus Operator (if not using built-in)

```bash
# OpenShift includes Prometheus by default
# Configure GPU metrics collection
```

#### Create GPU Dashboard

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboard-gpu
  namespace: openshift-monitoring
data:
  gpu-dashboard.json: |
    {
      "dashboard": {
        "title": "H100 GPU Metrics",
        "panels": [
          {
            "title": "GPU Utilization",
            "targets": [
              {
                "expr": "DCGM_FI_DEV_GPU_UTIL"
              }
            ]
          }
        ]
      }
    }
```

#### Configure Alerts

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: gpu-alerts
  namespace: nvidia-gpu-operator
spec:
  groups:
  - name: gpu
    rules:
    - alert: GPUHighTemperature
      expr: DCGM_FI_DEV_GPU_TEMP > 85
      for: 5m
      annotations:
        summary: "GPU temperature high"
    - alert: GPUMemoryHigh
      expr: DCGM_FI_DEV_FB_USED / DCGM_FI_DEV_FB_FREE > 0.9
      for: 5m
```

### 4. Resource Management

#### Set GPU Quotas

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: gpu-quota
  namespace: ai-workloads
spec:
  hard:
    requests.nvidia.com/gpu: "8"
    limits.nvidia.com/gpu: "8"
```

#### Set LimitRanges

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: gpu-limits
  namespace: ai-workloads
spec:
  limits:
  - max:
      nvidia.com/gpu: "8"
    min:
      nvidia.com/gpu: "1"
    type: Container
```

### 5. Security Hardening

#### Network Policies

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: gpu-workload-policy
  namespace: ai-workloads
spec:
  podSelector:
    matchLabels:
      gpu: "true"
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ai-workloads
  egress:
  - to:
    - namespaceSelector: {}
```

#### Pod Security Standards

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: ai-workloads
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

## Scaling to Multiple H100 Nodes

### Steps to Add Another H100 Worker

1. Provision new H100 instance
2. Attach cluster network interfaces (requires stopping)
3. Start instance
4. Integrate with OpenShift (CSR approval)
5. Label node appropriately

### Multi-Node Training Configuration

```yaml
# PyTorch DDP across 2 H100 nodes (16 GPUs total)
apiVersion: batch/v1
kind: Job
metadata:
  name: multi-node-training
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/gpu
                operator: Exists
      containers:
      - name: master
        image: nvcr.io/nvidia/pytorch:24.02-py3
        command: ["/bin/bash", "-c"]
        args:
        - |
          export MASTER_ADDR=$(hostname -i)
          export MASTER_PORT=23456
          export WORLD_SIZE=16
          export RANK=0
          python -m torch.distributed.launch \
            --nproc_per_node=8 \
            --nnodes=2 \
            --node_rank=0 \
            train.py
        resources:
          limits:
            nvidia.com/gpu: 8
```

## Performance Optimization

### NCCL Tuning

Environment variables for optimal performance:

```bash
# Basic RDMA configuration
export NCCL_IB_DISABLE=0
export NCCL_NET_GDR_LEVEL=5
export NCCL_IB_HCA=mlx5

# Performance tuning
export NCCL_IB_GID_INDEX=3
export NCCL_IB_TC=106
export NCCL_IB_TIMEOUT=22

# Multi-node
export NCCL_SOCKET_IFNAME=eth0
export NCCL_IB_HCA=mlx5_0,mlx5_1,mlx5_2,mlx5_3,mlx5_4,mlx5_5,mlx5_6,mlx5_7
```

### GPU Optimization

```bash
# Set persistence mode
nvidia-smi -pm 1

# Set application clocks
nvidia-smi -ac 1593,1980

# MIG mode (if needed, not typical for H100 training)
nvidia-smi -mig 1
```

### Container Optimization

```Dockerfile
# Optimized training container
FROM nvcr.io/nvidia/pytorch:24.02-py3

# Install RDMA tools
RUN apt-get update && apt-get install -y \
    rdma-core \
    libibverbs-dev \
    ibverbs-utils \
    perftest

# Install monitoring
RUN pip install py3nvml gpustat

# Optimize for H100
ENV NVIDIA_DRIVER_CAPABILITIES=compute,utility
ENV CUDA_DEVICE_ORDER=PCI_BUS_ID
```

## Cost Optimization

### Automatic Scaling

Consider implementing:
- Time-based scaling (scale down nights/weekends)
- Job-based scaling (scale for specific workloads)
- Cost tracking per namespace/team

### Resource Utilization Monitoring

```bash
# Check GPU utilization
oc exec <pod> -- nvidia-smi dmon -c 1

# Cost analysis
# Track GPU hours per namespace
# Monitor idle time
# Implement chargeback policies
```

## Backup and Disaster Recovery

### Cluster Backup

```bash
# Backup cluster resources
oc adm backup

# Backup etcd
oc get -o yaml all --all-namespaces > cluster-backup.yaml
```

### Training Checkpoints

Implement checkpoint strategies:
- Save checkpoints to object storage
- Use persistent volumes for checkpoint data
- Implement restart-from-checkpoint logic

### Model Registry

Consider deploying:
- MLflow
- DVC (Data Version Control)
- Custom model registry

## Compliance and Governance

### Audit Logging

Enable and monitor:
- API audit logs
- GPU usage logs
- Network access logs

### Access Control

- Implement RBAC for GPU namespaces
- Use separate namespaces per team
- Limit admin access

## References

- [OpenShift Documentation](https://docs.openshift.com)
- [NVIDIA GPU Operator Docs](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/)
- [PyTorch Distributed](https://pytorch.org/tutorials/beginner/dist_overview.html)
- [TensorFlow Distributed](https://www.tensorflow.org/guide/distributed_training)
