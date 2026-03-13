# Phase 9: Wide Expert Parallelism with DeepSeek-V2

## Overview

This phase deploys DeepSeek-V2 (236B, 160 MoE experts) with **Wide Expert Parallelism (EP)** across both GPU nodes using a single `LLMInferenceService` CR. Expert Parallelism distributes MoE model experts across GPUs — "wide" means the EP group spans **across nodes** using NCCL all-to-all communication. This is fundamentally different from Phase 8's P/D disaggregation (which splits prefill/decode roles and transfers KV cache via NIXL).

**What You'll Accomplish:**
- Expand the NFS file share and download DeepSeek-V2 (~472GB)
- Deploy a single LLMInferenceService with `parallelism.expert: true` and a `worker` field
- EP=16 across 2 nodes (160 experts distributed: 10 per GPU)
- NCCL all-to-all over TCP (IBM Cloud VF limitation — functional, not production-speed)
- Validate expert distribution and cross-node NCCL communication

**Model**: deepseek-ai/DeepSeek-V2 (236B total, 21B activated per token, 160 routed experts)
**GPU Layout**: 2 pods x 8 GPUs = 16 GPUs total (EP=16, TP=1)
**Estimated Time**: 90-120 minutes (includes NFS expansion + 472GB model download)

## Key Concepts

### Mixture of Experts (MoE)

DeepSeek-V2 is a Mixture-of-Experts model. Unlike dense models (Qwen3-32B, Llama) where every parameter is used for every token, MoE models only activate a **subset of expert networks** per token:

```
Dense model (32B):                  MoE model (236B total, 21B activated):
Every token uses all 32B params     Each token routes to 6 of 160 experts

[Token] --> [All 32B params]        [Token] --> [Router] --> [Expert 3]  (1.3B)
                                                         --> [Expert 47] (1.3B)
                                                         --> [Expert 91] (1.3B)
                                                         --> [Expert 12] (1.3B)
                                                         --> [Expert 118](1.3B)
                                                         --> [Expert 55] (1.3B)
                                                         --> [Shared experts] (2B)
                                                         --> [Dense layers]  (13B)
```

MoE achieves the quality of a 236B model while only using 21B parameters per token — 11x more efficient than running all 236B.

### Expert Parallelism (EP) vs Tensor Parallelism (TP)

Phase 6 and 8 used **Tensor Parallelism** — splitting each layer's weight matrices across GPUs within a single node. EP takes a different approach:

| Aspect | Tensor Parallelism (Phase 6/8) | Expert Parallelism (Phase 9) |
|---|---|---|
| What's split | Each layer's weight matrix | Whole expert networks |
| Granularity | Sub-matrix per GPU | Whole expert per GPU |
| Communication | AllReduce after each layer (NVLink) | All-to-all for expert routing |
| Model type | Any (dense or MoE) | MoE only |
| KV cache | Duplicated across TP GPUs | One copy per DP rank (10x more efficient for MLA) |
| Scale | Usually 1 node (NVLink) | Spans nodes (NCCL) |

### Why TP=1 for DeepSeek-V2?

DeepSeek-V2 uses **Multi-head Latent Attention (MLA)**, which compresses KV cache dramatically (~9.6x vs standard multi-head attention). With TP, KV cache is **duplicated** across all TP GPUs — wasting the MLA advantage. With DP+EP (TP=1), each GPU keeps its **own** KV cache, maximizing the memory benefit of MLA.

| Configuration | KV cache copies | Effective KV memory |
|---|---|---|
| TP=8, EP=1 (single node) | 8 copies | 1/8 of total GPU memory |
| TP=1, EP=16 (two nodes) | 1 copy per rank | Full GPU memory per rank |

### What is "Wide" EP?

"Wide" means the EP group spans **multiple nodes**. Experts on node A communicate with experts on node B via NCCL all-to-all:

```
Token arrives at GPU 0 (Node A, H100)
  |
  [Router]: "This token needs experts 3, 47, 91, 12, 118, 55"
  |
  Experts 0-79 are on Node A (GPUs 0-7, 10 experts each)
  Experts 80-159 are on Node B (GPUs 8-15, 10 experts each)
  |
  Expert 3  --> GPU 0 (local, NVLink)     ~900 GB/s
  Expert 47 --> GPU 4 (local, NVLink)     ~900 GB/s
  Expert 91 --> GPU 11 (remote, NCCL)     ~25-50 Gbps (TCP)  <-- cross-node
  Expert 12 --> GPU 1 (local, NVLink)     ~900 GB/s
  Expert 118--> GPU 13 (remote, NCCL)    ~25-50 Gbps (TCP)  <-- cross-node
  Expert 55 --> GPU 5 (local, NVLink)     ~900 GB/s
  |
  [All-to-all]: collect results from all experts
  |
  Continue to next layer
```

Every forward pass involves all-to-all communication between GPUs. Cross-node transfers use NCCL over TCP — significantly slower than intra-node NVLink. This is the fundamental trade-off of wide EP.

### IBM Cloud VF Limitation: NCCL over TCP

NCCL normally uses IB verbs (RDMA) for cross-node communication (~400 Gbps). On IBM Cloud cluster network VFs (device `101e`), NCCL IB verbs don't work (same VF limitation as UCX RC transport discovered in Phase 8). NCCL falls back to **TCP sockets** (~25-50 Gbps) — functional but 8-16x slower than RDMA.

Additionally, the `deepep_high_throughput` and `deepep_low_latency` all-to-all backends require NVSHMEM with IBGDA transport, which needs true RDMA PFs. On IBM Cloud VFs, we use the `naive` all-to-all backend.

**This deployment validates the pattern (LWS multi-node EP, NCCL communication, MoE expert routing, MLA inference). It does NOT represent production-speed NCCL performance.**

### Phase 8 vs Phase 9

