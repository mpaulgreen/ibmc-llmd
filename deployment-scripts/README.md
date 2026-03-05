# OpenShift 4.20+ IPI Deployment with H100 GPU Worker on IBM Cloud VPC

## 🎯 Overview

This deployment creates an **OpenShift 4.20+ cluster** on IBM Cloud VPC with:
- **3 master nodes** (high availability control plane)
- **1 H100 GPU worker node** with 8× NVIDIA H100 GPUs (80GB each)
- **IBM Cloud cluster network** integration using **hopper-1 profile** for RDMA connectivity
- **Region**: eu-de (Frankfurt), **Zone**: eu-de-2
- **Total bandwidth**: 3.2 Tbps aggregate network bandwidth per H100 node

## ⚠️ CRITICAL: Technology Preview Status

**OpenShift IPI on IBM Cloud VPC is currently a Technology Preview feature:**
- ❌ Not supported with Red Hat production service-level agreements (SLAs)
- ⚠️ May not be functionally complete
- 🧪 Not intended for production use
- 📝 User acknowledgment required before proceeding

## 🏗️ Architecture

```
┌────────────────────────────────────────────────────────────┐
│        OpenShift 4.20+ IPI Cluster (Tech Preview)          │
├────────────────────────────────────────────────────────────┤
│                                                            │
│  Control Plane (3 Masters - IPI Managed)                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ Master-0 │  │ Master-1 │  │ Master-2 │               │
│  │bx2-8x32  │  │bx2-8x32  │  │bx2-8x32  │               │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘               │
│       └──────VPC Network───────────┘                      │
│                                                            │
│  Compute Workers                                          │
│  ┌──────────────────────────────────────────────────┐    │
│  │  H100 Worker (gx3d-160x1792x8h100)               │    │
│  │                                                   │    │
│  │  VPC Management Network                          │    │
│  │  • Kubernetes API/kubelet communication          │    │
│  │                                                   │    │
│  │  Cluster Network (8× RDMA Interfaces)            │    │
│  │  • 8× ConnectX-7 NICs (400 Gbps each)           │    │
│  │  • Total: 3.2 Tbps bandwidth                     │    │
│  │  • RoCE v2 with GPU Direct RDMA                  │    │
│  │                                                   │    │
│  │  GPU Resources                                    │    │
│  │  • 8× NVIDIA H100 SXM5 (80GB HBM3 each)         │    │
│  │  • 640GB total GPU memory                        │    │
│  └──────────────────────────────────────────────────┘    │
│                                                            │
│  Kubernetes Operators                                     │
│  • Node Feature Discovery (NFD)                           │
│  • NMState Operator                                       │
│  • SR-IOV Network Operator                                │
│  • NVIDIA Network Operator                                │
│  • NVIDIA GPU Operator                                    │
└────────────────────────────────────────────────────────────┘
```

## 📋 Prerequisites

### Required IBM Cloud Resources (Already Provisioned)

You must have these resources already created in IBM Cloud:

- ✅ **VPC**: rdma-pvc-eude (r010-39a1b8f9-0c94-4fea-9842-54635fb079e9)
- ✅ **Cluster Network**: rdma-cluster with hopper-1 profile (02c7-20a6fc6c-33f1-461a-b69b-f36f83255022)
- ✅ **8× Cluster Network Subnets** (for 8 GPU rails)
- ✅ **Management Subnet**: 02c7-67b188b3-1981-4454-bc7b-1417f8cdee5d
- ✅ **Security Group**: r010-25a67700-a8a2-48d4-a837-573734fca8e4
- ✅ **SSH Key**: r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8

### Required Software

1. **macOS** (darwin) environment
2. **IBM Cloud CLI** with VPC plugin (already installed)
3. **OpenShift CLI** (oc) - will be installed during setup
4. **jq** - JSON processor
5. **Helm 3** - Kubernetes package manager

### Required Credentials

1. **IBM Cloud API Key** with VPC permissions
2. **Red Hat Pull Secret** (download from console.redhat.com)
3. **OpenShift Installer** 4.20+ for macOS (download from console.redhat.com)
4. **SSH Key Pair** (already exists at ~/.ssh/id_rsa.pub)

