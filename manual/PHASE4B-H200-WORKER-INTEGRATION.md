# Phase 4B: Integrate H200 as Worker Node

## Overview

This phase integrates the H200 GPU instance as an OpenShift worker node by approving Certificate Signing Requests (CSRs) and applying H200-specific labels.

**What You'll Accomplish:**
- Approve bootstrap and serving CSRs from the H200 node
- Verify the node joins the cluster and becomes Ready
- Apply GPU, RDMA, and workload labels (H200-specific)
- Verify cluster health with all nodes

**Estimated Time**: 10-15 minutes

## How It Works

The H200 instance was created in Phase 3B with `--user-data @worker.ign` (RHCOS worker ignition config). When kubelet starts, it generates CSRs. There are two rounds:

1. **Bootstrap CSR** — kubelet requests client certificate to join
2. **Serving CSR** — kubelet requests server certificate for metrics/logs

## Pre-Flight Checks

Before starting, ensure Phases 1-3 and 3B are complete:

- [ ] OpenShift cluster deployed (Phase 2) — 3 masters Ready
- [ ] H200 instance running (Phase 3B) — with 8 cluster network attachments
- [ ] Environment file loaded: `source ~/.ibmcloud-h100-env`
- [ ] KUBECONFIG set and working

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
```

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
oc get nodes
```

Should show 3 master nodes (and possibly H100 worker if running).

```bash
ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status'
```

Should show: `running`

---

## Step-by-Step Instructions

### Step 1: Load Environment and Verify Access

```bash
source ~/.ibmcloud-h100-env
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
```

Verify key variables are set:

```bash
echo "H200_INSTANCE_ID_0: $H200_INSTANCE_ID_0"
echo "OCP_SG_ID:          $OCP_SG_ID"
```

If any are empty, recover them:

```bash
[ -z "$H200_INSTANCE_ID_0" ] && export H200_INSTANCE_ID_0=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-gpu-worker-h200-0") | .id') && sed -i '' "s/^export H200_INSTANCE_ID_0=.*/export H200_INSTANCE_ID_0=$H200_INSTANCE_ID_0/" ~/.ibmcloud-h100-env
```

Verify cluster access:

```bash
oc whoami
```

**Expected**: `system:admin`

---

### Step 2: Verify Cluster State

```bash
oc get nodes
```

**Expected:**
```
NAME                   STATUS   ROLES                         AGE   VERSION
ocp-master-0           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-1           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-2           Ready    control-plane,master,worker   Xh    v1.32.x
```

3 masters, all Ready. (H100 worker may also appear if running.)

---

### Step 3: Check for Pending CSRs

The H200 kubelet (started automatically by RHCOS + worker.ign) generates CSRs when it boots.

```bash
oc get csr
```

**Expected**: One or more CSRs with `Pending` condition:

```
NAME        AGE   SIGNERNAME                                    REQUESTOR                                                                   CONDITION
csr-xxxxx   Xm    kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
```

If no pending CSRs, the H200 may still be booting (RHCOS with cluster networks takes 10-15 minutes). Wait and retry:

```bash
sleep 60 && oc get csr | grep Pending
```

---

### Step 4: Approve Bootstrap CSR (First Round)

Approve all pending CSRs:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

**Expected:**
```
certificatesigningrequest.certificates.k8s.io/csr-xxxxx approved
```

Verify:

```bash
oc get csr
```

Should show `Approved,Issued`.

---

### Step 5: Wait for Node to Appear

After approving the bootstrap CSR, the node joins within 1-2 minutes:

```bash
oc get nodes
```

**Expected** — a new node appears:

```
NAME                     STATUS     ROLES                         AGE   VERSION
ocp-master-0             Ready      control-plane,master,worker   Xh    v1.32.x
ocp-master-1             Ready      control-plane,master,worker   Xh    v1.32.x
ocp-master-2             Ready      control-plane,master,worker   Xh    v1.32.x
ocp-gpu-worker-h200-0    NotReady   worker                        Xs    v1.32.x
```

