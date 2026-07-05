/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kiln build-time compat stub for <soc/rockchip/rockchip_iommu.h>.
 *
 * The vendor BSP ships this header; mainline does not. The rknpu driver uses
 * exactly one symbol from it in a compiled path:
 *   rknpu_drv.c: readx_poll_timeout(rockchip_iommu_is_enabled, dev, val, !val, ...)
 * in rknpu_power_off(), waiting until the NPU MMU is DISABLED before cutting
 * power, so the vendor BSP's asynchronous IOMMU runtime-suspend does not touch
 * powered-off registers.
 *
 * On mainline this wait is unnecessary and must NOT block: the platform IOMMU
 * (drivers/iommu/rockchip-iommu.c, "rockchip,rk3568-iommu") is a real device in
 * the NPU power domain (see the rknpu_mmu_0/1 power-domains) with a device-link
 * to the NPU, so genpd runs the IOMMU suspend callback while still powered and
 * only then drops the domain -- no post-power-off register access. Return
 * FALSE so the poll's `!val` condition is met immediately and power-off
 * proceeds. (An earlier version returned true whenever the device had an IOMMU
 * group, which is ALWAYS true here -> the poll timed out every idle power-off
 * with "iommu still enabled", observed on board.)
 *
 * Reference for the stub approach: w568w/rknpu-module (out-of-tree port).
 */
#ifndef __SOC_ROCKCHIP_IOMMU_H
#define __SOC_ROCKCHIP_IOMMU_H

#include <linux/device.h>
#include <linux/iommu.h>

static inline bool rockchip_iommu_is_enabled(struct device *dev)
{
	/* mainline genpd + device-links handle IOMMU suspend ordering; don't wait */
	return false;
}

static inline void rockchip_iommu_enable(struct device *dev)
{
	/* no-op: mainline rockchip-iommu enables on attach */
}

static inline void rockchip_iommu_disable(struct device *dev)
{
	/* no-op: mainline rockchip-iommu disables on detach */
}

#endif /* __SOC_ROCKCHIP_IOMMU_H */
