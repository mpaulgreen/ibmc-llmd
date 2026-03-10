# Phase 5: Install Operators (GPU, AI Platform, Model Serving)

## Overview

This phase installs the complete operator stack to enable GPU workloads and AI/ML model serving on the H100 worker node.

**What You'll Accomplish:**
- Install NFD Operator to discover GPU hardware features
- Install NVIDIA GPU Operator to expose 8x H100 GPUs to Kubernetes
- (Optional) Install RDMA operators for multi-node GPU training
- Install AI platform operators (cert-manager, RHCL, LWS, RHOAI)
- Configure DataScienceCluster with KServe for model serving

**Estimated Time**: 45-60 minutes

## Operator Install Order

```
Part A: GPU Stack (Required)
  Step 1: NFD Operator
  Step 2: NVIDIA GPU Operator + ClusterPolicy

Part B: RDMA Operators (Optional — Multi-Node Only)
  Step 3: NVIDIA Network Operator + NicClusterPolicy (RDMA shared device plugin)

Part C: AI Platform Operators (Required for Model Serving)
  Step 6: cert-manager
  Step 7: Red Hat Connectivity Link (RHCL)
  Step 8: Leader Worker Set (LWS) Operator
  Step 9: Red Hat OpenShift AI (RHOAI) 3.0

Part D: Configure Model Serving (Required)
  Step 10: Wait for DSCInitialization
  Step 11: Create DataScienceCluster
  Step 12: Final Verification
```

## Operator Versions

| Operator | Version | Channel | Source |
|---|---|---|---|
| NFD | 4.19.0 | stable | redhat-operators |
| NVIDIA GPU Operator | 25.10.1 | v25.10 | certified-operators |
| NVIDIA Network Operator | 26.1.0 | v26.1 | certified-operators |
| cert-manager | 1.18.1 | stable-v1.18 | redhat-operators |
| RHCL | 1.3.0 | stable | redhat-operators |
| Authorino | 1.3.0 | (auto via RHCL) | -- |
| Limitador | 1.3.0 | (auto via RHCL) | -- |
| DNS Operator | 1.3.0 | (auto via RHCL) | -- |
| LWS | 1.0.0 | stable-v1.0 | redhat-operators |
| RHOAI | 3.3.0 | fast-3.x | redhat-operators |
| Service Mesh 3 | 3.2.1 | (auto via RHOAI) | -- |

## Pre-Flight Checks

Before starting, ensure Phases 1-4 are complete:

- [ ] OpenShift cluster deployed — 3 masters + 1 H100 worker, all Ready
- [ ] H100 node labeled (Phase 4 Step 9)
- [ ] Environment file loaded: `source ~/.ibmcloud-h100-env`
- [ ] KUBECONFIG set and working

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
```

```bash
oc get nodes
```

Should show 4 nodes, all Ready:

```
NAME                   STATUS   ROLES                         AGE   VERSION
ocp-master-0           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-1           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-master-2           Ready    control-plane,master,worker   Xh    v1.32.x
ocp-gpu-worker-h100    Ready    worker                        Xm    v1.32.x
```

```bash
oc whoami
```

**Expected**: `system:admin`

---

# Part A: GPU Stack (Required)

---

## Step 1: Install NFD Operator

Node Feature Discovery detects hardware features (GPUs, NICs) and labels nodes automatically.

### 1a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-nfd
EOF
```

### 1b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-nfd
  namespace: openshift-nfd
spec:
  targetNamespaces:
    - openshift-nfd
EOF
```

### 1c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nfd
  namespace: openshift-nfd
spec:
  channel: stable
  installPlanApproval: Automatic
  name: nfd
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 1d. Wait for NFD Operator Ready

```bash
echo "Waiting for NFD operator..."
while ! oc get csv -n openshift-nfd 2>/dev/null | grep nfd | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "NFD operator installed."
```

Verify:

```bash
oc get csv -n openshift-nfd
```

**Expected**: `nfd.v4.19.0` (or later) with phase `Succeeded`.

### 1e. Create NodeFeatureDiscovery Instance

```bash
oc apply -f - <<EOF
apiVersion: nfd.openshift.io/v1
kind: NodeFeatureDiscovery
metadata:
  name: nfd-instance
  namespace: openshift-nfd