| Aspect | Phase 8 (P/D Disaggregation) | Phase 9 (Wide EP) |
|---|---|---|
| Model type | Dense (Qwen3-32B) | MoE (DeepSeek-V2, 160 experts) |
| Multi-node pattern | Prefill on one node, decode on other | Same role on both, experts distributed |
| Communication | NIXL/UCX (KV cache, once per request) | NCCL all-to-all (expert routing, every forward pass) |
| Orchestration | LLMInferenceService `prefill` field | LLMInferenceService `worker` field (creates LWS) |
| NCCL required? | No | Yes |
| Pod relationship | Independent pods | Coordinated LWS group (leader + worker) |
| TP | 2 (split layers) | 1 (whole layers, experts distributed) |

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
[EPP Scheduler]                    (auto-created, load-aware)
      |
      v
[LeaderWorkerSet: replicas=1, size=2]   (auto-created by controller)
  |
  +--- Pod 0 (leader) --> [H100 or H200 node, 8 GPUs]
  |     EP ranks 0-7 (10 experts each)
  |     Serves OpenAI API on port 8000
  |     NCCL all-to-all <--> Pod 1
  |
  +--- Pod 1 (worker) --> [Other GPU node, 8 GPUs]
        EP ranks 8-15 (10 experts each)
        Headless (no API server)
        NCCL all-to-all <--> Pod 0

Cross-node communication:
  NCCL all-to-all over TCP/eth0 (NCCL_IB_DISABLE=1)
  Every forward pass: activations sent to expert-holding GPUs
  Intra-node: NVLink (~900 GB/s)
  Inter-node: TCP sockets (~25-50 Gbps)
```

**Why no nodeSelector?** Each pod requests `nvidia.com/gpu: 8` and each node has exactly 8 GPUs. Kubernetes can only fit one pod per GPU node — the scheduler automatically places the second pod on the other node. No anti-affinity or nodeSelector needed.

**Why `replicas: 1`?** The controller computes LWS `size = parallelism.data / parallelism.dataLocal = 16 / 8 = 2` pods per replica. With `replicas: 1`, we get 1 LWS group of 2 pods = 16 GPUs total.

## Pre-Flight Checks

Before starting, ensure Phase 5 operators are installed and both GPU nodes are healthy:

- [ ] 5 nodes Ready (3 masters + H100 + H200)
- [ ] GPU Operator installed — `nvidia.com/gpu: 8` on both GPU nodes
- [ ] DataScienceCluster Ready
- [ ] LLMInferenceService CRD present with EP-related parallelism fields
- [ ] LeaderWorkerSet CRD present
- [ ] KUBECONFIG set and working
- [ ] IBM Cloud CLI logged in
- [ ] **Phase 8 workloads cleaned up** (all GPUs free)

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

### Verify EP Support in LLMInferenceService CRD

The `parallelism` field must support `data`, `dataLocal`, and `expert` sub-fields for Wide EP:

```bash
oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.parallelism.properties}' | python3 -c "
import sys, json
fields = sorted(json.load(sys.stdin).keys())
required = ['data', 'dataLocal', 'expert', 'tensor']
print('Parallelism fields:', fields)
for f in required:
    status = 'FOUND' if f in fields else 'MISSING'
    print(f'  {f}: {status}')
missing = [f for f in required if f not in fields]
if missing:
    print(f'\nBLOCKER: Missing fields: {missing}')
    print('Wide EP requires RHOAI with DP+EP support.')
else:
    print('\nAll EP fields present -- Wide EP supported.')
"
```

**Expected**: All four fields present. If `data`, `dataLocal`, or `expert` are missing, the RHOAI version does not support Wide EP via LLMInferenceService.

### Verify LeaderWorkerSet CRD

```bash
oc get crd leaderworkersets.leaderworkerset.x-k8s.io --no-headers
```

Should show the CRD exists. If missing, create the `LeaderWorkerSetOperator` CR (Phase 5 Step 8e).

### Verify Worker Field in LLMInferenceService CRD

```bash
oc get crd llminferenceservices.serving.kserve.io -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties}' | python3 -c "
import sys, json
fields = sorted(json.load(sys.stdin).keys())
print('worker' in fields and 'worker field: FOUND' or 'worker field: MISSING')
"
```

**Expected**: `worker field: FOUND`.

### Clean Up Phase 8 (If Still Running)

Phase 8 uses all 16 GPUs. You must free them before deploying Phase 9:

```bash
# Check if Phase 8 namespace exists and has pods
oc get pods -n llm-d-pd --no-headers 2>/dev/null | head -5
```

If pods are running, tear down Phase 8:

```bash
oc delete llmisvc --all -n llm-d-pd
oc delete namespace llm-d-pd --wait=true
```

Wait until all GPU pods are terminated, then verify GPUs are free:

```bash
for NODE in ocp-gpu-worker-h100 ocp-gpu-worker-h200-0; do
  ALLOCATED=$(oc get node $NODE -o jsonpath='{.status.allocatable.nvidia\.com/gpu}')
  USED=$(oc describe node $NODE | grep "nvidia.com/gpu" | tail -1 | awk '{print $2}')
  echo "$NODE: $ALLOCATED allocatable, $USED requested"
done
```

**Expected**: 8 allocatable, 0 requested on each node.

### Create Inference Gateway (If Not Present)

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

# Part A: Storage Preparation

---

## Step 1: Expand NFS File Share

DeepSeek-V2 is ~472GB at bf16. The Phase 8 file share may be only 100GB. Check and expand if needed.

### 1a. Login and Get File Share Info

```bash
source ~/.ibmcloud-h100-env
ibmcloud_login
```

```bash
# If FILE_SHARE_ID is not set, find it
if [ -z "$FILE_SHARE_ID" ]; then
  export FILE_SHARE_ID=$(ibmcloud is shares --output json | jq -r '.[] | select(.name=="model-share") | .id')
