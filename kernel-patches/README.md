# Kiln kernel patches (RK3576 NPU)

**Honest correction to an earlier claim.** Kiln was described as running the
vendor `rknpu` stack on a mainline kernel with *no kernel patches* — everything
in the out-of-tree module plus a DT overlay. That is **not true for the RK3576
NPU power domain.** The module and the overlay cannot touch the built-in
`drivers/pmdomain/rockchip/pm-domains.c`, and without a fix there the NPU power
domain SErrors while the NoC is still settling after de-idle — on ROCK 4D that
is a **hard system freeze** during the first NPU inference (and a clean
`failed to get pm runtime for npu0, ret: -110` if the domain is cold when the
driver loads late).

The buildroot `linux-next` 7.1 image Kiln was validated on already carried these
fixes in its kernel tree, so the gap was invisible until Kiln was run on a stock
Armbian kernel. To run the NPU on Armbian you therefore need a kernel built with
(at least) the first patch below. These are **built-in driver fixes** — they
cannot be shipped as a module.

## Patches

| file | subsystem | why Kiln needs it | required? |
|---|---|---|---|
| `0001-pmdomain-rockchip-npu-settle-delay.patch` | `pmdomain/rockchip` | 15 µs settle delay for the NPUTOP/NPU0/NPU1 domains between de-idle and QoS restore. **This is the fix for the inference freeze / `-110`.** Self-contained; no DT change. | **yes — the fatal one** |
| `0002-pmdomain-rockchip-cycle-pd-resets.patch` | `pmdomain/rockchip` | Per-domain reset pulse on power-on: reads `resets` on the power-domain node and cycles it. On RK3576 this pulses the NPU **BIU** (bus interface unit) reset (`SRST_A_RKNNx_BIU`) that 0005 adds, so the NPU bus comes up initialised. **Without it, reading an NPU register (rknpu `GET_HW_VERSION` ioctl) async-SErrors and panics** even though the domain is powered. | **yes (with 0005)** |
| `0005-arm64-dts-rk3576-npu-pd-clocks-biu-reset.patch` | `arm64: dts` | Gives the `power-domain@RK3576_PD_NPU0/1` nodes the full NPU clock set (DSU0 + CBUF gates, not just root/aclk) so every clock runs during the power transition, and adds `resets = <&cru SRST_A_RKNNx_BIU>` for 0002 to pulse. Pairs with 0002. | **yes** |
| `0003-iommu-rockchip-take-all-dt-clocks.patch` | `iommu/rockchip` | **Driver-only** (split from its old DT hunk): take every DT clock via `devm_clk_bulk_get_all()` instead of the named `aclk`/`iface` pair, so the NPU MMU's extra CBUF/DSU gates run during `rk_iommu_resume` (mainline enables only aclk+iface → the MMU DTE write is silently dropped). Kiln's module also programs the DTE directly, so inference works without it, but this is the correct kernel-side fix. | recommended |
| `0004-arm64-dts-rk3576-add-vendor-rknpu-node.patch` | `arm64: dts` | Adds the vendor-shaped `npu@27700000` + two v2 IOMMUs to mainline `rk3576.dtsi` and enables it on ROCK 4D with `vdd_npu_s0`. Mainline has **no** NPU compute node (its accel/rocket path uses a different `rknn_core` layout), so this is what the vendor `rknpu` driver binds — the in-tree equivalent of the Armbian DT overlay. | **yes for a mainline build** |
| `0006-pmdomain-rockchip-npu-warm-power-on-skip-broken-mem-reset.patch` | `pmdomain/rockchip` | The NPU domain powers **cold** on first use (works) but is power-cycled again on every re-acquire — between LLM chat turns, or first use after a warm reboot. A **warm** power-on (domain memory still on) runs `rockchip_pmu_domain_mem_reset()`, whose NPUTOP power-*chain* poll never completes on this SoC → `failed to get chain status 'nputop'` → the power-on aborts with `-110` → the rknpu driver reads an unpowered core → **async SError that panics the board**. Skip the optional SRAM reset when the chain poll times out so the warm path finishes powering on exactly like the (working) cold path. (This hardens the warm genpd path; the actual "second inference wedges" root cause turned out to be the NPU rail dropping — see **0010**.) | **yes** |

| `0007-iommu-rockchip-skip-orphaned-fault-banks-in-stall-active.patch` | `iommu/rockchip` | The RK3576 NPU MMU banks can boot with an orphaned `PAGE_FAULT_ACTIVE` (no stall, idle) left by firmware. `rk_iommu_is_stall_active()` then reports the whole IOMMU "not stalled" forever, so `rk_iommu_resume()`'s stall poll never passes. Skip those quiescent banks. **The buildroot linux-next kernel that runs the stack carries this; Kiln's 7.1.3 omitted it, and a stall-poll timeout during the NPU's iommu resume can stall the shared PMU path → `cpu _set_opp_voltage … -110` → board wedge.** | **yes** |
| `0008-iommu-rockchip-skip-orphaned-fault-banks-in-enable-stall.patch` | `iommu/rockchip` | Same orphaned-fault banks: don't send `CMD_ENABLE_STALL` to them — the dropped command also delays the *other* banks past the poll timeout. Pairs with 0007. | **yes** |

