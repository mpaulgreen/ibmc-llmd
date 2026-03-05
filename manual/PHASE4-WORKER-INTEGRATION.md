# Phase 4: Integrate H100 as Worker Node

## Overview

This phase integrates the H100 GPU instance as an OpenShift worker node using the Certificate Signing Request (CSR) approval workflow.

**What You'll Accomplish:**
- Understand the integration challenge
- Monitor for Certificate Signing Requests from the H100
- Approve bootstrap and serving CSRs
- Verify node joins the cluster
- Apply GPU, RDMA, and workload labels to the node
- Verify node is Ready and properly configured

**Estimated Time**: 30-60 minutes

**Complexity**: ⚠️ **HIGH** - This is the most complex phase

## Why This is Complex

The H100 instance was provisioned **outside** of OpenShift's standard MachineSet workflow. Additionally:

1. **Cluster network attachment** required the instance to be STOPPED during attachment
2. **Non-standard integration** - Can't use standard IPI-managed or MachineSet automation
3. **Manual CSR approval** - Worker must request certificates, which we approve manually
4. **Two-step approval** - Bootstrap CSR, then serving CSR (after node joins)

## Integration Approach

We use OpenShift's **Certificate Signing Request (CSR) approval workflow**:

1. **H100 generates CSR** - Worker attempts to join cluster, requests certificates
2. **We approve bootstrap CSR** - Allows worker to join cluster
3. **Node appears in cluster** - Shows up in `oc get nodes`
4. **We approve serving CSR** - Allows kubelet to serve metrics/logs
5. **Apply labels** - Tag node for GPU, RDMA, workload targeting

## Pre-Flight Checks

Before starting, ensure Phases 1-3 are complete:

