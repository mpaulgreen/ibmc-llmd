# OpenShift UPI + H100 GPU on IBM Cloud VPC

## Overview

Manual, step-by-step guides for deploying OpenShift 4.19 via UPI (User-Provisioned Infrastructure) on IBM Cloud VPC with H100 GPU worker node, RDMA cluster networks, and AI/ML model serving stack.

Each command is reviewed and executed individually. All infrastructure (VPC, subnets, cluster network) is created from scratch by the guides — no pre-existing resources required except CIS, COS, and SSH key.

## Technology Preview

OpenShift on IBM Cloud VPC is a **Technology Preview** feature — no Red Hat production SLA, may have bugs, not recommended for production.

## Architecture

```
OpenShift 4.19 UPI Cluster
+---------------------------------------------------------------+
|  Control Plane (3 Masters)                                     |
|  +----------+  +----------+  +----------+                     |
|  | Master-0 |  | Master-1 |  | Master-2 |                     |
|  | bx2-8x32 |  | bx2-8x32 |  | bx2-8x32 |                     |
|  +----+-----+  +----+-----+  +----+-----+                     |
|       +------VPC Network (10.240.0.0/24)------+                |
|                                                                |
|  H100 Worker (gx3d-160x1792x8h100)                            |
|  +----------------------------------------------------------+ |
|  | 160 vCPU | 1.75 TiB RAM | 8x H100 80GB HBM3             | |
|  | Cluster Network: 8x ConnectX-7 (400 Gbps each, RoCE v2)  | |
|  +----------------------------------------------------------+ |
|                                                                |
|  H200 Worker (gx3d-160x1792x8h200)                             |
|  +----------------------------------------------------------+ |
|  | 160 vCPU | 1.75 TiB RAM | 8x H200 141GB HBM3e           | |
|  | Cluster Network: 8x ConnectX-7 (400 Gbps each, RoCE v2)  | |
|  +----------------------------------------------------------+ |
+---------------------------------------------------------------+
```

## Deployment Phases

| Phase | Guide | Duration | Description |
|-------|-------|----------|-------------|
| **1** | [PHASE1-PREREQUISITES.md](PHASE1-PREREQUISITES.md) | 30 min | Install tools, configure environment |
| **2** | [PHASE2-UPI-CONTROL-PLANE.md](PHASE2-UPI-CONTROL-PLANE.md) | 90-120 min | Create VPC, deploy OpenShift UPI (3 masters) |
| **3** | [PHASE3-H100-PROVISIONING.md](PHASE3-H100-PROVISIONING.md) | 30-45 min | Create cluster network, provision H100 |
| **3B** | [PHASE3B-H200-PROVISIONING.md](PHASE3B-H200-PROVISIONING.md) | 20-30 min | Provision H200 worker (reuse cluster network) |
| **4** | [PHASE4-WORKER-INTEGRATION.md](PHASE4-WORKER-INTEGRATION.md) | 10-15 min | Join H100 to cluster via CSR approval |
| **4B** | [PHASE4B-H200-WORKER-INTEGRATION.md](PHASE4B-H200-WORKER-INTEGRATION.md) | 10-15 min | Join H200 to cluster via CSR approval |
| **5** | [PHASE5-OPERATORS.md](PHASE5-OPERATORS.md) | 45-60 min | GPU, RDMA, AI platform operators + model serving |
| **6** | [PHASE6-INFERENCE-SCHEDULING.md](PHASE6-INFERENCE-SCHEDULING.md) | 30-45 min | LLMInferenceService — intelligent inference scheduling |
| **7** | [PHASE7-TIERED-PREFIX-CACHE.md](PHASE7-TIERED-PREFIX-CACHE.md) | 15-20 min | CPU prefix cache offloading (add-on to Phase 6) |
| **8** | [PHASE8-PD-DISAGGREGATION.md](PHASE8-PD-DISAGGREGATION.md) | 30-45 min | Prefill/decode disaggregation (H200 prefill, H100 decode) |

**Total Time**: 4.5-6 hours

## Phase 5 Operator Stack

Phase 5 installs 8+ operators in 4 parts:

