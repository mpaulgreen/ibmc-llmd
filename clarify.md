Now I have the exact facts. Here's the answer:                                                                                                                                                                                                      
                                                                                                                                                                                                                                                      
  P/D Disaggregation: YES, works with 1 H100 + 1 H200 (mixed GPUs)                                                                                                                                                                                    
                                                                                                                                                                                                                                                      
  From the guide:                                                                                                                                                                                                                                     
  - Hardware requirement: "8 Nvidia GPUs of any kind, and RDMA via InfiniBand or RoCE between all pods"                                                                                                                                               
  - Prefill and decode are separate vLLM instances (separate pods) — not one distributed job                                                                                                                                                          
  - Default config: 4x TP=1 prefill workers + 1x TP=4 decode worker = 8 GPUs total                                                                                                                                                                    
  - Model: openai/gpt-oss-120b                                                                                                                                                                                                                        
  - Since prefill and decode are independent pods, they can run on different GPU types. You could put prefill pods on H200 and decode pods on H100 (or all on one node)                                                                               
  - This fits on 1 H100 + 1 H200, or even a single 8-GPU node                                                                                                                                                                                         
                                                                                                                                                                                                                                                      
  Wide Expert-Parallelism: NO, cannot use mixed GPUs. Also requires 32 GPUs.

  From the guide:
  - Hardware requirement: "32 Nvidia H200 or B200 GPUs and InfiniBand or RoCE RDMA networking"
  - Validated on: 32xH200 (GKE), 32xH200 (IB), 32xB200 (GKE)
  - Deploys DeepSeek-R1-0528 with DP=16 prefill + DP=16 decode
  - Benchmark ran on 4x a4-highgpu-8g VMs (32 GPUs)
  - Critical requirement: "Every NIC on a host must be able to communicate with every NIC on all other hosts. Networks restricted to communicating only between matching NIC IDs (rail-only connectivity) will fail."
  - H100 is not listed as supported. Needs 32 H200 or B200 GPUs (4 nodes). Not feasible with your setup.

  Bottom line:
  - P/D Disaggregation — doable with your current 1 H100 + 1 H200 (or even single node)
  - Wide EP — not feasible. Needs 32 H200/B200 GPUs across 4 nodes. Way beyond current setup regardless of GPU mix



