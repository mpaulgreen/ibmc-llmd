# Phase 3: Create Cluster Network and Provision H100 GPU Instance

## Overview

This phase creates the RDMA cluster network from scratch, provisions an H100 GPU instance, and attaches the cluster network interfaces for RDMA connectivity.

**What You'll Accomplish:**
- Create the cluster network with `hopper-1` profile
- Create 8 cluster network subnets (one per GPU rail)
- Use the RHCOS image for the OpenShift worker node
- Create the GPU instance with VPC management network
- Stop instance (required for cluster network attachment)
- Create and attach 8 cluster network interfaces (one per GPU rail)
- Start instance and initialize RDMA fabric
- Create floating IP for SSH access
- Validate GPU and RDMA hardware

**Estimated Time**: 30-45 minutes

## Pre-Flight Checks

Before starting, ensure Phase 2 is complete:

- [ ] OpenShift cluster deployed and healthy
- [ ] 3 master nodes in Ready state
- [ ] Environment file loaded: `source ~/.ibmcloud-h100-env`
- [ ] IBM Cloud CLI logged in

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
ibmcloud target
```

Verify region is `eu-de`.

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
oc get nodes
```

Should show 3 master nodes in Ready state.

---

## Step-by-Step Instructions

### Step 1: Load Environment

```bash
source ~/.ibmcloud-h100-env
```

Verify key variables are set (saved in Phase 2):

```bash
echo "VPC_ID:        $VPC_ID"
echo "MGMT_SUBNET_ID: $MGMT_SUBNET_ID"
echo "OCP_SG_ID:     $OCP_SG_ID"
```

If any are empty, recover them:

```bash
[ -z "$VPC_ID" ] && export VPC_ID=$(ibmcloud is vpcs --output json | jq -r '.[] | select(.name=="rdma-pvc-eude") | .id') && sed -i '' "s/^export VPC_ID=.*/export VPC_ID=$VPC_ID/" ~/.ibmcloud-h100-env
[ -z "$MGMT_SUBNET_ID" ] && export MGMT_SUBNET_ID=$(ibmcloud is subnets --output json | jq -r '.[] | select(.name=="ocp-mgmt-subnet") | .id') && sed -i '' "s/^export MGMT_SUBNET_ID=.*/export MGMT_SUBNET_ID=$MGMT_SUBNET_ID/" ~/.ibmcloud-h100-env
[ -z "$OCP_SG_ID" ] && export OCP_SG_ID=$(ibmcloud is security-groups --output json | jq -r '.[] | select(.name=="ocp-h100-cluster-sg") | .id') && sed -i '' "s/^export OCP_SG_ID=.*/export OCP_SG_ID=$OCP_SG_ID/" ~/.ibmcloud-h100-env
echo "VPC_ID=$VPC_ID  MGMT_SUBNET_ID=$MGMT_SUBNET_ID  OCP_SG_ID=$OCP_SG_ID"
```

### Step 2: Login to IBM Cloud

```bash
ibmcloud_login
```

---

### Step 3: Create Cluster Network

> **What this creates**: A managed RDMA fabric for H100 GPU instances using the `hopper-1` profile. This provides 8x 400 Gbps ConnectX-7 NICs (3.2 Tbps total bandwidth) with RoCE v2 and GPU Direct RDMA.

#### 3a. Check for Existing Cluster Network

```bash
ibmcloud is cluster-networks --output json | jq -r '.[] | select(.name=="rdma-cluster") | {name, id, lifecycle_state}'
```

**If empty** — no cluster network exists. Proceed to 3b.

**If a cluster network is shown** — set `export CN_ID=<id>` and skip to Step 4.

#### 3b. Create Cluster Network

```bash
ibmcloud is cluster-network-create \
  --vpc $VPC_ID \
  --zone $IBMCLOUD_ZONE \
  --profile hopper-1 \
  --name rdma-cluster \
  --subnet-prefixes-cidr 10.0.0.0/9 \
  --output json > /tmp/cluster-network-create.json
```

#### 3c. Get Cluster Network ID

```bash
export CN_ID=$(jq -r '.id' /tmp/cluster-network-create.json)
echo "Cluster Network ID: $CN_ID"
```

#### 3d. Wait for Cluster Network to be Stable

```bash
while true; do
  STATUS=$(ibmcloud is cluster-network $CN_ID --output json | jq -r '.lifecycle_state')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  [ "$STATUS" = "stable" ] && break
  sleep 10
done
echo "Cluster network is ready"
```

