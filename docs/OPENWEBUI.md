# Open WebUI, LangChain & any OpenAI client

`kiln-serve` is an **OpenAI-compatible** HTTP API, so the whole OpenAI ecosystem points
at your board with **zero code changes** — just a different base URL. Pair it with
[**Open WebUI**](https://github.com/open-webui/open-webui) and you get a **ChatGPT-style
web page backed entirely by your board's NPU** — private, offline, no API keys.

The base URL is always **`http://<board-ip>:8080/v1`** (default port; set in
`[server]`). The API key is ignored — pass any non-empty string.

## 1. Start the server on the board

```sh
sudo kiln-config        # Server → host = 0.0.0.0 (all interfaces), then service → enable
# or, one-off:
kiln-serve --host 0.0.0.0 --port 8080
```

`host = 0.0.0.0` is important — `127.0.0.1` would only accept connections from the board
itself. Sanity-check from another machine on the LAN:

```sh
curl http://<board-ip>:8080/v1/models
```

## 2. Open WebUI (the ChatGPT-style web page)

Run Open WebUI with Docker — on **any machine on your LAN** (a PC, or the board itself if
it has the headroom) — and point it at the board:

```sh
docker run -d -p 3000:8080 \
  -e OPENAI_API_BASE_URL=http://<board-ip>:8080/v1 \
  -e OPENAI_API_KEY=kiln \
  -e ENABLE_OLLAMA_API=false \
  -v open-webui:/app/backend/data \
  --name open-webui ghcr.io/open-webui/open-webui:main
```

Open **http://localhost:3000**, create the first (local) account, and your board's model
appears in the model picker (its name comes from `GET /v1/models` — the `.rkllm`
filename). Chat streams token-by-token straight off the NPU.

> Already have Open WebUI running? Just add the connection in **Settings → Admin →
> Connections → OpenAI API**: URL `http://<board-ip>:8080/v1`, key `kiln`.

## 3. The `openai` Python SDK

```python
from openai import OpenAI
client = OpenAI(base_url="http://<board-ip>:8080/v1", api_key="kiln")

stream = client.chat.completions.create(
    model="kiln",                                   # any id; the box has one model
    messages=[{"role": "user", "content": "Say hi in one sentence."}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="", flush=True)
```

## 4. LangChain

```python
from langchain_openai import ChatOpenAI
llm = ChatOpenAI(base_url="http://<board-ip>:8080/v1", api_key="kiln", model="kiln")
print(llm.invoke("Give me one fun fact about Rockchip.").content)
```

Anything that speaks OpenAI chat completions works the same way: LlamaIndex, the Vercel
AI SDK, `llm` (Simon Willison's CLI), Continue.dev, etc. — set the base URL, use any key.

## 5. Plain `curl`

```sh
# list models
curl http://<board-ip>:8080/v1/models

# streaming chat (SSE)
curl -N http://<board-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}],"stream":true}'

# non-streaming
curl http://<board-ip>:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"hi"}]}'
```

## Endpoints

| method | path | notes |
|---|---|---|
| `GET`  | `/health` | liveness (`{"status":"ok"}`) |
| `GET`  | `/v1/models` | the loaded `.rkllm` model(s) |
| `POST` | `/v1/chat/completions` | OpenAI chat; `"stream": true` → SSE token stream |
| `POST` | `/v1/vision/classify` | **not** OpenAI-standard: POST an image (raw body or multipart `file=`), get top-N classes |
| `POST` | `/v1/vision/detect` | POST an image, get YOLO boxes (`?conf=` / `?iou=` to tune) |

```sh
curl http://<board-ip>:8080/v1/vision/classify --data-binary @cat.jpg
curl "http://<board-ip>:8080/v1/vision/detect?conf=0.25" --data-binary @street.jpg
```

## Notes & security

- **The API is unauthenticated and CORS is open (`*`)** — it's meant for a **trusted LAN**.
  Don't expose it to the internet directly; put it behind a reverse proxy (nginx/Caddy)
  that adds TLS + auth if you need remote access.
- The NPU is **single-tenant**: requests are serialized, so concurrent callers queue
  rather than run in parallel.
- `model` in the request is ignored (the box serves the one model it loaded) — send any
  id; use `GET /v1/models` for the real name.
- Vision-only boxes (e.g. RK3568, no `.rkllm`) answer `503` on `/v1/chat/completions` and
  still serve the vision endpoints.

See [SERVER.md](SERVER.md) for the server's config fields and the systemd unit.
