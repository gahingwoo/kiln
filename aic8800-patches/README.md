# aic8800 patches (Wi-Fi/BT on Linux 7.1)

The Radxa ROCK 4D's onboard Wi-Fi/BT is an **AIC8800** driven by the out-of-tree
[`radxa-pkg/aic8800`](https://github.com/radxa-pkg/aic8800) fullmac driver. It is
**not in mainline**, and even its latest release (5.0, Jan 2026) does not build on
Linux 7.1 — so after Kiln moves the board to a mainline 7.1.3 kernel, stock
aic8800 fails to compile and Wi-Fi/BT drop. That is not acceptable ("install Kiln,
get the NPU, lose Wi-Fi"), so Kiln carries the compat fix here until it lands
upstream in radxa-pkg/aic8800.

## The patch

`0001-aic8800-cfg80211-7.1-net_device-to-wireless_dev.patch`

Linux 7.1 changed a batch of `struct cfg80211_ops` key/station callbacks — and
the `cfg80211_new_sta()` / `cfg80211_del_sta()` helpers — to take a
`struct wireless_dev *` instead of a `struct net_device *`. The patch switches the
aic8800 fullmac driver's callbacks to the new signatures, all behind
`#if LINUX_VERSION_CODE >= KERNEL_VERSION(7, 0, 0)` so older kernels keep the old
paths. Touched (in `src/USB/driver_fw/drivers/aic8800/aic8800_fdrv/`):

- **rwnx_main.c** — `add_key` / `get_key` / `del_key` / `add_station` /
  `del_station` / `change_station` / `get_station` / `dump_station`, plus
  `set_default_mgmt_key` (also switched to `wireless_dev`) and `get_tx_power`
  (7.1 added `radio_idx` + `link_id`); internal callers and the
  `cfg80211_new_sta`/`cfg80211_del_sta` call sites pass `&rwnx_vif->wdev`.
- **rwnx_tdls.c** — the `ieee80211_mgmt.u.action` inner union became anonymous in
  7.1 and `action_code` moved into the action header; the TDLS discover-response
  path is adjusted.
- **rwnx_rx.c** — `in_irq()` (removed in mainline) → `in_hardirq()`.

The BT half (`aic_btusb`) builds unchanged on 7.1.3.

## Firmware (also required)

The driver is only half of it: `aic_load_fw` downloads chip firmware from
`/lib/firmware/<chip>/` (the chip is auto-detected — on the ROCK 4D it is the
**AIC8800D80**, so `/lib/firmware/aic8800D80/fw_patch_table_8800d80_u02.bin` etc.).
Without matching firmware the USB bus never comes up (`bus is not up`, no `wlan0`).
The stock aic8800-firmware package (paired with the old v4 driver) is a version
mismatch for the v5 driver, so `kiln-install.sh` also copies
`src/USB/driver_fw/fw/*` from the v5 tree into `/lib/firmware/`.

## Status

Verified to **compile** against a mainline 7.1.3 tree (`aic8800_fdrv.ko` links,
zero errors). Final proof is `insmod` on the running kernel + Wi-Fi associate;
`kiln-install.sh` builds and installs this patched driver via DKMS so the board
keeps Wi-Fi on the Kiln kernel. Applies with `patch -p1` on the
`radxa-pkg/aic8800` source tree.

The upstream fix is a PR to `radxa-pkg/aic8800`; once merged, this patch is
retired.
