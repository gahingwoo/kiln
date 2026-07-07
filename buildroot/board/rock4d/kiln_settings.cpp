// SPDX-License-Identifier: Apache-2.0
// kiln-settings -- one interactive editor for the whole Kiln stack. Reads and
// writes the unified /etc/kiln/config.ini (kiln_config.h), which kiln-chat,
// kiln-vision and kiln-serve all read. Plain line-based prompts (no ncurses):
// Enter keeps the current value; model fields offer a numbered pick from the
// model directory. Only fields the closed runtimes actually expose are here.
#include "kiln_config.h"
#include <cstdio>
#include <cstdlib>
#include <string>
#include <vector>
#include <iostream>
#include <dirent.h>

static std::string ask(const std::string &label, const std::string &cur) {
    printf("  %-18s [%s]: ", label.c_str(), cur.c_str());
    fflush(stdout);
    std::string line;
    if (!std::getline(std::cin, line)) return cur;
    line = kiln::trim(line);
    return line.empty() ? cur : line;
}
static int   ask_int(const std::string &l, int c)   { std::string s = ask(l, std::to_string(c)); return atoi(s.c_str()); }
static float ask_float(const std::string &l, float c){ char b[32]; snprintf(b, sizeof(b), "%g", c); std::string s = ask(l, b); return (float)atof(s.c_str()); }

static std::vector<std::string> scan(const std::string &dir, const std::string &ext) {
    std::vector<std::string> v;
    DIR *d = opendir(dir.c_str());
    if (!d) return v;
    for (dirent *e; (e = readdir(d));) {
        std::string n = e->d_name;
        if (n.size() > ext.size() && n.compare(n.size() - ext.size(), ext.size(), ext) == 0)
            v.push_back(dir + "/" + n);
    }
    closedir(d);
    return v;
}

// Model picker: list *.ext in the current model's directory, numbered; the user
// picks a number, types a full path, or presses Enter to keep the current one.
static std::string pick_model(const std::string &label, const std::string &cur, const std::string &ext) {
    std::string dir = cur.substr(0, cur.find_last_of('/'));
    if (dir.empty()) dir = "/opt/models";
    auto files = scan(dir, ext);
    printf("  %s (current: %s)\n", label.c_str(), cur.c_str());
    for (size_t i = 0; i < files.size(); i++)
        printf("    %zu) %s\n", i + 1, files[i].c_str());
    printf("    number to pick, a full path, or Enter to keep: ");
    fflush(stdout);
    std::string line;
    if (!std::getline(std::cin, line)) return cur;
    line = kiln::trim(line);
    if (line.empty()) return cur;
    char *end = nullptr;
    long n = strtol(line.c_str(), &end, 10);
    if (end && *end == 0 && n >= 1 && n <= (long)files.size()) return files[n - 1];
    return line;   // treated as a path
}

int main() {
    KilnConfig c;
    std::string path = kiln::config_path();
    bool existed = kiln::load(c, path);
    printf("=== Kiln settings === (%s%s)\n", path.c_str(), existed ? "" : " -- new, using defaults");
    printf("Press Enter to keep the shown value.\n");

    printf("\n[LLM]\n");
    c.llm_model           = pick_model("model (.rkllm)", c.llm_model, ".rkllm");
    c.llm_system_prompt   = ask("system_prompt", c.llm_system_prompt);
    c.llm_max_context_len = ask_int("max_context_len", c.llm_max_context_len);
    c.llm_max_new_tokens  = ask_int("max_new_tokens", c.llm_max_new_tokens);
    c.llm_temperature     = ask_float("temperature", c.llm_temperature);
    c.llm_top_k           = ask_int("top_k", c.llm_top_k);
    c.llm_top_p           = ask_float("top_p", c.llm_top_p);
    c.llm_repeat_penalty  = ask_float("repeat_penalty", c.llm_repeat_penalty);
    c.llm_frequency_penalty = ask_float("frequency_penalty", c.llm_frequency_penalty);
    c.llm_presence_penalty  = ask_float("presence_penalty", c.llm_presence_penalty);
    c.llm_keep_history    = ask_int("keep_history (1 multi-turn / 0 single)", c.llm_keep_history) ? 1 : 0;
    c.llm_n_keep          = ask_int("n_keep (-1 default)", c.llm_n_keep);
    c.llm_embed_flash     = ask_int("embed_flash (0/1)", c.llm_embed_flash) ? 1 : 0;

    printf("\n[Vision]\n");
    c.vision_model    = pick_model("model (.rknn)", c.vision_model, ".rknn");
    c.vision_labels   = ask("labels", c.vision_labels);
    c.vision_top_n    = ask_int("top_n", c.vision_top_n);
    c.vision_core_mask= ask("core_mask (auto|0|1|0_1)", c.vision_core_mask);
    c.vision_priority = ask("priority (high|medium|low)", c.vision_priority);

    printf("\n[API server]\n");
    c.server_host = ask("host", c.server_host);
    c.server_port = ask_int("port", c.server_port);
    c.server_llm_model    = ask("llm_model (blank=use [llm])", c.server_llm_model);
    c.server_vision_model = ask("vision_model (blank=use [vision])", c.server_vision_model);

    if (!kiln::save(c, path)) {
        fprintf(stderr, "kiln-settings: could not write %s (try sudo)\n", path.c_str());
        return 1;
    }
    printf("\nSaved %s\n", path.c_str());

    // Optional: kiln-serve autostart via systemd.
    std::string ans = ask("Enable kiln-serve on boot? (yes/no/skip)", "skip");
    if (ans == "yes" || ans == "y")
        (void)!system("systemctl enable --now kiln-serve 2>/dev/null && echo '  kiln-serve enabled + started' || echo '  (systemctl failed; run as root)'");
    else if (ans == "no" || ans == "n")
        (void)!system("systemctl disable --now kiln-serve 2>/dev/null && echo '  kiln-serve disabled' || true");

    printf("Done. kiln-chat / kiln-vision / kiln-serve now use these settings.\n");
    return 0;
}
