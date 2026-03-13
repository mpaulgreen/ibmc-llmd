# Claude Context: OpenShift UPI + H100 GPU on IBM Cloud VPC

## Project Status: FULLY DEPLOYED AND OPERATIONAL (2026-03-10)

- OpenShift 4.19.24 UPI cluster running on IBM Cloud VPC (eu-de-2)
- 4 nodes: 3 masters (bx2-8x32) + 1 H100 worker (gx3d-160x1792x8h100)
- 8x H100 80GB HBM3 GPUs operational (`nvidia.com/gpu: 8`)
- 8x RDMA links active (`rdma/rdma_mlx5: 1k`)
- 11 operators installed and Succeeded
- KServe model serving stack ready (DataScienceCluster Ready)
- Cost: ~$30-41/hour while H100 running

## What Was Accomplished

### Phase 1: Prerequisites
- Installed IBM Cloud CLI, oc 4.19.24, openshift-install 4.19.24, jq, helm, podman, AWS CLI
- Configured `~/.ibmcloud-h100-env` (all IDs populated dynamically by subsequent phases)
- Pre-existing resources: CIS (`ocp-cis`), COS (`ocp-cos`), SSH key (`r010-3f6ad86f...`)

### Phase 2: UPI Control Plane
- Created VPC (`rdma-pvc-eude`) from scratch with subnet, public gateway, security group
- Deployed OpenShift 4.19.24 via UPI (NOT IPI — IPI failed due to CAPI provider bugs)
- 3 masters with `control-plane,master,worker` roles
- DNS via CIS + Route 53 forwarder, CCM auto-creates load balancers

### Phase 3: H100 Provisioning
- Created cluster network (`rdma-cluster`, `hopper-1` profile) with 8 subnets
- Provisioned H100 with RHCOS + worker ignition (`--user-data @worker.ign`)
- Stopped instance, attached 8 cluster network interfaces, restarted
- RDMA fabric initialization: 10-15 minutes on start
- Cluster network interfaces survive instance deletion (reusable)

### Phase 4: Worker Integration
- Approved bootstrap + serving CSRs for H100 to join cluster
- Applied labels: `node-role.kubernetes.io/gpu=true`, NVIDIA, RDMA, workload labels
- Node: `ocp-gpu-worker-h100` (160 vCPU, 1.75 TiB RAM)

### Phase 5: Operators (11 operators, 4 parts)
- **Part A — GPU Stack**: NFD (auto-discovers GPUs + Mellanox NICs) + NVIDIA GPU Operator (ClusterPolicy, 8 GPUs)
- **Part B — RDMA**: NVIDIA Network Operator + NicClusterPolicy (RDMA shared device plugin, 1k contexts)
- **Part C — AI Platform**: cert-manager, RHCL, LWS, RHOAI 3.3.0 + Service Mesh 3.2.2
- **Part D — Model Serving**: DataScienceCluster (KServe managed), GatewayClass, Istio gateway

## Critical Technical Details (Learned During Deployment)

### IPI vs UPI
- IPI on IBM Cloud VPC failed (7 attempts) — CAPI provider creates instances with `metadata_service.enabled=false`, `user_data=null`
- UPI works reliably with manual instance creation + worker ignition

### NFD Configuration
- `deviceClassWhitelist`: Must include `0200` (Ethernet) + `0300` + `0302` (GPU)
- `deviceLabelFields`: Must be `[vendor]` only — GPU Operator needs `pci-10de.present`
- Restart workers after config changes: `oc delete pods -n openshift-nfd -l app=nfd-worker`

### GPU Operator (ClusterPolicy)
- v25.10 CRD requires `daemonsets`, `dcgm`, `gfd` fields
- `driver.rdma.enabled: true, useHostMofed: false` — GPUDirect RDMA via containerized MOFED
- **CRITICAL**: `useHostMofed` MUST be `false` (containerized MOFED via NicClusterPolicy), NOT `true` (host MOFED)
- `useHostMofed: true` with containerized MOFED causes recursive mounts → crash loop
- `nvidia-smi` only inside driver container (`-c nvidia-driver-ctr`), NOT via `oc debug node`
- Stable pod label: `app.kubernetes.io/component=nvidia-driver`

### IBM Cloud RDMA — SR-IOV Does NOT Work
- Cluster network NICs are VFs (`15b3:101e`), NOT PFs (`15b3:2344`)
- SR-IOV operator rejects device ID `101e` (not in supported list)
- Use NVIDIA Network Operator **RDMA shared device plugin** via `NicClusterPolicy` instead
- `NicClusterPolicy` includes `ofedDriver` (containerized MOFED) + `rdmaSharedDevicePlugin`
- `NicClusterPolicy` image repo: `nvcr.io/nvidia/mellanox` (not `cloud-native`), version field required
- `UNLOAD_STORAGE_MODULES=true` in ofedDriver env — required when NFS is in use

### NVIDIA Network Operator
- Install via **OLM** (`certified-operators`, package `nvidia-network-operator`), NOT Helm
- Helm `upgrade-crd` job conflicts with OpenShift NFD CRDs (scope mismatch)

### Service Mesh 3
- Runs in `openshift-ingress` (NOT `istio-system`)
- Chain upgrade can get stuck — delete intermediate CSV to unblock

### OLM Package Names
- RHCL: `rhcl-operator` (NOT `connectivity-link-operator`)
- LWS: `leader-worker-set` (NOT `lws-operator`)
- GPU: `gpu-operator-certified`, Network: `nvidia-network-operator`
- NFD: `nfd`, RHOAI: `rhods-operator`, cert-manager: `openshift-cert-manager-operator`

