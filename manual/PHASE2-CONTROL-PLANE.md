# Phase 2: Deploy OpenShift IPI Control Plane

## Overview

This phase deploys a 3-node OpenShift control plane on IBM Cloud VPC using the Installer-Provisioned Infrastructure (IPI) method.

**What You'll Accomplish:**
- Create CIS instance and configure DNS domain
- Generate OpenShift installation configuration
- Create cloud credential manifests using `ccoctl` (via Podman)
- Deploy 3 master nodes using openshift-install
- Configure cluster access with kubeconfig
- Verify control plane health
- Obtain console credentials

**Estimated Time**: 75-105 minutes (CIS setup + credential setup + 45-60 min installer)

## Pre-Flight Checks

Before starting, ensure Phase 1 is complete:

- [ ] Environment file exists: `~/.ibmcloud-h100-env`
- [ ] IBM Cloud CLI is logged in
- [ ] openshift-install is version 4.20+
- [ ] oc CLI is version 4.20+
- [ ] Pull secret exists at `~/.pull-secret.json`
- [ ] SSH public key exists at `~/.ssh/id_rsa.pub`
- [ ] Podman is installed and machine is running
- [ ] IBM Cloud CIS plugin installed (`ibmcloud plugin install cis`)

### Quick Verification

```bash
source ~/.ibmcloud-h100-env
verify_environment
```

Expected output: `✅ Environment loaded successfully`

```bash
ibmcloud target
```

Verify region is `eu-de` and resource group is `Default`.

```bash
podman machine list
```

Verify a machine is listed with status `Currently running`. If not:

```bash
podman machine start
```

---

## Key Information for This Phase

| Resource | Value |
|----------|-------|
| **Base Domain** | `ibmc.kni.syseng.devcluster.openshift.com` |
| **CIS Instance** | Will be created in Step 4 |
| **CIS Plan** | `standard-next` (~$200/month) |
| **Management Subnet** | `ocp-mgmt-subnet` (10.240.0.0/24, eu-de-2) |
| **VPC** | `rdma-pvc-eude` |
| **COS Instance** | `ocp-cos` |
| **Release Image Architecture** | amd64 (target cluster) |

---

## Step-by-Step Instructions

### Step 1: Load Environment

Source the environment configuration:

```bash
source ~/.ibmcloud-h100-env
```

### Step 2: Login to IBM Cloud

Authenticate to IBM Cloud:

```bash
ibmcloud_login
```

**Expected Output:**
```
Logging into IBM Cloud...
API endpoint:     https://cloud.ibm.com
Region:           eu-de
...
Targeted resource group Default
...
OK
```

---

### Step 3: Set IC_API_KEY

The OpenShift installer and `ccoctl` utility require the `IC_API_KEY` environment variable (not `IBMCLOUD_API_KEY`).

Export it:

```bash
export IC_API_KEY="$IBMCLOUD_API_KEY"
```

Verify it's set:

```bash
echo "IC_API_KEY length: ${#IC_API_KEY} chars"
```

Should show a length of ~44 characters.

Add to your environment file for persistence:

```bash
grep -q "IC_API_KEY" ~/.ibmcloud-h100-env || cat >> ~/.ibmcloud-h100-env << 'ENVEOF'

# OpenShift installer requires IC_API_KEY (not IBMCLOUD_API_KEY)
export IC_API_KEY="$IBMCLOUD_API_KEY"
ENVEOF
```

---

### Step 4: Ensure Public Gateway on Subnet

> **CRITICAL**: Without a public gateway, master nodes cannot reach the internet (Red Hat registries, COS for ignition). The bootstrap will fail with `EOF` errors because masters can't pull container images or form an etcd cluster.

#### 4a. Check if Public Gateway Exists

```bash
ibmcloud is subnet ocp-mgmt-subnet --output json | jq -r '.public_gateway // "NONE"'
```

**If output shows a gateway object** — already attached. Skip to Step 5.

**If output shows `NONE`** — continue below.

#### 4b. Create Public Gateway

```bash
ibmcloud is public-gateway-create ocp-pgw rdma-pvc-eude eu-de-2
```

