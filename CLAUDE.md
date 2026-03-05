# Claude Context: OpenShift IPI + H100 GPU Deployment on IBM Cloud

## Project Objective
Deploy OpenShift 4.20+ using IPI (Installer-Provisioned Infrastructure) on IBM Cloud VPC with H100 GPU worker node and RDMA cluster networks for AI/ML workloads.

## Critical Constraints

### Technology Limitations
- **OpenShift IPI on IBM Cloud VPC**: Technology Preview (not production-ready, no Red Hat SLA)
- **Cluster Networks**: Can only be attached to STOPPED instances
- **Non-Standard Integration**: H100 worker cannot use standard MachineSet workflow due to cluster network requirement

### Infrastructure Requirements
- **Region**: eu-de (Frankfurt)
- **Zone**: eu-de-2
- **VPC**: rdma-pvc-eude (r010-39a1b8f9-0c94-4fea-9842-54635fb079e9)
- **Cluster Network**: rdma-cluster with hopper-1 profile (02c7-20a6fc6c-33f1-461a-b69b-f36f83255022)
- **8 Cluster Network Subnets**: Pre-provisioned for 8 GPU rails
- **Management Subnet**: 02c7-67b188b3-1981-4454-bc7b-1417f8cdee5d
- **Security Group**: r010-25a67700-a8a2-48d4-a837-573734fca8e4
- **SSH Key**: r010-3f6ad86f-6044-48fd-9bf4-b9cca40927b8

### Cost
- H100: ~$30-40/hour
- Control plane: ~$0.50-1.00/hour

## Architecture

### Compute
- **Control Plane**: 3 master nodes (bx2-8x32: 8 vCPU, 32GB RAM)
- **Worker**: 1 H100 node (gx3d-160x1792x8h100: 160 vCPU, 1.75TB RAM, 8× H100 80GB GPUs)

### Network Design (Dual-Network)
- **VPC Management Network**: Kubernetes API, kubelet, pod networking, services
- **Cluster Network (RDMA)**: 8× ConnectX-7 NICs (400 Gbps each) = 3.2 Tbps total
- **Protocol**: RoCE v2 with GPU Direct RDMA
- **Isolation**: Complete separation between management and RDMA traffic

### Software Stack
- **OpenShift**: 4.20+ (IPI deployment)
- **OS**: RHCOS (Red Hat Enterprise Linux CoreOS)
- **Operators**: NFD → NMState → SR-IOV → NVIDIA Network → NVIDIA GPU (order critical)
- **CNI**: OpenShift SDN/OVN-Kubernetes (primary) + SR-IOV CNI (secondary for RDMA)

## User Request
"Document all the information. I will implement it based on your documentation and executable script. Think Hard"

## What I Delivered