fi
echo "File Share ID: $FILE_SHARE_ID"
```

### 1b. Check Current Size

```bash
CURRENT_SIZE=$(ibmcloud is share $FILE_SHARE_ID --output json | jq -r '.size')
echo "Current size: ${CURRENT_SIZE} GB"
```

### 1c. Expand to 600GB (If Needed)

DeepSeek-V2 (~472GB) + Qwen3-32B (~65GB if present) + overhead = 600GB minimum.

> **Note**: IBM Cloud VPC file share expansion is in-place — no downtime, no data loss. The share size can only be increased, never decreased.

```bash
if [ "$CURRENT_SIZE" -lt 600 ]; then
  echo "Expanding file share from ${CURRENT_SIZE}GB to 600GB..."
  ibmcloud is share-update $FILE_SHARE_ID --size 600
  echo "Expansion initiated. Waiting for stable..."
  while true; do
    STATUS=$(ibmcloud is share $FILE_SHARE_ID --output json | jq -r '.lifecycle_state')
    SIZE=$(ibmcloud is share $FILE_SHARE_ID --output json | jq -r '.size')
    echo "  Status: $STATUS, Size: ${SIZE}GB ($(date '+%H:%M:%S'))"
    if [ "$STATUS" = "stable" ] && [ "$SIZE" -ge 600 ]; then
      echo "File share expanded to ${SIZE}GB"
      break
    fi
    sleep 10
  done
else
  echo "File share already ${CURRENT_SIZE}GB -- no expansion needed"
fi
```

---

## Step 2: Create Namespace and Storage

### 2a. Create Namespace

```bash
export NAMESPACE=wide-ep
oc new-project ${NAMESPACE} 2>/dev/null || oc project ${NAMESPACE}
```

### 2b. Get NFS Mount Info

```bash
# Get mount target ID
if [ -z "$MOUNT_TARGET_ID" ]; then
  export MOUNT_TARGET_ID=$(ibmcloud is share-mount-targets $FILE_SHARE_ID --output json | jq -r '.[0].id')
fi

export NFS_SERVER=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.mount_path' | cut -d: -f1)
export NFS_PATH=$(ibmcloud is share-mount-target $FILE_SHARE_ID $MOUNT_TARGET_ID --output json | jq -r '.mount_path' | cut -d: -f2)
echo "NFS Server: $NFS_SERVER"
echo "NFS Path:   $NFS_PATH"
```

### 2c. Create PersistentVolume

> **Note**: If `model-share-pv` from Phase 8 is still bound to a PVC in another namespace, create a second PV with a different name. A PV can only bind to one PVC.

```bash
# Check if existing PV is available
PV_STATUS=$(oc get pv model-share-pv -o jsonpath='{.status.phase}' 2>/dev/null)

if [ "$PV_STATUS" = "Bound" ]; then
  BOUND_NS=$(oc get pv model-share-pv -o jsonpath='{.spec.claimRef.namespace}')
  if [ "$BOUND_NS" != "${NAMESPACE}" ]; then
    echo "PV model-share-pv is bound to namespace $BOUND_NS"
    echo "Creating a second PV (model-share-pv-ep) for the wide-ep namespace"
    PV_NAME="model-share-pv-ep"
  else
    echo "PV model-share-pv already bound to ${NAMESPACE} -- reusing"
    PV_NAME="model-share-pv"
  fi
elif [ "$PV_STATUS" = "Available" ] || [ "$PV_STATUS" = "Released" ]; then
  echo "Reusing existing PV model-share-pv"
  PV_NAME="model-share-pv"
  # If Released, clear the old claimRef so it can bind to new PVC
  if [ "$PV_STATUS" = "Released" ]; then
    oc patch pv model-share-pv --type json -p '[{"op":"remove","path":"/spec/claimRef"}]'
  fi
else
  echo "Creating new PV model-share-pv"
  PV_NAME="model-share-pv"
fi

echo "PV name: $PV_NAME"
```

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${PV_NAME}
spec:
  capacity:
    storage: 600Gi
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

### 2d. Create PersistentVolumeClaim

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
  volumeName: ${PV_NAME}
  resources:
    requests:
      storage: 600Gi
EOF
```

### 2e. Verify PVC is Bound

```bash
oc get pvc model-cache-rwx -n ${NAMESPACE}
```

**Expected**: `Bound` to `${PV_NAME}`.

---

## Step 3: Create Service Account and Secrets

### 3a. Create Service Account

```bash
oc create sa wide-ep-sa -n ${NAMESPACE}
```

### 3b. Grant Multi-Node SCC

NCCL requires GPU memory pinning. The multi-node SCC provides `IPC_LOCK` and related capabilities:

```bash
oc adm policy add-scc-to-user openshift-ai-llminferenceservice-multi-node-scc \
  -z wide-ep-sa -n ${NAMESPACE}
```

### 3c. Create HuggingFace Token Secret

```bash
export HF_TOKEN=<your-huggingface-token>
```

```bash
oc create secret generic deepseek-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}"
```

---

## Step 4: Download DeepSeek-V2

DeepSeek-V2 is ~472GB at bf16. This will take 60-120 minutes depending on HuggingFace egress speed.

### 4a. Start Download Job

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: download-deepseek-v2
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
            repo_id='deepseek-ai/DeepSeek-V2',
            local_dir='/model-cache/hub/deepseek-ai/DeepSeek-V2',
            token='${HF_TOKEN}'
          )
          print('Download complete')
          "
        env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: deepseek-hf-token
              key: HF_TOKEN
        resources:
          requests:
            cpu: "2"
            memory: "8Gi"
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

### 4b. Monitor Download Progress

```bash
echo "Waiting for DeepSeek-V2 download (~472GB, 60-120 min)..."
while true; do
  STATUS=$(oc get job download-deepseek-v2 -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Complete")].status}' 2>/dev/null)
  FAILED=$(oc get job download-deepseek-v2 -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Failed")].status}' 2>/dev/null)
  if [ "$STATUS" = "True" ]; then
    echo ""
    echo "Model download complete."
    break
  fi
  if [ "$FAILED" = "True" ]; then
    echo ""
    echo "Download FAILED. Check logs: oc logs -n ${NAMESPACE} job/download-deepseek-v2"
    break
  fi
  echo -n "."
  sleep 60
done
```

