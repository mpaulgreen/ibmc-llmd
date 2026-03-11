# Phase 6: Intelligent Inference Scheduling with LLMInferenceService

## Overview

This phase deploys Qwen3-32B on the H100 GPU worker using RHOAI's `LLMInferenceService` CRD — a single custom resource that creates the entire inference stack: vLLM model servers, Inference Gateway (EPP scheduler), InferencePool, and HTTPRoute. This replaces the manual helmfile approach from upstream llm-d, which required 3 helm charts, manual InferencePool/HTTPRoute creation, and mesh integration hacks.

**What You'll Accomplish:**
- Download Qwen3-32B model to persistent storage
- Deploy 4 vLLM replicas via a single LLMInferenceService CR
- Get automatic Inference Gateway with prefix-cache-aware scheduling
- Test inference requests through the RHOAI-managed Gateway

**Model**: Qwen/Qwen3-32B (32B parameters, TP=2 per replica)
**GPU Layout**: 4 replicas x 2 GPUs = 8 GPUs (full H100 node)
**Estimated Time**: 30-45 minutes (includes model download)

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
  |   |   |   |                        (load-aware + prefix-cache-aware)
  v   v   v   v
[vLLM] [vLLM] [vLLM] [vLLM]      <-- auto-created by LLMInferenceService
 2GPU   2GPU   2GPU   2GPU          Qwen3-32B on each
```

**Why LLMInferenceService instead of helmfile?**

| Manual helmfile approach | LLMInferenceService (this guide) |
|---|---|
| 3 helm charts + manual patches | Single CR creates everything |
| Gateway in user namespace | Reuses RHOAI-managed Gateway |
| Manual InferencePool + HTTPRoute | Auto-created by controller |
| EPP mesh integration issues | RHOAI handles mesh automatically |
| Two InferencePool API groups | Controller uses correct API group |

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
```

```bash
oc get nodes --no-headers
```

Should show 4 nodes, all Ready.

```bash
oc get crd llminferenceservices.serving.kserve.io --no-headers
```

Should show the CRD exists. If missing, verify RHOAI 3.3 DataScienceCluster is Ready.

```bash
oc get crd leaderworkersets.leaderworkerset.x-k8s.io --no-headers
```

Should show the CRD exists. If missing, create the `LeaderWorkerSetOperator` CR (Phase 5 Step 8e):

```bash
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
spec:
  managementState: Managed
EOF
```

