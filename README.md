# Multi-Node GPU Inference on OpenShift + IBM Cloud VPC

## Executive Summary

This proof of concept demonstrates **multi-node LLM inference** on OpenShift 4.19 running on IBM Cloud VPC with NVIDIA H100 and H200 GPUs. Over 12 phases executed across several weeks, we deployed a 5-node cluster (3 masters + 2 GPU workers with 16 total GPUs), installed a complete AI/ML operator stack (RHOAI 3.3, NVIDIA GPU + Network Operators), and validated four progressively advanced inference patterns: single-node serving, CPU prefix cache offloading, cross-node prefill/decode disaggregation, and wide expert parallelism with a 236B MoE model distributed across 16 GPUs on 2 nodes. The PoC uncovered critical constraints in IBM Cloud's VF-based RDMA fabric — cross-node RDMA is blocked at the IB verbs level, making TCP the only viable transport for NCCL and UCX — and documented workarounds for vLLM startup timeouts, Kubernetes liveness probe interactions with LWS, and VPC load balancer idle timeouts.

---

## Architecture

```
IBM Cloud VPC (eu-de-2, Frankfurt)
+-----------------------------------------------------------------------------------+
|  VPC: rdma-pvc-eude                                                               |
|  Domain: ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com                |
|                                                                                   |
|  Management Network (10.240.0.0/24) ---- OVN-Kubernetes Pod Network               |
|  +----------+  +----------+  +----------+                                         |
|  | Master-0 |  | Master-1 |  | Master-2 |  Control Plane (bx2-8x32 x3)           |
|  | 8 vCPU   |  | 8 vCPU   |  | 8 vCPU   |  Roles: control-plane,master,worker    |
|  | 32 GB    |  | 32 GB    |  | 32 GB    |  Operators + cluster services           |
|  +----------+  +----------+  +----------+                                         |
|                                                                                   |
|  +----------------------------------+  +----------------------------------+       |
|  | H100 Worker                      |  | H200 Worker                      |       |
|  | gx3d-160x1792x8h100              |  | gx3d-160x1792x8h200              |       |
|  | 160 vCPU, 1.75 TiB RAM           |  | 160 vCPU, 1.75 TiB RAM           |       |
|  | 8x H100 SXM5 (80 GB HBM3 each)  |  | 8x H200 SXM5 (141 GB HBM3e each)|       |
|  | Total GPU mem: 640 GB            |  | Total GPU mem: 1.13 TB            |       |
|  +----------------------------------+  +----------------------------------+       |
|       |  8x ConnectX-7 VFs (101e)        |  8x ConnectX-7 VFs (101e)              |
|       +-- RDMA Cluster Network ----------+                                        |
|           rdma-cluster (hopper-1 profile)                                          |
|           8 subnets, RoCE v2, 400 Gbps/link                                       |
|           3.2 Tbps bisection bandwidth                                             |
+-----------------------------------------------------------------------------------+
```

**Cluster**: OpenShift 4.19.24 via UPI | **Region**: eu-de (Frankfurt), Zone: eu-de-2
**Total GPUs**: 16 (8x H100 80GB + 8x H200 141GB) | **Total GPU Memory**: 1.77 TB

---

## Phase Control Matrix

