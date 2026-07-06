// Copyright (c) 2024 by Rockchip Electronics Co., Ltd. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <string.h>
#include <unistd.h>
#include <string>
#include "rkllm.h"
#include <fstream>
#include <iostream>
#include <csignal>
#include <vector>
#include <chrono>
#include <stdexcept>


using namespace std;
LLMHandle llmHandle = nullptr;

/* KILN benchmark: wall-clock prefill (time-to-first-token) + decode tok/s. */
static std::chrono::steady_clock::time_point g_bench_start;
static double g_bench_ttft_ms = -1.0;
static long   g_bench_ntok = 0;
static bool   g_bench_on = false;

static double kiln_ms_since(std::chrono::steady_clock::time_point t0)
{
    return std::chrono::duration<double, std::milli>(
               std::chrono::steady_clock::now() - t0).count();
}

void exit_handler(int signal)
{
    if (llmHandle != nullptr)
    {
        {
            cout << "Exiting ..." << endl;
            LLMHandle _tmp = llmHandle;
            llmHandle = nullptr;
            rkllm_destroy(_tmp);
        }
    }
    exit(signal);
}

void callback(RKLLMResult *result, void *userdata, LLMCallState state)
{
    if (state == RKLLM_RUN_FINISH)
    {
        printf("\n");
        if (g_bench_on) {
            double total_ms = kiln_ms_since(g_bench_start);
            double decode_ms = total_ms - (g_bench_ttft_ms < 0 ? 0 : g_bench_ttft_ms);
            double decode_tps = (g_bench_ntok > 1 && decode_ms > 0)
                                    ? (g_bench_ntok - 1) * 1000.0 / decode_ms : 0.0;
            printf("[bench] tokens=%ld  prefill(TTFT)=%.0f ms  decode=%.1f tok/s  total=%.0f ms\n",
                   g_bench_ntok, g_bench_ttft_ms < 0 ? 0.0 : g_bench_ttft_ms,
                   decode_tps, total_ms);
        }
    } else if (state == RKLLM_RUN_ERROR) {
        printf("\\run error\n");
    } else if (state == RKLLM_RUN_NORMAL) {
        if (g_bench_on) {
            if (g_bench_ntok == 0)
                g_bench_ttft_ms = kiln_ms_since(g_bench_start);
            g_bench_ntok++;
        }
        /* ================================================================================================================
        若使用GET_LAST_HIDDEN_LAYER功能,callback接口会回传内存指针:last_hidden_layer,token数量:num_tokens与隐藏层大小:embd_size
        通过这三个参数可以取得last_hidden_layer中的数据
        注:需要在当前callback中获取,若未及时获取,下一次callback会将该指针释放
        ===============================================================================================================*/
        if (result->last_hidden_layer.embd_size != 0 && result->last_hidden_layer.num_tokens != 0) {
            int data_size = result->last_hidden_layer.embd_size * result->last_hidden_layer.num_tokens * sizeof(float);
            printf("\ndata_size:%d",data_size);
            std::ofstream outFile("last_hidden_layer.bin", std::ios::binary);
            if (outFile.is_open()) {
                outFile.write(reinterpret_cast<const char*>(result->last_hidden_layer.hidden_states), data_size);
                outFile.close();
                std::cout << "Data saved to output.bin successfully!" << std::endl;
            } else {
                std::cerr << "Failed to open the file for writing!" << std::endl;
            }
        }
        printf("%s", result->text);
    }
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        std::cerr << "Usage: " << argv[0] << " model_path max_new_tokens max_context_len\n";
        return 1;
    }

    signal(SIGINT, exit_handler);
    printf("rkllm init start\n");

    //设置参数及初始化
    RKLLMParam param = rkllm_createDefaultParam();
    param.model_path = argv[1];

    //设置采样参数
    param.top_k = 1;
    param.top_p = 0.95;
    param.temperature = 0.8;
    param.repeat_penalty = 1.1;
    param.frequency_penalty = 0.0;
    param.presence_penalty = 0.0;

    param.max_new_tokens = std::atoi(argv[2]);
    param.max_context_len = std::atoi(argv[3]);
    param.skip_special_token = true;
    param.extend_param.base_domain_id = 0;
    param.extend_param.embed_flash = 1;

    int ret = rkllm_init(&llmHandle, &param, callback);
    if (ret == 0){
        printf("rkllm init success\n");
    } else {
        printf("rkllm init failed\n");
        exit_handler(-1);
    }


    RKLLMInput rkllm_input;

    // 初始化 infer 参数结构体
    RKLLMInferParam rkllm_infer_params;
    memset(&rkllm_infer_params, 0, sizeof(RKLLMInferParam));  // 将所有内容初始化为 0

    // 1. 初始化并设置 LoRA 参数（如果需要使用 LoRA）
    // RKLLMLoraAdapter lora_adapter;
    // memset(&lora_adapter, 0, sizeof(RKLLMLoraAdapter));
    // lora_adapter.lora_adapter_path = "qwen0.5b_fp16_lora.rkllm";
    // lora_adapter.lora_adapter_name = "test";
    // lora_adapter.scale = 1.0;
    // ret = rkllm_load_lora(llmHandle, &lora_adapter);
    // if (ret != 0) {
    //     printf("\nload lora failed\n");
    // }

    // 加载第二个lora
    // lora_adapter.lora_adapter_path = "Qwen2-0.5B-Instruct-all-rank8-F16-LoRA.gguf";
    // lora_adapter.lora_adapter_name = "knowledge_old";
    // lora_adapter.scale = 1.0;
    // ret = rkllm_load_lora(llmHandle, &lora_adapter);
    // if (ret != 0) {
    //     printf("\nload lora failed\n");
    // }

    // RKLLMLoraParam lora_params;
    // lora_params.lora_adapter_name = "test";  // 指定用于推理的 lora 名称
    // rkllm_infer_params.lora_params = &lora_params;

    // 2. 初始化并设置 Prompt Cache 参数（如果需要使用 prompt cache）
    // RKLLMPromptCacheParam prompt_cache_params;
    // prompt_cache_params.save_prompt_cache = true;                  // 是否保存 prompt cache
    // prompt_cache_params.prompt_cache_path = "./prompt_cache.bin";  // 若需要保存prompt cache, 指定 cache 文件路径
    // rkllm_infer_params.prompt_cache_params = &prompt_cache_params;
    
    // rkllm_load_prompt_cache(llmHandle, "./prompt_cache.bin"); // 加载缓存的cache

    rkllm_infer_params.mode = RKLLM_INFER_GENERATE;
    // By default, the chat operates in single-turn mode (no context retention)
    // 0 means no history is retained, each query is independent
    rkllm_infer_params.keep_history = 0;

    //The model has a built-in chat template by default, which defines how prompts are formatted  
    //for conversation. Users can modify this template using this function to customize the  
    //system prompt, prefix, and postfix according to their needs.  
    // Qwen2.5 ChatML template + identity system prompt (an empty system prompt
    // makes Qwen2.5 misidentify itself, e.g. "developed by OpenAI"; the DeepSeek
    // <｜User｜>/<｜Assistant｜> markers are also wrong for Qwen).
    rkllm_set_chat_template(
        llmHandle,
        "<|im_start|>system\nYou are Qwen, created by Alibaba Cloud. You are a helpful assistant. Always reply in the same language the user writes in.<|im_end|>\n",
        "<|im_start|>user\n",
        "<|im_end|>\n<|im_start|>assistant\n");
    
    while (true)
    {
        std::string input_str;
        printf("\n");
        printf("user: ");
        std::getline(std::cin, input_str);
        if (input_str == "exit")
        {
            break;
        }
        if (input_str == "clear")
        {
            ret = rkllm_clear_kv_cache(llmHandle, 1);
            if (ret != 0)
            {
                printf("clear kv cache failed!\n");
            }
            continue;
        }
        rkllm_input.input_type = RKLLM_INPUT_PROMPT;
        rkllm_input.prompt_input = (char *)input_str.c_str();
        printf("robot: ");

        // KILN benchmark: reset counters and start the wall clock for this turn.
        g_bench_on = true;
        g_bench_ntok = 0;
        g_bench_ttft_ms = -1.0;
        g_bench_start = std::chrono::steady_clock::now();

        // The tokenizer can throw std::invalid_argument("invalid character") on
        // some inputs / bad decodes; catch it so one bad turn doesn't abort the
        // whole chat -- just report and keep going.
        try {
            rkllm_run(llmHandle, &rkllm_input, &rkllm_infer_params, NULL);
        } catch (const std::exception &e) {
            printf("\n[error] generation failed: %s -- try rephrasing.\n", e.what());
        } catch (...) {
            printf("\n[error] generation failed (unknown) -- try rephrasing.\n");
        }
    }
    rkllm_destroy(llmHandle);

    return 0;
}