Wait for CRD: `while ! oc get crd leaderworkersets.leaderworkerset.x-k8s.io 2>/dev/null; do sleep 5; done`

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'; echo " GPUs"
```

Should show `8 GPUs`.

```bash
oc get gateway data-science-gateway -n openshift-ingress --no-headers
```

Should show `data-science-gateway` with `True` (Programmed).

---

# Part A: Clean Up Previous Deployment

---

> **Skip this section** if no previous llm-d deployment exists (fresh cluster after Phase 5).

## Step 1: Delete Previous llm-d Namespace

If a previous helmfile-based deployment exists, delete it entirely:

```bash
oc delete namespace llm-d --wait=true 2>/dev/null && echo "Namespace deleted" || echo "No llm-d namespace found"
```

This removes all helmfile releases, manual patches (PeerAuthentication, DestinationRule, EnvoyFilter), InferencePools, HTTPRoutes, PVCs, and secrets.

### 1b. Verify Cleanup

```bash
oc get namespace llm-d 2>&1
```

**Expected**: `Error from server (NotFound): namespaces "llm-d" not found`

Wait for namespace termination to complete before proceeding (may take 1-2 minutes if Gateway pods need cleanup).

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

# Part C: Deploy LLMInferenceService

---

## Step 4: Create Inference Gateway

The LLMInferenceService controller's default template (with `router.gateway: {}`) expects a Gateway named `openshift-ai-inference` in `openshift-ingress`. This Gateway does not exist by default — RHOAI creates `data-science-gateway` instead, which is locked down by a `GatewayConfig` controller. We create `openshift-ai-inference` separately with open `allowedRoutes`.

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

> **Why a separate Gateway?** The RHOAI-managed `data-science-gateway` restricts `allowedRoutes` to `openshift-ingress` and `redhat-ods-applications`, enforced by a `GatewayConfig` CR that reconciles patches back. The `openshift-ai-inference` Gateway is not owned by `GatewayConfig`, so it persists with `from: All`. This is the name the LLMInferenceService controller expects when `router.gateway: {}` is specified.

---

## Step 5: Create LLMInferenceService

This single CR creates the entire inference stack — vLLM deployments, InferencePool, EPP scheduler, and HTTPRoute:

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
            value: "--tensor-parallel-size 2 --gpu-memory-utilization=0.95 --disable-uvicorn-access-log"
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

**What each field does:**

| Field | Value | Purpose |
|---|---|---|
| `model.name` | `Qwen/Qwen3-32B` | Served model name (appears in `/v1/models`) |
| `model.uri` | `pvc://llm-d-model-cache/...` | Model location on PVC |
| `parallelism.tensor` | `2` | Tensor parallelism metadata (does NOT inject `--tensor-parallel-size` — use `VLLM_ADDITIONAL_ARGS`) |
| `replicas` | `4` | 4 replicas x 2 GPUs = 8 GPUs total |
| `router.gateway: {}` | (empty) | Controller auto-creates a Gateway in the `llm-d` namespace |
| `router.route: {}` | (empty) | Controller auto-creates HTTPRoute |
| `router.scheduler: {}` | (empty) | Controller auto-creates EPP + InferencePool |
| `VLLM_ADDITIONAL_ARGS` | `--tensor-parallel-size 2 ...` | Extra vLLM args injected into controller's startup script |
| `nvidia.com/gpu: "2"` | per replica | 2 GPUs per replica (matches TP=2) |
| `/dev/shm` volume | `20Gi tmpfs` | Required for PyTorch NCCL with TP>1 |

> **Important — Do NOT specify `image:` or `args:`**. The controller uses RHOAI's `registry.redhat.io/rhaiis/vllm-cuda-rhel9` image and generates a bash startup script (`/bin/bash -c "..."`) that includes RoCE HCA auto-discovery, TLS setup, and `vllm serve`. Specifying a custom `image:` (e.g., upstream `ghcr.io/llm-d/llm-d-cuda`) will fail because the entrypoint is incompatible with the controller's command template. Specifying `args:` will overwrite the generated bash script. Use `VLLM_ADDITIONAL_ARGS` env var instead — the controller's script expands `${VLLM_ADDITIONAL_ARGS}` into the `vllm serve` command.

> **Note on `router.gateway: {}`**: This creates a namespace-local Gateway in `llm-d` (with its own Istio proxy pod). We use this instead of referencing the RHOAI-managed `data-science-gateway` because that Gateway's `allowedRoutes` is locked down by a `GatewayConfig` controller that reconciles changes back.

---

## Step 6: Wait for Deployment

### 6a. Check LLMInferenceService Status

```bash
oc get llminferenceservice qwen3-32b -n ${NAMESPACE}
```

### 6b. Watch Pod Creation

```bash
watch -n 10 'oc get pods -n llm-d --no-headers'
```

Wait until all pods show `Running`. The controller creates:

| Pod | Count | Purpose |
|---|---|---|
| vLLM model server | 4 | Serve Qwen3-32B (TP=2 each) |
| EPP scheduler | 1 | Load-aware + prefix-cache-aware routing |

> **Note**: The Gateway pod runs in `openshift-ingress` (created by Step 4b), not in the `llm-d` namespace.

### 6c. Verify Auto-Created Resources

The LLMInferenceService controller auto-creates these resources:

```bash
echo "=== InferencePool ==="
oc get inferencepool -n ${NAMESPACE} --no-headers

echo ""
echo "=== HTTPRoute ==="
oc get httproute -n ${NAMESPACE} --no-headers

echo ""
echo "=== Deployments ==="
oc get deployment -n ${NAMESPACE} --no-headers

echo ""
echo "=== Services ==="
oc get svc -n ${NAMESPACE} --no-headers
```

