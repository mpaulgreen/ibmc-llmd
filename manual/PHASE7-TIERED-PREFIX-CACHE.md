# Phase 7: Tiered Prefix Cache (CPU Offloading)

## Overview

This phase adds CPU prefix cache offloading to the inference scheduling stack deployed in Phase 6. By offloading prefix cache entries from GPU HBM to the H100 node's 1.75 TiB CPU RAM, you get higher cache hit rates, lower time-to-first-token (TTFT), and improved throughput — especially for long-context or shared-prompt workloads.

**What You'll Accomplish:**
- Enable CPU prefix cache offloading in vLLM
- Configure tiered cache scoring in the Inference Gateway
- Validate improved performance for long-context workloads

**Prerequisite**: Phase 6 must be deployed and working (LLMInferenceService with 4 vLLM replicas).

**Estimated Time**: 15-20 minutes

## Why CPU Offloading?

Each H100 GPU has 80GB HBM. With `gpu_memory_utilization=0.95`, ~24GB per GPU is available for KV cache. Across 2 GPUs (TP=2), that's ~48GB per replica.

The H100 node has **1.75 TiB CPU RAM**. Allocating 100GB for CPU cache per replica extends the effective cache by ~4x — without any additional hardware.

| Scenario | Without CPU Offloading | With CPU Offloading |
|---|---|---|
| Cache capacity per replica | ~48GB (HBM only) | ~148GB (HBM + 100GB CPU) |
| Mean TTFT (high cache) | 9.0s | 6.7s (-26%) |
| Throughput (high cache) | 38,535 tok/s | 46,751 tok/s (+21%) |
| Low cache overhead | Baseline | Minimal (~1-2%) |

*Benchmark data from llm-d project using 16x H100 GPUs with Qwen3-32B.*

## Pre-Flight Checks

- [ ] Phase 6 deployed and working (LLMInferenceService with 4 vLLM replicas + EPP)
- [ ] Inference requests returning completions
- [ ] KUBECONFIG set

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
export NAMESPACE=llm-d
oc get llminferenceservice qwen3-32b -n $NAMESPACE --no-headers
oc get pods -n $NAMESPACE --no-headers | grep Running | wc -l
```

Should show 5+ running pods (4 vLLM + 1 EPP). The Gateway pod is in `openshift-ingress`.

---

# Part A: Enable CPU Prefix Cache Offloading

---

## Step 1: Understand the Options

Two connectors are available:

| Connector | Description | Recommended? |
|---|---|---|
| **vLLM OffloadingConnector** | Native vLLM CPU offloading. Simpler setup. | Yes — start here |
| **LMCache Connector** | External cache manager. More features, slightly more complex. | Alternative |

We'll use the **vLLM native OffloadingConnector** (simpler, fewer dependencies).

---

## Step 2: Enable CPU Offloading in LLMInferenceService

Patch the LLMInferenceService to add CPU offloading args via `VLLM_ADDITIONAL_ARGS`:

> **Important**: Do NOT use `args:` — it overwrites the controller's bash startup script. Use `VLLM_ADDITIONAL_ARGS` env var instead (see Phase 6 Step 5 notes).

```bash
oc patch llminferenceservice qwen3-32b -n ${NAMESPACE} --type merge -p '{
  "spec": {
    "template": {
      "containers": [{
        "name": "main",
        "env": [
          {
            "name": "HF_TOKEN",
            "valueFrom": {"secretKeyRef": {"name": "llm-d-hf-token", "key": "HF_TOKEN"}}
          },
          {
            "name": "VLLM_ADDITIONAL_ARGS",
            "value": "--tensor-parallel-size 2 --gpu-memory-utilization=0.95 --disable-uvicorn-access-log --kv-transfer-config {\"kv_connector\":\"OffloadingConnector\",\"kv_role\":\"kv_both\",\"kv_connector_extra_config\":{\"shared_storage_path\":\"/dev/shm/offloading\"}}"
          }
        ]
      }]
    }
  }
}'
```

> **Note**: The `--kv-transfer-config` arg enables the vLLM native OffloadingConnector for CPU prefix cache offloading. The full env var includes all previous flags (`--tensor-parallel-size 2`, etc.) because the `merge` patch replaces the entire env list.

Verify the LLMInferenceService still shows 4 replicas:

```bash
oc get llminferenceservice qwen3-32b -n ${NAMESPACE} -o jsonpath='Replicas: {.spec.replicas}'; echo ""
```

---

## Step 3: Verify CPU Offloading is Active

### 3a. Wait for Pods Ready

```bash
echo "Waiting for vLLM pods..."
while true; do
  READY=$(oc get pods -n llm-d -l app=qwen3-32b --no-headers 2>/dev/null | grep Running | wc -l | tr -d ' ')
  echo "  Running: $READY (expected: 4)"
  [ "$READY" -ge 4 ] && break
  sleep 15