spec:
  operand:
    image: registry.redhat.io/openshift4/ose-node-feature-discovery-rhel9:v4.19
    servicePort: 12000
  workerConfig:
    configData: |
      core:
        sleepInterval: 60s
      sources:
        pci:
          deviceClassWhitelist:
            - "0200"
            - "0300"
            - "0302"
          deviceLabelFields:
            - vendor
EOF
```

### 1f. Wait for NFD Pods Running

```bash
echo "Waiting for NFD pods..."
sleep 30
oc get pods -n openshift-nfd
```

**Expected**: `nfd-controller-manager`, `nfd-master`, and `nfd-worker` pods all Running.

### 1g. Verify PCI Vendor Labels

NFD auto-discovers GPUs and Mellanox NICs and labels the node. Wait 1-2 minutes:

```bash
sleep 60
oc get node ocp-gpu-worker-h100 -o json | jq '.metadata.labels | with_entries(select(.key | startswith("feature.node.kubernetes.io/pci-1")))'
```

**Expected**:

```json
{
  "feature.node.kubernetes.io/pci-10de.present": "true",
  "feature.node.kubernetes.io/pci-15b3.present": "true"
}
```

- `10de` = NVIDIA (GPU Operator uses this to identify GPU nodes)
- `15b3` = Mellanox (Network Operator uses this for RDMA device plugin scheduling)

Both labels are NFD-managed and survive node restarts.

> Class `0200` (Ethernet) in the whitelist also creates `pci-1af4.present` (Virtio NIC) — this is harmless, nothing selects on it.

---

## Step 2: Install NVIDIA GPU Operator

### 2a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-gpu-operator
EOF
```

### 2b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-gpu-operator
  namespace: nvidia-gpu-operator
spec:
  targetNamespaces:
    - nvidia-gpu-operator
EOF
```

### 2c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: gpu-operator-certified
  namespace: nvidia-gpu-operator
spec:
  channel: v25.10
  installPlanApproval: Automatic
  name: gpu-operator-certified
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: gpu-operator-certified.v25.10.1
EOF
```

### 2d. Wait for GPU Operator Ready

```bash
echo "Waiting for GPU Operator..."
while ! oc get csv -n nvidia-gpu-operator 2>/dev/null | grep gpu-operator | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "GPU Operator installed."
```

Verify:

```bash
oc get csv -n nvidia-gpu-operator
```

**Expected**: `gpu-operator-certified.v25.10.1` with phase `Succeeded`.

### 2e. Create ClusterPolicy

The ClusterPolicy tells the GPU Operator how to configure GPU resources:

```bash
oc apply -f - <<EOF
apiVersion: nvidia.com/v1
kind: ClusterPolicy
metadata:
  name: gpu-cluster-policy
spec:
  operator:
    defaultRuntime: crio
    use_ocp_driver_toolkit: true
  daemonsets:
    labels: {}
    annotations: {}
    tolerations: []
    priorityClassName: system-node-critical
    updateStrategy: RollingUpdate
    rollingUpdate:
      maxUnavailable: "1"
  driver:
    enabled: true
    kernelModuleType: auto
    rdma:
      enabled: false
      useHostMofed: false
  dcgm:
    enabled: true
  dcgmExporter:
    enabled: true
  devicePlugin:
    enabled: true
  gfd:
    enabled: true
  migManager:
    enabled: true
  toolkit:
    enabled: true
  cdi:
    enabled: true
    default: false
  gds:
    enabled: false
  gdrcopy:
    enabled: false
  nodeStatusExporter:
    enabled: true
  validator:
    plugin:
      env:
        - name: WITH_WORKLOAD
          value: "false"
EOF
```

> **Note on `driver.rdma.enabled: false`**: RDMA in the ClusterPolicy requires MOFED (Mellanox OFED). With `enabled: true`, the driver init container waits for the NVIDIA Network Operator to install containerized MOFED — which blocks driver loading if the Network Operator isn't installed. Set to `false` for single-node. If you install RDMA operators (Part B), patch it back:
> ```bash
> oc patch clusterpolicy gpu-cluster-policy --type merge -p '{"spec":{"driver":{"rdma":{"enabled":true}}}}'
> ```

> **Note on `migManager.enabled: true`**: The GPU Operator detects whether MIG is configured on the GPUs. With `enabled: true`, the MIG manager pod runs but takes no action if MIG is not configured — this is the recommended default.

### 2f. Wait for ClusterPolicy Ready