You can check download progress in another terminal:

```bash
oc logs -n wide-ep job/download-deepseek-v2 --tail=5 -f
```

### 4c. Verify Model on PVC

```bash
oc run pvc-check --restart=Never -n ${NAMESPACE} \
  --overrides='{
    "spec":{
      "nodeSelector":{"node-role.kubernetes.io/gpu":"true"},
      "containers":[{
        "name":"check",
        "image":"registry.access.redhat.com/ubi9/ubi-minimal",
        "command":["sh","-c","ls -la /model-cache/hub/deepseek-ai/DeepSeek-V2/ && echo && du -sh /model-cache/hub/deepseek-ai/DeepSeek-V2/"],
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

Should show model files (config.json, model weight shards, tokenizer, etc.) totaling ~472GB.

---

# Part B: Deploy Wide EP with LLMInferenceService

---

## Step 5: Create LLMInferenceService with Expert Parallelism

This single CR creates the entire Wide EP stack: LWS with size=2, vLLM with EP=16, EPP scheduler, InferencePool, and HTTPRoute.

> **Key configuration notes:**
> - `parallelism.data: 16` — total data-parallel size (16 GPUs across 2 nodes)
> - `parallelism.dataLocal: 8` — GPUs per node; controller computes LWS size = data/dataLocal = 2
> - `parallelism.expert: true` — enables `--enable-expert-parallel` in vLLM
> - `parallelism.tensor: 1` — no TP; EP handles distribution; preserves MLA KV cache efficiency
> - `worker` section — defines the worker pod template (non-leader pods in the LWS group)
> - `NCCL_IB_DISABLE=1` — forces TCP sockets (IB verbs don't work on IBM Cloud VFs)
> - `VLLM_ALL2ALL_BACKEND=naive` — naive all-to-all (deepep backends need NVSHMEM/IBGDA)
> - No `--kv-transfer-config` — EP does not use NIXL; NCCL handles all communication
> - No `UCX_TLS` — UCX/NIXL is not involved in EP communication

```bash
oc apply -n ${NAMESPACE} -f - <<'EOF'
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: deepseek-v2-ep
  namespace: wide-ep
spec:
  model:
    name: deepseek-ai/DeepSeek-V2
    uri: "pvc://model-cache-rwx/hub/deepseek-ai/DeepSeek-V2"

  # ==========================================
  # LEADER pod template (serves API)
  # ==========================================
  replicas: 1
  parallelism:
    data: 16
    dataLocal: 8
    expert: true
    tensor: 1
  template:
    serviceAccountName: wide-ep-sa
    containers:
    - name: main
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
            - SYS_RAWIO
      env:
      - name: HF_TOKEN
        valueFrom:
          secretKeyRef:
            name: deepseek-hf-token
            key: HF_TOKEN
      # ----- NCCL: force TCP (IBM Cloud VFs don't support IB verbs) -----
      - name: NCCL_IB_DISABLE
        value: "1"
      - name: NCCL_SOCKET_IFNAME
        value: "eth0"
      - name: NCCL_DEBUG
        value: "INFO"
      - name: NCCL_DEBUG_SUBSYS
        value: "INIT,NET"
      # ----- Gloo (PyTorch distributed) -----
      - name: GLOO_SOCKET_IFNAME
        value: "eth0"
      # ----- vLLM configuration -----
      - name: VLLM_ALL2ALL_BACKEND
        value: "naive"
      - name: VLLM_ADDITIONAL_ARGS
        value: "--gpu-memory-utilization 0.90 --max-model-len 8192 --enforce-eager --disable-uvicorn-access-log"
      - name: VLLM_LOGGING_LEVEL
        value: DEBUG
      resources:
        limits:
          nvidia.com/gpu: "8"
          cpu: "64"
          memory: "512Gi"
      volumeMounts:
      - name: shm
        mountPath: /dev/shm
      livenessProbe:
        httpGet:
          path: /health
          port: 8000
          scheme: HTTPS
        initialDelaySeconds: 3600
        periodSeconds: 10
        timeoutSeconds: 10
        failureThreshold: 3
    volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 32Gi

  # ==========================================
  # WORKER pod template (headless, EP ranks 8-15)
  # ==========================================
  worker:
    serviceAccountName: wide-ep-sa
    containers:
    - name: main
      securityContext:
        capabilities:
          add:
            - IPC_LOCK
            - SYS_RAWIO
      env:
      - name: HF_TOKEN
        valueFrom:
          secretKeyRef:
            name: deepseek-hf-token
            key: HF_TOKEN
      # ----- NCCL: force TCP -----
      - name: NCCL_IB_DISABLE
        value: "1"
      - name: NCCL_SOCKET_IFNAME
        value: "eth0"
      - name: NCCL_DEBUG
        value: "INFO"
      - name: NCCL_DEBUG_SUBSYS
        value: "INIT,NET"
      # ----- Gloo -----
      - name: GLOO_SOCKET_IFNAME
        value: "eth0"
      # ----- vLLM configuration -----
      - name: VLLM_ALL2ALL_BACKEND
        value: "naive"
      - name: VLLM_ADDITIONAL_ARGS
        value: "--gpu-memory-utilization 0.90 --max-model-len 8192 --enforce-eager --disable-uvicorn-access-log"
      - name: VLLM_LOGGING_LEVEL
        value: DEBUG
      resources:
        limits:
          nvidia.com/gpu: "8"
          cpu: "64"
          memory: "512Gi"
      volumeMounts:
      - name: shm
        mountPath: /dev/shm
      livenessProbe:
        httpGet:
          path: /health
          port: 8000
          scheme: HTTPS
        initialDelaySeconds: 3600
        periodSeconds: 10
        timeoutSeconds: 10
        failureThreshold: 3
    volumes:
    - name: shm
      emptyDir:
        medium: Memory
        sizeLimit: 32Gi

  # ==========================================
  # ROUTER (EPP scheduler)
  # ==========================================
  router:
    gateway: {}
    route: {}
    scheduler: {}
