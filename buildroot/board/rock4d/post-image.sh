#!/usr/bin/env bash
# Kiln ROOTFS_POST_IMAGE_SCRIPT: assemble a flashable sdcard.img for ROCK 4D.
# Adapted from the rocket tree's board/rock4d/post-image.sh. Layout: 16 MiB
# u-boot + 128 MiB FAT32 /boot + the ext4 rootfs.
set -euo pipefail

BINARIES="${BINARIES_DIR:-${1:?missing binaries dir}}"
ROCKCHIP_BIN="${ROCKCHIP_BINARIES:?set ROCKCHIP_BINARIES to your rock4d u-boot dir}"
OUT="${BINARIES}/sdcard.img"
# The defconfig builds the stock in-tree DTS name rockchip/rk3576-rock-4d, so the
# kernel installs rk3576-rock-4d.dtb (the vendor rknpu node is added to that dtb
# by kernel-patches/0004). Override with KILN_DTB only for a custom name.
DTB="${KILN_DTB:-rk3576-rock-4d.dtb}"
# Dual-image: the ROCKET variant dtb (open accel/rocket binds npu@27700000). If
# it was built, the boot menu offers a second "rocket" entry; else kiln-only.
ROCKET_DTB="${KILN_ROCKET_DTB:-rk3576-rock-4d-rocket.dtb}"

UBOOT_IMG="${UBOOT_IMG:-${ROCKCHIP_BIN}/rock4d-sd-uboot.img}"
UBOOT_MB=16
BOOT_MB=128
ROOTFS_MB=$(( $(stat -c%s "${BINARIES}/rootfs.ext2") / 1024 / 1024 + 8 ))
TOTAL_MB=$(( UBOOT_MB + BOOT_MB + ROOTFS_MB ))

echo "==> Kiln post-image: building ${OUT}  (${TOTAL_MB} MiB)"
for cmd in mtools dd sfdisk mkfs.fat; do command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }; done
[[ -f "${UBOOT_IMG}" ]] || { echo "ERROR: ${UBOOT_IMG} not found"; exit 1; }
[[ -f "${BINARIES}/Image" ]] || { echo "ERROR: ${BINARIES}/Image not found"; exit 1; }
[[ -f "${BINARIES}/${DTB}" ]] || { echo "ERROR: ${DTB} not found in ${BINARIES}"; exit 1; }
[[ -f "${BINARIES}/rootfs.ext2" ]] || { echo "ERROR: rootfs.ext2 not found"; exit 1; }

truncate -s "${TOTAL_MB}M" "${OUT}"
dd if="${UBOOT_IMG}" of="${OUT}" bs=1M conv=notrunc status=none

BOOT_START=32768
BOOT_SECTORS=$(( BOOT_MB * 2048 ))
ROOT_START=$(( BOOT_START + BOOT_SECTORS ))
ROOT_SECTORS=$(( ROOTFS_MB * 2048 ))
sfdisk --quiet "${OUT}" <<SFDISK
label: dos
unit: sectors
start=${BOOT_START},  size=${BOOT_SECTORS}, type=c
start=${ROOT_START}, size=${ROOT_SECTORS}, type=83
SFDISK

BOOT_FAT_IMG="$(mktemp /tmp/boot.XXXXXX.fat)"
trap 'rm -f "${BOOT_FAT_IMG}"' EXIT
truncate -s "$(( BOOT_MB * 1024 * 1024 ))" "${BOOT_FAT_IMG}"
export MTOOLS_SKIP_CHECK=1
mkfs.fat -F32 -n BOOT "${BOOT_FAT_IMG}" >/dev/null
mcopy -i "${BOOT_FAT_IMG}" "${BINARIES}/Image" ::Image
mcopy -i "${BOOT_FAT_IMG}" "${BINARIES}/${DTB}" ::${DTB}

APPEND='console=ttyS0,1500000n8 earlycon=uart8250,mmio32,0x2ad40000 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw clk_ignore_unused log_buf_len=8M'
EXTLINUX_CONF="$(mktemp /tmp/extlinux.XXXXXX.conf)"
# Default = KILN (vendor rknpu). If the rocket variant dtb was built, add a
# second selectable entry -- a menu prompt lets the operator pick at boot.
# NOTE for the env-trace comparison: a FULL POWER-CYCLE (not warm reboot) between
# the two modes is required -- the NPU cold-start arm is per-power-session.
cat > "${EXTLINUX_CONF}" <<EOF
default kiln
menu title Kiln RK3576 -- pick the NPU driver (power-cycle between modes)
prompt 1
timeout 50

label kiln
    menu label Kiln (vendor rknpu + RKLLM/RKNN)
    kernel /Image
    fdt /${DTB}
    append ${APPEND}
EOF
if [[ -f "${BINARIES}/${ROCKET_DTB}" ]]; then
	mcopy -i "${BOOT_FAT_IMG}" "${BINARIES}/${ROCKET_DTB}" ::${ROCKET_DTB}
	cat >> "${EXTLINUX_CONF}" <<EOF

label rocket
    menu label rocket (open accel/rocket driver)
    kernel /Image
    fdt /${ROCKET_DTB}
    append ${APPEND}
EOF
	echo "==> dual-image: kiln + rocket boot entries (default kiln)"
else
	echo "==> single-image: kiln only (${ROCKET_DTB} not found)"
fi
mmd  -i "${BOOT_FAT_IMG}" ::extlinux
mcopy -i "${BOOT_FAT_IMG}" "${EXTLINUX_CONF}" ::extlinux/extlinux.conf
rm -f "${EXTLINUX_CONF}"

dd if="${BOOT_FAT_IMG}" of="${OUT}" bs=512 seek="${BOOT_START}" conv=notrunc status=none
dd if="${BINARIES}/rootfs.ext2" of="${OUT}" bs=512 seek="${ROOT_START}" conv=notrunc status=none
echo "==> Kiln sdcard.img ready: ${OUT}"
