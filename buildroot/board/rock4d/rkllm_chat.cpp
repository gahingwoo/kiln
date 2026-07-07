// Kiln: interactive chat with an LLM on the RK3576 NPU (librkllmrt).
//
// Now config-driven (kiln_llm.h + kiln_config.h): model, context, sampling,
// system prompt and KV-cache history come from /etc/kiln/config.ini. The RKLLM
// call sequence is unchanged -- it lives in kiln_llm.h so kiln-serve reuses it.
//
// Usage:
//   rkllm_chat                                  # all from config
//   rkllm_chat <model.rkllm> [new_tokens] [ctx] # explicit override (old form)
#include "kiln_llm.h"
#include "kiln_config.h"
#include <cstdio>
#include <string>
#include <iostream>
#include <chrono>
#include <csignal>

static KilnLLM *g_llm = nullptr;
static void on_sigint(int) { printf("\nExiting ...\n"); if (g_llm) { /* destructor releases */ } exit(0); }

int main(int argc, char **argv) {
    KilnConfig cfg;
    kiln::load(cfg);
    // old form: <model> [max_new_tokens] [max_context_len] overrides config
    if (argc > 1) cfg.llm_model = argv[1];
    if (argc > 2) cfg.llm_max_new_tokens = atoi(argv[2]);
    if (argc > 3) cfg.llm_max_context_len = atoi(argv[3]);

    signal(SIGINT, on_sigint);
    printf("rkllm init start\n");

    KilnLLM llm;
    g_llm = &llm;
    if (llm.init(cfg) != 0) { printf("rkllm init failed\n"); return -1; }
    printf("rkllm init success\n");

    printf("=== Kiln RK3576 NPU LLM (librkllmrt) ===\n");
    printf("model: %s | history: %s\n", cfg.llm_model.c_str(),
           cfg.llm_keep_history ? "multi-turn" : "single-turn");
    printf("Type your question at 'user:'. 'clear' resets KV, 'exit' quits.\n");

    while (true) {
        std::string input;
        printf("\nuser: ");
        if (!std::getline(std::cin, input)) break;
        if (input == "exit") break;
        if (input == "clear") { llm.clear_kv_cache(1); printf("[kv cache cleared]\n"); continue; }

        printf("robot: ");
        fflush(stdout);

        // KILN benchmark: time-to-first-token + decode tok/s per turn.
        auto t0 = std::chrono::steady_clock::now();
        double ttft = -1.0;
        long ntok = 0;
        KilnRunCtx ctx;
        ctx.on_token = [&](const char *tok) {
            if (ntok == 0)
                ttft = std::chrono::duration<double, std::milli>(
                           std::chrono::steady_clock::now() - t0).count();
            ntok++;
            printf("%s", tok);
            fflush(stdout);
        };
        try {
            llm.run(input, cfg.llm_keep_history != 0, ctx);
        } catch (const std::exception &e) {
            printf("\n[error] generation failed: %s -- try rephrasing.\n", e.what());
            continue;
        } catch (...) {
            printf("\n[error] generation failed (unknown) -- try rephrasing.\n");
            continue;
        }
        double total = std::chrono::duration<double, std::milli>(
                           std::chrono::steady_clock::now() - t0).count();
        double decode_ms = total - (ttft < 0 ? 0 : ttft);
        double tps = (ntok > 1 && decode_ms > 0) ? (ntok - 1) * 1000.0 / decode_ms : 0.0;
        printf("\n[bench] tokens=%ld  prefill(TTFT)=%.0f ms  decode=%.1f tok/s  total=%.0f ms\n",
               ntok, ttft < 0 ? 0.0 : ttft, tps, total);
    }
    return 0;
}
