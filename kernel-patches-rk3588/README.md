# Kiln on RK3588 (Radxa ROCK 5B) — kernel patches

**Status: SKELETON. The Kiln DTB compiles (dtc); nothing has run on RK3588
hardware.** This directory scaffolds the RK3588 NPU port so it can be finished
and validated against a real RK3588 vendor BSP and against the mainline
`accel/rocket` path. Treat every hardware-specific value marked `TODO(bsp)` as
*unconfirmed*.

The tested Kiln path is RK3576 (ROCK 4D) — see
[`../kernel-patches/README.md`](../kernel-patches/README.md) and
[`../docs/MAINLINE-KERNEL.md`](../docs/MAINLINE-KERNEL.md).

## The one thing that makes RK3588 different from RK3576

On **RK3576**, mainline has *no* NPU compute node, so Kiln **adds** a vendor
`rockchip,rk3576-rknpu` node (`../kernel-patches/0004`).

On **RK3588**, mainline 7.1.3 **already describes the NPU** — as three
`rockchip,rk3588-rknn-core` nodes for the open `accel/rocket` driver, and
`rk3588-rock-5b.dtsi` **enables** them:

| what | where (7.1.3 tree) |
|---|---|
| 3 rocket cores `npu@fdab0000` / `fdac0000` / `fdad0000` | `arch/arm64/boot/dts/rockchip/rk3588-base.dtsi` (`rknn_core_0/1/2`) |
| 3 IOMMUs `iommu@fdab9000`(+`fdaba000`) / `fdaca000` / `fdada000` | same file (`rknn_mmu_0/1/2`) |
| ROCK 5B enables all of them on `vdd_npu_s0` | `rk3588-rock-5b-5bp-5t.dtsi:555-583` |
| rocket driver targets `rockchip,rk3588-rknn-core` | `drivers/accel/rocket/rocket_drv.c:299` |

Kiln uses the closed **`librkllmrt` / `librknnrt`** runtimes, which speak the
**vendor `rknpu` ioctl ABI** and need a **single `rockchip,rk3588-rknpu`** node
(the vendor driver's `rk3588_rknpu_config` has `core_mask = 0x7`, i.e. it owns all
three cores from one node — `../driver/rknpu/rknpu_drv.c:183`). The two drivers
cannot both own the NPU MMIO.

**So the RK3588 port is delete-and-reshape, not add:** the Kiln DTB removes the
three rocket cores and turns `rknn_core_0`'s node into the vendor node. This is
the same "kiln DTB vs rocket DTB" split as RK3576, but forced by the existing
in-tree nodes rather than a missing one.

## What is verified (no hardware needed)

- **The vendor driver already supports RK3588.** `rockchip,rk3588-rknpu` →
  `rk3588_rknpu_config` (`core_mask=0x7`, `pc_task_number_bits=12`,
  `pc_task_status_offset=0x3c`, 40-bit DMA), plus RK3588 devfreq/OPP with leakage
  binning (`rk3588_npu_get_soc_info`, reads RK3588M/J) — all in
  `../driver/rknpu/`. The `rknpu.ko` is the **same binary** as RK3576.
- **The NPU hardware resources** (reg bases, 3 IOMMUs, `RK3588_PD_NPUTOP/NPU1/NPU2`,
  `ACLK/HCLK_NPU0..2`, `SCMI_CLK_NPU`, `PCLK_NPU_ROOT`, `SRST_A/H_RKNN0..2`, IRQs
  `GIC_SPI 110/111/112`) — copied verbatim from the mainline `rknn_core_0/1/2`
  nodes (same silicon).
- **`rk3588-rock-5b-kiln.dtb` compiles** with a single `rockchip,rk3588-rknpu`
  node and no `rknn-core` nodes (dtc, via cpp preprocessing of the real 7.1.3
  tree).
- **The console** is UART2 `@0xfeb50000` (`serial2:1500000n8`) — used by the
  buildroot `post-image.sh`.

## Patches

| file | what | verified |
|---|---|---|
| `0001-arm64-dts-rk3588-add-rock-5b-kiln-vendor-rknpu-dtb.patch` | adds `rk3588-rock-5b-kiln.dts` (+ Makefile): deletes rocket `rknn_core_1/2`, reshapes `rknn_core_0` → `rockchip,rk3588-rknpu` (3-core reg), enables `rknn_mmu_0/1/2` | applies to 7.1.3; DTB **compiles**. NOT run on hardware. |

## Open items — MUST be reconciled before it binds/runs

These are `TODO(bsp)` in the patch. They need a **real RK3588 vendor `rknpu`
node** (from a Rockchip 6.1 BSP for RK3588) and/or **hardware**:

1. **`reg` span/count.** The node uses a per-core `0x9000` span (the RK3576-vendor
   pattern). The vendor RK3588 `rknpu` node's exact `reg` layout is unconfirmed —
   the driver reads registers by index, so a wrong layout mis-drives the cores.
2. **`clk_npu` route.** Mainline uses `&scmi_clk SCMI_CLK_NPU`. The RK3576 Kiln
   port had to *leave* SCMI for a CRU clock (firmware clamped SCMI to 198 MHz and
   the core wedged). Confirm which RK3588 needs, and the safe rate.
3. **OPP + voltage.** No `operating-points-v2` yet; add the RK3588 NPU rates /
   microvolts (and whether devfreq needs `rockchip,rk3588` opp bindings).
4. **Leakage nvmem.** `rk3588_npu_get_soc_info` reads leakage/bin nvmem cells; the
   node needs the matching `nvmem-cells` or the driver falls back / warns.
5. **Which mainline kernel-patches apply.** The RK3576 series
   (`../kernel-patches/0001-0010`) is RK3576-specific (pmdomain settle-delay, NPU
   core arm, orphaned-fault-bank skips, `vdd_npu` always-on). RK3588's power path
   is 3 PDs under `VD_NPU` and more mature in mainline; **do not assume any of
   0001-0010 apply.** Re-derive against RK3588 on hardware. Candidates worth
   checking first: `0003` (iommu take-all-dt-clocks) and `0007/0008` (orphaned
   fault banks) since RK3588 also uses `rockchip-iommu` across multiple banks.
6. **On-board bring-up:** does the vendor node power on (watch `-ETIMEDOUT` /
   `failed to get pm runtime`), probe (`/dev/dri/renderD*`), and run a conv with
   correct output on all 3 cores?

## Build (once the open items above are addressed)

Same flow as RK3576, with the rock5b defconfig + an **RK3588** base kernel config:

```sh
# KERNEL_SRC = a mainline 7.1.3 tree with kernel-patches-rk3588/ applied
# base.config = an RK3588 kernel config (NOT the rk3576 one)
# ROCKCHIP_BINARIES = a dir with rock5b-sd-uboot.img (you supply it)
DEFCONFIG=kiln_rock5b_713_defconfig \
UBOOT_IMG_NAME=rock5b-sd-uboot.img \
UBOOT_IMG="$ROCKCHIP_BINARIES/rock5b-sd-uboot.img" \
KERNEL_SRC=... BASE_CONFIG=... ROCKCHIP_BINARIES=... \
  buildroot/build-image.sh
```

`kernel-patches-rk3588/` is applied to `KERNEL_SRC` the same way as the RK3576
series — `build-image.sh` expects `KERNEL_SRC` to already have the patches
applied (it does not patch the tree itself).

See [`../docs/RK3588.md`](../docs/RK3588.md) for the user-facing status.
