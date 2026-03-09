# Phase 2: Deploy OpenShift Control Plane (UPI)

## Overview

This phase deploys a 3-node OpenShift control plane on IBM Cloud VPC using the **User-Provisioned Infrastructure (UPI)** method. Unlike IPI (which has a CAPI bug preventing deployment), UPI creates all infrastructure manually — giving full control over instance creation and configuration.

**What You'll Accomplish:**
- Create VPC, subnet, and public gateway from scratch
- Generate OpenShift ignition configs
- Upload bootstrap ignition to Cloud Object Storage
- Create security groups, load balancers, and DNS records
- Create bootstrap + 3 master instances with `--user-data`
- Bootstrap and complete the OpenShift installation

**Estimated Time**: 90-120 minutes

**Why UPI Instead of IPI?**
The OpenShift 4.19/4.20 IPI installer uses a CAPI (Cluster API) provider for IBM Cloud that creates instances with `metadata_service=false` and `user_data=null`. RHCOS boots without ignition config — nothing works. UPI bypasses this by creating instances directly with `ibmcloud is instance-create` and `--user-data`.

## Pre-Flight Checks

Before starting, ensure Phase 1 is complete:

- [ ] Environment file exists: `~/.ibmcloud-h100-env`
- [ ] IBM Cloud CLI logged in to eu-de region
- [ ] openshift-install 4.19+ installed
- [ ] oc 4.19+ installed
- [ ] Pull secret at `~/.pull-secret.json`
- [ ] SSH public key at `~/.ssh/id_rsa.pub`
- [ ] CIS domain `ibmc.kni.syseng.devcluster.openshift.com` active
- [ ] COS instance `ocp-cos` exists
- [ ] SSH key `my-h100-key-eude` exists in IBM Cloud (`r010-3f6ad86f-...`)

---

## Phase 0: Create VPC Infrastructure

### Step 0: Create VPC, Subnet, and Public Gateway

This step creates the VPC networking infrastructure from scratch. After this step, VPC_ID and MGMT_SUBNET_ID will be saved to your env file.

#### 0a. Load Environment and Login

```bash
source ~/.ibmcloud-h100-env
```

```bash
ibmcloud_login
```

#### 0b. Check for Existing VPC

```bash
ibmcloud is vpcs --output json | jq -r '.[] | select(.name == "rdma-pvc-eude") | .name, .id'
```

**If a VPC is shown** — set `export VPC_ID=<id>`, recover the subnet ID with `export MGMT_SUBNET_ID=$(ibmcloud is subnets --output json | jq -r '.[] | select(.name=="ocp-mgmt-subnet") | .id')`, save both to env file with `sed`, and skip to 0g.

**If empty** — no VPC exists. Proceed to 0c.

#### 0c. Create VPC

```bash
ibmcloud is vpc-create rdma-pvc-eude \
  --address-prefix-management manual \
  --output json > /tmp/vpc-create.json
```

```bash
export VPC_ID=$(jq -r '.id' /tmp/vpc-create.json)
echo "VPC ID: $VPC_ID"
```

Save to env file:

```bash
sed -i '' "s/^export VPC_ID=.*/export VPC_ID=$VPC_ID/" ~/.ibmcloud-h100-env
```

#### 0d. Create Address Prefix

```bash
ibmcloud is vpc-address-prefix-create mgmt-prefix $VPC_ID eu-de-2 10.240.0.0/16 \
  --output json > /tmp/addr-prefix.json
echo "Address Prefix: $(jq -r '.id' /tmp/addr-prefix.json)"
```

#### 0e. Create Management Subnet

```bash
ibmcloud is subnet-create ocp-mgmt-subnet $VPC_ID \
  --zone eu-de-2 \
  --ipv4-cidr-block 10.240.0.0/24 \
  --output json > /tmp/mgmt-subnet.json
```

```bash
export MGMT_SUBNET_ID=$(jq -r '.id' /tmp/mgmt-subnet.json)
echo "Subnet ID: $MGMT_SUBNET_ID"
```

Save to env file:

```bash
sed -i '' "s/^export MGMT_SUBNET_ID=.*/export MGMT_SUBNET_ID=$MGMT_SUBNET_ID/" ~/.ibmcloud-h100-env
```

#### 0f. Create and Attach Public Gateway

```bash
ibmcloud is public-gateway-create ocp-pgw $VPC_ID eu-de-2 \
  --output json > /tmp/pgw.json
export PGW_ID=$(jq -r '.id' /tmp/pgw.json)
echo "Public Gateway ID: $PGW_ID"
```

Attach to subnet:

```bash
ibmcloud is subnet-update $MGMT_SUBNET_ID --pgw $PGW_ID --output json | jq '{name, public_gateway: .public_gateway.name}'
```

#### 0g. Verify VPC Setup

```bash
echo "VPC:     $(ibmcloud is vpc $VPC_ID --output json | jq -r '.name') ($VPC_ID)"
echo "Subnet:  $(ibmcloud is subnet $MGMT_SUBNET_ID --output json | jq -r '.name + " " + .ipv4_cidr_block')"
echo "Gateway: $(ibmcloud is subnet $MGMT_SUBNET_ID --output json | jq -r '.public_gateway.name // "NONE"')"
```

**Expected**: VPC `rdma-pvc-eude`, subnet `ocp-mgmt-subnet 10.240.0.0/24`, gateway `ocp-pgw`.

Reload env file with the new IDs:

```bash
source ~/.ibmcloud-h100-env
```

---

## Phase A: Generate Configs

### Step 1: Load Environment and Login

```bash
source ~/.ibmcloud-h100-env
```

```bash
ibmcloud_login
```

```bash
export IC_API_KEY="$IBMCLOUD_API_KEY"
```

Verify:

```bash
ibmcloud target
echo "IC_API_KEY length: ${#IC_API_KEY}"
```

Region should be `eu-de`, resource group `Default`, IC_API_KEY ~44 chars.

---

### Step 2: Create Install Directory

```bash
rm -rf ~/ocp-h100-upi-install && mkdir -p ~/ocp-h100-upi-install
```

---

### Step 3: Create install-config.yaml

```bash
export PULL_SECRET=$(cat $HOME/.pull-secret.json | jq -c .)
export SSH_PUBLIC_KEY=$(cat $HOME/.ssh/id_rsa.pub)
export BASE_DOMAIN="ibmc.kni.syseng.devcluster.openshift.com"
```

