# kiln-chat — interactive LLM on the NPU

`kiln-chat` is a terminal chat over `librkllmrt`. Type a message and the model
replies, streaming tokens as they decode; each turn prints a `[bench]` line
(time-to-first-token and decode tok/s). Everything else is a **slash command** —
a line starting with `/`.

Config comes from `/etc/kiln/config.ini` (`[llm]` section); the commands below
change the running session, and some mirror config fields so you can try a value
before writing it to the file.

## Commands

| command | what it does |
|---|---|
| `/help` | show current state, then list the commands |
| `/status` | show current state only (model, history, turns, system prompt) |
| `/clear` | forget the conversation; keep the system prompt |
| `/new` | start a fresh session (clear + reset counters) |
| `/history [on\|off]` | multi-turn memory on/off; no argument shows the current state |
| `/system [text]` | show the system prompt, or set it (resets the session) |
| `/context` | show the context window and session counters |
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

Two commands are deliberately absent. A `/compact` (summarize-to-free-context)
was tried and removed: the runtime has no KV compaction, so the only place to
put a summary back is the system prompt, and on a small model that makes it
recite the prompt and never stop -- a broken feature is worse than none. A
`/rewind` undo is absent for the same class of reason: there is no KV
snapshot/restore that would make it reliable. Both need runtime support (or a
larger model) that is not there today. To shorten a long chat, use `/clear` or
`/new`.

## Persisting changes

`/model`, `/system` and `/history` affect the current run only. To keep a choice
across restarts, set the matching field in `/etc/kiln/config.ini`
(`model`, `system_prompt`, `keep_history`) — see [`CONFIG.md`](CONFIG.md).