EOF
```

**What each section does:**

| Section | Purpose |
|---|---|
| `spec.model` | Model name and URI (RWX PVC, mounted on all pods) |
| `replicas: 1` | 1 LWS group (2 pods per group, computed from data/dataLocal) |
| `parallelism.data: 16` | Total DP size = 16 GPUs, maps to `--data-parallel-size 16` |
| `parallelism.dataLocal: 8` | Per-node DP size, maps to `--data-parallel-size-local 8`; LWS size = 16/8 = 2 |
| `parallelism.expert: true` | Enables `--enable-expert-parallel` in vLLM |
| `parallelism.tensor: 1` | No TP; each GPU runs full expert(s), keeps own KV cache |
| `template` | Leader pod (rank 0-7, serves OpenAI API) |
| `worker` | Worker pod (rank 8-15, headless, NCCL peer) |
| `NCCL_IB_DISABLE=1` | Forces NCCL to TCP sockets (IBM Cloud VFs) |
| `VLLM_ALL2ALL_BACKEND=naive` | Naive all-to-all (no NVSHMEM/IBGDA dependency) |
| `--gpu-memory-utilization 0.90` | Conservative for H100 80GB (leaves headroom for NCCL buffers) |
| `--max-model-len 8192` | Conservative context length for initial validation |
| `--enforce-eager` | Skips CUDA graph compilation — faster startup on NFS |
| `livenessProbe.initialDelaySeconds: 3600` | 60 min grace: 472GB NFS load is much slower than 65GB |
| `router.scheduler: {}` | Default scheduler (load-aware, no P/D split) |

> **Note on `--gpu-memory-utilization 0.90`**: With mixed H100 (80GB) and H200 (141GB), the H100 is the bottleneck. Setting 0.90 x 80GB = 72GB available per GPU — sufficient for DeepSeek-V2's ~29.5GB weights/GPU + KV cache + NCCL buffers.

> **Note on `livenessProbe.initialDelaySeconds: 3600`**: DeepSeek-V2 has many more weight shards than Qwen3-32B. At ~130s/shard cold cache, loading 472GB from NFS could take 45-60 minutes. The 60-minute liveness probe grace period prevents Kubernetes from killing pods during initial model loading.

---

## Step 5b: Grant SCC to Controller-Created SA

The LLMInferenceService controller auto-creates a service account named `deepseek-v2-ep-kserve`. Wait for it, then grant the multi-node SCC:

```bash
echo "Waiting for controller to create SA..."
while ! oc get sa deepseek-v2-ep-kserve -n ${NAMESPACE} &>/dev/null; do
  echo -n "."
  sleep 5
done
echo ""
echo "SA created. Granting SCC..."

oc adm policy add-scc-to-user openshift-ai-llminferenceservice-multi-node-scc \
  -z deepseek-v2-ep-kserve -n ${NAMESPACE}