- [ ] OpenShift cluster deployed (Phase 2)
- [ ] 3 master nodes Ready
- [ ] H100 instance created and running (Phase 3)
- [ ] 8 cluster network interfaces attached
- [ ] Environment file loaded: `source ~/.ibmcloud-h100-env`
- [ ] KUBECONFIG set and working

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
```

```bash
oc get nodes
```

Should show 3 master nodes, all Ready.

```bash
ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status'
```

Should show: `running`

```bash
ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json | jq '. | length'
```

Should show: `8`

---

## Understanding Worker Join Methods

There are two approaches to join the H100 to OpenShift:

### Option A: RHCOS with Ignition (Recommended)

If the H100 is running RHCOS (Red Hat Enterprise Linux CoreOS):
- Use ignition file for automated configuration
- Most native to OpenShift
- **Requires**: Recreating the instance with ignition (loses cluster network attachments)

**Status**: Not practical for our case due to cluster network attachment requirement.

### Option B: Manual CSR Approval (What We'll Do)

The worker node attempts to join OpenShift:
- Generates bootstrap CSR
- We approve it manually
- Node joins cluster
- Generates serving CSR
- We approve it manually
- Node becomes fully functional

**This is the approach we'll use.**

---

## Step-by-Step Instructions

### Step 1: Load Environment and Verify Access

Load environment:

```bash
source ~/.ibmcloud-h100-env
```

Verify cluster access:

```bash
export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig
```

```bash
oc whoami
```

**Expected**: `system:admin` or `kube:admin`

Test cluster connectivity:

```bash
oc cluster-info
```

Should show Kubernetes control plane URL.

---

### Step 2: Get Current Cluster State

#### 2a. List Current Nodes

```bash
oc get nodes
```

**Expected Output:**
```
NAME                                         STATUS   ROLES                  AGE   VERSION
ocp-h100-cluster-xxxxx-master-0              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-1              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-2              Ready    control-plane,master   Xh    v1.x.x
```

Note the node count:

```bash
export INITIAL_NODE_COUNT=$(oc get nodes --no-headers | wc -l | tr -d ' ')
echo "Initial node count: $INITIAL_NODE_COUNT"
```

Should be: `3`

#### 2b. Check for Existing Worker Nodes

```bash
oc get nodes -l node-role.kubernetes.io/worker
```

**Expected**: No resources found (we haven't added workers yet)

---

### Step 3: Get H100 Instance Information

Get the H100 private IP:

```bash
export H100_PRIVATE_IP=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.primary_network_interface.primary_ip.address')
echo "H100 Private IP: $H100_PRIVATE_IP"
```

Get cluster API endpoint:

```bash
export CLUSTER_API=$(oc whoami --show-server)
echo "Cluster API: $CLUSTER_API"
```

---

### Step 4: Understand the CSR Workflow

**What happens when H100 tries to join:**

1. **H100 kubelet starts** (either automatically or manually configured)
2. **Generates bootstrap CSR** - Requests permission to join cluster
3. **CSR appears in cluster** - Visible via `oc get csr`
4. **CSR status: Pending** - Waiting for admin approval
5. **We approve CSR** - Using `oc adm certificate approve`
6. **Kubelet gets certificate** - Can now join cluster
7. **Node appears** - Shows in `oc get nodes`
8. **Generates serving CSR** - Requests permission to serve metrics/logs
9. **We approve serving CSR** - Node becomes fully functional

**Our task**: Monitor for CSRs and approve them.

---

### Step 5: Check for Pending CSRs

#### 5a. List All CSRs

```bash
oc get csr
```

**Expected Output** (if H100 hasn't started join process):
```
No resources found
```

Or may show some old CSRs in Approved state.

#### 5b. Check for Pending CSRs Specifically

```bash
oc get csr | grep Pending
```

**If output is empty**: No pending CSRs yet. H100 hasn't started the join process.

**If CSRs shown**: H100 is already trying to join! Skip to Step 6.

---

### Step 5c: If No CSRs - Troubleshooting

**If no CSRs appear, possible reasons:**

1. **H100 kubelet not started/configured** - The instance needs kubelet configured to join
2. **Network connectivity issue** - H100 can't reach cluster API
3. **No join credentials** - H100 doesn't have bootstrap token/kubeconfig

**For this deployment:**

The H100 instance was created with a basic image. It likely needs manual configuration to join OpenShift.

**Two approaches:**

**A. Wait for automatic join** (if image has cloud-init or ignition):
- Some images auto-detect OpenShift cluster
- May take 10-20 minutes
- Monitor CSRs: `watch oc get csr`

**B. Manual configuration** (advanced):
- SSH to H100 instance
- Configure kubelet with cluster bootstrap token
- Start kubelet service
- CSRs should appear within 1-2 minutes

**For this manual guide, we'll assume approach A.**

---

### Step 6: Monitor for CSRs (Automated Waiting)

Set up a watch to monitor for new CSRs:

```bash
watch -n 10 'oc get csr | grep -E "NAME|Pending"'
```

This will refresh every 10 seconds and show pending CSRs.

**Keep this running in your terminal.**

**What to look for:**
```
NAME        AGE   SIGNERNAME                            REQUESTOR                     CONDITION
csr-xxxxx   Xs    kubernetes.io/kube-apiserver-client...  system:bootstrap:xxxxx       Pending
```

**When you see a Pending CSR**, press `Ctrl+C` and proceed to Step 7.

**If no CSRs after 10 minutes:**

The H100 instance likely needs manual configuration. See "Advanced: Manual H100 Configuration" section at the end of this guide.

---

### Step 7: Review Pending CSRs

List all pending CSRs:

```bash
oc get csr | grep Pending
```

**Expected Output:**
```
csr-xxxxx   Xs    kubernetes.io/kube-apiserver-client...  system:bootstrap:xxxxx       Pending
```

Get details of the CSR:

```bash
export PENDING_CSR=$(oc get csr --no-headers | grep Pending | head -1 | awk '{print $1}')
echo "Pending CSR: $PENDING_CSR"
```

View CSR details:

```bash
oc describe csr $PENDING_CSR
```

Look for:
- **Requestor**: Should be `system:bootstrap:...` or similar
- **Usages**: Should include client auth
- **Status**: Pending

**Verify this is legitimate** - it should be from the H100 worker attempting to join.

---

### Step 8: Approve Bootstrap CSR

⚠️ **IMPORTANT**: Only approve CSRs you trust. CSRs grant cluster access.

**In our case:** This should be from our H100 worker, which is safe to approve.

Approve the CSR:

```bash
oc adm certificate approve $PENDING_CSR
```

**Expected Output:**
```
certificatesigningrequest.certificates.k8s.io/csr-xxxxx approved
```

Verify it's approved:

```bash
oc get csr $PENDING_CSR
```

**Expected:**
```
NAME        AGE   SIGNERNAME     REQUESTOR     CONDITION
csr-xxxxx   Xm    ...            ...           Approved,Issued
```

Status should show: `Approved,Issued`

---

### Step 9: Wait for Node to Join

After approving the bootstrap CSR, the node should join within 1-2 minutes.

Monitor nodes:

```bash
watch -n 5 'oc get nodes'
```

**Expected progression:**
```
# Initially: 3 nodes (masters only)
NAME                                         STATUS   ROLES                  AGE   VERSION
ocp-h100-cluster-xxxxx-master-0              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-1              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-2              Ready    control-plane,master   Xh    v1.x.x

