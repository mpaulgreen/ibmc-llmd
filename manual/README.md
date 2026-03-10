# OpenShift UPI + H100 GPU on IBM Cloud VPC

## Overview

Manual, step-by-step guides for deploying OpenShift 4.19 via UPI (User-Provisioned Infrastructure) on IBM Cloud VPC with H100 GPU worker node, RDMA cluster networks, and AI/ML model serving stack.

Each command is reviewed and executed individually. All infrastructure (VPC, subnets, cluster network) is created from scratch by the guides — no pre-existing resources required except CIS, COS, and SSH key.

## Technology Preview

OpenShift on IBM Cloud VPC is a **Technology Preview** feature — no Red Hat production SLA, may have bugs, not recommended for production.

## Architecture

```
OpenShift 4.19 UPI Cluster
+-------------------------------------------------------+
|  Control Plane (3 Masters)                             |
|  +----------+  +----------+  +----------+             |
|  | Master-0 |  | Master-1 |  | Master-2 |             |
|  | bx2-8x32 |  | bx2-8x32 |  | bx2-8x32 |             |
|  +----+-----+  +----+-----+  +----+-----+             |
|       +------VPC Network (10.240.0.0/24)------+        |
|                                                        |
|  H100 Worker (gx3d-160x1792x8h100)                    |
|  +--------------------------------------------------+ |
|  | 160 vCPU | 1.75 TiB RAM | 8x H100 80GB HBM3     | |
|  |                                                    | |
|  | VPC Network: Kubernetes API, kubelet, pod CNI      | |
|  | Cluster Network: 8x ConnectX-7 (400 Gbps each)    | |
|  |                  3.2 Tbps total, RoCE v2           | |
|  +--------------------------------------------------+ |
+-------------------------------------------------------+
```

## Deployment Phases

| Phase | Guide | Duration | Description |
|-------|-------|----------|-------------|
| **1** | [PHASE1-PREREQUISITES.md](PHASE1-PREREQUISITES.md) | 30 min | Install tools, configure environment |
| **2** | [PHASE2-UPI-CONTROL-PLANE.md](PHASE2-UPI-CONTROL-PLANE.md) | 90-120 min | Create VPC, deploy OpenShift UPI (3 masters) |
| **3** | [PHASE3-H100-PROVISIONING.md](PHASE3-H100-PROVISIONING.md) | 30-45 min | Create cluster network, provision H100 |
| **4** | [PHASE4-WORKER-INTEGRATION.md](PHASE4-WORKER-INTEGRATION.md) | 10-15 min | Join H100 to cluster via CSR approval |
| **5** | [PHASE5-OPERATORS.md](PHASE5-OPERATORS.md) | 45-60 min | GPU, RDMA, AI platform operators + model serving |
| **6** | [PHASE6-INFERENCE-SCHEDULING.md](PHASE6-INFERENCE-SCHEDULING.md) | 30-45 min | LLMInferenceService — intelligent inference scheduling |
| **7** | [PHASE7-TIERED-PREFIX-CACHE.md](PHASE7-TIERED-PREFIX-CACHE.md) | 15-20 min | CPU prefix cache offloading (add-on to Phase 6) |

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
- **Total**: ~$30-41/hour

Stop the H100 when not in use (`ibmcloud is instance-stop $H100_INSTANCE_ID --force`). It auto-rejoins the cluster on restart.

## Success Criteria

After all 5 phases:

- [ ] 4 nodes Ready (3 masters + 1 H100 worker)
- [ ] All cluster operators Available=True, Degraded=False
- [ ] `nvidia.com/gpu: 8` allocatable on H100
- [ ] `rdma/rdma_mlx5: 1k` allocatable on H100 (if Part B installed)
- [ ] `nvidia-smi` shows 8x H100 80GB HBM3
- [ ] 8 RDMA links ACTIVE/LINK_UP (if Part B installed)
- [ ] All operator CSVs Succeeded
- [ ] DataScienceCluster Ready, GatewayClass Accepted

## Directory Structure

```
manual/
+-- README.md                       # This file
+-- PHASE1-PREREQUISITES.md         # Tools and environment setup
+-- PHASE2-UPI-CONTROL-PLANE.md     # VPC creation + OpenShift UPI deployment
+-- PHASE3-H100-PROVISIONING.md     # Cluster network + H100 instance
+-- PHASE4-WORKER-INTEGRATION.md    # Worker node join via CSR approval
+-- PHASE5-OPERATORS.md             # GPU, RDMA, AI platform operators
+-- PHASE6-INFERENCE-SCHEDULING.md  # llm-d intelligent inference scheduling
+-- PHASE7-TIERED-PREFIX-CACHE.md   # CPU prefix cache offloading
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
**GPU Profile**: gx3d-160x1792x8h100 (8x H100 80GB)
