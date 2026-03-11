# Phase 4: Integrate H100 as Worker Node

## Overview

This phase integrates the H100 GPU instance as an OpenShift worker node by approving Certificate Signing Requests (CSRs) and applying labels.

**What You'll Accomplish:**
- Approve bootstrap and serving CSRs from the H100
- Verify the node joins the cluster and becomes Ready
- Apply GPU, RDMA, and workload labels
- Verify cluster health with 4 nodes

**Estimated Time**: 10-15 minutes

## How It Works

The H100 was created in Phase 3 with `--user-data @worker.ign` (RHCOS worker ignition config). This ignition config:
- Configures kubelet to join the OpenShift cluster
- Includes the SSH public key (from `install-config.yaml` sshKey field)
- Starts kubelet automatically on boot

When kubelet starts, it generates CSRs requesting permission to join the cluster. We approve these CSRs, and the node joins automatically. There are two rounds:

1. **Bootstrap CSR** — kubelet requests client certificate to join
2. **Serving CSR** — kubelet requests server certificate for metrics/logs

## Pre-Flight Checks

Before starting, ensure Phases 1-3 are complete:

- [ ] OpenShift cluster deployed (Phase 2) — 3 masters Ready
- [ ] H100 instance running (Phase 3) — with 8 cluster network attachments
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

Should show 3 master nodes, all Ready.

```bash
ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status'
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
echo "H100_INSTANCE_ID: $H100_INSTANCE_ID"
echo "OCP_SG_ID:        $OCP_SG_ID"
```

If any are empty, recover them:

```bash
[ -z "$H100_INSTANCE_ID" ] && export H100_INSTANCE_ID=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-gpu-worker-h100") | .id') && sed -i '' "s/^export H100_INSTANCE_ID=.*/export H100_INSTANCE_ID=$H100_INSTANCE_ID/" ~/.ibmcloud-h100-env
[ -z "$OCP_SG_ID" ] && export OCP_SG_ID=$(ibmcloud is security-groups --output json | jq -r '.[] | select(.name=="ocp-h100-cluster-sg") | .id') && sed -i '' "s/^export OCP_SG_ID=.*/export OCP_SG_ID=$OCP_SG_ID/" ~/.ibmcloud-h100-env
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
NAME           STATUS   ROLES                         AGE   VERSION
ocp-master-0   Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-1   Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-2   Ready    control-plane,master,worker   Xh    v1.32.x
```

3 masters, all Ready.

---

### Step 3: Check for Pending CSRs

The H100 kubelet (started automatically by RHCOS + worker.ign) generates CSRs when it boots.

```bash
oc get csr
```

**Expected**: One or more CSRs with `Pending` condition:

```
NAME        AGE   SIGNERNAME                                    REQUESTOR                                                                   CONDITION
csr-xxxxx   Xm    kubernetes.io/kube-apiserver-client-kubelet   system:serviceaccount:openshift-machine-config-operator:node-bootstrapper   Pending
```

If no pending CSRs, the H100 may still be booting (RHCOS with cluster networks takes 10-15 minutes). Wait and retry:

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

**Expected** — a 4th node appears:

```
NAME                   STATUS     ROLES                         AGE   VERSION
ocp-master-0           Ready      control-plane,master,worker   Xh    v1.32.x
ocp-master-1           Ready      control-plane,master,worker   Xh    v1.32.x
ocp-master-2           Ready      control-plane,master,worker   Xh    v1.32.x
ocp-gpu-worker-h100    NotReady   worker                        Xs    v1.32.x
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

**Expected** — all 4 nodes Ready:

```
NAME                   STATUS   ROLES                         AGE   VERSION
ocp-master-0           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-1           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-2           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-gpu-worker-h100    Ready    worker                        Xm    v1.32.x
```

If the node stays `NotReady` for more than 5 minutes, check node conditions:

```bash
oc describe node ocp-gpu-worker-h100 | grep -A 5 "Conditions:"
```

---

### Step 8: Save Node Name to Environment

```bash
export H100_NODE_NAME=$(oc get nodes --no-headers | grep h100 | awk '{print $1}')
echo "H100 Node Name: $H100_NODE_NAME"
```

Save to environment file:

```bash
sed -i '' "s/^export H100_NODE_NAME=.*/export H100_NODE_NAME=$H100_NODE_NAME/" ~/.ibmcloud-h100-env
source ~/.ibmcloud-h100-env
```

---

### Step 9: Apply Labels

#### 9a. Apply Worker Role Label (if not present)

```bash
oc label node $H100_NODE_NAME node-role.kubernetes.io/worker="" --overwrite
```

#### 9b. Apply GPU Role Label

```bash
oc label node $H100_NODE_NAME node-role.kubernetes.io/gpu=true --overwrite
```

#### 9c. Apply NVIDIA-Specific Labels

```bash
oc label node $H100_NODE_NAME \
    nvidia.com/gpu.product=H100-SXM5 \
    nvidia.com/gpu.memory=80GB \
    nvidia.com/gpu.count=8 \
    --overwrite
