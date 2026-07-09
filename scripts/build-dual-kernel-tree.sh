#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# build-dual-kernel-tree.sh -- reconstruct the DUAL (vendor rknpu + open rocket)
# mainline 7.1.3 kernel source tree that the dual-boot image is built from.
#
# The dual image runs BOTH NPU stacks on one 7.1.3 kernel and picks the driver
# for npu@27700000 at boot via two DTB variants. This script builds the kernel
# source that makes that possible:
#   1. copy the vendor-patched 7.1.3 tree (7.1.3 + Kiln kernel-patches 0001-0010),
#   2. apply the open rocket RK3576 series (accel/rocket rknn_core support),
#   3. add #ifdef KILN_ROCKET_NPU guards so the two same-address NPU node sets
#      (vendor rknpu vs rocket rknn_core, both npu@27700000) are mutually
#      exclusive per dtb (dtc rejects two nodes at one address),
#   4. add the rk3576-rock-4d-rocket.dts variant + its Makefile entry.
#
# Idempotent: re-running is safe (guards/variant are added only once).
# Output default is IN-TREE ($KILN/kernel-dual), so build-image.sh finds it.
# ---------------------------------------------------------------------------
set -euo pipefail

KILN="$(cd "$(dirname "$0")/.." && pwd)"
# External reference trees (override via env; not in this repo). KILN_REF_ROOT
# defaults to $HOME/Desktop only as a convenience -- set it to wherever you
# cloned the refs, or set each path individually.
KILN_REF_ROOT="${KILN_REF_ROOT:-$HOME/Desktop}"
# 7.1.3 + Kiln vendor kernel-patches 0001-0010 already applied
VENDOR_SRC="${VENDOR_SRC:-$KILN_REF_ROOT/kiln-713/linux-7.1.3}"
# the open rocket RK3576 patch series (00*.patch, applied in order)
ROCKET_PATCHES="${ROCKET_PATCHES:-$KILN_REF_ROOT/linux-rk3576-npu/kernel}"
OUT="${OUT:-$KILN/kernel-dual/linux-7.1.3}"

for p in "$VENDOR_SRC/Makefile" "$ROCKET_PATCHES"/0001-*.patch; do
	[ -e "$p" ] || { echo "ERROR: missing $p (set VENDOR_SRC / ROCKET_PATCHES)"; exit 1; }
done

echo "==> [1/4] source-clean copy: $VENDOR_SRC -> $OUT"
mkdir -p "$(dirname "$OUT")"
rsync -a --delete \
	--exclude='*.o' --exclude='*.o.*' --exclude='.*.cmd' --exclude='*.ko' \
	--exclude='*.mod' --exclude='*.mod.c' --exclude='*.a' --exclude='*.order' \
	--exclude='*.symvers' --exclude='.tmp_versions/' --exclude='.config' \
	--exclude='include/generated/' --exclude='include/config/' \
	--exclude='arch/arm64/boot/Image*' --exclude='arch/arm64/boot/dts/**/*.dtb' \
	"$VENDOR_SRC/" "$OUT/"

echo "==> [2/4] apply the rocket RK3576 series (driver clean; the shared-platform"
echo "         hunks are already present in the vendor tree -- expected, ignored)"
cd "$OUT"
for p in "$ROCKET_PATCHES"/00*.patch; do
	patch -p1 --forward --no-backup-if-mismatch < "$p" >/dev/null 2>&1 || true
done
find "$OUT" -name '*.rej' -delete 2>/dev/null || true
find "$OUT" -name '*.orig' -delete 2>/dev/null || true

echo "==> [3/4] #ifdef KILN_ROCKET_NPU guards + rocket DTB variant + Makefile"
python3 - "$OUT" <<'PY'
import sys
root = sys.argv[1]
RKD  = f"{root}/arch/arm64/boot/dts/rockchip"
dtsi, board, mk = f"{RKD}/rk3576.dtsi", f"{RKD}/rk3576-rock-4d.dts", f"{RKD}/Makefile"
variant = f"{RKD}/rk3576-rock-4d-rocket.dts"

