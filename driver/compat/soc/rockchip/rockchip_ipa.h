/* SPDX-License-Identifier: GPL-2.0 */
/*
 * Kiln build-time compat stub for <soc/rockchip/rockchip_ipa.h>.
 *
 * Mainline has no such header. struct rknpu_device holds only a POINTER
 * (`struct ipa_power_model_data *model_data`, rknpu_drv.h), so an incomplete
 * type suffices for the compiled units. The IPA power-model math lives in
 * rknpu_devfreq.c, which Kiln does not build (DVFS off for bring-up).
 */
#ifndef __SOC_ROCKCHIP_IPA_H
#define __SOC_ROCKCHIP_IPA_H

struct ipa_power_model_data;

#endif /* __SOC_ROCKCHIP_IPA_H */