#### 3e. Save to Environment File

```bash
sed -i '' "s/^export CN_ID=.*/export CN_ID=$CN_ID/" ~/.ibmcloud-h100-env
```

---

### Step 4: Create 8 Cluster Network Subnets

> **Why 8 subnets?** The `hopper-1` profile does NOT auto-create subnets. Each H100 has 8 GPU rails, each needing its own cluster network subnet. Each /18 subnet provides 16,384 addresses.

#### 4a. Create Subnets

```bash
for i in $(seq 1 8); do
  idx=$((i-1))
  echo -n "Creating rdma-subnet-${idx}... "
  ibmcloud is cluster-network-subnet-create $CN_ID \
    --total-ipv4-address-count 16384 \
    --name "rdma-subnet-${idx}" \
    --output json > /tmp/cn-subnet-${idx}.json
  echo "$(jq -r '.id' /tmp/cn-subnet-${idx}.json)"
done
echo "Done"
```

#### 4b. Save Subnet IDs to Environment File

```bash
for i in $(seq 0 7); do
  SUBNET_ID=$(jq -r '.id' /tmp/cn-subnet-${i}.json)
  sed -i '' "s/^export CN_SUBNET_ID_${i}=.*/export CN_SUBNET_ID_${i}=$SUBNET_ID/" ~/.ibmcloud-h100-env
done
source ~/.ibmcloud-h100-env
echo "Saved all 8 subnet IDs to env file"
```

---

### Step 5: Verify Cluster Network and Subnets

#### 5a. Verify Cluster Network

```bash
ibmcloud is cluster-network $CN_ID --output json | jq '{name, id, lifecycle_state, profile: .profile.name, subnet_prefix: .subnet_prefixes[0].cidr}'
```

**Expected**: name `rdma-cluster`, lifecycle_state `stable`, profile `hopper-1`, subnet_prefix `10.0.0.0/9`

#### 5b. Verify All 8 Subnets

```bash
ibmcloud is cluster-network-subnets $CN_ID --output json | \
  jq -r '.ClusterNetworkSubnets[] | "\(.name): \(.ipv4_cidr_block) [\(.lifecycle_state)]"' | sort
```

**Expected**: 8 subnets (`rdma-subnet-0` through `rdma-subnet-7`), all `stable`, each with a /18 CIDR from the 10.0.0.0/9 range.

#### 5c. Verify Env File Saved Correctly

```bash
for i in $(seq 0 7); do
  eval echo "CN_SUBNET_ID_$i=\$CN_SUBNET_ID_$i"
done
```

All 8 should show non-empty IDs.

---

### Step 6: Set RHCOS Image

Use the RHCOS custom image imported during Phase 2 (Step 7). The instance boots with the worker ignition config and joins the OpenShift cluster automatically. NVIDIA drivers are installed later via the GPU Operator (Phase 6).

```bash
export IMAGE_ID=$(ibmcloud is images --visibility private --output json | jq -r '.[] | select(.name=="ocp-rhcos") | .id')
export IMAGE_NAME=$(ibmcloud is image $IMAGE_ID --output json | jq -r '.name')
echo "Using image: $IMAGE_NAME ($IMAGE_ID)"
```

If empty, you need to import RHCOS first — see Phase 2 Step 7.

---

### Step 7: Check for Existing H100 Instance

```bash
EXISTING_INSTANCE=$(ibmcloud is instances --output json | jq -r '.[] | select(.name == "ocp-gpu-worker-h100") | .id')
echo "Existing instance: ${EXISTING_INSTANCE:-none}"
```

**If empty** — no existing instance. Proceed to Step 8.

**If an instance ID is shown** — instance already exists. Choose:

- **Use it**: Set `export H100_INSTANCE_ID=$EXISTING_INSTANCE` and skip to Step 10 (or Step 11 if it's running and you need to attach cluster networks).
- **Delete and recreate**: `ibmcloud is instance-delete $EXISTING_INSTANCE --force` then wait 30s and proceed to Step 8.

---

### Step 8: Create H100 Instance

#### 8a. Verify Worker Ignition Config

> **Why user-data?** The IBM Cloud `--keys` flag silently fails for GPU instances. For RHCOS, the worker ignition config is passed via `--user-data` — this configures the node to join the OpenShift cluster.

```bash
# The worker.ign was generated in Phase 2 Step 4c
ls -la ~/ocp-h100-upi-install/worker.ign
```

#### 8b. Review Configuration

```bash
cat << EOF

========================================
H100 Instance Configuration
========================================

Name:              ocp-gpu-worker-h100
Profile:           $GPU_PROFILE
VPC:               $VPC_NAME ($VPC_ID)
Zone:              $IBMCLOUD_ZONE
Management Subnet: $MGMT_SUBNET_ID
Security Group:    $OCP_SG_ID (ocp-h100-cluster-sg — same as masters)
Image:             $IMAGE_NAME

Instance Specs (gx3d-160x1792x8h100):
  - 160 vCPUs
  - 1.75TB RAM
  - 8x NVIDIA H100 SXM5 GPUs (80GB each)
  - 640GB total GPU memory

Cost: ~\$30-40 per hour while running

========================================

EOF
```

#### 8c. Create Instance

```bash
ibmcloud is instance-create ocp-gpu-worker-h100 \
  $VPC_ID \
  eu-de-2 \
  $GPU_PROFILE \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/worker.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/h100-instance.json
```

#### 8d. Get and Save Instance ID

```bash
export H100_INSTANCE_ID=$(jq -r '.id' /tmp/h100-instance.json)
echo "H100 Instance ID: $H100_INSTANCE_ID"
```

If empty or `null`, check the output: `cat /tmp/h100-instance.json`

Save to environment file:

```bash
sed -i '' "s/^export H100_INSTANCE_ID=.*/export H100_INSTANCE_ID=$H100_INSTANCE_ID/" ~/.ibmcloud-h100-env
source ~/.ibmcloud-h100-env
```

---

### Step 9: Wait for Instance to Start

```bash
while true; do
  STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "running" ]; then
    echo "Instance is running"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "Instance failed to start"
    ibmcloud is instance $H100_INSTANCE_ID
    break
  fi
  sleep 10
done
```

**Expected time**: 2-5 minutes

---

### Step 10: Get Instance Details

```bash
ibmcloud is instance $H100_INSTANCE_ID --output json > /tmp/h100-instance-details.json

echo "Name:       $(jq -r '.name' /tmp/h100-instance-details.json)"
echo "Status:     $(jq -r '.status' /tmp/h100-instance-details.json)"
echo "Zone:       $(jq -r '.zone.name' /tmp/h100-instance-details.json)"
echo "Private IP: $(jq -r '.primary_network_interface.primary_ip.address' /tmp/h100-instance-details.json)"
echo "Profile:    $GPU_PROFILE"
```

---

### Step 11: Stop Instance for Cluster Network Attachment

> **CRITICAL**: Cluster network interfaces can ONLY be attached when the instance is STOPPED.

#### 11a. Stop the Instance

```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
```

#### 11b. Wait for Stop

```bash
while true; do
  STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "stopped" ]; then
    echo "Instance stopped"
    break
  fi
  sleep 10
done
```

**Expected time**: 1-2 minutes

---

### Step 12: Create and Attach Cluster Network Interfaces

Now we create 8 cluster network interfaces (one per GPU rail) and attach them to the stopped H100 instance.

#### 12a. Create 8 Cluster Network Interfaces

```bash
echo "Creating 8 cluster network interfaces..."
for i in $(seq 0 7); do
  eval SUBNET_ID=\$CN_SUBNET_ID_$i
  echo -n "  Rail $i: "
  ibmcloud is cluster-network-interface-create $CN_ID \
    --subnet $SUBNET_ID \
    --rip-auto-delete true \
    --rip-name "h100-rail-${i}-rip" \
    --name "h100-gpu-rail-${i}" \
    --output json | jq -r '"\(.name) | \(.id) | \(.lifecycle_state)"'
done
echo "Done"
```

#### 12b. Attach 8 Interfaces to Instance

```bash
echo "Attaching 8 interfaces to H100..."
for i in $(seq 0 7); do
  IFACE_ID=$(ibmcloud is cluster-network-interfaces $CN_ID --output json | \
    jq -r ".[] | select(.name==\"h100-gpu-rail-${i}\") | .id")
  echo -n "  Rail $i ($IFACE_ID): "
  ibmcloud is instance-cluster-network-attachment-create $H100_INSTANCE_ID \
    --cni $IFACE_ID \
    --cluster-network $CN_ID \
    --name "h100-gpu-rail-${i}" \
    --output json | jq -r '"\(.name) | \(.lifecycle_state)"'
done
echo "Done"
```

---

### Step 13: Verify All Attachments

```bash
echo "Attachments: $(ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json | jq '. | length') (expected: 8)"
echo ""
ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json | \
  jq -r '.[] | "\(.name): \(.lifecycle_state)"'
```

All 8 should show `stable` (or `pending` if still configuring — they'll become `stable` when the instance starts).

---

### Step 14: Start H100 Instance

#### 14a. Start Instance

```bash
ibmcloud is instance-start $H100_INSTANCE_ID
```

#### 14b. Wait for Running

> **Note**: Starting with cluster networks takes 10-15 minutes — the RDMA fabric and GPU Fabric Manager must initialize. This is expected.

```bash
while true; do
  STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "running" ]; then
    echo "Instance is running"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "Instance failed to start"
    break
  fi
  sleep 15
done
```

---

### Step 15: Create Floating IP for SSH Access

> **IMPORTANT**: IBM Cloud uses the VirtualNetworkInterface (VNI) model. The floating IP attaches with `--vni`, NOT `--nic`.

#### 15a. Get the Virtual Network Interface ID

```bash
H100_VNI=$(ibmcloud is instance $H100_INSTANCE_ID --output json | \
  jq -r '.network_attachments[0].virtual_network_interface.id')
echo "VNI: $H100_VNI"
```

#### 15b. Create Floating IP

```bash
ibmcloud is floating-ip-reserve h100-fip --vni $H100_VNI --output json | jq '{name, address}'
```

> If `h100-fip` already exists, get its address instead:
> ```bash
> ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h100-fip") | .address'
> ```

#### 15c. Get Floating IP Address

```bash
export H100_FIP=$(ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h100-fip") | .address')
echo "H100 Floating IP: $H100_FIP"
```

#### 15d. Save to Environment

```bash
grep -q "H100_FIP" ~/.ibmcloud-h100-env || echo "export H100_FIP=$H100_FIP" >> ~/.ibmcloud-h100-env
```

---

### Step 16: Validate Hardware

> Wait 10-15 minutes after start before attempting SSH. The GPU instance needs time for RDMA fabric initialization and Fabric Manager startup.

#### 16a. Test SSH Connectivity

SSH as `core` (the default RHCOS user):

```bash
ssh -o ConnectTimeout=60 -i ~/.ssh/id_rsa core@$H100_FIP "hostname && uptime"
```

If connection times out, wait a few more minutes and retry — RHCOS with cluster networks takes 10-15 minutes to fully boot.

#### 16b. Verify Instance Joined the Cluster

From your local machine (not SSH):

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
oc get nodes
```

The H100 worker should appear (may show `NotReady` until CSRs are approved in Phase 4).

#### 16c. Verify RDMA Devices (on instance via SSH)

> **Note**: GPU validation (`nvidia-smi`) and full RDMA tools (`ibv_devices`, `rdma link`) are not available on RHCOS until the GPU Operator (Phase 6) and NVIDIA Network Operator (Phase 5) are installed. For now, verify basic network connectivity.

```bash
ssh core@$H100_FIP "ip link show | grep -c enp"
```

**Expected**: Multiple network interfaces (1 management + 8 RDMA).

---

### Step 17: Final Summary

```bash
echo ""
echo "========================================"
echo "H100 Instance Summary"
echo "========================================"
echo ""
echo "Instance ID:     $H100_INSTANCE_ID"
echo "Status:          $(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')"
echo "Private IP:      $(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.primary_network_interface.primary_ip.address')"
echo "Floating IP:     $H100_FIP"
echo "Profile:         $GPU_PROFILE"
echo "Image:           $IMAGE_NAME"
echo ""
echo "Cluster Network: $CN_NAME (hopper-1)"
echo "Attachments:     $(ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json | jq '. | length') (expected: 8)"
echo "Bandwidth:       3.2 Tbps (8x 400 Gbps ConnectX-7)"
echo ""
echo "GPUs:            8x NVIDIA H100 SXM5 (80GB each)"
echo "Total GPU Mem:   640GB"
echo ""
echo "Cost:            ~\$30-40/hour while running"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 3, you should have:

- [x] Cluster network created (`rdma-cluster`, `hopper-1` profile)
- [x] 8 cluster network subnets created (`rdma-subnet-0` through `rdma-subnet-7`)
- [x] H100 instance created (`gx3d-160x1792x8h100` profile)
- [x] 8x H100 GPUs provisioned
- [x] VPC management network attached (primary interface)
- [x] 8 cluster network interfaces created and attached (all `stable`)
- [x] Instance running with RDMA fabric initialized
- [x] Floating IP assigned for SSH access
- [x] All resource IDs saved to `~/.ibmcloud-h100-env`

---

## Cost Management

The H100 instance is **RUNNING** and **ACCRUING COSTS** (~$30-40/hour).

**To stop costs temporarily:**

```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
```

**To resume:**

```bash
ibmcloud is instance-start $H100_INSTANCE_ID
```

> Starting with cluster networks attached takes 10-15 minutes.

---

## Teardown

To delete all Phase 3 resources (reverse order of creation):

### 1. Delete Floating IP

```bash
ibmcloud is floating-ip-release h100-fip --force
```

### 2. Delete H100 Instance

```bash
ibmcloud is instance-delete $H100_INSTANCE_ID --force
```

Wait for deletion to complete (~30s):

```bash
while ibmcloud is instance $H100_INSTANCE_ID --output json 2>/dev/null | jq -r '.status' 2>/dev/null; do
  echo "  Waiting for instance deletion..."
  sleep 10
done
echo "Instance deleted"
```

### 3. Delete Cluster Network Interfaces

```bash
for IFACE_ID in $(ibmcloud is cluster-network-interfaces $CN_ID --output json | jq -r '.[].id'); do
  echo -n "Deleting interface $IFACE_ID... "
  ibmcloud is cluster-network-interface-delete $CN_ID $IFACE_ID --force 2>&1
done
```

### 4. Delete 8 Cluster Network Subnets

```bash
for SUBNET_ID in $(ibmcloud is cluster-network-subnets $CN_ID --output json | jq -r '.ClusterNetworkSubnets[].id'); do
  echo -n "Deleting subnet $SUBNET_ID... "
  ibmcloud is cluster-network-subnet-delete $CN_ID $SUBNET_ID --force 2>&1
done
```

### 5. Delete Cluster Network

```bash
ibmcloud is cluster-network-delete $CN_ID --force
```

### 6. Clear Environment Variables

```bash
sed -i '' "s/^export CN_ID=.*/export CN_ID=/" ~/.ibmcloud-h100-env
sed -i '' "s/^export H100_INSTANCE_ID=.*/export H100_INSTANCE_ID=/" ~/.ibmcloud-h100-env
for i in $(seq 0 7); do
  sed -i '' "s/^export CN_SUBNET_ID_${i}=.*/export CN_SUBNET_ID_${i}=/" ~/.ibmcloud-h100-env
done
source ~/.ibmcloud-h100-env
echo "Environment variables cleared"
```

---

## Troubleshooting

### Instance Creation Fails with Quota Error

Check VPC quotas in IBM Cloud console. Delete unused instances or request quota increase.

### Cannot Attach Cluster Network (Instance Not Stopped)

```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
# Wait for stopped status, then retry attachment
```

### Cluster Network Interface Creation Fails

Check cluster network state — must be `stable`:

```bash
ibmcloud is cluster-network $CN_ID --output json | jq -r '.lifecycle_state'
```

### Instance Takes Too Long to Start (>20 min)

Starting with cluster networks attached takes 10-15 minutes due to RDMA fabric initialization. If >20 minutes, check the instance in IBM Cloud console for errors.

### Floating IP Already Exists

If `h100-fip` exists from a previous run:

```bash
export H100_FIP=$(ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h100-fip") | .address')
```

### Lost Track of Interfaces

```bash
ibmcloud is cluster-network-interfaces $CN_ID --output json | \
  jq -r '.[] | select(.name | startswith("h100-gpu-rail")) | "\(.name) | \(.id)"'
```

### Cluster Network Subnet Creation Returns Error

The `hopper-1` profile uses `--total-ipv4-address-count 16384` (not a CIDR). If you get a validation error, check that `CN_ID` is set and the cluster network is `stable`.

---

## Next Steps

You're ready for **[Phase 4: Integrate H100 as Worker Node](PHASE4-WORKER-INTEGRATION.md)**

This phase will:
- Join the H100 instance to the OpenShift cluster
- Approve Certificate Signing Requests (CSRs)
- Apply appropriate labels to the worker node

**Before proceeding**, ensure:
- H100 instance is running
- All 8 cluster network attachments are stable
- OpenShift cluster is healthy (3 masters Ready)

---

**Phase 3 Complete!**

**Cluster network created, H100 instance provisioned with RDMA. Costs accruing (~$30-40/hour).**
