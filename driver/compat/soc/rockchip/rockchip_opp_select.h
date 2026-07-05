/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kiln build-time compat stub for <soc/rockchip/rockchip_opp_select.h>.
 *
 * Mainline has no such header. The rknpu driver only needs this type to be
 * complete: struct rknpu_device embeds `struct rockchip_opp_info opp_info` BY
 * VALUE (rknpu_drv.h), so every translation unit that includes rknpu_drv.h must
 * know its size. The DVFS path (rknpu_devfreq.c) is not built. One accessor is
 * still reached in a compiled unit: rknpu_drv.c:rknpu_get_invalid_core_mask()
 * calls rockchip_nvmem_cell_read_u8(), but only when the DT rknpu node has a
 * "cores" nvmem-cell (the Kiln node does not), so at runtime the call is
 * skipped; the stub only needs to compile. It returns -ENOSYS.
 *
 * If you later re-enable rknpu_devfreq.o, replace this with the real vendor
 * header (it defines the leakage/pvtm/scmi_clk fields the DVFS path uses).
 */
#ifndef __SOC_ROCKCHIP_OPP_SELECT_H
#define __SOC_ROCKCHIP_OPP_SELECT_H

#include <linux/of.h>
#include <linux/errno.h>
#include <linux/types.h>

struct rockchip_opp_info {
	int dummy;
};

static inline int rockchip_nvmem_cell_read_u8(struct device_node *np,
					      const char *cell_id, u8 *val)
{
	return -ENOSYS;
}

#endif /* __SOC_ROCKCHIP_OPP_SELECT_H */
