# Troubleshooting Guide

## Common Issues and Solutions

### Phase 1: Prerequisites

#### Issue: OpenShift installer download fails
**Symptoms**: Cannot download from Red Hat console
**Solution**:
- Verify Red Hat account has valid subscription
- Check Red Hat customer portal access
- Try alternative download from mirror.openshift.com

#### Issue: IBM Cloud CLI authentication fails
**Symptoms**: `ibmcloud login` fails
**Solution**:
- Verify API key is correct
- Check API key has required permissions
- Try: `ibmcloud iam api-key-create new-key` to create new key

### Phase 2: Control Plane Deployment

#### Issue: OpenShift install hangs at bootstrap
**Symptoms**: Installer stuck waiting for bootstrap
**Solution**:
```bash
# Check bootstrap logs
oc --kubeconfig=<install-dir>/auth/kubeconfig logs -n openshift-kube-apiserver-operator <pod>

# Check bootstrap node (if accessible)
ssh core@<bootstrap-ip> 'journalctl -u bootkube.service'
```

#### Issue: Control plane operators degraded
**Symptoms**: `oc get co` shows operators with Available=False
**Solution**:
- Wait 10-15 minutes for operators to stabilize
- Check specific operator logs:
  ```bash
  oc logs -n openshift-<operator-name> <pod-name>
  ```

#### Issue: Cannot access cluster console
**Symptoms**: Console URL returns connection refused
**Solution**:
- Verify ingress operator is healthy: `oc get co ingress`
- Check console pods: `oc get pods -n openshift-console`
- Verify load balancer is healthy in IBM Cloud console

### Phase 3: H100 Provisioning

#### Issue: H100 instance creation fails
**Symptoms**: Instance creation returns error
**Solution**:
- Check quota: `ibmcloud is instance-profiles`
- Verify H100 availability in zone: `ibmcloud target -r eu-de`
- Check VPC limits
- Contact IBM Cloud support for H100 availability

#### Issue: Cluster network attachment fails
**Symptoms**: Cannot attach cluster network interface
**Solution**:
- Verify instance is STOPPED: `ibmcloud is instance <id>`
- Check cluster network state: `ibmcloud is cluster-network <id>`
- Verify subnet IDs are correct
- Check cluster network profile matches instance

#### Issue: Instance won't start after cluster network attachment
**Symptoms**: Instance stuck in starting state
**Solution**:
- Wait 15-20 minutes for RDMA fabric initialization
- Check instance console logs via IBM Cloud console
- Verify all 8 interfaces attached correctly
- Try stop/start cycle

### Phase 4: Worker Integration

#### Issue: CSRs never appear
**Symptoms**: No pending CSRs when running approve script
**Solution**:
- Check H100 can reach cluster API:
  ```bash
  # On H100
  curl -k https://<api-url>:6443/healthz
  ```
- Verify kubelet is running:
  ```bash
  systemctl status kubelet
  journalctl -u kubelet
  ```
- Check firewall/security groups allow traffic

#### Issue: Node stays NotReady
**Symptoms**: Node appears but status is NotReady
**Solution**:
- Check CNI plugin: `oc get pods -n openshift-sdn` or `oc get pods -n openshift-ovn-kubernetes`
- Check node logs:
  ```bash
  oc adm node-logs <node-name> -u kubelet
  ```
- Verify container runtime: `oc debug node/<node-name>` then `chroot /host` and `crictl ps`

#### Issue: Node has no labels
**Symptoms**: Node joined but missing GPU/RDMA labels
**Solution**:
- Manually apply labels:
  ```bash
  ./phase4-worker-integration/03-label-h100-node.sh
  ```

### Phase 5: RDMA Operators

#### Issue: SR-IOV operator install fails
**Symptoms**: SR-IOV operator CSV shows Failed
**Solution**:
- Check operator logs: `oc logs -n openshift-sriov-network-operator <operator-pod>`
- Verify OpenShift version compatibility
- Check for conflicting operators

#### Issue: No RDMA resources on node
**Symptoms**: `oc get node -o json` shows no rdma/rdma_mlx5
**Solution**:
- Check SR-IOV policy applied: `oc get sriovnetworknodepolicy -n openshift-sriov-network-operator`
- Check node state: `oc get sriovnetworknodestate -n openshift-sriov-network-operator -o yaml`
- Verify NICs are detected: On H100 run `lspci | grep Mellanox`
- Check device IDs match policy (vendor: 15b3, device: 2344)

#### Issue: NetworkAttachmentDefinition not working
**Symptoms**: Pods can't use rdma-cluster-network annotation
**Solution**:
- Verify NAD exists: `oc get network-attachment-definitions -n default`
- Check Multus is running: `oc get pods -n openshift-multus`
- Review pod events: `oc describe pod <pod-name>`