What the manifests configure:                                                                                                                                                                                                                       
                                                                                                                                                                                                                                                      
  ┌─────────────────────────────┬─────────────────────────┬────────┐                                                                                                                                                                                  
  │          Parameter          │         Prefill         │ Decode │                                                                                                                                                                                  
  ├─────────────────────────────┼─────────────────────────┼────────┤                                                                                                                                                                                  
  │ LWS replicas                │ 1                       │ 1      │                                                                                                                                                                                  
  ├─────────────────────────────┼─────────────────────────┼────────┤                                                                                                                                                                                  
  │ LWS size (pods per replica) │ 2                       │ 2      │                                                                                                                                                                                  
  ├─────────────────────────────┼─────────────────────────┼────────┤                                                                                                                                                                                  
  │ GPUs per pod                │ 8                       │ 8      │
  ├─────────────────────────────┼─────────────────────────┼────────┤
  │ DP_SIZE_LOCAL               │ 8                       │ 8      │
  ├─────────────────────────────┼─────────────────────────┼────────┤
  │ TP_SIZE                     │ 1                       │ 1      │
  ├─────────────────────────────┼─────────────────────────┼────────┤
  │ data-parallel-size          │ LWS_GROUP_SIZE × 8 = 16 │ 16     │
  ├─────────────────────────────┼─────────────────────────┼────────┤
  │ Total GPUs                  │ 16                      │ 16     │
  └─────────────────────────────┴─────────────────────────┴────────┘

  Grand total: 32 GPUs (4 nodes)

  The "wide" part is LWS size=2 — each worker type spans 2 nodes with EP=16 (8 local + 8 remote via RDMA all-to-all).

  Can you reduce to 2 nodes (16 GPUs)?

  The blocker is DeepSeek-R1-0528 model size, not the pattern:

  - DeepSeek-R1: ~671B params, ~1.34TB at bf16
  - With EP=16 (minimum to fit): each GPU holds dense layers (~60-80GB) + 1/16 of experts (~79GB) = ~139GB per GPU
  - H200 (141GB): barely fits
  - H100 (80GB): does not fit — model shard is 139GB

  So even with 2 nodes, the H100 cannot participate in wide EP for DeepSeek-R1. The per-GPU memory requirement exceeds 80GB.

  What WOULD work on 1 H100 + 1 H200 (16 GPUs):

  Use a smaller MoE model like Mixtral-8x22B (~282GB at bf16):
  - EP=8: ~35GB per GPU — fits on both H100 (80GB) and H200 (141GB)
  - Modify manifests: LWS size=1 per worker, prefill on one node, decode on the other
  - But this is P/D disaggregation with per-node EP, not true "wide EP" spanning nodes

  For true wide EP across 2 nodes with a smaller model:
  - Set LWS size=2, DP_SIZE_LOCAL=8, total EP=16
  - But both nodes need to run the same worker type (prefill OR decode), not one each
  - You'd need all 16 GPUs for one worker type — no room for the other

  Bottom line:

  ┌────────────────────────────────────────────────┬───────────────────────┬────────────────────────────────────────────────────────────┐
  │                    Scenario                    │      H100+H200?       │                           Notes                            │
  ├────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────────────────────┤
  │ Wide EP with DeepSeek-R1 (guide default)       │ No                    │ H100's 80GB too small for model shard                      │
  ├────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────────────────────┤
  │ Wide EP with smaller MoE (e.g., Mixtral-8x22B) │ Possible but modified │ Need to change model, parallelism, manifests significantly │
  ├────────────────────────────────────────────────┼───────────────────────┼────────────────────────────────────────────────────────────┤
  │ P/D disaggregation with EP per node            │ Yes                   │ Prefill on H200, decode on H100, EP=8 within each node     │
  └────────────────────────────────────────────────┴───────────────────────┴────────────────────────────────────────────────────────────┘

  The guide's 32 GPU requirement isn't just a benchmark preference — it's driven by DeepSeek-R1's model size. A smaller MoE model would let you validate the EP pattern on fewer GPUs, but it would be a custom configuration, not the guide as
  written.






  ------


  Config 1: Basic DP+EP with DeepEP High-Throughput

  File: llm-inference-service-dp-ep-deepseek-r1-gpu-deepep-ht.yaml

  - Purpose: Multi-node inference without P/D split — all pods do both prefill and decode
  - Parallelism: DP=32, DP_LOCAL=8, TP=1, EP=true
  - Pods: 4 pods (32/8=4), each with 8 GPUs → 32 GPUs total across 4 nodes
  - All2All backend: deepep_high_throughput
  - KV transfer: None (no P/D split)
  - Use case: Maximum throughput for batch workloads

  Config 2: Basic DP+EP Naive

  File: llm-inference-service-dp-ep-deepseek-r1-gpu-naive.yaml

  - Purpose: Same as Config 1 but likely using NCCL-based all-to-all instead of DeepEP
  - Parallelism: Similar DP+EP setup
  - Use case: Baseline comparison / compatibility with hardware that doesn't support DeepEP

  Config 3: P/D Disaggregation with DeepEP High-Throughput (both)

  File: llm-inference-service-dp-ep-deepseek-r1-pd-gpu-p-deepep-ht-d-deepep-ht.yaml

  - Purpose: Separate prefill and decode into independent pools
  - Decode pool (top-level spec): DP=16, DP_LOCAL=8, replicas=1 + worker → 2 pods × 8 GPUs = 16 GPUs
  - Prefill pool (spec.prefill): DP=16, DP_LOCAL=8, replicas=1 + worker → 2 pods × 8 GPUs = 16 GPUs
  - Total: 32 GPUs (4 nodes)
  - All2All backend: deepep_high_throughput for both prefill and decode
  - KV transfer: NIXL (NixlConnector) transfers KV cache from prefill → decode
  - EPP: P/D-aware scheduler with pd-profile-handler, prefill-filter, decode-filter
  - GPU memory: 0.99 (decode), 0.97 (prefill)
  - Use case: Lower inter-token latency by eliminating prefill interference on decode

  Config 4: P/D Disaggregation with Mixed Backends

  File: llm-inference-service-dp-ep-deepseek-r1-pd-gpu-p-deepep-ht-d-pplx.yaml

  - Purpose: Same P/D split as Config 3 but with different all-to-all backends optimized per role
  - Decode pool: pplx backend (optimized for low-latency token generation)
  - Prefill pool: deepep_high_throughput (optimized for batch throughput)
  - Total: 32 GPUs (4 nodes)
  - KV transfer: NIXL
  - Use case: Best of both worlds — high-throughput prefill + low-latency decode

  Summary Table

  ┌──────────────────────┬───────────┬──────────────────────────────┬──────┬───────┬────────────────────────┐
  │        Config        │ P/D Split │       All2All Backend        │ GPUs │ Nodes │      Key Benefit       │
  ├──────────────────────┼───────────┼──────────────────────────────┼──────┼───────┼────────────────────────┤
  │ 1. DP+EP (deepep_ht) │ No        │ deepep_high_throughput       │ 32   │ 4     │ Max throughput         │
  ├──────────────────────┼───────────┼──────────────────────────────┼──────┼───────┼────────────────────────┤
  │ 2. DP+EP (naive)     │ No        │ naive/nccl                   │ 32   │ 4     │ Baseline/compatibility │
  ├──────────────────────┼───────────┼──────────────────────────────┼──────┼───────┼────────────────────────┤
  │ 3. P/D (ht + ht)     │ Yes       │ deepep_ht (both)             │ 32   │ 4     │ Lower decode latency   │
  ├──────────────────────┼───────────┼──────────────────────────────┼──────┼───────┼────────────────────────┤
  │ 4. P/D (ht + pplx)   │ Yes       │ ht (prefill) + pplx (decode) │ 32   │ 4     │ Optimized per role     │
  └──────────────────────┴───────────┴──────────────────────────────┴──────┴───────┴────────────────────────┘

  All 4 use DeepSeek-R1-0528, EP=true, GPUDirect RDMA via NVSHMEM/IBGDA, and require 32 H200/B200 GPUs across 4 nodes. Configs 3-4 use spec.prefill in the LLMInferenceService CR, confirming that v1alpha1 supports P/D disaggregation natively.