| Part | Operators | Purpose |
|------|-----------|---------|
| **A: GPU Stack** | NFD, NVIDIA GPU Operator | GPU discovery + `nvidia.com/gpu: 8` |
| **B: RDMA** (optional) | NVIDIA Network Operator | RDMA shared device plugin + `rdma/rdma_mlx5: 1k` |
| **C: AI Platform** | cert-manager, RHCL, LWS, RHOAI | Model serving prerequisites |
| **D: Model Serving** | DataScienceCluster + KServe | Inference endpoint platform |

## Prerequisites

### Pre-Existing IBM Cloud Resources
- **CIS instance**: `ocp-cis` with domain `ibmc.kni.syseng.devcluster.openshift.com`
- **COS instance**: `ocp-cos` (standard)
- **SSH Key**: `r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8`
- **IBM Cloud API Key**: With VPC permissions

### Required Downloads
- **Red Hat Pull Secret**: https://console.redhat.com/openshift/install/pull-secret
- OpenShift installer and CLI are downloaded automatically in Phase 1

### System Requirements
- macOS with Apple Silicon (arm64)
- IBM Cloud CLI access
- ~20GB disk space

## Key Files

| File | Location | Created By |
|------|----------|------------|
| Environment config | `~/.ibmcloud-h100-env` | Phase 1 |
| Pull secret | `~/.pull-secret.json` | Phase 1 |
| Kubeconfig | `~/ocp-h100-upi-install/auth/kubeconfig` | Phase 2 |
| Admin password | `~/ocp-h100-upi-install/auth/kubeadmin-password` | Phase 2 |

## Cost

- **Control Plane** (3x bx2-8x32): ~$0.50-1.00/hour
- **H100 Worker** (gx3d-160x1792x8h100): ~$30-40/hour
- **H200 Worker** (1x gx3d-160x1792x8h200): ~$30-40/hour
- **Total (all running)**: ~$60-81/hour

Stop GPU workers when not in use. They auto-rejoin the cluster on restart.

## Success Criteria

After all phases (including 3B/4B):

- [ ] 5 nodes Ready (3 masters + 1 H100 + 1 H200 workers)
- [ ] All cluster operators Available=True, Degraded=False
- [ ] `nvidia.com/gpu: 8` allocatable on each GPU worker
- [ ] `rdma/rdma_mlx5: 1k` allocatable on each GPU worker (if Part B installed)
- [ ] `nvidia-smi` shows 8x GPUs on each worker
- [ ] 8 RDMA links ACTIVE/LINK_UP per worker (if Part B installed)
- [ ] All operator CSVs Succeeded
- [ ] DataScienceCluster Ready, GatewayClass Accepted

## Directory Structure

```
manual/
+-- README.md                            # This file
+-- PHASE1-PREREQUISITES.md              # Tools and environment setup
+-- PHASE2-UPI-CONTROL-PLANE.md          # VPC creation + OpenShift UPI deployment
+-- PHASE3-H100-PROVISIONING.md          # Cluster network + H100 instance
+-- PHASE3B-H200-PROVISIONING.md         # H200 instance (reuse cluster network)
+-- PHASE4-WORKER-INTEGRATION.md         # H100 worker join via CSR approval
+-- PHASE4B-H200-WORKER-INTEGRATION.md   # H200 worker join via CSR approval
+-- PHASE5-OPERATORS.md                  # GPU, RDMA, AI platform operators
+-- PHASE6-INFERENCE-SCHEDULING.md       # llm-d intelligent inference scheduling
+-- PHASE7-TIERED-PREFIX-CACHE.md        # CPU prefix cache offloading
+-- PHASE8-PD-DISAGGREGATION.md         # Prefill/decode disaggregation
```

## Getting Started

```bash
cd ~/Documents/knowledgebase/ibmc-ipi-roce/manual
```

Start with **[Phase 1: Prerequisites](PHASE1-PREREQUISITES.md)** and proceed sequentially. Complete each phase fully before moving to the next.

---

**Updated**: 2026-03-10
**OpenShift Version**: 4.19.24
**Deployment Method**: UPI (User-Provisioned Infrastructure)
**Region**: eu-de (Frankfurt), Zone: eu-de-2
**GPU Profiles**: gx3d-160x1792x8h100 (8x H100 80GB), gx3d-160x1792x8h200 (8x H200 141GB)