### File Structure (32 files total)
```
deployment-scripts/
├── README.md                         # Overview, architecture, quickstart
├── EXECUTION-GUIDE.md                # Step-by-step execution instructions
├── RUN-ALL-PHASES.sh                 # Master automation script
├── DEPLOYMENT-SUMMARY.md             # Summary at root (created later)
│
├── docs/
│   ├── ARCHITECTURE.md               # Dual-network, GPU Direct RDMA, scaling
│   ├── TROUBLESHOOTING.md            # Issues by phase, debugging, support
│   ├── POST-DEPLOYMENT.md            # AI/ML workloads, monitoring, optimization
│   └── RISKS.md                      # Risk assessment, mitigation, support strategy
│
├── phase1-prerequisites/             # 2 scripts
│   ├── 01-setup-prerequisites.sh     # Install tools (jq, helm, oc, openshift-install)
│   └── 02-verify-environment.sh      # Verify IBM Cloud access, resources
│
├── phase2-ipi-control-plane/         # 3 scripts
│   ├── 01-generate-install-config.sh # Create install-config.yaml
│   ├── 02-deploy-cluster.sh          # Run openshift-install (45-60 min)
│   └── 03-verify-control-plane.sh    # Verify 3 masters Ready, operators healthy
│
├── phase3-h100-provisioning/         # 3 scripts
│   ├── 01-create-h100-instance.sh    # Create H100 with VPC network
│   ├── 02-attach-cluster-networks.sh # Stop instance, attach 8 RDMA interfaces
│   └── 03-start-h100-instance.sh     # Start instance, wait RDMA fabric (10-15 min)
│
├── phase4-worker-integration/        # 3 scripts + README
│   ├── README.md                     # Integration approaches explanation
│   ├── 01-prepare-h100-for-openshift.sh # Configure for cluster join
│   ├── 02-approve-csrs.sh            # Approve certificate signing requests
│   └── 03-label-h100-node.sh         # Apply GPU/RDMA labels, optional taints
│
├── phase5-rdma-operators/            # 6 scripts
│   ├── 01-install-nfd.sh             # Node Feature Discovery
│   ├── 02-install-nmstate.sh         # Network state management
│   ├── 03-install-sriov.sh           # SR-IOV Network Operator
│   ├── 04-install-nvidia-network-operator.sh # NVIDIA Network Operator (via Helm)
│   ├── 05-configure-sriov-rdma.sh    # Create SriovNetworkNodePolicy, NetworkAttachmentDefinition
│   └── 06-verify-rdma-resources.sh   # Verify rdma/rdma_mlx5 resources
│
├── phase6-gpu-operator/              # 3 scripts
│   ├── 01-install-gpu-operator.sh    # NVIDIA GPU Operator
│   ├── 02-create-cluster-policy.sh   # ClusterPolicy with GPUDirect RDMA enabled
│   └── 03-verify-gpu-resources.sh    # Verify nvidia.com/gpu: 8
│
└── phase7-validation/                # 4 scripts
    ├── 01-verify-cluster-health.sh   # Nodes, operators
    ├── 02-test-rdma.sh               # Deploy test pod with RDMA annotation
    ├── 03-test-gpu.sh                # Deploy test pod with GPU request
    └── 04-test-nccl-optional.sh      # NCCL multi-GPU bandwidth test
```

### Script Features
- **Error Handling**: `set -e` (exit on error), `set -u` (exit on undefined var)
- **User Experience**: Color-coded output (red/yellow/green), progress indicators, confirmations
- **Safety**: Dry-run where possible, backups of critical files, validation at each step
- **Idempotency**: Most scripts can be re-run safely
- **Documentation**: Inline comments, clear section headers, helpful error messages

### Documentation Coverage
- **Architecture**: Network design, GPU Direct RDMA, operator stack, scaling
- **Troubleshooting**: Issues by phase, debugging commands, when to escalate
- **Post-Deployment**: AI/ML workloads (PyTorch/TensorFlow), monitoring, storage, optimization
- **Risks**: Tech Preview implications, cost management, integration complexity

## Deployment Phases (3-4.5 hours total)

1. **Prerequisites** (30 min): Install tools, configure environment
2. **Control Plane** (45-60 min): Deploy 3 masters via openshift-install
3. **H100 Provisioning** (20-30 min): Create instance, attach cluster networks
4. **Worker Integration** (30-60 min): Join H100 via CSR approval (complex)
5. **RDMA Operators** (30-40 min): NFD → NMState → SR-IOV → NVIDIA Network
6. **GPU Operator** (20-30 min): Install GPU Operator, create ClusterPolicy
7. **Validation** (15-20 min): Test cluster health, RDMA, GPU, optional NCCL

## Critical Technical Details

### Phase 4 Complexity (Worker Integration)
- **Problem**: Cluster networks require instance STOPPED for attachment
- **Impact**: Cannot use standard MachineSet automation
- **Solution**: Manual CSR approval workflow
- **Options**:
  - A: RHCOS + ignition (requires reinstall + reattach cluster networks)
  - B: RHEL + manual kubelet config (faster but less native)