## 🚀 Quick Start

### Step 1: Download Required Files from Red Hat

#### Download OpenShift Installer
1. Visit: https://console.redhat.com/openshift/install
2. Select: **IBM Cloud** → **Installer-Provisioned Infrastructure**
3. Download: **OpenShift Installer for macOS** (version 4.20+)
4. Save to: `~/Downloads/openshift-install-mac-4.20.x.tar.gz`

#### Download Pull Secret
1. Visit: https://console.redhat.com/openshift/install/pull-secret
2. Click: **Download pull secret**
3. Save to: `~/Downloads/pull-secret.txt`

### Step 2: Run Prerequisites Setup

```bash
cd deployment-scripts
./phase1-prerequisites/01-setup-prerequisites.sh
```

This will:
- Install OpenShift installer to `/usr/local/bin/`
- Install `oc` CLI
- Install `jq` and `helm`
- Verify all tools are working
- Create environment configuration file

### Step 3: Configure Environment

Edit the generated environment file:

```bash
vim ~/.ibmcloud-h100-env
```

Add your **IBM Cloud API Key**:
```bash
export IBMCLOUD_API_KEY="your-actual-api-key-here"
```

Source the environment:
```bash
source ~/.ibmcloud-h100-env
```

### Step 4: Deploy OpenShift Control Plane

```bash
./phase2-ipi-control-plane/01-generate-install-config.sh
./phase2-ipi-control-plane/02-deploy-cluster.sh
```

⏱️ **Time**: 45-60 minutes

### Step 5: Provision H100 Instance

```bash
./phase3-h100-provisioning/01-create-h100-instance.sh
./phase3-h100-provisioning/02-attach-cluster-networks.sh
./phase3-h100-provisioning/03-start-h100-instance.sh
```

⏱️ **Time**: 20-30 minutes

### Step 6: Integrate H100 as Worker Node

```bash
./phase4-worker-integration/01-prepare-h100-for-openshift.sh
./phase4-worker-integration/02-approve-csrs.sh
./phase4-worker-integration/03-label-h100-node.sh
```

⏱️ **Time**: 30-60 minutes

### Step 7: Install RDMA Operators

```bash
./phase5-rdma-operators/01-install-nfd.sh
./phase5-rdma-operators/02-install-nmstate.sh
./phase5-rdma-operators/03-install-sriov.sh
./phase5-rdma-operators/04-install-nvidia-network-operator.sh
./phase5-rdma-operators/05-configure-sriov-rdma.sh
./phase5-rdma-operators/06-verify-rdma-resources.sh
```

⏱️ **Time**: 30-40 minutes

### Step 8: Install GPU Operator

```bash
./phase6-gpu-operator/01-install-gpu-operator.sh
./phase6-gpu-operator/02-create-cluster-policy.sh
./phase6-gpu-operator/03-verify-gpu-resources.sh
```

⏱️ **Time**: 20-30 minutes

### Step 9: Validation

```bash
./phase7-validation/01-verify-cluster-health.sh
./phase7-validation/02-test-rdma.sh
./phase7-validation/03-test-gpu.sh
./phase7-validation/04-test-nccl-optional.sh
```

⏱️ **Time**: 15-20 minutes

## 📊 Total Deployment Time

**Estimated**: 3-4.5 hours

| Phase | Duration |
|-------|----------|
| Prerequisites | 30 min |
| Control Plane | 45-60 min |
| H100 Provisioning | 20-30 min |
| Worker Integration | 30-60 min |
| RDMA Operators | 30-40 min |
| GPU Operator | 20-30 min |
| Validation | 15-20 min |

## 📁 Directory Structure

