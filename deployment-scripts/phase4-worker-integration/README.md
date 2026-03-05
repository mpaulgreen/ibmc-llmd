# Phase 4: H100 Worker Node Integration

## Overview

This phase integrates the H100 GPU instance as an OpenShift worker node. This is the most complex phase because:

1. The H100 instance was provisioned **outside** of OpenShift's MachineSet workflow
2. Cluster network attachments required the instance to be stopped during attachment
3. Standard OpenShift node join procedures assume IPI-managed or UPI-managed nodes

## Integration Approach

We use the **Certificate Signing Request (CSR) approval workflow**, which is the standard OpenShift method for adding nodes that weren't provisioned by the cluster.

### Steps

1. **Prepare H100 for OpenShift**
   - Install required packages (CRI-O, kubelet)
   - Configure ignition/cloud-init for cluster join
   - Set up cluster API connectivity

2. **Approve CSRs**
   - Wait for node bootstrap CSR
   - Approve bootstrap CSR
   - Wait for node serving CSR
   - Approve serving CSR

3. **Label and Configure Node**
   - Apply worker role label
   - Apply GPU-specific labels
   - Apply RDMA labels
   - Add taints if needed

## Important Notes

### Option A: RHCOS-based (Recommended)

If the H100 instance is running RHCOS (Red Hat Enterprise Linux CoreOS):
- Use ignition configuration for automated join
- Minimal manual configuration required
- Native OpenShift integration

### Option B: RHEL-based (Alternative)

If the H100 instance is running standard RHEL:
- Manual configuration of kubelet, CRI-O
- More complex but provides flexibility
- Requires RHEL entitlement

## Prerequisites

- OpenShift cluster deployed and healthy (Phase 2 complete)
- H100 instance running with cluster networks attached (Phase 3 complete)
- SSH access to H100 instance (or console access)
- Cluster admin kubeconfig

## Execution Time

- **Preparation**: 15-20 minutes
- **CSR Approval**: 5-10 minutes
- **Labeling**: 5 minutes
- **Total**: 30-60 minutes

## Scripts

1. `01-prepare-h100-for-openshift.sh` - Configure H100 for cluster join
2. `02-approve-csrs.sh` - Approve certificate signing requests
3. `03-label-h100-node.sh` - Apply labels and configure node

## Validation

After completion, verify:
- Node appears in `oc get nodes`
- Node status is `Ready`
- Node has appropriate labels
- Cluster network interfaces are visible

## Next Steps

After successful integration:
- Proceed to Phase 5: Install RDMA operators
- Proceed to Phase 6: Install GPU operator

## Troubleshooting

**Node doesn't appear:**
- Check kubelet logs on H100
- Verify network connectivity to cluster API
- Check firewall/security group rules

**CSRs not appearing:**
- Verify kubelet bootstrap configuration
- Check cluster API endpoint
- Verify certificates and tokens

**Node stays NotReady:**
- Check CNI plugin installation
- Verify network routes
- Check kubelet logs

## References

- [OpenShift CSR Approval](https://docs.openshift.com/container-platform/latest/machine_management/csr_approval.html)
- [Adding RHEL nodes](https://docs.openshift.com/container-platform/latest/machine_management/adding-rhel-compute.html)