```bash
cat > ~/ocp-h100-upi-install/install-config.yaml << EOF
apiVersion: v1
baseDomain: ${BASE_DOMAIN}
metadata:
  name: ${CLUSTER_NAME}
compute:
- architecture: amd64
  name: worker
  replicas: 0
  platform:
    ibmcloud:
      zones:
      - eu-de-2
controlPlane:
  architecture: amd64
  name: master
  replicas: 3
  platform:
    ibmcloud:
      type: bx2-8x32
      zones:
      - eu-de-2
platform:
  ibmcloud:
    region: ${IBMCLOUD_REGION}
    resourceGroupName: ${IBMCLOUD_RESOURCE_GROUP}
    networkResourceGroupName: ${IBMCLOUD_RESOURCE_GROUP}
    vpcName: ${VPC_NAME}
    controlPlaneSubnets:
    - ocp-mgmt-subnet
    computeSubnets:
    - ocp-mgmt-subnet
credentialsMode: Manual
pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
EOF
```

Backup (ignition generation consumes the file):

```bash
cp ~/ocp-h100-upi-install/install-config.yaml ~/ocp-h100-upi-install/install-config.yaml.backup
```

---

### Step 4: Generate Manifests and Add Credential Secrets

> **IMPORTANT**: For `credentialsMode: Manual`, we must generate manifests first, add credential secrets, then generate ignition configs.

#### 4a. Generate Manifests

```bash
openshift-install create manifests --dir ~/ocp-h100-upi-install
```

#### 4b. Create Credential Secrets

```bash
for ns_secret in \
  "openshift-cloud-controller-manager:ibm-cloud-credentials" \
  "openshift-machine-api:ibmcloud-credentials" \
  "openshift-image-registry:installer-cloud-credentials" \
  "openshift-ingress-operator:cloud-credentials" \
  "openshift-cluster-csi-drivers:ibm-cloud-credentials"; do
  NS="${ns_secret%%:*}"
  SECRET="${ns_secret##*:}"
  cat > ~/ocp-h100-upi-install/manifests/${NS}-${SECRET}-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET}
  namespace: ${NS}
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
done
echo "Created $(ls ~/ocp-h100-upi-install/manifests/*credentials* | wc -l | tr -d ' ') credential secrets"
```

#### 4c. Generate Ignition Configs

```bash
openshift-install create ignition-configs --dir ~/ocp-h100-upi-install
```

**Expected Output:**
```
INFO Consuming Install Config from target directory
INFO Ignition-Configs created in: ...
```

Verify the files were created:

```bash
ls -lh ~/ocp-h100-upi-install/*.ign ~/ocp-h100-upi-install/auth/
```

**Expected:**
```
bootstrap.ign    (~1-5 MB — too large for user-data)
master.ign       (~1.5 KB — fits in user-data)
worker.ign       (~1.5 KB — for later use with H100)
auth/kubeconfig
auth/kubeadmin-password
```

Check sizes:

```bash
wc -c ~/ocp-h100-upi-install/bootstrap.ign ~/ocp-h100-upi-install/master.ign
```

`bootstrap.ign` should be > 64KB (too large for IBM Cloud VPC user-data). `master.ign` should be < 64KB.

---

### Step 5: Upload Bootstrap Ignition to COS

> **Why?** `bootstrap.ign` exceeds IBM Cloud VPC's 64KB user-data limit. We upload it to Cloud Object Storage and create a small "shim" ignition file that points to the COS URL.

#### 5a. Install COS Plugin (if not installed)

```bash
ibmcloud plugin list | grep cloud-object-storage || ibmcloud plugin install cloud-object-storage -f
```

#### 5b. Get COS Instance CRN

```bash
export COS_CRN=$(ibmcloud resource service-instance ocp-cos --output json | jq -r '.[0].crn')
echo "COS CRN: $COS_CRN"
```

#### 5c. Set COS Config

```bash
ibmcloud cos config crn --crn $COS_CRN
ibmcloud cos config region --region eu-de
```

#### 5d. Create COS Bucket

```bash
ibmcloud cos bucket-create --bucket ocp-bootstrap-ign --region eu-de
```

If bucket already exists, that's fine — proceed.

#### 5e. Upload bootstrap.ign

```bash
ibmcloud cos object-put --bucket ocp-bootstrap-ign --key bootstrap.ign --body ~/ocp-h100-upi-install/bootstrap.ign --region eu-de
```

Verify upload:

```bash
ibmcloud cos object-head --bucket ocp-bootstrap-ign --key bootstrap.ign --region eu-de
```

Should show the object with its size.

#### 5f. Create HMAC Credentials for COS

> **Why?** IBM Cloud COS uses IAM, not S3-style ACLs. We create HMAC credentials to generate a presigned URL that allows the bootstrap instance to download `bootstrap.ign` without authentication.

```bash
ibmcloud resource service-key-create ocp-cos-hmac --instance-name ocp-cos --parameters '{"HMAC": true}' --output json > /tmp/cos-hmac.json
```

Extract the HMAC keys:

```bash
export COS_ACCESS_KEY=$(cat /tmp/cos-hmac.json | jq -r '.credentials.cos_hmac_keys.access_key_id')
export COS_SECRET_KEY=$(cat /tmp/cos-hmac.json | jq -r '.credentials.cos_hmac_keys.secret_access_key')
echo "COS Access Key: $COS_ACCESS_KEY"
```

#### 5g. Generate Presigned URL

Generate a presigned URL valid for 4 hours (enough time for bootstrap to start and download):

```bash
export BOOTSTRAP_IGN_URL=$(AWS_ACCESS_KEY_ID=$COS_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$COS_SECRET_KEY \
  aws s3 presign s3://ocp-bootstrap-ign/bootstrap.ign \
  --endpoint-url https://s3.eu-de.cloud-object-storage.appdomain.cloud \
  --region eu-de \
  --expires-in 14400)
echo "Bootstrap IGN URL: $BOOTSTRAP_IGN_URL"
```

Test the URL is accessible (must use GET, not HEAD — presigned URLs are signed for GET only):

```bash
curl -so /dev/null -w "%{http_code}" "$BOOTSTRAP_IGN_URL"
```

Should show `200`. (A `curl -sI` HEAD request will return 403 — this is expected since the presigned signature only covers GET.)

> **Note**: The presigned URL expires in 4 hours. If you need to restart the process, regenerate it with the same command.

#### 5h. Create Bootstrap Shim Ignition

This is a tiny ignition file (~200 bytes) that tells the bootstrap instance where to download the full ignition:

```bash
cat > ~/ocp-h100-upi-install/bootstrap-shim.ign << EOF
{
  "ignition": {
    "version": "3.2.0",
    "config": {
      "merge": [
        {
          "source": "${BOOTSTRAP_IGN_URL}"
        }
      ]
    }
  }
}
EOF
```

Verify it's valid JSON:

