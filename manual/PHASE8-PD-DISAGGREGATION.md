# Phase 8: Prefill/Decode Disaggregation with LLMInferenceService

## Overview

This phase deploys Qwen3-32B with P/D disaggregation using a single `LLMInferenceService` CR — separating inference into prefill workers (prompt processing) on the H200 node and decode workers (token generation) on the H100 node. KV cache is transferred between them via NIXL over RDMA.

**What You'll Accomplish:**
- Create an IBM Cloud VPC File Share (managed NFS4) for RWX model storage
- Deploy a single LLMInferenceService CR with `spec.prefill` for P/D disaggregation
- 4 prefill replicas on H200 + 4 decode replicas on H100 (16 GPUs total)
- P/D-aware EPP scheduler routes prefill/decode requests to correct workers
- Validate KV cache transfer between prefill and decode via NIXL logs

**Model**: Qwen/Qwen3-32B (32B parameters, TP=2 per pod)
**GPU Layout**: 4 prefill x 2 GPUs (H200) + 4 decode x 2 GPUs (H100) = 16 GPUs total
**Estimated Time**: 45-60 minutes (includes file share setup + model download)

## Key Concepts

### Tensor Parallelism (TP)

A 32B parameter model in bfloat16 requires ~65GB of GPU memory just for weights. A single H100 or H200 has 80GB HBM — the model barely fits, leaving almost no room for KV cache (the working memory needed to process requests).

**TP splits the model across multiple GPUs within a single pod:**

```
Pod (TP=2)
├── GPU 0: holds half of each transformer layer's weight matrices (~32.5 GB)
├── GPU 1: holds the other half (~32.5 GB)
└── NVLink: GPUs synchronize intermediate results every layer (~900 GB/s)
```

Each GPU holds ~32.5GB of weights → ~47GB remains free for KV cache. More KV cache means longer sequences and more concurrent requests. NVLink between co-located GPUs is extremely fast (~900 GB/s), so the synchronization overhead of splitting computations is minimal.

| TP Setting | Weights per GPU | Free for KV Cache | Trade-off |
|---|---|---|---|
| TP=1 | ~65 GB | ~15 GB | No sync overhead, but very little KV cache |
| TP=2 | ~32.5 GB | ~47 GB | Minimal sync cost, good KV cache capacity |
| TP=4 | ~16.3 GB | ~64 GB | Higher sync cost, diminishing returns |

TP=2 is the sweet spot for 32B models on 80GB GPUs.

### Prefill vs Decode — Two Phases of LLM Inference

Every LLM inference request goes through two fundamentally different computational phases:

**Prefill (prompt processing)**
- Processes the **entire input prompt** in one forward pass (all tokens in parallel)
- **Compute-bound** — massive matrix multiplications across all prompt tokens
- GPU compute units are fully saturated
- Runs **once** per request; duration scales with prompt length
- Output: KV cache (key-value pairs encoding the prompt's "memory")

**Decode (token generation)**
- Generates output tokens **one at a time**, each requiring a separate forward pass
- **Memory-bandwidth-bound** — reads all model weights (~65GB) but only processes 1 token
- GPU compute units are mostly idle, waiting for memory reads
- Runs **many times** per request (once per output token)
- Input: KV cache from prefill + previously generated tokens

### Why Disaggregate Prefill and Decode?

When prefill and decode share the same GPU, they interfere with each other:

```
Timeline on a shared GPU:
[prefill A ██████████] [decode B ▪] [decode C ▪] [prefill D ██████████] [decode B ▪]
                                                   ↑ decode requests stall while
                                                     prefill monopolizes the GPU
```

- A long prefill (e.g., 8K token prompt) **blocks all decode operations** for seconds
- Decode latency spikes → users see pauses in token streaming (time-to-next-token increases)
- GPUs alternate between compute-bound and memory-bound work — neither is optimized

With disaggregation, each GPU type does what it's best at:

```
H200 (prefill):  [req A ██████] [req D ██████] [req F ██████]
                      ↓ KV cache transfer via NIXL
H100 (decode):   [req B ▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪▪] [req C ▪▪▪▪▪▪▪▪▪▪▪]
                  ↑ never interrupted by prefill
```

| Aspect | Mixed (Phase 6) | Disaggregated (Phase 8) |
|---|---|---|
| Decode latency | Spiky (blocked by prefill) | Consistent (no interference) |
| GPU utilization | Alternates compute/memory-bound | Each GPU optimized for its workload |
| Time-to-first-token (TTFT) | Delayed if decode queue is long | Prefill GPUs always available |
| Scaling | Prefill + decode scale together | Scale independently based on workload |
| Complexity | Simple | KV cache transfer adds overhead |

### The Cost: KV Cache Transfer

The trade-off is that after prefill completes, the KV cache must be **transferred** from the prefill GPU to the decode GPU. This is where NIXL comes in:

```
Prefill GPU (H200)                    Decode GPU (H100)
┌──────────────┐                     ┌──────────────┐
│  KV Cache    │── NIXL/UCX ──────>  │  KV Cache    │
│  (GPU HBM)   │   tcp + cuda_copy   │  (GPU HBM)   │
└──────────────┘                     └──────────────┘
```

- **nvidia-peermem** enables `cuda_copy` UCX transport → GPU memory can be registered with the network stack
- **TCP transport** handles the active message signaling (coordination between pods)
- Transfer goes: GPU HBM → PCIe → Network → PCIe → GPU HBM
- For short prompts, the transfer overhead may exceed the benefit — the `pd-profile-handler` `threshold` parameter controls the minimum prompt length for P/D splitting

---

## Architecture

```
Client Request
      |
      v
[openshift-ai-inference Gateway]   (port 80, openshift-ingress)
      |
      v
[HTTPRoute]                        (auto-created by LLMInferenceService)
      |
      v
[EPP - P/D-aware scheduler]        (auto-created, pd-profile-handler)
  |        Routes based on request phase:
  |        - new requests --> prefill workers
  |        - after KV transfer --> decode workers
  |
  +--- prefill ---> [4x vLLM on H200]  (TP=2, 8 GPUs)
  |                   Process prompt, generate KV cache
  |                   Transfer KV via NIXL --> decode
  |                   Model from NFS (RWX PVC)
  |
  +--- decode ----> [4x vLLM on H100]  (TP=2, 8 GPUs)
                     Receive KV cache via NIXL
                     Generate output tokens
                     Model from NFS (RWX PVC)
```

**Why RWX storage?** LLMInferenceService uses a single `spec.model.uri` for all workloads (prefill + decode). The controller auto-mounts this PVC on every pod. With RWO (block storage), the PVC can only bind to one node — pods on the other node fail. IBM Cloud VPC File Shares provide managed NFS4 with RWX access, allowing both H100 and H200 nodes to mount the same PVC simultaneously.

**Why LLMInferenceService with `spec.prefill`?**

RHOAI 3.3's LLMInferenceService v1alpha1 natively supports P/D disaggregation. The `spec.prefill` field creates a separate prefill deployment with independent replicas, parallelism, node placement, and resources. This is the same pattern used in Red Hat's [DeepSeek-R1 P/D examples](https://github.com/red-hat-data-services/kserve/tree/main/docs/samples/llmisvc/dp-ep/deepseek-r1-gpu-rdma-roce), adapted for Qwen3-32B on H100+H200.

| Aspect | Phase 6 (standard serving) | Phase 8 (P/D disaggregation) |
|---|---|---|
| CR fields | `spec.replicas`, `spec.template` | + `spec.prefill` with separate replicas/template |
| Deployments | 1 (all replicas same role) | 2 (prefill + decode, separate nodes) |
| EPP scheduler | Standard (load-aware + prefix-cache) | P/D-aware (pd-profile-handler + filters) |
| KV cache | Local to each replica | Transferred via NIXL from prefill to decode |
| Node placement | All pods on same node | Prefill on H200, decode on H100 |
| Storage | RWO PVC (single node) | RWX PVC via VPC File Share (both nodes) |

## Pre-Flight Checks

Before starting, ensure Phase 5 is complete:

- [ ] 5 nodes Ready (3 masters + H100 + H200)
- [ ] GPU Operator installed — `nvidia.com/gpu: 8` on both GPU nodes
- [ ] RDMA available — `rdma/rdma_mlx5: 1k` on both GPU nodes
- [ ] DataScienceCluster Ready
- [ ] LLMInferenceService CRD present with `prefill` field
- [ ] KUBECONFIG set and working
- [ ] IBM Cloud CLI logged in

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
```

```bash
oc get nodes --no-headers
```

Should show 5 nodes, all Ready.

```bash
for NODE in ocp-gpu-worker-h100 ocp-gpu-worker-h200-0; do
  echo "=== $NODE ==="
  oc get node $NODE -o jsonpath='  GPU:  {.status.allocatable.nvidia\.com/gpu}{"\n"}  RDMA: {.status.allocatable.rdma/rdma_mlx5}{"\n"}'
done
```

Should show `GPU: 8` and `RDMA: 1k` on each node.

Verify LLMInferenceService CRD has the `prefill` field:

```bash
oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties}' | python3 -c "import sys,json; fields=sorted(json.load(sys.stdin).keys()); print('prefill' in fields and 'SUPPORTED' or 'NOT SUPPORTED'); print('Fields:', fields)"
```

**Expected**: `SUPPORTED` with fields including `prefill`.

### Create Inference Gateway

```bash
oc get gateway openshift-ai-inference -n openshift-ingress --no-headers 2>/dev/null
```

**If the Gateway already exists** (shows `True`), skip to Part A.

**If not found**, create it:

```bash
oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: openshift-ai-inference
  namespace: openshift-ingress
spec:
  gatewayClassName: data-science-gateway-class
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All
EOF
```

Verify:

```bash
oc get gateway openshift-ai-inference -n openshift-ingress --no-headers
```

**Expected**: `openshift-ai-inference` with `True` (Programmed).

---

# Part A: RWX Storage via VPC File Share

---

## Step 1: Create IBM Cloud VPC File Share

IBM Cloud VPC File Shares provide managed NFS4 storage with ReadWriteMany access — no operators or CSI drivers needed. We create a file share, add a mount target to our VPC, and mount it as an NFS PV in OpenShift.

### 1a. Login to IBM Cloud

```bash
source ~/.ibmcloud-h100-env
ibmcloud_login
```

### 1b. Create File Share

```bash
ibmcloud is share-create \
  --name model-share \
  --zone $IBMCLOUD_ZONE \
  --profile dp2 \
  --size 100 \
  --iops 1000 \
  --output json > /tmp/file-share.json
```

### 1c. Get File Share ID and Wait for Available

```bash
export FILE_SHARE_ID=$(jq -r '.id' /tmp/file-share.json)
echo "File Share ID: $FILE_SHARE_ID"

while true; do
  STATUS=$(ibmcloud is share $FILE_SHARE_ID --output json | jq -r '.lifecycle_state')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "stable" ]; then
    echo "File share ready"
    break
  fi
  sleep 10