This takes 5-10 minutes as the operator deploys driver containers, device plugin, DCGM exporter, etc.

```bash
echo "Waiting for ClusterPolicy to become ready..."
echo "This takes 5-10 minutes (driver compilation, container pulls)."
while true; do
  STATE=$(oc get clusterpolicy gpu-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null)
  if [ "$STATE" = "ready" ]; then
    echo ""
    echo "ClusterPolicy is ready."
    break
  fi
  echo -n "."
  sleep 15
done
```

### 2g. Verify GPU Operator Pods

```bash
oc get pods -n nvidia-gpu-operator -o wide
```

**Expected**: All pods Running. Key pods to look for:
- `nvidia-driver-daemonset-*` — NVIDIA kernel driver
- `nvidia-device-plugin-daemonset-*` — Exposes GPUs to kubelet
- `nvidia-dcgm-exporter-*` — GPU metrics
- `nvidia-operator-validator-*` — Validates GPU setup
- `gpu-operator-*` — Operator controller

### 2h. Verify GPU Resources on Node

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='Capacity:    {.status.capacity.nvidia\.com/gpu}{"\n"}Allocatable: {.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

**Expected**:

```
Capacity:    8
Allocatable: 8
```

8 H100 GPUs are now schedulable.

### 2i. Verify nvidia-smi

Run `nvidia-smi` via the driver container (the GPU Operator uses containerized drivers, so `nvidia-smi` is only available inside the driver pod):

```bash
DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app.kubernetes.io/component=nvidia-driver -o jsonpath='{.items[0].metadata.name}')
oc exec -n nvidia-gpu-operator $DRIVER_POD -c nvidia-driver-ctr -- nvidia-smi
```

**Expected**: Shows 8x NVIDIA H100 80GB HBM3 GPUs with driver version and CUDA version.

---

# Part B: RDMA Operators (Optional -- Multi-Node Only)

> **Skip this entire section if you have a single GPU node.**
>
> RDMA operators are only needed for multi-node GPU training where NCCL communicates across nodes over the cluster network (ConnectX-7 NICs, RoCE v2). For single-node inference or single-node multi-GPU training, the 8 H100 GPUs communicate via NVLink/NVSwitch within the node -- no RDMA operators required.

---

## Step 3: Install NVIDIA Network Operator (Multi-Node Only)

The NVIDIA Network Operator deploys the RDMA shared device plugin, which discovers RDMA-capable devices and registers them as Kubernetes extended resources.

> **Why not SR-IOV?** IBM Cloud presents the cluster network ConnectX-7 NICs as Virtual Functions (`15b3:101e`) to the guest VM. The OpenShift SR-IOV operator rejects device ID `101e` (not in its supported device list). The RDMA shared device plugin works with any RDMA-capable device without a vendor allowlist.

### 3a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: nvidia-network-operator
EOF
```

### 3b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: nvidia-network-operator
  namespace: nvidia-network-operator
spec:
  targetNamespaces:
    - nvidia-network-operator
EOF
```

### 3c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: nvidia-network-operator
  namespace: nvidia-network-operator
spec:
  channel: v26.1
  installPlanApproval: Automatic
  name: nvidia-network-operator
  source: certified-operators
  sourceNamespace: openshift-marketplace
  startingCSV: nvidia-network-operator.v26.1.0
EOF
```

### 3d. Wait for NVIDIA Network Operator Ready

```bash
echo "Waiting for NVIDIA Network Operator..."
while ! oc get csv -n nvidia-network-operator 2>/dev/null | grep nvidia-network-operator | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "NVIDIA Network Operator installed."
```

Verify:

```bash
oc get csv -n nvidia-network-operator
```

**Expected**: `nvidia-network-operator.v26.1.0` with phase `Succeeded`.

### 3e. Create NicClusterPolicy

The NicClusterPolicy tells the Network Operator to deploy the RDMA shared device plugin, which discovers the 8 Mellanox VFs and registers them as `rdma/rdma_mlx5` resources:

```bash
oc apply -f - <<EOF
apiVersion: mellanox.com/v1alpha1
kind: NicClusterPolicy
metadata:
  name: nic-cluster-policy
spec:
  rdmaSharedDevicePlugin:
    image: k8s-rdma-shared-dev-plugin
    repository: nvcr.io/nvidia/mellanox
    version: network-operator-v26.1.0
    config: |
      {
        "configList": [{
          "resourceName": "rdma_mlx5",
          "rdmaHcaMax": 1000,
          "selectors": {
            "vendors": ["15b3"],
            "deviceIDs": ["101e"],
            "drivers": ["mlx5_core"]
          }
        }]
      }
