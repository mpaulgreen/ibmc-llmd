# Manual Execution Guides: OpenShift IPI + H100 on IBM Cloud

## Overview

This directory contains **manual, step-by-step guides** for deploying OpenShift 4.20+ with H100 GPU workers on IBM Cloud VPC. Each command can be reviewed and executed individually for maximum control and safety.

## Why Manual Guides?

While automated scripts exist in the `../deployment-scripts/` directory, these manual guides provide:

- **Risk Mitigation**: Review each command before execution
- **Learning**: Better understanding of what each step does
- **Debugging**: Easier to identify where failures occur
- **Flexibility**: Adapt commands to your specific environment
- **Complete Visibility**: See exactly what's being executed

## Architecture

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
│  │  Dual Network Architecture:                      │    │
│  │  • VPC Management Network                        │    │
│  │    - Kubernetes API/kubelet                      │    │
│  │    - Pod networking (CNI)                        │    │
│  │                                                   │    │
│  │  • Cluster Network (RDMA)                        │    │
│  │    - 8× ConnectX-7 NICs (400 Gbps each)         │    │
│  │    - Total: 3.2 Tbps bandwidth                   │    │
│  │    - RoCE v2 with GPU Direct RDMA                │    │
│  │                                                   │    │
│  │  GPU Resources:                                   │    │
│  │  • 8× NVIDIA H100 SXM5 (80GB HBM3 each)         │    │
│  │  • 640GB total GPU memory                        │    │
│  └──────────────────────────────────────────────────┘    │
└────────────────────────────────────────────────────────────┘
```

## ⚠️ CRITICAL: Technology Preview Status

**OpenShift IPI on IBM Cloud VPC is currently a Technology Preview feature:**

- ❌ **Not supported** with Red Hat production service-level agreements (SLAs)
- ⚠️ May not be functionally complete
- 🧪 **Not intended for production use**
- 📝 User acknowledgment required before proceeding

**Proceed only if you accept these limitations.**

## Deployment Phases

This guide covers the first 4 phases required to get a functional OpenShift cluster with H100 worker:

| Phase | Guide | Duration | Description |
|-------|-------|----------|-------------|
| **1** | [PHASE1-PREREQUISITES.md](PHASE1-PREREQUISITES.md) | 30 min | Install tools, configure environment |
| **2** | [PHASE2-UPI-CONTROL-PLANE.md](PHASE2-UPI-CONTROL-PLANE.md) | 90-120 min | Deploy OpenShift UPI control plane (3 masters) |
| **3** | [PHASE3-H100-PROVISIONING.md](PHASE3-H100-PROVISIONING.md) | 20-30 min | Create H100 instance with cluster networks |
| **4** | [PHASE4-WORKER-INTEGRATION.md](PHASE4-WORKER-INTEGRATION.md) | 30-60 min | Join H100 to cluster as worker node |

**Total Time**: 2.5-3.5 hours for Phases 1-4

### Additional Phases (Not Covered Here)

Phases 5-7 (RDMA operators, GPU operator, validation) are covered in the automated scripts:
- Phase 5: RDMA Operators (30-40 min)
- Phase 6: GPU Operator (20-30 min)
- Phase 7: Validation (15-20 min)

See `../deployment-scripts/` for those phases.

## Prerequisites Checklist

Before starting, ensure you have:

### IBM Cloud Resources (Already Provisioned)

- ✅ **VPC**: `rdma-pvc-eude` (r010-39a1b8f9-0c94-4fea-9842-54635fb079e9)
- ✅ **Cluster Network**: `rdma-cluster` with hopper-1 profile (02c7-20a6fc6c-33f1-461a-b69b-f36f83255022)
- ✅ **8× Cluster Network Subnets** (for 8 GPU rails)
- ✅ **Management Subnet**: 02c7-67b188b3-1981-4454-bc7b-1417f8cdee5d
- ✅ **Security Group**: r010-25a67700-a8a2-48d4-a837-573734fca8e4
- ✅ **SSH Key**: r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8

### Required Downloads

1. **OpenShift Installer and CLI** — Downloaded via `curl` in Phase 1 Steps 7-8
   - Source: https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable-4.20/
   - `openshift-install-mac-arm64.tar.gz` (~373 MB)
   - `openshift-client-mac-arm64.tar.gz` (~58 MB)

2. **Red Hat Pull Secret**
   - Download from: https://console.redhat.com/openshift/install/pull-secret
   - Save to: `~/Downloads/`

3. **IBM Cloud API Key**
   - Create in IBM Cloud console with VPC permissions
   - You'll need this during Phase 1

### System Requirements

- **Operating System**: macOS with Apple Silicon (M1/M2/M3/M4 — arm64)
- **Network Access**: IBM Cloud VPC, Red Hat mirror
- **Permissions**: sudo access on local machine
- **Disk Space**: ~20GB for OpenShift installer artifacts

## Getting Started

### Step 1: Understand the Guides

Each phase guide follows this structure:

1. **Overview** - What this phase accomplishes
2. **Pre-Flight Checks** - What to verify before starting
3. **Step-by-Step Instructions** - Individual commands to execute
4. **Verification Steps** - How to confirm success
5. **Checkpoint Summary** - What should be true at end of phase

### Step 2: Execute Phase by Phase

Start with Phase 1 and proceed sequentially:

```bash
cd /Users/mrigankapaul/Documents/knowledgebase/ibmc-ipi-roce/manual
open PHASE1-PREREQUISITES.md
```

**IMPORTANT**:
- Complete each phase fully before moving to the next
- Verify success at each checkpoint
- Do not skip phases

### Step 3: Copy and Execute Commands

For each command in the guides:

1. **Read the explanation** - Understand what the command does
2. **Copy the command** - Use the code blocks provided
3. **Paste into terminal** - Execute the command
4. **Verify output** - Check it matches expected results
5. **Proceed to next step** - Continue when successful

## Cost Awareness

### Estimated Hourly Costs

- **Control Plane** (3 masters): ~$0.50-1.00/hour
- **H100 Worker**: ~$30-40/hour
- **Total**: ~$30-41/hour while running

### Cost Management Tips

1. **Stop when not in use**: H100 instance can be stopped between work sessions
2. **Monitor usage**: Use IBM Cloud cost dashboard
3. **Set budgets**: Configure billing alerts
4. **Plan deployments**: Complete testing in focused sessions

## Directory Structure

```
manual/
├── README.md                       # This file
├── PHASE1-PREREQUISITES.md         # Tools and environment setup
├── PHASE2-CONTROL-PLANE.md         # OpenShift cluster deployment
├── PHASE3-H100-PROVISIONING.md     # H100 instance creation
└── PHASE4-WORKER-INTEGRATION.md    # Worker node join process
```

## Important Files Generated

During the deployment, key files will be created:

| File | Location | Purpose |
|------|----------|---------|
| Environment Config | `~/.ibmcloud-h100-env` | All configuration variables |
| Pull Secret | `~/.pull-secret.json` | Red Hat authentication |
| Install Config | `~/ocp-h100-ipi-install/install-config.yaml` | Cluster configuration |
| Kubeconfig | `~/ocp-h100-ipi-install/auth/kubeconfig` | Cluster access credentials |
| Admin Password | `~/ocp-h100-ipi-install/auth/kubeadmin-password` | Web console login |
| Cluster Info | `~/ocp-h100-ipi-install/cluster-info.txt` | Summary of cluster details |

**Backup these files securely!**

## Troubleshooting

If you encounter issues:

1. **Check the specific phase guide** - Each has troubleshooting sections
2. **Review logs** - Command outputs usually indicate the problem
3. **Verify prerequisites** - Ensure previous phases completed successfully
4. **Check IBM Cloud status** - Service outages can affect deployments
5. **Consult detailed troubleshooting** - See `../deployment-scripts/docs/TROUBLESHOOTING.md`

### Common Issues

- **API authentication failures**: Check IBM Cloud API key and permissions
- **Quota limits**: Verify VPC quotas for instances, floating IPs, load balancers
- **Network connectivity**: Ensure security groups allow required traffic
- **CSR approval timeout**: H100 may need manual kubelet configuration adjustment

## Support Resources

- **Red Hat OpenShift Documentation**: https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/
- **IBM Cloud VPC Documentation**: https://cloud.ibm.com/docs/vpc
- **NVIDIA GPU Operator**: https://docs.nvidia.com/datacenter/cloud-native/openshift/
- **IBM Cloud Cluster Networks**: https://github.com/ibm-cloud-docs/vpc/blob/master/cn-about.md

## Safety Guidelines

### Destructive Operations

The guides will warn you before destructive operations:

- ⚠️ **Stopping instances** - Results in downtime
- ⚠️ **Deleting resources** - Cannot be undone
- ⚠️ **Recreating clusters** - Destroys all existing data
- ⚠️ **Force operations** - Bypass safety checks

**Always read warnings carefully before proceeding.**

### Best Practices

1. **Execute one command at a time** - Don't batch commands without understanding them
2. **Verify after each major step** - Use verification commands provided
3. **Save important outputs** - Keep cluster credentials, instance IDs, etc.
4. **Document customizations** - Note any changes you make
5. **Backup before destructive ops** - Save configurations before major changes

## Next Steps After Phases 1-4

Once you complete these four phases, you'll have:

- ✅ Functional OpenShift cluster (3 masters)
- ✅ H100 worker node joined to cluster
- ✅ Cluster networks attached (8× RDMA interfaces)
- ✅ Basic cluster access configured

To complete the full stack:

1. **Install RDMA Operators** (Phase 5)
   - Use automated scripts: `../deployment-scripts/phase5-rdma-operators/`
   - Or follow Red Hat documentation for manual setup

2. **Install GPU Operator** (Phase 6)
   - Use automated scripts: `../deployment-scripts/phase6-gpu-operator/`
   - Or use NVIDIA's Helm charts directly

3. **Validate Deployment** (Phase 7)
   - Use automated scripts: `../deployment-scripts/phase7-validation/`
   - Or manually test GPU and RDMA functionality

## Success Criteria

After completing Phases 1-4, verify:

- [ ] 3 master nodes in Ready state
- [ ] 1 H100 worker node in Ready state
- [ ] All cluster operators Available=True, Degraded=False
- [ ] Web console accessible
- [ ] `oc` commands work from your workstation
- [ ] H100 node has cluster network attachments visible

## Reference Documentation

### This Deployment

- [Architecture Details](../deployment-scripts/docs/ARCHITECTURE.md)
- [Risk Assessment](../deployment-scripts/docs/RISKS.md)
- [Troubleshooting Guide](../deployment-scripts/docs/TROUBLESHOOTING.md)
- [Post-Deployment Guide](../deployment-scripts/docs/POST-DEPLOYMENT.md)

### Official Documentation

- **OpenShift 4.20 on IBM Cloud (PDF)**: [Installing on IBM Cloud](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/pdf/installing_on_ibm_cloud/OpenShift_Container_Platform-4.20-Installing_on_IBM_Cloud-en-US.pdf)
- **OpenShift 4.17 IBM Cloud VPC**: [Installing on IBM Cloud VPC](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/installing_on_ibm_cloud/installing-ibm-cloud-vpc)
- **NVIDIA GPU Operator**: [GPU Operator on OpenShift](https://docs.nvidia.com/datacenter/cloud-native/openshift/latest/index.html)
- **GPUDirect RDMA**: [Configuration Guide](https://docs.nvidia.com/datacenter/cloud-native/gpu-operator/latest/gpu-operator-rdma.html)

---

## Ready to Begin?

Start with **[Phase 1: Prerequisites Setup](PHASE1-PREREQUISITES.md)**

This phase will install all required tools and configure your environment for the deployment.

---

**Created**: 2026-02-28
**OpenShift Version**: 4.20+
**Target Platform**: IBM Cloud VPC (eu-de)
**GPU Profile**: gx3d-160x1792x8h100 (8× H100 80GB)