# After 1-2 minutes: 4 nodes (3 masters + 1 worker)
NAME                                         STATUS     ROLES                  AGE   VERSION
ocp-h100-cluster-xxxxx-master-0              Ready      control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-1              Ready      control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-2              Ready      control-plane,master   Xh    v1.x.x
ocp-h100-worker                              NotReady   worker                 Xs    v1.x.x
```

**Note:** New node will likely show `NotReady` initially. This is normal.

When you see the 4th node, press `Ctrl+C`.

---

### Step 10: Get Worker Node Name

List worker nodes:

```bash
oc get nodes -l node-role.kubernetes.io/worker
```

**Expected Output:**
```
NAME              STATUS     ROLES    AGE   VERSION
ocp-h100-worker   NotReady   worker   Xs    v1.x.x
```

Save the node name:

```bash
export H100_NODE_NAME=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers | awk '{print $1}')
echo "H100 Node Name: $H100_NODE_NAME"
```

**If empty**, the worker role label might not be applied yet. Get all non-master nodes:

```bash
export H100_NODE_NAME=$(oc get nodes --no-headers | grep -v master | awk '{print $1}')
echo "H100 Node Name: $H100_NODE_NAME"
```

Save to environment file:

```bash
echo "" >> ~/.ibmcloud-h100-env
echo "# H100 Worker Node (joined $(date))" >> ~/.ibmcloud-h100-env
echo "export H100_NODE_NAME=$H100_NODE_NAME" >> ~/.ibmcloud-h100-env
```

---

### Step 11: Check for Additional Pending CSRs

After the node joins, it will generate **serving CSRs** for kubelet metrics and logs.

Wait 30 seconds:

```bash
sleep 30
```

Check for new pending CSRs:

```bash
oc get csr | grep Pending
```

**If pending CSRs exist:**

These are likely the serving CSRs. List them:

```bash
oc get csr --no-headers | grep Pending
```

Approve all pending CSRs:

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

**Expected Output:**
```
certificatesigningrequest.certificates.k8s.io/csr-xxxxx approved
certificatesigningrequest.certificates.k8s.io/csr-yyyyy approved
```

Verify all are approved:

```bash
oc get csr | grep -v Approved
```

Should only show the header line (all CSRs approved).

**If no pending CSRs:**

They may appear in 1-2 minutes. Check again:

```bash
sleep 60
oc get csr | grep Pending
```

If still none, the node may be using a different configuration. Proceed to Step 12.

---

### Step 12: Wait for Node to Become Ready

Monitor node status:

```bash
watch -n 10 "oc get node $H100_NODE_NAME"
```

**Expected progression:**
```
# Initially
NAME              STATUS     ROLES    AGE   VERSION
ocp-h100-worker   NotReady   worker   Xm    v1.x.x

# After 2-5 minutes
NAME              STATUS   ROLES    AGE   VERSION
ocp-h100-worker   Ready    worker   Xm    v1.x.x
```

**Why NotReady?**
- CNI (network plugin) still initializing
- Container runtime starting
- Node components configuring

**Typical time**: 2-5 minutes to reach Ready

Once STATUS shows `Ready`, press `Ctrl+C` and proceed.

---

### Step 13: Verify Node Details

Get detailed node information:

```bash
oc describe node $H100_NODE_NAME
```

**Check for:**
- **Status: Ready**
- **Roles: worker**
- **Internal IP**: Should match H100 private IP
- **OS Image**: RHCOS or RHEL
- **Container Runtime**: CRI-O

View node conditions:

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.status.conditions[*].type}' | tr ' ' '\n'
```

**Expected:**
```
Ready
MemoryPressure
DiskPressure
PIDPressure
```

Check all are healthy:

```bash
oc get node $H100_NODE_NAME -o jsonpath='{range .status.conditions[*]}{.type}{"\t"}{.status}{"\n"}{end}'
```

**Expected:**
```
Ready                True
MemoryPressure       False
DiskPressure         False
PIDPressure          False
```

---

### Step 14: Apply Labels to H100 Node

Now we'll apply labels for GPU, RDMA, and workload targeting.

#### 14a. View Current Labels

```bash
oc get node $H100_NODE_NAME --show-labels
```

Shows all current labels (very long output).

#### 14b. Apply Worker Role Label (if not present)

Check if worker role label exists:

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/worker}'
```

If empty, apply it:

```bash
oc label node $H100_NODE_NAME node-role.kubernetes.io/worker="" --overwrite
```

#### 14c. Apply GPU Role Label

```bash
oc label node $H100_NODE_NAME node-role.kubernetes.io/gpu=true --overwrite
```

**Expected:**
```
node/ocp-h100-worker labeled
```

#### 14d. Apply NVIDIA-Specific Labels

```bash
oc label node $H100_NODE_NAME \
    nvidia.com/gpu.product=H100-SXM5 \
    nvidia.com/gpu.memory=80GB \
    nvidia.com/gpu.count=8 \
    --overwrite
```

**Expected:**
```
node/ocp-h100-worker labeled
```

#### 14e. Apply RDMA Labels

```bash
oc label node $H100_NODE_NAME \
    ibm-cloud.kubernetes.io/rdma=enabled \
    ibm-cloud.kubernetes.io/cluster-network=rdma-cluster \
    ibm-cloud.kubernetes.io/cluster-network-profile=hopper-1 \
    --overwrite
```

**Expected:**
```
node/ocp-h100-worker labeled
```

#### 14f. Apply IBM Cloud Labels

```bash
oc label node $H100_NODE_NAME \
    ibm-cloud.kubernetes.io/instance-id="$H100_INSTANCE_ID" \
    ibm-cloud.kubernetes.io/instance-profile="$GPU_PROFILE" \
    ibm-cloud.kubernetes.io/zone="$IBMCLOUD_ZONE" \
    --overwrite
```

**Expected:**
```
node/ocp-h100-worker labeled
```

#### 14g. Apply Workload Type Labels

```bash
oc label node $H100_NODE_NAME \
    workload.openshift.io/ai-ml=true \
    workload.openshift.io/hpc=true \
    --overwrite
```

**Expected:**
```
node/ocp-h100-worker labeled
```

---

### Step 15: Verify Labels Applied

Check all GPU-related labels:

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels}' | jq '.'
```

This will show all labels in JSON format.

**Verify these are present:**
- `node-role.kubernetes.io/gpu: "true"`
- `nvidia.com/gpu.product: "H100-SXM5"`
- `nvidia.com/gpu.count: "8"`
- `ibm-cloud.kubernetes.io/rdma: "enabled"`
- `ibm-cloud.kubernetes.io/cluster-network: "rdma-cluster"`
- `workload.openshift.io/ai-ml: "true"`