done
```

---

## Step 2: Create Mount Target

The mount target provides an NFS endpoint within the VPC that the OpenShift nodes can reach.

> **IMPORTANT**: The mount target must be in the **same subnet** as the GPU worker nodes (`$MGMT_SUBNET_ID` — the management subnet). If placed in a different subnet, NFS traffic won't route to the worker nodes.

### 2a. Create Mount Target

```bash
ibmcloud is share-mount-target-create $FILE_SHARE_ID \
  --vpc $VPC_ID \
  --name model-mount \
  --subnet $MGMT_SUBNET_ID \
  --output json > /tmp/mount-target.json
```

### 2b. Wait for Mount Target Ready

```bash
export MOUNT_TARGET_ID=$(jq -r '.id' /tmp/mount-target.json)

while true; do
  STATUS=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.lifecycle_state')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "stable" ]; then
    echo "Mount target ready"
    break
  fi
  sleep 10
done
```

### 2c. Get NFS Endpoint

```bash
export NFS_SERVER=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.mount_path' | cut -d: -f1)
export NFS_PATH=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.mount_path' | cut -d: -f2)
echo "NFS Server: $NFS_SERVER"
echo "NFS Path:   $NFS_PATH"
```

---

## Step 3: Allow NFS Traffic in Security Groups

NFS uses TCP port 2049. You need rules on **two** security groups:

### 3a. Worker Node Security Group (outbound NFS to file share)

The worker nodes need to reach the file share mount target:

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp \
  --port-min 2049 --port-max 2049 \
  --remote 10.240.0.0/16 \
  --output json | jq '{id, direction, protocol, port_min, port_max}'
```

### 3b. File Share Security Group (inbound NFS from workers)

The VPC file share mount target has its own security group. Get it and add an inbound rule:

```bash
# Get the mount target's security group
MOUNT_SG=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.virtual_network_interface.security_groups[0].id // empty')

# If the mount target uses the VPC default SG, get that
if [ -z "$MOUNT_SG" ]; then
  MOUNT_SG=$(ibmcloud is vpc $VPC_ID --output json | jq -r '.default_security_group.id')
  echo "Using VPC default SG: $MOUNT_SG"
fi
echo "Mount target SG: $MOUNT_SG"

# Add inbound NFS rule (if not already the same SG)
if [ "$MOUNT_SG" != "$OCP_SG_ID" ]; then
  ibmcloud is security-group-rule-add $MOUNT_SG inbound tcp \
    --port-min 2049 --port-max 2049 \
    --remote 10.240.0.0/16 \
    --output json | jq '{id, direction, protocol, port_min, port_max}'
  echo "Added NFS rule to mount target SG"
else
  echo "Mount target uses same SG as workers -- rule already added in 3a"
fi
```

> **Why two SGs?** The worker node SG controls traffic to/from the workers. The file share mount target has its own VNI with a separate SG. NFS traffic must be allowed on both sides.

---

## Step 4: Create RWX PV and PVC in OpenShift

### 4a. Create Namespace

```bash
export NAMESPACE=llm-d-pd
oc new-project ${NAMESPACE} 2>/dev/null || oc project ${NAMESPACE}
```

### 4b. Create PersistentVolume (NFS)

> **IMPORTANT**: VPC File Shares only support NFSv4.1. Without `nfsvers=4.1` the mount may fall back to NFSv3 and fail silently. The `sec=sys` option uses standard UNIX authentication. `hard` + `intr` ensures mounts retry on failure and can be interrupted.

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: model-share-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  nfs:
    server: "${NFS_SERVER}"
    path: "${NFS_PATH}"
  mountOptions:
    - nfsvers=4.1
    - sec=sys
    - hard
    - intr
EOF
```

### 4c. Create PersistentVolumeClaim (RWX)

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: model-cache-rwx
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  volumeName: model-share-pv
  resources:
    requests:
      storage: 100Gi
EOF
```

### 4d. Verify PVC is Bound

```bash
oc get pvc model-cache-rwx -n ${NAMESPACE}
```

**Expected**: `Bound` to `model-share-pv`.

---

## Step 5: Create Service Account, Secrets, and SCC

NIXL requires `IPC_LOCK` and `SYS_RAWIO` Linux capabilities for RDMA memory locking — `IPC_LOCK` to pin GPU memory pages so they can't be swapped during a network transfer, and `SYS_RAWIO` for raw device access to the RDMA HCAs. OpenShift's default `restricted-v2` SCC rejects any capability additions. RHOAI provides an SCC (`openshift-ai-llminferenceservice-multi-node-scc`) that allows them, but no service accounts are authorized by default. We create a dedicated SA, grant the SCC, and reference it in the LLMInferenceService CR.

> **RHOAI 3.3 Limitation — Manual SCC Grants Required**
>
> RHOAI ships the `openshift-ai-llminferenceservice-multi-node-scc` SCC with the correct capabilities (`IPC_LOCK`, `SYS_RAWIO`, `NET_BIND_SERVICE`, `NET_RAW`), but does **not** automatically grant it to the service accounts used by LLMInferenceService pods. The administrator must manually run `oc adm policy add-scc-to-user` for each SA — both the custom prefill SA (Step 5b) and the controller-generated decode SA (Step 6b). Furthermore, the decode SA cannot be granted before the LLMInferenceService is created, because the controller creates it with an `ownerReference` — pre-creating the SA manually causes a reconciliation failure. This two-phase SCC grant is a manual operational step that RHOAI could automate in a future release.

### 5a. Create Service Account

