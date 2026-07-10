// SPDX-License-Identifier: Apache-2.0
// kiln_detect.h -- EXPERIMENTAL object-detection foundation for the RK3576 NPU via
// librknnrt (RKNN). Anchor-free YOLOv8 / YOLO11 (DFL) decode.
//
//   *** EXPERIMENTAL -- NOT verified on real hardware. ***
//
// The GENERIC pieces here are host-unit-tested and correct-by-construction: the
// letterbox preprocessing + its inverse, IoU, per-class NMS, the label loader, and
// the RKNN plumbing (query ALL outputs, run, read floats). The YOLOv8/11 DFL DECODE
// mirrors airockchip/rknn_model_zoo (examples/yolov8/cpp/postprocess.cc) but has NOT
// been run against a real .rknn on a board -- it may produce wrong boxes. Detection
// is therefore OFF by default (config `[vision] task = classify`); set `task = detect`
// to try it, and expect to verify/tune it on hardware. Kiln does NOT claim working
// object detection -- this is a foundation to build on, not a shipped feature.
//
// Deliberately SEPARATE from kiln_vision.h (classification): the result type,
// preprocessing, and post-processing are fundamentally different, and keeping them
// apart leaves the working classifier completely untouched.
//
// Model expectations (match the airockchip RKNN export of YOLOv8/YOLO11):
//   - input: one NHWC (or NCHW) uint8 tensor, square (e.g. 640x640), queried not set.
//   - outputs: 6 tensors (a box tensor [1, 4*dfl_len, gh, gw] + a class-score tensor
//     [1, num_classes, gh, gw] per stride 8/16/32) or 9 (adds a [1,1,gh,gw] score_sum
//     early-out gate, which we ignore). Order per stride is [box, score, (score_sum)].
//   - anchor-free: no anchors, no objectness; score = max class prob.
// A future anchor-based (v5/v7) path and the int8-gating speed optimization are noted
// where they'd slot in; this foundation reads float outputs (want_float=1) for
// correctness+simplicity and lets the runtime dequantize.
//
// The ONE translation unit that needs stb's decoder must `#define
// STB_IMAGE_IMPLEMENTATION` before including this header (kiln_vision.h says the same,
// so a TU that includes both defines it once).
#pragma once
#include "rknn_api.h"
// See kiln_vision.h: guard stb so it isn't compiled twice when a TU includes both.
#ifndef KILN_STB_INCLUDED
#define KILN_STB_INCLUDED
#include "stb_image.h"
#endif
#include "kiln_config.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cmath>
#include <string>
#include <vector>
#include <algorithm>
#include <chrono>

struct KilnBox { float x1, y1, x2, y2; };                    // pixels in the ORIGINAL image
struct KilnDetection { KilnBox box; int class_id; std::string label; float score; };
struct KilnLetterbox { float scale; int pad_x, pad_y; int in_w, in_h; };