**Expected Output:**
```
ID       r010-...
Name     ocp-pgw
Status   available
Zone     eu-de-2
```

#### 4c. Attach Public Gateway to Subnet

```bash
ibmcloud is subnet-update ocp-mgmt-subnet --pgw ocp-pgw
```

**Expected Output:** Shows subnet with `Public Gateway: ocp-pgw`

#### 4d. Verify

```bash
ibmcloud is subnet ocp-mgmt-subnet --output json | jq -r '"Public Gateway: \(.public_gateway.name)"'
```

**Expected:** `Public Gateway: ocp-pgw`

> **Note**: The public gateway is a one-time setup. Once attached, all instances in the subnet get outbound internet access. It persists across cluster deployments.

---

### Step 5: Create CIS Instance and Configure Domain (Skip if Already Done)

OpenShift IPI on IBM Cloud requires IBM Cloud Internet Services (CIS) to manage DNS records for the cluster. The installer creates `api.<cluster>.<domain>` and `*.apps.<cluster>.<domain>` records automatically.

> **Cost**: CIS standard-next plan costs ~$200/month. This is required for the duration of the cluster.

#### 4a. Verify No Existing CIS Instance

```bash
ibmcloud resource service-instances --service-name internet-svcs
```

**Expected**: `No service instance found.`

If a CIS instance already exists with your domain, skip to Step 4g.

#### 4b. Create CIS Instance

```bash
ibmcloud resource service-instance-create ocp-cis internet-svcs standard-next global -g Default
```

**What this does:**
- `ocp-cis` — Name of the new CIS instance
- `internet-svcs` — IBM Cloud Internet Services
- `standard-next` — Standard plan (required for OpenShift)
- `global` — CIS is a global service
- `-g Default` — In your Default resource group

**Expected Output:**
```
Creating service instance ocp-cis in resource group Default...
OK
Service instance ocp-cis was created.
...
```

#### 4c. Verify Instance Created

```bash
ibmcloud resource service-instance ocp-cis
```

Should show `State: active`.

#### 4d. Set CIS Instance Context

```bash
ibmcloud cis instance-set ocp-cis
```

**Expected Output:**
```
Setting context service instance to 'ocp-cis' ...
OK
```

#### 4e. Add Domain to CIS

```bash
ibmcloud cis domain-add ibmc.kni.syseng.devcluster.openshift.com
```

**Expected Output:**
```
Adding domain 'ibmc.kni.syseng.devcluster.openshift.com' ...
OK
...
```

#### 4f. Get CIS Nameservers

The domain will initially show `pending` status. This is normal — it needs NS delegation.

```bash
ibmcloud cis domains
```

Note the domain ID from the output, then get the nameservers:

```bash
export CIS_DOMAIN_ID=$(ibmcloud cis domains --output json | jq -r '.[0].id')
echo "Domain ID: $CIS_DOMAIN_ID"
```

```bash
ibmcloud cis domain $CIS_DOMAIN_ID --output json | jq -r '.name_servers[]'
```

**Expected Output** (nameservers will vary):
```
nsXXX.name.cloud.ibm.com
nsYYY.name.cloud.ibm.com
```

**Save these nameservers** — they are needed for NS delegation.

#### 4g. Set Up NS Delegation

> **IMPORTANT**: For the domain to become `active`, NS records must be created in the **parent DNS zone** pointing to the CIS nameservers from Step 4f.

Since `ibmc.kni.syseng.devcluster.openshift.com` is under Red Hat's `devcluster.openshift.com`:

1. Contact the owner of the parent zone (`devqe.ibmc.devcluster.openshift.com` or higher)
2. Request they add NS records for `ibmc.kni.syseng.devcluster.openshift.com` pointing to the two CIS nameservers from Step 4f
3. Example DNS records to add in parent zone:
   ```
   ibmc.kni.syseng.devcluster.openshift.com.  NS  nsXXX.name.cloud.ibm.com.
   ibmc.kni.syseng.devcluster.openshift.com.  NS  nsYYY.name.cloud.ibm.com.
   ```

