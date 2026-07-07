// Kiln: image classification on the RK3576 NPU via librknnrt (RKNN). The CNN
// control experiment next to kiln-chat's RKLLM matmul path.
//
// Now config-driven (kiln_vision.h + kiln_config.h): model / labels / top-N /
// NPU core mask / priority come from /etc/kiln/config.ini. The RKNN call
// sequence is unchanged -- it just lives in kiln_vision.h so kiln-serve reuses
// it too.
//
// Usage:
//   rknn_mobilenet <image.jpg>                     # model/labels from config
//   rknn_mobilenet <model.rknn> <image> [labels]   # explicit override (old form)
#define STB_IMAGE_IMPLEMENTATION
#include "kiln_vision.h"
#include "kiln_config.h"
#include <cstdio>
#include <string>

static bool ends_with(const std::string &s, const char *suf) {
    std::string t = suf;
    return s.size() >= t.size() && s.compare(s.size() - t.size(), t.size(), t) == 0;
}

int main(int argc, char **argv) {
    KilnConfig cfg;
    kiln::load(cfg);

    std::string image;
    // old form: <model.rknn> <image> [labels] overrides config
    if (argc >= 3 && ends_with(argv[1], ".rknn")) {
        cfg.vision_model = argv[1];
        image = argv[2];
        if (argc > 3) cfg.vision_labels = argv[3];
    } else {
        image = argc > 1 ? argv[1] : "/opt/models/test.jpg";
    }

    KilnVision v;
    if (v.init(cfg) != 0) { fprintf(stderr, "kiln-vision: %s\n", v.error()); return 1; }

    double ms = 0; std::string err;
    auto res = v.classify_file(image, cfg.vision_top_n, &ms, &err);
    if (res.empty() && !err.empty()) { fprintf(stderr, "kiln-vision: %s\n", err.c_str()); return 1; }

    printf("\ntop-%d  (NPU inference %.1f ms):\n", (int)res.size(), ms);
    for (size_t k = 0; k < res.size(); k++)
        printf("  %zu. [%4d] %-28s %.4f\n", k + 1, res[k].index, res[k].label.c_str(), res[k].score);
    printf("[bench] rknn inference: %.1f ms (%.1f fps)\n", ms, ms > 0 ? 1000.0 / ms : 0.0);
    return 0;
}