### 6d. Check vLLM Startup

If pods are slow to start, check logs:

```bash
oc logs -n ${NAMESPACE} -l app.kubernetes.io/component=llminferenceservice-workload --tail=20 2>/dev/null || \
  oc logs -n ${NAMESPACE} $(oc get pods -n ${NAMESPACE} --no-headers | grep -v router-scheduler | grep -v Completed | head -1 | awk '{print $1}') --tail=20
```

Look for: `INFO: Application startup complete` or model loading progress.

### 6e. Verify LLMInferenceService Conditions

```bash
oc get llminferenceservice qwen3-32b -n ${NAMESPACE} -o jsonpath='{range .status.conditions[*]}{.type}: {.status} ({.reason}){"\n"}{end}'
```

All conditions should show `True`.

---

# Part D: Test and Validate

---

## Step 7: Identify Gateway Endpoint

The HTTPRoute references the `openshift-ai-inference` Gateway created in Step 4:

```bash
oc get gateway openshift-ai-inference -n openshift-ingress --no-headers
```

**Expected**: `openshift-ai-inference` with `True` (Programmed).

Find the Gateway service:

```bash
GW_SVC=$(oc get svc -n openshift-ingress --no-headers | grep openshift-ai-inference | awk '{print $1}' | head -1)
echo "Gateway service: $GW_SVC"
```

For local testing, port-forward to the Gateway:

```bash
oc port-forward -n openshift-ingress svc/$GW_SVC 8000:80 &
```

Wait a moment for port-forward to establish.

> **Alternative**: If the HTTPRoute has a hostname, you may need to pass it as a `Host` header. Check:
> ```bash
> oc get httproute -n ${NAMESPACE} -o jsonpath='{.items[0].spec.hostnames}'; echo ""
> ```
> If hostnames are set, add `-H "Host: <hostname>"` to curl commands below.

---

## Step 8: Test Model Endpoint

```bash
curl -s localhost:8000/llm-d/qwen3-32b/v1/models | jq '.data[].id'
```

**Expected**: `"Qwen/Qwen3-32B"`

> **Path prefix**: The controller creates the HTTPRoute with path-based routing at `/<namespace>/<model-name>/...`. All API calls must use this prefix (e.g., `/llm-d/qwen3-32b/v1/models`). Bare `/v1/models` returns 404.

---

## Step 9: Send Inference Request

```bash
curl -s -X POST localhost:8000/llm-d/qwen3-32b/v1/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "prompt": "Explain the theory of relativity in simple terms:",
    "max_tokens": 100
  }' | jq '.choices[0].text'
```

**Expected**: A coherent text completion.

---

## Step 10: Test Chat Completions

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

---

## Step 11: Verify Prefix-Cache-Aware Routing

Send the same prompt twice — the scheduler should route the second request to the same replica (prefix cache hit):

```bash
for i in 1 2; do
  echo "Request $i:"
  curl -s -X POST localhost:8000/llm-d/qwen3-32b/v1/completions \
    -H "Content-Type: application/json" \
    -d '{
      "model": "Qwen/Qwen3-32B",
      "prompt": "The history of artificial intelligence begins in",
      "max_tokens": 20
    }' | jq '{id, model}'
  echo ""
done
```

### Investigating Routing Decisions

The EPP (Endpoint Picker) scores each pod using `prefix-cache-scorer` (weight 2.0) + `load-aware-scorer` (weight 1.0), then picks the highest score. Per-request routing logs are not emitted at default log level, and EPP metrics (port 9090) are RBAC-locked (`--secure-serving`). Use vLLM per-pod metrics instead:

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

If the EPP is routing correctly, the pod that received the first request should also receive the second identical request (prefix cache hit → higher score). Pods with no matching prefix will show fewer or zero requests.

---

## Step 12: Stop Port-Forward

```bash
kill %1 2>/dev/null
```

---

# Part E: External Access via Load Balancer (Optional)

---

## Step 13: Expose Gateway Externally