> **Note**: If the previous NS delegation for this domain is still active in the parent zone, you may get different CIS nameservers this time. The parent zone must be updated to match the new nameservers.

#### 4h. Wait for Domain to Become Active

Monitor the domain status:

```bash
ibmcloud cis domains
```

**Expected progression:**
```
Status: pending    →    Status: active
```

This can take **a few minutes to several hours** depending on DNS propagation and how quickly the parent zone is updated.

> **Do NOT proceed to Step 6 until the domain shows `active` status.**

You can continue with Step 5 while waiting.

To check status periodically:

```bash
watch -n 30 'ibmcloud cis domains'
```

Press `Ctrl+C` when status shows `active`.

#### 4i. Save CIS Details to Environment

Once the domain is active:

```bash
export BASE_DOMAIN="ibmc.kni.syseng.devcluster.openshift.com"
```

```bash
grep -q "BASE_DOMAIN" ~/.ibmcloud-h100-env || cat >> ~/.ibmcloud-h100-env << 'ENVEOF'

# CIS Domain for OpenShift IPI
export BASE_DOMAIN="ibmc.kni.syseng.devcluster.openshift.com"
ENVEOF
```

#### 4j. Verify CIS Is Ready

```bash
ibmcloud cis instance-set ocp-cis
ibmcloud cis domains
```

Confirm:
- CIS instance: `ocp-cis` (active)
- Domain: `ibmc.kni.syseng.devcluster.openshift.com` (active)

---

### Step 6: Set Release Image Variable

The release image is needed for credential extraction. Set it:

```bash
export RELEASE_IMAGE="quay.io/openshift-release-dev/ocp-release@sha256:682e85bfe8034924e596b281ed8fefe4451e6f6c5bac07b5ec300443eeb23566"
```

Verify it matches your installer:

```bash
openshift-install version
```

**Expected Output:**
```
openshift-install 4.20.14
built from commit ...
release image quay.io/openshift-release-dev/ocp-release@sha256:682e85bfe8034924e596b281ed8fefe4451e6f6c5bac07b5ec300443eeb23566
release architecture amd64
```

The `release image` line should match your `RELEASE_IMAGE` variable exactly.

---

### Step 7: Create Installation Directory

#### 5a. Check for Existing Installation Directory

```bash
ls -ld ~/ocp-h100-ipi-install 2>/dev/null
```

**If directory exists:**

> **WARNING**: An existing installation directory found!
>
> If you proceed, you will **DELETE ALL EXISTING CLUSTER DATA**.
>
> Only do this if:
> - You want to completely redeploy the cluster
> - You've backed up any important data
> - You understand this is destructive
>
> **To delete and recreate:**
> ```bash
> rm -rf ~/ocp-h100-ipi-install
> ```

**If directory doesn't exist**, proceed to 5b.

#### 5b. Create Fresh Installation Directory

```bash
mkdir -p ~/ocp-h100-ipi-install
```

---

### Step 8: Generate install-config.yaml

#### 6a. Read Pull Secret

Load the pull secret into a variable:

```bash
export PULL_SECRET=$(cat $HOME/.pull-secret.json | jq -c .)
```

Verify it's loaded:

```bash
echo $PULL_SECRET | jq -r 'keys'
```

**Expected Output:**
```
[
  "auths"
]
```

#### 6b. Read SSH Public Key

```bash
export SSH_PUBLIC_KEY=$(cat $HOME/.ssh/id_rsa.pub)
```

#### 6c. Get Management Subnet Name

```bash
export MGMT_SUBNET_NAME=$(ibmcloud is subnet $MGMT_SUBNET_ID --output json | jq -r '.name')
echo "Management Subnet Name: $MGMT_SUBNET_NAME"
```

**Expected Output:**
```
Management Subnet Name: ocp-mgmt-subnet
```

#### 6d. Create install-config.yaml

Create the installation configuration file:

```bash
cat > ~/ocp-h100-ipi-install/install-config.yaml << EOF
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
    - ${MGMT_SUBNET_NAME}
    computeSubnets:
    - ${MGMT_SUBNET_NAME}

credentialsMode: Manual

pullSecret: '${PULL_SECRET}'
sshKey: '${SSH_PUBLIC_KEY}'
EOF
```

