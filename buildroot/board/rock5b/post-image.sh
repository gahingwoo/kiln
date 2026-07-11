#!/usr/bin/env bash
# Kiln RK3588 (ROCK 5B) ROOTFS_POST_IMAGE_SCRIPT: assemble a flashable sdcard.img.
# Adapted from board/rock4d/post-image.sh. Layout: 16 MiB u-boot + 128 MiB FAT32
# /boot + the ext4 rootfs.
#
# SKELETON, not hardware-validated. You must supply a ROCK 5B u-boot image
# ($ROCKCHIP_BINARIES/rock5b-sd-uboot.img or set UBOOT_IMG) -- Kiln ships none.
# The console/earlycon below use RK3588 UART2 @ 0xfeb50000 (serial2), which is the
# ROCK 5B debug console (verified in rk3588-rock-5b-5bp-5t.dtsi: stdout-path =
# "serial2:1500000n8").
set -euo pipefail

BINARIES="${BINARIES_DIR:-${1:?missing binaries dir}}"
ROCKCHIP_BIN="${ROCKCHIP_BINARIES:?set ROCKCHIP_BINARIES to your rock5b u-boot dir}"
OUT="${BINARIES}/sdcard.img"
# The defconfig builds rockchip/rk3588-rock-5b-kiln (vendor rknpu). Override with
# KILN_DTB only for a custom name.
DTB="${KILN_DTB:-rk3588-rock-5b-kiln.dtb}"
# Optional dual-image: the STOCK rk3588-rock-5b.dtb drives the NPU with the open
# accel/rocket driver. If it was also built, the boot menu offers a "rocket" entry.
ROCKET_DTB="${KILN_ROCKET_DTB:-rk3588-rock-5b.dtb}"

UBOOT_IMG="${UBOOT_IMG:-${ROCKCHIP_BIN}/rock5b-sd-uboot.img}"
UBOOT_MB=16
BOOT_MB=128
ROOTFS_MB=$(( $(stat -c%s "${BINARIES}/rootfs.ext2") / 1024 / 1024 + 8 ))
TOTAL_MB=$(( UBOOT_MB + BOOT_MB + ROOTFS_MB ))

echo "==> Kiln post-image (RK3588/ROCK 5B): building ${OUT}  (${TOTAL_MB} MiB)"
for cmd in mtools dd sfdisk mkfs.fat; do command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }; done
[[ -f "${UBOOT_IMG}" ]] || { echo "ERROR: ${UBOOT_IMG} not found (supply a ROCK 5B u-boot image)"; exit 1; }
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

# RK3588 debug console = UART2 @ 0xfeb50000 (serial2), 1500000 baud.
APPEND='console=ttyS2,1500000n8 earlycon=uart8250,mmio32,0xfeb50000 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait rw clk_ignore_unused log_buf_len=8M'
EXTLINUX_CONF="$(mktemp /tmp/extlinux.XXXXXX.conf)"
cat > "${EXTLINUX_CONF}" <<EOF
default kiln
menu title Kiln RK3588 -- pick the NPU driver (power-cycle between modes)
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