```

> **Why two SAs?** Same pattern as Phase 8: `wide-ep-sa` is used by the worker template, `deepseek-v2-ep-kserve` is auto-created by the controller for the leader/decode template. Both need the SCC for GPU memory pinning.

---

## Step 6: Wait for Model Loading and Pods Ready

DeepSeek-V2 is ~472GB — NFS cold load will take 30-60 minutes per pod.

```bash
echo "Waiting for LLMInferenceService to become Ready..."
echo "(DeepSeek-V2 is 472GB -- NFS cold load takes 30-60 min per pod)"
while true; do
  READY=$(oc get llmisvc deepseek-v2-ep -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  if [ "$READY" = "True" ]; then
    echo ""
    echo "LLMInferenceService is Ready."
    break
  fi
  echo -n "."
  sleep 30
done
```

Verify pod placement:

```bash
oc get pods -n ${NAMESPACE} -o wide --no-headers | grep -v download | grep -v Completed
```

**Expected**:
- 2 vLLM pods on separate GPU nodes (1 leader, 1 worker)
- 1 EPP scheduler pod on a master node
- All pods Running

Check the LWS was created:

```bash
oc get lws -n ${NAMESPACE}
```

**Expected**: A LeaderWorkerSet named `deepseek-v2-ep-*` with `replicas: 1` and `size: 2`.

If pods are stuck or crashing, check logs:

```bash
# Controller logs
oc logs -n redhat-ods-applications deployment/kserve-controller-manager --tail=30 | grep -i error

# Leader pod logs (most recent)
LEADER_POD=$(oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v scheduler | grep -v download | grep -v Completed | head -1 | awk '{print $1}')
oc logs -n ${NAMESPACE} $LEADER_POD -c main --tail=50

# Worker pod logs
WORKER_POD=$(oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v scheduler | grep -v download | grep -v Completed | tail -1 | awk '{print $1}')
oc logs -n ${NAMESPACE} $WORKER_POD -c main --tail=50
```

---

# Part C: Validate Wide EP

---

> **STOP -- Set these variables before running ANY command below.**

```bash
export NAMESPACE=wide-ep
export LLMISVC_NAME=deepseek-v2-ep
export MODEL_NAME="deepseek-ai/DeepSeek-V2"
export GATEWAY_IP=$(oc get svc -n openshift-ingress \
  -l gateway.networking.k8s.io/gateway-name=openshift-ai-inference \
  -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
```

Verify:

```bash
echo "NAMESPACE:    ${NAMESPACE}"
echo "LLMISVC_NAME: ${LLMISVC_NAME}"
echo "MODEL_NAME:   ${MODEL_NAME}"
echo "GATEWAY_IP:   ${GATEWAY_IP}"
```

**Expected**: All four values populated. `GATEWAY_IP` should be a hostname like `*.lb.appdomain.cloud`.

---

## Step 7: Validate Layer 1 -- NCCL Initialization

NCCL must initialize with TCP transport (not IB) and form a communicator across both nodes.

### 7a. Verify NCCL Transport Selection

```bash
LEADER_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v scheduler | grep -v download | grep -v Completed | head -1 | awk '{print $1}')
echo "Leader pod: $LEADER_POD"
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -i "NCCL" | head -20
```

**Expected**: NCCL should report using Socket transport (TCP):

```
NCCL INFO Bootstrap: Using eth0:10.x.x.x<0>
NCCL INFO NET/Socket: Using [0]eth0:10.x.x.x
NCCL INFO Using network Socket
```

**If you see `Using network IB`**: NCCL found IB devices despite `NCCL_IB_DISABLE=1`. Verify the env var is set:

```bash
oc get pod $LEADER_POD -n ${NAMESPACE} -o jsonpath='{.spec.containers[0].env}' | python3 -c "
import sys, json
for e in json.load(sys.stdin):
    if 'NCCL' in e.get('name',''):
        print(f\"{e['name']}={e.get('value','')}\")
"
```

### 7b. Verify NCCL Communicator Formed Across Nodes

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -i "comm.*Init\|ranks\|nNodes"
```

**Expected**: NCCL should report 16 ranks across 2 nodes:

```
NCCL INFO comm 0x... rank 0 nranks 16 ...
```

The `nranks 16` confirms all 16 GPUs are in the NCCL communicator.

### 7c. Check Worker NCCL

```bash
WORKER_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep -v scheduler | grep -v download | grep -v Completed | tail -1 | awk '{print $1}')
echo "Worker pod: $WORKER_POD"
oc logs -n ${NAMESPACE} $WORKER_POD -c main 2>&1 | grep -i "NCCL" | head -20
```

**Expected**: Same Socket transport, connecting to the leader.

---

## Step 8: Validate Layer 2 -- Expert Parallelism Configuration

### 8a. Verify EP Mode in vLLM Logs

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -iE "expert.parallel|data.parallel|EP|DP"
```

**Expected** (log messages may vary by vLLM version):

```
INFO ... data_parallel_size=16
INFO ... data_parallel_size_local=8
INFO ... enable_expert_parallel=True
```

### 8b. Verify Model Architecture Detected

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -i "DeepseekV2\|MoE\|experts\|MLA"
```

**Expected**: vLLM should detect DeepSeek-V2's MoE architecture with 160 experts and MLA attention.

### 8c. Verify GPU Memory Usage

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -i "gpu.*memory\|model.*loaded\|weight"
```

With EP=16, each GPU holds ~29.5GB of weights (10 experts + dense layers). On H100 (80GB), this leaves ~50GB for KV cache and NCCL buffers.

---

## Step 9: Validate Layer 3 -- LLMInferenceService Status

### 9a. Check All Status Conditions

```bash
oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o json | \
  python3 -c 'import sys,json
for c in json.load(sys.stdin).get("status",{}).get("conditions",[]):
    print(c["type"] + ": " + c["status"])'
```

**Expected** -- all True:

```
HTTPRoutesReady: True
InferencePoolReady: True
MainWorkloadReady: True
PresetsCombined: True
Ready: True
RouterReady: True
SchedulerWorkloadReady: True
WorkloadsReady: True
```

> **Note**: No `PrefillWorkloadReady` — Phase 9 doesn't use P/D disaggregation.

### 9b. Verify Pod Placement on Separate Nodes

```bash
echo "Pod placement:"
oc get pods -n ${NAMESPACE} -o wide --no-headers | grep -v scheduler | grep -v download | grep -v Completed | awk '{printf "  %-55s %s\n", $1, $7}'
```

**Expected**: Two pods on two different GPU nodes.

### 9c. Verify LWS Group

```bash
oc get lws -n ${NAMESPACE} -o custom-columns='NAME:.metadata.name,REPLICAS:.spec.replicas,SIZE:.spec.leaderWorkerTemplate.size,READY:.status.readyReplicas'
```

**Expected**: `REPLICAS: 1`, `SIZE: 2`, `READY: 1`.

---

## Step 10: Validate Layer 4 -- Gateway and Routing

### 10a. Verify HTTPRoute

```bash
oc get httproute -n ${NAMESPACE} -o custom-columns='NAME:.metadata.name,PATH:.spec.rules[0].matches[0].path.value' --no-headers
```

Note the path pattern for curl commands.

### 10b. Verify InferencePool

```bash
oc get inferencepool -n ${NAMESPACE}
```

**Expected**: One pool in Ready state.

---

## Step 11: Validate Layer 5 -- End-to-End Inference

### 11a. Send a Short Request

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is expert parallelism? Answer in 2 sentences.\"}],
    \"max_tokens\": 100
  }" | python3 -m json.tool
```

**Expected**: HTTP 200 with a valid response in `choices[0].message.content`.

**If you get a 404**, the HTTPRoute path doesn't match. Check Step 10a and adjust the curl path.

**If you get a 503**, the EPP scheduler can't reach backend pods. Check scheduler logs:

```bash
oc logs -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep scheduler | awk '{print $1}') --tail=20
```

### 11b. Send a Longer Request

A longer prompt exercises more expert routing:

```bash
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{
    \"model\": \"${MODEL_NAME}\",
    \"messages\": [
      {\"role\": \"system\", \"content\": \"You are a helpful AI assistant that explains distributed computing concepts clearly.\"},
      {\"role\": \"user\", \"content\": \"Explain how Mixture of Experts models work, including the gating mechanism, expert selection, and why MoE is more efficient than dense models. Compare DeepSeek-V2's MoE architecture to standard MoE.\"}
    ],
    \"max_tokens\": 300
  }" | python3 -m json.tool
```

### 11c. Verify Throughput Metrics

Check the leader pod's throughput (only the leader serves the API):

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main --since=120s 2>&1 | grep "throughput" | tail -5
```

**Expected**: Non-zero prompt and generation throughput.

> **Performance note**: NCCL over TCP adds significant latency to every forward pass (cross-node all-to-all). Expect lower tokens/s compared to Phase 6 (single-node TP). The throughput here validates correctness, not production performance.

---

## Step 12: Validate Layer 6 -- Expert Distribution

### 12a. Verify Expert Routing in Logs

Check that experts are being routed across both nodes:

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -iE "all.to.all\|all2all\|expert.*parallel\|dispatch" | tail -10
```

### 12b. Verify Both Pods Are Active

During inference, both pods should show GPU activity. Send a request and immediately check:

```bash
# Send request in background
curl -s http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"Write a detailed essay about distributed AI systems.\"}],\"max_tokens\":500}" > /dev/null &

# Check both pods for activity
sleep 5
echo "Leader pod throughput:"
oc logs -n ${NAMESPACE} $LEADER_POD -c main --since=30s 2>&1 | grep "throughput" | tail -3
echo ""
echo "Worker pod activity:"
oc logs -n ${NAMESPACE} $WORKER_POD -c main --since=30s 2>&1 | grep -iE "throughput\|forward\|step\|batch" | tail -3
wait
```

### 12c. Full Validation Script

Run this after sending at least one successful inference request:

```bash
echo ""
echo "========================================"
echo "Wide EP Validation Report"
echo "========================================"
echo ""

# 1. LLMInferenceService status
READY=$(oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
echo "1. LLMInferenceService Ready: $READY"

# 2. LWS status
LWS_SIZE=$(oc get lws -n ${NAMESPACE} -o jsonpath='{.items[0].spec.leaderWorkerTemplate.size}' 2>/dev/null)
LWS_READY=$(oc get lws -n ${NAMESPACE} -o jsonpath='{.items[0].status.readyReplicas}' 2>/dev/null)
echo "2. LWS: size=$LWS_SIZE, ready=$LWS_READY"

# 3. Pod placement
POD_NODES=$(oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v scheduler | grep -v download | grep -v Completed | awk '{print $7}' | sort -u)
POD_COUNT=$(echo "$POD_NODES" | wc -l | tr -d ' ')
echo "3. Pods on $POD_COUNT distinct nodes:"
for node in $POD_NODES; do echo "   $node"; done
MULTI_NODE="false"
if [ "$POD_COUNT" -ge 2 ]; then MULTI_NODE="true"; fi
echo "   Cross-node: $([ "$MULTI_NODE" = "true" ] && echo 'YES (correct)' || echo 'NO (both on same node)')"

# 4. Restart count
TOTAL_RESTARTS=$(oc get pods -n ${NAMESPACE} -o json | python3 -c 'import sys,json
items = json.load(sys.stdin).get("items",[])
total = sum(cs.get("restartCount",0) for i in items for cs in i.get("status",{}).get("containerStatuses",[]))
print(total)')
echo "4. Total restarts: $TOTAL_RESTARTS $([ "$TOTAL_RESTARTS" = "0" ] && echo "(clean)" || echo "(INVESTIGATE)")"

# 5. NCCL transport
NCCL_TRANSPORT=$(oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep "NCCL INFO.*Using" | head -1 | grep -o "Socket\|IB")
echo "5. NCCL transport: ${NCCL_TRANSPORT:-unknown} $([ "$NCCL_TRANSPORT" = "Socket" ] && echo "(TCP -- correct for IBM Cloud)" || echo "(check NCCL_IB_DISABLE)")"

# 6. NCCL ranks
NCCL_RANKS=$(oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -o "nranks [0-9]*" | head -1 | awk '{print $2}')
echo "6. NCCL ranks: ${NCCL_RANKS:-unknown} $([ "$NCCL_RANKS" = "16" ] && echo "(all 16 GPUs)" || echo "(expected 16)")"

# 7. Inference test
echo "7. Inference test:"
RESPONSE=$(curl -s -w "\n%{http_code}" http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL_NAME}\",\"messages\":[{\"role\":\"user\",\"content\":\"What is 2+2?\"}],\"max_tokens\":10}" 2>/dev/null)
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
echo "   HTTP status: $HTTP_CODE $([ "$HTTP_CODE" = "200" ] && echo "(success)" || echo "(FAILED)")"

echo ""
echo "========================================"

# Final verdict
if [ "$READY" = "True" ] && [ "$MULTI_NODE" = "true" ] && [ "$TOTAL_RESTARTS" = "0" ] && [ "$HTTP_CODE" = "200" ]; then
  echo "RESULT: ALL CHECKS PASSED"
else
  echo "RESULT: SOME CHECKS NEED ATTENTION"
fi
echo "========================================"
```

**Expected output**:

```
========================================
Wide EP Validation Report
========================================

1. LLMInferenceService Ready: True
2. LWS: size=2, ready=1
3. Pods on 2 distinct nodes:
   ocp-gpu-worker-h100
   ocp-gpu-worker-h200-0
   Cross-node: YES (correct)
4. Total restarts: 0 (clean)
5. NCCL transport: Socket (TCP -- correct for IBM Cloud)
6. NCCL ranks: 16 (all 16 GPUs)
7. Inference test:
   HTTP status: 200 (success)

========================================
RESULT: ALL CHECKS PASSED
========================================
```

---

## Step 13: Summary

```bash
echo ""
echo "========================================"
echo "Phase 9: Wide Expert Parallelism Complete"
echo "========================================"
echo ""
echo "Model:       DeepSeek-V2 (236B, 160 experts)"
echo "EP Size:     16 (across 2 nodes)"
echo "TP Size:     1 (no tensor parallelism)"
echo "All2All:     naive (NCCL over TCP)"
echo ""
echo "LLMInferenceService: $(oc get llmisvc ${LLMISVC_NAME} -n ${NAMESPACE} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
echo ""
echo "Pods:"
oc get pods -n ${NAMESPACE} --no-headers -o wide | grep -v download | grep -v Completed | awk '{printf "  %-55s %s  %s\n", $1, $3, $7}'
echo ""
echo "Gateway: http://${GATEWAY_IP}/${NAMESPACE}/${LLMISVC_NAME}/v1/chat/completions"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 9, you should have:

- [x] **NFS file share** expanded to 600GB+
- [x] **DeepSeek-V2** downloaded to NFS PVC (~472GB)
- [x] **LLMInferenceService** with `parallelism.expert: true` and `worker` field
- [x] **LWS** auto-created with `size: 2` (1 leader + 1 worker)
- [x] **2 pods** on separate GPU nodes (8 GPUs each, 16 total)
- [x] **EP=16** with 160 experts distributed (10 per GPU)
- [x] **NCCL** initialized with TCP transport (Socket, not IB)
- [x] **All 16 GPUs** participating in NCCL communicator
- [x] **End-to-end inference** returning valid responses
- [x] **Auto-created** InferencePool, HTTPRoute, Gateway reference

---

## Known Limitations

1. **NCCL over TCP**: IBM Cloud VFs (101e) don't support NCCL IB verbs. NCCL falls back to TCP sockets (~25-50 Gbps vs ~400 Gbps RDMA). Since EP's all-to-all runs on every forward pass, TCP is the dominant bottleneck. Expect significantly lower throughput than RDMA-native deployments.

2. **No P/D + Wide EP**: Combining P/D disaggregation with Wide EP requires 32 GPUs (16 prefill + 16 decode). This deployment has 16 GPUs total — we run EP without P/D split.

3. **Mixed GPU memory**: H100 (80GB) limits per-GPU capacity. `--gpu-memory-utilization 0.90` is set for the smaller GPU. H200 nodes (141GB) have unused memory capacity.

4. **Naive all-to-all backend**: The `deepep_high_throughput` and `deepep_low_latency` backends require NVSHMEM with IBGDA transport, which needs true RDMA PFs — not available on IBM Cloud VFs.

5. **Model loading time**: 472GB over NFS is slow — 30-60 min cold cache. Subsequent restarts are faster with page cache.

---

## Teardown

### Delete OpenShift Resources

```bash
oc delete llmisvc --all -n ${NAMESPACE}
# Wait for pods to terminate
sleep 30
oc delete namespace ${NAMESPACE} --wait=true
```

### Delete PV (if created separately)

```bash
# Only if you created model-share-pv-ep
oc delete pv model-share-pv-ep 2>/dev/null
```

### Shrink File Share (Optional)

IBM Cloud VPC file shares cannot be shrunk — only expanded. To reduce cost, delete and recreate at a smaller size:

```bash
# WARNING: This deletes the downloaded model
ibmcloud is share-mount-target-delete $FILE_SHARE_ID $MOUNT_TARGET_ID --force
sleep 30
ibmcloud is share-delete $FILE_SHARE_ID --force
```

---

## Troubleshooting

### NCCL Timeout During Initialization

If pods hang during NCCL communicator setup:

```bash
# Check if both pods can reach each other
LEADER_IP=$(oc get pod $LEADER_POD -n ${NAMESPACE} -o jsonpath='{.status.podIP}')
WORKER_IP=$(oc get pod $WORKER_POD -n ${NAMESPACE} -o jsonpath='{.status.podIP}')
echo "Leader: $LEADER_IP, Worker: $WORKER_IP"

# Test connectivity from leader to worker
oc exec -n ${NAMESPACE} $LEADER_POD -c main -- curl -s --connect-timeout 5 http://$WORKER_IP:8000/health || echo "Cannot reach worker"
```

Common causes:
- Network policy blocking pod-to-pod traffic
- NCCL_SOCKET_IFNAME set to wrong interface
- Worker pod not yet running (still loading model)

### LWS Not Created

If the LLMInferenceService is stuck and no LWS appears:

```bash
oc logs -n redhat-ods-applications deployment/kserve-controller-manager --tail=50 | grep -i "error\|lws\|leader"
```

Common causes:
- `parallelism.data` or `parallelism.dataLocal` not supported by the CRD version
- LeaderWorkerSet CRD not installed (Phase 5 Step 8e)

### Model OOM on H100

If the H100 pod crashes with OOM:

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main --previous --tail=20 2>/dev/null
```

Reduce memory usage:
- Lower `--gpu-memory-utilization` from 0.90 to 0.85
- Reduce `--max-model-len` from 8192 to 4096

### All-to-All Backend Errors

If vLLM fails with all-to-all backend errors:

```bash
oc logs -n ${NAMESPACE} $LEADER_POD -c main 2>&1 | grep -i "all2all\|nvshmem\|deepep"
```

Ensure `VLLM_ALL2ALL_BACKEND=naive` is set. The `deepep_*` backends require NVSHMEM which is not available on IBM Cloud VFs.

### SCC Rejection (CreateContainerError)

If pods fail with `CreateContainerError` related to capabilities:

```bash
oc get events -n ${NAMESPACE} --sort-by='.lastTimestamp' | tail -10
```

Verify both SAs have the SCC:

```bash
oc adm policy who-can use scc openshift-ai-llminferenceservice-multi-node-scc 2>/dev/null | grep -A5 "ServiceAccounts"
```

Both `wide-ep-sa` and `deepseek-v2-ep-kserve` should be listed.

---

## Next Steps

1. **Compare with single-node EP**: Deploy DeepSeek-V2 on a single 8-GPU node with EP=8 to measure the TCP overhead of wide EP
2. **Benchmark**: Use [inference-perf](https://github.com/kubernetes-sigs/inference-perf) to measure tokens/s with wide EP vs single-node
3. **Production RDMA**: On bare-metal or cloud with PF-based RDMA, re-enable `NCCL_IB_DISABLE=0` and switch to `deepep_high_throughput` backend for ~16x faster cross-node communication
4. **Scale up**: With 32+ GPUs, combine Wide EP (Phase 9) with P/D disaggregation (Phase 8) for the reference architecture pattern

---

**Phase 9 Complete!**

**Wide Expert Parallelism validated: DeepSeek-V2 (236B, 160 experts) distributed across 16 GPUs on 2 nodes via LWS, NCCL all-to-all over TCP, EP=16 with TP=1.**