#### 6e. Verify Configuration

View the generated file:

```bash
cat ~/ocp-h100-ipi-install/install-config.yaml
```

Verify these values:
- `baseDomain:` is `ibmc.kni.syseng.devcluster.openshift.com` (your CIS domain from Step 4)
- `name:` is `ocp-h100-cluster`
- `architecture: amd64` in compute and controlPlane
- `replicas: 0` for workers
- `replicas: 3` for masters (bx2-8x32)
- `region:` is `eu-de`
- `vpcName:` is `rdma-pvc-eude`
- `controlPlaneSubnets:` has `ocp-mgmt-subnet`
- `computeSubnets:` has `ocp-mgmt-subnet`
- `credentialsMode: Manual`
- `pullSecret:` is present (long JSON string)
- `sshKey:` starts with `ssh-rsa`

#### 6f. Create Backup

> **IMPORTANT**: The installer **consumes** install-config.yaml during manifest generation in the next step. Create a backup now.

```bash
cp ~/ocp-h100-ipi-install/install-config.yaml ~/ocp-h100-ipi-install/install-config.yaml.backup
```

Verify backup exists:

```bash
ls -lh ~/ocp-h100-ipi-install/install-config.yaml.backup
```

---

### Step 9: Generate Manifests

> **Why this step?** With `credentialsMode: Manual`, you must generate manifests first, then add cloud credential secrets before deploying.

Run the manifest generation:

```bash
openshift-install create manifests --dir ~/ocp-h100-ipi-install
```

**Expected Output:**
```
INFO Consuming Install Config from target directory
INFO Manifests created in: ~/ocp-h100-ipi-install/manifests and ~/ocp-h100-ipi-install/openshift
```

> **Note**: This **consumes** (deletes) install-config.yaml. That's why we created a backup in Step 6f.

Verify manifests were created:

```bash
ls ~/ocp-h100-ipi-install/manifests/ | head -10
```

```bash
ls ~/ocp-h100-ipi-install/openshift/ | head -10
```

Both directories should contain YAML files.

---

### Step 10: Create Cloud Credential Secrets

> **Why this step?** With `credentialsMode: Manual`, the installer needs pre-created Kubernetes Secret manifests containing IBM Cloud API keys for each cluster component.
>
> **Approach**: We create 5 Secret manifests using your existing API key. This is simpler than using the `ccoctl` utility (which is Linux-only and has compatibility issues on Apple Silicon Macs).

The OpenShift cluster needs credentials for 5 components:

| # | Component | Secret Namespace | Secret Name |
|---|-----------|-----------------|-------------|
| 1 | Cloud Controller Manager | `openshift-cloud-controller-manager` | `ibm-cloud-credentials` |
| 2 | Machine API | `openshift-machine-api` | `ibmcloud-credentials` |
| 3 | Image Registry | `openshift-image-registry` | `installer-cloud-credentials` |
| 4 | Ingress Operator | `openshift-ingress-operator` | `cloud-credentials` |
| 5 | Storage (CSI Driver) | `openshift-cluster-csi-drivers` | `ibm-cloud-credentials` |

#### 8a. Create Secret for Cloud Controller Manager

```bash
cat > ~/ocp-h100-ipi-install/manifests/openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cloud-controller-manager
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
```

#### 8b. Create Secret for Machine API

```bash
cat > ~/ocp-h100-ipi-install/manifests/openshift-machine-api-ibmcloud-credentials-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibmcloud-credentials
  namespace: openshift-machine-api
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
```

#### 8c. Create Secret for Image Registry

```bash
cat > ~/ocp-h100-ipi-install/manifests/openshift-image-registry-installer-cloud-credentials-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: installer-cloud-credentials
  namespace: openshift-image-registry
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
```

#### 8d. Create Secret for Ingress Operator

```bash
cat > ~/ocp-h100-ipi-install/manifests/openshift-ingress-operator-cloud-credentials-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: cloud-credentials
  namespace: openshift-ingress-operator
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
```