```bash
oc create sa llm-d-pd-sa -n ${NAMESPACE}
```

### 5b. Grant Multi-Node SCC to Prefill SA

Grant the SCC to the prefill SA now. The decode SA is handled **after** the LLMInferenceService is created (Step 6b).

```bash
# Grant to our SA (used by prefill pods)
oc adm policy add-scc-to-user openshift-ai-llminferenceservice-multi-node-scc \
  -z llm-d-pd-sa -n ${NAMESPACE}
```

> **Why not grant the decode SA here?** The LLMInferenceService controller auto-creates a SA named `<llmisvc-name>-kserve` (e.g., `qwen3-32b-pd-kserve`) for the decode deployment, with an `ownerReference` pointing back to the LLMInferenceService CR. If you pre-create this SA manually, the controller will **fail** with: `"failed to update v1.ServiceAccount: it is not controlled by v1alpha1.LLMInferenceService"`. The SCC grant to the decode SA must happen after Step 6 creates the LLMInferenceService.

### 5c. Create HuggingFace Token Secret

```bash
export HF_TOKEN=<your-huggingface-token>
```

```bash
oc create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}"
```

### 5d. Download Model

Since the PVC is RWX, we only need ONE download job — it can run on either node:

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: download-model
spec:
  template:
    spec:
      nodeSelector:
        node-role.kubernetes.io/gpu: "true"
      containers:
      - name: download
        image: registry.access.redhat.com/ubi9/python-312
        command:
        - bash
        - -c
        - |
          pip install -q huggingface_hub && \
          python3 -c "
          from huggingface_hub import snapshot_download
          snapshot_download(
            repo_id='Qwen/Qwen3-32B',
            local_dir='/model-cache/hub/Qwen/Qwen3-32B',
            token='${HF_TOKEN}'
          )
          print('Download complete')
          "
        volumeMounts:
        - name: model-storage
          mountPath: /model-cache
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: model-cache-rwx
      restartPolicy: Never
  backoffLimit: 2