The Istio sail-operator may auto-create the `openshift-ai-inference` Gateway service as `LoadBalancer`. Check:

### 13a. Check or Patch Service Type

```bash
GW_SVC=$(oc get svc -n openshift-ingress --no-headers | grep openshift-ai-inference | awk '{print $1}' | head -1)
oc get svc $GW_SVC -n openshift-ingress -o jsonpath='Type: {.spec.type}'; echo ""
```

If already `LoadBalancer` — skip to Step 13b. If `ClusterIP`, patch it:

```bash
oc patch svc $GW_SVC -n openshift-ingress -p '{"spec":{"type":"LoadBalancer"}}'
```

### 13b. Wait for Load Balancer Provisioning

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

### 13c. Test External Access

```bash
export INFERENCE_URL="http://${LB_HOST}"
```

```bash
curl -s ${INFERENCE_URL}/llm-d/qwen3-32b/v1/models | jq '.data[].id'
```

**Expected**: `"Qwen/Qwen3-32B"`

```bash
curl -s -X POST ${INFERENCE_URL}/llm-d/qwen3-32b/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-32B",
    "messages": [
      {"role": "user", "content": "What is OpenShift?"}
    ],
    "max_tokens": 100
  }' | jq '.choices[0].message.content'
```

> **In-cluster clients** can use the ClusterIP service directly:
> `http://<GW_SVC>.openshift-ingress.svc.cluster.local/llm-d/qwen3-32b/v1/chat/completions`
> (Replace `<GW_SVC>` with the gateway service name from Step 13a)

> **Cost**: VPC Load Balancer adds ~$0.02/hour. To revert:
> `oc patch svc $GW_SVC -n openshift-ingress -p '{"spec":{"type":"ClusterIP"}}'`

---

## Checkpoint Summary

At the end of Phase 6, you should have:

- [x] Model downloaded to PVC (100Gi block storage)
- [x] LLMInferenceService CR created (single resource)
- [x] 4 vLLM replicas serving Qwen3-32B (TP=2 each, 8 GPUs total)
- [x] EPP (inference scheduler) auto-created and running
- [x] InferencePool auto-created
- [x] HTTPRoute auto-created, referencing RHOAI Gateway
- [x] `/llm-d/qwen3-32b/v1/models` returns Qwen3-32B
- [x] Inference requests return completions
- [x] Prefix-cache-aware routing active

---

## Cleanup

To remove Phase 6 deployment:

```bash
oc delete llminferenceservice qwen3-32b -n llm-d
oc delete job download-model -n llm-d 2>/dev/null
oc delete pvc llm-d-model-cache -n llm-d 2>/dev/null
oc delete namespace llm-d
oc delete gateway openshift-ai-inference -n openshift-ingress 2>/dev/null
```

---

## Troubleshooting

### LLMInferenceService Not Creating Resources

Check controller logs:

```bash
oc logs -n redhat-ods-applications deployment/kserve-controller-manager --tail=30 2>/dev/null | grep -i llm
```

If no controller is handling LLMInferenceService, check that the DataScienceCluster has KServe enabled:

```bash
oc get datasciencecluster -A -o jsonpath='{range .items[*]}{.spec.components.kserve.managementState}{"\n"}{end}'
```

**Expected**: `Managed`

### LeaderWorkerSet CRD Missing

If you see `no matches for kind "LeaderWorkerSet" in version "leaderworkerset.x-k8s.io/v1"`:

```bash
oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: LeaderWorkerSetOperator
metadata:
  name: cluster
spec:
  managementState: Managed
EOF
```

Wait for the CRD to appear, then the LLMInferenceService controller will auto-reconcile.

### HTTPRoute Rejected — NotAllowedByListeners

If the HTTPRoute status shows `namespace "llm-d" is not allowed by the parent`, the Gateway's `allowedRoutes` doesn't include the `llm-d` namespace.

**Cause**: The LLMInferenceService referenced the wrong Gateway (e.g., `data-science-gateway` which restricts `allowedRoutes` via `GatewayConfig`).

