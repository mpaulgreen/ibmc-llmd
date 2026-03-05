# Phase 3: Provision H100 GPU Instance

## Overview

This phase provisions the H100 GPU instance with 8× NVIDIA H100 GPUs and attaches 8 cluster network interfaces for RDMA connectivity.

**What You'll Accomplish:**
- Find appropriate RHCOS image for H100 instance
- Create H100 instance with VPC management network
- Stop instance (required for cluster network attachment)
- Create and attach 8 cluster network interfaces
- Start instance and initialize RDMA fabric

**Estimated Time**: 20-30 minutes

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
oc get nodes
```

Should show 3 master nodes in Ready state.

---

## Step-by-Step Instructions

### Step 1: Load Environment

Source the environment configuration:

```bash
source ~/.ibmcloud-h100-env
```

### Step 2: Login to IBM Cloud

```bash
ibmcloud_login
```

---

### Step 3: Find RHCOS Image

#### 3a. Search for RHCOS Images

List available RHCOS images in your region:

```bash
ibmcloud is images --output json | jq -r '.[] | select(.name | contains("rhcos")) | select(.status == "available") | "\(.name) - \(.id)"'
```

**Expected Output:**
```
rhcos-4.x-xxx... - r010-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Take note of the image ID (the `r010-...` part).

#### 3b. Set Image ID

If you found an RHCOS image above, set it:

```bash
export IMAGE_ID="<paste-the-image-id-here>"
```

Replace `<paste-the-image-id-here>` with actual ID from step 3a.

**If no RHCOS image found:**

You'll need to import one or use a RHEL-based image. For this guide, we'll assume you have an RHCOS image. If you need to import one, see the Red Hat documentation for downloading RHCOS qcow2 images and importing to IBM Cloud Object Storage.

**Alternative - Use any RHEL/RHCOS image:**
```bash
# Find any suitable image
ibmcloud is images --output json | jq -r '.[] | select(.status == "available") | "\(.name) - \(.id)"' | head -5
```

Pick one and set IMAGE_ID to its ID.

#### 3c. Get Image Details

```bash
ibmcloud is image $IMAGE_ID --output json > /tmp/image-info.json
```

```bash
export IMAGE_NAME=$(cat /tmp/image-info.json | jq -r '.name')
echo "Using image: $IMAGE_NAME"
echo "Image ID: $IMAGE_ID"
```

---

### Step 4: Check for Existing H100 Instance

Check if an instance named `ocp-h100-worker` already exists:

```bash
export EXISTING_INSTANCE=$(ibmcloud is instances --output json | jq -r '.[] | select(.name == "ocp-h100-worker") | .id')
echo "Existing instance: $EXISTING_INSTANCE"
```

**If output is empty**, no existing instance. **Skip to Step 5.**

**If an instance ID is shown:**

⚠️ **WARNING**: Instance `ocp-h100-worker` already exists!

**Option A - Use Existing Instance:**

Set the environment variable and skip to Phase 4:

```bash
export H100_INSTANCE_ID=$EXISTING_INSTANCE
echo "export H100_INSTANCE_ID=$H100_INSTANCE_ID" >> ~/.ibmcloud-h100-env
echo "Using existing instance: $H100_INSTANCE_ID"
```

Then skip to **Phase 4: Worker Integration**.

**Option B - Delete and Recreate:**

⚠️ **DESTRUCTIVE**: This will delete the instance!

```bash
ibmcloud is instance-delete $EXISTING_INSTANCE --force
```

Wait for deletion to complete:

```bash
sleep 30
```

Verify it's deleted:

```bash
ibmcloud is instances | grep ocp-h100-worker
```

Should return no results. Proceed to Step 5.

---

### Step 5: Create H100 Instance

#### 5a. Review Instance Configuration

Display what will be created:

```bash
cat << EOF

========================================
H100 Instance Configuration
========================================

Name:              ocp-h100-worker
Profile:           $GPU_PROFILE
VPC:               $VPC_NAME ($VPC_ID)
Zone:              $IBMCLOUD_ZONE
Management Subnet: $MGMT_SUBNET_ID
Security Group:    $SG_ID
SSH Key:           $KEY_ID
Image:             $IMAGE_NAME

Instance Specs (gx3d-160x1792x8h100):
  - 160 vCPUs
  - 1.75TB RAM
  - 8× NVIDIA H100 SXM5 GPUs (80GB each)
  - 640GB total GPU memory

⚠️  Cost: ~\$30-40 per hour while running
⚠️  This is a significant cost - ensure you need this instance

========================================

EOF
```