| Phase | Guide | Duration | Description | Models | GPU Layout | Status |
|-------|-------|----------|-------------|--------|------------|--------|
| **1** | [PHASE1-PREREQUISITES.md](manual/PHASE1-PREREQUISITES.md) | 30 min | Tools, CLI, environment config | -- | -- | Complete |
| **2** | [PHASE2-UPI-CONTROL-PLANE.md](manual/PHASE2-UPI-CONTROL-PLANE.md) | 90-120 min | VPC + OpenShift UPI (3 masters) | -- | -- | Complete |
| **3** | [PHASE3-H100-PROVISIONING.md](manual/PHASE3-H100-PROVISIONING.md) | 30-45 min | Cluster network + H100 instance | -- | -- | Complete |
| **3B** | [PHASE3B-H200-PROVISIONING.md](manual/PHASE3B-H200-PROVISIONING.md) | 20-30 min | H200 instance (reuses cluster network) | -- | -- | Complete |
| **4** | [PHASE4-WORKER-INTEGRATION.md](manual/PHASE4-WORKER-INTEGRATION.md) | 10-15 min | H100 CSR approval + node labels | -- | -- | Complete |
| **4B** | [PHASE4B-H200-WORKER-INTEGRATION.md](manual/PHASE4B-H200-WORKER-INTEGRATION.md) | 10-15 min | H200 CSR approval + node labels | -- | -- | Complete |
| **5** | [PHASE5-OPERATORS.md](manual/PHASE5-OPERATORS.md) | 45-60 min | 11 operators: GPU, RDMA, AI platform, model serving | -- | 16 GPUs exposed | Complete |
| **6** | [PHASE6-INFERENCE-SCHEDULING.md](manual/PHASE6-INFERENCE-SCHEDULING.md) | 30-45 min | Single-node inference + EPP scheduling | Qwen3-32B (65GB) | 8 GPUs, TP=2, 4 replicas | Complete |
| **7** | [PHASE7-TIERED-PREFIX-CACHE.md](manual/PHASE7-TIERED-PREFIX-CACHE.md) | 15-20 min | CPU prefix cache offloading | Qwen3-32B (65GB) | 8 GPUs, TP=2, 4 replicas | Complete |
| **8** | [PHASE8-PD-DISAGGREGATION.md](manual/PHASE8-PD-DISAGGREGATION.md) | 45-60 min | Prefill/decode disaggregation (cross-node) | Qwen3-32B (65GB) | 16 GPUs: H200 prefill, H100 decode | Complete |
| **9** | [PHASE9-WIDE-EP.md](manual/PHASE9-WIDE-EP.md) | 90-120 min | Wide expert parallelism (EP=16, 2 nodes) | DeepSeek-V2 (472GB, 236B) | 16 GPUs, EP=16, TP=1 | Complete |
| **9B** | [PHASE9B-NCCL-ROCE-PROBE.md](manual/PHASE9B-NCCL-ROCE-PROBE.md) | 30-45 min | NCCL RoCE probe (diagnostic) | -- | -- | Complete (FAILED by design) |

**Total Time**: 8-10 hours (sequential execution)

---

## What Was Accomplished

### Infrastructure (Phases 1-4B)

| Accomplishment | Detail |
|---|---|
| OpenShift 4.19 on IBM Cloud VPC | UPI deployment (IPI fails due to CAPI provider bug) |
| 5-node cluster | 3 masters (bx2-8x32) + 2 GPU workers |
| RDMA cluster network | `hopper-1` profile, 8 subnets, RoCE v2, 3.2 Tbps |
| Mixed GPU fleet | 8x H100 80GB + 8x H200 141GB = 16 GPUs, 1.77 TB GPU memory |
| NFS shared storage | VPC File Share (NFSv4.1 RWX) for cross-node model access |

### Operator Stack (Phase 5)

| Operator | Version | Source | Purpose |
|---|---|---|---|
| NFD | 4.19.0 | redhat-operators | GPU + NIC discovery, node labeling |
| NVIDIA Network Operator | 26.1.0 | certified-operators | Containerized MOFED + RDMA shared device plugin |
| NVIDIA GPU Operator | 25.10.1 | certified-operators | GPU driver, device plugin, GFD, nvidia-peermem |
| cert-manager | 1.18.1 | redhat-operators | TLS certificate management |
| RHCL | 1.3.0 | redhat-operators | Authorino, Limitador, DNS (auto-created) |
| LWS | 1.0.0 | redhat-operators | LeaderWorkerSet CRD for multi-node pods |
| RHOAI | 3.3.0 | redhat-operators | KServe, LLMInferenceService, DataScienceCluster |
| Service Mesh 3 | 3.2.2 | (auto via RHOAI) | Gateway API, Istio ingress |

**Installation order matters**: NFD -> Network Operator (MOFED) -> GPU Operator (nvidia-peermem depends on MOFED)

