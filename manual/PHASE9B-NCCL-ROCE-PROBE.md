# Phase 9B: NCCL RoCE Probe on IBM Cloud VFs

## Result: NCCL RoCE FAILS on IBM Cloud VFs

**Tested 2026-03-18.** NCCL IB plugin fails on IBM Cloud cluster network VFs (device `101e`) with `ibv_modify_qp` error (errno 19 = ENODEV) during QP state transition. Both GDRDMA and non-GDRDMA modes fail identically. TCP sockets (`NCCL_IB_DISABLE=1`) remain the only viable NCCL transport on these VFs.

## Overview

Phase 9 deployed DeepSeek-V2 with NCCL over TCP (`NCCL_IB_DISABLE=1`). This was based on the Phase 8 finding that UCX RC transport fails on IBM Cloud VFs (device `101e`). However, NCCL uses fundamentally different IB verbs than UCX, so we hypothesized NCCL RoCE might work where UCX RC didn't.

This guide documents the probe we ran to test that hypothesis, and the definitive failure we found.

**Prerequisites**: Phase 9 completed (DeepSeek-V2 running with NCCL over TCP)
**Time taken**: ~30 minutes

## Background: Why We Tested This

### The Networking Stack on IBM Cloud GPU Instances

IBM Cloud's physical servers have real network cards (PFs — Physical Functions, device `15b3:2344`). These are split into virtual network cards (VFs — Virtual Functions, device `15b3:101e`) that are assigned to each VM. Your H100 and H200 instances each get 8 VFs — one per RDMA subnet.

VFs look like real network cards to the OS but have restricted capabilities. The hopper-1 RDMA fabric provides **3.2 Tbps bisection bandwidth** (8 links x 400 Gbps), but this bandwidth is only accessible if the VFs support the RDMA verbs needed by the software.

### Two Ways GPUs Talk Across Nodes

**TCP sockets** (what Phase 9 uses): Data goes through the CPU and OS networking stack. Reliable but slower — achieves **40-80 Gbps**.

**RDMA/RoCE** (what we hoped to enable): Network card reads/writes GPU memory directly, bypassing CPU and OS entirely. Could achieve **up to 100 Gbps** (capped by instance bandwidth).

### Why UCX RC Failed (Phase 8) but NCCL Might Differ

In Phase 8, UCX RC transport failed because VFs don't support "active messages" — a specific callback mechanism. We hypothesized NCCL might work because it uses a different communication pattern:

- **UCX**: RC QP + Active Message delivery (remote callbacks)
- **NCCL**: RC QP + `RDMA_WRITE_WITH_IMM` (one-sided writes + completion queue polling)

Since NCCL never uses active messages, the specific UCX failure mode shouldn't apply. The question was whether VFs support `RDMA_WRITE_WITH_IMM` and QP state transitions.

### What "RoCE" Means

IBM Cloud cluster network uses **RoCE v2** (RDMA over Converged Ethernet), not InfiniBand. NCCL treats both as "IB" internally but RoCE requires setting `NCCL_IB_GID_INDEX` to select the correct GID entry (index 3 for RoCE v2 with IPv4).

## The Probe

### Step 1: Discover HCA Names and GID Indices

We queried RDMA devices via sysfs on the MOFED driver pods.

> **Note**: The MOFED pods (label `nvidia.com/ofed-driver`) do NOT include `ibv_devinfo` — it is not bundled in the containerized MOFED image. Use sysfs (`/sys/class/infiniband/`) instead.

**Find the MOFED pods:**

```bash
H100_MOFED=$(oc get pods -n nvidia-network-operator \
  --field-selector spec.nodeName=ocp-gpu-worker-h100 \
  -l nvidia.com/ofed-driver \
  -o jsonpath='{.items[0].metadata.name}')
echo "H100 MOFED pod: $H100_MOFED"

H200_MOFED=$(oc get pods -n nvidia-network-operator \
  --field-selector spec.nodeName=ocp-gpu-worker-h200-0 \
  -l nvidia.com/ofed-driver \
  -o jsonpath='{.items[0].metadata.name}')
echo "H200 MOFED pod: $H200_MOFED"
```

**Discover HCAs and GID table (run on each node):**