**Review this carefully.** H100 costs are high!

#### 5b. Create Instance

⚠️ **CRITICAL CHECKPOINT**

You are about to create an H100 instance that costs ~$30-40 per hour.

**Ready to proceed? If yes, run:**

```bash
ibmcloud is instance-create \
    ocp-h100-worker \
    $VPC_ID \
    $IBMCLOUD_ZONE \
    $GPU_PROFILE \
    $MGMT_SUBNET_ID \
    --image $IMAGE_ID \
    --keys $KEY_ID \
    --security-groups $SG_ID \
    --output json > /tmp/h100-instance-create.json
```

This will take 5-10 minutes to create the instance.

#### 5c. Get Instance ID

```bash
export H100_INSTANCE_ID=$(cat /tmp/h100-instance-create.json | jq -r '.id')
echo "H100 Instance ID: $H100_INSTANCE_ID"
```

**If empty or 'null':**

Creation failed. Check the output:

```bash
cat /tmp/h100-instance-create.json
```

Common failures:
- Quota exceeded
- Profile not available in zone
- Invalid parameters

#### 5d. Save Instance ID to Environment

```bash
echo "" >> ~/.ibmcloud-h100-env
echo "# H100 Instance (created $(date))" >> ~/.ibmcloud-h100-env
echo "export H100_INSTANCE_ID=$H100_INSTANCE_ID" >> ~/.ibmcloud-h100-env
```

Reload environment:

```bash
source ~/.ibmcloud-h100-env
```

---

### Step 6: Wait for Instance to Start

Monitor instance status:

```bash
watch -n 10 "ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status'"
```

**Expected progression:**
- `pending` → `starting` → `running`

Press `Ctrl+C` when status shows `running`.

**Or use a manual check loop:**

```bash
while true; do
    STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
    echo "Status: $STATUS"
    if [ "$STATUS" = "running" ]; then
        echo "✅ Instance is running"
        break
    elif [ "$STATUS" = "failed" ]; then
        echo "❌ Instance failed to start"
        ibmcloud is instance $H100_INSTANCE_ID
        exit 1
    fi
    sleep 10
done
```

**Expected time**: 5-10 minutes

---

### Step 7: Get Instance Details

Fetch full instance information:

```bash
ibmcloud is instance $H100_INSTANCE_ID --output json > /tmp/h100-instance.json
```

Extract key details:

```bash
export INSTANCE_NAME=$(cat /tmp/h100-instance.json | jq -r '.name')
export INSTANCE_STATUS=$(cat /tmp/h100-instance.json | jq -r '.status')
export INSTANCE_ZONE=$(cat /tmp/h100-instance.json | jq -r '.zone.name')
export PRIVATE_IP=$(cat /tmp/h100-instance.json | jq -r '.primary_network_interface.primary_ip.address')

echo "Instance Name:   $INSTANCE_NAME"
echo "Status:          $INSTANCE_STATUS"
echo "Zone:            $INSTANCE_ZONE"
echo "Private IP:      $PRIVATE_IP"
echo "Profile:         $GPU_PROFILE"
```

Check for floating/public IP:

```bash
export FLOATING_IP=$(cat /tmp/h100-instance.json | jq -r '.primary_network_interface.floating_ips[0].address // empty')

if [ -n "$FLOATING_IP" ]; then
    echo "Public IP:       $FLOATING_IP"
    echo "SSH Command:     ssh root@$FLOATING_IP"
else
    echo "⚠️  No public IP assigned"
    echo "    SSH requires VPN or bastion host"
fi
```

---

### Step 8: Stop Instance for Cluster Network Attachment

⚠️ **IMPORTANT**: Cluster network interfaces can **only** be attached when the instance is **STOPPED**.

#### 8a. Stop the Instance

```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
```

#### 8b. Wait for Instance to Stop

Monitor status:

```bash
while true; do
    STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
    echo "Status: $STATUS"
    if [ "$STATUS" = "stopped" ]; then
        echo "✅ Instance stopped"
        break
    fi
    sleep 10
done
```

**Expected time**: 1-2 minutes

---

### Step 9: Verify Cluster Network Configuration

Before attaching interfaces, verify the cluster network and subnets:

#### 9a. Check Cluster Network

```bash
ibmcloud is cluster-network $CN_ID --output json > /tmp/cluster-network.json
```

```bash
cat /tmp/cluster-network.json | jq -r '"\(.name) - \(.lifecycle_state) - \(.profile.name)"'
```

**Expected Output:**
```
rdma-cluster - stable - hopper-1
```