### Inference Capabilities Validated (Phases 6-9)

| Capability | Phase | Model | GPU Layout | Key Metric | Transport |
|---|---|---|---|---|---|
| **Single-node inference** | 6 | Qwen3-32B (65GB) | 8 GPUs, TP=2, 4 replicas | Baseline throughput | N/A (local) |
| **CPU prefix cache** | 7 | Qwen3-32B (65GB) | 8 GPUs, TP=2, 4 replicas | +21% throughput, -26% TTFT | N/A (local) |
| **P/D disaggregation** | 8 | Qwen3-32B (65GB) | 16 GPUs: H200 prefill, H100 decode | KV cache transfer validated | NIXL/UCX over TCP |
| **Wide expert parallelism** | 9 | DeepSeek-V2 (236B, 160 experts) | 16 GPUs, EP=16, TP=1, LWS | 160 experts across 16 GPUs | NCCL over TCP |

### RDMA Probe (Phase 9B)

Phase 9B is a diagnostic phase that definitively confirmed IBM Cloud cluster network VFs **cannot** support cross-node RDMA:

- **Single-node NCCL over IB**: PASSED (local QP creation works)
- **Cross-node NCCL over IB**: FAILED (`ibv_modify_qp` errno 19 ENODEV)
- **Cross-node with GDRDMA disabled**: FAILED (same error)
- **Root cause**: VFs block QP state transitions (INIT -> RTR) for remote endpoints
- **Conclusion**: TCP is the ONLY viable cross-node transport on IBM Cloud VPC GPU instances

---

## Constraints & Limitations Discovered

These are the hard-won learnings from weeks of debugging. They represent the primary value of this PoC for anyone deploying GPU inference on IBM Cloud VPC.

### IBM Cloud VPC Platform

| Constraint | Impact | Workaround |
|---|---|---|
| **IPI deployment fails** | CAPI provider creates instances with `metadata_service.enabled=false`, `user_data=null` | Use UPI (manual instance creation with `--user-data @worker.ign`) |
| **VFs block `ibv_modify_qp`** | No cross-node RDMA (NCCL IB, UCX RC both fail). Device ID `15b3:101e` (VF) not `15b3:2344` (PF) | `NCCL_IB_DISABLE=1` (TCP sockets). `UCX_TLS=tcp,...` (no `rc`) |
| **VPC LB 50s idle timeout** | Non-streaming inference responses with >30 tokens get dropped | Use `"stream": true` for longer responses |
| **NFS cold load performance** | ~143s/shard for large models (472GB DeepSeek-V2 = ~130 min load) | Plan for 170 min total startup. No quick iteration. |
| **SR-IOV unsupported on VFs** | SR-IOV operator rejects device ID `101e` | Use NVIDIA Network Operator RDMA shared device plugin instead |
| **Block storage is RWO only** | Cannot share model PVC across nodes | Use VPC File Shares (managed NFS4 RWX) |
| **Quota: vGPU per instance** | 8 vGPUs per instance, need quota increase for multiple GPU instances | Request quota increase before provisioning |
| **`cannot_start_capacity`** | Physical hardware unavailable (not quota) | Retry later or try different zone |

### NVIDIA / vLLM / Kubernetes

