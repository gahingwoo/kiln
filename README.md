# rk3576-npu-llm (Kiln)

Run LLMs on the **Rockchip RK3576 NPU** under a **mainline** Linux kernel (7.x),
by building the vendor GPL `rknpu` driver **out-of-tree** and driving it with the
closed `librkllmrt` RKLLM runtime.

The vendor RKLLM stack already runs multi-matmul LLMs on RK3576 — on the vendor
6.1 BSP kernel. Kiln's goal is to put that same stack (vendor `rknpu.ko` v0.9.8 +
`librkllmrt`) on a **mainline** kernel, using mainline's own clock / power-domain
/ IOMMU drivers instead of the BSP's.

## Status — honest

This is **bring-up in progress**, not a finished product.

What works on real hardware (ROCK 4D, RK3576), verified from serial logs:

- The out-of-tree `rknpu` v0.9.8 driver builds against mainline 7.1 (`linux-next`)
  and loads (a set of small API-compat shims cover the 6.1 → 7.x drift; see
  `driver/apply-mainline-shims.sh`).
- It probes cleanly against a mainline DT node (`dts/`): power domains toggle,
  the register interface and MMU respond, the DRM render node comes up.
- `librkllmrt` opens the device, loads a TinyLlama-1.1B `w4a16` `.rkllm` model,
  and the **runtime/driver/platform version-lock check passes on the board**
  (`rkllm 1.2.0` + `rknpu 0.9.8` + `RK3576`).

What does **not** work yet:

- **NPU compute jobs time out.** The matmul job is submitted, but the compute
  units never engage: `raw status 0x30000000`, the `0x300` DPU-done bits are
  never set, `task_counter` stays `0`, on both cores, with no IOMMU page fault.
  No tokens come out yet. This is the same class of "the PC won't iterate the
  task / the units won't engage" wall seen in the from-scratch open driver
  investigation, now hit through the vendor stack on a mainline port. Under
  active investigation — the divergence is somewhere in the mainline port
  (IOMMU delivery / on-chip NBUF operand cache / a platform mode bit), since the
  same vendor payload is known to compute on the vendor and rocket kernels.

If you are looking for a working RK3576 LLM setup today, use the vendor 6.1 BSP.
This repo is about getting there on mainline.

## Build

The whole thing is assembled as a buildroot br2-external:

```sh
# 1. Fetch the GPL rknpu v0.9.8 source (not redistributed here)
driver/fetch-vendor-driver.sh

# 2. Fetch the closed runtimes (librkllmrt / librknnrt) into buildroot/dl
buildroot/fetch-runtimes.sh

# 3. Build the flashable image (rootfs + kernel module + model baked in)
buildroot/build-image.sh
```

The module alone can be built against any mainline kernel tree:

```sh
make KDIR=/path/to/your/kernel/build     # after fetch + shims
```

The DT node uses the **real** vendor RK3576 addresses (see `dts/`), not the
guessed open-driver layout.

## Layout

- `dts/` — RK3576 NPU DT node + ROCK 4D board DTS (real vendor addresses)
- `driver/fetch-vendor-driver.sh` — pull the GPL v0.9.8 `rknpu` source
- `driver/apply-mainline-shims.sh` — the 6.1 → 7.x API-compat shims (idempotent)
- `driver/compat/` — build-time compat stub headers for BSP-only `soc/rockchip/*`
- `Kbuild`, `Makefile`, `dkms.conf` — out-of-tree module build (DRM_GEM path)
- `buildroot/` — br2-external: board config, package, rootfs overlay, image scripts
- `scripts/` — build / load / smoke-test / run helpers

## Credits

- **Driver base:** [`armbian/linux-rockchip`](https://github.com/armbian/linux-rockchip)
  (rk-6.1-rkr6.1), which carries the GPL-2.0 vendor `rknpu` v0.9.8 driver
  (byte-identical to `rockchip-linux/kernel` develop-6.1).
- **Out-of-tree port reference:** [`w568w/rknpu-module`](https://github.com/w568w/rknpu-module)
  — proof that the v0.9.8 `rknpu` driver builds and runs on a mainline kernel.
  Kiln does not vendor its code; its `drm_driver` shims and `soc/rockchip/*`
  compat stubs were a useful reference for the RK3576 port. Thanks to its author.

## License

GPL-2.0 (see `LICENSE`). Kiln wraps and builds the GPL-2.0 vendor `rknpu`
driver, whose source is **fetched, not redistributed** here
(`driver/fetch-vendor-driver.sh`). The `librkllmrt` / `librknnrt` runtimes are
closed and distributed by Rockchip; Kiln does not include them. Model weights
are licensed separately and are not included.