```bash
jq . ~/ocp-h100-upi-install/bootstrap-shim.ign
```

Check size (must be < 64KB):

```bash
wc -c ~/ocp-h100-upi-install/bootstrap-shim.ign
```

Should be ~200-300 bytes.

---

## Phase B: Create Infrastructure

### Step 6: Create Security Group

#### 6a. Create the Security Group

```bash
ibmcloud is security-group-create ocp-h100-cluster-sg $VPC_ID --output json > /tmp/ocp-sg.json
export OCP_SG_ID=$(jq -r '.id' /tmp/ocp-sg.json)
echo "Security Group ID: $OCP_SG_ID"
```

Save to environment file (Phase 3 needs this):

```bash
sed -i '' "s/^export OCP_SG_ID=.*/export OCP_SG_ID=$OCP_SG_ID/" ~/.ibmcloud-h100-env
```

#### 6b. Add Inbound Rules

SSH (for debugging):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 22 --port-max 22 --remote 0.0.0.0/0
```

Kubernetes API (external access):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 6443 --port-max 6443 --remote 0.0.0.0/0
```

Machine Config Server (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 22623 --port-max 22623 --remote 10.240.0.0/24
```

etcd (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 2379 --port-max 2380 --remote 10.240.0.0/24
```

Kubelet + OpenShift components (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 10250 --port-max 10259 --remote 10.240.0.0/24
```

VXLAN overlay (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound udp --port-min 4789 --port-max 4789 --remote 10.240.0.0/24
```

Geneve overlay (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound udp --port-min 6081 --port-max 6081 --remote 10.240.0.0/24
```

OpenShift platform range (internal only):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 9000 --port-max 9999 --remote 10.240.0.0/24
```

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound udp --port-min 9000 --port-max 9999 --remote 10.240.0.0/24
```

ICMP (internal, for health checks):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound icmp --remote 10.240.0.0/24
```

Kubernetes NodePort range (CCM-created LB routes to NodePorts on masters):

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID inbound tcp --port-min 30000 --port-max 32767 --remote 10.240.0.0/24
```

#### 6c. Add Outbound Rule (All Traffic)

```bash
ibmcloud is security-group-rule-add $OCP_SG_ID outbound all --remote 0.0.0.0/0
```

#### 6d. Verify Security Group Rules

```bash
ibmcloud is security-group-rules $OCP_SG_ID
```

Should show ~12 rules (11 inbound + 1 outbound).

---

### Step 7: Import RHCOS Image

> **Why import?** IBM Cloud VPC doesn't have RHCOS images pre-loaded. We upload the RHCOS qcow2 (cached by the installer) to COS and import it as a VPC custom image.

#### 7a. Check for Existing RHCOS Image

```bash
export IMAGE_ID=$(ibmcloud is image ocp-rhcos --output json | jq -r '.id')
echo "RHCOS Image ID: $IMAGE_ID"
```

If IMAGE_ID is set, skip to Step 8.

#### 7b. Grant VPC Access to COS (Skip if Already Done)

> **Note**: If you get "policy_conflict_error", the authorization already exists from a previous run. This is safe to skip.

```bash
ibmcloud iam authorization-policy-create is cloud-object-storage Reader \
  --source-resource-type image \
  --target-service-instance-id $(ibmcloud resource service-instance ocp-cos --output json | jq -r '.[0].guid') 2>&1 || echo "Authorization already exists — OK"
```

#### 7c. Create COS Bucket for Image

```bash
ibmcloud cos bucket-create --bucket ocp-rhcos-image --region eu-de
```

#### 7c (cont). Upload RHCOS Image to COS

The RHCOS image is cached locally from previous installer runs (~2.1GB):

```bash
ibmcloud cos upload --bucket ocp-rhcos-image \
  --key rhcos-9.6.20260112-0-ibmcloud.x86_64.qcow2 \
  --file ~/Library/Caches/openshift-installer/image_cache/rhcos-9.6.20260112-0-ibmcloud.x86_64.qcow2 \
  --region eu-de
```

This takes 5-10 minutes.

#### 7d. Import as VPC Custom Image

```bash
ibmcloud is image-create ocp-rhcos \
  --file cos://eu-de/ocp-rhcos-image/rhcos-9.6.20260112-0-ibmcloud.x86_64.qcow2 \
  --os-name rhel-coreos-stable-amd64 \
  --output json > /tmp/rhcos-image.json
```

#### 7e. Wait for Image to Become Available

```bash
watch -n 15 'ibmcloud is image ocp-rhcos --output json | jq -r ".status"'
```

Wait until status shows `available` (5-10 minutes). Press `Ctrl+C` when ready.

#### 7f. Set Image ID

```bash
export IMAGE_ID=$(ibmcloud is image ocp-rhcos --output json | jq -r '.id')
echo "RHCOS Image ID: $IMAGE_ID"
```

---

### Step 8: Create Load Balancers

> **Two LBs needed**: API (public, port 6443) and API-int (private, ports 6443 + 22623)

#### 8a. Create API Load Balancer (Public)

```bash
ibmcloud is load-balancer-create ocp-api-lb public \
  --subnet $MGMT_SUBNET_ID \
  --family application \
  --output json > /tmp/api-lb.json
```

```bash
export API_LB_ID=$(jq -r '.id' /tmp/api-lb.json)
export API_LB_HOSTNAME=$(jq -r '.hostname' /tmp/api-lb.json)
echo "API LB ID: $API_LB_ID"
echo "API LB Hostname: $API_LB_HOSTNAME"
```

#### 8b. Create API-int Load Balancer (Private)

```bash
ibmcloud is load-balancer-create ocp-api-int-lb private \
  --subnet $MGMT_SUBNET_ID \
  --family application \
  --output json > /tmp/api-int-lb.json
```

```bash
export API_INT_LB_ID=$(jq -r '.id' /tmp/api-int-lb.json)
export API_INT_LB_HOSTNAME=$(jq -r '.hostname' /tmp/api-int-lb.json)
echo "API-int LB ID: $API_INT_LB_ID"
echo "API-int LB Hostname: $API_INT_LB_HOSTNAME"
```

#### 8c. Wait for Load Balancers to Become Active

```bash
echo "Waiting for load balancers to become active..."
while true; do
  API_STATUS=$(ibmcloud is load-balancer $API_LB_ID --output json | jq -r '.provisioning_status')
  INT_STATUS=$(ibmcloud is load-balancer $API_INT_LB_ID --output json | jq -r '.provisioning_status')
  echo "API LB: $API_STATUS | API-int LB: $INT_STATUS"
  if [ "$API_STATUS" = "active" ] && [ "$INT_STATUS" = "active" ]; then
    echo "Both load balancers are active"
    break
  fi
  sleep 15
done
```

This takes 3-5 minutes.

#### 8d. Create Backend Pools

API LB — port 6443 pool:

```bash
ibmcloud is load-balancer-pool-create ocp-api-pool $API_LB_ID round_robin tcp 15 2 5 tcp \
  --health-monitor-port 6443 \
  --output json > /tmp/api-pool.json
export API_POOL_ID=$(jq -r '.id' /tmp/api-pool.json)
echo "API Pool ID: $API_POOL_ID"
```

API-int LB — port 6443 pool:

```bash
ibmcloud is load-balancer-pool-create ocp-api-int-pool $API_INT_LB_ID round_robin tcp 15 2 5 tcp \
  --health-monitor-port 6443 \
  --output json > /tmp/api-int-pool.json
export API_INT_POOL_ID=$(jq -r '.id' /tmp/api-int-pool.json)
echo "API-int Pool ID: $API_INT_POOL_ID"
```

API-int LB — port 22623 pool (Machine Config Server):

```bash
ibmcloud is load-balancer-pool-create ocp-mcs-pool $API_INT_LB_ID round_robin tcp 15 2 5 tcp \
  --health-monitor-port 22623 \
  --output json > /tmp/mcs-pool.json
export MCS_POOL_ID=$(jq -r '.id' /tmp/mcs-pool.json)
echo "MCS Pool ID: $MCS_POOL_ID"
```

#### 8e. Create Listeners

API LB listener (port 6443):

```bash
ibmcloud is load-balancer-listener-create $API_LB_ID --port 6443 --protocol tcp \
  --default-pool $API_POOL_ID \
  --output json
```

API-int LB listener (port 6443):

```bash
ibmcloud is load-balancer-listener-create $API_INT_LB_ID --port 6443 --protocol tcp \
  --default-pool $API_INT_POOL_ID \
  --output json
```

API-int LB listener (port 22623):

```bash
ibmcloud is load-balancer-listener-create $API_INT_LB_ID --port 22623 --protocol tcp \
  --default-pool $MCS_POOL_ID \
  --output json
```

#### 8f. Fix Load Balancer Security Groups

> **CRITICAL**: IBM Cloud VPC auto-creates a security group for each load balancer that only allows inbound traffic from the LB's own SG — NOT from the internet or subnet. Without this fix, the Kubernetes API (port 6443) and Machine Config Server (port 22623) are unreachable through the LBs, causing `i/o timeout` errors.

Get the LB security group ID (both LBs share the same SG):

```bash
export LB_SG_ID=$(ibmcloud is load-balancer $API_LB_ID --output json | jq -r '.security_groups[0].id')
echo "LB Security Group ID: $LB_SG_ID"
```

Add port 6443 inbound from internet (for external API access):

```bash
ibmcloud is security-group-rule-add $LB_SG_ID inbound tcp --port-min 6443 --port-max 6443 --remote 0.0.0.0/0
```

Add port 6443 inbound from subnet (for internal API access):

```bash
ibmcloud is security-group-rule-add $LB_SG_ID inbound tcp --port-min 6443 --port-max 6443 --remote 10.240.0.0/24
```

Add port 22623 inbound from subnet (for Machine Config Server):

```bash
ibmcloud is security-group-rule-add $LB_SG_ID inbound tcp --port-min 22623 --port-max 22623 --remote 10.240.0.0/24
```

Verify the rules were added:

```bash
ibmcloud is security-group-rules $LB_SG_ID
```

#### 8g. Ingress Load Balancer — Created Automatically by CCM

> **No manual action needed.** The cloud-controller-manager (CCM) will automatically create the ingress load balancer when the IngressController is created during cluster installation. This works because:
>
> 1. The public gateway allows CCM to reach the VPC API via public endpoints
> 2. The default IngressController uses `LoadBalancerService` strategy
> 3. CCM creates the VPC LB, pools, listeners, and backend members automatically
>
> The `*.apps` DNS record (Step 9e) will be created as a placeholder — update it after install-complete when you know the CCM-created LB hostname.

---

### Step 9: Create DNS Records in CIS

#### 9a. Set CIS Context

```bash
ibmcloud cis instance-set ocp-cis
```

#### 9b. Get CIS Domain ID

```bash
export CIS_DOMAIN_ID=$(ibmcloud cis domains --output json | jq -r '.[0].id')
echo "CIS Domain ID: $CIS_DOMAIN_ID"
```

#### 9c. Create API DNS Record

```bash
ibmcloud cis dns-record-create $CIS_DOMAIN_ID \
  --type CNAME \
  --name "api.${CLUSTER_NAME}" \
  --content "$API_LB_HOSTNAME" \
  --ttl 120
```

#### 9d. Create API-int DNS Record

```bash
ibmcloud cis dns-record-create $CIS_DOMAIN_ID \
  --type CNAME \
  --name "api-int.${CLUSTER_NAME}" \
  --content "$API_INT_LB_HOSTNAME" \
  --ttl 120
```

#### 9e. Apps Wildcard DNS — Created Later in Step 16b

> **Do NOT create the `*.apps` record here.** The ingress LB hostname isn't known until CCM creates it during installation. Creating a placeholder pointing to the wrong backend causes silent routing failures. The `*.apps` record will be created in Step 16b after the CCM-created LB hostname is available.
>
> `wait-for bootstrap-complete` (Step 14) does NOT need `*.apps` DNS — it only needs `api` and `api-int`.

#### 9f. Flush DNS and Verify

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
```

```bash
dig api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
```

Should resolve to the API LB hostname/IPs.

```bash
dig api-int.${CLUSTER_NAME}.${BASE_DOMAIN} +short
```

Should resolve to the API-int LB hostname/IPs.

> **Note**: Do NOT test `*.apps` DNS here — the `*.apps` record hasn't been created yet (that happens in Step 16c after the CCM creates the ingress LB).

---

## Phase C: Deploy Instances

### Step 10: Create Bootstrap Instance

```bash
ibmcloud is instance-create ocp-bootstrap \
  $VPC_ID \
  eu-de-2 \
  bx2-4x16 \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/bootstrap-shim.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/bootstrap-instance.json
```

```bash
export BOOTSTRAP_ID=$(jq -r '.id' /tmp/bootstrap-instance.json)
export BOOTSTRAP_IP=$(jq -r '.primary_network_interface.primary_ip.address' /tmp/bootstrap-instance.json)
echo "Bootstrap ID: $BOOTSTRAP_ID"
echo "Bootstrap IP: $BOOTSTRAP_IP"
```

Attach floating IP for SSH debugging:

```bash
export BOOTSTRAP_VNI_ID=$(jq -r '.primary_network_attachment.virtual_network_interface.id' /tmp/bootstrap-instance.json)
ibmcloud is floating-ip-reserve ocp-bootstrap-fip \
  --vni $BOOTSTRAP_VNI_ID \
  --output json > /tmp/bootstrap-fip.json
export BOOTSTRAP_FIP=$(jq -r '.address' /tmp/bootstrap-fip.json)
echo "Bootstrap Floating IP: $BOOTSTRAP_FIP"
```

---

### Step 11: Create 3 Master Instances

Master 0:

```bash
ibmcloud is instance-create ocp-master-0 \
  $VPC_ID \
  eu-de-2 \
  bx2-8x32 \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/master.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/master-0.json
export MASTER0_ID=$(jq -r '.id' /tmp/master-0.json)
export MASTER0_IP=$(jq -r '.primary_network_interface.primary_ip.address' /tmp/master-0.json)
echo "Master-0 ID: $MASTER0_ID  IP: $MASTER0_IP"
```

Master 1:

```bash
ibmcloud is instance-create ocp-master-1 \
  $VPC_ID \
  eu-de-2 \
  bx2-8x32 \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/master.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/master-1.json
export MASTER1_ID=$(jq -r '.id' /tmp/master-1.json)
export MASTER1_IP=$(jq -r '.primary_network_interface.primary_ip.address' /tmp/master-1.json)
echo "Master-1 ID: $MASTER1_ID  IP: $MASTER1_IP"
```

Master 2:

```bash
ibmcloud is instance-create ocp-master-2 \
  $VPC_ID \
  eu-de-2 \
  bx2-8x32 \
  $MGMT_SUBNET_ID \
  --image $IMAGE_ID \
  --user-data @$HOME/ocp-h100-upi-install/master.ign \
  --sgs $OCP_SG_ID \
  --metadata-service true \
  --output json > /tmp/master-2.json
export MASTER2_ID=$(jq -r '.id' /tmp/master-2.json)
export MASTER2_IP=$(jq -r '.primary_network_interface.primary_ip.address' /tmp/master-2.json)
echo "Master-2 ID: $MASTER2_ID  IP: $MASTER2_IP"
```

Verify all instances are running:

```bash
ibmcloud is instances --output json | jq -r '.[] | select(.name | startswith("ocp-")) | "\(.name) | \(.status) | \(.primary_network_interface.primary_ip.address)"'
```

**Expected**: 4 instances (1 bootstrap + 3 masters) all `running`.

---

### Step 12: Add Instances to Load Balancer Pools

#### 12-pre. Recover Environment Variables

> **Why?** Steps 8 and 10-11 set variables with `export`, but these are lost if your terminal session resets. Run this block to re-derive all IDs from existing resources.

```bash
source ~/.ibmcloud-h100-env

# Load Balancer IDs
export API_LB_ID=$(ibmcloud is load-balancers --output json | jq -r '.[] | select(.name=="ocp-api-lb") | .id')
export API_INT_LB_ID=$(ibmcloud is load-balancers --output json | jq -r '.[] | select(.name=="ocp-api-int-lb") | .id')

# Pool IDs
export API_POOL_ID=$(ibmcloud is load-balancer-pools $API_LB_ID --output json | jq -r '.[] | select(.name=="ocp-api-pool") | .id')
export API_INT_POOL_ID=$(ibmcloud is load-balancer-pools $API_INT_LB_ID --output json | jq -r '.[] | select(.name=="ocp-api-int-pool") | .id')
export MCS_POOL_ID=$(ibmcloud is load-balancer-pools $API_INT_LB_ID --output json | jq -r '.[] | select(.name=="ocp-mcs-pool") | .id')

# LB Hostnames (for DNS in Step 9)
export API_LB_HOSTNAME=$(ibmcloud is load-balancer $API_LB_ID --output json | jq -r '.hostname')
export API_INT_LB_HOSTNAME=$(ibmcloud is load-balancer $API_INT_LB_ID --output json | jq -r '.hostname')

# Security Group ID
export OCP_SG_ID=$(ibmcloud is security-groups --output json | jq -r '.[] | select(.name=="ocp-h100-cluster-sg") | .id')

# RHCOS Image ID
export IMAGE_ID=$(ibmcloud is images --visibility private --output json | jq -r '.[] | select(.name=="ocp-rhcos") | .id')

# Instance IPs
export BOOTSTRAP_IP=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-bootstrap") | .primary_network_interface.primary_ip.address')
export MASTER0_IP=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-master-0") | .primary_network_interface.primary_ip.address')
export MASTER1_IP=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-master-1") | .primary_network_interface.primary_ip.address')
export MASTER2_IP=$(ibmcloud is instances --output json | jq -r '.[] | select(.name=="ocp-master-2") | .primary_network_interface.primary_ip.address')

echo "API_LB_ID=$API_LB_ID"
echo "API_INT_LB_ID=$API_INT_LB_ID"
echo "API_POOL_ID=$API_POOL_ID"
echo "API_INT_POOL_ID=$API_INT_POOL_ID"
echo "MCS_POOL_ID=$MCS_POOL_ID"
echo "BOOTSTRAP_IP=$BOOTSTRAP_IP"
echo "MASTER0_IP=$MASTER0_IP"
echo "MASTER1_IP=$MASTER1_IP"
echo "MASTER2_IP=$MASTER2_IP"
```

Verify none are empty before proceeding.

#### 12a. Add to API LB Pool (port 6443)

> The LB goes into `update_pending` after each member addition. Wait 60 seconds between each. If you get errors, wait longer and retry.

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_LB_ID $API_POOL_ID 6443 $BOOTSTRAP_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_LB_ID $API_POOL_ID 6443 $MASTER0_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_LB_ID $API_POOL_ID 6443 $MASTER1_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_LB_ID $API_POOL_ID 6443 $MASTER2_IP
```

#### 12b. Add to API-int LB Pool (port 6443)

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $API_INT_POOL_ID 6443 $BOOTSTRAP_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $API_INT_POOL_ID 6443 $MASTER0_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $API_INT_POOL_ID 6443 $MASTER1_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $API_INT_POOL_ID 6443 $MASTER2_IP
```

#### 12c. Add to MCS Pool (port 22623)

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $MCS_POOL_ID 22623 $BOOTSTRAP_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $MCS_POOL_ID 22623 $MASTER0_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $MCS_POOL_ID 22623 $MASTER1_IP
```

```bash
sleep 60 && ibmcloud is load-balancer-pool-member-create $API_INT_LB_ID $MCS_POOL_ID 22623 $MASTER2_IP
```

#### 12d. Verify All Pool Members

> Wait 60 seconds after the last add for the LB to finish processing.

```bash
sleep 60
echo "API pool:     $(ibmcloud is load-balancer-pool-members $API_LB_ID $API_POOL_ID --output json | jq '. | length') members"
echo "API-int pool: $(ibmcloud is load-balancer-pool-members $API_INT_LB_ID $API_INT_POOL_ID --output json | jq '. | length') members"
echo "MCS pool:     $(ibmcloud is load-balancer-pool-members $API_INT_LB_ID $MCS_POOL_ID --output json | jq '. | length') members"
```

Expected: API=4, API-int=4, MCS=4. (Ingress pool members are managed by CCM automatically — no manual action needed.)

#### 12e. Test API Reachability Through LB

```bash
curl -sk --connect-timeout 10 https://api.${CLUSTER_NAME}.${BASE_DOMAIN}:6443/version | head -5
```

Should return Kubernetes version JSON (or connection refused if instances haven't fully booted yet). If it times out, the LB SG rules from Step 8f didn't apply — check `ibmcloud is security-group-rules $LB_SG_ID`.

---

## Phase D: Bootstrap

### Step 13: Start DNS Flush Loop

> **Why?** macOS aggressively caches DNS negative results. If `api.ocp-h100-cluster.ibmc...` was queried before the CIS records propagated, macOS caches the NXDOMAIN and `openshift-install` (which uses the system resolver) will fail with `no such host`. This flush loop clears that negative cache every 30 seconds.

In a **second terminal**:

```bash
sudo echo "sudo cached" && while true; do sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder && echo "$(date): DNS cache flushed"; sleep 30; done
```

> **When to stop**: Kill this loop (`Ctrl+C`) after `wait-for install-complete` succeeds (Step 17). It's only needed while `openshift-install` is running on your Mac.

---

### Step 14: Wait for Bootstrap Complete

> **This takes 30-40 minutes.** The bootstrap node starts etcd, creates the temporary control plane, then hands off to the masters.

```bash
openshift-install wait-for bootstrap-complete \
  --dir ~/ocp-h100-upi-install \
  --log-level=debug
```

**What happens:**
1. Bootstrap instance downloads full ignition from COS
2. Bootstrap starts temporary etcd + kube-apiserver
3. Masters download their config from bootstrap's MCS (port 22623)
4. Masters start their own etcd + kube-apiserver
5. Control plane transitions from bootstrap to masters
6. Bootstrap signals completion

**Success message:**
```
INFO It is now safe to remove the bootstrap resources
INFO Time elapsed: Xm
```

**If it fails:**

SSH to bootstrap for debugging:

```bash
ssh -o StrictHostKeyChecking=no core@$BOOTSTRAP_FIP
```

On the bootstrap, check:

```bash
sudo journalctl -u bootkube.service -f
sudo journalctl -u kubelet.service -f
sudo crictl ps
```

---

### Step 15: Clean Up Bootstrap Resources

After bootstrap completes successfully:

#### 15a. Remove Bootstrap from LB Pools

Get the pool member IDs for bootstrap:

```bash
export BOOTSTRAP_API_MEMBER=$(ibmcloud is load-balancer-pool-members $API_LB_ID $API_POOL_ID --output json | jq -r ".[] | select(.target.address == \"$BOOTSTRAP_IP\") | .id")
ibmcloud is load-balancer-pool-member-delete $API_LB_ID $API_POOL_ID $BOOTSTRAP_API_MEMBER --force
```

```bash
export BOOTSTRAP_INT_MEMBER=$(ibmcloud is load-balancer-pool-members $API_INT_LB_ID $API_INT_POOL_ID --output json | jq -r ".[] | select(.target.address == \"$BOOTSTRAP_IP\") | .id")
ibmcloud is load-balancer-pool-member-delete $API_INT_LB_ID $API_INT_POOL_ID $BOOTSTRAP_INT_MEMBER --force
```

```bash
export BOOTSTRAP_MCS_MEMBER=$(ibmcloud is load-balancer-pool-members $API_INT_LB_ID $MCS_POOL_ID --output json | jq -r ".[] | select(.target.address == \"$BOOTSTRAP_IP\") | .id")
ibmcloud is load-balancer-pool-member-delete $API_INT_LB_ID $MCS_POOL_ID $BOOTSTRAP_MCS_MEMBER --force
```

#### 15b. Delete Bootstrap Instance

```bash
ibmcloud is instance-delete ocp-bootstrap --force
```

#### 15c. Release Bootstrap Floating IP

```bash
ibmcloud is floating-ip-release ocp-bootstrap-fip --force
```

#### 15d. Remove Bootstrap Ignition from COS and HMAC Credentials

```bash
ibmcloud cos object-delete --bucket ocp-bootstrap-ign --key bootstrap.ign --region eu-de --force
```

```bash
ibmcloud resource service-key-delete ocp-cos-hmac --force
```

---

## Phase E: Complete Installation

### Step 16: Configure DNS Forwarder and Create Credential Secrets

> **Why?** The VPC internal DNS resolver (`161.26.0.x`) cannot resolve CIS-managed domains (returns NXDOMAIN). OpenShift pods use CoreDNS, which forwards to the VPC DNS resolver by default. We add a DNS forwarder so CoreDNS forwards our domain to Google DNS (which can resolve CIS records).

#### 16a. Add DNS Forwarder for CIS Domain

```bash
export KUBECONFIG=$HOME/ocp-h100-upi-install/auth/kubeconfig
```

```bash
oc patch dns.operator default --type merge -p '{
  "spec": {
    "servers": [
      {
        "name": "apps-dns-forwarder",
        "zones": ["ibmc.kni.syseng.devcluster.openshift.com"],
        "forwardPlugin": {
          "upstreams": ["8.8.8.8", "8.8.4.4"],
          "policy": "Random"
        }
      }
    ]
  }
}'
```

Wait for CoreDNS to pick up the new config (auto-reloads within ~30 seconds):

```bash
sleep 30
oc get configmap dns-default -n openshift-dns -o jsonpath='{.data.Corefile}' | head -10
```

Should show `ibmc.kni.syseng.devcluster.openshift.com:5353` with `forward . 8.8.8.8 8.8.4.4`. If not, wait and check again — the dns-operator reconciles the Corefile from the `dns.operator` CR.

#### 16b. Wait for CCM-Created Ingress LB

The CCM creates the ingress VPC load balancer automatically when the IngressController starts. This takes ~5 minutes. Poll until the hostname appears:

```bash
echo "Waiting for CCM to create ingress LB..."
while true; do
  INGRESS_LB_HOSTNAME=$(oc get svc -n openshift-ingress router-default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)
  if [ -n "$INGRESS_LB_HOSTNAME" ]; then
    echo "CCM-created LB: $INGRESS_LB_HOSTNAME"
    break
  fi
  echo "$(date +%H:%M:%S) - Still pending..."
  sleep 30
done
```

> **If this hangs for >10 minutes**: Check CCM logs with `oc get pods -n openshift-cloud-controller-manager -o name | head -1 | xargs -I{} oc logs -n openshift-cloud-controller-manager {} --tail=20`. If you see `i/o timeout`, verify the public gateway is attached to the subnet (`ibmcloud is subnet $MGMT_SUBNET_ID --output json | jq -r '.public_gateway.name'`).

#### 16c. Create *.apps DNS Record

```bash
ibmcloud cis instance-set ocp-cis
export CIS_DOMAIN_ID=$(ibmcloud cis domains --output json | jq -r '.[0].id')

# Create or update — handles both fresh deploy and re-runs
APPS_RECORD_ID=$(ibmcloud cis dns-records $CIS_DOMAIN_ID -i ocp-cis --output json | jq -r '.[] | select(.name | contains("*.apps")) | .id')
if [ -n "$APPS_RECORD_ID" ]; then
  echo "Updating existing *.apps record..."
  ibmcloud cis dns-record-update $CIS_DOMAIN_ID $APPS_RECORD_ID -i ocp-cis \
    --type CNAME --name "*.apps.${CLUSTER_NAME}" --content "$INGRESS_LB_HOSTNAME" --ttl 120
else
  echo "Creating *.apps record..."
  ibmcloud cis dns-record-create $CIS_DOMAIN_ID \
    --type CNAME --name "*.apps.${CLUSTER_NAME}" --content "$INGRESS_LB_HOSTNAME" --ttl 120
fi
```

Verify resolution (from your Mac):

```bash
dig +short console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
```

Should return the LB hostname and its IPs.

#### 16d. Create Credential Secrets (if not embedded in ignition)

> **Note**: If you followed Step 4 correctly (manifests → secrets → ignition), these secrets are already embedded. If they're missing, create them now:

```bash
for ns_secret in \
  "openshift-cloud-controller-manager:ibm-cloud-credentials" \
  "openshift-machine-api:ibmcloud-credentials" \
  "openshift-image-registry:installer-cloud-credentials" \
  "openshift-ingress-operator:cloud-credentials" \
  "openshift-cluster-csi-drivers:ibm-cloud-credentials"; do
  NS="${ns_secret%%:*}"
  SECRET="${ns_secret##*:}"
  oc get secret $SECRET -n $NS 2>/dev/null || \
    oc create secret generic $SECRET -n $NS --from-literal=ibmcloud_api_key=$IBMCLOUD_API_KEY
done
```

---

### Step 17: Wait for Install Complete

```bash
openshift-install wait-for install-complete \
  --dir ~/ocp-h100-upi-install \
  --log-level=debug
```

> **This takes 20-30 minutes.** The installer waits for all cluster operators to become Available.

**Success message:**
```
INFO Install complete!
INFO To access the cluster as the system:admin user when using 'oc', run 'export KUBECONFIG=...'
INFO Access the OpenShift web-console here: https://console-openshift-console.apps...
INFO Login to the console with user: "kubeadmin", and password: "xxxxx-xxxxx-xxxxx-xxxxx"
```

---

### Step 18: Verify and Save

#### 18a. Check Nodes

```bash
oc get nodes
```

**Expected:**
```
NAME          STATUS   ROLES                  AGE   VERSION
ocp-master-0  Ready    control-plane,master   Xm    v1.x.x
ocp-master-1  Ready    control-plane,master   Xm    v1.x.x
ocp-master-2  Ready    control-plane,master   Xm    v1.x.x
```

#### 18b. Check Cluster Operators

```bash
oc get co
```

All should show `AVAILABLE=True`, `PROGRESSING=False`, `DEGRADED=False`.

#### 18c. Get Cluster Version

```bash
oc get clusterversion
```

#### 18d. Get Access Information

```bash
echo "API URL: $(oc whoami --show-server)"
echo "Console URL: $(oc whoami --show-console)"
echo "kubeadmin password: $(cat ~/ocp-h100-upi-install/auth/kubeadmin-password)"
```

#### 18e. Verify Apps DNS and Console Access

```bash
echo "DNS resolution:"
dig +short console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}

echo ""
echo "Console HTTP status:"
curl -sk -o /dev/null -w "%{http_code}" https://console-openshift-console.apps.${CLUSTER_NAME}.${BASE_DOMAIN}
```

DNS should return the CCM-created LB IPs. Console should return HTTP `200`.

#### 18f. Save Cluster Info

```bash
cat > ~/ocp-h100-upi-install/cluster-info.txt << EOF
OpenShift Cluster Information (UPI)
Generated: $(date)
=====================================

Cluster Name:        ${CLUSTER_NAME}
Base Domain:         ${BASE_DOMAIN}
OpenShift Version:   $(oc version -o json | jq -r '.openshiftVersion')
Region:              eu-de
Method:              UPI (User-Provisioned Infrastructure)

API URL:             $(oc whoami --show-server)
Console URL:         $(oc whoami --show-console)

Credentials:
  Username:          kubeadmin
  Password:          $(cat ~/ocp-h100-upi-install/auth/kubeadmin-password)

Kubeconfig:          ~/ocp-h100-upi-install/auth/kubeconfig

Instances:
  Master-0:          $MASTER0_IP ($MASTER0_ID)
  Master-1:          $MASTER1_IP ($MASTER1_ID)
  Master-2:          $MASTER2_IP ($MASTER2_ID)

Load Balancers:
  API:               $API_LB_HOSTNAME ($API_LB_ID)
  API-int:           $API_INT_LB_HOSTNAME ($API_INT_LB_ID)

Security Group:      $OCP_SG_ID

=====================================
EOF

cat ~/ocp-h100-upi-install/cluster-info.txt
```

Stop the DNS flush loop in the second terminal (Ctrl+C).

---

## Checkpoint Summary

At the end of Phase 2 (UPI), you should have:

- [x] **VPC created** (`rdma-pvc-eude`) with subnet, public gateway, and address prefix
- [x] **VPC_ID and MGMT_SUBNET_ID** saved to `~/.ibmcloud-h100-env`
- [x] **3 master nodes** in Ready state
- [x] **All cluster operators** Available
- [x] **API and API-int load balancers** active
- [x] **DNS records** for api, api-int, *.apps
- [x] **Kubeconfig** at `~/ocp-h100-upi-install/auth/kubeconfig`
- [x] **Admin credentials** saved
- [x] **Bootstrap cleaned up** (instance deleted, COS cleaned)
- [x] **Web console** accessible

---

## Troubleshooting

### Bootstrap Never Completes

SSH to bootstrap:

```bash
ssh -o StrictHostKeyChecking=no core@$BOOTSTRAP_FIP
```

Check services:

```bash
sudo journalctl -u bootkube.service --no-pager | tail -50
sudo journalctl -u kubelet.service --no-pager | tail -50
```

### Instances Don't Get Ignition

Check user-data was set:

```bash
ibmcloud is instance ocp-bootstrap --output json | jq '.metadata_service, .user_data'
```

`metadata_service.enabled` should be `true`. `user_data` should not be null.

### Load Balancer Health Checks Failing

Check LB pool member health:

```bash
ibmcloud is load-balancer-pool-members $API_LB_ID $API_POOL_ID
```

Members should show `health: ok` once the API server starts.

### DNS Not Resolving

Flush and recheck:

```bash
sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
dig api.${CLUSTER_NAME}.${BASE_DOMAIN} +short
```

### Cluster Operators Stuck

```bash
oc get co | grep -v "True.*False.*False" | grep -v "^NAME"
oc describe co <operator-name>
```

---

## Clean Up (If Deployment Fails)

To start over, delete all resources. **Order matters** — load balancers must be fully deprovisioned before subnet/VPC deletion.

### Teardown Step 1: Delete ALL Load Balancers FIRST

> **CRITICAL**: Delete load balancers before instances. The CCM creates LBs that may not match obvious name patterns (`ocp-*`, `kube-*`). Delete ALL LBs unconditionally, then wait for their reserved IPs to be cleaned up before proceeding.

```bash
# List ALL load balancers
ibmcloud is load-balancers --output json | jq -r '.[] | "\(.name) | \(.id)"'
```

```bash
# Delete ALL load balancers unconditionally
for LB_ID in $(ibmcloud is load-balancers --output json | jq -r '.[].id'); do
  echo -n "Deleting $LB_ID... "
  ibmcloud is load-balancer-delete $LB_ID --force
done
```

### Teardown Step 2: Wait for LB Reserved IPs to Clear

> **Why wait here?** Deleted LBs leave orphaned reserved IPs on the subnet. Until IBM Cloud's backend cleans them up, the subnet cannot be deleted. This takes 5-30 minutes.

```bash
echo "Waiting for LB reserved IPs to clear..."
while true; do
  GHOST_COUNT=$(ibmcloud is subnet-reserved-ips $MGMT_SUBNET_ID --output json | jq '[.[] | select(.target.resource_type == "load_balancer")] | length')
  if [ "$GHOST_COUNT" = "0" ]; then
    echo "All LB reserved IPs cleared"
    break
  fi
  echo "$(date +%H:%M:%S) - $GHOST_COUNT ghost LB reserved IPs remaining, waiting..."
  sleep 120
done
```

### Teardown Step 3: Delete Instances and Floating IPs

```bash
# Delete instances
ibmcloud is instance-delete ocp-bootstrap --force 2>/dev/null
ibmcloud is instance-delete ocp-master-0 --force
ibmcloud is instance-delete ocp-master-1 --force
ibmcloud is instance-delete ocp-master-2 --force

# Wait for instance deletion
sleep 60

# Delete floating IPs
ibmcloud is floating-ip-release ocp-bootstrap-fip --force 2>/dev/null
```

### Teardown Step 4: Delete Security Groups, Image, DNS, COS

```bash
# Delete security groups (except default)
ibmcloud is security-group-delete ocp-h100-cluster-sg --force
# Auto-created LB SGs
ibmcloud is security-groups --output json | jq -r '.[] | select(.name | contains("kube-api-lb") or contains("sg-kube")) | .id' | xargs -I{} ibmcloud is security-group-delete {} --force 2>/dev/null

# Delete custom image
ibmcloud is image-delete ocp-rhcos --force 2>/dev/null

# Delete DNS records
ibmcloud cis instance-set ocp-cis
export CIS_DOMAIN_ID=$(ibmcloud cis domains --output json | jq -r '.[0].id')
for record in $(ibmcloud cis dns-records $CIS_DOMAIN_ID --output json | jq -r '.[].id'); do
  echo "y" | ibmcloud cis dns-record-delete $CIS_DOMAIN_ID $record
done

# Clean COS
ibmcloud cos object-delete --bucket ocp-bootstrap-ign --key bootstrap.ign --region eu-de --force 2>/dev/null
ibmcloud cos object-delete --bucket ocp-rhcos-image --key rhcos.qcow2 --region eu-de --force 2>/dev/null

# Remove install directory
rm -rf ~/ocp-h100-upi-install
```

### Teardown Step 5: Delete VPC Resources (Phase 0)

```bash
# Detach public gateway from subnet
echo "y" | ibmcloud is subnet-public-gateway-detach $MGMT_SUBNET_ID

# Delete subnet (should succeed since Step 2 confirmed LB reserved IPs are cleared)
ibmcloud is subnet-delete $MGMT_SUBNET_ID --force

# Delete public gateway
ibmcloud is public-gateway-delete ocp-pgw --force

# Delete address prefix
ADDR_PREFIX_ID=$(ibmcloud is vpc-address-prefixes $VPC_ID --output json | jq -r '.[] | select(.name=="mgmt-prefix") | .id')
ibmcloud is vpc-address-prefix-delete $VPC_ID $ADDR_PREFIX_ID --force

# Delete VPC
ibmcloud is vpc-delete $VPC_ID --force
```

### Teardown Step 6: Clear Environment Variables

```bash
sed -i '' "s/^export VPC_ID=.*/export VPC_ID=/" ~/.ibmcloud-h100-env
sed -i '' "s/^export MGMT_SUBNET_ID=.*/export MGMT_SUBNET_ID=/" ~/.ibmcloud-h100-env
sed -i '' "s/^export OCP_SG_ID=.*/export OCP_SG_ID=/" ~/.ibmcloud-h100-env
source ~/.ibmcloud-h100-env
echo "Environment variables cleared"
```

---

## Next Steps

After Phase 2 completes:

1. **Phase 3**: Provision H100 GPU instance — See [PHASE3-H100-PROVISIONING.md](PHASE3-H100-PROVISIONING.md)
2. **Phase 4**: Join H100 as worker node — See [PHASE4-WORKER-INTEGRATION.md](PHASE4-WORKER-INTEGRATION.md)

---

**Phase 2 (UPI) Complete! ✅**
