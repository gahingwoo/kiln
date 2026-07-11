#!/usr/bin/env bash
# Kiln: build a flashable ROCK 4D sdcard.img (mainline kernel + out-of-tree
# vendor rknpu.ko + version-locked librkllmrt/librknnrt).
#
# Reuses the rocket tree's buildroot SOURCE (br-src) and the kernel tree that
# already carries the RK3576 IOMMU/PD/clock platform patches. No source under
# The NPU compute node is in the kernel DTB via kernel-patches/0004 (the KERNEL_SRC
# tree must have kernel-patches/ 0001-0010 applied); the 713 defconfig builds the
# in-tree rockchip/rk3576-rock-4d dtb, no custom DTS.
#
# These external inputs live OUTSIDE this repo. Point KILN_REF_ROOT at the dir
# that holds the reference trees, or override any single path below. Nothing here
# hardcodes an author-specific absolute path -- KILN_REF_ROOT defaults to
# $HOME/Desktop only as a convenience; set it to wherever you cloned the refs.
set -euo pipefail

# ---- external reference trees (override via env; not in this repo) -----------
KILN_REF_ROOT="${KILN_REF_ROOT:-$HOME/Desktop}"
BR_SRC="${BR_SRC:-$KILN_REF_ROOT/linux-rk3576-npu/buildroot/br-src}"                 # buildroot source
# DUAL image: mainline 7.1.3 + vendor kernel-patches 0001-0010 + the open rocket
# RK3576 series (accel/rocket rknn_core). Both NPU drivers coexist; the two DTB
# variants (rk3576-rock-4d{,-rocket}) pick which one binds npu@27700000 at boot.
# Default = the in-tree tree built by scripts/build-dual-kernel-tree.sh.
KERNEL_SRC="${KERNEL_SRC:-$(cd "$(dirname "$0")/.." && pwd)/kernel-dual/linux-7.1.3}"
BASE_CONFIG="${BASE_CONFIG:-$KILN_REF_ROOT/linux-rk3576-npu/kernel/base.config}"     # kernel .config base
ROCKCHIP_BINARIES="${ROCKCHIP_BINARIES:-$KILN_REF_ROOT/rock4d_package/binaries}"     # rock4d u-boot dir
# Kiln-only image: the open rocket driver + its userspace are NOT included.
# -----------------------------------------------------------------------------

KILN="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$KILN/buildroot"
OUT="${OUT:-$KILN/br-out}"                # writable buildroot output (in-tree, not under the read-only refs)
export ROCKCHIP_BINARIES

for p in "$BR_SRC/Makefile" "$KERNEL_SRC/Makefile" "$BASE_CONFIG" "$ROCKCHIP_BINARIES/rock4d-sd-uboot.img"; do
	[ -e "$p" ] || { echo "ERROR: not found: $p (edit the paths at the top of $0)"; exit 1; }
done

echo "==> Kiln build: BR_SRC=$BR_SRC KERNEL_SRC=$KERNEL_SRC OUT=$OUT"
mkdir -p "$OUT" "$EXT/dl"

# 0. reuse the reference buildroot download cache (saves re-downloading package
#    sources). BR2_DL_DIR must be writable, so seed a Kiln-owned copy.
REF_DL="${REF_DL:-$(dirname "$BR_SRC")/br-src/dl}"
KILN_DL="${KILN_DL:-$KILN/br-dl}"
if [ -d "$REF_DL" ] && [ ! -d "$KILN_DL" ]; then
	echo "==> seeding download cache from $REF_DL"
	cp -a "$REF_DL" "$KILN_DL"
fi
export BR2_DL_DIR="$KILN_DL"

# 1. stage base.config where the defconfig references it
cp "$BASE_CONFIG" "$EXT/dl/base.config"

# 2. fetch the version-locked closed runtimes (librkllmrt v1.2.0, librknnrt)
"$EXT/fetch-runtimes.sh"

# 3. fetch + shim the GPL rknpu driver (build happens in post-build against the
#    kernel buildroot builds). Skip if already fetched+shimmed so in-tree edits
#    (e.g. bring-up diagnostics) survive a rebuild; force with KILN_REFETCH=1.
if [ -n "${KILN_REFETCH:-}" ] || [ ! -f "$KILN/driver/rknpu/rknpu_drv.c" ]; then
	"$KILN/driver/fetch-vendor-driver.sh"
fi

# 4. point buildroot's kernel at the patched mainline 7.1.3 tree (read-only safe)
cat > "$OUT/local.mk" <<EOF
LINUX_OVERRIDE_SRCDIR = $KERNEL_SRC
EOF

# 5. configure + build
make -C "$BR_SRC" O="$OUT" BR2_EXTERNAL="$EXT" ${DEFCONFIG:-kiln_rock4d_713_defconfig}
[ -n "${KILN_LINUX_REBUILD:-}" ] && make -C "$BR_SRC" O="$OUT" linux-dirclean || true
echo "==> building (first run compiles the toolchain + kernel; ~40-90 min)"
make -C "$BR_SRC" O="$OUT"

echo "==> DONE. Flashable image: $OUT/images/sdcard.img"
ls -la "$OUT/images/sdcard.img"
