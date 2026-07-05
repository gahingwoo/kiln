# Kiln out-of-tree build of the vendor rknpu driver (v0.9.8) for mainline.
# The driver sources live under driver/rknpu/ after fetch-vendor-driver.sh.
# Adjust the object list to match the fetched tree if the vendor changes files.
#
# Memory-manager choice: DRM_GEM, not DMA_HEAP.
#   librkllmrt (the LLM runtime) discovers the NPU via the DRM render node
#   (matches DRM driver name "rknpu", allocates GEM handles: verified against
#   librkllmrt.so symbols). It does NOT use the /dev/rknpu misc device that the
#   DMA_HEAP path (rknpu_mem.c) provides. Building DRM_GEM therefore drops the
#   rknpu_mem.o / rknpu_mm.o objects AND removes the <linux/rk-dma-heap.h>
#   dependency entirely (that header is only pulled in under DMA_HEAP).
# Same config W568W uses to run this driver on mainline 6.19/7.0.

obj-m += rknpu.o

# Memory manager + optional features are selected here because there is no
# Kconfig in an out-of-tree build. These -D flags gate code inside the vendor
# sources (e.g. the whole DRM registration is under CONFIG_ROCKCHIP_RKNPU_DRM_GEM).
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DRM_GEM
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_FENCE
ccflags-y += -DCONFIG_ROCKCHIP_RKNPU_DEBUG_FS

rknpu-objs := \
	driver/rknpu/rknpu_drv.o \
	driver/rknpu/rknpu_job.o \
	driver/rknpu/rknpu_gem.o \
	driver/rknpu/rknpu_fence.o \
	driver/rknpu/rknpu_iommu.o \
	driver/rknpu/rknpu_reset.o \
	driver/rknpu/rknpu_debugger.o

# Intentionally omitted objects:
#  - rknpu_mem.o (DMA_HEAP path): hard-includes <linux/rk-dma-heap.h>, absent in
#    mainline; not needed for the DRM_GEM / LLM path (verified: librkllmrt uses
#    the DRM render node + GEM, not the /dev/rknpu misc device).
#  - rknpu_mm.o (SRAM path): needs CONFIG_ROCKCHIP_RKNPU_SRAM / NO_GKI.
#  - rknpu_devfreq.o (DVFS): pulls in the vendor OPP/system-monitor/ipa stack.
#    For bring-up the NPU runs at a fixed rate. rknpu_devfreq.h already ships
#    no-op inline fallbacks for the 6 entry points rknpu_drv.c calls (init,
#    remove, lock, unlock, runtime_suspend, runtime_resume); apply-mainline-shims.sh
#    forces that fallback branch so this object is not required to link.

# -I order: put the build-time compat stubs (soc/rockchip/*, rockchip_iommu.h)
# BEFORE the driver's own include dir so they shadow the missing vendor headers.
ccflags-y += -I$(src)/driver/compat
ccflags-y += -I$(src)/driver/rknpu/include