### LWS Operator — Meta-Operator Pattern
- Installing the CSV alone does NOT create the `LeaderWorkerSet` CRD
- Must create `LeaderWorkerSetOperator` CR (`operator.openshift.io/v1`, name: `cluster`, managementState: `Managed`)
- Without this, LLMInferenceService fails: `no matches for kind "LeaderWorkerSet" in version "leaderworkerset.x-k8s.io/v1"`

### LLMInferenceService (Phase 6)
- CRD: `serving.kserve.io/v1alpha1`, provided by RHOAI 3.3
- Do NOT specify custom `image:` — controller uses RHOAI's `registry.redhat.io/rhaiis/vllm-cuda-rhel9`
- Do NOT specify `args:` — controller generates a bash startup script; custom args overwrite it
- Use `VLLM_ADDITIONAL_ARGS` env var for extra vLLM flags (TP, gpu-memory-utilization, etc.)
- `parallelism.tensor` is metadata only — does NOT inject `--tensor-parallel-size`
- Controller auto-creates: Deployment, InferencePool, EPP scheduler, HTTPRoute, TLS certs
- Controller mounts PVC from `pvc://` URI at `/mnt/models` with correct subPath
- `router.gateway: {}` references default Gateway `openshift-ai-inference` in `openshift-ingress` (must be created manually)
- RHOAI's `data-science-gateway` restricts `allowedRoutes` via `GatewayConfig` controller — do NOT use it
- Create `openshift-ai-inference` Gateway with `allowedRoutes.namespaces.from: All`, HTTP port 80

## Architecture

- **Control Plane**: 3x bx2-8x32 (8 vCPU, 32GB each)
- **Worker**: 1x gx3d-160x1792x8h100 (160 vCPU, 1.75 TiB RAM, 8x H100 80GB)
- **VPC Network**: Kubernetes API, kubelet, pod CNI (OVN-Kubernetes)
- **Cluster Network**: 8x ConnectX-7 VFs (400 Gbps each, 3.2 Tbps total, RoCE v2)
- **Region**: eu-de, Zone: eu-de-2
- **Domain**: ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com

## Operator Versions (validated 2026-03-10)

| Operator | Version | Package | Source |
|---|---|---|---|
| NFD | 4.19.0 | nfd | redhat-operators |
| GPU Operator | 25.10.1 | gpu-operator-certified | certified-operators |
| Network Operator | 26.1.0 | nvidia-network-operator | certified-operators |
| cert-manager | 1.18.1 | openshift-cert-manager-operator | redhat-operators |
| RHCL | 1.3.0 | rhcl-operator | redhat-operators |
| LWS | 1.0.0 | leader-worker-set | redhat-operators |
| RHOAI | 3.3.0 | rhods-operator | redhat-operators |
| Service Mesh | 3.2.2 | servicemeshoperator3 | (auto via RHOAI) |
| Authorino | 1.3.0 | | (auto via RHCL) |
| Limitador | 1.3.0 | | (auto via RHCL) |
| DNS | 1.3.0 | | (auto via RHCL) |

## File Locations

| File | Path |
|---|---|
| Manual guides | `~/Documents/knowledgebase/ibmc-ipi-roce/manual/` |
| Phase guides | `PHASE1-PREREQUISITES.md` through `PHASE5-OPERATORS.md` |
| Env config | `~/.ibmcloud-h100-env` |
| Kubeconfig | `~/ocp-h100-upi-install/auth/kubeconfig` |
| Admin password | `~/ocp-h100-upi-install/auth/kubeadmin-password` |
| Pull secret | `~/.pull-secret.json` |

## Deployment Guides (manual/ directory)

| Phase | File | Duration | Description |
|---|---|---|---|
| 1 | PHASE1-PREREQUISITES.md | 30 min | Tools, environment |
| 2 | PHASE2-UPI-CONTROL-PLANE.md | 90-120 min | VPC + OpenShift UPI |
| 3 | PHASE3-H100-PROVISIONING.md | 30-45 min | Cluster network + H100 |
| 4 | PHASE4-WORKER-INTEGRATION.md | 10-15 min | CSR approval + labels |
| 5 | PHASE5-OPERATORS.md | 45-60 min | GPU, RDMA, AI platform, model serving |
| 6 | PHASE6-INFERENCE-SCHEDULING.md | 30-45 min | LLMInferenceService (vLLM + EPP + Gateway) |
| 7 | PHASE7-TIERED-PREFIX-CACHE.md | 15-20 min | CPU prefix cache offloading (add-on) |

## Infrastructure (Pre-existing, kept across deploys)
- **SSH Key**: r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8
- **CIS**: ocp-cis (domain: ibmc.kni.syseng.devcluster.openshift.com)
- **COS**: ocp-cos (standard)

## Cost
- Control plane: ~$0.50-1.00/hour
- H100 worker: ~$30-40/hour
- Stop H100 when not in use: `ibmcloud is instance-stop $H100_INSTANCE_ID --force`
- H100 auto-rejoins cluster on restart (no CSR approval needed for short stops)

## For Future Claude Sessions
- This is a **documentation + implementation project** — user executes manual guides step-by-step
- All infrastructure is created from scratch by the guides (no hardcoded IDs except SSH key, CIS, COS)
- The `deployment-scripts/` directory contains older automated scripts (pre-UPI) — manual guides in `manual/` are the current, validated path
- User preference: review each command before executing, manual step-by-step
- If deploying from scratch: start Phase 2 (Phase 1 tools already installed)
- If H100 deleted but cluster exists: start Phase 3 (skip Steps 3-4 if cluster network exists)
- If all operators deleted: start Phase 5