```

#### 9d. Apply RDMA Labels

```bash
oc label node $H100_NODE_NAME \
    ibm-cloud.kubernetes.io/rdma=enabled \
    ibm-cloud.kubernetes.io/cluster-network=rdma-cluster \
    ibm-cloud.kubernetes.io/cluster-network-profile=hopper-1 \
    --overwrite
```

#### 9e. Apply IBM Cloud Labels

```bash
oc label node $H100_NODE_NAME \
    ibm-cloud.kubernetes.io/instance-id="$H100_INSTANCE_ID" \
    ibm-cloud.kubernetes.io/instance-profile="$GPU_PROFILE" \
    ibm-cloud.kubernetes.io/zone="$IBMCLOUD_ZONE" \
    --overwrite
```

#### 9f. Apply Workload Type Labels

```bash
oc label node $H100_NODE_NAME \
    workload.openshift.io/ai-ml=true \
    workload.openshift.io/hpc=true \
    --overwrite
```

---

### Step 10: Verify Labels

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key | contains("nvidia") or contains("rdma") or contains("gpu") or contains("workload")))'
```

**Expected** — should show all GPU, RDMA, and workload labels:

```json
{
  "ibm-cloud.kubernetes.io/cluster-network": "rdma-cluster",
  "ibm-cloud.kubernetes.io/cluster-network-profile": "hopper-1",
  "ibm-cloud.kubernetes.io/rdma": "enabled",
  "node-role.kubernetes.io/gpu": "true",
  "nvidia.com/gpu.count": "8",
  "nvidia.com/gpu.memory": "80GB",
  "nvidia.com/gpu.product": "H100-SXM5",
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

4 nodes, all Ready.

#### 11b. Node Resource Capacity

```bash
oc describe node $H100_NODE_NAME | grep -A 10 "Capacity:"
```

**Look for:**
- `cpu:` 160 (160 vCPUs)
- `memory:` ~1.75Ti

> GPU resources (`nvidia.com/gpu: 8`) will NOT appear until GPU Operator is installed (Phase 5).

#### 11c. Cluster Operators Healthy

```bash
oc get co | grep -v "True.*False.*False" | grep -v "^NAME"
```

Should return nothing (all healthy). Some operators may show `PROGRESSING: True` briefly after adding a worker — wait 5 minutes and check again.

#### 11d. CNI Pods Running on H100

```bash
oc get pods -A -o wide | grep $H100_NODE_NAME | head -10
```

Should show pods like `ovnkube-node`, `node-ca`, `multus` — all `Running`.

#### 11e. Verify Pod Egress Connectivity

Pods on the H100 must be able to reach external hosts (e.g., to download ML models from HuggingFace). OVN-Kubernetes may not fully initialize UDP routing on a manually-added worker node, causing DNS resolution failures from pods.

Test external connectivity from a pod scheduled on the H100:

```bash
oc run egress-test --restart=Never --overrides='{"spec":{"nodeName":"ocp-gpu-worker-h100"}}' --image=registry.access.redhat.com/ubi9/ubi-minimal -- sleep 60
sleep 15
oc exec egress-test -- bash -c "curl -sI https://huggingface.co --connect-timeout 10 2>&1 | head -3"
oc delete pod egress-test
```

**Expected**: `HTTP/2 200` — pod can reach external hosts.

**If no output or timeout**: DNS resolution from pods on the H100 is broken. Fix by restarting the OVN-Kubernetes node pod on the H100 to reinitialize network flows:

```bash
oc delete pod -n openshift-ovn-kubernetes -l app=ovnkube-node --field-selector spec.nodeName=ocp-gpu-worker-h100
```

Wait 60 seconds for the OVN pod to restart (8/8 Running), then retest:

```bash
sleep 60
oc get pods -n openshift-ovn-kubernetes --field-selector spec.nodeName=ocp-gpu-worker-h100 --no-headers
```

Rerun the egress test above. It should now return `HTTP/2 200`.

> **Root cause**: When the H100 joins the cluster via CSR approval, OVN-Kubernetes configures the node's gateway but UDP routing (used by DNS) may not fully initialize. The 8 cluster network interfaces (RDMA) on the H100 add complexity to OVN's network configuration. Restarting the `ovnkube-node` pod forces re-initialization of all OVN flows, fixing the UDP path to CoreDNS.

#### 11f. Summary

```bash
echo ""
echo "========================================"
echo "Phase 4 Complete"
echo "========================================"
echo ""
echo "Nodes:  $(oc get nodes --no-headers | wc -l | tr -d ' ') (expected: 4)"
echo "Worker: $H100_NODE_NAME"
echo "Status: $(oc get node $H100_NODE_NAME -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')"
echo "Roles:  $(oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/gpu}'  && echo ' gpu') $(oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/worker}' && echo ' worker')"
echo "CPU:    $(oc get node $H100_NODE_NAME -o jsonpath='{.status.capacity.cpu}')"
echo "Memory: $(oc get node $H100_NODE_NAME -o jsonpath='{.status.capacity.memory}')"
echo ""
echo "GPU resources: Not yet (Phase 5 — GPU Operator)"
echo "RDMA networks: Not yet (Phase 5 — RDMA Operators, optional)"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 4, you should have:

- [x] **H100 node joined cluster** via CSR approval
- [x] **Bootstrap CSR approved**
- [x] **Serving CSR approved**
- [x] **Node in Ready state**
- [x] **GPU labels applied** (`nvidia.com/gpu.*`)
- [x] **RDMA labels applied** (`ibm-cloud.kubernetes.io/rdma=enabled`)
- [x] **Workload labels applied** (`workload.openshift.io/ai-ml=true`)
- [x] **4 total nodes** — 3 masters + 1 H100 worker
- [x] **All cluster operators healthy**

---

## Cost

After Phase 4:
- **Control Plane**: 3 masters (bx2-8x32) — ~$0.50-1.00/hour
- **Worker**: 1 H100 (gx3d-160x1792x8h100) — ~$30-40/hour
- **Total**: ~$30-41/hour

---

## Operations: Stop/Start H100

The H100 costs ~$30-40/hour. Stop it when not in use to save costs. The node auto-rejoins OpenShift on restart — no manual intervention needed.

### Stop H100 (Save Costs)

```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
```

What happens:
- Node shows `NotReady` in `oc get nodes` within ~1 minute
- Cluster network attachments **persist** (not detached on stop)
- Kubelet certificates **persist** on disk
- Pods on the node are evicted after 5 minutes (default `pod-eviction-timeout`)

### Start H100

```bash
ibmcloud is instance-start $H100_INSTANCE_ID
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

Should show 4 nodes, all Ready.

```bash
oc get pods -A -o wide | grep ocp-gpu-worker-h100 | grep -v Running
```

Should return nothing (all pods Running).

```bash
ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json | jq '. | length'
```

Should show `8` (all cluster network attachments intact).

### If Node Doesn't Rejoin After Restart

If the instance was stopped for an extended period, kubelet certificates may have expired. Check for pending CSRs:

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

The H100 boots RHCOS with worker.ign — CSRs should appear within 1-5 minutes of the instance reaching `running` state. If no CSRs after 10 minutes:

1. Verify instance is running:
   ```bash
   ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status'
   ```

2. SSH to the instance and check kubelet:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H100_FIP "sudo systemctl status kubelet"
   ```

3. Check kubelet logs for errors:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H100_FIP "sudo journalctl -u kubelet --no-pager | tail -20"
   ```

4. Verify the instance can reach the cluster API internally:
   ```bash
   ssh -i ~/.ssh/id_rsa core@$H100_FIP "curl -sk https://api-int.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443/version"
   ```

### Node Stays NotReady

Check node conditions:

```bash
oc describe node $H100_NODE_NAME | grep -A 5 "Conditions:"
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

After Phase 4 completes:

1. **Phase 5**: Install Operators — GPU stack (NFD, GPU Operator), AI platform (cert-manager, RHCL, LWS, RHOAI), model serving (DataScienceCluster + KServe). See `PHASE5-OPERATORS.md`.

---

**Phase 4 Complete!**

**H100 joined as OpenShift worker node. 4 nodes total (3 masters + 1 H100). Proceed to Phase 5 (PHASE5-OPERATORS.md) for operator installation.**
