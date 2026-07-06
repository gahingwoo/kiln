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
| `0002-pmdomain-rockchip-cycle-pd-resets.patch` | `pmdomain/rockchip` | Optional per-domain reset pulse on power-on for domains whose bus interface needs a reset edge. Only fires if the power-domain DT node carries `resets` (needs a matching DT change), so it is a no-op on stock Armbian DT. | optional |
| `0003-iommu-rockchip-take-all-dt-clocks.patch` | `iommu/rockchip` | Take all DT clocks by index instead of the named `aclk`/`iface` pair, so the NPU MMU nodes' clocks are managed. Fixes the harmless `rk_iommu ... Failed to get clk 'aclk'` `-ENOENT`; the clocks are already on (enabled by the NPU node), so this is cosmetic for Kiln. | optional (cosmetic) |

Start with **0001 only**. It is the minimum that makes NPU inference work; 0002
and 0003 address non-fatal / DT-dependent details.

## Provenance

Authored by gahingwoo (`huhuvmb88`) for the RK3576 NPU bring-up, on top of the
`linux-next` 20260527 snapshot (so they apply cleanly to Armbian **edge** 7.1,
which shares that base — not to 6.19). They are **not upstream**: stock mainline
/ stock Armbian of any version does not have them, which is why simply moving to
a newer Armbian kernel does not help. The long-term fix is to land 0001 in
mainline (and/or Armbian's kernel patch set) so a stock Armbian edge kernel runs
the NPU with no rebuild.

## Applying

These are consumed by the Armbian kernel build (see `../ARMBIAN-KERNEL.md`),
which drops them into the Armbian build framework's `userpatches/` and produces a
patched `linux-image-*.deb`. They are ordinary `git format-patch` output and also
apply with `patch -p1` against an Armbian edge kernel source tree.