EOF
```

> **IBM Cloud specifics**:
> - `deviceIDs: ["101e"]` — ConnectX Family mlx5Gen Virtual Function (how IBM Cloud presents ConnectX-7 NICs to the guest)
> - `rdmaHcaMax: 1000` — maximum concurrent RDMA contexts per device (shared mode allows multiple pods to use the same RDMA device)
> - Image repository is `nvcr.io/nvidia/mellanox` (not `nvcr.io/nvidia/cloud-native`)

### 3f. Wait for NicClusterPolicy Ready

```bash
echo "Waiting for NicClusterPolicy..."
while true; do
  STATE=$(oc get nicclusterpolicy nic-cluster-policy -o jsonpath='{.status.state}' 2>/dev/null)
  if [ "$STATE" = "ready" ]; then
    echo ""
    echo "NicClusterPolicy is ready."
    break
  fi
  echo -n "."
  sleep 10
done
```

Verify the RDMA shared device plugin pod is running on the H100:

```bash
oc get pods -n nvidia-network-operator -o wide --no-headers | grep rdma
```

**Expected**: `rdma-shared-dp-ds-*` pod Running on `ocp-gpu-worker-h100`.

### 3g. Verify RDMA Resources

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='Capacity:    {.status.capacity.rdma/rdma_mlx5}{"\n"}Allocatable: {.status.allocatable.rdma/rdma_mlx5}{"\n"}'
```

**Expected**:

```
Capacity:    1k
Allocatable: 1k
```

RDMA resources registered (1000 contexts per `rdmaHcaMax` setting).

### 3h. Verify RDMA Links Active

```bash
oc debug node/ocp-gpu-worker-h100 -- chroot /host rdma link show
```

**Expected**: 8 RDMA links, all `state ACTIVE physical_state LINK_UP`:

```
link mlx5_0/1 state ACTIVE physical_state LINK_UP netdev enp233s0
link mlx5_1/1 state ACTIVE physical_state LINK_UP netdev enp223s0
link mlx5_2/1 state ACTIVE physical_state LINK_UP netdev enp213s0
link mlx5_3/1 state ACTIVE physical_state LINK_UP netdev enp203s0
link mlx5_4/1 state ACTIVE physical_state LINK_UP netdev enp193s0
link mlx5_5/1 state ACTIVE physical_state LINK_UP netdev enp183s0
link mlx5_6/1 state ACTIVE physical_state LINK_UP netdev enp173s0
link mlx5_7/1 state ACTIVE physical_state LINK_UP netdev enp163s0
```

---

# Part C: AI Platform Operators (Required for Model Serving)

---

## Step 6: Install cert-manager Operator

cert-manager manages TLS certificates for RHOAI and KServe.

### 6a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
EOF
```

### 6b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator
  namespace: cert-manager-operator
spec:
  targetNamespaces:
    - cert-manager-operator
EOF
```

### 6c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1.18
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 6d. Wait for cert-manager Ready

```bash
echo "Waiting for cert-manager operator..."
while ! oc get csv -n cert-manager-operator 2>/dev/null | grep cert-manager | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "cert-manager operator installed."
```

Verify:

```bash
oc get csv -n cert-manager-operator
```

**Expected**: `cert-manager-operator.v1.18.1` with phase `Succeeded`.

### 6e. Verify cert-manager Pods

```bash
oc get pods -n cert-manager
```

**Expected**: `cert-manager`, `cert-manager-cainjector`, `cert-manager-webhook` pods Running.

---

## Step 7: Install Red Hat Connectivity Link (RHCL)

RHCL provides API gateway capabilities (AuthPolicy, RateLimitPolicy) used by RHOAI for model serving endpoints.

### 7a. Create Subscription

RHCL installs in `openshift-operators` namespace (global scope, no OperatorGroup needed):

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhcl-operator
  namespace: openshift-operators
spec:
  channel: stable
  installPlanApproval: Automatic
  name: rhcl-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 7b. Wait for RHCL Operator Ready

```bash
echo "Waiting for RHCL operator..."
while ! oc get csv -n openshift-operators 2>/dev/null | grep rhcl-operator | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "RHCL operator installed."
```