`NotReady` is normal at this stage — the serving CSR hasn't been approved yet.

If the node doesn't appear after 2 minutes, check for more pending CSRs and approve them:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

---

### Step 6: Approve Serving CSR (Second Round)

After the node joins, kubelet generates a serving CSR. Wait 30 seconds:

```bash
sleep 30
oc get csr --no-headers | grep Pending
```

If pending CSRs exist, approve them:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

Verify all CSRs are approved:

```bash
oc get csr --no-headers | grep -v Approved
```

Should return nothing (all approved).

---

### Step 7: Wait for Node Ready

```bash
oc get nodes
```

**Expected** — all nodes Ready:

```
NAME                     STATUS   ROLES                         AGE   VERSION
ocp-master-0             Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-1             Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-2             Ready    control-plane,master,worker   Xh    v1.32.x
ocp-gpu-worker-h200-0    Ready    worker                        Xm    v1.32.x
```

If the node stays `NotReady` for more than 5 minutes, check node conditions:

```bash
oc describe node ocp-gpu-worker-h200-0 | grep -A 5 "Conditions:"
```

> **Note**: The H100 worker may also be shown (Ready or NotReady depending on whether it's running).

---

### Step 8: Save Node Name to Environment

```bash
export H200_NODE_NAME_0=$(oc get nodes --no-headers | grep h200-0 | awk '{print $1}')
echo "H200 Node: $H200_NODE_NAME_0"
```

Save to environment file:

```bash
sed -i '' "s/^export H200_NODE_NAME_0=.*/export H200_NODE_NAME_0=$H200_NODE_NAME_0/" ~/.ibmcloud-h100-env
source ~/.ibmcloud-h100-env
```

---

### Step 9: Apply Labels

#### 9a. Apply Worker and GPU Role Labels

```bash
oc label node $H200_NODE_NAME_0 \
    node-role.kubernetes.io/worker="" \
    node-role.kubernetes.io/gpu=true \
    --overwrite
```

#### 9b. Apply NVIDIA-Specific Labels

```bash
oc label node $H200_NODE_NAME_0 \
    nvidia.com/gpu.product=H200-SXM5 \
    nvidia.com/gpu.memory=141GB \
    nvidia.com/gpu.count=8 \
    --overwrite
```

#### 9c. Apply RDMA Labels

```bash
oc label node $H200_NODE_NAME_0 \
    ibm-cloud.kubernetes.io/rdma=enabled \
    ibm-cloud.kubernetes.io/cluster-network=rdma-cluster \
    ibm-cloud.kubernetes.io/cluster-network-profile=hopper-1 \
    --overwrite
```

#### 9d. Apply IBM Cloud Labels

```bash
oc label node $H200_NODE_NAME_0 \
    ibm-cloud.kubernetes.io/instance-id="$H200_INSTANCE_ID_0" \
    ibm-cloud.kubernetes.io/instance-profile="$H200_GPU_PROFILE" \
    ibm-cloud.kubernetes.io/zone="$IBMCLOUD_ZONE" \
    --overwrite
```

#### 9e. Apply Workload Type Labels

```bash
oc label node $H200_NODE_NAME_0 \
    workload.openshift.io/ai-ml=true \
    workload.openshift.io/hpc=true \
    --overwrite
```

---

### Step 10: Verify Labels

```bash
oc get node $H200_NODE_NAME_0 -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key | contains("nvidia") or contains("rdma") or contains("gpu") or contains("workload")))'
```

**Expected:**

```json
{
  "ibm-cloud.kubernetes.io/cluster-network": "rdma-cluster",
  "ibm-cloud.kubernetes.io/cluster-network-profile": "hopper-1",
  "ibm-cloud.kubernetes.io/rdma": "enabled",
  "node-role.kubernetes.io/gpu": "true",
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.memory": "141GB",
  "nvidia.com/gpu.product": "H200-SXM5",
  "workload.openshift.io/ai-ml": "true",
  "workload.openshift.io/hpc": "true"
}
```

---

### Step 11: Final Verification

#### 11a. All Nodes Ready

```bash
oc get nodes
```

Should show 4-5 nodes (3 masters + 1 H100 if running + 1 H200), all Ready.

#### 11b. Node Resource Capacity

```bash
oc describe node $H200_NODE_NAME_0 | grep -A 10 "Capacity:"
```

**Look for:**
- `cpu:` 160 (160 vCPUs)
- `memory:` ~1.75Ti

> GPU resources (`nvidia.com/gpu: 8`) will NOT appear until GPU Operator is installed (Phase 5). If Phase 5 operators are already installed, the GPU Operator will auto-discover the H200 GPUs.

#### 11c. Cluster Operators Healthy

```bash
oc get co | grep -v "True.*False.*False" | grep -v "^NAME"
```

Should return nothing (all healthy). Some operators may show `PROGRESSING: True` briefly after adding a worker — wait 5 minutes and check again.

#### 11d. CNI Pods Running on H200

```bash
oc get pods -A -o wide --field-selector spec.nodeName=$H200_NODE_NAME_0 --no-headers | head -10
```

Should show pods like `ovnkube-node`, `node-ca`, `multus` — all `Running`.

#### 11e. Verify Pod Egress Connectivity

Test external connectivity from a pod scheduled on the H200 node:

```bash
oc run egress-test-h200 --restart=Never --overrides='{"spec":{"nodeName":"ocp-gpu-worker-h200-0"}}' --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep 60
sleep 15
oc exec egress-test-h200 -- bash -c "curl -sI https://huggingface.co --connect-timeout 10 2>&1 | head -3"
oc delete pod egress-test-h200
```

**Expected**: `HTTP/2 200` — pod can reach external hosts.

**If no output or timeout**: DNS resolution from pods on the H200 is broken. Fix by restarting the OVN-Kubernetes node pod:

```bash
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=ocp-gpu-worker-h200-0
```

Wait 60 seconds for the OVN pod to restart, then retest:

```bash
sleep 60
oc get pods -n openshift-ovn-kubernetes --field-selector spec.nodeName=ocp-gpu-worker-h200-0 --no-headers
```

> **Root cause**: Same as H100 — OVN-Kubernetes may not fully initialize UDP routing on manually-added worker nodes with cluster network interfaces. Restarting `ovnkube-node` forces re-initialization of all OVN flows.

#### 11f. Summary

```bash
echo ""
echo "========================================"
echo "Phase 4B Complete"
echo "========================================"
echo ""
echo "Total Nodes: $(oc get nodes --no-headers | wc -l | tr -d ' ')"
echo ""
echo "--- $H200_NODE_NAME_0 ---"
echo "Status: $(oc get node $H200_NODE_NAME_0 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
echo "CPU:    $(oc get node $H200_NODE_NAME_0 -o jsonpath='{.status.capacity.cpu}')"
echo "Memory: $(oc get node $H200_NODE_NAME_0 -o jsonpath='{.status.capacity.memory}')"
echo ""
echo "GPU resources: Not yet (Phase 5 — GPU Operator auto-discovers on new nodes)"
echo "RDMA networks: Not yet (Phase 5 — RDMA Operators)"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 4B, you should have:

- [x] **H200 node joined cluster** via CSR approval
- [x] **Bootstrap CSR approved**
- [x] **Serving CSR approved**
- [x] **Node in Ready state**
- [x] **H200-specific GPU labels applied** (`nvidia.com/gpu.product=H200-SXM5`, `nvidia.com/gpu.memory=141GB`)
- [x] **RDMA labels applied** (`ibm-cloud.kubernetes.io/rdma=enabled`)
- [x] **Workload labels applied** (`workload.openshift.io/ai-ml=true`)
- [x] **4-5 total nodes** — 3 masters + 1 H100 (if running) + 1 H200
- [x] **All cluster operators healthy**
- [x] **Pod egress connectivity verified** on H200 node

---

## Cost

After Phase 4B:
- **Control Plane**: 3 masters (bx2-8x32) — ~$0.50-1.00/hour
- **H100 Worker** (if running): 1x gx3d-160x1792x8h100 — ~$30-40/hour
- **H200 Worker**: 1x gx3d-160x1792x8h200 — ~$30-40/hour
- **Total (all running)**: ~$60-81/hour

---

## Operations: Stop/Start H200 Node

The H200 node costs ~$30-40/hour. Stop it when not in use.

### Stop H200 (Save Costs)

```bash
ibmcloud is instance-stop $H200_INSTANCE_ID_0 --force
```

What happens:
- Node shows `NotReady` in `oc get nodes` within ~1 minute
- Cluster network attachments **persist** (not detached on stop)
- Kubelet certificates **persist** on disk
- Pods on the node are evicted after 5 minutes

### Start H200

```bash
ibmcloud is instance-start $H200_INSTANCE_ID_0
```

What happens:
- RDMA fabric reinitializes (takes 10-15 minutes)
- Kubelet starts and reconnects using existing certificates
- **No CSR approval needed** — the node is already known to the cluster
- Node returns to `Ready` automatically

### Verify After Restart

Wait 10-15 minutes after start, then:

```bash
oc get nodes
```

Should show all nodes Ready.

```bash
oc get pods -A -o wide --field-selector spec.nodeName=$H200_NODE_NAME_0 --no-headers | grep -v Running
```

Should return nothing (all pods Running).

```bash
ibmcloud is instance-cluster-network-attachments $H200_INSTANCE_ID_0 --output json | jq '. | length'
```

Should show `8` (all cluster network attachments intact).

### If Node Doesn't Rejoin After Restart

If instance was stopped for an extended period, kubelet certificates may have expired. Check for pending CSRs:

```bash
oc get csr | grep Pending
```

If pending CSRs exist, approve them:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

---

## Troubleshooting

### No CSRs Appearing

The H200 boots RHCOS with worker.ign — CSRs should appear within 1-5 minutes of the instance reaching `running` state. If no CSRs after 10 minutes:

1. Verify instance is running:
   ```bash
   ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status'
   ```

2. SSH to the instance and check kubelet:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H200_FIP_0 "sudo systemctl status kubelet"
   ```

3. Check kubelet logs for errors:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H200_FIP_0 "sudo journalctl -u kubelet --no-pager | tail -20"
   ```

4. Verify the instance can reach the cluster API:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H200_FIP_0 "curl -sk https://api-int.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443/version"
   ```

### Node Stays NotReady

Check node conditions:

```bash
oc describe node $H200_NODE_NAME_0 | grep -A 5 "Conditions:"
```

Common causes:
- CNI not initialized — wait 2-5 minutes
- Additional CSRs pending — approve them: `oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve`

### Multiple CSRs Accumulate

If many CSRs pile up (e.g., from instance restarts), approve all at once:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

---

## Next Steps

After Phase 4B completes:

1. **If Phase 5 operators are NOT installed**: Proceed to Phase 5 (`PHASE5-OPERATORS.md`). The GPU Operator and Network Operator will auto-discover GPUs and RDMA on all worker nodes (H100 + H200).

2. **If Phase 5 operators ARE already installed**: The GPU Operator and NFD will auto-discover the H200 GPUs. Verify:
   ```bash
   # Wait 5-10 minutes for operator pods to schedule on the new node
   oc get pods -n nvidia-gpu-operator -o wide | grep h200
   oc get node $H200_NODE_NAME_0 -o jsonpath='{.status.allocatable.nvidia\.com/gpu}'
   ```
   The H200 node should show `nvidia.com/gpu: 8`.

---

**Phase 4B Complete!**

**H200 joined as OpenShift worker node. Proceed to Phase 5 (if needed) or verify GPU auto-discovery.**
