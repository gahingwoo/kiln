# kiln-mainline.patch

One patch against the pinned pristine vendor rknpu v0.9.8 source
(`armbian/linux-rockchip` `rk-6.1-rkr6.1` `drivers/rknpu`). `fetch-vendor-driver.sh`
pulls the GPL source; `apply-mainline-shims.sh` applies this patch. The vendor
driver is not committed here — only Kiln's modifications (this patch) are.

It is deliberately a single, deterministic patch rather than a set of in-place
regex edits: the source is pinned, so a patch reproduces the exact working
driver every time and fails loudly if the vendor source ever drifts.

## Layer 1 — mainline (6.1 → 7.x) build shims

The API drift that stops the 6.1-era vendor driver from compiling on a modern
kernel. Each is version-guarded so the patched source still builds on 6.6/6.19/7.x.

| Change | Reason |
|---|---|
| drop `.date = DRIVER_DATE` | `date` removed from `struct drm_driver` |
| gate `.gem_prime_mmap` `< 6.6` | member removed from `struct drm_driver` in 6.6 |
| `MODULE_IMPORT_NS` string literal | became a string literal in 6.13 |
| `hrtimer_init` → `hrtimer_setup` | API renamed in 6.15 |
| `struct platform_driver.remove` returns void | signature changed in 6.11 |
| drop `<linux/pfn_t.h>`, add `<linux/vmalloc.h>` | `pfn_t.h` removed in 6.16 |
| `iommu_map` / `iommu_map_sg` gfp arg | gained a trailing `gfp_t` in 6.3 |
| `sg_is_dma_bus_address` → `sg_dma_is_bus_address` | renamed |
| devfreq runtime callbacks return `0` | no-op DVFS for bring-up (no vendor OPP stack) |
| guard `enum iommu_dma_cookie_type type` out | mainline `iommu_dma_cookie` put `iovad` at offset 0; keeping the vendor's leading `type` field mis-offsets `iovad` → Oops in `alloc_iova` |

## Layer 2 — RK3576 NPU-execution fixes

Without these the driver loads and `librkllmrt` loads the model, but every NPU
job times out (`task_counter=0`, `raw status 0x30000000`, DPU-done `0x300` never
set). These are the real "make matmul run on mainline" changes.

- **`rknpu_mmu_enable_all()`** (rknpu_drv.c) — the NPU is one device with two
  IOMMUs (`rknpu_mmu_0/1`), but mainline `rockchip-iommu` manages only a single
  *primary* iommu per device (`dev_iommu_priv_get`), so the second core's MMU is
  never attached/enabled: its jobs read the regcmd IOVA as a raw physical address
  → garbage → `task_counter=0`, no page fault. This learns the page-directory
  base from the bank the kernel did enable and mirrors it onto all four banks
  (write DTE, ZAP, unmask IRQ, ENABLE_PAGING). Called after every power-on.
- **per-job MMU TLB ZAP** (rknpu_job.c) — mainline only invalidates the primary
  iommu on unmap, so the orphan MMU accumulates stale IOVA→PA entries as the
  runtime churns buffers → output degrades into repetition/garbage → segfault.
  ZAP both banks of the committing core before every job.
- **force-resume the platform IOMMU devices** (rknpu_drv.c) — the NPU power-domain
  cycle wipes the MMU; the `dev->iommu` device-link resume doesn't re-fire in this
  multi-domain genpd setup, so rknpu resolves the `iommus` phandles and
  `pm_runtime_get_sync`s them per power-on.
- **re-enable MMUs after `soft_reset`** (rknpu_reset.c) — `soft_reset` (issued on
  a job timeout) resets both MMUs; call `rknpu_mmu_enable_all()` so the next job
  isn't left MMU-off.
- **pin 594 MHz NPU clock** (rknpu_drv.c) — with devfreq off nothing sets the
  compute clock; pin a clean GPLL/2 rate on power-up.
- **`power_put_delay = 600000`** (rknpu_drv.c) — keep the NPU warm across a chat
  turn; a power-domain cycle mid-conversation cold-starts the next inference,
  which degrades. 10 min covers realistic pacing, still idles down eventually.

## Regenerating

```sh
# baseline = fresh pristine + this patch; working = your edited driver/rknpu
diff -ruN <pristine>/rknpu driver/rknpu > driver/patches/kiln-mainline.patch
# then strip absolute paths in the +++ lines back to rknpu/...
```