### 7c. Approve Sub-Operator Install Plans

RHCL auto-creates subscriptions for Authorino, Limitador, and DNS operators. These may need install plan approval:

```bash
echo "Checking for pending install plans..."
sleep 30
```

List pending install plans:

```bash
oc get installplan -n openshift-operators --no-headers | grep -v Complete
```

If any show `RequiresApproval`, approve them:

```bash
for plan in $(oc get installplan -n openshift-operators --no-headers | awk '{print $1}'); do
  oc patch installplan $plan -n openshift-operators --type merge --patch '{"spec":{"approved":true}}'
done
```

### 7d. Wait for All RHCL Sub-Operators

```bash
echo "Waiting for Authorino, Limitador, DNS operators..."
for op in authorino-operator limitador-operator dns-operator; do
  while ! oc get csv -n openshift-operators 2>/dev/null | grep $op | grep -q Succeeded; do
    sleep 10
    echo -n "."
  done
  echo ""
  echo "$op ready."
done
```

### 7e. Verify RHCL CRDs

```bash
oc get crd | grep -E 'authpolic|ratelimitpolic'
```

**Expected**: `authpolicies.kuadrant.io` and `ratelimitpolicies.kuadrant.io` CRDs exist.

---

## Step 8: Install Leader Worker Set (LWS) Operator

LWS enables leader-worker topology for distributed inference workloads.

### 8a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-lws-operator
EOF
```

### 8b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: openshift-lws-operator
  namespace: openshift-lws-operator
spec:
  targetNamespaces:
    - openshift-lws-operator
EOF
```

### 8c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lws-operator
  namespace: openshift-lws-operator
spec:
  channel: stable-v1.0
  installPlanApproval: Automatic
  name: leader-worker-set
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 8d. Wait for LWS Operator Ready

```bash
echo "Waiting for LWS operator..."
while ! oc get csv -n openshift-lws-operator 2>/dev/null | grep leader-worker-set | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "LWS operator installed."
```

Verify:

```bash
oc get csv -n openshift-lws-operator
```

**Expected**: `leader-worker-set.v1.0.0` with phase `Succeeded`.

### 8e. Create LeaderWorkerSetOperator CR

The LWS operator follows the meta-operator pattern — the CSV deploys the operator pod, but the actual LWS controller and `LeaderWorkerSet` CRD are only created when you create the operand CR:

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

### 8f. Wait for LWS CRD

```bash
echo "Waiting for LeaderWorkerSet CRD..."
while ! oc get crd leaderworkersets.leaderworkerset.x-k8s.io --no-headers 2>/dev/null | grep -q leaderworkersets; do
  sleep 5
  echo -n "."
done
echo ""
echo "LeaderWorkerSet CRD available."
```

Verify:

```bash
oc get leaderworkersetoperators.operator.openshift.io cluster \
  -o jsonpath='Available: {.status.conditions[?(@.type=="Available")].status}'; echo ""
```

**Expected**: `Available: True`

> **Why this step?** Without the `LeaderWorkerSetOperator` CR, the `LeaderWorkerSet` CRD (`leaderworkerset.x-k8s.io/v1`) does not exist. LLMInferenceService (Phase 6) requires this CRD and will fail with `no matches for kind "LeaderWorkerSet" in version "leaderworkerset.x-k8s.io/v1"` if it's missing.

---

## Step 9: Install Red Hat OpenShift AI (RHOAI) 3.0

RHOAI provides the model serving platform (KServe, data science pipelines, model registry).

### 9a. Create Namespace

```bash
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: redhat-ods-operator
  labels:
    openshift.io/cluster-monitoring: "true"
EOF
```

### 9b. Create OperatorGroup

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: redhat-ods-operator
  namespace: redhat-ods-operator
spec: {}
EOF
```

> Note: Empty `spec` (no `targetNamespaces`) gives RHOAI cluster-wide scope, which it requires.

### 9c. Create Subscription

```bash
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: rhods-operator
  namespace: redhat-ods-operator
spec:
  channel: fast-3.x
  installPlanApproval: Automatic
  name: rhods-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF
```

### 9d. Wait for RHOAI Operator Ready

RHOAI takes longer to install (pulls multiple images):

```bash
echo "Waiting for RHOAI operator (this may take 3-5 minutes)..."
while ! oc get csv -n redhat-ods-operator 2>/dev/null | grep rhods-operator | grep -q Succeeded; do
  sleep 15
  echo -n "."