```bash
oc exec -n nvidia-network-operator $H100_MOFED -c mofed-container -- bash -c '
echo "=== HCA devices ==="
ls /sys/class/infiniband/
echo ""
for dev in /sys/class/infiniband/*/; do
  devname=$(basename $dev)
  echo "--- $devname ---"
  for port in $dev/ports/*/; do
    pnum=$(basename $port)
    echo "  port $pnum: state=$(cat $port/state 2>/dev/null) link_layer=$(cat $port/link_layer 2>/dev/null)"
    for i in 0 1 2 3; do
      gid=$(cat $port/gids/$i 2>/dev/null)
      gtype=$(cat $port/gid_attrs/types/$i 2>/dev/null)
      if [ -n "$gid" ] && [ "$gid" != "0000:0000:0000:0000:0000:0000:0000:0000" ]; then
        echo "    GID[$i]: $gid  ($gtype)"
      fi
    done
  done
done
'
```

**Result** (same structure on both nodes):

```
=== HCA devices ===
mlx5_0 mlx5_1 mlx5_2 mlx5_3 mlx5_4 mlx5_5 mlx5_6 mlx5_7

--- mlx5_0 ---
  port 1: state=4: ACTIVE link_layer=Ethernet
    GID[0]: fe80:0000:0000:0000:0000:03ff:feb9:c270  (IB/RoCE v1)
    GID[1]: fe80:0000:0000:0000:0000:03ff:feb9:c270  (RoCE v2)
    GID[2]: 0000:0000:0000:0000:0000:ffff:0a01:c006  (IB/RoCE v1)
    GID[3]: 0000:0000:0000:0000:0000:ffff:0a01:c006  (RoCE v2)      <-- NCCL needs this one
...
```

- **8 HCAs** per node (`mlx5_0`-`mlx5_7`): ConnectX-7 VFs, FW 28.39.3004
- All ports **ACTIVE**, link layer **Ethernet** (RoCE, not InfiniBand)
- **GID index 3** = RoCE v2 + IPv4-mapped address
- Each HCA has a unique cluster network IP (one per RDMA subnet)
- `node_type: 1: CA` (Channel Adapter) — RDMA-capable devices

> **Note**: `/dev/infiniband/uverbs*` devices are NOT present inside the MOFED container — the MOFED pod is the driver, not a consumer. The RDMA shared device plugin injects these devices into pods that request `rdma/rdma_mlx5: 1` in their resource limits.

### Step 2: Deploy NCCL Test Pods

Created a namespace with the multi-node SCC and deployed two pods (one per GPU node):

```bash
oc create namespace nccl-probe
oc create serviceaccount nccl-probe-sa -n nccl-probe
oc adm policy add-scc-to-user openshift-ai-llminferenceservice-multi-node-scc \
  -z nccl-probe-sa -n nccl-probe
```

```yaml
cat <<'EOF' | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: nccl-probe-h100
  namespace: nccl-probe
  labels:
    app: nccl-probe
spec:
  serviceAccountName: nccl-probe-sa
  nodeSelector:
    kubernetes.io/hostname: ocp-gpu-worker-h100
  containers:
  - name: nccl
    image: nvcr.io/nvidia/pytorch:24.12-py3
    command: ["sleep", "infinity"]
    resources:
      limits:
        nvidia.com/gpu: 1
        rdma/rdma_mlx5: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK", "SYS_RAWIO"]
    env:
    - name: NCCL_DEBUG
      value: "INFO"
    - name: NCCL_IB_DISABLE
      value: "0"
    - name: NCCL_IB_GID_INDEX
      value: "3"
    - name: NCCL_IB_TIMEOUT
      value: "23"
    - name: NCCL_IB_RETRY_CNT
      value: "7"
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
---
apiVersion: v1
kind: Pod
metadata:
  name: nccl-probe-h200
  namespace: nccl-probe
  labels:
    app: nccl-probe
spec:
  serviceAccountName: nccl-probe-sa
  nodeSelector:
    kubernetes.io/hostname: ocp-gpu-worker-h200-0
  containers:
  - name: nccl
    image: nvcr.io/nvidia/pytorch:24.12-py3
    command: ["sleep", "infinity"]
    resources:
      limits:
        nvidia.com/gpu: 1
        rdma/rdma_mlx5: 1
    securityContext:
      capabilities:
        add: ["IPC_LOCK", "SYS_RAWIO"]
    env:
    - name: NCCL_DEBUG
      value: "INFO"
    - name: NCCL_IB_DISABLE
      value: "0"
    - name: NCCL_IB_GID_INDEX
      value: "3"
    - name: NCCL_IB_TIMEOUT
      value: "23"
    - name: NCCL_IB_RETRY_CNT
      value: "7"
  restartPolicy: Never
  terminationGracePeriodSeconds: 5
EOF
```

