/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kiln build-time compat stub for <soc/rockchip/rockchip_system_monitor.h>.
 *
 * Mainline has no such header. struct rknpu_device holds only a POINTER
 * (`struct monitor_dev_info *mdev_info`, rknpu_drv.h), so an incomplete type is
 * enough for the compiled units. The full definitions and the register/adjust
 * helpers live in rknpu_devfreq.c, which Kiln does not build (DVFS off for
 * bring-up). If you re-enable devfreq, use the real vendor header instead.
 */
#ifndef __SOC_ROCKCHIP_SYSTEM_MONITOR_H
#define __SOC_ROCKCHIP_SYSTEM_MONITOR_H

struct monitor_dev_info;
struct monitor_dev_profile;

#endif /* __SOC_ROCKCHIP_SYSTEM_MONITOR_H */