```
deployment-scripts/
├── README.md                           # This file
├── phase1-prerequisites/               # Setup tools and credentials
│   ├── 01-setup-prerequisites.sh
│   └── 02-verify-environment.sh
├── phase2-ipi-control-plane/          # Deploy OpenShift masters
│   ├── 01-generate-install-config.sh
│   ├── 02-deploy-cluster.sh
│   └── 03-verify-control-plane.sh
├── phase3-h100-provisioning/          # Create H100 instance
│   ├── 01-create-h100-instance.sh
│   ├── 02-attach-cluster-networks.sh
│   └── 03-start-h100-instance.sh
├── phase4-worker-integration/         # Join H100 to cluster
│   ├── 01-prepare-h100-for-openshift.sh
│   ├── 02-approve-csrs.sh
│   └── 03-label-h100-node.sh
├── phase5-rdma-operators/             # Install RDMA stack
│   ├── 01-install-nfd.sh
│   ├── 02-install-nmstate.sh
│   ├── 03-install-sriov.sh
│   ├── 04-install-nvidia-network-operator.sh
│   ├── 05-configure-sriov-rdma.sh
│   └── 06-verify-rdma-resources.sh
├── phase6-gpu-operator/               # Install GPU stack
│   ├── 01-install-gpu-operator.sh
│   ├── 02-create-cluster-policy.sh
│   └── 03-verify-gpu-resources.sh
├── phase7-validation/                 # Test everything
│   ├── 01-verify-cluster-health.sh
│   ├── 02-test-rdma.sh
│   ├── 03-test-gpu.sh
│   └── 04-test-nccl-optional.sh
├── configs/                           # YAML configurations
│   ├── install-config.yaml.template
│   ├── nfd-operator.yaml
│   ├── nmstate-operator.yaml
│   ├── sriov-operator.yaml
│   ├── sriov-network-policy.yaml
│   ├── network-attachment-definition.yaml
│   ├── gpu-operator.yaml
│   ├── gpu-cluster-policy.yaml
│   ├── rdma-test-pod.yaml
│   ├── gpu-test-pod.yaml
│   └── nccl-test-job.yaml
└── docs/                              # Additional documentation
    ├── ARCHITECTURE.md
    ├── TROUBLESHOOTING.md
    ├── RISKS.md
    └── POST-DEPLOYMENT.md
```

## 🔒 Security Considerations

- All scripts check for required environment variables before proceeding
- IBM Cloud API key stored in environment file (add to .gitignore)
- Pull secret stored in user home directory with restricted permissions
- SSH keys used for secure instance access
- RBAC policies recommended for GPU resource access

## 🐛 Troubleshooting

If you encounter issues, see [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

Common issues:
- **OpenShift install fails**: Check VPC quota, subnet configuration
- **H100 won't join cluster**: Verify CSR approval, check kubelet logs
- **RDMA not working**: Verify cluster network attachments, check mlx5 devices
- **GPU not detected**: Wait for GPU operator pods to complete, check driver installation

## 📚 Official Documentation References

### Red Hat OpenShift
- [OpenShift 4.20 Installing on IBM Cloud (PDF)](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/pdf/installing_on_ibm_cloud/OpenShift_Container_Platform-4.20-Installing_on_IBM_Cloud-en-US.pdf)
- [OpenShift 4.17 Installing on IBM Cloud VPC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/installing_on_ibm_cloud/installing-ibm-cloud-vpc)

### NVIDIA
- [NVIDIA GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)
- [GPUDirect RDMA Configuration](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-rdma.html)

### IBM Cloud
- [IBM Cloud Cluster Networks](https://github.com/ibm-cloud-docs/vpc/blob/master/cn-about.md)
- [H100 Cluster Network Profile](https://cloud.ibm.com/docs/vpc?topic=vpc-cluster-network-h100-profile)

## 🎓 Next Steps After Deployment

See [docs/POST-DEPLOYMENT.md](docs/POST-DEPLOYMENT.md) for:
- Deploying AI/ML workloads
- Configuring monitoring and logging
- Setting up distributed storage
- Scaling to multiple H100 nodes
- Security hardening

## 📞 Support

- **Red Hat Support**: For OpenShift issues (note: Technology Preview = limited support)
- **IBM Cloud Support**: For VPC and cluster network issues
- **NVIDIA Support**: For GPU Operator and CUDA issues

## 📄 License

This deployment guide is provided as-is for educational and development purposes.

---

**Created**: 2026-02-28
**OpenShift Version**: 4.20+
**Target Platform**: IBM Cloud VPC (eu-de)
**GPU Profile**: gx3d-160x1792x8h100 (8× H100 80GB)