EOF
```

### 5e. Wait for Download

> **NFS write throughput**: VPC File Share `dp2` profile delivers ~1-2 GB/s write throughput. The ~65GB Qwen3-32B download will take 30-60 minutes (HuggingFace egress speed is typically the bottleneck, not NFS).

```bash
echo "Waiting for model download (~65GB, 30-60 min on NFS)..."
while true; do
  STATUS=$(oc get job download-model -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
  FAILED=$(oc get job download-model -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
  if [ "$STATUS" = "True" ]; then
    echo ""
    echo "Model download complete."
    break
  fi
  if [ "$FAILED" = "True" ]; then
    echo ""
    echo "Download FAILED. Check logs: oc logs -n ${NAMESPACE} job/download-model"
    break
  fi
  echo -n "."
  sleep 30
done
```

### 5f. Verify Model on PVC

```bash
oc run pvc-check --restart=Never -n ${NAMESPACE} \
  --overrides='{
    "spec":{
      "nodeSelector":{"node-role.kubernetes.io/gpu":"true"},
      "containers":[{
        "name":"check",
        "image":"registry.access.redhat.com/ubi9/ubi-minimal",
        "command":["ls","-la","/model-cache/hub/Qwen/Qwen3-32B/"],
        "volumeMounts":[{"name":"model","mountPath":"/model-cache"}]
      }],
      "volumes":[{
        "name":"model",
        "persistentVolumeClaim":{"claimName":"model-cache-rwx"}
      }]
    }
  }' \
  --image=registry.access.redhat.com/ubi9/ubi-minimal 2>/dev/null
sleep 10
oc logs pvc-check -n ${NAMESPACE}
oc delete pod pvc-check -n ${NAMESPACE}
```

Should show model files (config.json, model weight shards, tokenizer, etc.).

---

# Part B: Deploy P/D Disaggregated Inference

---

## Step 6: Create LLMInferenceService with P/D Disaggregation

This single CR creates the entire P/D stack: separate prefill and decode deployments, NIXL-enabled vLLM servers, P/D-aware EPP scheduler, InferencePool, and HTTPRoute.

> **Key configuration notes:**
> - `serviceAccountName: llm-d-pd-sa` — uses the SA with multi-node SCC (Step 5a-5b). Decode SA SCC is granted in Step 6b after the controller creates it.
> - `securityContext.capabilities.add: [IPC_LOCK, SYS_RAWIO]` — required for NIXL RDMA memory locking
> - `--enforce-eager` in `VLLM_ADDITIONAL_ARGS` — skips CUDA graph compilation, avoids 5-10 min compilation time on startup
> - `livenessProbe.initialDelaySeconds: 2400` (40 min) — NFS model loading is slower than block storage; prevents liveness probe from killing pods during initial load

```bash
oc apply -n ${NAMESPACE} -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen3-32b-pd
  namespace: llm-d-pd
spec:
  model:
    name: Qwen/Qwen3-32B
    uri: "pvc://model-cache-rwx/hub/Qwen/Qwen3-32B"

  # ==========================================
  # DECODE workload (top-level spec = decode)
  # ==========================================
  replicas: 4
  parallelism:
    tensor: 2
  template:
    serviceAccountName: llm-d-pd-sa
    nodeSelector:
      nvidia.com/gpu.product: NVIDIA-H100-80GB-HBM3
    containers:
    - name: main
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
            - SYS_RAWIO
      env:
      - name: KSERVE_INFER_ROCE
        value: "true"
      - name: HF_TOKEN
        valueFrom:
          secretKeyRef:
            name: llm-d-hf-token
            key: HF_TOKEN
      - name: VLLM_ADDITIONAL_ARGS
        value: "--tensor-parallel-size 2 --gpu-memory-utilization 0.95 --max-model-len 32000 --block-size 128 --enforce-eager --disable-uvicorn-access-log --kv-transfer-config '{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}'"
      - name: VLLM_NIXL_SIDE_CHANNEL_HOST
        valueFrom:
          fieldRef:
            fieldPath: status.podIP
      - name: UCX_TLS
        value: "tcp,sm,self,cuda_copy,cuda_ipc"
      - name: UCX_NET_DEVICES
        value: "eth0"
      - name: UCX_PROTO_INFO
        value: "y"
      - name: VLLM_LOGGING_LEVEL
        value: DEBUG
      resources:
        limits:
          nvidia.com/gpu: "2"
          rdma/rdma_mlx5: "1"
          cpu: "16"
          memory: "64Gi"
      volumeMounts:
      - name: shm
        mountPath: /dev/shm
      livenessProbe:
        httpGet:
          path: /health
          port: 8001
          scheme: HTTPS
        initialDelaySeconds: 2400
        periodSeconds: 10
        timeoutSeconds: 10
        failureThreshold: 3
    volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 20Gi

  # ==========================================
  # PREFILL workload
  # ==========================================
  prefill:
    replicas: 4
    parallelism:
      tensor: 2
    template:
      serviceAccountName: llm-d-pd-sa
      nodeSelector:
        nvidia.com/gpu.product: NVIDIA-H200
      containers:
      - name: main
        securityContext:
          capabilities:
            add:
              - IPC_LOCK
              - SYS_RAWIO
        env:
        - name: KSERVE_INFER_ROCE
          value: "true"
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: llm-d-hf-token
              key: HF_TOKEN
        - name: VLLM_ADDITIONAL_ARGS
          value: "--tensor-parallel-size 2 --gpu-memory-utilization 0.95 --max-model-len 32000 --block-size 128 --enforce-eager --disable-uvicorn-access-log --kv-transfer-config '{\"kv_connector\":\"NixlConnector\",\"kv_role\":\"kv_both\"}'"
        - name: VLLM_NIXL_SIDE_CHANNEL_HOST
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: UCX_TLS
          value: "tcp,sm,self,cuda_copy,cuda_ipc"
        - name: UCX_NET_DEVICES
          value: "eth0"
        - name: UCX_PROTO_INFO
          value: "y"
        - name: VLLM_LOGGING_LEVEL
          value: DEBUG
        resources:
          limits:
            nvidia.com/gpu: "2"
            rdma/rdma_mlx5: "1"
            cpu: "16"
            memory: "64Gi"
        volumeMounts:
        - name: shm
          mountPath: /dev/shm
        livenessProbe:
          httpGet:
            path: /health
            port: 8000
            scheme: HTTPS
          initialDelaySeconds: 2400
          periodSeconds: 10
          timeoutSeconds: 10
          failureThreshold: 3
      volumes:
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 20Gi

  # ==========================================
  # ROUTER (P/D-aware EPP scheduler)
  # ==========================================
  router:
    gateway: {}
    route: {}
    scheduler:
      template:
        containers:
        - name: main
          args:
          - "--pool-name"
          - "{{ ChildName .ObjectMeta.Name \`-inference-pool\` }}"
          - "--pool-namespace"
          - "{{ .ObjectMeta.Namespace }}"
          - "--grpc-port"
          - "9002"
          - "--config-text"
          - |2

            apiVersion: inference.networking.x-k8s.io/v1alpha1
            kind: EndpointPickerConfig
            plugins:
            - type: pd-profile-handler
              parameters:
                threshold: 0
            - type: prefill-header-handler
            - type: prefill-filter
            - type: decode-filter
            - type: prefix-cache-scorer
            - type: load-aware-scorer
            - type: max-score-picker
            schedulingProfiles:
            - name: prefill
              plugins:
              - pluginRef: prefill-filter
              - pluginRef: prefix-cache-scorer
                weight: 2.0
              - pluginRef: load-aware-scorer
                weight: 1.0
              - pluginRef: max-score-picker
            - name: decode
              plugins:
              - pluginRef: decode-filter
              - pluginRef: prefix-cache-scorer
                weight: 2.0
              - pluginRef: load-aware-scorer
                weight: 1.0
              - pluginRef: max-score-picker
EOF
```

**What each section does:**

| Section | Purpose |
|---|---|
| `spec.model` | Model name and URI (RWX PVC — mounted on all pods) |
| Top-level `replicas`, `parallelism`, `template` | **Decode** workload: 4 replicas, TP=2, on H100 |
| `spec.prefill` | **Prefill** workload: 4 replicas, TP=2, on H200 |
| `serviceAccountName: llm-d-pd-sa` | SA with multi-node SCC for RDMA capabilities (prefill uses this SA; decode SA granted in Step 6b) |
| `securityContext.capabilities.add` | `IPC_LOCK` + `SYS_RAWIO` for NIXL RDMA memory locking |
| `--enforce-eager` | Skips CUDA graph compilation — faster startup on NFS |
| `livenessProbe.initialDelaySeconds: 2400` | 40 min grace period for NFS model loading |
| `router.scheduler` | P/D-aware EPP with `pd-profile-handler` (threshold=0 = always split P/D) |
| `router.gateway: {}` | Uses default `openshift-ai-inference` Gateway |
| `router.route: {}` | Auto-creates HTTPRoute |

> **Note on RWX PVC**: Both decode and prefill pods mount the same `model-cache-rwx` PVC (NFS4). No `/mnt/models` conflict — the controller auto-mounts it once per pod.

> **Note on `--enforce-eager`**: Skips CUDA graph compilation, reducing startup time by 5-10 minutes. Inference latency is slightly higher without CUDAGraphs but functionally identical. Remove this flag for production deployments where startup time is less critical.

> **Note on `pd-profile-handler` threshold=0**: All requests go through P/D disaggregation (prefill first, then decode). Set threshold > 0 to allow short prompts to bypass prefill and go directly to decode.

---

## Step 6b: Grant Multi-Node SCC to Decode SA

The controller has now auto-created the `qwen3-32b-pd-kserve` SA with proper `ownerReferences`. Grant it the multi-node SCC so decode pods can request `IPC_LOCK` and `SYS_RAWIO` capabilities:

```bash
# Verify the controller created the SA
oc get sa qwen3-32b-pd-kserve -n ${NAMESPACE}
```

**Expected**: The SA exists (created by the controller, not manually).

```bash
# Grant SCC to the auto-generated decode SA
oc adm policy add-scc-to-user openshift-ai-llminferenceservice-multi-node-scc \
  -z qwen3-32b-pd-kserve -n ${NAMESPACE}
```

> **Why here and not in Step 5b?** The controller creates this SA with an `ownerReference` to the LLMInferenceService CR. If you pre-create it manually (before Step 6), the controller cannot take ownership and fails with: `"it is not controlled by v1alpha1.LLMInferenceService"`. The correct sequence is: (1) create LLMInferenceService → (2) controller creates SA → (3) grant SCC to controller-created SA.

> **Two SAs, two grants**: The prefill deployment uses `llm-d-pd-sa` (granted in Step 5b). The decode deployment uses `qwen3-32b-pd-kserve` (granted here). The controller overrides `serviceAccountName` for the decode deployment to its auto-generated SA, ignoring the value in the CR template.

---

## Step 7: Wait for Pods Ready

The controller creates separate deployments for prefill and decode.

> **NFS cold-start latency**: Model weight loading reads all ~65GB sequentially from NFS. This is slower than local block storage — expect 5-10 minutes per pod for initial model load (vs 2-3 minutes on block). Once loaded into GPU HBM, inference performance is identical — NFS is only touched at startup.

```bash
echo "Waiting for LLMInferenceService to become Ready..."
while true; do
  READY=$(oc get llmisvc qwen3-32b-pd -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  REASON=$(oc get llmisvc qwen3-32b-pd -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
  if [ "$READY" = "True" ]; then
    echo ""
    echo "LLMInferenceService is Ready."
    break
  fi
  echo -n "."
  sleep 15
done
```

Verify pod placement:

```bash
oc get pods -n ${NAMESPACE} -o wide --no-headers | grep -v download | grep -v Completed
```

**Expected**:
- Prefill pods on `ocp-gpu-worker-h200-0`
- Decode pods on `ocp-gpu-worker-h100`
- EPP scheduler pod on a master node
- All pods Running

If pods are stuck, check logs:

```bash
# Controller logs
oc logs -n redhat-ods-applications deployment/kserve-controller-manager --tail=30 | grep -i error

# Prefill pod logs
oc logs -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep prefill | head -1 | awk '{print $1}') --tail=30

# Decode pod logs
oc logs -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v epp | grep -v scheduler | grep -v download | grep -v Completed | head -1 | awk '{print $1}') --tail=30
```

---

# Part C: Validate P/D Disaggregation

This validation section is systematic and model-agnostic. Replace model names, namespaces, and LLMInferenceService names as needed for your deployment. The validation proceeds through 6 layers — from infrastructure to end-to-end inference — ensuring each layer works before moving to the next.

> **STOP — You MUST run this block first.** Every command below uses these variables. If you skip this step, commands will silently target wrong resources or hang indefinitely.

```bash
# ============================================================
# REQUIRED: Set these variables before running ANY command below
# Adapt values for your model if not using Qwen3-32B
# ============================================================
export NAMESPACE=llm-d-pd
export LLMISVC_NAME=qwen3-32b-pd
export MODEL_NAME="Qwen/Qwen3-32B"
export GATEWAY_IP=$(oc get svc -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
```

> **Why the LoadBalancer hostname?** The inference gateway service is type `LoadBalancer`. Using the external LB hostname (e.g., `e3ffe0ea-eu-de.lb.appdomain.cloud`) ensures curl works from your local machine. Do NOT use the ClusterIP (`172.30.x.x`) — it's only reachable from inside the cluster and curl will hang.

Verify they are set:

```bash
echo "NAMESPACE:    ${NAMESPACE}"
echo "LLMISVC_NAME: ${LLMISVC_NAME}"
echo "MODEL_NAME:   ${MODEL_NAME}"
echo "GATEWAY_IP:   ${GATEWAY_IP}"
```

**Expected**: All four values populated. `GATEWAY_IP` should be a hostname like `*.lb.appdomain.cloud`, NOT a `172.30.x.x` ClusterIP.

---

## Step 8: Validate Layer 1 — Infrastructure (GPUDirect RDMA)

Before checking application-level behavior, verify the GPU + RDMA infrastructure is healthy.

### 8a. Verify nvidia-peermem Loaded on All GPU Nodes

`nvidia-peermem` is the kernel module that allows GPU memory to be registered with RDMA HCAs. Without it, UCX `cuda_copy` transport fails and NIXL cannot transfer GPU-resident KV cache.

```bash
for NODE in $(oc get nodes -l nvidia.com/gpu.present=true -o name); do
  NODE_NAME=$(echo $NODE | cut -d/ -f2)
  echo "=== $NODE_NAME ==="
  oc debug node/$NODE_NAME -- chroot /host lsmod 2>/dev/null | grep nvidia_peermem
  echo ""
done
```

**Expected** per node:

```
nvidia_peermem         20480  0
```

The module should show connections to both `nvidia` and `ib_uverbs`:

```
nvidia      14413824  199 nvidia_uvm,nvidia_peermem,nvidia_modeset
ib_uverbs    233472    3 nvidia_peermem,rdma_ucm,mlx5_ib
```

**If nvidia_peermem is NOT loaded**: Check the driver pod's `nvidia-peermem-ctr` container logs:

```bash
oc logs -n nvidia-gpu-operator $(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver -o name | head -1) -c nvidia-peermem-ctr --tail=10
```

Common failure: "waiting for mellanox ofed and nvidia drivers to be installed" — means MOFED pods aren't ready. Check `oc get pods -n nvidia-network-operator | grep mofed`.

### 8b. Verify GPU and RDMA Resources Available

```bash
for NODE in $(oc get nodes -l nvidia.com/gpu.present=true -o name); do
  NODE_NAME=$(echo $NODE | cut -d/ -f2)
  echo "=== $NODE_NAME ==="
  oc get node $NODE_NAME -o jsonpath='  GPU:  {.status.allocatable.nvidia\.com/gpu}{"\n"}  RDMA: {.status.allocatable.rdma/rdma_mlx5}{"\n"}'
done
```

**Expected** per node:

```
  GPU:  8
  RDMA: 1k
```

If GPUs show `0`, check ClusterPolicy state: `oc get clusterpolicy -o jsonpath='{.items[0].status.state}'`.
If RDMA shows empty, check NicClusterPolicy: `oc get nicclusterpolicy -o jsonpath='{.items[0].status.state}'`.

### 8c. Verify ClusterPolicy RDMA Configuration

```bash
oc get clusterpolicy -o jsonpath='{.items[0].spec.driver.rdma}'
```

**Expected**: `{"enabled":true,"useHostMofed":false}`

- `enabled: true` → deploys `nvidia-peermem-ctr` in driver pods
- `useHostMofed: false` → coordinates with containerized MOFED from NicClusterPolicy (NOT host-installed)

### 8d. Verify Driver Pods Have 3 Containers

```bash
oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver \
  -o custom-columns='NAME:.metadata.name,READY:.status.containerStatuses[*].ready,CONTAINERS:.spec.containers[*].name'
```

**Expected**: Each driver pod has 3 containers, all ready:

```
NAME                                           READY             CONTAINERS
nvidia-driver-daemonset-...-xxxxx              true,true,true    nvidia-driver-ctr,nvidia-peermem-ctr,openshift-driver-toolkit-ctr
```

If only 2 containers (missing `nvidia-peermem-ctr`), the ClusterPolicy `driver.rdma.enabled` is `false`.

---

## Step 9: Validate Layer 2 — LLMInferenceService Status

### 9a. Check All Status Conditions

```bash
oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o json | \
  python3 -c 'import sys,json
for c in json.load(sys.stdin).get("status",{}).get("conditions",[]):
    print(c["type"] + ": " + c["status"])'
```

**Expected** — all True:

```
HTTPRoutesReady: True
InferencePoolReady: True
MainWorkloadReady: True
PrefillWorkloadReady: True
PresetsCombined: True
Ready: True
RouterReady: True
SchedulerWorkloadReady: True
WorkloadsReady: True
```

**If any condition is False**, check the reason and message:

```bash
oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o json | \
  python3 -c 'import sys,json
conditions = json.load(sys.stdin).get("status",{}).get("conditions",[])
failed = [c for c in conditions if c["status"] not in ("True",)]
for c in failed:
    print(c["type"] + ": " + c.get("message",""))
if not failed:
    print("All conditions True -- no failures.")'
```

Common failures:
- `ReconcileSingleNodeWorkloadError` — SA ownership conflict (see Step 5b)
- `MinimumReplicasUnavailable` — pods still starting or crashing
- `HTTPRoutesNotReady` — Gateway not yet Programmed

### 9b. Verify All Pods Running and Ready

```bash
oc get pods -n ${NAMESPACE} -o wide --no-headers | grep -v Completed | grep -v download
```

**Expected layout**:

| Pod Pattern | Count | Ready | Node |
|---|---|---|---|
| `*-kserve-*` (not prefill, not scheduler) | 4 | 2/2 | Decode GPU node |
| `*-prefill-*` | 4 | 1/1 | Prefill GPU node |
| `*-scheduler-*` | 1 | 1/1 | Any node |

**Check for restarts** — restarts indicate crashes (NIXL failures, OOM, etc.):

```bash
oc get pods -n ${NAMESPACE} -o custom-columns='POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,NODE:.spec.nodeName' --no-headers | grep -v Completed | grep -v download
```

Zero restarts is expected. If any pod has restarts > 0, check its logs for the crash reason.

### 9c. Verify Pod Placement (Correct Nodes)

```bash
echo "Prefill pods (should be on prefill GPU node):"
oc get pods -n ${NAMESPACE} --no-headers -o wide | grep prefill | awk '{printf "  %-55s %s\n", $1, $7}'
echo ""
echo "Decode pods (should be on decode GPU node):"
oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | awk '{printf "  %-55s %s\n", $1, $7}'
```

If pods are on wrong nodes, verify `nodeSelector` labels in the CR match the GFD-assigned GPU labels:

```bash
for NODE in $(oc get nodes -l nvidia.com/gpu.present=true -o name); do
  NODE_NAME=$(echo $NODE | cut -d/ -f2)
  echo "$NODE_NAME: $(oc get node $NODE_NAME -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}')"
done
```

---

## Step 10: Validate Layer 3 — NIXL Backend Initialization

NIXL backend initialization happens **after model loading**. This is the most critical validation — if NIXL fails, KV cache transfer won't work.

### 10a. Verify NIXL is Available (Both Sides)

Check a **decode** pod:

```bash
DECODE_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | head -1 | awk '{print $1}')
echo "Decode pod: $DECODE_POD"
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep -E "NIXL is available|NIXL_ERR|nixlBackendError"
```

Check a **prefill** pod:

```bash
PREFILL_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep prefill | head -1 | awk '{print $1}')
echo "Prefill pod: $PREFILL_POD"
oc logs -n ${NAMESPACE} $PREFILL_POD -c main 2>&1 | grep -E "NIXL is available|NIXL_ERR|nixlBackendError"
```

**Expected** on both:

```
INFO ... NIXL is available
INFO ... Creating v1 connector with name: NixlConnector and engine_id: <uuid>
```

**If you see `NIXL_ERR_BACKEND`**: UCX transport initialization failed. Check the full error:

```bash
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep -B5 "NIXL_ERR_BACKEND" | head -20
```

Common UCX errors and fixes:

| UCX Error | Meaning | Fix |
|---|---|---|
| `no active messages transport` | No transport supports AM (active messages) | Add `tcp` to `UCX_TLS` |
| `cuda_copy/cuda - no am bcopy` | cuda_copy can't do active messages (by design) | Need `tcp` or `rc` alongside cuda_copy |
| `Destination is unreachable` | No viable transport combination | Check `UCX_TLS` includes `tcp,sm,self` |

### 10b. Verify KV Cache Registration on GPU Memory

```bash
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep "Registering KV_Caches"
```

**Expected**:

```
Registering KV_Caches. use_mla: False, kv_buffer_device: cuda, use_host_buffer: False
```

- `kv_buffer_device: cuda` → KV cache is in GPU memory (GPUDirect RDMA path)
- `use_host_buffer: False` → NOT staging through CPU (direct GPU transfer)

If you see `kv_buffer_device: cpu` or `use_host_buffer: True`, the KV cache is being staged through CPU memory — functional but slower. This happens when nvidia-peermem is not loaded.

### 10c. Verify NIXL Block Registration

```bash
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep "Created.*blocks for src engine"
```

**Expected** (2 lines for TP=2):

```
Created 314496 blocks for src engine <engine-uuid> and rank 0 on device id 0
Created 314496 blocks for src engine <engine-uuid> and rank 1 on device id 1
```

The block count depends on available GPU memory after model loading. More blocks = more concurrent KV cache capacity.

### 10d. Verify NIXL Side Channel Listening

```bash
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep "Starting listening on path"
```

**Expected**:

```
Starting listening on path: tcp://<pod-ip>:5600
```

The side channel is how NIXL peers discover each other. Each pod listens on port 5600 at its pod IP.

### 10e. Verify UCX Transport Selection

The UCX protocol info shows which transports were negotiated:

```bash
oc logs -n ${NAMESPACE} $PREFILL_POD -c main 2>&1 | grep "ucp_context_0" | head -10
```

**Expected** (with `UCX_TLS=tcp,sm,self,cuda_copy,cuda_ipc`):

```
| ucp_context_0 intra-node cfg#0 | ... | posix/memory |    ← shared memory for intra-pod
| ucp_context_0 intra-node cfg#1 | ... | cuda_ipc     |    ← GPU-to-GPU within same node
| ucp_context_0 inter-node cfg#2 | ... | tcp/eth0     |    ← TCP for cross-node active messages
```

Key things to verify:
- `cuda_ipc` appears in intra-node config → GPUDirect between GPUs on same node
- `tcp/eth0` appears in inter-node config → TCP for cross-node KV transfer signaling
- No `rc` transport errors (RC doesn't work on IBM Cloud VFs)

---

## Step 11: Validate Layer 4 — Gateway and Routing

### 11a. Verify Gateway Address

`GATEWAY_IP` was set in the required variables block at the top of Part C. Verify it is the **LoadBalancer hostname** (not a ClusterIP):

```bash
echo "GATEWAY_IP: ${GATEWAY_IP}"
```

**Expected**: A hostname like `e3ffe0ea-eu-de.lb.appdomain.cloud`. If empty, go back and run the setup block. If it shows `172.30.x.x`, you used the ClusterIP — re-run:

```bash
export GATEWAY_IP=$(oc get svc -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
```

### 11b. Verify HTTPRoute Path

The controller auto-creates the HTTPRoute. The path may not match what you expect:

```bash
oc get httproute -n ${NAMESPACE} -o custom-columns='NAME:.metadata.name,PATH:.spec.rules[0].matches[0].path.value' --no-headers
```

**Expected**: `/${NAMESPACE}/${LLMISVC_NAME}/v1/completions` (or similar pattern).

Note the path — you'll use it in curl commands below. The chat completions endpoint replaces `/v1/completions` with `/v1/chat/completions`.

### 11c. Verify InferencePool

```bash
oc get inferencepool -n ${NAMESPACE}
```

**Expected**: One pool named `${LLMISVC_NAME}-inference-pool` (or similar) in Ready state.

---

## Step 12: Validate Layer 5 — End-to-End Inference

### 12a. Send a Short Request

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is 2+2? Answer in one word.\"}],
    \"max_tokens\": 10
  }" | python3 -m json.tool
```

**Expected**: HTTP 200 with a JSON response containing `choices[0].message.content`.

**If you get a 404**, the HTTPRoute path doesn't match. Check Step 11b and adjust the curl path.

**If you get a 503**, the EPP scheduler can't reach any backend pods. Check:

```bash
oc logs -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep scheduler | awk '{print $1}') --tail=20
```

### 12b. Send a Longer Request

A longer prompt produces more KV cache, making P/D transfer more visible in logs:

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a helpful AI assistant that explains distributed systems concepts clearly.\"},
      {\"role\": \"user\", \"content\": \"Explain how RDMA (Remote Direct Memory Access) works and why it is important for large language model inference across multiple GPUs. Include details about RoCE v2.\"}
    ],
    \"max_tokens\": 300
  }" | python3 -m json.tool