Check specific labels:

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/gpu}'
```

Should output: `true`

```bash
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels.nvidia\.com/gpu\.count}'
```

Should output: `8`

---

### Step 16: Optional - Apply Taints (GPU Exclusivity)

**What are taints?**

Taints prevent regular workloads from scheduling on GPU nodes. Only pods with matching tolerations can schedule.

**When to use:**
- Reserve GPU nodes exclusively for GPU workloads
- Prevent CPU-only pods from consuming GPU node resources
- Cost optimization (GPU nodes are expensive)

**Apply GPU taint:**

```bash
oc adm taint node $H100_NODE_NAME nvidia.com/gpu=present:NoSchedule
```

**Expected:**
```
node/ocp-h100-worker tainted
```

**To remove taint later:**

```bash
oc adm taint node $H100_NODE_NAME nvidia.com/gpu:NoSchedule-
```

**For now, we'll skip taints** to allow easier testing. You can apply later if desired.

---

### Step 17: Final Node Verification

#### 17a. Get Node Status Summary

```bash
oc get nodes
```

**Expected Output:**
```
NAME                                         STATUS   ROLES                  AGE   VERSION
ocp-h100-cluster-xxxxx-master-0              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-1              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-cluster-xxxxx-master-2              Ready    control-plane,master   Xh    v1.x.x
ocp-h100-worker                              Ready    gpu,worker             Xm    v1.x.x
```

Verify:
- 4 nodes total (3 masters + 1 worker)
- All show `STATUS: Ready`
- Worker shows roles: `gpu,worker`

#### 17b. Get Node Resource Capacity

```bash
oc describe node $H100_NODE_NAME | grep -A 20 "Capacity:"
```

**Look for:**
- `cpu:` 160 (160 vCPUs)
- `memory:` ~1.75Ti
- `pods:` 250 (default pod limit)

**Note:** GPU resources won't show yet. They appear after GPU Operator installation (Phase 6).

#### 17c. Check Node Networking

View network interfaces:

```bash
oc debug node/$H100_NODE_NAME -- ip addr show
```

This opens a debug pod on the node and shows network interfaces.

**Look for:**
- Primary interface (VPC management network)
- Additional interfaces (cluster network/RDMA - may not be visible yet)

Type `exit` to leave the debug session.

---

### Step 18: Verify Cluster Health

#### 18a. Check All Nodes

```bash
oc get nodes
```

All 4 nodes should be Ready.

#### 18b. Check Cluster Operators

```bash
oc get co
```

All cluster operators should show:
- `AVAILABLE: True`
- `PROGRESSING: False`
- `DEGRADED: False`

Some operators may show `PROGRESSING: True` briefly after adding worker. Wait 5-10 minutes and check again.

#### 18c. Check Node Pods

Verify CNI and other node components are running on H100:

```bash
oc get pods -A -o wide | grep $H100_NODE_NAME
```

**Should see pods like:**
- `ovnkube-node-xxxxx` (OVN CNI)
- `node-ca-xxxxx` (certificate management)
- `multus-xxxxx` (network plugin)

All should show `STATUS: Running`

---

## Checkpoint Summary

At the end of Phase 4, you should have:

- [x] **H100 node joined cluster** via CSR approval workflow
- [x] **Bootstrap CSR approved** - Allowed initial join
- [x] **Serving CSR approved** - Enabled kubelet metrics/logs
- [x] **Node in Ready state** - Fully functional
- [x] **GPU labels applied** - `nvidia.com/gpu.*`
- [x] **RDMA labels applied** - `ibm-cloud.kubernetes.io/rdma=enabled`
- [x] **Workload labels applied** - `workload.openshift.io/ai-ml=true`
- [x] **4 total nodes** - 3 masters + 1 H100 worker

### Verify Checklist

```bash
# Should show 4 nodes, all Ready
oc get nodes

# Should show worker node
oc get nodes -l node-role.kubernetes.io/gpu

# Should show GPU labels
oc get node $H100_NODE_NAME -o jsonpath='{.metadata.labels}' | jq 'with_entries(select(.key | contains("nvidia") or contains("rdma")))'

# Should show all operators healthy
oc get co | grep -v "True.*False.*False" | wc -l
# Should output: 1 (just the header line)
```

If all checks pass, Phase 4 is complete!

---

## Troubleshooting

### Issue: No CSRs Appearing

**Possible causes:**
- H100 instance not configured for OpenShift
- Network connectivity issues
- Kubelet not started

**Diagnosis:**

Check if H100 can reach cluster API:

```bash
# Get H100 floating IP (if exists)
FLOATING_IP=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.primary_network_interface.floating_ips[0].address // empty')

# SSH to H100
ssh root@$FLOATING_IP

