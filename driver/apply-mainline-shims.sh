#!/usr/bin/env bash
# Apply Kiln's mainline (7.x) build shims to the fetched vendor rknpu source.
#
# This patches driver/rknpu/ IN PLACE after fetch-vendor-driver.sh. It does NOT
# vendor any GPL driver code into Kiln: the source is fetched and patched at
# build time, never committed. The edits are the minimal set needed to build the
# v0.9.8 rknpu driver against a mainline kernel, verified against real source
# (see docs/VERIFICATION-REPORT.md, deliverable 5). Reference for the technique:
# w568w/rknpu-module.
#
# All edits are idempotent: re-running is a no-op. Each edit fails loudly if its
# expected anchor is missing, so a vendor source change can never be silently
# mis-patched.
set -euo pipefail

RKNPU="$(cd "$(dirname "$0")" && pwd)/rknpu"
DRV="$RKNPU/rknpu_drv.c"
GEM="$RKNPU/rknpu_gem.c"
IOMMU_C="$RKNPU/rknpu_iommu.c"
DBG="$RKNPU/rknpu_debugger.c"
DEVFREQ_H="$RKNPU/include/rknpu_devfreq.h"

for f in "$DRV" "$GEM" "$IOMMU_C" "$DBG" "$DEVFREQ_H"; do
	[ -f "$f" ] || { echo "[kiln] ERROR: $f not found. Run fetch-vendor-driver.sh first." >&2; exit 1; }
done

note() { echo "[kiln-shim] $*"; }

# ---------------------------------------------------------------------------
# Shim 1: drop `.date = DRIVER_DATE,` from struct drm_driver.
# The `date` member was removed from struct drm_driver in mainline (gone in 7.x).
# The assignment is purely informational, so removing it is version-agnostic.
# ---------------------------------------------------------------------------
if grep -qE '^\s*\.date = DRIVER_DATE,\s*$' "$DRV"; then
	perl -i -ne 'print unless /^\s*\.date = DRIVER_DATE,\s*$/' "$DRV"
	note "removed .date = DRIVER_DATE from drm_driver (rknpu_drv.c)"
else
	note "shim 1 already applied (.date not present)"
fi

# ---------------------------------------------------------------------------
# Shim 2: gate `.gem_prime_mmap` behind < 6.6.
# The gem_prime_mmap member was removed from struct drm_driver in 6.6. Add a
# 6.6 branch that emits nothing, keeping the existing 6.1/older assignments for
# older kernels. Anchor is the unique `#if 6.1` line immediately followed by the
# drm_gem_prime_mmap assignment, so the other `#if 6.1` guards are untouched.
# ---------------------------------------------------------------------------
if grep -qE '#if KERNEL_VERSION\(6, 6, 0\) <= LINUX_VERSION_CODE' "$DRV" \
   && grep -qE '\.gem_prime_mmap' "$DRV" \
   && perl -0777 -ne 'exit(!(/#if KERNEL_VERSION\(6, 6, 0\) <= LINUX_VERSION_CODE\n#elif KERNEL_VERSION\(6, 1, 0\) <= LINUX_VERSION_CODE\n\t\.gem_prime_mmap/))' "$DRV"; then
	note "shim 2 already applied (gem_prime_mmap gated < 6.6)"
elif perl -0777 -ne 'exit(!(/#if KERNEL_VERSION\(6, 1, 0\) <= LINUX_VERSION_CODE\n\t\.gem_prime_mmap = drm_gem_prime_mmap,/))' "$DRV"; then
	perl -0777 -i -pe 's/#if KERNEL_VERSION\(6, 1, 0\) <= LINUX_VERSION_CODE\n(\t\.gem_prime_mmap = drm_gem_prime_mmap,)/#if KERNEL_VERSION(6, 6, 0) <= LINUX_VERSION_CODE\n#elif KERNEL_VERSION(6, 1, 0) <= LINUX_VERSION_CODE\n$1/' "$DRV"
	note "gated .gem_prime_mmap behind < 6.6 (rknpu_drv.c)"
else
	echo "[kiln] ERROR: gem_prime_mmap anchor not found in $DRV (vendor source changed?)." >&2
	exit 1
fi