```

**Expected**: A detailed response. Note the `id` field (e.g., `chatcmpl-1cfd475a-...`) — you'll use it to trace through the P/D pipeline in the next step.

### 12c. Save the Request ID

```bash
export REQUEST_ID=$(curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"Explain tensor parallelism in distributed AI inference.\"}],
    \"max_tokens\": 100
  }" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
echo "Request ID: $REQUEST_ID"
```

---

## Step 13: Validate Layer 6 — P/D Disaggregation (KV Cache Transfer)

This is the most important validation. It confirms that requests actually flow through the P/D pipeline: prefill on one node, KV transfer via NIXL, decode on the other node.

### 13a. Find Which Decode Pod Served the Request

Search all decode pods for the request ID:

```bash
for pod in $(oc get pods -n ${NAMESPACE} --no-headers -o name | grep -v prefill | grep -v scheduler | grep -v download | grep kserve); do
  result=$(oc logs -n ${NAMESPACE} $pod -c main --tail=100 2>&1 | grep "request_finished.*${REQUEST_ID}")
  if [ -n "$result" ]; then
    echo "=== DECODE: $pod ==="
    echo "$result"
    echo ""
  fi
done
```

**Expected output** (single line, wrapped here for readability):

```
=== DECODE: pod/qwen3-32b-pd-kserve-xxxxx ===
(EngineCore_DP0 pid=367) DEBUG 03-13 14:24:56 [distributed/.../v1/nixl_connector.py:725]
  NIXLConnector request_finished(chatcmpl-xxxxx),
  request_status=FINISHED_LENGTH_CAPPED,
  kv_transfer_params={
    'do_remote_decode': False,
    'do_remote_prefill': False,
    'remote_block_ids': [1],
    'remote_engine_id': '<prefill-engine-uuid>',
    'remote_host': '10.x.x.x',
    'remote_port': 5600,
    'remote_request_id': 'chatcmpl-xxxxx',
    'tp_size': 2
  }