The `nvcr.io/nvidia/pytorch:24.12-py3` image bundles `nccl-tests` at `/usr/local/bin/all_reduce_perf` — no build step required.

### Step 3: Single-Node NCCL Test (Passed)

First, verified that NCCL can initialize the IB plugin on a single node:

```bash
oc exec -it nccl-probe-h100 -n nccl-probe -- bash -c "
  export NCCL_DEBUG=INFO
  export NCCL_IB_DISABLE=0
  export NCCL_IB_GID_INDEX=3
  export NCCL_IB_TIMEOUT=23
  export NCCL_IB_RETRY_CNT=7
  export MASTER_ADDR=\$(hostname -i)
  export MASTER_PORT=29500
  export NCCL_SOCKET_IFNAME=eth0
  all_reduce_perf \
    -b 8 -e 128M -f 2 -g 1 \
    -n 20 \
    2>&1
"
```

**Result**: NCCL successfully discovered all 8 RoCE devices and initialized:

```
NCCL INFO NET/IB : Using [0]mlx5_0:1/RoCE [1]mlx5_1:1/RoCE [2]mlx5_2:1/RoCE [3]mlx5_3:1/RoCE [4]mlx5_4:1/RoCE [5]mlx5_5:1/RoCE [6]mlx5_6:1/RoCE [7]mlx5_7:1/RoCE
NCCL INFO Using network IBext_v8
NCCL INFO DMA-BUF is available on GPU device 0
NCCL INFO ncclCommInitAll comm ... rank 0 nranks 1 ... - Init COMPLETE
```

This looked promising — NCCL found RoCE, detected DMA-BUF for GPUDirect. But with only 1 rank, no cross-node QP connections were established.

### Step 4: Cross-Node NCCL Test (Failed)

This is the real test. Used PyTorch distributed to run a 2-rank all_reduce across H100 and H200.

**Terminal 1 — H100 (rank 0):**

```bash
oc exec -it nccl-probe-h100 -n nccl-probe -- bash -c "
  export NCCL_DEBUG=INFO
  export NCCL_IB_DISABLE=0
  export NCCL_IB_GID_INDEX=3
  export NCCL_IB_TIMEOUT=23
  export NCCL_IB_RETRY_CNT=7
  export NCCL_SOCKET_IFNAME=eth0
  export MASTER_ADDR=\$(hostname -i)
  export MASTER_PORT=29500
  echo \"MASTER_ADDR=\$MASTER_ADDR\"
  python3 -c '
import os, torch, torch.distributed as dist
os.environ[\"RANK\"] = \"0\"
os.environ[\"WORLD_SIZE\"] = \"2\"
dist.init_process_group(backend=\"nccl\")
device = torch.device(\"cuda:0\")
tensor = torch.ones(1024*1024, device=device)  # 4MB
for i in range(5):
    dist.all_reduce(tensor)
    torch.cuda.synchronize()
    print(f\"Round {i}: sum={tensor[0].item()}\")
dist.destroy_process_group()
print(\"SUCCESS: NCCL cross-node test passed\")
'
"
```

**Terminal 2 — H200 (rank 1):**

