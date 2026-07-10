// SPDX-License-Identifier: Apache-2.0
// kiln_vision.h -- thin wrapper around librknnrt used by both kiln-vision (CLI)
// and kiln-serve's optional /v1/vision/classify. Same RKNN sequence as the
// original rknn_mobilenet.cpp (rknn_init -> query attrs -> inputs_set -> run ->
// outputs_get -> top-N), driven from KilnConfig.
//
// Runtime-settable (real, from rknn_api.h): model, NPU core mask
// (rknn_set_core_mask), init priority flag, top-N, labels file. NOT settable:
// input size + mean/std -- those are baked into the .rknn at conversion, so they
// are queried, not configured.
//
// Header-only. The ONE translation unit that needs stb's decoder must
// `#define STB_IMAGE_IMPLEMENTATION` before including this header.
#pragma once
#include "rknn_api.h"
// stb's IMPLEMENTATION section isn't its own include-guarded, so if a TU pulls both
// kiln_vision.h and kiln_detect.h it would compile stb twice. Guard the include so
// whichever header is seen first pulls stb (and the STB_IMAGE_IMPLEMENTATION the TU
// defined); the second skips it. Declarations are then already visible.
#ifndef KILN_STB_INCLUDED
#define KILN_STB_INCLUDED
#include "stb_image.h"
#endif
#include "kiln_config.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

struct KilnVisionResult { int index; std::string label; float score; };

class KilnVision {
public:
    // init from config (model/core_mask/priority/labels). Returns 0 on success.
    int init(const KilnConfig &cfg) {
        cfg_ = cfg;
        size_t sz = 0;
        void *model = read_file(cfg.vision_model.c_str(), &sz);
        if (!model) { snprintf(err_, sizeof(err_), "cannot read model %s", cfg.vision_model.c_str()); return -1; }

        uint32_t flag = 0;
        if      (cfg.vision_priority == "medium") flag = RKNN_FLAG_PRIOR_MEDIUM;
        else if (cfg.vision_priority == "low")    flag = RKNN_FLAG_PRIOR_LOW;
        else                                      flag = RKNN_FLAG_PRIOR_HIGH;

        int ret = rknn_init(&ctx_, model, sz, flag, nullptr);
        free(model);
        if (ret < 0) { snprintf(err_, sizeof(err_), "rknn_init failed: %d", ret); return ret; }

        rknn_core_mask cm = RKNN_NPU_CORE_AUTO;
        if      (cfg.vision_core_mask == "0")   cm = RKNN_NPU_CORE_0;
        else if (cfg.vision_core_mask == "1")   cm = RKNN_NPU_CORE_1;
        else if (cfg.vision_core_mask == "0_1") cm = RKNN_NPU_CORE_0_1;
        rknn_set_core_mask(ctx_, cm);   // RK3576: 2 cores; ignored if unsupported

        rknn_query(ctx_, RKNN_QUERY_IN_OUT_NUM, &io_, sizeof(io_));
        memset(&in_, 0, sizeof(in_));  in_.index = 0;
        rknn_query(ctx_, RKNN_QUERY_INPUT_ATTR, &in_, sizeof(in_));
        memset(&out_, 0, sizeof(out_)); out_.index = 0;
        rknn_query(ctx_, RKNN_QUERY_OUTPUT_ATTR, &out_, sizeof(out_));

        if (in_.fmt == RKNN_TENSOR_NCHW) { c_ = in_.dims[1]; h_ = in_.dims[2]; w_ = in_.dims[3]; }
        else                             { h_ = in_.dims[1]; w_ = in_.dims[2]; c_ = in_.dims[3]; }
        nchw_ = (in_.fmt == RKNN_TENSOR_NCHW);
        if (c_ != 3) { snprintf(err_, sizeof(err_), "input channels %d (need 3)", c_); return -1; }

        labels_ = load_labels(cfg.vision_labels.c_str());
        return 0;
    }