| Constraint | Impact | Workaround |
|---|---|---|
| **vLLM hardcoded ZMQ timeout (10 min)** | API server crashes with `TimeoutError` if model loading exceeds 10 min. `VLLM_RPC_TIMEOUT` is dead code. | initContainer patches `core_client.py`: `timeout=600_000` -> `timeout=14400_000` via emptyDir + subPath overlay |
| **LWS worker liveness probe** | Worker pods are headless (no HTTP API on port 8000). Liveness probe kills worker after `initialDelaySeconds`, triggering cascade restart of entire LWS group | Remove liveness probe from worker template entirely |
| **GFD overwrites GPU labels** | Manual `nvidia.com/gpu.product` labels overwritten by GPU Feature Discovery | Use GFD labels: `NVIDIA-H100-80GB-HBM3`, `NVIDIA-H200` |
| **`useHostMofed` must be false** | `true` causes recursive mounts under `/run/nvidia/driver` -> crash loop | `useHostMofed: false` (MOFED is containerized via NicClusterPolicy) |
| **LWS CRD not auto-created** | Installing LWS operator CSV alone does NOT create the LeaderWorkerSet CRD | Must create `LeaderWorkerSetOperator` CR (`name: cluster`, `managementState: Managed`) |
| **Mixed GPU memory** | H100 (80GB) is bottleneck when paired with H200 (141GB) | Set `--gpu-memory-utilization` for the smaller GPU (0.90 x 80GB = 72GB) |
| **EP over TCP: ~1.5s/token** | NCCL all-to-all over TCP adds significant latency vs RDMA | Functional validation only, not production performance |
| **FlashInfer autotuning** | First startup includes ~16 min kernel autotuning after model load | Account for 170 min total (130 load + 22 profiling + 16 autotuning + 2 init) |

### Cross-Node Transport Summary

| Framework | IB Verb Used | Failure Point | Error |
|---|---|---|---|
| NCCL IB | `ibv_modify_qp` | QP INIT -> RTR transition | errno 19 ENODEV |
| UCX RC | Active Messages | Transport initialization | RC transport can't do AM on VFs |
| NCCL TCP | TCP sockets | -- | Works (~40-80 Gbps) |
| UCX TCP | TCP sockets | -- | Works (active messages over TCP) |

**Bottom line**: IBM Cloud would need to expose PFs (`15b3:2344`) instead of VFs (`15b3:101e`) for true RDMA to work.

---

## Technology Stack

| Component | Version | Notes |
|---|---|---|
| OpenShift | 4.19.24 | UPI on IBM Cloud VPC |
| RHCOS | 9.6 | Base OS for all nodes |
| RHOAI | 3.3.0 | Red Hat OpenShift AI |
| vLLM | 0.13.0+rhai11 | RHOAI's vLLM build (`registry.redhat.io/rhaiis/vllm-cuda-rhel9`) |
| NVIDIA GPU Driver | 25.10.x | Via GPU Operator ClusterPolicy |
| MOFED | doca3.3.0-26.01 | Containerized via NicClusterPolicy |
| NCCL | (bundled with vLLM) | TCP sockets only (`NCCL_IB_DISABLE=1`) |
| UCX/NIXL | (bundled with vLLM) | TCP for active messages, cuda_copy for GPU memory |
| KServe | (via RHOAI 3.3) | LLMInferenceService v1alpha1 |
| Service Mesh | 3.2.2 | Istio gateway in `openshift-ingress` |
| Gateway API | v1 | HTTPRoute, GatewayClass, Gateway |

---

## Cost Summary

| Component | Profile | Cost/Hour |
|---|---|---|
| Control plane (3x masters) | bx2-8x32 | ~$0.50-1.00 |
| H100 worker | gx3d-160x1792x8h100 | ~$30-40 |
| H200 worker | gx3d-160x1792x8h200 | ~$30-40 |
| VPC File Share (600GB NFS) | dp2 | ~$0.10 |
| **Total (all running)** | | **~$60-81/hour** |

**Cost management**: Stop GPU instances when not in use (`ibmcloud is instance-stop`). They auto-rejoin the cluster on restart (no CSR approval needed for short stops). Stopped instances still count against vGPU quota.

---

## Quick Reference

| Item | Value |
|---|---|
| **Cluster domain** | `ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com` |
| **API endpoint** | `https://api.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443` |
| **Region / Zone** | eu-de / eu-de-2 |
| **Kubeconfig** | `~/ocp-h100-upi-install/auth/kubeconfig` |
| **Admin password** | `~/ocp-h100-upi-install/auth/kubeadmin-password` |
| **Environment config** | `~/.ibmcloud-h100-env` |
| **Pull secret** | `~/.pull-secret.json` |
| **Phase guides** | `~/Documents/knowledgebase/ibmc-ipi-roce/manual/` |