class KilnDetect {
public:
    // ---- pure helpers (host-unit-tested; no NPU needed) --------------------
    // Aspect-preserving fit of a WxH image into model_w x model_h: scale by the
    // smaller ratio, center the result, pad the rest. Returns the transform.
    static KilnLetterbox make_letterbox(int iw, int ih, int mw, int mh) {
        float s = std::min((float)mw / iw, (float)mh / ih);
        int nw = (int)std::lround(iw * s), nh = (int)std::lround(ih * s);
        KilnLetterbox lb; lb.scale = s; lb.pad_x = (mw - nw) / 2; lb.pad_y = (mh - nh) / 2;
        lb.in_w = iw; lb.in_h = ih; return lb;
    }
    // Map a box in model (letterboxed) pixel coords back to original-image coords,
    // clamped to the image. Inverse of make_letterbox: subtract pad, divide by scale.
    static KilnBox unletterbox(KilnBox b, const KilnLetterbox &lb) {
        KilnBox o;
        o.x1 = (b.x1 - lb.pad_x) / lb.scale; o.y1 = (b.y1 - lb.pad_y) / lb.scale;
        o.x2 = (b.x2 - lb.pad_x) / lb.scale; o.y2 = (b.y2 - lb.pad_y) / lb.scale;
        o.x1 = clampf(o.x1, 0, lb.in_w); o.x2 = clampf(o.x2, 0, lb.in_w);
        o.y1 = clampf(o.y1, 0, lb.in_h); o.y2 = clampf(o.y2, 0, lb.in_h);
        return o;
    }
    static float iou(const KilnBox &a, const KilnBox &b) {
        float ix1 = std::max(a.x1, b.x1), iy1 = std::max(a.y1, b.y1);
        float ix2 = std::min(a.x2, b.x2), iy2 = std::min(a.y2, b.y2);
        float iw = std::max(0.f, ix2 - ix1), ih = std::max(0.f, iy2 - iy1);
        float inter = iw * ih;
        float ua = area(a) + area(b) - inter;
        return ua > 0 ? inter / ua : 0.f;
    }
    // Per-class NMS: within each class, keep the highest-scoring box and drop others
    // that overlap it beyond iou_thresh. Boxes of different classes never suppress
    // each other (the rknn_model_zoo convention). Sorts by score, in place.
    static void nms(std::vector<KilnDetection> &d, float iou_thresh) {
        std::sort(d.begin(), d.end(), [](const KilnDetection &p, const KilnDetection &q) { return p.score > q.score; });
        std::vector<char> dead(d.size(), 0);
        for (size_t i = 0; i < d.size(); i++) {
            if (dead[i]) continue;
            for (size_t j = i + 1; j < d.size(); j++) {
                if (dead[j] || d[j].class_id != d[i].class_id) continue;
                if (iou(d[i].box, d[j].box) > iou_thresh) dead[j] = 1;
            }
        }
        std::vector<KilnDetection> keep;
        for (size_t i = 0; i < d.size(); i++) if (!dead[i]) keep.push_back(d[i]);
        d.swap(keep);
    }

    // ---- NPU path ----------------------------------------------------------
    // init from config (model / core_mask / priority / labels). Queries ALL outputs.
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
        rknn_set_core_mask(ctx_, cm);

        rknn_query(ctx_, RKNN_QUERY_IN_OUT_NUM, &io_, sizeof(io_));
        memset(&in_, 0, sizeof(in_)); in_.index = 0;
        rknn_query(ctx_, RKNN_QUERY_INPUT_ATTR, &in_, sizeof(in_));
        if (in_.fmt == RKNN_TENSOR_NCHW) { c_ = in_.dims[1]; h_ = in_.dims[2]; w_ = in_.dims[3]; }
        else                             { h_ = in_.dims[1]; w_ = in_.dims[2]; c_ = in_.dims[3]; }
        nchw_ = (in_.fmt == RKNN_TENSOR_NCHW);
        if (c_ != 3) { snprintf(err_, sizeof(err_), "input channels %d (need 3)", c_); return -1; }