```bash
# Replace <MASTER_IP> with the IP printed in Terminal 1
oc exec -it nccl-probe-h200 -n nccl-probe -- bash -c "
  export NCCL_DEBUG=INFO
  export NCCL_IB_DISABLE=0
  export NCCL_IB_GID_INDEX=3
  export NCCL_IB_TIMEOUT=23
  export NCCL_IB_RETRY_CNT=7
  export NCCL_SOCKET_IFNAME=eth0
  export MASTER_ADDR=<MASTER_IP>
  export MASTER_PORT=29500
  python3 -c '
import os, torch, torch.distributed as dist
os.environ[\"RANK\"] = \"1\"
os.environ[\"WORLD_SIZE\"] = \"2\"
dist.init_process_group(backend=\"nccl\")
device = torch.device(\"cuda:0\")
tensor = torch.ones(1024*1024, device=device)  # 4MB
for i in range(5):
    dist.all_reduce(tensor)
    torch.cuda.synchronize()
    print(f\"Round {i}: sum={tensor[0].item()}\")
dist.destroy_process_group()
print(\"SUCCESS: NCCL cross-node test passed\")
'
"
```

**Result**: NCCL initialized the 2-rank communicator and selected RoCE with GPUDirect RDMA:

```
NCCL INFO comm ... rank 0 nRanks 2 nNodes 2 localRanks 1 localRank 0
NCCL INFO Channel 00/0 : 1[0] -> 0[0] [receive] via NET/IBext_v8/7/GDRDMA
NCCL INFO Channel 00/0 : 0[0] -> 1[0] [send] via NET/IBext_v8/7/GDRDMA
```

But then **failed** when trying to establish the cross-node QP connection:

```
ibvwrap.c:174 NCCL WARN Call to ibv_modify_qp failed with error No such device errno 19
```

### Step 5: Retry Without GPUDirect (Also Failed)

To rule out GPUDirect as the cause, we retried with `NCCL_NET_GDR_LEVEL=0` (forces NCCL to stage data through host memory instead of direct GPU-NIC transfers).

Same environment variables as Step 4, plus:

```bash
export NCCL_NET_GDR_LEVEL=0
```

**Result**: Channels now show `NET/IBext_v8/7` (no `GDRDMA` suffix), confirming GPUDirect was disabled. But the exact same failure:

```
ibvwrap.c:174 NCCL WARN Call to ibv_modify_qp failed with error No such device errno 19
```

The problem is at the QP connection level, not GPUDirect.

### Step 6: Clean Up

```bash
oc delete namespace nccl-probe
```

## Conclusion

### What Failed and Why

NCCL RoCE fails at `ibv_modify_qp` — the IB verb that transitions a Queue Pair from INIT to RTR (Ready-To-Receive) state. This is a fundamental step in establishing any RDMA connection between two machines. Without it, no data can flow over RDMA.

The VFs can create QPs locally, but cannot modify them to point at a remote node. It's like being able to build a phone but not being able to connect a call.

### IBM Cloud VF Limitation — Full Picture

Both UCX (Phase 8) and NCCL (Phase 9B) fail on these VFs, but at different points:

| Framework | IB Verb Used | Failure Point | Error |
|---|---|---|---|
| UCX RC (Phase 8) | RC QP + Active Messages | Transport init | "rc transport can't do active messages on VFs" |
| NCCL IB (Phase 9B) | RC QP + RDMA_WRITE_WITH_IMM | `ibv_modify_qp` | errno 19 ENODEV |

The VFs provide:
- Device discovery (8 HCAs, GID tables, sysfs)
- Local QP creation
- Single-node NCCL initialization with IB plugin

The VFs do NOT support:
- `ibv_modify_qp` for cross-node RC QP connections
- Active message delivery (UCX RC)

The limitation is at the IB verbs level — no software framework can work around it.

### Confirmed Transport Path

**TCP sockets (`NCCL_IB_DISABLE=1`) are the only viable NCCL transport on IBM Cloud cluster network VFs.**

| Transport | Bandwidth | Status |
|---|---|---|
| NVLink (intra-node) | ~900 GB/s | Working |
| RoCE via VFs | Up to 100 Gbps | **BLOCKED** — `ibv_modify_qp` fails |
| TCP sockets | 40-80 Gbps | **Working** — only viable cross-node path |

### Implications

- Phase 9's `NCCL_IB_DISABLE=1` was correct — it's the only option, not a conservative choice
- `deepep_high_throughput` / `deepep_low_latency` all-to-all backends will also fail (they need NVSHMEM/IBGDA which requires RDMA)
- `VLLM_ALL2ALL_BACKEND=naive` remains the only viable all-to-all backend
- To get true RDMA, IBM Cloud would need to expose PFs (`15b3:2344`) instead of VFs (`15b3:101e`)
