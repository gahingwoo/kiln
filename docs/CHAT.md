# kiln-chat — interactive LLM on the NPU

`kiln-chat` is a terminal chat over `librkllmrt`. Type a message and the model
replies, streaming tokens as they decode; each turn prints a `[bench]` line
(time-to-first-token and decode tok/s). Everything else is a **slash command** —
a line starting with `/`.

The input line has cursor editing and history (via readline): backspace, left/
right/Home/End, up/down to recall earlier prompts, and correct UTF-8 so non-ASCII
input edits properly. (Without libreadline at build it falls back to a plain read.)

It runs any RKLLM `.rkllm` model; the chat template and stop tokens are picked
from the model name — **Llama-3** (`<|start_header_id|>…<|eot_id|>`) vs
**Qwen / ChatML** (`<|im_start|>…<|im_end|>`) — so switching models Just Works.

Config comes from `/etc/kiln/config.ini` (`[llm]` section); the commands below
change the running session, and the sticky ones write it back so the choice
survives a restart.

## Commands

| command | what it does |
|---|---|
| `/help` | show current state, then list the commands |
| `/status` | show current state only (model, history, turns, system prompt) |
| `/clear` | forget the conversation; keep the system prompt |
| `/new` | start a fresh session (clear + reset counters) |
| `/history [on\|off]` | multi-turn memory on/off; no argument shows the current state |
| `/system [text\|clear\|none]` | show, set, or clear (`clear`/`none`) the system prompt (resets the session) |
| `/context` | show the context window and session counters |
| `/compact` | summarize the conversation into the system prompt to free up context |
| `/model [name]` | switch model; with no name, pick from a list with the arrow keys |
| `/exit`, `/quit` | leave |

`/help` and `/status` print the live state first, e.g. `model: qwen... | history: on
| turns: 3`, so you can see where the session stands at a glance.

`/model` with no argument opens an arrow-key picker (up/down to move, Enter to
switch, `q` to cancel); the current model is marked. Give a name (`/model foo.rkllm`)
to switch without the menu. When stdin is not a terminal it falls back to a plain
list you switch by name.

## How each is backed

Slash commands are a dispatch layer around the same generation call — they do
not change the inference path. What the closed runtime actually supports:

- **`/clear`, `/new`, `/history`, `/system`** are backed directly by the
  runtime. History is the runtime's own KV cache: `/clear` and `/new` call
  `rkllm_clear_kv_cache` (keeping or dropping the system prompt), `/history`
  toggles whether each turn is appended to it, and `/system` re-applies the chat
  template and clears the KV so the new system prompt takes effect cleanly.
- **`/model`** reloads the runtime (`rkllm_destroy` + `rkllm_init`), so a switch
  takes a few seconds. With no argument it lists `.rkllm` files next to the
  current model and marks the active one.
- **`/context`** is **partial by necessity**: the runtime exposes neither live
  KV usage nor a tokenizer, so it reports the context window size and what can be
  counted exactly (turns and tokens the model generated). Prompt-side token usage
  is not observable from the API.

- **`/compact`** is an **application-level approximation**, not a runtime feature:
  the runtime has no KV compaction, so `/compact` asks the model to summarize the
  conversation (one extra inference) and folds that single-line summary into the
  system prompt, then clears the KV. Quality is bounded by the model — it works
  acceptably on a coherent model (e.g. Llama-3.2) but a weak one may summarize
  poorly. It can no longer run away: a bad summary still stops on the EOS token /
  role-label stop sequence. If a summary is unhelpful, `/clear` or `/new` reset.

A `/rewind` undo is deliberately absent: the runtime has no KV snapshot/restore
that would make it reliable, and faking it would change the inference path.

## Persisting changes

`/model`, `/system` and `/history` **write `/etc/kiln/config.ini`** when you use
them (you'll see `[saved to …]`), so the model, system prompt, and multi-turn
setting survive a restart. The system prompt is **empty by default** (model-neutral);
`/system clear` blanks it and persists that. Sampling and the other `[llm]` fields
are edited in the file directly — or via `sudo kiln-config` → LLM Settings — see
[`CONFIG.md`](CONFIG.md).
