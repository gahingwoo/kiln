# Kiln buildroot external (ROCK 4D, RK3576 NPU)

Builds a flashable `sdcard.img`: mainline kernel + out-of-tree vendor `rknpu.ko`
(v0.9.8, DRM_GEM) + version-locked `librkllmrt` v1.2.0 + `librknnrt` v2.3.0, with
the rocket driver turned off so only the vendor rknpu binds the NPU.

## What is validated vs what you run

Validated on this dev machine (not just written):
- `rknpu.ko` COMPILES against a patched 7.1 arm64 tree in DRM_GEM mode via
  `driver/apply-mainline-shims.sh`, which applies one deterministic patch
  (`patches/kiln-mainline.patch`) plus two supplementary shims — see
  [`../driver/patches/README.md`](../driver/patches/README.md). (Compile-validated on
  a linux-next 7.1.0 / next-20260527 snapshot; the runtime target is mainline 7.1.3.)
  Produces a ~510 KB `.ko`, `vermagic` matching the target kernel, `import_ns: DMA_BUF`,
  no `rk_dma_heap` symbols.
- The vendor `rockchip,rk3576-rknpu` node + IOMMUs are added to the in-tree
  `rockchip/rk3576-rock-4d` dtb by `kernel-patches/0004` (with a CRU fixed-rate NPU
  clock); the KERNEL_SRC tree must have `kernel-patches/` 0001-0010 applied.
- `buildroot/fetch-runtimes.sh` fetches librkllmrt v1.2.0 (build 2025-04-08) and
  librknnrt v2.3.0 into `dl/`.

You run (needs the ROCK 4D u-boot binaries + a writable output dir; the full
buildroot build compiles its own toolchain + the kernel, ~40-90 min first run):

```
# edit the 4 paths at the top if yours differ, then:
./buildroot/build-image.sh
# -> br-out/images/sdcard.img
```

`build-image.sh` reuses the rocket tree's buildroot source and the linux-next tree
that already carries the RK3576 IOMMU/PD/clock platform patches. It changes nothing
in those reference trees (they live under `$KILN_REF_ROOT`, outside this repo):
rocket is disabled by `npu.fragment` (`CONFIG_DRM_ACCEL_ROCKET` builds in but idles
with no `rknn_core` node to bind), and the KILN dtb (`rk3576-rock-4d`) simply does not
carry the rocket NPU node — it is compiled out of that dtb at the DT-source level — so
the out-of-tree vendor `rknpu.ko` owns `npu@27700000` there. The separate `-rocket`
dtb keeps the rocket node for the dual-image boot menu.

## Files

- `configs/kiln_rock4d_713_defconfig` — Kiln defconfig (mainline 7.1.3, rocket off,
  post-build/post-image, `BR2_ROOTFS_OVERLAY=rootfs/`, ext4 `BR2_TARGET_ROOTFS_EXT2_SIZE=2560M`).
- `npu.fragment` — kernel fragment: `# CONFIG_DRM_ACCEL_ROCKET is not set` + deps.
- `board/rock4d/` — the userspace sources compiled into the image (`rkllm_chat.cpp`,
  `rknn_mobilenet.cpp`, `kiln_serve.cpp`, and the shared headers `kiln_config.h` /
  `kiln_llm.h` / `kiln_vision.h`), plus the build hooks:
  - `post-build.sh` — builds `rknpu.ko` (+ `depmod`); installs the runtimes
    (`librkllmrt` / `librknnrt` / `libgomp.so.1`); cross-builds the `rkllm_demo` and
    `rknn_mobilenet` demos; installs `kiln-doctor` + `kiln-config` (from `scripts/`)
    and `kiln-env-trace` (from `capture/`); adds an `S89rknpu` init that `modprobe`s
    rknpu at boot; bakes the vision assets (test image + labels, and the `.rknn` if
    present in `model/`).
  - `post-image.sh` — packs `sdcard.img` (16 MiB u-boot + FAT32 boot + ext4 rootfs)
    with the Kiln DTB.
- `rootfs/` — the `BR2_ROOTFS_OVERLAY`: ships `usr/bin/kiln-chat`, `usr/bin/kiln-vision`,
  the `kiln-serve.service` unit, and the login MOTD (`etc/profile.d/kiln-motd.sh`).
- `fetch-runtimes.sh` — fetches the version-locked closed `.so` blobs + demo headers
  into `dl/` (idempotent).
- `fetch-vision-assets.sh` — fetches the MobileNet test image + ImageNet labels (and
  optionally a pre-converted `.rknn` via `KILN_MODELS_URL`) into `model/`; idempotent,
  so installer phase 1 can pre-cache it for an offline phase 2.
- `build-image.sh` — orchestrator (set 4 paths, one command).
- `dl/` — build-time fetch cache: closed `.so` blobs + `libgomp.so.1` + demo headers
  (`rkllm.h`, `rknn_api.h`, `stb_image.h`) + kiln-serve's `httplib.h` / `json.hpp` +
  `llm_demo.cpp` + `base.config`. Not source; do not commit.

## Models are not baked in by default

The rootfs is sized **2560M** in the defconfig (libs + `rknpu.ko` + headroom — enough
for a baked ~1.4 GB LLM). By default `post-build.sh` bakes only the small vision assets
(test image + labels, and a `mobilenetv2-12_rk3576.rknn` **if you dropped one in
`model/`**); the large LLM `.rkllm` is baked only with `KILN_BAKE_MODEL=1
./buildroot/build-image.sh`. Kiln ships no models — put a `*.rkllm` / `*.rknn` in
`model/` to bake, or `scp` them to `/opt/models` on the board.