**Fix**: Ensure the `openshift-ai-inference` Gateway exists (Step 4b) with `allowedRoutes.namespaces.from: All`, and that the CR uses `router.gateway: {}` (which defaults to `openshift-ai-inference`).

### HTTPRoute References Non-Existent Gateway

If you see `Managed HTTPRoute references non-existent Gateway openshift-ingress/openshift-ai-inference`:

**Fix**: Create the Gateway (Step 4b):

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

### vLLM Pods CrashLoopBackOff — `/bin/bash: --: invalid option`

This means a custom `image:` or `args:` was specified that conflicts with the controller's bash startup script. Fix:

1. Do NOT specify `image:` — let the controller use RHOAI's `registry.redhat.io/rhaiis/vllm-cuda-rhel9`
2. Do NOT specify `args:` — the controller generates a full bash script; custom args overwrite it
3. Use `VLLM_ADDITIONAL_ARGS` env var for extra vLLM flags (e.g., `--tensor-parallel-size 2`)

Delete and recreate the LLMInferenceService with the correct CR from Step 5.

### Controller Doesn't Set `--tensor-parallel-size`

The `parallelism.tensor: 2` field is metadata — the controller does NOT inject `--tensor-parallel-size` into the vLLM command. You must set it explicitly via:

```yaml
env:
  - name: VLLM_ADDITIONAL_ARGS
    value: "--tensor-parallel-size 2"
```

The controller's startup script expands `${VLLM_ADDITIONAL_ARGS}` into the `vllm serve` command.

### vLLM Pods OOMKilled

Qwen3-32B needs ~64GB GPU memory (FP16). With TP=2 and 2x H100 80GB, there's headroom. If OOMKilled, check resource limits:

```bash
oc describe pod -n llm-d <pod-name> | grep -A 5 "Limits:"
```

### Pods Stuck Pending — Insufficient GPU

Verify 8 GPUs are allocatable and not consumed by other workloads:

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='Allocatable: {.status.allocatable.nvidia\.com/gpu}{"\n"}Allocated: ' && \
  oc describe node ocp-gpu-worker-h100 | grep "nvidia.com/gpu" | tail -1
```

### EPP Init CrashLoopBackOff

If the EPP pod fails to start, check its logs:

```bash
EPP_POD=$(oc get pods -n llm-d --no-headers | grep epp | head -1 | awk '{print $1}')
oc logs -n llm-d $EPP_POD --all-containers --tail=30
```

Common causes:
- InferencePool not ready yet — wait and it will self-resolve
- Missing CRD — verify `oc api-resources --api-group=inference.networking.x-k8s.io`

### Pods Stuck Pending — Disk Pressure on H100

If you see `untolerated taint {node.kubernetes.io/disk-pressure: }`, the H100 node's 95GB ephemeral storage is full (container images, logs). The RHOAI vLLM image alone is ~15GB.

**Fix**: Restart the H100 instance to trigger CRI-O image garbage collection:

```bash
source ~/.ibmcloud-h100-env
ibmcloud is instance-stop $H100_INSTANCE_ID --force
# Wait for stopped state
ibmcloud is instance-start $H100_INSTANCE_ID
```

The node auto-rejoins the cluster in 5-15 minutes (RDMA fabric init takes 10-15 min). No CSR approval needed for short stops. Monitor:

```bash
watch -n 15 'oc get node ocp-gpu-worker-h100 --no-headers'
```

### Model Download Timeout

If the download job fails, check logs and retry:

```bash
oc logs -n llm-d job/download-model --tail=20
oc delete job download-model -n llm-d
# Re-run Step 3b
```

---

## Next Steps

After Phase 6 completes:

1. **Phase 7**: Add Tiered Prefix Cache (CPU offloading) for improved long-context performance
2. **Benchmarking**: Use inference-perf to measure throughput and latency

---

**Phase 6 Complete!**

**4 vLLM replicas serving Qwen3-32B with intelligent prefix-cache-aware scheduling via LLMInferenceService. All mesh integration managed automatically by RHOAI.**
