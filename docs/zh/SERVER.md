# kiln-serve —— NPU 上的 OpenAI 兼容大模型 API

英文版:[SERVER.md](../SERVER.md)。

`kiln-serve` 把跑在 RK3576 NPU 上的大模型放到一个 HTTP API 后面,说的是 OpenAI 的
`/v1/chat/completions` 协议,所以现成的 OpenAI 客户端(`openai` Python/JS SDK、LangChain、
`curl`、大多数聊天前端)指向板子就能直接用,不用改。它包装的是跟 `kiln-chat` 同一套
`librkllmrt` 调用(经 `kiln_llm.h`)——推理没有重实现——并读共享的 `/etc/kiln/config.ini`。

它是**单模型、单租户**服务:模型在启动时加载一次,请求被串行化(NPU 一次只跑一个生成)。
仅头文件依赖(`cpp-httplib` + `nlohmann/json`),无 Python、无额外运行时。

## 运行

```sh
kiln-serve                      # 从配置读 [server] host/port/model
kiln-serve --host 0.0.0.0 --port 8080 --model /opt/models/other.rkllm   # 覆盖
```

或作为服务(安装器装好但默认不启用):

```sh
sudo systemctl enable --now kiln-serve      # 现在启动 + 开机自启
sudo systemctl status kiln-serve
```

启动时它会**打印填好 IP 的连接串**(免得你去查板子地址):

```
kiln-serve: ready [chat+classify]. Listening on http://0.0.0.0:8080  (OpenAI /v1)
  -> Open WebUI / OpenAI:  OPENAI_API_BASE_URL=http://192.168.1.42:8080/v1   (API key: any)
  -> test:                 curl http://192.168.1.42:8080/v1/models
```

> **要点:** `[server] host` 必须是 `0.0.0.0` 才能从别的机器 / Open WebUI 连;`127.0.0.1`
> 只接受板子本机(`kiln-doctor` 会提醒)。接入教程见 [Open WebUI 与生态接入](OPENWEBUI.md)。

## 端点

| 方法 | 路径 | 说明 |
|---|---|---|
| `GET`  | `/health` | `{"status":"ok"}` |
| `GET`  | `/v1/models` | 列出加载模型旁边的 `.rkllm`(返回清理过的显示名) |
| `POST` | `/v1/chat/completions` | OpenAI 对话;`"stream": true` → SSE 流 |
| `POST` | `/v1/vision/classify` | 可选——图片 → top-N 类别(配了 `.rknn` 才有,否则 `503`) |
| `POST` | `/v1/vision/detect` | 可选——图片 → YOLO 框(`task=detect` 且配了检测器) |

每个请求**无状态**:每次把 OpenAI 的 `messages` 数组拍平成一条 ChatML prompt(客户端按 OpenAI
约定重发历史),所以多轮不需要服务端会话状态。

## curl

```sh
# 流式
curl -N http://<板子IP>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"stream":true,"messages":[{"role":"user","content":"用一句话解释 RK3576 NPU。"}]}'

# 视觉(自定义,非 OpenAI 形状)——POST 裸图字节
curl "http://<板子IP>:8080/v1/vision/classify?top_n=5" --data-binary @cat.jpg
```

## OpenAI SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://<板子IP>:8080/v1", api_key="kiln")
for chunk in client.chat.completions.create(
        model="kiln", messages=[{"role":"user","content":"你好"}], stream=True):
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## 配置

默认值来自 `/etc/kiln/config.ini` 的 `[server]` 和 `[llm]`——手动编辑(见 [配置](CONFIG.md))。
`[server].llm_model`(空 = 用 `[llm].model`)决定加载哪个 `.rkllm`;采样 / 上下文 / system prompt
来自 `[llm]`。

## 限制(实话)

- 一个进程一个模型(启动时加载)。换 `.rkllm` 要用 `--model` 重启或改配置。请求里的 `model`
  字段**被忽略**——响应始终报告实际加载的模型,没有热切换。
- 仅视觉模式:没加载 `.rkllm` 时(如 RK3568,或 LLM 路径错)服务照常起,提供
  `/v1/vision/classify`;`/v1/chat/completions` 返回 **503**。
- 一次一个生成(NPU 单租户);并发请求排队。
- 仅 HTTP(无 TLS)。需要 HTTPS/鉴权就放反向代理后面。
