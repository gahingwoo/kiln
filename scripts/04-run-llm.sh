#!/usr/bin/env bash
# Stage 4: run an LLM on the NPU via librkllmrt.
#   - librkllmrt version must match the driver (v0.9.8-era, e.g. rkllm-runtime 1.1.x/1.2.x/1.3.x)
#   - model must be converted for rk3576 (num_npu_core=2)
set -euo pipefail
MODEL="${1:?usage: 04-run-llm.sh model_rk3576.rkllm [max_new_tokens] [max_ctx]}"
MAXNEW="${2:-512}"; MAXCTX="${3:-1024}"
export LD_LIBRARY_PATH="${RKLLM_LIB:-./lib}:${LD_LIBRARY_PATH:-}"
ulimit -HSn 10240 || true
echo "[kiln] running LLM on NPU: $MODEL"
taskset f0 ./llm_demo "$MODEL" "$MAXNEW" "$MAXCTX"
