# kiln-chat —— NPU 上的交互式大模型

英文版:[CHAT.md](../CHAT.md)。

`kiln-chat` 是基于 `librkllmrt` 的终端聊天。打一句话,模型回复,token 边解码边流式输出;每轮打印
一行 `[bench]`(首 token 时间和解码 tok/s)。其余都是**斜杠命令**——以 `/` 开头的行。

输入行有光标编辑和历史(readline):退格、左右/Home/End、上下翻历史、正确的 UTF-8(中文能正常
编辑)。(构建时没有 libreadline 会退化成普通读行。)

它能跑任意 RKLLM `.rkllm` 模型;chat 模板和停止符按模型名自动选——**Llama-3**
(`<|start_header_id|>…<|eot_id|>`)vs **Qwen / ChatML**(`<|im_start|>…<|im_end|>`)——所以换
模型开箱即用。

> **小技巧:** 在提示符打一个单独的 **`/`** 回车,会弹出所有斜杠命令的箭头选单——不用记、也不用
> 先打 `/help` 去翻。

## 命令

| 命令 | 作用 |
|---|---|
| `/help` | 先显示当前状态,再列出命令 |
| `/status` | 只显示当前状态(模型、历史、轮数、system prompt) |
| `/clear` | 忘掉对话;保留 system prompt |
| `/new` | 开一个全新会话(清空 + 重置计数) |
| `/history [on\|off]` | 多轮记忆开/关;不带参数显示当前状态 |
| `/system [文本\|clear\|none]` | 显示 / 设置 / 清除 system prompt(会重置会话) |
| `/context` | 显示上下文窗口和会话计数 |
| `/compact` | 把对话总结进 system prompt 以释放上下文 |
| `/model [名字]` | 换模型;不带名字则用箭头键从列表选 |
| `/exit`, `/quit` | 退出 |

`/model` 不带参数会开箭头选单(上下移动、回车切换、`q` 取消),当前模型有标记。给名字
(`/model foo.rkllm`)则直接切、不弹菜单。stdin 不是终端时退化成按名字切换的纯列表。

## 各命令背后

斜杠命令是围绕同一个生成调用的分发层——不改变推理路径。闭源运行时实际支持的:

- **`/clear`、`/new`、`/history`、`/system`** 由运行时直接支撑。历史就是运行时自己的 KV cache:
  `/clear` 和 `/new` 调 `rkllm_clear_kv_cache`(保留或丢掉 system prompt),`/history` 切换每轮是否
  追加进去,`/system` 重新套用 chat 模板并清 KV 让新 prompt 干净生效。
- **`/model`** 重载运行时(`rkllm_destroy` + `rkllm_init`),所以切换要几秒。不带参数时列出当前模型
  旁边的 `.rkllm` 并标出正在用的。
- **`/context`** **天生是部分的**:运行时既不暴露实时 KV 用量也没有 tokenizer,所以它只报上下文窗口
  大小和能精确数的(轮数、模型生成的 token)。prompt 侧的 token 用量从 API 看不到。
- **`/compact`** 是**应用层近似**,不是运行时功能:运行时没有 KV 压缩,所以 `/compact` 让模型总结
  对话(多一次推理),把这条单行摘要折进 system prompt,再清 KV。质量受模型限制——连贯的模型
  (如 Llama-3.2)还行,弱模型可能总结得差。它不会失控:坏摘要仍会在 EOS / 角色停止符处停。摘要
  没用就 `/clear` 或 `/new` 重置。

`/rewind` 撤销故意没做:运行时没有能让它可靠的 KV 快照/恢复,硬造会改变推理路径。

## 持久化

`/model`、`/system`、`/history` 在你用时会**写 `/etc/kiln/config.ini`**(你会看到 `[saved to …]`),
所以模型、system prompt 和多轮设置重启后仍在。system prompt **默认为空**(模型中立);`/system clear`
清空并持久化。采样和其他 `[llm]` 字段直接在文件里改——或经 `sudo kiln-config` → LLM Settings——
见 [配置](CONFIG.md)。
