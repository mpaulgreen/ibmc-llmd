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