| `0009-pmdomain-rockchip-arm-the-rk3576-npu-core-on-power-on.patch` | `pmdomain/rockchip` | **The cold-start arm.** On mainline the NPU core register block (`base+0x0`) is unreadable from a later ioctl -- vendor rknpu `GET_HW_VERSION` async-SErrors / hangs the board -- unless it is touched *during* the power-domain power-on, right after the BIU reset. The vendor BSP / the working buildroot linux-next kernel do exactly this; mainline never does, so the core comes up "on" but dead. Read `base+0x0` + cycle the MMU bank DTE regs in `rockchip_pd_power()` (npu0). Confirmed still needed: with 0010 in place the boot arm reads a valid NPU version (`0x46495245`, "FIRE") — a live core — where without it the core comes up dead. | **yes** |

| `0010-arm64-dts-rk3576-rock-4d-npu-vdd-always-on.patch` | `arm64: dts` | **The actual "second inference wedges the board" fix.** The board DTS marks the NPU rail `vdd_npu_s0` only `regulator-boot-on`, so the regulator core's boot-time cleanup (~30 s) disables it once the driver's probe balances its enable/disable. The genpd domain still reports "on" (PMU status is decoupled from the PMIC rail), so the next NPU use early-returns in `rockchip_pd_power()` without re-powering, and the driver reads an MMU register on a dead rail → the MMIO read never returns → CPU wedge / RCU stall. **The first inference after boot works, the second hangs.** The vendor BSP and the buildroot linux-next kernel (9.3 tok/s) mark this rail `regulator-always-on`; stock mainline does not. Add it so the rail stays up. **Verified on real hardware: with this line, ROCK 4D holds a multi-turn Qwen2.5-1.5B chat at 9.3 tok/s on pure mainline 7.1.3.** | **yes — the one that makes re-use work** |

For a **mainline** build apply **0001 … 0010** (the CI does). The split of labour,
now that the stack is verified end-to-end at 9.3 tok/s on pure mainline 7.1.3:

- **0001 + 0002 + 0005 + 0009** make the **cold** NPU power-on correct: settle
  delay, BIU reset pulse, full domain clocks, and the core "arm" (touch
  `base+0x0` during power-on) so the first NPU register read doesn't SError and
  the core comes up alive.
- **0003 + 0007 + 0008** are the iommu-side fixes (take all DT clocks; skip
  orphaned-fault MMU banks) that match the buildroot linux-next kernel and stop
  the iommu-resume stall-poll from wedging the board via CPU DVFS.
- **0010** is what makes **re-use** work: it keeps the NPU rail powered so the
  *second* inference lands on a live core instead of a dead one. This was the
  real root cause of the "first chat turn works, second wedges the board"
  symptom — not a pmdomain bug. An earlier draft of this file called **0006**
  and **0009** "the fix" for that; that was premature. 0006 still hardens the
  warm genpd path and 0009 is still needed for cold-start core liveness, but the
  wedge itself was the missing `regulator-always-on` on `vdd_npu_s0` (0010).

0006 also pairs with the driver-side "bail on power-on failure" shim in
`driver/apply-mainline-shims.sh` (belt and suspenders: any power-on failure
becomes a clean `rkllm init failed` instead of an SError panic).

The whole "keep the NPU resident via a sysfs `power/control=on` udev rule /
S89rknpu init" approach explored during bring-up was a **dead end** and is not
needed: the vendor driver already keeps the NPU warm 10 min between jobs
(`power_put_delay`), and sysfs runtime-PM cannot hold the driver's per-domain
`genpd_dev_npu*` votes anyway. The rail-always-on (0010) is the real fix.

## Provenance

Authored by Jiaxing Hu (`huhuvmb88`) during the RK3576 NPU bring-up. Verified to
apply to **mainline 7.1.3**: 0001 clean, 0003 clean (driver-only), 0004 clean and
compiles into a valid `rk3576-rock-4d.dtb`. They also apply to Armbian **edge**
7.1 (same base). They are **not upstream** — stock mainline / stock Armbian of any
version lacks them, which is why moving to a newer kernel alone does not help.

## Upstreaming status (honest — not yet submitted)

These are carried here to make the NPU work today; they are **not** LKML-ready as
written. Known review points before submission:

- **0001** — the 15 µs is empirical (it mirrors the vendor kernel's NPUTOP
  `delay_us`); a maintainer will want the delay tied to a documented NoC/settle
  timing, not "the vendor does it", and may ask for it as a DT property rather
  than hard-coded. The `udelay` sits in the genpd power path, so it must stay
  short.
- **0003** — the DT and driver changes are now split (this is the driver half;
  the NPU MMU node with the full clock set lives in 0004). Reviewers will scrutinise
  the `devm_clk_bulk_get_all()` `err == -ENOENT || err == 0` boundary.
- **0002** — optional; needs a matching `dt-bindings` addition for the
  power-domain `resets` and only fires when the DT provides them.
- **0004** — board/SoC DT; would go via the Rockchip DT tree, separate from the
  driver patches, and depends on the vendor `rknpu` binding being acceptable
  upstream (mainline's own NPU path is the open `accel/rocket` driver).

The long-term fix is to land 0001 (and 0003) in mainline so a **stock** kernel
runs the NPU with no rebuild.

## Applying

The mainline kernel build (see `../MAINLINE-KERNEL.md`) applies these with
`patch -p1` (or `git am`) on a `linux-7.1.3` tree; the Armbian build
(`../ARMBIAN-KERNEL.md`) drops 0001 into the framework's `userpatches/`. They are
ordinary `git format-patch` output.
