# Phase 7: Tiered Prefix Cache (CPU Offloading)

## Overview

This phase deploys Qwen3-32B with CPU prefix cache offloading — extending the KV cache from GPU HBM into the H100 node's 1.75 TiB CPU RAM. This increases cache hit rates, lowers time-to-first-token (TTFT), and improves throughput for long-context or shared-prompt workloads.

This is a **fresh deployment** — if Phase 6 is currently running, it will be cleaned up and replaced with a CPU-offloading-enabled deployment.

**What You'll Accomplish:**
- Deploy 4 vLLM replicas with CPU prefix cache offloading enabled
- Get automatic Inference Gateway with prefix-cache-aware scheduling
- Validate improved performance for long-context workloads
- Inspect cache metrics

**Model**: Qwen/Qwen3-32B (32B parameters, TP=2 per replica)
**GPU Layout**: 4 replicas x 2 GPUs = 8 GPUs (full H100 node)
**Estimated Time**: 30-45 minutes (includes model download if PVC doesn't exist)

## Why CPU Offloading?

Each H100 GPU has 80GB HBM. With `gpu_memory_utilization=0.95`, ~24GB per GPU is available for KV cache. Across 2 GPUs (TP=2), that's ~48GB per replica.

The H100 node has **1.75 TiB CPU RAM**. CPU offloading extends the effective cache by ~4x — without any additional hardware.

| Scenario | Without CPU Offloading | With CPU Offloading |
|---|---|---|
| Cache capacity per replica | ~48GB (HBM only) | ~148GB (HBM + 100GB CPU) |
| Mean TTFT (high cache) | 9.0s | 6.7s (-26%) |
| Throughput (high cache) | 38,535 tok/s | 46,751 tok/s (+21%) |
| Low cache overhead | Baseline | Minimal (~1-2%) |

*Benchmark data from llm-d project using 16x H100 GPUs with Qwen3-32B.*

## Architecture

```
Client Request
      |
      v
[openshift-ai-inference Gateway]  <-- created in Step 4 (openshift-ingress)
      |                                port 80, allowedRoutes: All
      v
[HTTPRoute]                       <-- auto-created by LLMInferenceService
      |
      v
[EPP - Endpoint Picker]           <-- auto-created inference scheduler
  |   |   |   |                        (prefix-cache-aware + load-aware)
  v   v   v   v
[vLLM] [vLLM] [vLLM] [vLLM]      <-- auto-created by LLMInferenceService
 2GPU   2GPU   2GPU   2GPU          Qwen3-32B + CPU offloading on each
  |      |      |      |
  v      v      v      v
[CPU RAM cache tier]              <-- /dev/shm OffloadingConnector
```

## Pre-Flight Checks

Before starting, ensure Phase 5 is complete:

- [ ] OpenShift cluster healthy — 4 nodes Ready
- [ ] GPU Operator installed — `nvidia.com/gpu: 8` on H100
- [ ] DataScienceCluster Ready
- [ ] LLMInferenceService CRD present
- [ ] LeaderWorkerSet CRD present (Phase 5 Step 8e)
- [ ] KUBECONFIG set and working

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
export NAMESPACE=llm-d
```

```bash
oc get nodes --no-headers
```

Should show 4 nodes, all Ready.

```bash
oc get crd llminferenceservices.serving.kserve.io --no-headers
oc get crd leaderworkersets.leaderworkerset.x-k8s.io --no-headers
```

Both CRDs should exist.

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; echo " GPUs"
```

Should show `8 GPUs`.

---

# Part A: Clean Up Previous Deployment

---

> **Skip this section** if no previous llm-d deployment exists (fresh cluster after Phase 5).

## Step 1: Delete Previous Deployment

If a Phase 6 or previous Phase 7 deployment exists, delete it:

```bash
oc delete llminferenceservice qwen3-32b -n llm-d 2>/dev/null
oc delete job download-model -n llm-d 2>/dev/null
oc delete namespace llm-d --wait=true 2>/dev/null && echo "Namespace deleted" || echo "No llm-d namespace found"
```

> **Note**: The PVC with the downloaded model is deleted with the namespace. If you want to preserve it for reuse, skip the namespace deletion and only delete the LLMInferenceService.

Wait for namespace termination to complete before proceeding.

---

# Part B: Prerequisites

---

## Step 2: Create Namespace and Secrets

### 2a. Create Namespace

```bash
export NAMESPACE=llm-d
oc new-project ${NAMESPACE}
```

### 2b. Create HuggingFace Token Secret

You need a HuggingFace token to download Qwen3-32B. Get one from https://huggingface.co/settings/tokens.

```bash
export HF_TOKEN=<your-huggingface-token>
```

```bash
oc create secret generic llm-d-hf-token \
  --from-literal="HF_TOKEN=${HF_TOKEN}" \
  --namespace "${NAMESPACE}"
```

---

## Step 3: Download Model to PVC

> **Why PVC?** Each vLLM replica stores model files in ephemeral storage by default. With 4 replicas x ~65GB = 260GB total, but the H100 node only has 95Gi ephemeral storage. Using a PVC, the model is downloaded once and shared read-only across all replicas.

### 3a. Create PVC

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: llm-d-model-cache
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ibmc-vpc-block-10iops-tier
  resources:
    requests:
      storage: 100Gi
EOF
```

### 3b. Download Model

Run a one-time job to download Qwen3-32B from HuggingFace into the PVC:

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: download-model
spec:
  template:
    spec:
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
          claimName: llm-d-model-cache
      restartPolicy: Never
      nodeSelector:
        node-role.kubernetes.io/gpu: "true"
  backoffLimit: 2
EOF
```

### 3c. Wait for Model Download

This takes 10-30 minutes (~65GB download):

```bash
echo "Waiting for model download..."
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
    echo "Download failed. Check logs:"
    echo "  oc logs -n ${NAMESPACE} job/download-model"
    break
  fi
  echo -n "."
  sleep 30
done
```

### 3d. Verify Model on PVC

```bash
oc run pvc-check --restart=Never -n ${NAMESPACE} \
  --overrides='{
    "spec":{
      "nodeName":"ocp-gpu-worker-h100",
      "containers":[{
        "name":"check",
        "image":"registry.access.redhat.com/ubi9/ubi-minimal",
        "command":["ls","-la","/model-cache/hub/Qwen/Qwen3-32B/"],
        "volumeMounts":[{"name":"model","mountPath":"/model-cache"}]
      }],
      "volumes":[{
        "name":"model",
        "persistentVolumeClaim":{"claimName":"llm-d-model-cache"}
      }]
    }
  }' \
  --image=registry.access.redhat.com/ubi9/ubi-minimal 2>/dev/null
oc wait --for=jsonpath='{.status.phase}'=Succeeded pod/pvc-check -n ${NAMESPACE} --timeout=60s
oc logs pvc-check -n ${NAMESPACE}
oc delete pod pvc-check -n ${NAMESPACE}
```

Should show model files (config.json, model weight shards, tokenizer, etc.).

---

# Part C: Deploy with CPU Offloading

---

## Step 4: Create Inference Gateway

The LLMInferenceService controller's default template (with `router.gateway: {}`) expects a Gateway named `openshift-ai-inference` in `openshift-ingress`.

### 4a. Verify GatewayClass

```bash
oc get gatewayclass data-science-gateway-class \
  -o jsonpath='Accepted: {.status.conditions[?(@.type=="Accepted")].status}'; echo ""
```

**Expected**: `Accepted: True`

### 4b. Create the Inference Gateway

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

### 4c. Verify Gateway is Programmed

```bash
oc get gateway openshift-ai-inference -n openshift-ingress --no-headers
```

**Expected**: `openshift-ai-inference` with `True` (Programmed).

> **Why a separate Gateway?** The RHOAI-managed `data-science-gateway` restricts `allowedRoutes` to `openshift-ingress` and `redhat-ods-applications`, enforced by a `GatewayConfig` CR that reconciles patches back. The `openshift-ai-inference` Gateway is not owned by `GatewayConfig`, so it persists with `from: All`.

---

## Step 5: Create LLMInferenceService with CPU Offloading

This single CR creates the entire inference stack with CPU prefix cache offloading enabled:

```bash
oc apply -n ${NAMESPACE} -f - <<EOF
apiVersion: serving.kserve.io/v1alpha1
kind: LLMInferenceService
metadata:
  name: qwen3-32b
  namespace: ${NAMESPACE}
spec:
  model:
    name: Qwen/Qwen3-32B
    uri: "pvc://llm-d-model-cache/hub/Qwen/Qwen3-32B"
  parallelism:
    tensor: 2
  replicas: 4
  router:
    gateway: {}
    route: {}
    scheduler: {}
  template:
    containers:
      - name: main
        env:
          - name: HF_TOKEN
            valueFrom:
              secretKeyRef:
                name: llm-d-hf-token
                key: HF_TOKEN
          - name: VLLM_ADDITIONAL_ARGS
            value: "--tensor-parallel-size 2 --gpu-memory-utilization=0.95 --disable-uvicorn-access-log --kv-transfer-config '{\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"shared_storage_path\":\"/dev/shm/offloading\",\"num_cpu_blocks\":2500}}'"
        resources:
          limits:
            nvidia.com/gpu: "2"
            cpu: "32"
            memory: "100Gi"
        volumeMounts:
          - name: shm
            mountPath: /dev/shm
    volumes:
      - name: shm
        emptyDir:
          medium: Memory
          sizeLimit: 20Gi
EOF
```

**Key difference from Phase 6**: The `VLLM_ADDITIONAL_ARGS` includes `--kv-transfer-config` which enables the vLLM native OffloadingConnector. This offloads KV cache entries from GPU HBM to CPU RAM via `/dev/shm/offloading`.

> **Critical — Single quotes around JSON**: The `--kv-transfer-config` JSON value must be wrapped in single quotes (`'{"kv_connector":...}'`) in the env var. The controller's startup script uses `eval "vllm serve ... ${VLLM_ADDITIONAL_ARGS} ..."` — without single quotes, `eval` strips the double quotes from the JSON keys, causing a parse error (`Invalid JSON: expected value at line 1 column 1`).

> **`num_cpu_blocks: 2500`**: Required by the RHOAI vLLM build. Specifies how many KV cache blocks to allocate in CPU RAM. Each block is ~4MB for Qwen3-32B (bf16, TP=2), so 2500 blocks = ~10GB. Adjust based on available `/dev/shm` size (20Gi in this config). Without this parameter, vLLM fails with `num_cpu_blocks must be specified in kv_connector_extra_config`.

> **Important — Do NOT specify `image:` or `args:`**. The controller uses RHOAI's `registry.redhat.io/rhaiis/vllm-cuda-rhel9` image and generates a bash startup script. Use `VLLM_ADDITIONAL_ARGS` env var for extra vLLM flags.

---

## Step 6: Wait for Deployment and Verify CPU Offloading

### 6a. Watch Pod Status

```bash
watch -n 10 'oc get pods -n llm-d --no-headers'
```

Wait until all pods show `Running` (expect 2 restarts on vLLM pods due to liveness probe — model loading takes >150s, self-heals).

**Expected pods:**

| Pod | Count | Purpose |
|---|---|---|
| vLLM model server | 4 | Serve Qwen3-32B with CPU offloading (TP=2 each) |
| EPP scheduler | 1 | Prefix-cache-aware + load-aware routing |

### 6b. Verify LLMInferenceService Conditions

```bash
oc get llminferenceservice qwen3-32b -n ${NAMESPACE} -o jsonpath='{range .status.conditions[*]}{.type}: {.status}{"\n"}{end}'
```

All conditions should show `True`.

### 6c. Verify CPU Offloading is Active

Check vLLM logs for offloading initialization:

```bash
VLLM_POD=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/component=llminferenceservice-workload -o jsonpath='{.items[0].metadata.name}')
oc logs -n ${NAMESPACE} $VLLM_POD 2>&1 | grep -i -E "offload|connector|CPUOffloadingSpec"
```

**Expected** — lines confirming the OffloadingConnector and CPU offloading spec are active:
- `Creating v1 connector with name: OffloadingConnector`
- `Initializing KVConnectorBase_V1`
- `Creating offloading spec with name: CPUOffloadingSpec`
- `Initializing OffloadingSpec`

### 6d. Verify VLLM_ADDITIONAL_ARGS Applied

```bash
oc get deployment $(oc get deployment -n ${NAMESPACE} --no-headers | grep -v router-scheduler | head -1 | awk '{print $1}') -n ${NAMESPACE} \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'; echo ""
```

Should show the full args string including `--kv-transfer-config`.

---

# Part D: Validate

---

## Step 7: Test Basic Inference

Set up port-forward to the Gateway:

```bash
GW_SVC=$(oc get svc -n openshift-ingress --no-headers | grep openshift-ai-inference | awk '{print $1}' | head -1)
oc port-forward -n openshift-ingress svc/$GW_SVC 8000:80 &
sleep 3
```

List models:

```bash
curl -s localhost:8000/llm-d/qwen3-32b/v1/models | jq '.data[].id'
```

**Expected**: `"Qwen/Qwen3-32B"`

> **Path prefix**: The controller creates HTTPRoutes with path-based routing at `/<namespace>/<model-name>/...`. Bare `/v1/models` returns 404.

Send a quick inference request:

```bash
curl -s -X POST localhost:8000/llm-d/qwen3-32b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "messages": [
      {"role": "user", "content": "What is OpenShift?"}
    ],
    "max_tokens": 100
  }' | jq '.choices[0].message.content'
```

**Expected**: A coherent response.

---

## Step 8: Test Long-Context Workload (Cache Hit Comparison)

The benefit of CPU offloading is most visible with long, shared system prompts. Send multiple requests with the same long prefix:

```bash
LONG_PROMPT=$(python3 -c "print('Summarize this document: ' + 'Lorem ipsum dolor sit amet. ' * 500)")

echo "Request 1 (cold cache):"
time curl -s -X POST localhost:8000/llm-d/qwen3-32b/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"Qwen/Qwen3-32B\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 50}" | jq '.usage'

echo ""
echo "Request 2 (warm cache - should be faster TTFT):"
time curl -s -X POST localhost:8000/llm-d/qwen3-32b/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"Qwen/Qwen3-32B\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 50}" | jq '.usage'
```

The second request should show lower TTFT due to prefix cache reuse. With CPU offloading, even evicted GPU cache entries are retained in CPU RAM and can be restored faster than recomputation.

> **Expected improvement**: With ~3,000 tokens, expect a modest 10-15% improvement. The dramatic gains (-26% TTFT, +21% throughput from the benchmark table) require long shared prompts (10k+ tokens), high concurrency (many simultaneous requests), and sustained load where GPU HBM cache fills up and entries are evicted to CPU RAM. For short, unique prompts, performance is similar to baseline with minimal overhead.

---

## Step 9: Check Cache Metrics

The EPP routes requests to specific pods, so check cache metrics across **all** pods (not just one):

```bash
for pod in $(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/component=llminferenceservice-workload --no-headers | awk '{print $1}'); do
  QUERIES=$(oc exec -n ${NAMESPACE} $pod -- curl -sk https://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_queries_total" | awk '{print $2}')
  HITS=$(oc exec -n ${NAMESPACE} $pod -- curl -sk https://localhost:8000/metrics 2>/dev/null | grep "^vllm:prefix_cache_hits_total" | awk '{print $2}')
  echo "$pod: queries=$QUERIES hits=$HITS"
done
```

**Expected**: The pod that received the Step 8 requests should show non-zero queries and hits. Other pods show 0 (EPP routed all repeated prompts to the same pod for cache reuse).

For detailed cache config on a specific pod:

```bash
VLLM_POD=$(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/component=llminferenceservice-workload -o jsonpath='{.items[0].metadata.name}')
oc exec -n ${NAMESPACE} $VLLM_POD -- curl -sk https://localhost:8000/metrics 2>/dev/null | grep -i "cache"
```

Key metrics:
- `vllm:prefix_cache_queries_total` — total tokens queried against prefix cache
- `vllm:prefix_cache_hits_total` — tokens found in cache (higher = better)
- `vllm:cache_config_info` — shows `enable_prefix_caching="True"` confirming cache is active

---

## Step 10: Investigate Routing Decisions

The EPP scores each pod using `prefix-cache-scorer` (weight 2.0) + `load-aware-scorer` (weight 1.0), then picks the highest score.

**Check EPP scoring config:**

```bash
EPP_POD=$(oc get pods -n ${NAMESPACE} --no-headers | grep router-scheduler | head -1 | awk '{print $1}')
oc get pod $EPP_POD -n ${NAMESPACE} -o jsonpath='{.spec.containers[0].args}' | python3 -c "import sys,json; [print(a) for a in json.loads(sys.stdin.read()) if 'config' in a or 'scorer' in a.lower()]"
```

**Check per-pod request distribution:**

```bash
for pod in $(oc get pods -n ${NAMESPACE} -l app.kubernetes.io/component=llminferenceservice-workload --no-headers | awk '{print $1}'); do
  REQS=$(oc exec -n ${NAMESPACE} $pod -- curl -sk https://localhost:8000/metrics 2>/dev/null | grep "^vllm:request_success_total" | grep -v "0.0$")
  echo "$pod: ${REQS:-  (no requests)}"
done
```

If the EPP is routing correctly, the pod that received the first long-context request should also receive the second identical request (prefix cache hit = higher score).

> **Note**: EPP metrics on port 9090 are RBAC-locked (`--secure-serving`). Use vLLM per-pod metrics (above) to verify routing distribution.

---

## Step 11: Stop Port-Forward

```bash
kill %1 2>/dev/null
```

---

# Part E: External Access via Load Balancer (Optional)

---

## Step 12: Expose Gateway Externally

The Istio sail-operator may auto-create the `openshift-ai-inference` Gateway service as `LoadBalancer`. Check:

### 12a. Check or Patch Service Type

```bash
GW_SVC=$(oc get svc -n openshift-ingress --no-headers | grep openshift-ai-inference | awk '{print $1}' | head -1)
oc get svc $GW_SVC -n openshift-ingress -o jsonpath='Type: {.spec.type}'; echo ""
```

If already `LoadBalancer` — skip to Step 12b. If `ClusterIP`, patch it:

```bash
oc patch svc $GW_SVC -n openshift-ingress -p '{"spec":{"type":"LoadBalancer"}}'
```

### 12b. Wait for Load Balancer Provisioning

IBM Cloud VPC Load Balancer provisioning takes 2-5 minutes:

```bash
echo "Waiting for external hostname..."
while true; do
  LB_HOST=$(oc get svc $GW_SVC -n openshift-ingress \
    -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$LB_HOST" ]; then
    echo ""
    echo "Load Balancer hostname: $LB_HOST"
    break
  fi
  printf "."
  sleep 15
done
```

Wait for DNS to propagate:

```bash
echo "Waiting for DNS resolution..."
while true; do
  IP=$(dig +short "$LB_HOST" 2>/dev/null | head -1)
  if [ -n "$IP" ]; then
    echo "Resolved: $IP"
    break
  fi
  printf "."
  sleep 10
done
```

### 12c. Test External Access

```bash
export INFERENCE_URL="http://${LB_HOST}"
```

List models:

```bash
curl -s ${INFERENCE_URL}/llm-d/qwen3-32b/v1/models | jq '.data[].id'
```

**Expected**: `"Qwen/Qwen3-32B"`

Test inference with a long prompt (CPU offloading benefit):

```bash
curl -s -X POST ${INFERENCE_URL}/llm-d/qwen3-32b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "messages": [
      {"role": "user", "content": "Explain the benefits of tiered prefix caching in LLM inference serving."}
    ],
    "max_tokens": 150
  }' | jq '.choices[0].message.content'
```

**Expected**: A coherent response. This confirms the full external path:

```
Client → VPC Load Balancer (public IPs)
  → Istio Envoy proxy (port 80)
    → HTTPRoute (/llm-d/qwen3-32b/...) → EPP picks best vLLM replica
      → Qwen3-32B inference (with CPU prefix cache offloading)
```

> **In-cluster clients** can use the ClusterIP service directly:
> `http://<GW_SVC>.openshift-ingress.svc.cluster.local/llm-d/qwen3-32b/v1/chat/completions`
> (Replace `<GW_SVC>` with the gateway service name from Step 12a)

> **Cost**: VPC Load Balancer adds ~$0.02/hour. To revert:
> `oc patch svc $GW_SVC -n openshift-ingress -p '{"spec":{"type":"ClusterIP"}}'`

---

## Checkpoint Summary

At the end of Phase 7, you should have:

- [x] Model downloaded to PVC (100Gi block storage)
- [x] LLMInferenceService with CPU offloading (`--kv-transfer-config OffloadingConnector`)
- [x] 4 vLLM replicas serving Qwen3-32B (TP=2 each, 8 GPUs total)
- [x] EPP scheduler with prefix-cache-aware routing
- [x] InferencePool and HTTPRoute auto-created
- [x] `/llm-d/qwen3-32b/v1/models` returns Qwen3-32B
- [x] Inference requests return completions
- [x] Long-context requests benefit from extended cache (GPU HBM + CPU RAM)
- [x] Cache metrics visible via vLLM metrics endpoint
- [x] External access via VPC Load Balancer (optional)

---

## Cleanup

To remove Phase 7 deployment entirely:

```bash
oc delete llminferenceservice qwen3-32b -n llm-d
oc delete job download-model -n llm-d 2>/dev/null
oc delete pvc llm-d-model-cache -n llm-d 2>/dev/null
oc delete namespace llm-d
oc delete gateway openshift-ai-inference -n openshift-ingress 2>/dev/null
```

To revert to Phase 6 (without CPU offloading), recreate the LLMInferenceService with Phase 6's `VLLM_ADDITIONAL_ARGS` (without `--kv-transfer-config`):

```bash
VLLM_ADDITIONAL_ARGS: "--tensor-parallel-size 2 --gpu-memory-utilization=0.95 --disable-uvicorn-access-log"
```

See Phase 6 Step 5 for the full CR.

---

## Troubleshooting

### CPU Offloading Not Active

Check that `VLLM_ADDITIONAL_ARGS` includes the `--kv-transfer-config` flag:

```bash
VLLM_POD=$(oc get pods -n llm-d -l app.kubernetes.io/component=llminferenceservice-workload -o jsonpath='{.items[0].metadata.name}')
oc get pod $VLLM_POD -n llm-d -o jsonpath='{.spec.containers[0].env[?(@.name=="VLLM_ADDITIONAL_ARGS")].value}'; echo ""
```

If `--kv-transfer-config` is missing, the LLMInferenceService CR needs to be updated (delete and recreate with the correct `VLLM_ADDITIONAL_ARGS` from Step 5).

### No Performance Improvement

CPU offloading benefits are most visible with:
- Long shared system prompts (10k+ tokens)
- High concurrency (many simultaneous requests)
- Repeated prompts with common prefixes

For short, unique prompts, performance is similar to baseline (with minimal overhead).

### Pods Stuck Pending — Disk Pressure

The RHOAI vLLM image is ~15GB. If the H100 node's 95GB disk fills up, restart the instance to trigger CRI-O image garbage collection:

```bash
source ~/.ibmcloud-h100-env
ibmcloud is instance-stop $H100_INSTANCE_ID --force
# Wait for stopped state
ibmcloud is instance-start $H100_INSTANCE_ID
```

The node auto-rejoins in 10-15 minutes. See Phase 6 Troubleshooting for details.

### OOMKilled (CPU Memory)

If the node runs out of CPU RAM (unlikely with 1.75 TiB), reduce the offloading cache size or check node memory usage:

```bash
oc adm top node ocp-gpu-worker-h100
```

---

## Next Steps

With Phase 7 complete, you have:

1. **Intelligent inference scheduling** — load-aware + prefix-cache-aware routing
2. **Tiered prefix cache** — GPU HBM + CPU RAM for extended cache capacity
3. **Production-ready inference endpoint** — accessible via OpenShift Gateway

Future enhancements (requires additional H100 nodes):
- **P/D Disaggregation** — separate prefill and decode for large models
- **Wide Expert Parallelism** — DeepSeek-R1 across 32+ GPUs

---

**Phase 7 Complete!**

**Qwen3-32B deployed with CPU prefix cache offloading. Tiered cache extends capacity from GPU HBM into 1.75 TiB CPU RAM. Long-context workloads benefit from higher cache hit rates and lower TTFT.**