done
echo "All vLLM pods ready."
```

### 3b. Check vLLM Logs for CPU Offloading

```bash
VLLM_POD=$(oc get pods -n llm-d -l app=qwen3-32b -o jsonpath='{.items[0].metadata.name}')
oc logs -n llm-d $VLLM_POD --tail=50 | grep -i -E "cpu|offload|cache"
```

Look for lines indicating CPU offloading is enabled, such as:
- `CPU offloading connector initialized`
- `cpu_bytes_to_use` configuration

---

# Part B: Configure Tiered Cache Scoring

---

## Step 4: Update InferencePool Configuration

The InferencePool's EPP (endpoint picker) needs to know about the CPU cache tier to make smarter routing decisions.

### 4a. Check Current InferencePool

```bash
oc get inferencepool -n llm-d -o yaml | grep -A 20 "spec:"
```

### 4b. Update EPP Scheduler for Tiered Scoring

The LLMInferenceService auto-created the EPP scheduler. To enable tiered cache scoring, patch the EPP deployment's environment:

```bash
EPP_DEPLOY=$(oc get deployment -n ${NAMESPACE} --no-headers | grep epp | awk '{print $1}')
oc set env deployment/$EPP_DEPLOY -n ${NAMESPACE} \
  SCORER_WEIGHTS="QueueScorer:2,KVCacheUtilizationScorer:2,GPUPrefixCacheScorer:1,CPUPrefixCacheScorer:1"
```

The tiered cache configuration uses weights **2:2:1:1** (Queue Scorer : KV Cache Utilization : GPU Prefix Cache : CPU Prefix Cache). The CPU cache is essentially a superset of GPU cache, so combined weight of GPU+CPU prefix scorers equals 2.

> **Note**: If the EPP does not support the `SCORER_WEIGHTS` env var, check the EPP deployment for the correct configuration method:
> ```bash
> oc get deployment $EPP_DEPLOY -n ${NAMESPACE} -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -m json.tool
> ```

### 4c. Verify EPP Restarted

```bash
oc get pods -n llm-d | grep epp
```

EPP pod should have restarted with updated config.

---

# Part C: Validate

---

## Step 5: Test Basic Inference

Verify the stack still works after the changes:

```bash
GW_SVC=$(oc get svc -n openshift-ingress --no-headers | grep openshift-ai-inference | awk '{print $1}' | head -1)
oc port-forward -n openshift-ingress svc/$GW_SVC 8000:80 &
sleep 3
```

```bash
curl -s localhost:8000/v1/models | jq '.data[].id'
```

**Expected**: `"Qwen/Qwen3-32B"`

---

## Step 6: Test Long-Context Workload (High Cache Scenario)

The benefit of CPU offloading is most visible with long, shared system prompts. Send multiple requests with the same long prefix:

```bash
LONG_PROMPT=$(python3 -c "print('Summarize this document: ' + 'Lorem ipsum dolor sit amet. ' * 500)")

echo "Request 1 (cold cache):"
time curl -s -X POST localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"Qwen/Qwen3-32B\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 50}" | jq '.usage'

