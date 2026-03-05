#!/bin/bash
################################################################################
# MASTER DEPLOYMENT SCRIPT - RUN ALL PHASES
# WARNING: This script runs the entire deployment end-to-end
# Estimated time: 3-4.5 hours
################################################################################

set -e
set -u

echo "=================================================="
echo "OpenShift 4.20+ IPI with H100 GPU - Full Deployment"
echo "=================================================="
echo ""
echo "⚠️  WARNING: This will run ALL deployment phases"
echo "   Estimated time: 3-4.5 hours"
echo "   Cost: ~$30-40/hour for H100 after Phase 3"
echo ""
echo "Prerequisites:"
echo "  - OpenShift installer downloaded to ~/Downloads"
echo "  - Pull secret downloaded to ~/Downloads"
echo "  - IBM Cloud API key ready"
echo ""

read -p "Continue with full deployment? (yes/NO): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Deployment cancelled"
    exit 0
fi

# Phase 1
echo ""; echo "=== PHASE 1: PREREQUISITES ==="; echo ""
./phase1-prerequisites/01-setup-prerequisites.sh

echo ""; echo "⚠️  STOP: Edit ~/.ibmcloud-h100-env and set your API key"; echo ""
read -p "Press Enter when API key is set..."

source ~/.ibmcloud-h100-env
./phase1-prerequisites/02-verify-environment.sh

# Phase 2
echo ""; echo "=== PHASE 2: CONTROL PLANE ==="; echo ""
./phase2-ipi-control-plane/01-generate-install-config.sh
./phase2-ipi-control-plane/02-deploy-cluster.sh
export KUBECONFIG=~/ocp-h100-ipi-install/auth/kubeconfig
./phase2-ipi-control-plane/03-verify-control-plane.sh

# Phase 3
echo ""; echo "=== PHASE 3: H100 PROVISIONING ==="; echo ""
source ~/.ibmcloud-h100-env
./phase3-h100-provisioning/01-create-h100-instance.sh
./phase3-h100-provisioning/02-attach-cluster-networks.sh
./phase3-h100-provisioning/03-start-h100-instance.sh

# Phase 4
echo ""; echo "=== PHASE 4: WORKER INTEGRATION ==="; echo ""
echo "⚠️  This phase requires manual steps - follow prompts carefully"
./phase4-worker-integration/01-prepare-h100-for-openshift.sh
./phase4-worker-integration/02-approve-csrs.sh
./phase4-worker-integration/03-label-h100-node.sh

# Phase 5
echo ""; echo "=== PHASE 5: RDMA OPERATORS ==="; echo ""
./phase5-rdma-operators/01-install-nfd.sh
./phase5-rdma-operators/02-install-nmstate.sh
./phase5-rdma-operators/03-install-sriov.sh
./phase5-rdma-operators/04-install-nvidia-network-operator.sh
./phase5-rdma-operators/05-configure-sriov-rdma.sh
./phase5-rdma-operators/06-verify-rdma-resources.sh

# Phase 6
echo ""; echo "=== PHASE 6: GPU OPERATOR ==="; echo ""
./phase6-gpu-operator/01-install-gpu-operator.sh
./phase6-gpu-operator/02-create-cluster-policy.sh
./phase6-gpu-operator/03-verify-gpu-resources.sh

# Phase 7
echo ""; echo "=== PHASE 7: VALIDATION ==="; echo ""
./phase7-validation/01-verify-cluster-health.sh
./phase7-validation/02-test-rdma.sh
./phase7-validation/03-test-gpu.sh

echo ""
echo "=================================================="
echo "✅ DEPLOYMENT COMPLETE!"
echo "=================================================="
echo ""
echo "Cluster Information:"
cat ~/ocp-h100-ipi-install/cluster-info.txt
echo ""
echo "Next steps: See docs/POST-DEPLOYMENT.md"