### Phase 6: GPU Operator

#### Issue: GPU operator pods crashlooping
**Symptoms**: nvidia-driver-daemonset or device-plugin pods failing
**Solution**:
- Check logs: `oc logs -n nvidia-gpu-operator <pod-name>`
- Verify kernel version compatibility
- Check for secure boot (must be disabled for NVIDIA drivers)
- Verify node has GPUs: SSH to H100 and run `lspci | grep NVIDIA`

#### Issue: No GPU resources on node
**Symptoms**: `nvidia.com/gpu: 0` in node allocatable
**Solution**:
- Wait for all GPU operator pods to be Running
- Check device plugin logs: `oc logs -n nvidia-gpu-operator nvidia-device-plugin-*`
- Verify nvidia-smi works on node: `oc debug node/<h100> -- chroot /host nvidia-smi`
- Check ClusterPolicy: `oc get clusterpolicy -n nvidia-gpu-operator`

#### Issue: GPUDirect RDMA not working
**Symptoms**: NCCL tests show low bandwidth
**Solution**:
- Verify RDMA enabled in ClusterPolicy:
  ```bash
  oc get clusterpolicy gpu-cluster-policy -o yaml | grep -A5 rdma
  ```
- Check MOFED driver loaded:
  ```bash
  oc debug node/<h100> -- chroot /host lsmod | grep mlx
  ```
- Verify NCCL environment variables set correctly

### Phase 7: Validation

#### Issue: RDMA test pod won't start
**Symptoms**: Pod pending or failed
**Solution**:
- Check RDMA resources available: `oc describe node <h100>`
- Verify NetworkAttachmentDefinition exists
- Check pod tolerations if node is tainted
- Review pod events: `oc describe pod rdma-test`

#### Issue: GPU test shows no GPUs
**Symptoms**: nvidia-smi returns "No devices found"
**Solution**:
- Verify GPU resources requested in pod spec
- Check GPU device plugin running
- Verify pod scheduled on GPU node
- Check pod has access to /dev/nvidia* devices

#### Issue: NCCL test fails
**Symptoms**: NCCL errors or low bandwidth
**Solution**:
- Check all 8 GPUs and 8 RDMA interfaces available
- Verify NCCL environment variables:
  ```bash
  NCCL_DEBUG=INFO
  NCCL_IB_DISABLE=0
  NCCL_NET_GDR_LEVEL=5
  ```
- Check RDMA links active: `oc exec <pod> -- rdma link show`
- Review NCCL debug output for errors

## Advanced Debugging

### Accessing H100 Instance Directly

```bash
# Get instance IP
ibmcloud is instance $H100_INSTANCE_ID --output json | jq -r '.primary_network_interface.primary_ip.address'

# SSH (if floating IP exists)
ssh root@<floating-ip>

# Via oc debug
oc debug node/<h100-node>
chroot /host
```

### Checking RDMA Devices

```bash
# List RDMA devices
ibv_devices

# Check RDMA link status
rdma link show

# Test RDMA connectivity (between two pods)
ibv_rc_pingpong -d mlx5_0 -g 0
```

### Checking GPU Devices

```bash
# GPU status
nvidia-smi

# GPU topology
nvidia-smi topo -m

# CUDA version
nvcc --version

# NCCL test
/usr/local/cuda/bin/nccl-test
```

### Collecting Diagnostic Data

```bash
# Cluster info
oc adm inspect clusteroperator

# Node logs
oc adm node-logs <node> -u kubelet
oc adm node-logs <node> -u crio

# Must-gather
oc adm must-gather

# GPU operator must-gather
oc adm must-gather --image=nvcr.io/nvidia/cloud-native/gpu-operator-must-gather:latest
```

## Getting Help

### Red Hat Support
- OpenShift issues: Open case at https://access.redhat.com
- Include must-gather output
- Note: Tech Preview features have limited support

### IBM Cloud Support
- VPC/cluster network issues: IBM Cloud support portal
- H100 instance issues: IBM Cloud support
- Include instance ID and timestamps

### NVIDIA Support
- GPU Operator issues: NVIDIA Developer Forums
- NCCL performance: NVIDIA NCCL GitHub
- H100 hardware: NVIDIA Enterprise Support (if applicable)

### Community Resources
- OpenShift Community: https://discuss.openshift.com
- NVIDIA Developer Forums: https://forums.developer.nvidia.com
- IBM Cloud Slack: https://ic-devops-slack-invite.us-south.devops.cloud.ibm.com
