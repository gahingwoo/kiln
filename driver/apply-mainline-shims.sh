#!/usr/bin/env bash
# Apply Kiln's mainline port + RK3576 NPU-execution fixes to the fetched vendor
# rknpu v0.9.8 source. Run automatically by fetch-vendor-driver.sh.
#
# This applies ONE deterministic patch (patches/kiln-mainline.patch) against the
# pinned pristine source (armbian linux-rockchip rk-6.1-rkr6.1 drivers/rknpu).
# It does NOT commit the vendor GPL driver: fetch-vendor-driver.sh pulls the full
# source, and only Kiln's modifications (this patch, with minimal context) live
# in the repo. GPL-2.0, same as the driver it patches.
#
# The patch has two layers:
#   1. mainline (6.1 -> 7.x) BUILD shims -- the API drift that stops the vendor
#      driver compiling on a modern kernel: drop drm_driver .date, gate
#      .gem_prime_mmap < 6.6, MODULE_IMPORT_NS string literal, hrtimer_setup,
#      void platform .remove, pfn.h/vmalloc.h, iommu_map / iommu_map_sg gfp arg,
#      sg_dma_is_bus_address rename, devfreq no-op callbacks, and the
#      iommu_dma_cookie layout (iovad now at offset 0).
#   2. RK3576 NPU-EXECUTION fixes -- what makes matmul actually run on mainline
#      (without these the vendor driver loads but every job times out,
#      task_counter=0). See patches/README.md for the why of each:
#        - rknpu_mmu_enable_all(): enable ALL four MMU banks incl. the "orphan"
#          MMU that mainline rockchip-iommu never attaches (single-primary model);
#        - per-job MMU TLB ZAP so the orphan MMU cannot serve stale translations;
#        - force-resume the platform IOMMU devices on every power-on;
#        - re-enable the MMUs after soft_reset;
#        - pin a clean 594 MHz NPU clock (GPLL/2) with devfreq off;
#        - 10-min power-put delay to keep the NPU warm across a chat turn.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RKNPU="$HERE/rknpu"
PATCH="$HERE/patches/kiln-mainline.patch"

[ -d "$RKNPU" ] || { echo "[kiln] ERROR: $RKNPU not found. Run fetch-vendor-driver.sh first." >&2; exit 1; }
[ -f "$PATCH" ] || { echo "[kiln] ERROR: $PATCH missing." >&2; exit 1; }

# Idempotent: a marker unique to the patch means it is already applied.
if grep -q "rknpu_mmu_enable_all" "$RKNPU/rknpu_drv.c" 2>/dev/null; then
	echo "[kiln] shims already applied (rknpu_mmu_enable_all present); nothing to do."
	exit 0
fi

echo "[kiln] applying kiln-mainline.patch to the fetched rknpu source ..."
if ! patch -p0 -d "$HERE" --no-backup-if-mismatch < "$PATCH"; then
	echo "[kiln] ERROR: patch did not apply cleanly. The fetched vendor source has" >&2
	echo "        probably drifted from the pinned rk-6.1-rkr6.1 v0.9.8 baseline." >&2
	echo "        Re-pin fetch-vendor-driver.sh or regenerate patches/kiln-mainline.patch." >&2
	exit 1
fi

echo "[kiln] driver/rknpu is patched for mainline + RK3576 NPU execution."
echo "[kiln] build with: make KDIR=<your-kernel-build>"