#### 8e. Create Secret for Storage (CSI Driver)

```bash
cat > ~/ocp-h100-ipi-install/manifests/openshift-cluster-csi-drivers-ibm-cloud-credentials-credentials.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
  name: ibm-cloud-credentials
  namespace: openshift-cluster-csi-drivers
type: Opaque
stringData:
  ibmcloud_api_key: ${IBMCLOUD_API_KEY}
EOF
```

#### 8f. Verify All 5 Credential Secrets

```bash
ls ~/ocp-h100-ipi-install/manifests/*credentials*
```

**Expected**: 5 files listed.

Verify format of one (redact the API key in output):

```bash
cat ~/ocp-h100-ipi-install/manifests/openshift-cloud-controller-manager-ibm-cloud-credentials-credentials.yaml | sed "s/ibmcloud_api_key: .*/ibmcloud_api_key: <REDACTED>/"
```

Should show a properly formatted Kubernetes Secret YAML.

---

### Step 11: Review Before Deployment

Display a summary of what will be deployed:

```bash
cat << EOF

========================================
OpenShift Installation Configuration
========================================

Cluster Name:        ${CLUSTER_NAME}
Base Domain:         ${BASE_DOMAIN}
Full Cluster Domain: ${CLUSTER_NAME}.${BASE_DOMAIN}
Region:              ${IBMCLOUD_REGION}
Resource Group:      ${IBMCLOUD_RESOURCE_GROUP}

VPC:                 ${VPC_NAME}
Management Subnet:   ocp-mgmt-subnet (10.240.0.0/24, eu-de-2)
CIS Instance:        ocp-cis

Control Plane:       3 masters (bx2-8x32, amd64)
Initial Workers:     0 (H100 will be added in Phase 4)

Installation Dir:    ~/ocp-h100-ipi-install
Credential Manifests: Present (created by ccoctl)

========================================
Technology Preview Notice
========================================

OpenShift IPI on IBM Cloud VPC is a Technology Preview feature:
  - Not supported for production workloads
  - No Red Hat production SLA applies
  - May have functional limitations

========================================
Resources to be Created
========================================

The installer will create:
  - 3 master node VPC instances (bx2-8x32)
  - Bootstrap node (temporary, deleted after cluster ready)
  - VPC load balancer for API/ingress
  - Security groups and network ACLs
  - Public IPs for cluster access
  - DNS records in CIS (ocp-cis)

Estimated Cost: ~\$0.50-1.00 per hour for control plane

========================================

EOF
```

**Review this output carefully.**

---

### Step 12: Deploy OpenShift Cluster

> **CRITICAL CHECKPOINT**
>
> You are about to:
> - Create OpenShift cluster resources in IBM Cloud
> - Create DNS records in your CIS domain
> - Incur hourly costs (~$0.50-1.00/hour for control plane)
> - Wait 45-60 minutes for deployment
> - **This process should NOT be interrupted**

#### 12a. Start DNS Flush Loop (Separate Terminal)

> **CRITICAL**: macOS caches DNS negative responses (NXDOMAIN) for 30 minutes. The installer creates DNS records mid-run, and without flushing, lookups fail with `no such host`.

Open a **second terminal** and run:

```bash
sudo echo "sudo cached" && while true; do sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder && echo "$(date): DNS cache flushed"; sleep 30; done
```

Keep this running throughout the entire installation. Stop with `Ctrl+C` after the installer completes.

#### 12b. Start Installation

In your **original terminal**:

```bash
openshift-install create cluster \
    --dir ~/ocp-h100-ipi-install \
    --log-level=info
```

**What happens now:**

The installer will proceed through these phases:

**Phase 1: Creating infrastructure (5-10 minutes)**
- Creates VPC resources (load balancers, security groups)
- Creates DNS records in CIS
- Provisions bootstrap node
- Provisions 3 master nodes

**Phase 2: Bootstrapping cluster (20-25 minutes)**
- Waits for bootstrap to complete
- Installs OpenShift control plane on masters
- Control plane components start

