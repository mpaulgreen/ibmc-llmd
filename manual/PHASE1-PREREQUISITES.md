# Phase 1: Prerequisites Setup

## Overview

This phase installs all required tools and configures your local environment for deploying OpenShift with H100 GPU workers on IBM Cloud VPC.

**What You'll Accomplish:**
- Install IBM Cloud CLI with VPC plugin
- Install jq, Helm, OpenShift installer, and oc CLI
- Configure Red Hat pull secret
- Set up SSH keys
- Create environment configuration file
- Verify IBM Cloud access

**Estimated Time**: 30 minutes

## Pre-Flight Checks

Before starting, ensure you have:

- [ ] macOS Apple Silicon system (arm64 / M1, M2, M3, M4)
- [ ] Internet connectivity
- [ ] sudo access on your machine
- [ ] IBM Cloud API key (you'll use this during setup)
- [ ] Downloaded pull secret from Red Hat

## Required Downloads

### 1. OpenShift Installer and CLI

The `openshift-install` and `oc` binaries will be downloaded directly from the Red Hat mirror via `curl` in Steps 7-8 below. No manual download is needed.

**Mirror URL**: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.19/

Alternatively, you can browse and download manually from:
https://console.redhat.com/openshift/install (IBM Cloud → IPI → macOS arm64)

### 2. Download Red Hat Pull Secret

1. Visit: https://console.redhat.com/openshift/install/pull-secret
2. Log in with your Red Hat account
3. Click: **Download pull secret**
4. File will be named: `pull-secret.txt` or similar
5. Save to: `~/Downloads/`

### 3. Get IBM Cloud API Key

If you don't have an API key:

1. Log in to IBM Cloud: https://cloud.ibm.com
2. Navigate to: **Manage** → **Access (IAM)** → **API keys**
3. Click: **Create an IBM Cloud API key**
4. Name it (e.g., "openshift-h100-deployment")
5. Copy the API key (you won't be able to see it again)
6. Save it securely - you'll need it in Step 12

---

## Step-by-Step Instructions

### Step 1: Verify macOS

Check you're running on macOS:

```bash
uname -s
```

**Expected Output:**
```
Darwin
```

If you see "Linux" or something else, these instructions are for macOS only.

---

### Step 2: Install Homebrew (if needed)

Check if Homebrew is installed:

```bash
brew --version
```

If you see a version number, Homebrew is installed. **Skip to Step 3.**

If you get "command not found", install Homebrew:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

This will:
- Download and install Homebrew
- May prompt for your password
- May take 5-10 minutes

After installation, verify:

```bash
brew --version
```

---

### Step 3: Verify IBM Cloud CLI

Check if IBM Cloud CLI is installed:

```bash
ibmcloud version
```

**Expected Output:**
```
ibmcloud version 2.x.x+...
```

If you get "command not found":

**ERROR**: IBM Cloud CLI is required but not installed.

Install from: https://cloud.ibm.com/docs/cli?topic=cli-install-ibmcloud-cli

Download the macOS installer and run it, then return to this guide.

---

### Step 4: Install/Verify VPC Infrastructure Plugin

Check if the VPC plugin is installed:

```bash
ibmcloud plugin list | grep vpc-infrastructure
```

If you see output with "vpc-infrastructure", it's installed. **Skip to Step 5.**

If you don't see it, install the plugin:

```bash
ibmcloud plugin install vpc-infrastructure -f
```

**Expected Output:**
```
Looking up 'vpc-infrastructure' from repository 'IBM Cloud'...
...
Plug-in 'vpc-infrastructure x.x.x' was successfully installed.
```

Verify installation:

```bash
ibmcloud plugin list | grep vpc-infrastructure
```

---

### Step 5: Install/Verify CIS Plugin

Check if the CIS plugin is installed:

```bash
ibmcloud plugin list | grep cis
```

If you see output with "cis", it's installed. **Skip to Step 6.**

If you don't see it, install the plugin:

```bash
ibmcloud plugin install cis -f
```

Verify installation:

```bash
ibmcloud plugin list | grep cis
```

---

### Step 6: Install jq (JSON Processor)

Check if jq is installed:

```bash
jq --version
```

If you see a version number (e.g., `jq-1.6` or `jq-1.7`), jq is installed. **Skip to Step 7.**

If not installed, install via Homebrew:

```bash
brew install jq
```

**Expected Output:**
```
==> Downloading https://ghcr.io/v2/homebrew/core/jq/...
==> Pouring jq--...
...
🍺  /usr/local/Cellar/jq/...: X files, XXM
```

Verify installation:

```bash
jq --version
```

---

### Step 7: Install Helm 3

Check if Helm is installed:

```bash
helm version --short
```

If you see a version starting with `v3.x.x`, Helm 3 is installed. **Skip to Step 8.**

If not installed or you have Helm 2, install/upgrade:

```bash
brew install helm
```

**Expected Output:**
```
==> Downloading https://ghcr.io/v2/homebrew/core/helm/...
==> Pouring helm--...
...
🍺  /usr/local/Cellar/helm/...: X files, XXM
```

Verify Helm 3 is installed:

```bash
helm version --short
```

Should show: `v3.x.x`

---

### Step 8: Install OpenShift Installer

#### 8a. Check for Existing Installation

Check if openshift-install is already installed:

```bash
openshift-install version
```

If you see version 4.19 or later, you can **skip to Step 9**.

If you see an older version, or "command not found", continue below to install.

#### 8b. Verify Architecture

Confirm you're on Apple Silicon:

```bash
uname -m
```

**Expected Output:**
```
arm64
```

If you see `x86_64` instead, you're on Intel Mac — replace `arm64` with `amd64` in the URLs below, or use the filenames without `arm64` (e.g., `openshift-install-mac.tar.gz`).

#### 8c. Download openshift-install for Mac Apple Silicon

Download directly from the Red Hat mirror (~373 MB):

```bash
curl -L -o /tmp/openshift-install-mac-arm64.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.19/openshift-install-mac-arm64.tar.gz"
```

**What this does:**
- `-L` follows redirects
- Downloads `openshift-install` v4.19.x built for Mac arm64 (Apple Silicon)
- Saves to `/tmp/` so it doesn't clutter your system

This will take 1-3 minutes depending on your connection.

Verify the download completed:

```bash
ls -lh /tmp/openshift-install-mac-arm64.tar.gz
```

Should show ~373 MB file.

#### 8d. Extract Installer

```bash
tar -xzf /tmp/openshift-install-mac-arm64.tar.gz -C /tmp/
```

Verify the binary was extracted:

```bash
ls -lh /tmp/openshift-install
```

Should show the binary file.

#### 8e. Install to System Path

Install the binary (requires sudo):

```bash
sudo mv /tmp/openshift-install /usr/local/bin/openshift-install
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/openshift-install
```

#### 8f. Clean Up

Remove the downloaded tarball:

```bash
rm -f /tmp/openshift-install-mac-arm64.tar.gz
```

#### 8g. Verify Installation

```bash
openshift-install version
```

**Expected Output:**
```
openshift-install 4.19.x
built from commit ...
release image quay.io/openshift-release-dev/ocp-release@sha256:...
release architecture arm64
```

Verify:
- Version is **4.19.x** or later
- Architecture shows **arm64**

---

### Step 9: Install OpenShift CLI (oc)

#### 9a. Check for Existing Installation

```bash
oc version --client
```

**Decision:**
- If version is **4.19 or later** and architecture is **arm64** → **Skip to Step 10**
- If version is **older than 4.20** (e.g., 4.13, 4.17) → Continue below to **upgrade**
- If "command not found" → Continue below to **install**

> **Why version matters:** The `oc` client should match (or be close to) the cluster version.
> Your cluster will be 4.19+, so `oc` must also be 4.19+.

#### 9b. Check Current oc Binary Location (if upgrading)

If you're upgrading an existing `oc`, find where the current one lives:

```bash
which oc
```

**Expected**: `/usr/local/bin/oc` — this is where we'll install the new version.

#### 9c. Download oc Client for Mac Apple Silicon

Download from the Red Hat mirror (~58 MB):

```bash
curl -L -o /tmp/openshift-client-mac-arm64.tar.gz \
  "https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.19/openshift-client-mac-arm64.tar.gz"
```

**What this does:**
- Downloads `oc` v4.19.x built for Mac arm64 (Apple Silicon)
- Same version stream as the installer from Step 8
- Saves to `/tmp/`

Verify the download completed:

```bash
ls -lh /tmp/openshift-client-mac-arm64.tar.gz
```

Should show ~58 MB file.

#### 9d. Extract

```bash
tar -xzf /tmp/openshift-client-mac-arm64.tar.gz -C /tmp/
```

Verify the binary was extracted:

```bash
ls -lh /tmp/oc
```

Should show the `oc` binary.

#### 9e. Install to System Path

Install the binary (requires sudo — will overwrite any existing `oc`):

```bash
sudo mv /tmp/oc /usr/local/bin/oc
```

Make it executable:

```bash
sudo chmod +x /usr/local/bin/oc
```

#### 9f. Clean Up

Remove the downloaded tarball and any extra extracted files:

```bash
rm -f /tmp/openshift-client-mac-arm64.tar.gz
rm -f /tmp/kubectl  # also extracted from the tarball
rm -f /tmp/README.md  # also extracted from the tarball
```

#### 9g. Verify Installation

```bash
oc version --client
```

**Expected Output:**
```
Client Version: 4.19.x
Kustomize Version: v5.x.x
```

Verify:
- Version is **4.19.x** or later
- Matches (or is close to) the `openshift-install` version from Step 8

Also verify kubectl works:

```bash
kubectl version --client
```

> **Note:** If you had a separate `kubectl` installed (e.g., via Homebrew), it remains
> independent. The `oc` binary includes kubectl functionality, so you can use either.
> They do not need to be the same version.

---

### Step 10: Configure Red Hat Pull Secret

#### 10a. Check for Existing Pull Secret

```bash
ls -lh ~/.pull-secret.json
```

If file exists and is valid JSON, you can **skip to Step 11**.

#### 10b. Verify Downloaded Pull Secret

Check if you downloaded the pull secret:

```bash
ls -lh ~/Downloads/pull-secret*
```

If not found, **go back to "Required Downloads"** and download it.

#### 10c. Copy to Home Directory

Copy the pull secret to standard location:

```bash
cp ~/Downloads/pull-secret*.txt ~/.pull-secret.json
```

Note: The file might be .txt or .json - the command above handles .txt files.

If your download is already .json:

```bash
cp ~/Downloads/pull-secret.json ~/.pull-secret.json
```

#### 10d. Set Proper Permissions

Protect the pull secret file:

```bash
chmod 600 ~/.pull-secret.json
```

#### 10e. Verify Pull Secret is Valid JSON

```bash
jq empty ~/.pull-secret.json
```

**Expected Output:**
No output means success. The pull secret is valid JSON.

If you get an error, the file is corrupted. Re-download it.

View the pull secret structure (don't share this output):

```bash
jq keys ~/.pull-secret.json
```

Should show: `["auths"]`

---

### Step 11: Configure SSH Keys

#### 11a. Check for Existing SSH Key

```bash
ls -lh ~/.ssh/id_rsa.pub
```

If file exists, you have an SSH key. **Skip to Step 12.**

#### 11b. Generate New SSH Key Pair

Generate a new 4096-bit RSA key:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N ""
```

**What this does:**
- `-t rsa`: Use RSA algorithm
- `-b 4096`: 4096-bit key (strong security)
- `-f ~/.ssh/id_rsa`: Save to default location
- `-N ""`: No passphrase (empty string)

**Expected Output:**
```
Generating public/private rsa key pair.
Your identification has been saved in /Users/yourname/.ssh/id_rsa
Your public key has been saved in /Users/yourname/.ssh/id_rsa.pub
The key fingerprint is:
SHA256:... yourname@yourmac
```

#### 11c. View Key Fingerprint

```bash
ssh-keygen -lf ~/.ssh/id_rsa.pub
```

**Expected Output:**
```
4096 SHA256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx yourname@yourmac (RSA)
```

Save this fingerprint for reference.

---

### Step 12: Create Environment Configuration File

#### 12a. Check for Existing Environment File

```bash
ls -lh ~/.ibmcloud-h100-env
```

If file exists, you can edit it instead of creating new one.

**Skip to 12c if you want to keep your existing file.**

#### 12b. Create New Environment File

Create the environment configuration file with all pre-configured values:

```bash
cat > ~/.ibmcloud-h100-env << 'EOF'
#!/bin/bash
################################################################################
# IBM Cloud H100 OpenShift Deployment Environment
# Created: 2026-02-28
################################################################################

# IBM Cloud Configuration
export IBMCLOUD_API_KEY="YOUR_API_KEY_HERE"  # ⚠️ REPLACE THIS IN NEXT STEP
export IBMCLOUD_REGION="eu-de"
export IBMCLOUD_ZONE="eu-de-2"
export IBMCLOUD_RESOURCE_GROUP="Default"

# Constants
export GPU_PROFILE="gx3d-160x1792x8h100"
export CLUSTER_NAME="ocp-h100-cluster"
export CN_NAME="rdma-cluster"
export BASE_DOMAIN="ibmc.kni.syseng.devcluster.openshift.com"

# Pre-existing (CIS, COS, SSH key — not created by guides)
export KEY_ID="r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8"

# Set in Phase 2 (VPC creation — Step 0)
export VPC_ID=""
export VPC_NAME="rdma-pvc-eude"
export MGMT_SUBNET_ID=""

# Set in Phase 2 (OCP deployment — Step 6)
export OCP_SG_ID=""

# Set in Phase 3 (cluster network creation)
export CN_ID=""
export CN_SUBNET_ID_0=""
export CN_SUBNET_ID_1=""
export CN_SUBNET_ID_2=""
export CN_SUBNET_ID_3=""
export CN_SUBNET_ID_4=""
export CN_SUBNET_ID_5=""
export CN_SUBNET_ID_6=""
export CN_SUBNET_ID_7=""

# Set in Phase 3 (H100 instance)
export H100_INSTANCE_ID=""

# Set in Phase 4 (worker integration)
export H100_NODE_NAME=""

# Derived Paths
export INSTALL_DIR="$HOME/ocp-h100-upi-install"
export KUBECONFIG="$INSTALL_DIR/auth/kubeconfig"
export PULL_SECRET_PATH="$HOME/.pull-secret.json"
export SSH_KEY_PATH="$HOME/.ssh/id_rsa.pub"

# OpenShift installer requires IC_API_KEY (not IBMCLOUD_API_KEY)
export IC_API_KEY="$IBMCLOUD_API_KEY"

################################################################################
# Helper Functions
################################################################################

verify_environment() {
    if [[ -z "$IBMCLOUD_API_KEY" || "$IBMCLOUD_API_KEY" == "YOUR_API_KEY_HERE" ]]; then
        echo "ERROR: IBMCLOUD_API_KEY not set"
        echo "Please edit ~/.ibmcloud-h100-env and set your API key"
        return 1
    fi
    echo "Environment loaded successfully"
    return 0
}

ibmcloud_login() {
    echo "Logging into IBM Cloud..."
    ibmcloud login --apikey "$IBMCLOUD_API_KEY" \
        -r "$IBMCLOUD_REGION" \
        -g "$IBMCLOUD_RESOURCE_GROUP"
}

verify_cluster_access() {
    if [[ ! -f "$KUBECONFIG" ]]; then
        echo "ERROR: KUBECONFIG not found at $KUBECONFIG"
        return 1
    fi
    oc version --client
    oc cluster-info
}

echo "IBM Cloud H100 Environment loaded"
echo "Run 'verify_environment' to check configuration"
echo "Run 'ibmcloud_login' to authenticate to IBM Cloud"
EOF
```

#### 12c. Set File Permissions

Make the environment file secure:

```bash
chmod 600 ~/.ibmcloud-h100-env
```

#### 12d. Edit Environment File to Add API Key

Open the environment file in your editor:

```bash
vim ~/.ibmcloud-h100-env
```

Or use nano if you prefer:

```bash
nano ~/.ibmcloud-h100-env
```

Find this line:
```bash
export IBMCLOUD_API_KEY="YOUR_API_KEY_HERE"  # ⚠️ REPLACE THIS IN NEXT STEP
```

Replace `YOUR_API_KEY_HERE` with your actual IBM Cloud API key.

Save and exit the editor.

**In vim**: Press `i` for insert mode, edit the line, press `Esc`, type `:wq`, press `Enter`

**In nano**: Edit the line, press `Ctrl+X`, press `Y`, press `Enter`

#### 12e. Load Environment

Source the environment file:

```bash
source ~/.ibmcloud-h100-env
```

**Expected Output:**
```
IBM Cloud H100 Environment loaded
Run 'verify_environment' to check configuration
Run 'ibmcloud_login' to authenticate to IBM Cloud
```

#### 12f. Verify Environment Configuration

Run the verification function:

```bash
verify_environment
```

**Expected Output:**
```
Environment loaded successfully
```

If you get an error about API key, edit the file again and ensure you replaced the placeholder.

---

### Step 13: Test IBM Cloud Authentication

#### 13a. Login to IBM Cloud

Use the helper function to login:

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

#### 13b. Verify Target Settings

Check you're in the right region and resource group:

```bash
ibmcloud target
```

**Expected Output:**
```
API endpoint:      https://cloud.ibm.com
Region:            eu-de
Resource group:    Default
...
```

Verify:
- Region is: `eu-de`
- Resource group is: `Default` (or your actual resource group)

---

### Step 14: Verify IBM Cloud VPC Access

#### 14a. Test VPC API Access

Verify you can list VPC resources (the VPC itself will be created in Phase 2):

```bash
ibmcloud is vpcs --output json | jq length
```

**Expected Output:** A number (0 or more). If you get an error, your API key lacks VPC permissions.

#### 14b. Verify SSH Key Exists

```bash
ibmcloud is key $KEY_ID --output json | jq -r '.name, .id'
```

**Expected Output:**
```
my-h100-key-eude
r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8
```

#### 14c. Verify CIS Instance

```bash
ibmcloud cis instance-set ocp-cis && ibmcloud cis domains --output json | jq -r '.[0].name'
```

**Expected Output:**
```
ibmc.kni.syseng.devcluster.openshift.com
```

#### 14d. Verify COS Instance

```bash
ibmcloud resource service-instance ocp-cos --output json | jq -r '.[0].name'
```

**Expected Output:**
```
ocp-cos
```

---

### Step 15: Install AWS CLI (for COS Presigned URLs)

Phase 2 uses `aws s3 presign` to generate presigned URLs for COS. Check if AWS CLI is installed:

```bash
aws --version
```

If you see a version (e.g., `aws-cli/2.x.x`), it's installed. **Skip to Step 16.**

If not installed:

```bash
brew install awscli
```

Verify:

```bash
aws --version
```

> **Note**: AWS CLI is only used for the `s3 presign` command against IBM Cloud COS (which is S3-compatible). No AWS account or credentials are needed — temporary HMAC keys are created in Phase 2.

---

### Step 16: Final Verification Summary

Run a complete verification of all tools:

```bash
echo "===== Tool Versions ====="
echo "IBM Cloud CLI: $(ibmcloud version | head -1)"
echo "VPC Plugin: $(ibmcloud plugin list | grep vpc-infrastructure | awk '{print $2}')"
echo "jq: $(jq --version)"
echo "Helm: $(helm version --short)"
echo "openshift-install: $(openshift-install version | head -1)"
echo "oc: $(oc version --client 2>&1 | head -1)"
echo "aws: $(aws --version 2>&1 | head -1)"
echo ""
echo "===== Configuration Files ====="
echo "Pull Secret: $(ls -lh ~/.pull-secret.json | awk '{print $5, $9}')"
echo "SSH Public Key: $(ls -lh ~/.ssh/id_rsa.pub | awk '{print $5, $9}')"
echo "Environment: $(ls -lh ~/.ibmcloud-h100-env | awk '{print $5, $9}')"
echo ""
echo "===== IBM Cloud Access ====="
echo "Region: $IBMCLOUD_REGION"
echo "Resource Group: $IBMCLOUD_RESOURCE_GROUP"
echo "SSH Key: $KEY_ID"
```

**Expected Output:**
Should show all tools installed with versions, all files present, and IBM Cloud access configured.

---

## Checkpoint Summary

At the end of Phase 1, you should have:

- [x] **Homebrew** installed and working
- [x] **IBM Cloud CLI** installed with VPC and CIS plugins
- [x] **jq** installed for JSON processing
- [x] **Helm 3** installed for Kubernetes package management
- [x] **openshift-install** version 4.19+ installed
- [x] **oc** CLI installed and working
- [x] **kubectl** symlinked to oc
- [x] **AWS CLI** installed (for COS presigned URLs)
- [x] **Red Hat pull secret** saved to `~/.pull-secret.json`
- [x] **SSH key pair** exists at `~/.ssh/id_rsa` and `~/.ssh/id_rsa.pub`
- [x] **Environment file** created at `~/.ibmcloud-h100-env` with API key set
- [x] **IBM Cloud login** successful
- [x] **VPC API access** verified (can list VPCs)
- [x] **SSH key** verified in IBM Cloud
- [x] **CIS and COS** instances verified

## Troubleshooting

### Issue: Homebrew Installation Fails

**Solution**: Ensure you have Xcode Command Line Tools:
```bash
xcode-select --install
```

### Issue: IBM Cloud CLI Plugin Installation Fails

**Solution**: Update IBM Cloud CLI first:
```bash
ibmcloud update
ibmcloud plugin update --all
```

### Issue: Pull Secret is Invalid JSON

**Solution**: Re-download from Red Hat. Ensure you copied the entire file content.

### Issue: VPC Access Returns Empty or Error

**Possible causes:**
- API key doesn't have VPC permissions
- Wrong resource group
- Resources are in different region

**Check permissions:**
```bash
ibmcloud iam api-key-get <your-api-key-name>
```

### Issue: Environment File Keeps Getting Reset

**Solution**: Don't run the creation command (12b) again. Just edit the file:
```bash
vim ~/.ibmcloud-h100-env
```

## Important Notes

### Security

- **API Key**: Keep `~/.ibmcloud-h100-env` secure. Do not commit to git.
- **Pull Secret**: Keep `~/.pull-secret.json` secure. Do not share.
- **SSH Keys**: Public key will be added to instances. Private key stays on your machine.

### Environment Persistence

After closing your terminal, you'll need to reload the environment:

```bash
source ~/.ibmcloud-h100-env
```

**Tip**: Add to your `~/.zshrc` or `~/.bashrc` to load automatically:
```bash
echo "source ~/.ibmcloud-h100-env" >> ~/.zshrc
```

### Helper Functions

The environment file includes helper functions:

- `verify_environment` - Check configuration is valid
- `ibmcloud_login` - Login to IBM Cloud with saved credentials
- `verify_cluster_access` - Test access to deployed cluster (use after Phase 2)

---

## Next Steps

You're ready for **[Phase 2: Deploy OpenShift Control Plane (UPI)](PHASE2-UPI-CONTROL-PLANE.md)**

This phase will:
- Create VPC, subnet, and public gateway
- Generate OpenShift install configuration
- Deploy 3-node control plane using UPI
- Configure cluster access
- Takes approximately 90-120 minutes

**Before proceeding**, ensure:
- All tools show correct versions
- IBM Cloud login is successful
- VPC API access works
- Pull secret, SSH key, CIS, and COS are configured

---

**Phase 1 Complete! ✅**