# From H100, test cluster API
curl -k $CLUSTER_API/version
```

Should return JSON with cluster version.

### Issue: CSRs Appear But Node Doesn't Join

**Check:**
- CSR was actually approved: `oc get csr`
- Node may need time: wait 5 minutes
- Check kubelet logs on H100 (if SSH access available)

### Issue: Node Stays NotReady

**Common causes:**
- CNI not initialized
- Container runtime issues
- Network plugin problems

**Diagnosis:**

```bash
oc describe node $H100_NODE_NAME
```

Look at "Conditions" section for specific errors.

Check node pods:

```bash
oc get pods -A -o wide | grep $H100_NODE_NAME
```

If CNI pods are not Running, that's the issue.

### Issue: Labels Not Applied

**Verify:**

```bash
oc get node $H100_NODE_NAME --show-labels | grep nvidia
```

If empty, re-run label commands from Step 14.

**Force label:**

```bash
oc label node $H100_NODE_NAME nvidia.com/gpu.count=8 --overwrite=true
```

### Issue: Multiple Pending CSRs

If many CSRs accumulate:

**Approve all at once:**

```bash
oc get csr --no-headers | grep Pending | awk '{print $1}' | xargs oc adm certificate approve
```

Then verify:

```bash
oc get csr
```

---

## Advanced: Manual H100 Configuration

**If CSRs never appear**, the H100 instance may need manual kubelet configuration.

This requires:
1. SSH access to H100
2. OpenShift bootstrap token
3. Manual kubelet configuration

**Steps (high-level):**

1. Generate bootstrap token on cluster
2. SSH to H100
3. Install/configure CRI-O
4. Install/configure kubelet
5. Create kubelet configuration with bootstrap token
6. Start kubelet service
7. CSRs should appear

This is advanced and beyond the scope of this manual guide. See OpenShift documentation for "Adding RHEL nodes to cluster."

---

## Important Notes

### Total Cluster Status

After Phase 4:
- **Control Plane**: 3 masters (bx2-8x32) - ~$0.50-1.00/hour
- **Workers**: 1 H100 (gx3d-160x1792x8h100) - ~$30-40/hour
- **Total Cost**: ~$30-41/hour

### GPU Resources Not Yet Available

**Important:** Even though the H100 has 8 GPUs, they won't show as Kubernetes resources yet:

```bash
oc describe node $H100_NODE_NAME | grep nvidia.com/gpu
```

Will show nothing.

**Why?** GPU Operator is not installed yet. This happens in Phase 6.

### RDMA Networks Not Yet Configured

The 8 cluster network interfaces are attached, but not yet configured for pod networking:

```bash
oc get network-attachment-definitions -A
```

Will show nothing or only default networks.

**Why?** RDMA operators (SR-IOV, NVIDIA Network) not installed yet. This happens in Phase 5.

### What We Have Now

- ✅ Worker node joined and Ready
- ✅ Can schedule regular pods
- ✅ Labels in place for future operator targeting
- ❌ GPUs not yet usable (need GPU Operator)
- ❌ RDMA not yet configured (need RDMA operators)

---

## Next Steps

**Phases 5-7 are not covered in these manual guides.** Use the automated scripts:

### Phase 5: RDMA Operators (30-40 min)

```bash
cd ../deployment-scripts/phase5-rdma-operators/
./01-install-nfd.sh
./02-install-nmstate.sh
./03-install-sriov.sh
./04-install-nvidia-network-operator.sh
./05-configure-sriov-rdma.sh
./06-verify-rdma-resources.sh
```

### Phase 6: GPU Operator (20-30 min)

```bash
cd ../deployment-scripts/phase6-gpu-operator/
./01-install-gpu-operator.sh
./02-create-cluster-policy.sh
./03-verify-gpu-resources.sh
```

### Phase 7: Validation (15-20 min)

```bash
cd ../deployment-scripts/phase7-validation/
./01-verify-cluster-health.sh
./02-test-rdma.sh
./03-test-gpu.sh
./04-test-nccl-optional.sh
```

### After All Phases Complete

You'll have:
- ✅ Functional OpenShift cluster with H100 worker
- ✅ 8× H100 GPUs available as Kubernetes resources (`nvidia.com/gpu`)
- ✅ 8× RDMA interfaces configured (`rdma/rdma_mlx5`)
- ✅ GPU Direct RDMA enabled
- ✅ Ready for AI/ML workloads (PyTorch, TensorFlow, etc.)

See `../deployment-scripts/docs/POST-DEPLOYMENT.md` for workload examples.

---

## Success Criteria

Phase 4 is complete when:

- [x] 4 nodes in cluster (3 masters + 1 worker)
- [x] All nodes show STATUS: Ready
- [x] H100 node has worker and gpu roles
- [x] GPU labels present on H100 node
- [x] RDMA labels present on H100 node
- [x] All cluster operators Available and not Degraded
- [x] CNI pods running on H100 node
- [x] Node can schedule regular pods (test with sample deployment)

---

**Phase 4 Complete! ✅**

**H100 successfully joined as OpenShift worker node. Cluster now has 4 nodes (3 masters + 1 H100 worker). Ready for operator installation in Phases 5-6.**
