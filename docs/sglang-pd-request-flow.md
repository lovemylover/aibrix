# AIBrix SGLang PD 端到端请求时序图

按一次 `POST /v1/chat/completions`（model=`llama2-7b-sglang`，sglang PD 路由）的真实日志还原。
对应 vLLM PD 请求时序图见 `request-flow-sequence.md`。

- request_id: `86e2928e-18a6-477f-8a95-35b3f0218223`
- 客户端：`curl http://localhost:8888/v1/chat/completions`
- prompt_tokens: 1, completion_tokens: 30 → total 31
- 总耗时 98.7 ms（vLLM PD 同条件 499 ms）

所有时间戳相对 t0 = `10:07:55.297350`（`gateway.go:450` 入口）。

## 时序图

```mermaid
sequenceDiagram
    autonumber
    participant C as curl / kubectl<br/>port-forward
    participant E as envoy-aibrix-system-aibrix-eg<br/>(envoy pod, 10.244.1.55)
    participant G as aibrix-gateway-plugins<br/>(ext-proc, 10.244.1.41)
    participant R as aibrix-redis-master<br/>(10.244.1.9:6379)
    participant P as prefill pod<br/>mock-llama2-7b-pd-sglang-roleset-t6w22-<br/>prefill-78c574-0 (10.244.1.62:8000)
    participant BP as bootstrap port 8998<br/>(prefill pod 内部)
    participant D as decode pod<br/>mock-llama2-7b-pd-sglang-roleset-t6w22-<br/>decode-7f4769-0 (10.244.1.63:8000)

    Note over C,E: Layer 1 — 客户端 → envoy
    C->>E: POST /v1/chat/completions<br/>{model:"llama2-7b-sglang", messages:[...]}<br/>x-request-id: 86e2928e-...

    Note over E,G: Layer 2 — envoy 经 ext-proc 委托给 gateway-plugins
    E->>G: gRPC stream (ext-proc, :50052)<br/>processing request (gateway.go:450)<br/>t = 0 ms

    Note over G,R: Layer 3a — PD 路由决策：查 Redis 选 prefill/decode
    G->>R: 读 prefix cache block 索引<br/>+ pod metric
    R-->>G: 候选 prefill + decode pod
    Note right of G: router.go:587 "selected prefill/decode pods"<br/>  prefill = mock-...-prefill-78c574-0 (10.244.1.62)<br/>  decode  = mock-...-decode-7f4769-0  (10.244.1.63)<br/>  llm_engine = sglang<br/>  prefill_score_policy = prefix_cache<br/>  decode_score_policy  = load_balancing<br/>  routing_time_taken = 1.4 ms<br/>(注: 第二次请求后 prefix cache cache hit,<br/> 路由快于第一次 8.5 ms)

    Note over G,P,D: Layer 3b — gateway-plugins 并发打 prefill + decode<br/>(sglang PD 特性: 不必等 prefill 完成)
    par gateway-plugins → prefill pod
        G->>P: POST http://10.244.1.62:8000/v1/chat/completions<br/>default.go:165 prefill_request_start<br/>outstanding_prefill_requests = 1
        Note over P: prefill pod 计算 KV cache<br/>(prompt_tokens=1)<br/>通过 bootstrap 协议<br/>监听 port 8998 等 decode 连入
        P-->>G: 200 OK (+ bootstrap metadata)<br/>prefill_time_taken = 53.2 ms<br/>default.go:280 prefill_request_end<br/>outstanding_prefill_requests = 0
    and gateway-plugins → decode pod (并发)
        G->>D: POST http://10.244.1.63:8000/v1/chat/completions<br/>gateway_req_body.go:230 request_start<br/>target_pod_ip = 10.244.1.63:8000<br/>(body 内含 prefill pod hint;<br/> sglang 走 bootstrap 自己拿 KV)
    end

    Note over P,BP,D: Layer 4 — sglang 引擎内部 bootstrap KV transfer<br/>(gateway-plugins 不参与, 无 kv_transfer_params 注入)
    D->>BP: bootstrap connect port 8998 (direct TCP)<br/>sglang 原生协议: 请求 KV cache
    BP-->>D: 返回 KV cache 数据<br/>(sglang 内部传输, 不经 envoy/gateway-plugins)
    Note over D: decode 继续 generate 30 tokens<br/>mock 中合并计为 ~45ms<br/>(日志里 decode_time_taken 未单独记,<br/> total - prefill ≈ 45ms)

    D-->>G: 200 OK<br/>{choices:[...], metrics:{mock_pod: "decode-7f4769-0", ...}}<br/>(无 kv_transfer_params 字段)<br/>gateway_rsp_body.go:413 request_end<br/>ttft = 98.7 ms<br/>total_time_taken = 98.7 ms

    G-->>E: ext-proc gRPC response

    Note over E,C: Layer 5 — envoy 把响应发回 curl
    E-->>C: HTTP 200<br/>{choices, metrics, usage}<br/>(无 kv_transfer_params)
```

## 关键时间分解（请求 `86e2928e-...`）

