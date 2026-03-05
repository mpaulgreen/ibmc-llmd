# Deployment Execution Guide

## Quick Reference

### Pre-Flight Checklist

Before starting deployment, verify you have:

- [ ] macOS environment with Terminal access
- [ ] Red Hat account with valid subscription
- [ ] IBM Cloud account with admin access
- [ ] IBM Cloud API key
- [ ] Existing VPC and cluster network in IBM Cloud (eu-de)
- [ ] H100 quota confirmed in eu-de-2 zone
- [ ] 4-6 hours of uninterrupted time for deployment
- [ ] Budget approval (~$30-40/hour for H100)

### Download Required Files

Before running any scripts:

1. **OpenShift Installer** (from https://console.redhat.com/openshift/install)
   - Select: IBM Cloud → Installer-Provisioned Infrastructure
   - Download: macOS version 4.20+
   - Save to: `~/Downloads/`

2. **Red Hat Pull Secret** (from https://console.redhat.com/openshift/install/pull-secret)
   - Download pull secret
   - Save to: `~/Downloads/`

## Step-by-Step Execution

### Phase 1: Prerequisites (30 minutes)

```bash
cd deployment-scripts

# Step 1: Install tools and setup environment
./phase1-prerequisites/01-setup-prerequisites.sh

# This will:
# - Install jq, helm, openshift-install, oc
# - Configure pull secret and SSH keys
# - Create environment file at ~/.ibmcloud-h100-env

# Step 2: Edit environment file and add your API key
vim ~/.ibmcloud-h100-env
# Set: export IBMCLOUD_API_KEY="your-actual-key"

# Step 3: Source environment
source ~/.ibmcloud-h100-env

# Step 4: Verify everything is ready
./phase1-prerequisites/02-verify-environment.sh

# ✅ Proceed only if verification passes
```

**Checkpoint**: All tools installed, environment configured, IBM Cloud accessible

### Phase 2: Deploy Control Plane (45-60 minutes)

```bash
# Step 1: Generate install configuration
./phase2-ipi-control-plane/01-generate-install-config.sh

# Review the generated config carefully
# This will create install-config.yaml

# Step 2: Deploy cluster (TAKES 45-60 MINUTES!)
./phase2-ipi-control-plane/02-deploy-cluster.sh

# ⏱️  GO GET COFFEE - This is fully automated but takes time
# Do not interrupt the installation process

# Step 3: Verify control plane health
export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig
./phase2-ipi-control-plane/03-verify-control-plane.sh

# ✅ Proceed only if all 3 masters are Ready
```

**Checkpoint**: 3 master nodes running, all cluster operators healthy

### Phase 3: Provision H100 (20-30 minutes)

```bash
# Source environment again (in case new terminal)
source ~/.ibmcloud-h100-env

# Step 1: Create H100 instance
./phase3-h100-provisioning/01-create-h100-instance.sh

# This creates the H100 instance with management network

# Step 2: Attach cluster networks (STOPS INSTANCE!)
./phase3-h100-provisioning/02-attach-cluster-networks.sh

# Attaches 8 RDMA network interfaces
# Instance must be stopped for this operation

# Step 3: Start instance with RDMA (TAKES 15-20 MINUTES!)
./phase3-h100-provisioning/03-start-h100-instance.sh

# ⏱️  WAIT for RDMA fabric initialization (10-15 min)
# This is normal for H100 boot-up

# ✅ Proceed when instance is running
```

**Checkpoint**: H100 running with 8 cluster network interfaces attached

### Phase 4: Worker Integration (30-60 minutes)

**⚠️ IMPORTANT**: This phase is complex due to cluster network requirements

```bash
# Step 1: Prepare H100 for OpenShift
./phase4-worker-integration/01-prepare-h100-for-openshift.sh

# Follow prompts - choose Option B (RHEL) for faster integration
# Option A (RHCOS) requires reinstalling the instance

# Step 2: Approve CSRs (WAIT FOR CSRS TO APPEAR!)
./phase4-worker-integration/02-approve-csrs.sh

# This script waits for CSRs from the H100 node
# May need to troubleshoot if CSRs don't appear

# In another terminal, monitor:
watch oc get csr

# Step 3: Label the H100 node
./phase4-worker-integration/03-label-h100-node.sh

# Applies GPU and RDMA labels
# Optionally applies taint to reserve for GPU workloads

# Verify node is ready:
oc get nodes

# ✅ You should see 3 masters + 1 worker (H100)
```

**Checkpoint**: H100 node joined cluster with Ready status and proper labels

### Phase 5: RDMA Operators (30-40 minutes)

**⚠️ CRITICAL**: Install in exact order listed

```bash
# Step 1: Node Feature Discovery
./phase5-rdma-operators/01-install-nfd.sh

# Step 2: NMState Operator
./phase5-rdma-operators/02-install-nmstate.sh

# Step 3: SR-IOV Network Operator
./phase5-rdma-operators/03-install-sriov.sh

# Step 4: NVIDIA Network Operator
./phase5-rdma-operators/04-install-nvidia-network-operator.sh

# Step 5: Configure SR-IOV for RDMA (TAKES 5-10 MINUTES!)
./phase5-rdma-operators/05-configure-sriov-rdma.sh

# ⏱️  WAIT for SR-IOV policy to apply

# Step 6: Verify RDMA resources
./phase5-rdma-operators/06-verify-rdma-resources.sh

# ✅ Should show rdma/rdma_mlx5 resources available on H100
```

**Checkpoint**: RDMA resources available on H100 node

### Phase 6: GPU Operator (20-30 minutes)

```bash
# Step 1: Install GPU Operator
./phase6-gpu-operator/01-install-gpu-operator.sh

# Step 2: Create ClusterPolicy (TRIGGERS DRIVER INSTALL!)
./phase6-gpu-operator/02-create-cluster-policy.sh

# ⏱️  WAIT 10-20 minutes for GPU operator pods to deploy
# Monitor with: watch oc get pods -n nvidia-gpu-operator

# Step 3: Verify GPU resources
./phase6-gpu-operator/03-verify-gpu-resources.sh

# ✅ Should show nvidia.com/gpu: 8 on H100 node
```

**Checkpoint**: 8 GPU resources available on H100 node

### Phase 7: Validation (15-20 minutes)

```bash
# Step 1: Verify overall cluster health
./phase7-validation/01-verify-cluster-health.sh

# Step 2: Test RDMA functionality
./phase7-validation/02-test-rdma.sh

# Step 3: Test GPU functionality
./phase7-validation/03-test-gpu.sh

# Step 4: Optional NCCL multi-GPU test
./phase7-validation/04-test-nccl-optional.sh

# ✅ All tests should pass
```

**Checkpoint**: All validation tests pass ✅

## Post-Deployment

### Save Important Information

The following files contain critical information:

```bash
# Cluster credentials
cat ~/ocp-h100-ipi-install/cluster-info.txt

# Kubeconfig
export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig

# Environment variables
cat ~/.ibmcloud-h100-env

# Installation logs
ls ~/ocp-h100-ipi-install/
```

### Access Your Cluster

```bash
# Command line
export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig
oc get nodes

# Web console
oc whoami --show-console
# Username: kubeadmin
# Password: (from cluster-info.txt)
```

### Next Steps

See `docs/POST-DEPLOYMENT.md` for:
- Deploying AI/ML workloads
- Setting up monitoring
- Configuring storage
- Scaling to multiple nodes

## Troubleshooting During Deployment

### If a Phase Fails

1. **Don't panic** - most issues are recoverable
2. **Check the logs** - each script outputs detailed error messages
3. **Consult docs/TROUBLESHOOTING.md** - common issues documented
4. **Retry the failed step** - scripts are mostly idempotent
5. **Ask for help** - see TROUBLESHOOTING.md for support contacts

### Common Issues

**Phase 2 - Control plane deployment fails**:
- Check VPC quota limits
- Verify subnet configuration
- Review OpenShift installer logs

**Phase 4 - Worker won't join**:
- Verify network connectivity from H100 to API server
- Check security group rules
- Review kubelet logs

**Phase 5 - No RDMA resources**:
- Wait longer for SR-IOV policy to apply
- Check node has ConnectX-7 NICs detected
- Verify cluster network interfaces are attached

**Phase 6 - No GPU resources**:
- Wait for all GPU operator pods to be Running
- Check nvidia-smi works on H100 node
- Review GPU operator logs

### Recovery Procedures

**To restart from scratch**:
```bash
# Delete OpenShift cluster
cd ~/ocp-h100-ipi-install
openshift-install destroy cluster --dir .

# Delete H100 instance
ibmcloud is instance-delete $H100_INSTANCE_ID --force

# Start over from Phase 1
```

**To retry a single phase**:
- Most scripts can be re-run safely
- Check script comments for idempotency notes
- Scripts create resources with --dry-run=client when possible

## Time Management

### Attended vs Unattended Time

**Total time**: 3-4.5 hours
**Unattended time**: 2-3 hours (waiting for installations)
**Attended time**: 1-1.5 hours (running scripts, making decisions)

### Schedule Recommendation

**Day 1**:
- Phase 1: Prerequisites (30 min)
- Phase 2: Control plane (start deployment, then break)
  - Come back after 1 hour
- Phase 2: Verify control plane (5 min)

**Day 1 or 2**:
- Phase 3: H100 provisioning (20 min to start, then break)
  - Come back after 20 minutes
- Phase 4: Worker integration (variable timing)

**Day 2**:
- Phase 5: RDMA operators (install all, then break)
  - Come back after 30 minutes
- Phase 6: GPU operator (install, then break)
  - Come back after 20 minutes
- Phase 7: Validation (15-20 min)

## Success Criteria

Deployment is successful when:

- ✅ 3 master nodes in Ready state
- ✅ 1 H100 worker node in Ready state
- ✅ All cluster operators Available=True
- ✅ RDMA resources: rdma/rdma_mlx5: 8 on H100
- ✅ GPU resources: nvidia.com/gpu: 8 on H100
- ✅ RDMA test pod can access mlx5 devices
- ✅ GPU test pod can run nvidia-smi
- ✅ Web console accessible
- ✅ oc commands work

## Final Notes

- **Save your work**: Backup KUBECONFIG and cluster-info.txt
- **Cost awareness**: H100 costs ~$30-40/hour - stop when not using
- **Tech Preview**: Remember this is not production-supported
- **Documentation**: Keep this guide handy for future reference
- **Community**: Share your experience, help others

---

**Good luck with your deployment!** 🚀

For questions or issues, see `docs/TROUBLESHOOTING.md`