echo ""
echo "Request 2 (warm cache - should be faster TTFT):"
time curl -s -X POST localhost:8000/v1/completions \
  -H "Content-Type: application/json" \
  -d "{\"model\": \"Qwen/Qwen3-32B\", \"prompt\": \"$LONG_PROMPT\", \"max_tokens\": 50}" | jq '.usage'
```

The second request should show lower TTFT due to prefix cache reuse (either from GPU HBM or CPU RAM tier).

---

## Step 7: Check Cache Metrics

```bash
VLLM_POD=$(oc get pods -n llm-d -l app=qwen3-32b -o jsonpath='{.items[0].metadata.name}')
curl -s $(oc get pod $VLLM_POD -n llm-d -o jsonpath='{.status.podIP}'):8000/metrics | grep -i "cache"
```

Look for cache hit/miss metrics from vLLM.

---

## Step 8: Stop Port-Forward

```bash
kill %1 2>/dev/null
```

---

## Checkpoint Summary

At the end of Phase 7, you should have:

- [x] CPU prefix cache offloading enabled in vLLM
- [x] Tiered cache scoring configured in InferencePool (GPU + CPU tiers)
- [x] Inference requests returning completions
- [x] Long-context requests benefiting from extended cache capacity
- [x] Cache metrics visible in vLLM metrics endpoint

---

## Cleanup

To remove Phase 7 changes and revert to Phase 6 baseline, reset `VLLM_ADDITIONAL_ARGS` to remove the CPU offloading config:

```bash
oc patch llminferenceservice qwen3-32b -n llm-d --type merge -p '{
  "spec": {
    "template": {
      "containers": [{
        "name": "main",
        "env": [
          {
            "name": "HF_TOKEN",
            "valueFrom": {"secretKeyRef": {"name": "llm-d-hf-token", "key": "HF_TOKEN"}}
          },
          {
            "name": "VLLM_ADDITIONAL_ARGS",
            "value": "--tensor-parallel-size 2 --gpu-memory-utilization=0.95 --disable-uvicorn-access-log"
          }
        ]
      }]
    }
  }
}'
```

To remove everything (Phase 6 + 7):

```bash
oc delete llminferenceservice qwen3-32b -n llm-d
oc delete job download-model -n llm-d 2>/dev/null
oc delete pvc llm-d-model-cache -n llm-d 2>/dev/null
oc delete namespace llm-d
```

---

## Troubleshooting

### CPU Offloading Not Active

Check vLLM pod args:

```bash
VLLM_POD=$(oc get pods -n llm-d -l app=qwen3-32b -o jsonpath='{.items[0].metadata.name}')
oc get pod $VLLM_POD -n llm-d -o jsonpath='{.spec.containers[0].args}' | jq '.'
```

Look for CPU offloading related args. If missing, the kustomize overlay may not have been applied correctly.

### No Performance Improvement

CPU offloading benefits are most visible with:
- Long shared system prompts (10k+ tokens)
- High concurrency (many simultaneous requests)
- Repeated prompts with common prefixes

For short, unique prompts, performance is similar to baseline (with minimal overhead).

### OOMKilled (CPU Memory)

If the node runs out of CPU RAM (unlikely with 1.75 TiB), reduce `cpu_bytes_to_use`:

```bash
# Check current node memory usage
oc adm top node ocp-gpu-worker-h100
```

---

## Next Steps

With Phases 6 and 7 complete, you have:

1. **Intelligent inference scheduling** — load-aware + prefix-cache-aware routing
2. **Tiered prefix cache** — GPU HBM + CPU RAM for extended cache capacity
3. **Production-ready inference endpoint** — accessible via OpenShift Gateway

Future enhancements (requires additional H100 nodes):
- **P/D Disaggregation** — separate prefill and decode for large models
- **Wide Expert Parallelism** — DeepSeek-R1 across 32+ GPUs

---

**Phase 7 Complete!**

**CPU prefix cache offloading active. Tiered cache scoring configured. Long-context workloads benefit from extended cache capacity (GPU HBM + CPU RAM).**