| 相对 t0 (ms) | 阶段 | 来源日志 |
|-------------|------|---------|
| 0 | gateway-plugins 收到 ext-proc 流 | `gateway.go:450` |
| 1.4 | PD 路由完成（pod 选定） | `router.go:587`<br/>`routing_time_taken=1.377ms` |
| 1.4 | prefill 请求 + decode 请求**同时**发出 | `default.go:165` + `gateway_req_body.go:230` |
| 54.6 | prefill 返回 53.2ms | `default.go:280 prefill_request_end`<br/>`prefill_time_taken=53.234ms` |
| 98.7 | decode 返回，请求结束 | `gateway_rsp_body.go:413 request_end`<br/>`ttft=98.684ms`<br/>`total_time_taken=98.749ms` |

**总链路 98.7ms**：prefill 53.2ms + 余下 ~45ms（decode 在内部等 prefill KV + 生成）。
注意 prefill 和 decode 是**并发**的，sglang decode 自己等 prefill 完成，所以总耗时 ≈ max(prefill, decode_kv_transfer+generate) ≈ 98.7ms，不是相加。

## 跟 vLLM PD 对比（同 prompt 同 max_tokens）

| 维度 | vLLM PD (`9ed804e7-...`) | SGLang PD (`86e2928e-...`) |
|------|---------------------------|----------------------------|
| 总耗时 | **499 ms** | **98.7 ms** ⚡ 5× faster |
| 路由决策 | 73.9 ms | 1.4 ms（首次 8.5ms，本次 Redis cache hit） |
| Prefill 时间 | 208.3 ms | 53.2 ms |
| Decode 时间 | 217 ms（含 KV transfer 等待） | ~45 ms（推断） |
| Prefill → Decode 模式 | **串行**：prefill 完才发 decode | **并发**：几乎同时发出 |
| KV transfer 机制 | SHFS connector (shared file system) | sglang bootstrap 协议 (port 8998) |
| 响应附加字段 | `kv_transfer_params {remote_host, remote_block_ids, ...}` | 无 |
| 日志关键事件 | `shfs.go:97 updated routing context with kv_transfer_params (SHFS)` | 无 |
| 引擎识别 | `llm_engine=vllm` | `llm_engine=sglang` |

## 涉及到的 pod 速查表

| 角色 | Pod 名称 | IP | 关键标签/注解 |
|------|---------|----|---------|
| Envoy 数据面 | `envoy-aibrix-system-aibrix-eg-903790dc-7ffb6c4f8b-2wbqx` | 10.244.1.55 | ext-proc → gateway-plugins |
| Gateway Plugins (active) | `aibrix-gateway-plugins-6bdc64876d-fxfwf` | 10.244.1.41 | 已服务请求 |
| Gateway Plugins (standby) | `aibrix-gateway-plugins-6bdc64876d-zf557` | - | HA 副本 |
| Redis | `aibrix-redis-master-67964b778f-5v266` | 10.244.1.9 | prefix cache + pod metric |
| **Prefill Pod (sglang)** | `mock-llama2-7b-pd-sglang-roleset-t6w22-prefill-78c574-0` | 10.244.1.62 | role=prefill<br/>`model.aibrix.ai/sglang-bootstrap-port=8998`<br/>`model.aibrix.ai/engine=sglang` |
| **Decode Pod (sglang)** | `mock-llama2-7b-pd-sglang-roleset-t6w22-decode-7f4769-0` | 10.244.1.63 | role=decode |

## 复盘要点

1. **sglang PD 比 vLLM PD 快 5×**：原因不在 mock 速度，而在 **prefill/decode 并发**。vLLM PD 必须串行因为 vLLM 通过 SHFS 共享文件，decode pod 需要等 prefill 写完 cache 才能开始；sglang 用 bootstrap 协议主动拉 KV cache，decode 可以早启动。

2. **gateway-plugins 对 sglang 更"轻"**：
   - vLLM PD：gateway-plugins 在响应里**注入** `kv_transfer_params`（remote_host/remote_port/block_ids 等），通过 `shfs.go` 路径
   - sglang PD：gateway-plugins 只选 pod 对，**不注入**任何 KV 元数据，sglang 引擎自己处理 bootstrap 协调

3. **bootstrap port 8998** 来自 StormService role 的 annotation `model.aibrix.ai/sglang-bootstrap-port`，gateway-plugins 不直接连这个端口——sglang decode pod 内部使用。如果改这个端口，gateway-plugins 不需要改代码。

4. **路由策略相同**：两者都用 `prefill_score_policy=prefix_cache` + `decode_score_policy=load_balancing`，差别只在引擎内部的 KV 实现。

5. **StormService roleset 的对应关系**：sglang PD 中，prefill 和 decode **必须来自同一 roleset**（这条请求里都是 `roleset-t6w22`），否则 bootstrap 协议会失败。这是 aibrix controller 通过 stormservice.spec.template 控制。

6. **响应中无 `kv_transfer_params`**：可以作为 sglang PD 路由的快速判别特征 —— 服务端响应没这个字段，就基本可以判定用的是 sglang（不是 vLLM）的 PD 路径。