```

> **Note**: The actual output is a single long line prefixed with the vLLM log header (`(EngineCore_DP0 pid=...) DEBUG ...`). It is shown wrapped above for readability.

**Key fields to verify in the decode pod's `kv_transfer_params`:**

| Field | Expected Value | Meaning |
|---|---|---|
| `do_remote_decode` | `False` | Decode is complete — no further remote work needed |
| `do_remote_prefill` | `False` | Prefill was already done — no further remote work needed |
| `remote_block_ids` | **Non-empty** list (e.g., `[1]`, `[1, 2, 3]`) | **P/D proof**: KV cache blocks received from prefill |
| `remote_engine_id` | UUID string | **P/D proof**: the prefill engine that sent the KV cache |
| `remote_host` | IP on the **prefill node's** subnet | **P/D proof**: confirms cross-node transfer |
| `remote_port` | `5600` | NIXL side channel port |
| `tp_size` | Matches your TP setting (e.g., `2`) | Tensor parallelism degree |

> **Why are both `do_remote_decode` and `do_remote_prefill` False?** These flags mean "does this request **still need** remote processing?" — they describe what happens **next**, not what already happened. At `request_finished` time on the decode pod, all work is complete: prefill was already done (by a remote prefill pod), decode was just done (by this pod). Both are `False` because there's nothing left to do. The evidence that P/D disaggregation **did occur** is in the `remote_*` fields — `remote_block_ids` being non-empty, `remote_engine_id` being set, and `remote_host` pointing to a prefill pod on the other node.

**If `remote_block_ids` is empty (`[]`)**: KV transfer didn't happen. The request was processed entirely on the decode side (no P/D split). Check:
- EPP scheduler is routing to prefill first (check scheduler logs)
- `pd-profile-handler` threshold may be too high for the prompt length

### 13b. Verify the Prefill Pod Processed the Prompt

The `remote_host` in Step 13a tells you which prefill pod handled the request. Cross-reference:

```bash
oc get pods -n ${NAMESPACE} -o wide --no-headers | grep prefill
```

Match the `remote_host` IP to a prefill pod and set it:

```bash
# Replace with the pod whose IP matches remote_host from Step 13a
export PREFILL_POD=<matched-pod-name>
```

> **Timing matters**: The throughput metric is a rolling average over ~10 second windows. If you check minutes after the request, it will have decayed to `0.0 tokens/s`. Either search the full log history for non-zero entries, or send a fresh request and check immediately.

**Method A** — Search full log history (works anytime):

```bash
oc logs -n ${NAMESPACE} $PREFILL_POD -c main 2>&1 | grep "prompt throughput" | grep -v "0.0 tokens/s" | tail -5
```

**Method B** — Send a request and check within 15 seconds:

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Explain RDMA in detail\"}],\"max_tokens\":50}" > /dev/null && \
sleep 5 && \
for pod in $(oc get pods -n ${NAMESPACE} --no-headers | grep prefill | awk '{print $1}'); do
  result=$(oc logs -n ${NAMESPACE} $pod -c main --since=30s 2>&1 | grep "prompt throughput" | grep -v "0.0 tokens/s")
  if [ -n "$result" ]; then
    echo "=== $pod ==="
    echo "$result"
  fi
done
```