def find(lines, sub):
	for i, l in enumerate(lines):
		if sub in l:
			return i
	raise SystemExit(f"anchor not found: {sub!r}")

def block_close(lines, open_idx):
	"""index of the '}' that closes the node opened at open_idx (brace match)."""
	depth = 0
	for i in range(open_idx, len(lines)):
		depth += lines[i].count('{') - lines[i].count('}')
		if depth == 0 and i >= open_idx:
			return i
	raise SystemExit("unbalanced braces")

def wrap(lines, start_sub, last_node_sub, opener, closer):
	s = find(lines, start_sub)
	e = block_close(lines, find(lines, last_node_sub))
	lines.insert(e + 1, closer)   # insert close first (higher index stays valid)
	lines.insert(s, opener)
	return lines

# --- dtsi: make vendor rknpu and rocket rknn_core mutually exclusive ---
t = open(dtsi).read()
if 'KILN_ROCKET_NPU' not in t:
	L = t.split('\n')
	L = wrap(L, 'rknpu: npu@27700000 {', 'rknpu_mmu_1: iommu@',
	         '#ifndef KILN_ROCKET_NPU', '#endif /* !KILN_ROCKET_NPU (vendor rknpu nodes) */')
	L = wrap(L, 'rknn_core_0: npu@27700000 {', 'rknn_mmu_1: iommu@',
	         '#ifdef KILN_ROCKET_NPU', '#endif /* KILN_ROCKET_NPU (rocket rknn nodes) */')
	open(dtsi, 'w').write('\n'.join(L))
	print("   dtsi guards added")
else:
	print("   dtsi guards already present")

# --- board dts: the vendor &rknpu overrides only apply when NOT rocket ---
t = open(board).read()
if 'KILN_ROCKET_NPU' not in t:
	L = t.split('\n')
	L = wrap(L, '&rknpu {', '&rknpu_mmu_1 {',
	         '#ifndef KILN_ROCKET_NPU', '#endif /* !KILN_ROCKET_NPU */')
	open(board, 'w').write('\n'.join(L))
	print("   board dts guard added")
else:
	print("   board dts guard already present")

# --- rocket DTB variant (defines the macro, enables rknn_core) ---
open(variant, 'w').write(
'''// SPDX-License-Identifier: (GPL-2.0+ OR MIT)
/*
 * Kiln dual-image ROCKET variant of the Radxa ROCK 4D.
 * Same board as rk3576-rock-4d.dts, but npu@27700000 is driven by the open
 * accel/rocket driver (rknn_core) instead of the vendor rknpu. KILN_ROCKET_NPU
 * swaps the rk3576.dtsi NPU node set (rknpu and rknn_core share npu@27700000, so
 * only one may exist). No /dts-v1/ here: it comes from the included base.
 */
#define KILN_ROCKET_NPU 1
#include "rk3576-rock-4d.dts"

/* rknpu is #ifndef'd out in this build; enable only the rocket nodes. */
&rknn_core_0 {
\tnpu-supply = <&vdd_npu_s0>;
\tstatus = "okay";
};
&rknn_mmu_0  { status = "okay"; };
''')
print("   rocket variant dts written")

# --- Makefile: build the variant dtb ---
t = open(mk).read()
if 'rk3576-rock-4d-rocket.dtb' not in t:
	lines = t.split('\n')
	i = find(lines, 'rk3576-rock-4d.dtb')
	lines.insert(i + 1, 'dtb-$(CONFIG_ARCH_ROCKCHIP) += rk3576-rock-4d-rocket.dtb')
	open(mk, 'w').write('\n'.join(lines))
	print("   Makefile variant dtb entry added")
else:
	print("   Makefile entry already present")
PY

echo "==> [4/4] done. dual kernel tree ready: $OUT"
echo "    build-image.sh uses it via KERNEL_SRC (default now points here)."