Verify:
- State is `stable` or `pending`
- Profile is `hopper-1`

#### 9b. Verify All 8 Cluster Network Subnets

Check subnet 0:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_0 --output json | jq -r '.name, .id'
```

Check subnet 1:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_1 --output json | jq -r '.name, .id'
```

Check subnet 2:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_2 --output json | jq -r '.name, .id'
```

Check subnet 3:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_3 --output json | jq -r '.name, .id'
```

Check subnet 4:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_4 --output json | jq -r '.name, .id'
```

Check subnet 5:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_5 --output json | jq -r '.name, .id'
```

Check subnet 6:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_6 --output json | jq -r '.name, .id'
```

Check subnet 7:

```bash
ibmcloud is cluster-network-subnet $CN_ID $CN_SUBNET_ID_7 --output json | jq -r '.name, .id'
```

Each command should output a subnet name and ID. If any fail, that subnet doesn't exist.

---

### Step 10: Create and Attach Cluster Network Interfaces

Now we'll create 8 cluster network interfaces (one per GPU rail) and attach them to the H100 instance.

⚠️ **IMPORTANT**: Execute these commands one at a time. Do not batch them.

#### 10a. Create Interface for GPU Rail 0

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_0 \
    --name "h100-gpu-rail-0" \
    --output json > /tmp/cn-interface-0.json
```

Get interface ID:

```bash
export CN_INTERFACE_0_ID=$(cat /tmp/cn-interface-0.json | jq -r '.id')
echo "Interface 0 ID: $CN_INTERFACE_0_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_0_ID \
    --name "h100-attachment-0" \
    --output json > /tmp/cn-attachment-0.json
```

Verify attachment:

```bash
cat /tmp/cn-attachment-0.json | jq -r '.name, .lifecycle_state'
```

**Expected**: Shows attachment name and state (likely `pending` or `stable`)

#### 10b. Create Interface for GPU Rail 1

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_1 \
    --name "h100-gpu-rail-1" \
    --output json > /tmp/cn-interface-1.json
```

Get interface ID:

```bash
export CN_INTERFACE_1_ID=$(cat /tmp/cn-interface-1.json | jq -r '.id')
echo "Interface 1 ID: $CN_INTERFACE_1_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_1_ID \
    --name "h100-attachment-1" \
    --output json > /tmp/cn-attachment-1.json
```

Verify:

```bash
cat /tmp/cn-attachment-1.json | jq -r '.name, .lifecycle_state'
```

#### 10c. Create Interface for GPU Rail 2

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_2 \
    --name "h100-gpu-rail-2" \
    --output json > /tmp/cn-interface-2.json
```

Get interface ID:

```bash
export CN_INTERFACE_2_ID=$(cat /tmp/cn-interface-2.json | jq -r '.id')
echo "Interface 2 ID: $CN_INTERFACE_2_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_2_ID \
    --name "h100-attachment-2" \
    --output json > /tmp/cn-attachment-2.json
```

Verify:

```bash
cat /tmp/cn-attachment-2.json | jq -r '.name, .lifecycle_state'
```

#### 10d. Create Interface for GPU Rail 3

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_3 \
    --name "h100-gpu-rail-3" \
    --output json > /tmp/cn-interface-3.json
```

Get interface ID:

```bash
export CN_INTERFACE_3_ID=$(cat /tmp/cn-interface-3.json | jq -r '.id')
echo "Interface 3 ID: $CN_INTERFACE_3_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_3_ID \
    --name "h100-attachment-3" \
    --output json > /tmp/cn-attachment-3.json
```

Verify:

```bash
cat /tmp/cn-attachment-3.json | jq -r '.name, .lifecycle_state'
```

#### 10e. Create Interface for GPU Rail 4

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_4 \
    --name "h100-gpu-rail-4" \
    --output json > /tmp/cn-interface-4.json
```

Get interface ID:

```bash
export CN_INTERFACE_4_ID=$(cat /tmp/cn-interface-4.json | jq -r '.id')
echo "Interface 4 ID: $CN_INTERFACE_4_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_4_ID \
    --name "h100-attachment-4" \
    --output json > /tmp/cn-attachment-4.json
```

Verify:

```bash
cat /tmp/cn-attachment-4.json | jq -r '.name, .lifecycle_state'
```

#### 10f. Create Interface for GPU Rail 5

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_5 \
    --name "h100-gpu-rail-5" \
    --output json > /tmp/cn-interface-5.json