**Expected**: At least one prefill pod shows non-zero prompt throughput:

```
Engine 000: Avg prompt throughput: 6.9 tokens/s, Avg generation throughput: 0.1 tokens/s
```

- `prompt throughput > 0` → prefill pod processed tokens
- `generation throughput ≈ 0` → prefill pod did NOT generate output tokens (correct — that's decode's job)

### 13c. Verify the Decode Pod Generated Tokens

First, ensure `$DECODE_POD` is set (it was defined in Step 10a — if you skipped there, set it now):

```bash
export DECODE_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | head -1 | awk '{print $1}')
echo "DECODE_POD: ${DECODE_POD}"
```

Then use the same approach as 13b — search full log history or check right after a request:

**Method A** — Search full log history (works anytime):

```bash
oc logs -n ${NAMESPACE} $DECODE_POD -c main 2>&1 | grep "generation throughput" | grep -v "generation throughput: 0.0" | tail -5
```

**Method B** — Send a request and check within 15 seconds:

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is RDMA?\"}],\"max_tokens\":50}" > /dev/null && \
sleep 5 && \
for pod in $(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | awk '{print $1}'); do
  result=$(oc logs -n ${NAMESPACE} $pod -c main --since=30s 2>&1 | grep "generation throughput" | grep -v "generation throughput: 0.0")
  if [ -n "$result" ]; then
    echo "=== $pod ==="
    echo "$result"
  fi
done
```

**Expected**: Non-zero generation throughput (actual log line includes vLLM prefix, shown wrapped):

```
(APIServer pid=69) INFO 03-13 14:23:35 [v1/metrics/loggers.py:248]
  Engine 000: Avg prompt throughput: 2.0 tokens/s,
  Avg generation throughput: 1.0 tokens/s,
  Running: 0 reqs, Waiting: 0 reqs,
  GPU KV cache usage: 0.0%, Prefix cache hit rate: 0.0%,
  External prefix cache hit rate: 100.0%
```

- `generation throughput > 0` → decode pod generated output tokens
- `prompt throughput` may also be non-zero — the decode pod processes the KV cache metadata received from prefill
- `External prefix cache hit rate: 100.0%` → confirms KV cache came from an external (remote prefill) source

### 13d. Verify Cross-Node UCX Transport

When a prefill pod first connects to a decode pod on a different node, UCX negotiates the transport and logs the result. This happens **once per peer pair** (not on every request), so search the full log — not `--since`:

```bash
oc logs -n ${NAMESPACE} $PREFILL_POD -c main 2>&1 | grep -A3 "inter-node.*active message" | head -12
```

**Expected** (actual log lines include timestamp and pod prefix, shown wrapped):

```
[1773411892.959098] [qwen3-32b-pd-kserve-prefill-...:503  :1]
  | ucp_context_0 inter-node cfg#2 | active message by ucp_am_send* from host memory    |
  +--------------------------------+-----------------------------------------+----------+
  |                        0..8184 | short                                   | tcp/eth0 |
  |                      8185..inf | multi-frag copy-in                      | tcp/eth0 |
```

This confirms:
- `inter-node cfg#2` → cross-node transfer (not same-node)
- `tcp/eth0` → using TCP over the pod network for active messages
- `multi-frag copy-in` / `multi-frag zero-copy` → large KV cache transfers
- `from host memory` → NIXL coordinates the transfer via host memory signaling, while `cuda_copy` handles GPU memory registration behind the scenes

### 13e. Full P/D Pipeline Validation Script

Run this comprehensive script after sending at least one request. It is self-contained — it does not depend on variables from earlier steps (except `NAMESPACE` and `LLMISVC_NAME` from the setup block).

> **Note**: This script takes 2-3 minutes to run because it checks nvidia-peermem on each GPU node via `oc debug`, which creates a temporary pod each time.

```bash
echo ""
echo "========================================"
echo "P/D Disaggregation Validation Report"
echo "========================================"
echo ""

# 1. LLMInferenceService status
READY=$(oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
echo "1. LLMInferenceService Ready: $READY"

# 2. Pod counts and placement
PREFILL_COUNT=$(oc get pods -n ${NAMESPACE} --no-headers | grep prefill | grep Running | wc -l | tr -d ' ')
DECODE_COUNT=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | grep Running | wc -l | tr -d ' ')
SCHEDULER_COUNT=$(oc get pods -n ${NAMESPACE} --no-headers | grep scheduler | grep Running | wc -l | tr -d ' ')
echo "2. Pods: $PREFILL_COUNT prefill, $DECODE_COUNT decode, $SCHEDULER_COUNT scheduler"

# 3. Node placement
PREFILL_NODES=$(oc get pods -n ${NAMESPACE} --no-headers -o wide | grep prefill | awk '{print $7}' | sort -u | tr '\n' ',' | sed 's/,$//')
DECODE_NODES=$(oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | awk '{print $7}' | sort -u | tr '\n' ',' | sed 's/,$//')
echo "3. Prefill nodes: $PREFILL_NODES"
echo "   Decode nodes:  $DECODE_NODES"
SAME_NODE="false"
if [ "$PREFILL_NODES" = "$DECODE_NODES" ]; then SAME_NODE="true"; fi
if [ "$SAME_NODE" = "false" ]; then echo "   Cross-node:    YES (correct)"; else echo "   Cross-node:    NO (prefill and decode on same node)"; fi

# 4. Restart count
TOTAL_RESTARTS=$(oc get pods -n ${NAMESPACE} -o json | python3 -c 'import sys,json
items = json.load(sys.stdin).get("items",[])
total = sum(cs.get("restartCount",0) for i in items for cs in i.get("status",{}).get("containerStatuses",[]))
print(total)')
echo "4. Total restarts: $TOTAL_RESTARTS $([ "$TOTAL_RESTARTS" = "0" ] && echo "(clean)" || echo "(INVESTIGATE)")"

# 5. NIXL backend
NIXL_OK=0
NIXL_FAIL=0
for pod in $(oc get pods -n ${NAMESPACE} --no-headers -o name | grep -v scheduler | grep -v download | grep kserve); do
  if oc logs -n ${NAMESPACE} $pod -c main 2>&1 | grep -q "NIXL is available"; then
    NIXL_OK=$((NIXL_OK + 1))
  fi
  if oc logs -n ${NAMESPACE} $pod -c main 2>&1 | grep -q "NIXL_ERR_BACKEND"; then
    NIXL_FAIL=$((NIXL_FAIL + 1))
  fi
done
echo "5. NIXL backend: $NIXL_OK pods OK, $NIXL_FAIL pods FAILED"

# 6. KV buffer device (pick first decode pod automatically)
FIRST_DECODE_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | head -1 | awk '{print $1}')
KV_DEVICE=$(oc logs -n ${NAMESPACE} $FIRST_DECODE_POD -c main 2>&1 | grep "kv_buffer_device" | head -1 | grep -o "kv_buffer_device='[^']*'" | cut -d"'" -f2)
echo "6. KV buffer device: ${KV_DEVICE:-unknown} $([ "$KV_DEVICE" = "cuda" ] && echo "(GPUDirect)" || echo "(CPU staging)")"

# 7. KV transfer evidence (search full logs, not just tail)
TRANSFER_COUNT=$(for pod in $(oc get pods -n ${NAMESPACE} --no-headers -o name | grep -v prefill | grep -v scheduler | grep -v download | grep kserve); do
  oc logs -n ${NAMESPACE} $pod -c main 2>&1 | grep "remote_block_ids" | grep -v "\[\]"
done | wc -l | tr -d ' ')
echo "7. KV transfers observed: $TRANSFER_COUNT $([ "$TRANSFER_COUNT" -gt "0" ] && echo "(P/D confirmed)" || echo "(send a request first)")"

# 8. nvidia-peermem
PEERMEM_OK=0
for NODE in $(oc get nodes -l nvidia.com/gpu.present=true -o name); do
  NODE_NAME=$(echo $NODE | cut -d/ -f2)
  if oc debug node/$NODE_NAME -- chroot /host lsmod 2>/dev/null | grep -q nvidia_peermem; then
    PEERMEM_OK=$((PEERMEM_OK + 1))
  fi
done
TOTAL_GPU_NODES=$(oc get nodes -l nvidia.com/gpu.present=true --no-headers | wc -l | tr -d ' ')
echo "8. nvidia-peermem: $PEERMEM_OK/$TOTAL_GPU_NODES GPU nodes"

echo ""
echo "========================================"

# Final verdict
if [ "$READY" = "True" ] && [ "$NIXL_FAIL" = "0" ] && [ "$TOTAL_RESTARTS" = "0" ] && [ "$SAME_NODE" = "false" ]; then
  echo "RESULT: ALL CHECKS PASSED"
else
  echo "RESULT: SOME CHECKS NEED ATTENTION"
fi
echo "========================================"
```

