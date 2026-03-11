# Phase 3B: Provision H200 GPU Instance

## Overview

This phase provisions an H200 GPU instance and attaches it to the existing RDMA cluster network. The cluster network (`rdma-cluster`) and its 8 subnets were created in Phase 3 — no new network resources are needed.

**What You'll Accomplish:**
- Verify the existing cluster network and subnets
- Provision H200 instance (`ocp-gpu-worker-h200-0`)
- Stop instance, attach 8 cluster network interfaces, and restart
- Create floating IP for SSH access
- Validate hardware

**Estimated Time**: 20-30 minutes

**Key Difference from Phase 3**: The cluster network already exists. Each H200 has 141GB HBM3e per GPU (vs H100's 80GB HBM3).

## Pre-Flight Checks

Before starting, ensure:

- [ ] OpenShift cluster deployed and healthy
- [ ] 3 master nodes in Ready state (H100 worker may be stopped — that's OK)
- [ ] Cluster network `rdma-cluster` exists (created in Phase 3)
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

Should show 3 master nodes in Ready state (H100 worker may show NotReady if stopped).

---

## Step-by-Step Instructions

### Part A: Prerequisites

#### Step 1: Load Environment and Verify Cluster Network

```bash
source ~/.ibmcloud-h100-env
```

Verify key variables are set:

```bash
echo "VPC_ID:        $VPC_ID"
echo "MGMT_SUBNET_ID: $MGMT_SUBNET_ID"
echo "OCP_SG_ID:     $OCP_SG_ID"
echo "CN_ID:         $CN_ID"
```

If any are empty, recover them:

```bash
[ -z "$VPC_ID" ] && export VPC_ID=$(ibmcloud is vpcs --output json | jq -r '.[] | select(.name=="rdma-pvc-eude") | .id') && sed -i '' "s/^export VPC_ID=.*/export VPC_ID=$VPC_ID/" ~/.ibmcloud-h100-env
[ -z "$MGMT_SUBNET_ID" ] && export MGMT_SUBNET_ID=$(ibmcloud is subnets --output json | jq -r '.[] | select(.name=="ocp-mgmt-subnet") | .id') && sed -i '' "s/^export MGMT_SUBNET_ID=.*/export MGMT_SUBNET_ID=$MGMT_SUBNET_ID/" ~/.ibmcloud-h100-env
[ -z "$OCP_SG_ID" ] && export OCP_SG_ID=$(ibmcloud is security-groups --output json | jq -r '.[] | select(.name=="ocp-h100-cluster-sg") | .id') && sed -i '' "s/^export OCP_SG_ID=.*/export OCP_SG_ID=$OCP_SG_ID/" ~/.ibmcloud-h100-env
[ -z "$CN_ID" ] && export CN_ID=$(ibmcloud is cluster-networks --output json | jq -r '.[] | select(.name=="rdma-cluster") | .id') && sed -i '' "s/^export CN_ID=.*/export CN_ID=$CN_ID/" ~/.ibmcloud-h100-env
echo "VPC_ID=$VPC_ID  MGMT_SUBNET_ID=$MGMT_SUBNET_ID  OCP_SG_ID=$OCP_SG_ID  CN_ID=$CN_ID"
```

Verify cluster network exists and is stable:

```bash
ibmcloud is cluster-network $CN_ID --output json | jq '{name, id, lifecycle_state, profile: .profile.name}'
```

**Expected**: name `rdma-cluster`, lifecycle_state `stable`, profile `hopper-1`

Verify all 8 subnets exist:

```bash
ibmcloud is cluster-network-subnets $CN_ID --output json | \
  jq -r '.ClusterNetworkSubnets[] | "\(.name): \(.ipv4_cidr_block) [\(.lifecycle_state)]"' | sort
```

**Expected**: 8 subnets (`rdma-subnet-0` through `rdma-subnet-7`), all `stable`.

#### Step 2: Login to IBM Cloud

```bash
ibmcloud_login
```

#### Step 3: Set RHCOS Image

```bash
export IMAGE_ID=$(ibmcloud is images --visibility private --output json | jq -r '.[] | select(.name=="ocp-rhcos") | .id')
export IMAGE_NAME=$(ibmcloud is image $IMAGE_ID --output json | jq -r '.name')
echo "Using image: $IMAGE_NAME ($IMAGE_ID)"
```

If empty, you need to import RHCOS first — see Phase 2 Step 7.

---

### Part B: Provision H200 Node

#### Step 4: Check for Existing H200 Instance

```bash
EXISTING_INSTANCE=$(ibmcloud is instances --output json | jq -r '.[] | select(.name == "ocp-gpu-worker-h200-0") | .id')
echo "Existing instance: ${EXISTING_INSTANCE:-none}"
```

**If empty** — no existing instance. Proceed to Step 5.

**If an instance ID is shown** — instance already exists. Choose:

- **Use it**: Set `export H200_INSTANCE_ID_0=$EXISTING_INSTANCE` and skip to Step 7 (or Step 8 if it's running and you need to attach cluster networks).
- **Delete and recreate**: `ibmcloud is instance-delete $EXISTING_INSTANCE --force` then wait 30s and proceed to Step 5.

#### Step 5: Create H200 Instance

##### 5a. Verify Worker Ignition Config

```bash
ls -la ~/ocp-h100-upi-install/worker.ign
```

##### 5b. Review Configuration

```bash
cat << EOF

========================================
H200 Instance Configuration
========================================

Name:              ocp-gpu-worker-h200-0
Profile:           $H200_GPU_PROFILE
VPC:               $VPC_NAME ($VPC_ID)
Zone:              $IBMCLOUD_ZONE
Management Subnet: $MGMT_SUBNET_ID
Security Group:    $OCP_SG_ID (ocp-h100-cluster-sg — same as masters)
Image:             $IMAGE_NAME

Instance Specs (gx3d-160x1792x8h200):
  - 160 vCPUs
  - 1.75TB RAM
  - 8x NVIDIA H200 SXM5 GPUs (141GB each)
  - 1128GB total GPU memory

Cost: ~\$30-40 per hour while running

========================================

EOF
```

##### 5c. Create Instance

```bash
ibmcloud is instance-create ocp-gpu-worker-h200-0 \
  $VPC_ID \
  eu-de-2 \
  $H200_GPU_PROFILE \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/worker.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/h200-instance-0.json
```

##### 5d. Get and Save Instance ID

```bash
export H200_INSTANCE_ID_0=$(jq -r '.id' /tmp/h200-instance-0.json)
echo "H200 Instance ID: $H200_INSTANCE_ID_0"
```

If empty or `null`, check the output: `cat /tmp/h200-instance-0.json`

#### Step 6: Wait for Instance to Start

```bash
while true; do
  STATUS=$(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "running" ]; then
    echo "Instance is running"
    break
  elif [ "$STATUS" = "failed" ]; then
    echo "Instance failed to start"
    ibmcloud is instance $H200_INSTANCE_ID_0
    break
  fi
  sleep 10
done
```

**Expected time**: 2-5 minutes

#### Step 7: Stop Instance for Cluster Network Attachment

> **CRITICAL**: Cluster network interfaces can ONLY be attached when the instance is STOPPED.

##### 7a. Stop the Instance

```bash
ibmcloud is instance-stop $H200_INSTANCE_ID_0 --force
```

##### 7b. Wait for Stop

```bash
while true; do
  STATUS=$(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status')
  echo "  Status: $STATUS ($(date '+%H:%M:%S'))"
  if [ "$STATUS" = "stopped" ]; then
    echo "Instance stopped"
    break
  fi
  sleep 10
done
```

#### Step 8: Create and Attach Cluster Network Interfaces

##### 8a. Create 8 Cluster Network Interfaces

```bash
echo "Creating 8 cluster network interfaces for H200..."
for i in $(seq 0 7); do
  eval SUBNET_ID=\$CN_SUBNET_ID_$i
  echo -n "  Rail $i: "
  ibmcloud is cluster-network-interface-create $CN_ID \
    --subnet $SUBNET_ID \
    --rip-auto-delete true \
    --rip-name "h200-0-rail-${i}-rip" \
    --name "h200-0-gpu-rail-${i}" \
    --output json | jq -r '"\(.name) | \(.id) | \(.lifecycle_state)"'
done
echo "Done"
```

##### 8b. Attach 8 Interfaces to Instance

```bash
echo "Attaching 8 interfaces to H200..."
for i in $(seq 0 7); do
  IFACE_ID=$(ibmcloud is cluster-network-interfaces $CN_ID --output json | \
    jq -r ".[] | select(.name==\"h200-0-gpu-rail-${i}\") | .id")
  echo -n "  Rail $i ($IFACE_ID): "
  ibmcloud is instance-cluster-network-attachment-create $H200_INSTANCE_ID_0 \
    --cni $IFACE_ID \
    --cluster-network $CN_ID \
    --name "h200-0-gpu-rail-${i}" \
    --output json | jq -r '"\(.name) | \(.lifecycle_state)"'
done
echo "Done"
```

##### 8c. Verify Attachments

```bash
echo "Attachments: $(ibmcloud is instance-cluster-network-attachments $H200_INSTANCE_ID_0 --output json | jq '. | length') (expected: 8)"
echo ""
ibmcloud is instance-cluster-network-attachments $H200_INSTANCE_ID_0 --output json | \
  jq -r '.[] | "\(.name): \(.lifecycle_state)"'
```

All 8 should show `stable` (or `pending` — they'll become `stable` when the instance starts).

#### Step 9: Start Instance

##### 9a. Start Instance

```bash
ibmcloud is instance-start $H200_INSTANCE_ID_0
```

##### 9b. Wait for Running

> **Note**: Starting with cluster networks takes 10-15 minutes — the RDMA fabric and GPU Fabric Manager must initialize.

```bash
while true; do
  STATUS=$(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status')
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

### Part C: Create Floating IP

#### Step 10: Create Floating IP

> **IMPORTANT**: IBM Cloud uses the VirtualNetworkInterface (VNI) model. The floating IP attaches with `--vni`, NOT `--nic`.

##### 10a. Get the Virtual Network Interface ID

```bash
H200_VNI=$(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | \
  jq -r '.network_attachments[0].virtual_network_interface.id')
echo "VNI: $H200_VNI"
```

##### 10b. Create Floating IP

```bash
ibmcloud is floating-ip-reserve h200-0-fip --vni $H200_VNI --output json | jq '{name, address}'
```

> If `h200-0-fip` already exists, get its address instead:
> ```bash
> ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h200-0-fip") | .address'
> ```

##### 10c. Get Floating IP Address

```bash
export H200_FIP_0=$(ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h200-0-fip") | .address')
echo "H200 Floating IP: $H200_FIP_0"
```

---

### Part D: Validate and Save

#### Step 11: Verify Instance Running

```bash
STATUS=$(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status')
ATTACHMENTS=$(ibmcloud is instance-cluster-network-attachments $H200_INSTANCE_ID_0 --output json | jq '. | length')
echo "H200: status=$STATUS  attachments=$ATTACHMENTS"
```

**Expected**: `running`, 8 attachments.

#### Step 12: Test SSH Connectivity

> Wait 10-15 minutes after start before attempting SSH. The GPU instance needs time for RDMA fabric initialization.

```bash
ssh -o ConnectTimeout=60 -i ~/.ssh/id_rsa core@$H200_FIP_0 "hostname && uptime"
```

If connection times out, wait a few more minutes and retry.

Verify network interfaces:

```bash
ssh core@$H200_FIP_0 "ip link show | grep -c enp"
```

**Expected**: Multiple network interfaces (1 management + 8 RDMA).

Check for pending CSRs (node won't appear in `oc get nodes` until Phase 4B CSR approval):

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
oc get csr | grep Pending
```

#### Step 13: Save All IDs to Environment File

```bash
# Save H200 instance IDs
grep -q "H200_INSTANCE_ID_0" ~/.ibmcloud-h100-env || echo "export H200_INSTANCE_ID_0=" >> ~/.ibmcloud-h100-env
grep -q "H200_FIP_0" ~/.ibmcloud-h100-env || echo "export H200_FIP_0=" >> ~/.ibmcloud-h100-env
grep -q "H200_NODE_NAME_0" ~/.ibmcloud-h100-env || echo "export H200_NODE_NAME_0=" >> ~/.ibmcloud-h100-env

sed -i '' "s/^export H200_INSTANCE_ID_0=.*/export H200_INSTANCE_ID_0=$H200_INSTANCE_ID_0/" ~/.ibmcloud-h100-env
sed -i '' "s/^export H200_FIP_0=.*/export H200_FIP_0=$H200_FIP_0/" ~/.ibmcloud-h100-env

source ~/.ibmcloud-h100-env
echo "H200 IDs saved to ~/.ibmcloud-h100-env"
```

#### Step 14: Final Summary

```bash
echo ""
echo "========================================"
echo "H200 Instance Summary"
echo "========================================"
echo ""
echo "Instance ID:     $H200_INSTANCE_ID_0"
echo "Status:          $(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.status')"
echo "Private IP:      $(ibmcloud is instance $H200_INSTANCE_ID_0 --output json | jq -r '.primary_network_interface.primary_ip.address')"
echo "Floating IP:     $H200_FIP_0"
echo "Profile:         $H200_GPU_PROFILE"
echo "Cluster Network: $CN_NAME (hopper-1)"
echo "Attachments:     $(ibmcloud is instance-cluster-network-attachments $H200_INSTANCE_ID_0 --output json | jq '. | length') (expected: 8)"
echo "Bandwidth:       3.2 Tbps (8x 400 Gbps ConnectX-7)"
echo ""
echo "GPUs:            8x NVIDIA H200 SXM5 (141GB each)"
echo "Total GPU Mem:   1128GB"
echo ""
echo "Cost:            ~\$30-40/hour while running"
echo "========================================"
```

---

## Checkpoint Summary

At the end of Phase 3B, you should have:

- [x] Cluster network verified (`rdma-cluster`, `hopper-1` profile)
- [x] 8 existing subnets reused (`rdma-subnet-0` through `rdma-subnet-7`)
- [x] H200 instance created (`ocp-gpu-worker-h200-0`, `gx3d-160x1792x8h200` profile)
- [x] 8 cluster network interfaces created and attached (all `stable`)
- [x] Instance running with RDMA fabric initialized
- [x] Floating IP assigned for SSH access
- [x] All resource IDs saved to `~/.ibmcloud-h100-env`

---

## Cost Management

The H200 instance is **RUNNING** and **ACCRUING COSTS** (~$30-40/hour).

**To stop costs temporarily:**

```bash
ibmcloud is instance-stop $H200_INSTANCE_ID_0 --force
```

**To resume:**

```bash
ibmcloud is instance-start $H200_INSTANCE_ID_0
```

> Starting with cluster networks attached takes 10-15 minutes.

---

## Teardown

To delete all Phase 3B resources (reverse order of creation):

### 1. Delete Floating IP

```bash
ibmcloud is floating-ip-release h200-0-fip --force
```

### 2. Delete H200 Instance

```bash
ibmcloud is instance-delete $H200_INSTANCE_ID_0 --force
```

Wait for deletion to complete (~30s):

```bash
while ibmcloud is instance $H200_INSTANCE_ID_0 --output json 2>/dev/null | jq -r '.status' 2>/dev/null; do
  echo "  Waiting for instance deletion..."
  sleep 10
done
echo "Instance deleted"
```

### 3. Delete Cluster Network Interfaces (H200 only)

```bash
for IFACE_ID in $(ibmcloud is cluster-network-interfaces $CN_ID --output json | jq -r '.[] | select(.name | startswith("h200-0-gpu-rail")) | .id'); do
  echo -n "Deleting interface $IFACE_ID... "
  ibmcloud is cluster-network-interface-delete $CN_ID $IFACE_ID --force 2>&1
done
```

> **Note**: Do NOT delete the cluster network or subnets — they are shared with the H100 node.

### 4. Clear Environment Variables

```bash
sed -i '' "s/^export H200_INSTANCE_ID_0=.*/export H200_INSTANCE_ID_0=/" ~/.ibmcloud-h100-env
sed -i '' "s/^export H200_FIP_0=.*/export H200_FIP_0=/" ~/.ibmcloud-h100-env
sed -i '' "s/^export H200_NODE_NAME_0=.*/export H200_NODE_NAME_0=/" ~/.ibmcloud-h100-env
source ~/.ibmcloud-h100-env
echo "H200 environment variables cleared"
```

---

## Troubleshooting

### Instance Creation Fails with Quota Error

Check VPC quotas in IBM Cloud console. Delete unused instances or request quota increase.

### Cannot Attach Cluster Network (Instance Not Stopped)

```bash
ibmcloud is instance-stop $H200_INSTANCE_ID_0 --force
# Wait for stopped status, then retry attachment
```

### Instance Takes Too Long to Start (>20 min)

Starting with cluster networks attached takes 10-15 minutes due to RDMA fabric initialization. If >20 minutes, check the instance in IBM Cloud console for errors.

### Floating IP Already Exists

If `h200-0-fip` exists from a previous run:

```bash
export H200_FIP_0=$(ibmcloud is floating-ips --output json | jq -r '.[] | select(.name=="h200-0-fip") | .address')
```

### Lost Track of Interfaces

```bash
ibmcloud is cluster-network-interfaces $CN_ID --output json | \
  jq -r '.[] | select(.name | startswith("h200-0-gpu-rail")) | "\(.name) | \(.id)"'
```

### Cluster Network Subnet Full

Each subnet has 16,378 available IPs — unlikely to be full. Verify:

```bash
ibmcloud is cluster-network-subnets $CN_ID --output json | \
  jq -r '.ClusterNetworkSubnets[] | "\(.name): \(.available_ipv4_address_count) available"'
```

---

## Next Steps

You're ready for **[Phase 4B: Integrate H200 Node as Worker](PHASE4B-H200-WORKER-INTEGRATION.md)**

This phase will:
- Join the H200 instance to the OpenShift cluster
- Approve Certificate Signing Requests (CSRs)
- Apply H200-specific labels to the worker node

**Before proceeding**, ensure:
- H200 instance is running
- All 8 cluster network attachments are stable
- OpenShift cluster is healthy (3 masters Ready)

---

**Phase 3B Complete!**

**H200 instance provisioned with RDMA. Costs accruing (~$30-40/hour).**