        // detection needs EVERY output tensor's shape (grid + channels), not just #0
        if (io_.n_output < 2) { snprintf(err_, sizeof(err_), "model has %u outputs; not a YOLOv8/11 detector (expect 6 or 9)", io_.n_output); return -1; }
        out_attrs_.resize(io_.n_output);
        for (uint32_t i = 0; i < io_.n_output; i++) {
            memset(&out_attrs_[i], 0, sizeof(rknn_tensor_attr));
            out_attrs_[i].index = i;
            rknn_query(ctx_, RKNN_QUERY_OUTPUT_ATTR, &out_attrs_[i], sizeof(rknn_tensor_attr));
        }
        labels_ = load_labels(cfg.vision_labels.c_str());
        return 0;
    }

    // Detect on already-decoded RGB (iw*ih*3). Fills `ms` with NPU time.
    std::vector<KilnDetection> detect_rgb(const unsigned char *rgb, int iw, int ih,
                                          float conf, float nms_iou, double *ms, std::string *err) {
        std::vector<KilnDetection> out;
        KilnLetterbox lb = make_letterbox(iw, ih, w_, h_);

        // letterbox into a model-sized uint8 buffer (fill 114, nearest-sample content)
        std::vector<uint8_t> buf(3 * h_ * w_, 114);
        int nw = (int)std::lround(iw * lb.scale), nh = (int)std::lround(ih * lb.scale);
        for (int y = 0; y < nh; y++) {
            int sy = std::min(ih - 1, (int)(y / lb.scale));
            for (int x = 0; x < nw; x++) {
                int sx = std::min(iw - 1, (int)(x / lb.scale));
                int dy = y + lb.pad_y, dx = x + lb.pad_x;
                for (int cc = 0; cc < 3; cc++) {
                    uint8_t v = rgb[(sy * iw + sx) * 3 + cc];
                    if (nchw_) buf[cc * h_ * w_ + dy * w_ + dx] = v;
                    else       buf[(dy * w_ + dx) * 3 + cc] = v;
                }
            }
        }

        rknn_input in; memset(&in, 0, sizeof(in));
        in.index = 0; in.type = RKNN_TENSOR_UINT8;
        in.fmt = nchw_ ? RKNN_TENSOR_NCHW : RKNN_TENSOR_NHWC;
        in.size = buf.size(); in.buf = buf.data();
        if (rknn_inputs_set(ctx_, 1, &in) < 0) { if (err) *err = "rknn_inputs_set failed"; return out; }

        auto t0 = std::chrono::steady_clock::now();
        int ret = rknn_run(ctx_, nullptr);
        double t = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
        if (ms) *ms = t;
        if (ret < 0) { if (err) *err = "rknn_run failed"; return out; }

        std::vector<rknn_output> outs(io_.n_output);
        memset(outs.data(), 0, outs.size() * sizeof(rknn_output));
        for (uint32_t i = 0; i < io_.n_output; i++) outs[i].want_float = 1;   // let the runtime dequantize
        if (rknn_outputs_get(ctx_, io_.n_output, outs.data(), nullptr) < 0) { if (err) *err = "rknn_outputs_get failed"; return out; }

        decode_yolov8(outs, conf, out);        // model coords -> candidate boxes
        rknn_outputs_release(ctx_, io_.n_output, outs.data());

        for (auto &d : out) d.box = unletterbox(d.box, lb);   // back to original image
        nms(out, nms_iou);
        return out;
    }

    std::vector<KilnDetection> detect_encoded(const unsigned char *data, int len,
                                              float conf, float nms_iou, double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load_from_memory(data, len, &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image"; return {}; }
        auto r = detect_rgb(img, iw, ih, conf, nms_iou, ms, err);
        stbi_image_free(img); return r;
    }
    std::vector<KilnDetection> detect_file(const std::string &path, float conf, float nms_iou,
                                           double *ms, std::string *err) {
        int iw, ih, ic;
        unsigned char *img = stbi_load(path.c_str(), &iw, &ih, &ic, 3);
        if (!img) { if (err) *err = "cannot decode image " + path; return {}; }
        auto r = detect_rgb(img, iw, ih, conf, nms_iou, ms, err);
        stbi_image_free(img); return r;
    }

    bool ok() const { return ctx_ != 0; }
    const char *error() const { return err_; }
    int in_w() const { return w_; } int in_h() const { return h_; }
    ~KilnDetect() { if (ctx_) rknn_destroy(ctx_); }

private:
    static float area(const KilnBox &b) { return std::max(0.f, b.x2 - b.x1) * std::max(0.f, b.y2 - b.y1); }
    static float clampf(float v, float lo, float hi) { return v < lo ? lo : (v > hi ? hi : v); }

    // --- YOLOv8 / YOLO11 anchor-free DFL decode (EXPERIMENTAL) ---------------
    // Mirrors airockchip/rknn_model_zoo examples/yolov8/cpp/postprocess.cc. Outputs
    // are grouped per stride as [box, score, (score_sum)]; output_per_branch =
    // n_output/3. Box tensor is [1, 4*dfl_len, gh, gw] (NCHW), score tensor is
    // [1, num_classes, gh, gw]. Reads floats (want_float=1), so no manual dequant.
    void decode_yolov8(const std::vector<rknn_output> &outs, float conf, std::vector<KilnDetection> &out) {
        int opb = (int)io_.n_output / 3;                 // 2 (box,score) or 3 (+score_sum)
        if (opb < 2) return;
        for (int s = 0; s < 3; s++) {
            int box_i = s * opb, score_i = box_i + 1;
            if (score_i >= (int)io_.n_output) break;
            const rknn_tensor_attr &ba = out_attrs_[box_i];
            const rknn_tensor_attr &sa = out_attrs_[score_i];
            int gh, gw, box_ch, ncls;
            dims_nchw(ba, gh, gw, box_ch);
            int sgh, sgw; dims_nchw(sa, sgh, sgw, ncls);
            if (gh <= 0 || gw <= 0 || box_ch % 4 != 0) continue;
            int dfl = box_ch / 4;                        // 16
            int stride_x = w_ / gw, stride_y = h_ / gh;  // e.g. 8/16/32
            const float *box = (const float *)outs[box_i].buf;
            const float *scr = (const float *)outs[score_i].buf;
            int cell = gh * gw;
            for (int i = 0; i < gh; i++) {
                for (int j = 0; j < gw; j++) {
                    int idx = i * gw + j;
                    // best class score at this cell (anchor-free: no objectness)
                    int best = -1; float bestp = conf;
                    for (int c = 0; c < ncls; c++) {
                        float p = scr[c * cell + idx];
                        if (p > bestp) { bestp = p; best = c; }
                    }
                    if (best < 0) continue;
                    // DFL: per side, softmax over `dfl` bins -> expected distance
                    float dist[4];
                    for (int b = 0; b < 4; b++) {
                        float acc = 0, sum = 0, tmp[32];
                        int n = dfl > 32 ? 32 : dfl;
                        for (int k = 0; k < n; k++) { tmp[k] = std::exp(box[(b * dfl + k) * cell + idx]); sum += tmp[k]; }
                        for (int k = 0; k < n; k++) acc += (tmp[k] / sum) * k;
                        dist[b] = acc;
                    }
                    KilnDetection d;
                    d.box.x1 = (-dist[0] + j + 0.5f) * stride_x;
                    d.box.y1 = (-dist[1] + i + 0.5f) * stride_y;
                    d.box.x2 = ( dist[2] + j + 0.5f) * stride_x;
                    d.box.y2 = ( dist[3] + i + 0.5f) * stride_y;
                    d.class_id = best; d.score = bestp;
                    d.label = (best >= 0 && best < (int)labels_.size()) ? labels_[best] : ("class " + std::to_string(best));
                    out.push_back(d);
                }
            }
        }
    }
    static void dims_nchw(const rknn_tensor_attr &a, int &gh, int &gw, int &ch) {
        // RK3576 (rknpu2) tensors are NCHW: dims = [1, C, H, W].
        if (a.n_dims == 4) { ch = a.dims[1]; gh = a.dims[2]; gw = a.dims[3]; }
        else { ch = gh = gw = 0; }
    }

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
    rknn_tensor_attr in_{};
    std::vector<rknn_tensor_attr> out_attrs_;
    int w_ = 0, h_ = 0, c_ = 0; bool nchw_ = false;
    std::vector<std::string> labels_;
    KilnConfig cfg_;
    char err_[256] = {0};
};