**Expected output**:

```
========================================
P/D Disaggregation Validation Report
========================================

1. LLMInferenceService Ready: True
2. Pods: 4 prefill, 4 decode, 1 scheduler
3. Prefill nodes: ocp-gpu-worker-h200-0
   Decode nodes:  ocp-gpu-worker-h100
   Cross-node:    YES (correct)
4. Total restarts: 0 (clean)
5. NIXL backend: 8 pods OK, 0 pods FAILED
6. KV buffer device: cuda (GPUDirect)
7. KV transfers observed: 2 (P/D confirmed)
8. nvidia-peermem: 2/2 GPU nodes

========================================
RESULT: ALL CHECKS PASSED
========================================
```

---

## Step 14: Summary

```bash
echo ""
echo "========================================"
echo "Phase 8: P/D Disaggregation Complete"
echo "========================================"
echo ""
echo "LLMInferenceService: $(oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
echo ""
echo "Prefill Workers:"
oc get pods -n ${NAMESPACE} --no-headers -o wide | grep prefill | awk '{printf "  %s  %s  %s\n", $1, $3, $7}'
echo ""
echo "Decode Workers:"
oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v prefill | grep -v scheduler | grep -v download | grep -v Completed | grep kserve | awk '{printf "  %s  %s  %s\n", $1, $3, $7}'
echo ""
echo "EPP Scheduler:"
oc get pods -n ${NAMESPACE} --no-headers | grep scheduler | awk '{printf "  %s  %s\n", $1, $3}'
echo ""
echo "Gateway: http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 8, you should have:

- [x] **VPC File Share** with NFS4 RWX storage for model
- [x] **Single LLMInferenceService CR** with `spec.prefill` for P/D disaggregation
- [x] **4 prefill pods** on H200 (TP=2, 8 GPUs total)
- [x] **4 decode pods** on H100 (TP=2, 8 GPUs total)
- [x] **P/D-aware EPP** with pd-profile-handler, prefill-filter, decode-filter
- [x] **Auto-created** InferencePool, HTTPRoute, Gateway reference
- [x] **nvidia-peermem** loaded on all GPU nodes (GPUDirect RDMA)
- [x] **NIXL backend** initialized on all pods (`NIXL is available`, `kv_buffer_device: cuda`)
- [x] **KV cache transfer** confirmed (decode logs: `remote_block_ids` populated, `remote_host` on prefill node)
- [x] **End-to-end inference** working through P/D pipeline

---

## Teardown

### Delete OpenShift Resources

```bash
oc delete namespace ${NAMESPACE} --wait=true
oc delete pv model-share-pv
```

### Delete IBM Cloud VPC File Share

```bash
# Delete mount target first
ibmcloud is share-mount-target-delete $FILE_SHARE_ID $MOUNT_TARGET_ID --force

# Wait for mount target deletion
sleep 30

# Delete file share
ibmcloud is share-delete $FILE_SHARE_ID --force
```

### Remove NFS Security Group Rule

```bash
# List rules to find the NFS rule (port 2049)
ibmcloud is security-group-rules $OCP_SG_ID --output json | \
  jq -r '.[] | select(.port_min==2049) | .id'

# Delete it
NFS_RULE_ID=$(ibmcloud is security-group-rules $OCP_SG_ID --output json | jq -r '.[] | select(.port_min==2049) | .id')
ibmcloud is security-group-rule-delete $OCP_SG_ID $NFS_RULE_ID --force
```

---

## Troubleshooting

### LLMInferenceService Not Reaching Ready

Check the status conditions:

```bash
oc get llmisvc qwen3-32b-pd -n ${NAMESPACE} -o yaml | grep -A 20 "status:"
```

Check controller logs:

```bash
oc logs -n redhat-ods-applications deployment/kserve-controller-manager --tail=50
```

### NFS Mount Failures

If pods fail with volume mount errors:

1. Verify the file share is stable:
   ```bash
   ibmcloud is share $FILE_SHARE_ID --output json | jq -r '.lifecycle_state'
   ```

2. Verify mount target is in the same subnet as workers:
   ```bash
   ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.subnet.name'
   ```
   Should show `ocp-mgmt-subnet` (same subnet as GPU workers).

3. Verify NFS connectivity from a GPU node:
   ```bash
   oc debug node/ocp-gpu-worker-h100 -- chroot /host showmount -e $NFS_SERVER
   ```

4. Check security group has TCP 2049 rule on BOTH SGs (worker SG + mount target SG):
   ```bash
   ibmcloud is security-group-rules $OCP_SG_ID --output json | jq '.[] | select(.port_min==2049)'
   ```

5. Verify PV uses `nfsvers=4.1` (VPC File Shares only support NFSv4.1):
   ```bash
   oc get pv model-share-pv -o jsonpath='{.spec.mountOptions}'
   ```
   Should include `nfsvers=4.1`.

### Prefill Pods Not Scheduling on H200

Verify node labels:

```bash
oc get node ocp-gpu-worker-h200-0 -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.product}'
```

Should show `NVIDIA-H200`. If different, adjust the `nodeSelector` in the CR.

### NIXL Connection Errors

If prefill and decode pods can't reach each other for KV transfer:

```bash
# Check pod IPs
oc get pods -n ${NAMESPACE} -o wide --no-headers

# Test pod-to-pod connectivity
PREFILL_IP=$(oc get pod -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep prefill | head -1 | awk '{print $1}') -o jsonpath='{.status.podIP}')
DECODE_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v prefill | grep -v epp | grep -v scheduler | grep -v download | grep -v Completed | head -1 | awk '{print $1}')
oc exec -n ${NAMESPACE} $DECODE_POD -- curl -s http://$PREFILL_IP:8000/health
```

### RDMA Not Available

If pods fail to schedule due to `rdma/rdma_mlx5`:

```bash
for NODE in ocp-gpu-worker-h100 ocp-gpu-worker-h200-0; do
  echo "$NODE RDMA: $(oc get node $NODE -o jsonpath='{.status.allocatable.rdma/rdma_mlx5}')"
done
```

Should show `1k` on each. If empty, verify NicClusterPolicy is ready (Phase 5 Step 3).

### HTTPRoute Returns 404

Check the auto-created HTTPRoute:

```bash
oc get httproute -n ${NAMESPACE} -o yaml
```

The path pattern depends on the controller's naming convention. Adjust curl path accordingly.

---

## Next Steps

1. **Tune P/D ratio**: Adjust `replicas` (decode) and `prefill.replicas` to match your workload's ISL/OSL ratio
2. **Selective P/D**: Increase `pd-profile-handler` threshold above 0 to bypass P/D for short prompts
3. **Compare performance**: Run the same workload with Phase 6 (standard serving) and Phase 8 (P/D) to measure inter-token latency improvement
4. **Benchmark**: Use [inference-perf](https://github.com/kubernetes-sigs/inference-perf) for systematic performance comparison

---

**Phase 8 Complete!**

**P/D disaggregation validated via LLMInferenceService: prefill on H200, decode on H100, shared NFS model storage, KV cache transfer via NIXL confirmed.**
