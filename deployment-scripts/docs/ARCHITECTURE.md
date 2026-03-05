# Architecture Deep Dive

## Network Architecture

### Dual-Network Design

The H100 deployment uses two completely separate networks:

#### 1. VPC Management Network
- **Purpose**: Standard Kubernetes/OpenShift communication
- **Traffic**:
  - Kubernetes API server communication
  - kubelet heartbeats and node management
  - Pod-to-pod communication (via CNI)
  - Service networking (ClusterIP, NodePort, LoadBalancer)
  - Ingress/egress traffic
  - Monitoring and logging data
- **Bandwidth**: Standard VPC network performance
- **Security**: IBM Cloud Security Groups and Network ACLs

#### 2. Cluster Network (RDMA)
- **Purpose**: High-performance GPU-to-GPU communication
- **Profile**: hopper-1 (optimized for H100)
- **Topology**: 8 subnets, each mapped to one GPU rail
- **NICs**: 8× NVIDIA ConnectX-7 (400 Gbps each)
- **Total Bandwidth**: 3.2 Tbps aggregate
- **Protocol**: RoCE v2 (RDMA over Converged Ethernet)
- **Traffic**:
  - NCCL collective operations
  - GPU Direct RDMA transfers
  - MPI inter-process communication
  - Distributed training data exchange

### Network Isolation Benefits

1. **Performance**: GPU traffic doesn't compete with management traffic
2. **Reliability**: Management network failures don't affect GPU communication
3. **Security**: RDMA network isolated from general cluster traffic
4. **Scalability**: Can scale GPU network independently

## GPU Direct RDMA Architecture

### What is GPU Direct RDMA?

GPU Direct RDMA allows GPUs to communicate directly over the network without CPU involvement:

```
Traditional Path (without GPU Direct):
GPU Memory → CPU Memory → Network Card → Network

GPU Direct Path:
GPU Memory → Network Card → Network
```

### Benefits
- **Lower Latency**: Eliminates CPU copies
- **Higher Bandwidth**: Direct GPU-to-network transfers
- **CPU Offload**: Frees CPU for other work
- **Power Efficiency**: Fewer data movements

### Implementation on H100

Each H100 GPU has a dedicated network path:
- 8 GPUs × 8 ConnectX-7 NICs
- Each GPU paired with one NIC
- Direct PCIe paths for minimal latency
- Hardware-accelerated RDMA operations

## OpenShift Integration

### Machine Management

Standard OpenShift uses MachineSets to manage nodes. Our H100 integration is non-standard because:

1. **Pre-provisioned Instance**: H100 created outside MachineSet
2. **Cluster Networks**: Required stopping instance for attachment
3. **Manual Integration**: CSR approval workflow needed

### Alternative Approaches

**Option 1: MachineSet with Cluster Network**
- Create custom MachineSet
- Use post-provisioning hooks for cluster network attachment
- Requires custom automation

**Option 2: Machine Config Operator**
- Define H100 node configuration as MachineConfig
- Let MCO manage node lifecycle
- Still requires manual cluster network handling

**Option 3: IBM ROKS (Recommended for Production)**
- Use IBM-managed OpenShift (ROKS)
- IBM handles cluster network integration
- Better support for GPU + cluster network scenarios

## Software Stack

### Container Runtime
- **CRI-O**: OpenShift default container runtime
- **GPU Support**: Via NVIDIA Container Toolkit
- **RDMA Support**: Via device plugins

### CNI Plugins
- **Primary CNI**: OpenShift SDN or OVN-Kubernetes
- **Secondary CNI**: SR-IOV CNI for RDMA devices
- **IPAM**: Whereabouts for cluster network IP allocation

### NVIDIA Stack
- **GPU Operator**: Manages GPU software lifecycle
- **Network Operator**: Manages RDMA drivers and plugins
- **Device Plugin**: Exposes GPUs to Kubernetes scheduler
- **DCGM**: GPU monitoring and telemetry

## Scaling Considerations

### Adding More H100 Nodes

To add additional H100 workers:

1. Provision new H100 instance
2. Attach cluster network interfaces (must stop instance)
3. Start instance and wait for RDMA initialization
4. Integrate with OpenShift (CSR approval)
5. Label node appropriately

### Multi-Node RDMA Topology

For multi-node configurations:
- Each node gets 8 cluster network interfaces
- RDMA fabric spans all nodes
- NCCL automatically discovers multi-node topology
- Consider network topology (rack placement, switch layout)

### Performance Optimization

**Single Node (8 GPUs)**:
- NVLink for intra-node GPU communication
- Cluster network for future multi-node expansion
- NCCL bandwidth: ~300-400 GB/s

**Multi-Node**:
- NVLink within each node
- Cluster network between nodes
- NCCL automatically optimizes topology
- Expected inter-node bandwidth: >100 GB/s per GPU pair

## Security Architecture

### Network Isolation
- VPC network secured by Security Groups
- Cluster network isolated network domain
- No cross-network routing by default

### RBAC for GPU Resources
Recommended policies:
```yaml
- GPU quota per namespace
- Role-based access to GPU nodes
- PodSecurityPolicy for GPU workloads
- NetworkPolicy for RDMA traffic
```

### Secrets Management
- Pull secrets for container images
- API credentials in Kubernetes Secrets
- Encryption at rest for etcd

## Monitoring Architecture

### Cluster Monitoring
- Prometheus (OpenShift built-in)
- Grafana dashboards
- AlertManager for notifications

### GPU Monitoring
- NVIDIA DCGM Exporter
- GPU metrics in Prometheus
- Custom Grafana dashboards for GPUs

### RDMA Monitoring
- Mellanox/NVIDIA network metrics
- Bandwidth and packet counters
- Error rate monitoring

### Recommended Metrics
- GPU utilization per device
- GPU memory usage
- GPU temperature
- RDMA bandwidth per interface
- RDMA packet loss/errors
- NCCL operation latency
- Training throughput

## References

- [NVIDIA H100 Architecture](https://resources.nvidia.com/en-us-gpu-resources/h100-datasheet-24306)
- [OpenShift Architecture](https://docs.openshift.com/container-platform/latest/architecture/architecture.html)
- [IBM Cloud VPC Architecture](https://cloud.ibm.com/docs/vpc?topic=vpc-about-networking-for-vpc)