### RDMA Configuration
- **Device**: ConnectX-7 (vendor: 15b3, deviceID: 2344)
- **Resource Name**: rdma/rdma_mlx5
- **SR-IOV**: numVfs: 0 (using physical functions, not VFs)
- **NetworkAttachmentDefinition**: Name: rdma-cluster-network, IPAM: whereabouts
- **Pod Annotation**: `k8s.v1.cni.cncf.io/networks: rdma-cluster-network`

### GPU Configuration
- **ClusterPolicy**:
  - driver.rdma.enabled: true
  - driver.rdma.useHostMofed: false (containerized MOFED)
  - migManager.enabled: false (H100 uses full GPUs)
- **NCCL Environment**:
  - NCCL_IB_DISABLE=0
  - NCCL_NET_GDR_LEVEL=5
  - NCCL_IB_HCA=mlx5

### Success Criteria
- 3 master nodes Ready
- 1 H100 worker Ready
- All cluster operators Available=True, Degraded=False
- Node resources: rdma/rdma_mlx5: 8, nvidia.com/gpu: 8
- RDMA test: mlx5 devices accessible
- GPU test: nvidia-smi works

## Environment Configuration File
Location: `~/.ibmcloud-h100-env`

Critical variables:
- IBMCLOUD_API_KEY (user must set)
- VPC_ID, CN_ID, MGMT_SUBNET_ID, SG_ID, KEY_ID (pre-configured)
- CN_SUBNET_ID_0 through CN_SUBNET_ID_7 (8 cluster network subnets)
- H100_INSTANCE_ID (set by phase3 scripts)
- H100_NODE_NAME (set by phase4 scripts)
- KUBECONFIG (set after phase2)

## Prerequisites User Must Download
- **OpenShift Installer**: https://console.redhat.com/openshift/install (macOS 4.20+)
- **Pull Secret**: https://console.redhat.com/openshift/install/pull-secret
- **IBM Cloud API Key**: User must have one with VPC permissions

## Known Limitations

### Technology Preview
- No Red Hat production SLA
- Limited support
- May have bugs or missing features
- Not recommended for production

### Scaling Challenges
- Each H100 worker requires manual provisioning + cluster network attachment
- No MachineSet automation due to cluster network requirement
- Scripts must be run for each new node

### Phase 4 Risk
- Worker integration is non-standard
- May require troubleshooting
- CSR approval workflow is manual
- If CSRs don't appear, requires debugging (network, kubelet, certificates)

## User's Next Steps

1. Download OpenShift installer and pull secret from Red Hat
2. Execute: `./deployment-scripts/phase1-prerequisites/01-setup-prerequisites.sh`
3. Edit `~/.ibmcloud-h100-env` to add IBM Cloud API key
4. Follow `EXECUTION-GUIDE.md` phase by phase
5. Validate at each checkpoint before proceeding

## Important Files for User

- **Start Here**: `deployment-scripts/README.md`
- **Execution**: `deployment-scripts/EXECUTION-GUIDE.md`
- **During Issues**: `deployment-scripts/docs/TROUBLESHOOTING.md`
- **After Success**: `deployment-scripts/docs/POST-DEPLOYMENT.md`
- **Credentials**: `~/ocp-h100-ipi-install/cluster-info.txt` (created during phase 2)
- **Kubeconfig**: `~/ocp-h100-ipi-install/auth/kubeconfig`

## What User Will Implement
Everything. I created documentation and scripts. User executes them to perform actual deployment.

## Project Status
- ✅ Complete documentation package delivered (32 files)
- ✅ All 7 phases scripted and documented
- ✅ Validation tests included
- ✅ Troubleshooting guide complete
- ⏸️ Actual deployment: User's responsibility

## Future Claude Sessions Should Know
- This is a **documentation project**, not an implementation
- User has existing IBM Cloud infrastructure (VPC, cluster network, subnets)
- User wanted scripts to execute themselves, not for me to execute
- All work is in `deployment-scripts/` directory
- If user asks about "implementing" - refer them to the scripts
- If errors occur during their execution - use `docs/TROUBLESHOOTING.md` as reference