# ---------------------------------------------------------------------------
# Shim 3: drop `#include <linux/version_compat_defs.h>` from rknpu_gem.c.
# That header is a Mali/kbase compat shim not shipped standalone; mainline does
# not provide it. Nothing in the GEM path needs it.
# ---------------------------------------------------------------------------
if grep -qE '^\s*#include <linux/version_compat_defs\.h>\s*$' "$GEM"; then
	perl -i -ne 'print unless /^\s*#include <linux\/version_compat_defs\.h>\s*$/' "$GEM"
	note "removed <linux/version_compat_defs.h> include (rknpu_gem.c)"
else
	note "shim 3 already applied (version_compat_defs.h include not present)"
fi

# ---------------------------------------------------------------------------
# Shim 4: force the devfreq no-op fallback (DVFS off for bring-up).
# rknpu_devfreq.h selects real (non-inline) entry points under CONFIG_PM_DEVFREQ
# and no-op inlines otherwise. That macro comes from the target kernel's config,
# which is typically CONFIG_PM_DEVFREQ=y, so without this the build would expect
# rknpu_devfreq.o (which Kiln does not compile) and fail to link. Forcing the
# fallback branch makes rknpu_drv.c use the header's no-op inlines. All 6 entry
# points it calls (init, remove, lock, unlock, runtime_suspend, runtime_resume)
# are covered by that branch.
# ---------------------------------------------------------------------------
if grep -qE '^\s*#ifdef CONFIG_PM_DEVFREQ\s*$' "$DEVFREQ_H"; then
	perl -0777 -i -pe 's/#ifdef CONFIG_PM_DEVFREQ/#if 0 \/* Kiln: DVFS off for bring-up; use no-op fallbacks below *\//' "$DEVFREQ_H"
	note "forced devfreq no-op fallback (rknpu_devfreq.h)"
else
	note "shim 4 already applied (#ifdef CONFIG_PM_DEVFREQ not present)"
fi

# ===========================================================================
# Shims 5-12 below were found by ACTUALLY COMPILING the driver against mainline
# 7.1 (linux-next). Each is a real API drift between the vendor 6.1 base and 7.x.
# ===========================================================================

# ---------------------------------------------------------------------------
# Shim 5: MODULE_IMPORT_NS bare token -> string literal (6.13).
# MODULE_INFO now static_asserts the arg is a string literal.
# ---------------------------------------------------------------------------
if grep -qE 'MODULE_IMPORT_NS\([A-Z_][A-Z0-9_]*\)' "$DRV"; then
	perl -i -pe 's/MODULE_IMPORT_NS\(([A-Z_][A-Z0-9_]*)\)/MODULE_IMPORT_NS("$1")/g' "$DRV"
	note "quoted MODULE_IMPORT_NS argument (rknpu_drv.c)"
else
	note "shim 5 already applied (MODULE_IMPORT_NS quoted)"
fi

# ---------------------------------------------------------------------------
# Shim 6: hrtimer_init + .function -> hrtimer_setup (6.15).
# ---------------------------------------------------------------------------
if ! grep -qE 'hrtimer_setup\(&rknpu_dev->timer' "$DRV"; then
	perl -0777 -i -pe 's/\thrtimer_init\(&rknpu_dev->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL\);\n\trknpu_dev->timer\.function = hrtimer_handler;/#if KERNEL_VERSION(6, 15, 0) <= LINUX_VERSION_CODE\n\thrtimer_setup(&rknpu_dev->timer, hrtimer_handler, CLOCK_MONOTONIC,\n\t\t      HRTIMER_MODE_REL);\n#else\n\thrtimer_init(&rknpu_dev->timer, CLOCK_MONOTONIC, HRTIMER_MODE_REL);\n\trknpu_dev->timer.function = hrtimer_handler;\n#endif/' "$DRV"
	note "converted hrtimer_init to hrtimer_setup (rknpu_drv.c)"
else
	note "shim 6 already applied (hrtimer_setup)"
fi

# ---------------------------------------------------------------------------
# Shim 7: platform_driver.remove callback int -> void (6.11).
# ---------------------------------------------------------------------------
if ! grep -qE 'static void rknpu_remove\(struct platform_device' "$DRV"; then
	perl -0777 -i -pe 's/\nstatic int rknpu_remove\(struct platform_device \*pdev\)\n\{/\n#if KERNEL_VERSION(6, 11, 0) <= LINUX_VERSION_CODE\nstatic void rknpu_remove(struct platform_device *pdev)\n#else\nstatic int rknpu_remove(struct platform_device *pdev)\n#endif\n{/' "$DRV"
	perl -0777 -i -pe 's/\tpm_runtime_disable\(&pdev->dev\);\n\n\treturn 0;\n\}/\tpm_runtime_disable(&pdev->dev);\n\n#if KERNEL_VERSION(6, 11, 0) > LINUX_VERSION_CODE\n\treturn 0;\n#endif\n}/' "$DRV"
	note "made rknpu_remove return void on >= 6.11 (rknpu_drv.c)"