done
echo ""
echo "RHOAI operator installed."
```

### 9e. Approve Service Mesh 3 Install Plan

RHOAI auto-installs Service Mesh 3. Check for pending install plans:

```bash
sleep 30
echo "Checking for Service Mesh install plan..."
oc get installplan -n openshift-operators --no-headers | grep -v Complete
```

If any show `RequiresApproval`:

```bash
for plan in $(oc get installplan -n openshift-operators --no-headers | awk '{print $1}'); do
  oc patch installplan $plan -n openshift-operators --type merge --patch '{"spec":{"approved":true}}'
done
```

Also check `redhat-ods-operator` namespace:

```bash
oc get installplan -n redhat-ods-operator --no-headers | grep -v Complete
```

```bash
for plan in $(oc get installplan -n redhat-ods-operator --no-headers | awk '{print $1}'); do
  oc patch installplan $plan -n redhat-ods-operator --type merge --patch '{"spec":{"approved":true}}'
done
```

### 9f. Fix Service Mesh Chain Upgrade (if stuck)

Service Mesh may install via a chain upgrade (e.g., v3.0.8 → v3.1.0 → v3.2.2). The intermediate CSV (v3.1.0) can fail with a CRD migration error (`risk of data loss updating ztunnels.sailoperator.io`), blocking the final version.

Check for stuck intermediate CSVs:

```bash
oc get csv -n openshift-operators --no-headers | grep servicemesh
```

If you see an intermediate version in `Pending` or `Failed` alongside the target version, delete the stuck intermediate:

```bash
# Example: delete stuck v3.1.0 to unblock v3.2.2
STUCK_CSV=$(oc get csv -n openshift-operators --no-headers | grep servicemesh | grep -v Succeeded | awk '{print $1}' | head -1)
if [ -n "$STUCK_CSV" ]; then
  echo "Deleting stuck CSV: $STUCK_CSV"
  oc delete csv $STUCK_CSV -n openshift-operators
fi
```

### 9g. Wait for Service Mesh Operator

```bash
echo "Waiting for Service Mesh operator..."
while ! oc get csv -n openshift-operators 2>/dev/null | grep servicemesh | grep -q Succeeded; do
  sleep 10
  echo -n "."