❯ Which configuration are going to use for out purpose? 

⏺ For your setup (1 H100 + 1 H200 = 16 GPUs), none of the 4 configs work as-is (DeepSeek-R1 too large for H100). But we adapt Config 3 (P/D with same backend) pattern — it's the cleanest P/D disaggregation example.

  Our adapted config:

  ┌─────────────────┬──────────────────────────────┬─────────────────────────────────────┐
  │     Aspect      │     Config 3 (original)      │           Our adaptation            │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ Model           │ DeepSeek-R1-0528 (671B)      │ Qwen3-32B (32B)                     │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ Prefill node    │ 2 pods × 8 GPUs (H200)       │ 4 pods × 2 GPUs on H200             │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ Decode node     │ 2 pods × 8 GPUs (H200)       │ 4 pods × 2 GPUs on H100             │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ Parallelism     │ DP=16, EP=true, TP=1         │ TP=2, no EP (dense model)           │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ All2All backend │ deepep_high_throughput       │ Not needed (no EP)                  │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ KV transfer     │ NIXL (NixlConnector)         │ NIXL (NixlConnector) — same         │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ RDMA resource   │ rdma/roce_gdr                │ rdma/rdma_mlx5                      │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ EPP scheduler   │ pd-profile-handler           │ pd-profile-handler — same           │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ GPUDirect RDMA  │ Yes (NVSHMEM/IBGDA)          │ No (regular RDMA)                   │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ Total GPUs      │ 32                           │ 16                                  │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ CRD             │ LLMInferenceService v1alpha1 │ LLMInferenceService v1alpha1 — same │
  ├─────────────────┼──────────────────────────────┼─────────────────────────────────────┤
  │ spec.prefill    │ Yes                          │ Yes — same pattern                  │
  └─────────────────┴──────────────────────────────┴─────────────────────────────────────┘

  What stays the same (proves the concept):
  - spec.prefill field for separate prefill deployment
  - NIXL KV cache transfer between prefill and decode
  - P/D-aware EPP scheduler (pd-profile-handler, prefill-filter, decode-filter)
  - LLMInferenceService single CR approach

  What changes (hardware adaptation):
  - Smaller model (fits on H100's 80GB)
  - TP instead of EP (dense model, not MoE)
  - No NVSHMEM/DeepEP env vars (no expert parallelism)
  - Different RDMA resource name for IBM Cloud


----

Qwen3-32B is a dense model — every parameter is used for every token. It has one set of weights, and all GPUs process the same computation split via Tensor Parallelism (TP).
                                                                                                                                  
  DeepSeek-R1 is a Mixture-of-Experts (MoE) model — it has 256 specialized "expert" sub-networks. For each token, only ~8 experts are activated (out of 256). Expert Parallelism (EP) distributes these 256 experts across GPUs so each GPU only holds
   a fraction of them. The all2all backend (DeepEP) handles routing tokens to the correct GPU that holds the needed expert.                                                                                                                           
   
  ┌─────────────────────────┬───────────────────────────────┬──────────────────────────────────────┐                                                                                                                                                  
  │                         │    Dense model (Qwen3-32B)    │       MoE model (DeepSeek-R1)        │
  ├─────────────────────────┼───────────────────────────────┼──────────────────────────────────────┤
  │ Parameters              │ All used for every token      │ Only ~8/256 experts active per token │
  ├─────────────────────────┼───────────────────────────────┼──────────────────────────────────────┤
  │ Parallelism             │ TP — split layers across GPUs │ EP — split experts across GPUs       │
  ├─────────────────────────┼───────────────────────────────┼──────────────────────────────────────┤
  │ Cross-GPU communication │ NCCL (tensor shards)          │ All2All (route tokens to experts)    │
  ├─────────────────────────┼───────────────────────────────┼──────────────────────────────────────┤
  │ All2All backend needed? │ No                            │ Yes (deepep_ht, pplx, or nccl)       │
  ├─────────────────────────┼───────────────────────────────┼──────────────────────────────────────┤
  │ NVSHMEM needed?         │ No                            │ Yes (for DeepEP backends)            │
  └─────────────────────────┴───────────────────────────────┴──────────────────────────────────────┘

  Since Qwen3-32B has no experts, there's nothing to distribute via EP. We use TP=2 instead — each pair of GPUs splits the model's layers in half.

  The P/D disaggregation (prefill/decode split + NIXL KV transfer) works identically for both dense and MoE models — it's orthogonal to the parallelism strategy.