else
	note "shim 7 already applied (rknpu_remove void)"
fi

# ---------------------------------------------------------------------------
# Shim 8: rknpu_gem.c pfn_t.h removed (6.16) -> pfn.h + vmalloc.h.
# pfn_t.h is gone; vmap/vunmap/VM_MAP need vmalloc.h explicitly once it is.
# ---------------------------------------------------------------------------
if grep -qE '^#include <linux/pfn_t\.h>' "$GEM"; then
	perl -0777 -i -pe 's{#include <linux/pfn_t\.h>}{#include <linux/pfn.h>\n#include <linux/vmalloc.h>}' "$GEM"
	note "replaced pfn_t.h with pfn.h + vmalloc.h (rknpu_gem.c)"
else
	note "shim 8 already applied (pfn.h/vmalloc.h)"
fi

# ---------------------------------------------------------------------------
# Shim 9: vmf_insert_mixed() takes a raw pfn (pfn_t removed, 6.16).
# ---------------------------------------------------------------------------
if ! grep -qE 'vmf_insert_mixed\(vma, vmf->address, pfn\);' "$GEM"; then
	perl -0777 -i -pe 's{\treturn vmf_insert_mixed\(vma, vmf->address,\n\t\t\t\t__pfn_to_pfn_t\(pfn, PFN_DEV\)\);}{#if KERNEL_VERSION(6, 16, 0) <= LINUX_VERSION_CODE\n\treturn vmf_insert_mixed(vma, vmf->address, pfn);\n#else\n\treturn vmf_insert_mixed(vma, vmf->address,\n\t\t\t\t__pfn_to_pfn_t(pfn, PFN_DEV));\n#endif}' "$GEM"
	note "vmf_insert_mixed uses raw pfn on >= 6.16 (rknpu_gem.c)"
else
	note "shim 9 already applied (vmf_insert_mixed raw pfn)"
fi

# ---------------------------------------------------------------------------
# Shim 10: iommu_map() gained a trailing gfp_t argument (6.3). Redirect the
# vendor's 5-arg calls via a macro defined AFTER <linux/iommu.h> so the real
# 6-arg prototype is already seen (the macro affects only later call sites).
# ---------------------------------------------------------------------------
if ! grep -qE '#define iommu_map\(d, i, p, s, prot\)' "$GEM"; then
	perl -0777 -i -pe 's{(#include "rknpu_iommu\.h"\n)}{$1\n#if KERNEL_VERSION(6, 3, 0) <= LINUX_VERSION_CODE\n/* iommu_map() gained a trailing gfp_t arg in 6.3; vendor uses the 5-arg form.\n * Defined after <linux/iommu.h> so the real 6-arg prototype is already seen. */\n#define iommu_map(d, i, p, s, prot) iommu_map((d), (i), (p), (s), (prot), GFP_KERNEL)\n#endif\n}' "$GEM"
	note "added iommu_map gfp compat macro (rknpu_gem.c)"
else
	note "shim 10 already applied (iommu_map macro)"
fi

# ---------------------------------------------------------------------------
# Shim 11: rknpu_iommu.c: sg_is_dma_bus_address renamed to sg_dma_is_bus_address;
# iommu_map_sg() gained a trailing gfp_t argument (6.3).
# ---------------------------------------------------------------------------
if grep -qE '\bsg_is_dma_bus_address\b' "$IOMMU_C"; then
	perl -i -pe 's/\bsg_is_dma_bus_address\b/sg_dma_is_bus_address/g' "$IOMMU_C"
	note "renamed sg_is_dma_bus_address -> sg_dma_is_bus_address (rknpu_iommu.c)"
else
	note "shim 11a already applied (sg_dma_is_bus_address)"