**Phase 3: Installing cluster operators (15-20 minutes)**
- Deploys cluster operators
- Configures ingress and API
- Sets up internal networking

**Phase 4: Finalizing installation (5-10 minutes)**
- Removes bootstrap node
- Waits for all cluster operators to be Available
- Completes installation

**Total time**: 45-60 minutes

#### 12c. Monitor Installation Progress

Watch for these milestones in the output:

```
INFO Waiting up to 20m0s for the Kubernetes API at https://api.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443...
INFO API v1.x.x up
INFO Waiting up to 30m0s for bootstrapping to complete...
INFO Destroying the bootstrap resources...
INFO Waiting up to 40m0s for the cluster to initialize...
```

**Final success message:**
```
INFO Install complete!
INFO To access the cluster as the system:admin user when using 'oc', run 'export KUBECONFIG=...'
INFO Access the OpenShift web-console here: https://console-openshift-console.apps.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com
INFO Login to the console with user: "kubeadmin", and password: "xxxxx-xxxxx-xxxxx-xxxxx"
```

**If installation fails:**
- Check logs: `tail -100 ~/ocp-h100-ipi-install/.openshift_install.log`
- Check IBM Cloud console for quota issues
- See Troubleshooting section below

> **DO NOT INTERRUPT**: Let the installer run to completion. Interrupting can leave resources in inconsistent state.

---

### Step 13: Configure Cluster Access

#### 13a. Export KUBECONFIG

```bash
export KUBECONFIG=$HOME/ocp-h100-ipi-install/auth/kubeconfig
```

The environment file already has `KUBECONFIG` defined. Verify it points to the right path:

```bash
echo $KUBECONFIG
```

**Expected:**
```
/Users/mrigankapaul/ocp-h100-ipi-install/auth/kubeconfig
```

#### 13b. Test Cluster Connection

```bash
oc version
```

**Expected Output:**
```
Client Version: 4.20.14
Kubernetes Version: v1.x.x
Server Version: 4.20.14
```

```bash
oc cluster-info
```

**Expected Output:**
```
Kubernetes control plane is running at https://api.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443
```

---

### Step 14: Verify Control Plane Installation

#### 14a. Check Nodes

```bash
oc get nodes
```

**Expected Output:**
```
NAME                                         STATUS   ROLES                  AGE   VERSION
ocp-h100-cluster-xxxxx-master-0              Ready    control-plane,master   Xm    v1.x.x
ocp-h100-cluster-xxxxx-master-1              Ready    control-plane,master   Xm    v1.x.x
ocp-h100-cluster-xxxxx-master-2              Ready    control-plane,master   Xm    v1.x.x
```

Verify:
- All 3 master nodes present
- All show `STATUS: Ready`
- All have `control-plane,master` roles

Count the nodes:

```bash
oc get nodes --no-headers | wc -l
```

Should output: `3`

#### 14b. Check Cluster Operators

```bash
oc get co
```

All operators should show:
- `AVAILABLE: True`
- `PROGRESSING: False`
- `DEGRADED: False`

> **Note**: Some operators may show `PROGRESSING: True` immediately after installation. Wait 5-10 minutes and check again.

Check for any unhealthy operators:

```bash
oc get co | grep -v "True.*False.*False" | grep -v "^NAME"
```

If this returns no output, all operators are healthy.

#### 14c. Get Cluster Version

```bash
oc get clusterversion
```

**Expected Output:**
```
NAME      VERSION   AVAILABLE   PROGRESSING   SINCE   STATUS
version   4.20.14   True        False         Xm      Cluster version is 4.20.14
```

Get detailed version:

```bash
export CLUSTER_VERSION=$(oc version -o json | jq -r '.openshiftVersion')
echo "OpenShift Version: $CLUSTER_VERSION"
```

---

### Step 15: Get Cluster Access Information

#### 15a. Get API URL

```bash
export API_URL=$(oc whoami --show-server)
echo "API URL: $API_URL"
```

#### 15b. Get Console URL

```bash
export CONSOLE_URL=$(oc whoami --show-console)
echo "Console URL: $CONSOLE_URL"
```

Try opening the console:

```bash
open $CONSOLE_URL
```

#### 15c. Get Admin Credentials

```bash
export KUBEADMIN_PASSWORD=$(cat ~/ocp-h100-ipi-install/auth/kubeadmin-password)
echo "kubeadmin password: $KUBEADMIN_PASSWORD"
```

> **SAVE THIS PASSWORD SECURELY!**

---

### Step 16: Save Cluster Information

Create a summary file with all cluster details:

```bash
cat > ~/ocp-h100-ipi-install/cluster-info.txt << EOF
OpenShift Cluster Information
Generated: $(date)
=====================================

Cluster Name:        ${CLUSTER_NAME}
Base Domain:         ibmc.kni.syseng.devcluster.openshift.com
OpenShift Version:   ${CLUSTER_VERSION}
Region:              ${IBMCLOUD_REGION}
Installation Dir:    ~/ocp-h100-ipi-install

API URL:             ${API_URL}
Console URL:         ${CONSOLE_URL}

Credentials:
  Username:          kubeadmin
  Password:          ${KUBEADMIN_PASSWORD}

Kubeconfig:          ~/ocp-h100-ipi-install/auth/kubeconfig

Control Plane Nodes: 3 masters (bx2-8x32)
Worker Nodes:        0 (H100 to be added in Phase 4)

CIS Instance:        ocp-cis
CIS Domain:          ${BASE_DOMAIN}

=====================================

Quick Commands:
  Access cluster:    export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig
  View nodes:        oc get nodes
  View operators:    oc get co
  Web console:       open ${CONSOLE_URL}

=====================================
EOF
```

View the saved info:

```bash
cat ~/ocp-h100-ipi-install/cluster-info.txt
```

---

### Step 17: Test Cluster Functionality (Optional)

#### 17a. Create a Test Project

```bash
oc new-project test-deployment
```

#### 17b. List Projects

```bash
oc get projects | head -10
```

Should show `test-deployment` and many `openshift-*` projects.

#### 17c. Check Cluster Pods

```bash
oc get pods -n openshift-apiserver
```

All pods should show `STATUS: Running`.

#### 17d. Clean Up Test Project

```bash
oc delete project test-deployment
```

---

## Checkpoint Summary

At the end of Phase 2, you should have:

- [x] **install-config.yaml** created and backed up
- [x] **Manifests** generated by openshift-install
- [x] **Cloud credentials** created by ccoctl (service IDs + secrets)
- [x] **OpenShift cluster** deployed successfully
- [x] **3 master nodes** in Ready state
- [x] **All cluster operators** Available and not Degraded
- [x] **Kubeconfig** file at `~/ocp-h100-ipi-install/auth/kubeconfig`
- [x] **Admin credentials** saved (kubeadmin / password)
- [x] **oc commands** working from your workstation
- [x] **Web console** accessible via CIS domain
- [x] **cluster-info.txt** created with all access details

### Verify Checklist

```bash
# Should show 3 nodes, all Ready
oc get nodes

# Should show all operators Available=True, Degraded=False
oc get co

# Should show cluster version 4.20.14
oc get clusterversion

# Should show your identity
oc whoami
```

If all of these work, Phase 2 is complete!

---

## Troubleshooting

### Issue: ccoctl Fails with "service ID already exists"

**Cause**: You ran ccoctl before. Existing service IDs conflict.

**Solution**: Delete existing service IDs from IBM Cloud console (IAM → Service IDs), then re-run Step 9c.

### Issue: ccoctl Fails with "Podman" Errors

**Check Podman machine is running:**
```bash
podman machine list
```

If not running:
```bash
podman machine start
```

**Check Podman can pull images:**
```bash
podman pull --authfile $HOME/.pull-secret.json $CCO_IMAGE
```

### Issue: Installation Fails with "DNS record creation failed"

**Cause**: CIS domain not active or installer can't find CIS instance.

**Check CIS domain status:**
```bash
ibmcloud cis instance-set "ocp-cis"
ibmcloud cis domains
```

Domain must show `active` status.

### Issue: Installation Hangs at "Waiting for bootstrap to complete"