    // classify already-decoded RGB (w*h*3). Fills `ms` with NPU time.
    std::vector<KilnVisionResult> classify_rgb(const unsigned char *rgb, int iw, int ih,
                                               int top_n, double *ms, std::string *err) {
        std::vector<KilnVisionResult> res;
        std::vector<uint8_t> buf(3 * h_ * w_);
        for (int y = 0; y < h_; y++)
            for (int x = 0; x < w_; x++) {
                int sx = x * iw / w_, sy = y * ih / h_;
                for (int cc = 0; cc < 3; cc++) {
                    uint8_t v = rgb[(sy * iw + sx) * 3 + cc];
                    if (nchw_) buf[cc * h_ * w_ + y * w_ + x] = v;
                    else       buf[(y * w_ + x) * 3 + cc] = v;
                }
            }
        rknn_input in;
        memset(&in, 0, sizeof(in));
        in.index = 0; in.type = RKNN_TENSOR_UINT8;
        in.fmt = nchw_ ? RKNN_TENSOR_NCHW : RKNN_TENSOR_NHWC;
        in.size = buf.size(); in.buf = buf.data();
        if (rknn_inputs_set(ctx_, 1, &in) < 0) { if (err) *err = "rknn_inputs_set failed"; return res; }

        auto t0 = std::chrono::steady_clock::now();
        int ret = rknn_run(ctx_, nullptr);
        double t = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (ms) *ms = t;
        if (ret < 0) { if (err) *err = "rknn_run failed"; return res; }

        rknn_output out;
        memset(&out, 0, sizeof(out));
        out.want_float = 1;
        if (rknn_outputs_get(ctx_, 1, &out, nullptr) < 0) { if (err) *err = "rknn_outputs_get failed"; return res; }

        int n = out_.n_elems ? (int)out_.n_elems : (int)(out.size / sizeof(float));
        float *scores = (float *)out.buf;
        std::vector<int> idx(n);
        for (int i = 0; i < n; i++) idx[i] = i;
        int k = top_n < n ? top_n : n;
        if (k < 0) k = 0;
        std::partial_sort(idx.begin(), idx.begin() + k, idx.end(),
                          [&](int a, int b) { return scores[a] > scores[b]; });
        int off = ((int)labels_.size() == n + 1) ? 1 : 0;   // some files have a "background" row
        for (int j = 0; j < k; j++) {
            int i = idx[j];
            std::string name = (i + off >= 0 && i + off < (int)labels_.size()) ? labels_[i + off] : "?";
            res.push_back({i, name, scores[i]});
        }
        rknn_outputs_release(ctx_, 1, &out);
        return res;
    }

    // decode an encoded image (jpg/png bytes) then classify.
    std::vector<KilnVisionResult> classify_encoded(const unsigned char *data, int len,
                                                   int top_n, double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load_from_memory(data, len, &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image"; return {}; }
        auto r = classify_rgb(img, iw, ih, top_n, ms, err);
        stbi_image_free(img);
        return r;
    }

    std::vector<KilnVisionResult> classify_file(const std::string &path, int top_n,
                                                double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load(path.c_str(), &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image " + path; return {}; }
        auto r = classify_rgb(img, iw, ih, top_n, ms, err);
        stbi_image_free(img);
        return r;
    }

    bool ok() const { return ctx_ != 0; }
    const char *error() const { return err_; }
    int in_w() const { return w_; } int in_h() const { return h_; }
    ~KilnVision() { if (ctx_) rknn_destroy(ctx_); }

private:
    static void *read_file(const char *path, size_t *out) {
        FILE *f = fopen(path, "rb"); if (!f) return nullptr;
        fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
        void *b = malloc(sz);
        if (b && fread(b, 1, sz, f) != (size_t)sz) { free(b); b = nullptr; }
        fclose(f); if (out) *out = sz; return b;
    }
    static std::vector<std::string> load_labels(const char *path) {
        std::vector<std::string> v;
        if (!path || !*path) return v;
        FILE *f = fopen(path, "r"); if (!f) return v;
        char line[512];
        while (fgets(line, sizeof(line), f)) {
            size_t n = strlen(line);
            while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
            v.push_back(line);
        }
        fclose(f); return v;
    }
    rknn_context ctx_ = 0;
    rknn_input_output_num io_{};
    rknn_tensor_attr in_{}, out_{};
    int w_ = 0, h_ = 0, c_ = 0; bool nchw_ = false;
    std::vector<std::string> labels_;
    KilnConfig cfg_;
    char err_[256] = {0};
};