done
echo ""
echo "Service Mesh operator installed."
```

### 9h. Verify Both Operators

```bash
oc get csv -n redhat-ods-operator
oc get csv -n openshift-operators | grep servicemesh
```

**Expected**:
- `rhods-operator.v3.3.0` — Succeeded
- `servicemeshoperator3.v3.2.1` — Succeeded

---

# Part D: Configure Model Serving (Required)

---

## Step 10: Wait for DSCInitialization

RHOAI automatically creates a `DSCInitialization` resource. Wait for it to reconcile:

```bash
echo "Waiting for DSCInitialization..."
while true; do
  PHASE=$(oc get dscinitializations default-dsci -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$PHASE" = "Ready" ]; then
    echo ""
    echo "DSCInitialization is Ready."
    break
  fi
  COND=$(oc get dscinitializations default-dsci -o jsonpath='{.status.conditions[?(@.type=="ReconcileComplete")].status}' 2>/dev/null)
  if [ "$COND" = "True" ]; then
    echo ""
    echo "DSCInitialization reconcile complete."
    break
  fi
  echo -n "."
  sleep 10
done
```

Verify:

```bash
oc get dscinitializations
```

**Expected**: `default-dsci` with status progressing towards Ready.

---

## Step 11: Create DataScienceCluster

Create a minimal DataScienceCluster with only KServe enabled:

```bash
oc apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v1
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    codeflare:
      managementState: Removed
    dashboard:
      managementState: Removed
    datasciencepipelines:
      managementState: Removed
    kserve:
      managementState: Managed
      serving:
        ingressGateway:
          certificate:
            type: SelfSigned
        managementState: Managed
        name: knative-serving
    kueue:
      managementState: Removed
    modelmeshserving:
      managementState: Removed
    modelregistry:
      managementState: Removed
    ray:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    trustyai:
      managementState: Removed
    workbenches:
      managementState: Removed
EOF
```

### 11a. Wait for DataScienceCluster Ready

This takes 3-5 minutes as it deploys KServe, Knative Serving, and Istio gateway:

```bash
echo "Waiting for DataScienceCluster to become Ready..."
echo "This takes 3-5 minutes."
while true; do
  PHASE=$(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$PHASE" = "Ready" ]; then
    echo ""
    echo "DataScienceCluster is Ready."
    break
  fi
  echo -n "."
  sleep 15
done
```

---

## Step 12: Final Verification

### 12a. DataScienceCluster Status

```bash
oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}'
```

**Expected**: `Ready`

### 12b. Service Mesh / Istio Gateway

Service Mesh 3 runs in `openshift-ingress` (not `istio-system`):

```bash
oc get pods -n openshift-ingress | grep -E "istiod|gateway"
```

**Expected**: `istiod-*` and `data-science-gateway-*` pods Running.

### 12c. GatewayClass

```bash
oc get gatewayclass
```

**Expected**: `data-science-gateway-class` with status `Accepted: True`.

### 12d. KServe Controller

```bash
oc get pods -n redhat-ods-applications | grep kserve
```

**Expected**: `kserve-controller-manager` pod Running.

### 12e. GPU Resources

```bash
oc get node ocp-gpu-worker-h100 -o jsonpath='Capacity:    {.status.capacity.nvidia\.com/gpu}{"\n"}Allocatable: {.status.allocatable.nvidia\.com/gpu}{"\n"}'
```

**Expected**:

```
Capacity:    8
Allocatable: 8
```

### 12f. All Operator CSVs

OLM copies global-scope CSVs into every namespace, so filter by name to see only the relevant operator per section:

```bash
echo "=== Operator Status ==="
echo ""
echo "--- NFD ---"
oc get csv -n openshift-nfd --no-headers 2>/dev/null | grep nfd
echo ""
echo "--- GPU Operator ---"
oc get csv -n nvidia-gpu-operator --no-headers 2>/dev/null | grep gpu-operator
echo ""
echo "--- Network Operator ---"
oc get csv -n nvidia-network-operator --no-headers 2>/dev/null | grep nvidia-network
echo ""
echo "--- cert-manager ---"
oc get csv -n cert-manager-operator --no-headers 2>/dev/null | grep cert-manager
echo ""
echo "--- RHCL + sub-operators ---"
oc get csv -n openshift-operators --no-headers 2>/dev/null | grep -E 'rhcl|authorino|limitador|dns-operator|servicemesh'
echo ""
echo "--- LWS ---"
oc get csv -n openshift-lws-operator --no-headers 2>/dev/null | grep leader-worker
echo ""
echo "--- RHOAI ---"
oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods
```

All should show `Succeeded`.

### 12g. GPU Operator Pods

```bash
oc get pods -n nvidia-gpu-operator --no-headers | grep -v Running | grep -v Completed
```

Should return nothing (all pods Running or Completed).

### 12h. Summary

```bash
echo ""
echo "========================================"
echo "Phase 5 Complete"
echo "========================================"
echo ""
echo "GPU Resources:"
oc get node ocp-gpu-worker-h100 -o jsonpath='  nvidia.com/gpu:  {.status.allocatable.nvidia\.com/gpu}{"\n"}  rdma/rdma_mlx5:  {.status.allocatable.rdma/rdma_mlx5}{"\n"}'
echo ""
echo "Operators Installed:"
echo "  NFD:              $(oc get csv -n openshift-nfd --no-headers 2>/dev/null | grep nfd | awk '{print $1, $NF}')"
echo "  GPU Operator:     $(oc get csv -n nvidia-gpu-operator --no-headers 2>/dev/null | grep gpu-operator | awk '{print $1, $NF}')"
echo "  Network Operator: $(oc get csv -n nvidia-network-operator --no-headers 2>/dev/null | grep nvidia-network | awk '{print $1, $NF}')"
echo "  cert-manager:     $(oc get csv -n cert-manager-operator --no-headers 2>/dev/null | grep cert-manager | awk '{print $1, $NF}')"
echo "  RHCL:             $(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep rhcl | awk '{print $1, $NF}')"
echo "  LWS:              $(oc get csv -n openshift-lws-operator --no-headers 2>/dev/null | grep leader-worker | awk '{print $1, $NF}')"
echo "  RHOAI:            $(oc get csv -n redhat-ods-operator --no-headers 2>/dev/null | grep rhods | awk '{print $1, $NF}')"
echo "  Service Mesh:     $(oc get csv -n openshift-operators --no-headers 2>/dev/null | grep servicemesh | awk '{print $1, $NF}')"
echo ""
echo "DataScienceCluster: $(oc get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null)"
echo "GatewayClass:       $(oc get gatewayclass data-science-gateway-class -o jsonpath='{.status.conditions[0].type}={.status.conditions[0].status}' 2>/dev/null)"
echo ""
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 5, you should have:

- [x] **NFD Operator** — GPU node labeled with `feature.node.kubernetes.io/pci-10de.present=true`
- [x] **NVIDIA GPU Operator** — ClusterPolicy ready, `nvidia.com/gpu: 8` on H100 node
- [x] **cert-manager** — TLS certificate management for RHOAI
- [x] **RHCL** — API gateway (Authorino, Limitador, DNS sub-operators)
- [x] **LWS** — Leader-worker set topology for distributed inference
- [x] **RHOAI** — OpenShift AI platform with Service Mesh 3
- [x] **DataScienceCluster** — KServe managed, Istio gateway healthy
- [x] **nvidia-smi** — Shows 8x H100 80GB GPUs
- [x] **All CSVs** — Succeeded

---

## Cost

No additional cost from operators — they run on the existing control plane nodes (master nodes have `worker` role). The GPU Operator deploys DaemonSet pods on the H100 worker, but no new instances are created.

---

## Troubleshooting

### ClusterPolicy Stuck (Not Reaching "ready")

Check GPU operator pods for errors:

```bash
oc get pods -n nvidia-gpu-operator | grep -v Running | grep -v Completed
```

Check driver pod logs:

```bash
DRIVER_POD=$(oc get pods -n nvidia-gpu-operator -l app=nvidia-driver-daemonset -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
oc logs -n nvidia-gpu-operator $DRIVER_POD --tail=50
```

Common issues:
- **Driver compilation fails**: Kernel headers mismatch. Check `oc get nodes -o wide` for OS version and ensure driver toolkit image matches.
- **Pod stuck in Init**: Image pull issues. Check `oc get events -n nvidia-gpu-operator --sort-by=.lastTimestamp | tail -20`.

### NFD Not Labeling GPU Node

```bash
oc get pods -n openshift-nfd -l app.kubernetes.io/component=worker -o wide
```

Ensure an NFD worker pod is running on the H100 node. Check its logs:

```bash
NFD_POD=$(oc get pods -n openshift-nfd -l app.kubernetes.io/component=worker --field-selector spec.nodeName=ocp-gpu-worker-h100 -o jsonpath='{.items[0].metadata.name}')
oc logs -n openshift-nfd $NFD_POD --tail=30
```

### RHOAI DSCInitialization Not Created

If `default-dsci` doesn't appear after 5 minutes:

```bash
oc get pods -n redhat-ods-operator
```

Check operator logs:

```bash
oc logs -n redhat-ods-operator deployment/rhods-operator --tail=50
```

### DataScienceCluster Not Reaching Ready

```bash
oc get datasciencecluster default-dsc -o yaml | grep -A 20 "status:"
```

Check for failed conditions. Common issue: Service Mesh not ready. Verify:

```bash
oc get csv -n openshift-operators | grep servicemesh
```

If not `Succeeded`, check install plans (Step 9e).

### Sub-Operator Install Plans Stuck

List all install plans across relevant namespaces:

```bash
for ns in openshift-operators redhat-ods-operator cert-manager-operator; do
  echo "--- $ns ---"
  oc get installplan -n $ns --no-headers 2>/dev/null
done
```

Approve any that are not `Complete`:

```bash
for ns in openshift-operators redhat-ods-operator; do
  for plan in $(oc get installplan -n $ns --no-headers 2>/dev/null | grep -v Complete | awk '{print $1}'); do
    echo "Approving $plan in $ns"
    oc patch installplan $plan -n $ns --type merge --patch '{"spec":{"approved":true}}'
  done
done
```

---

## Next Steps

After Phase 5 completes, the cluster is ready for AI/ML model serving:

1. **Deploy inference models** using KServe `InferenceService` resources
2. **Request GPU resources** in pods with `nvidia.com/gpu: N` in resource limits
3. **(Future)** For multi-node training, return to Part B to install RDMA operators

---

**Phase 5 Complete!**

**All operators installed. 8x H100 GPUs available. KServe model serving ready. DataScienceCluster in Ready state.**