**Possible causes:**
- Network connectivity issues
- Bootstrap node failed to start
- VPC quota limits reached

**Diagnosis:**
```bash
ibmcloud is instances | grep bootstrap
tail -f ~/ocp-h100-ipi-install/.openshift_install.log
```

### Issue: "VPC quota exceeded"

**Solution:**
- Check VPC quotas in IBM Cloud console
- Increase quotas or clean up unused resources
- Common limits: instances, floating IPs, load balancers

### Issue: Installation Fails During Operator Deployment

**Check which operator is failing:**
```bash
oc get co | grep -v "True.*False.*False" | grep -v "^NAME"
```

**View operator details:**
```bash
oc describe co <operator-name>
```

### Issue: Cannot Connect to Cluster After Installation

**Verify kubeconfig:**
```bash
ls -lh ~/ocp-h100-ipi-install/auth/kubeconfig
echo $KUBECONFIG
```

**Re-export if needed:**
```bash
export KUBECONFIG=$HOME/ocp-h100-ipi-install/auth/kubeconfig
```

### Issue: Web Console Not Accessible

**Check DNS resolution:**
```bash
nslookup console-openshift-console.apps.$CLUSTER_NAME.$BASE_DOMAIN
```

**Check console pods:**
```bash
oc get pods -n openshift-console
```

### Issue: Cluster Operators PROGRESSING=True

Normal immediately after installation. Wait 10-15 minutes:

```bash
watch oc get co
```

If still progressing after 30 minutes:

```bash
oc describe co <operator-name>
```

---

## Clean Up (If Deployment Fails)

If the deployment fails and you want to start over:

**1. Destroy cluster resources (if partially created):**

```bash
openshift-install destroy cluster --dir ~/ocp-h100-ipi-install
```

**2. Delete ccoctl service IDs** (from IBM Cloud console → IAM → Service IDs)

**Note**: Do NOT delete the CIS instance (`ocp-cis`) during cleanup — you can reuse it for the next attempt. Only delete CIS if you're done with the deployment entirely.

**3. Remove installation directory:**

```bash
rm -rf ~/ocp-h100-ipi-install
```

**4. Clean temporary files:**

```bash
rm -rf ~/ocp-ccoctl
```

**5. Start over from Step 5.**

---

## Important Notes

### Cluster Costs

The control plane is now running and incurring costs:
- ~$0.50-1.00 per hour
- Runs 24/7 unless you destroy the cluster

### DNS Records

The installer created DNS records in CIS (`ocp-cis`) for:
- `api.<cluster-name>.<base-domain>`
- `*.apps.<cluster-name>.<base-domain>`

These are automatically managed by OpenShift.

### Backup Important Files

Make backups of:
- `~/ocp-h100-ipi-install/auth/kubeconfig`
- `~/ocp-h100-ipi-install/auth/kubeadmin-password`
- `~/ocp-h100-ipi-install/install-config.yaml.backup`
- `~/ocp-h100-ipi-install/cluster-info.txt`

### Cluster Access From Other Machines

Copy `kubeconfig` to any machine and set:
```bash
export KUBECONFIG=/path/to/kubeconfig
```
Ensure network access to `api.ocp-h100-cluster.ibmc.kni.syseng.devcluster.openshift.com:6443`.

### Technology Preview Limitations

- Not a production-supported configuration
- Red Hat support may be limited
- IBM Cloud IPI is Technology Preview
- Best used for development and testing

---

## Next Steps

You're ready for **[Phase 3: Provision H100 GPU Instance](PHASE3-H100-PROVISIONING.md)**

This phase will:
- Create an H100 GPU instance with 8× H100 GPUs
- Attach 8 cluster network interfaces for RDMA
- Prepare the instance for joining the OpenShift cluster
- Takes approximately 20-30 minutes

**Before proceeding**, ensure:
- All 3 master nodes are Ready
- All cluster operators are Available
- You have cluster credentials saved
- Web console is accessible

---

**Phase 2 Complete! ✅**

**Cluster deployed and operational. Control plane costs now accruing (~$0.50-1.00/hour).**