```

Get interface ID:

```bash
export CN_INTERFACE_5_ID=$(cat /tmp/cn-interface-5.json | jq -r '.id')
echo "Interface 5 ID: $CN_INTERFACE_5_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_5_ID \
    --name "h100-attachment-5" \
    --output json > /tmp/cn-attachment-5.json
```

Verify:

```bash
cat /tmp/cn-attachment-5.json | jq -r '.name, .lifecycle_state'
```

#### 10g. Create Interface for GPU Rail 6

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_6 \
    --name "h100-gpu-rail-6" \
    --output json > /tmp/cn-interface-6.json
```

Get interface ID:

```bash
export CN_INTERFACE_6_ID=$(cat /tmp/cn-interface-6.json | jq -r '.id')
echo "Interface 6 ID: $CN_INTERFACE_6_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_6_ID \
    --name "h100-attachment-6" \
    --output json > /tmp/cn-attachment-6.json
```

Verify:

```bash
cat /tmp/cn-attachment-6.json | jq -r '.name, .lifecycle_state'
```

#### 10h. Create Interface for GPU Rail 7

Create the interface:

```bash
ibmcloud is cluster-network-interface-create \
    --cluster-network $CN_ID \
    --subnet $CN_SUBNET_ID_7 \
    --name "h100-gpu-rail-7" \
    --output json > /tmp/cn-interface-7.json
```

Get interface ID:

```bash
export CN_INTERFACE_7_ID=$(cat /tmp/cn-interface-7.json | jq -r '.id')
echo "Interface 7 ID: $CN_INTERFACE_7_ID"
```

Attach to instance:

```bash
ibmcloud is instance-cluster-network-attachment-create \
    $H100_INSTANCE_ID \
    --cluster-network-interface $CN_INTERFACE_7_ID \
    --name "h100-attachment-7" \
    --output json > /tmp/cn-attachment-7.json
```

Verify:

```bash
cat /tmp/cn-attachment-7.json | jq -r '.name, .lifecycle_state'
```

---

### Step 11: Verify All Attachments

List all cluster network attachments:

```bash
ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID --output json > /tmp/all-attachments.json
```

Count attachments:

```bash
cat /tmp/all-attachments.json | jq '. | length'
```

**Expected**: `8`

List attachment details:

```bash
cat /tmp/all-attachments.json | jq -r '.[] | "\(.name): \(.lifecycle_state)"'
```

**Expected Output:**
```
h100-attachment-0: stable
h100-attachment-1: stable
h100-attachment-2: stable
h100-attachment-3: stable
h100-attachment-4: stable
h100-attachment-5: stable
h100-attachment-6: stable
h100-attachment-7: stable
```

All should show `stable` state (or `pending` if still being configured).

---

### Step 12: Save Interface IDs to Environment

Save all interface IDs for reference:

```bash
cat >> ~/.ibmcloud-h100-env << EOF

# Cluster Network Interface IDs (created $(date))
export CN_INTERFACE_0_ID=$CN_INTERFACE_0_ID
export CN_INTERFACE_1_ID=$CN_INTERFACE_1_ID
export CN_INTERFACE_2_ID=$CN_INTERFACE_2_ID
export CN_INTERFACE_3_ID=$CN_INTERFACE_3_ID
export CN_INTERFACE_4_ID=$CN_INTERFACE_4_ID
export CN_INTERFACE_5_ID=$CN_INTERFACE_5_ID
export CN_INTERFACE_6_ID=$CN_INTERFACE_6_ID
export CN_INTERFACE_7_ID=$CN_INTERFACE_7_ID
EOF
```

---

### Step 13: Start H100 Instance

Now start the instance. This will initialize the RDMA fabric.

#### 13a. Start Instance

```bash
ibmcloud is instance-start $H100_INSTANCE_ID
```

#### 13b. Wait for Instance to Start

Monitor status:

```bash
while true; do
    STATUS=$(ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status')
    echo "Status: $STATUS"
    if [ "$STATUS" = "running" ]; then
        echo "✅ Instance is running"
        break
    elif [ "$STATUS" = "failed" ]; then
        echo "❌ Instance failed to start"
        exit 1
    fi
    sleep 10
done
```

**Expected time**: 10-15 minutes

**Note**: Starting an H100 instance with cluster networks takes longer than normal because the RDMA fabric must initialize. This is expected.

---

### Step 14: Get Final Instance Information

Once running, get updated instance details:

```bash
ibmcloud is instance $H100_INSTANCE_ID --output json > /tmp/h100-instance-final.json
```

Display summary:

```bash
cat << EOF

========================================
H100 Instance Summary
========================================

Instance ID:        $H100_INSTANCE_ID
Name:               $(cat /tmp/h100-instance-final.json | jq -r '.name')
Status:             $(cat /tmp/h100-instance-final.json | jq -r '.status')
Zone:               $(cat /tmp/h100-instance-final.json | jq -r '.zone.name')
Profile:            $GPU_PROFILE

Private IP:         $(cat /tmp/h100-instance-final.json | jq -r '.primary_network_interface.primary_ip.address')

Cluster Network:    $CN_NAME
Profile:            hopper-1
Interfaces:         8 (one per GPU rail)
Total Bandwidth:    3.2 Tbps (8× 400 Gbps)

GPUs:               8× NVIDIA H100 SXM5 (80GB each)
Total GPU Memory:   640GB

========================================

EOF
```

---

## Checkpoint Summary

At the end of Phase 3, you should have:

- [x] **H100 instance created** (gx3d-160x1792x8h100 profile)
- [x] **8× H100 GPUs** provisioned
- [x] **VPC management network** attached (primary interface)
- [x] **8 cluster network interfaces** created and attached
- [x] **Instance running** with RDMA fabric initialized
- [x] **Instance ID** saved to environment file
- [x] **Interface IDs** saved to environment file

### Verify Checklist

```bash
# Should show your H100 instance
ibmcloud is instance $H100_INSTANCE_ID

# Should show 8 attachments
ibmcloud is instance-cluster-network-attachments $H100_INSTANCE_ID

# Should show running status
ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.status'
```

If all show correct information, Phase 3 is complete!

---

## Troubleshooting

### Issue: Instance Creation Fails with Quota Error

**Error**: "Quota exceeded for instances"

**Solution:**
- Check VPC quotas in IBM Cloud console
- Delete unused instances
- Request quota increase

### Issue: Cannot Attach Cluster Network (Instance Not Stopped)

**Error**: "Instance must be stopped"

**Solution:**
```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
# Wait for stopped status, then retry attachment
```

### Issue: Cluster Network Interface Creation Fails

**Possible causes:**
- Cluster network not in stable state
- Subnet doesn't exist
- Permissions issue

**Check cluster network state:**
```bash
ibmcloud is cluster-network $CN_ID --output json | jq -r '.lifecycle_state'
```

Must be `stable` or `pending`.

### Issue: Instance Takes Too Long to Start

Starting with cluster networks attached takes 10-15 minutes due to RDMA fabric initialization. This is normal.

If > 20 minutes:
- Check instance status in IBM Cloud console
- Check for any errors in instance logs
- Verify cluster network is healthy

### Issue: Lost Track of Which Interfaces Were Created

List all cluster network interfaces for the cluster network:

```bash
ibmcloud is cluster-network-interfaces $CN_ID --output json | jq -r '.[] | select(.name | startswith("h100-gpu-rail")) | "\(.name) - \(.id)"'
```

This shows all interfaces starting with "h100-gpu-rail".

---

## Important Notes

### H100 Costs

The H100 instance is now **RUNNING** and **ACCRUING COSTS**:
- ~$30-40 per hour
- Runs continuously until stopped or deleted

**To stop costs temporarily:**
```bash
ibmcloud is instance-stop $H100_INSTANCE_ID --force
```

**To resume:**
```bash
ibmcloud is instance-start $H100_INSTANCE_ID
```

### RDMA Fabric

The 8 cluster network interfaces provide:
- 8× ConnectX-7 NICs
- 400 Gbps per interface
- 3.2 Tbps total aggregate bandwidth
- RoCE v2 protocol
- GPU Direct RDMA capability

These will be configured in Phases 5-6.

### Instance Network Topology

The H100 instance now has:
- **1 VPC network interface** (primary): For Kubernetes API, kubelet, pod networking
- **8 cluster network interfaces**: For RDMA GPU-to-GPU communication

This dual-network architecture separates management and high-performance data traffic.

---

## Next Steps

You're ready for **[Phase 4: Integrate H100 as Worker Node](PHASE4-WORKER-INTEGRATION.md)**

This phase will:
- Join the H100 instance to the OpenShift cluster
- Approve Certificate Signing Requests (CSRs)
- Apply appropriate labels to the worker node
- Takes approximately 30-60 minutes

**Before proceeding**, ensure:
- H100 instance is running
- All 8 cluster network attachments are stable
- OpenShift cluster is healthy (3 masters Ready)
- You have cluster admin access via oc CLI

---

**Phase 3 Complete! ✅**

**H100 instance provisioned with RDMA networks. Costs now accruing (~$30-40/hour).**
