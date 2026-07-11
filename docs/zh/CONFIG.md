# Kiln 配置

英文版:[CONFIG.md](../CONFIG.md)。

Kiln 只有一个配置文件 `/etc/kiln/config.ini`,**每个**工具都读它——`kiln-chat`、`kiln-vision`、
`kiln-serve`,以及 `kiln-config`、`kiln-doctor`。没有按工具硬编码。`kiln-install.sh` 会种一个能用的
默认,所以新板子不动它也能跑。

## 怎么编辑

它始终是**可手改**的纯 INI 文件——这是唯一真源。两个可选前端:

- **`sudo kiln-config`** —— whiptail TUI(LLM / Vision / Server 页)。它**就地**编辑文件,保留你的
  注释和未知字段;`<Save>` 写入、`<Back>` 丢弃。见 [工具](TOOLS.md)。
- **`kiln-doctor`** —— 读文件,检查引用的模型存在且版本匹配,连同驱动/MMU 健康检查。

`kiln-chat` 也能现场改几个 LLM 旋钮并持久化(见 [对话](CHAT.md))。

## 哪些可设、哪些不可

两个运行时是闭源 blob;**只有运行时 API 真正暴露的字段在这里**。转换时烤进模型的东西不是设置。

### `[llm]` —— librkllmrt

| 键 | 含义 |
|---|---|
| `model` | `.rkllm` 路径——**默认为空**;工具随后自动发现 `/opt/models` 里任意 `*.rkllm`。填路径可钉死一个。 |
| `system_prompt` | system 消息内容(套进模型的 ChatML 标记) |
| `max_context_len` | 上下文窗口(token) |
| `max_new_tokens` | 每轮最多生成的 token |
| `temperature`, `top_k`, `top_p` | 采样 |
| `repeat_penalty`, `frequency_penalty`, `presence_penalty` | 重复控制 |
| `keep_history` | `1` = 多轮(保留 KV cache),`0` = 单轮 |
| `n_keep` | 上下文窗口滑动时保留的 KV token;`-1` = 运行时默认 |
| `embed_flash` | `1` = 从 flash 流式取词嵌入,`0` = 内存 |

量化/精度在转换时烤进 `.rkllm`——不可设。

### `[vision]` —— librknnrt

| 键 | 含义 |
|---|---|
| `model` | `.rknn` 路径——**默认为空** = 自动发现 `/opt/models` 里任意 `*.rknn`(一个 `.rknn` 可能是分类器也可能是检测器,有多个时按 task 钉对) |
| `labels` | 类别标签文本(每行一个) |
| `top_n` | 打印/返回多少类(分类) |
| `core_mask` | NPU 核:`auto` \| `0` \| `1` \| `0_1`(RK3576 有 2 核) |
| `priority` | RKNN 调度优先级:`high` \| `medium` \| `low` |
| `task` | `classify`(默认,MobileNet)或 `detect`(YOLO)。检测已在板上验证(YOLOv8n),但较新、测的模型少;导出要**关 NMS**。`kiln-convert yolov8n` 能现构建一个。见 [视觉](VISION.md) |
| `detector` | 检测家族:`auto` \| `yolov8` \| `yolov5` \| `yolox` \| `yoloraw`(pre-NMS `[1,N,4+ncls]`,如 YOLO26/v10 `nms=False`)\| `end2end`(NMS 内置——会崩 NPU,避免);仅 `task=detect` 用 |
| `conf_threshold`, `nms_iou` | 检测分数 / NMS-IoU 阈值(仅 `task=detect`) |

**不可设(烤进 `.rknn`):** 输入尺寸/布局和 mean/std 归一化——运行时在转换时烤进,Kiln 只查询、不配置。

### `[server]` —— kiln-serve

| 键 | 含义 |
|---|---|
| `host`, `port` | 监听地址(`0.0.0.0` 才能从别的机器连) |
| `llm_model` | 服务加载的 `.rkllm`;空 = 用 `[llm].model` |
| `vision_model` | `/v1/vision/*` 用的 `.rknn`;空 = 用 `[vision].model` |

## 示例

```ini
[llm]
model =                   # 空 = 自动发现 /opt/models 里任意 *.rkllm
max_context_len = 2048
temperature = 0.8
keep_history = 1          # 1 = 多轮(默认),0 = 单轮
system_prompt = You are a helpful assistant.

[vision]
model =
labels = /opt/models/imagenet_labels.txt
top_n = 5

[server]
host = 0.0.0.0
port = 8080
```

工具在**没有**配置文件时也能跑(内置默认),所以文件还没写就能用;`kiln-install.sh` 会种一个默认。