fi
if ! grep -qE '#define iommu_map_sg\(d, i, sg, n, prot\)' "$IOMMU_C"; then
	perl -0777 -i -pe 's{(#include "rknpu_iommu\.h"\n)}{$1\n#if KERNEL_VERSION(6, 3, 0) <= LINUX_VERSION_CODE\n/* iommu_map_sg() gained a trailing gfp_t arg in 6.3; vendor uses the 5-arg form. */\n#define iommu_map_sg(d, i, sg, n, prot) iommu_map_sg((d), (i), (sg), (n), (prot), GFP_KERNEL)\n#endif\n}' "$IOMMU_C"
	note "added iommu_map_sg gfp compat macro (rknpu_iommu.c)"
else
	note "shim 11b already applied (iommu_map_sg macro)"
fi

# ---------------------------------------------------------------------------
# Shim 12: rknpu_debugger.c uses <../drivers/devfreq/governor.h> and update_devfreq
# under #ifdef CONFIG_PM_DEVFREQ (from the kernel config, typically =y). That
# in-tree relative include does not resolve for an out-of-tree module, and the
# DVFS path is off anyway. Force the no-op #else branch (same as shim 4).
# ---------------------------------------------------------------------------
if grep -qE '^#ifdef CONFIG_PM_DEVFREQ$' "$DBG"; then
	perl -0777 -i -pe 's/#ifdef CONFIG_PM_DEVFREQ/#if 0 \/* Kiln: DVFS off for bring-up *\//g' "$DBG"
	note "forced devfreq off in debugger (rknpu_debugger.c)"
else
	note "shim 12 already applied (debugger devfreq off)"
fi

# ---------------------------------------------------------------------------
# Shim 13: the devfreq-off no-op runtime PM callbacks must return 0, not
# -EOPNOTSUPP. With DVFS off (shims 4/12), rknpu_runtime_resume/suspend call
# rknpu_devfreq_runtime_resume/suspend, whose no-op fallbacks return -EOPNOTSUPP;
# that flows through pm_runtime_get_sync(dev) and rknpu_power_on leaks it, so
# probe fails with -95 (observed on board: "failed to get pm runtime for rknpu,
# ret: -95"). A no-op runtime resume/suspend must succeed. Leave the (ignored)
# rknpu_devfreq_init return as-is.
# ---------------------------------------------------------------------------
if grep -qzE 'rknpu_devfreq_runtime_resume\(struct device \*dev\)\n\{\n\treturn -EOPNOTSUPP;' "$DEVFREQ_H"; then
	perl -0777 -i -pe 's/(static inline int rknpu_devfreq_runtime_(?:suspend|resume)\(struct device \*dev\)\n\{\n\treturn )-EOPNOTSUPP;/${1}0;/g' "$DEVFREQ_H"
	note "devfreq-off runtime PM no-ops return 0 (rknpu_devfreq.h)"
else
	note "shim 13 already applied (runtime no-ops return 0)"
fi

# ---------------------------------------------------------------------------
# Shim 14: fix struct rknpu_iommu_dma_cookie layout. rknpu_iommu.c casts the
# mainline domain->iova_cookie (an opaque struct iommu_dma_cookie *) to this
# vendor struct and reads ->iovad. Mainline removed the leading
# `enum iommu_dma_cookie_type type` field (and the enum) from iommu_dma_cookie,
# so iovad is now at offset 0. The vendor struct kept `type` first, putting its
# iovad at offset 8 -> reading a garbage iova_domain -> alloc_iova() derefs a
# bad rbtree lock -> kernel Oops when librkllmrt allocates NPU memory (observed:
# "Unable to handle kernel paging request" in rknpu_iommu_dma_alloc_iova ->
# alloc_iova -> queued_spin_lock_slowpath). Guard the `type` field out so iovad
# is first on mainline.
# ---------------------------------------------------------------------------
IOMMU_H="$RKNPU/include/rknpu_iommu.h"
if grep -qzE 'struct rknpu_iommu_dma_cookie \{\n\tenum iommu_dma_cookie_type type;' "$IOMMU_H"; then
	perl -0777 -i -pe 's/(struct rknpu_iommu_dma_cookie \{\n)\tenum iommu_dma_cookie_type type;\n/${1}#if KERNEL_VERSION(6, 8, 0) > LINUX_VERSION_CODE\n\tenum iommu_dma_cookie_type type;\n#endif\n/' "$IOMMU_H"
	note "put iova_domain at offset 0 in rknpu_iommu_dma_cookie (rknpu_iommu.h)"
else
	note "shim 14 already applied (cookie iovad at offset 0)"
fi

note "all mainline shims applied."
echo "[kiln] driver/rknpu is now patched for mainline. Build with: make KDIR=<your-kernel-build>"