### Node Inventory

| Node | Role | Profile | GPUs | GPU Memory |
|---|---|---|---|---|
| ocp-master-0 | control-plane,master,worker | bx2-8x32 | -- | -- |
| ocp-master-1 | control-plane,master,worker | bx2-8x32 | -- | -- |
| ocp-master-2 | control-plane,master,worker | bx2-8x32 | -- | -- |
| ocp-gpu-worker-h100 | gpu,worker | gx3d-160x1792x8h100 | 8x H100 80GB | 640 GB |
| ocp-gpu-worker-h200-0 | gpu,worker | gx3d-160x1792x8h200 | 8x H200 141GB | 1.13 TB |

### Pre-Existing IBM Cloud Resources (shared, not created by guides)

| Resource | Name/ID |
|---|---|
| CIS instance | `ocp-cis` (domain: `ibmc.kni.syseng.devcluster.openshift.com`) |
| COS instance | `ocp-cos` (standard) |
| SSH Key | `r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8` |
| Cluster Network | `rdma-cluster` (hopper-1 profile, 8 subnets) |

---

## Getting Started

### Fresh Deployment (from scratch)

Start at **[Phase 1: Prerequisites](manual/PHASE1-PREREQUISITES.md)** and execute sequentially through Phase 5. Then choose which inference phases to run (6-9 are independent capabilities).

### Resuming After GPU Instance Stop/Start

```bash
source ~/.ibmcloud-h100-env
ibmcloud is instance-start $H100_INSTANCE_ID
ibmcloud is instance-start $H200_INSTANCE_ID_0
# Wait 10-15 min for RDMA fabric initialization
# Nodes auto-rejoin (no CSR approval needed)
oc get nodes   # verify all 5 Ready
```

### Re-running an Inference Phase

Phases 6-9 are independent inference deployments. Each creates its own namespace, PVC, and LLMInferenceService. Delete the previous phase's namespace before starting a new one to free GPU resources.

### If H100/H200 Deleted but Cluster Exists

Start at **Phase 3** (skip cluster network creation if it still exists).

### If All Operators Need Reinstalling

Start at **Phase 5**. Follow the exact operator installation order: NFD -> Network Operator -> GPU Operator -> AI platform.

---

## Directory Structure

```
ibmc-ipi-roce/
+-- README.md                                  # This file (control document)
+-- CLAUDE.md                                   # Claude Code context and instructions
+-- manual/
|   +-- README.md                               # Phase guide index (older version)
|   +-- PHASE1-PREREQUISITES.md                 # Tools and environment
|   +-- PHASE2-UPI-CONTROL-PLANE.md             # VPC + OpenShift UPI
|   +-- PHASE3-H100-PROVISIONING.md             # Cluster network + H100
|   +-- PHASE3B-H200-PROVISIONING.md            # H200 (reuses cluster network)
|   +-- PHASE4-WORKER-INTEGRATION.md            # H100 CSR approval + labels
|   +-- PHASE4B-H200-WORKER-INTEGRATION.md      # H200 CSR approval + labels
|   +-- PHASE5-OPERATORS.md                     # 11 operators in 5 parts
|   +-- PHASE6-INFERENCE-SCHEDULING.md          # Single-node Qwen3-32B + EPP
|   +-- PHASE7-TIERED-PREFIX-CACHE.md           # CPU prefix cache offloading
|   +-- PHASE8-PD-DISAGGREGATION.md             # Cross-node P/D with NIXL/UCX
|   +-- PHASE9-WIDE-EP.md                       # Wide EP with DeepSeek-V2
|   +-- PHASE9B-NCCL-ROCE-PROBE.md             # NCCL RoCE diagnostic
+-- deployment-scripts/                         # Older automated scripts (pre-UPI, not validated)
```

---

**Last Updated**: 2026-03-19
**PoC Status**: All 12 phases complete and validated
**OpenShift**: 4.19.24 | **RHOAI**: 3.3.0 | **GPU Operator**: 25.10.1 | **Network Operator**: 26.1.0
