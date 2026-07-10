#!/usr/bin/env bash
# Fetch the GPL-2.0 vendor rknpu driver v0.9.8 from the Armbian rockchip BSP.
# We do NOT vendor the GPL source into Kiln; we fetch it here so you port it
# in place under driver/rknpu/.
#
# Source: armbian/linux-rockchip (rk-6.1-rkr6.1). Its drivers/rknpu is
# byte-identical to rockchip-linux/kernel develop-6.1 (verified: diff -rq
# returns no differences), so this is purely a sourcing choice. Override with:
#   ./fetch-vendor-driver.sh <branch> <repo-url>
set -euo pipefail

BRANCH="${1:-rk-6.1-rkr6.1}"
REPO="${2:-https://github.com/armbian/linux-rockchip.git}"
DEST="$(cd "$(dirname "$0")" && pwd)/rknpu"

# Idempotent short-circuit. If a ready (fetched + shimmed) driver/rknpu is already
# in place, do nothing -- no network. This is what lets DKMS PRE_BUILD run OFFLINE
# in installer phase 2 (pre-fetch the source in phase 1 while online), and it also
# stops this script -- which DKMS runs on EVERY build -- from silently clobbering a
# local driver patch you're testing under driver/rknpu/. Force a fresh pull with
# KILN_FORCE_FETCH=1.
if [ -z "${KILN_FORCE_FETCH:-}" ] && [ -f "$DEST/include/rknpu_drv.h" ]; then
	ver=$(grep -E '#define DRIVER_(MAJOR|MINOR|PATCHLEVEL)' "$DEST/include/rknpu_drv.h" \
	      | awk '{print $3}' | paste -sd. -)
	echo "[kiln] driver/rknpu already present (v$ver) -- skip fetch (KILN_FORCE_FETCH=1 to refresh)"
	exit 0
fi

echo "[kiln] sparse-fetching drivers/rknpu from $REPO ($BRANCH) ..."
tmp="$(mktemp -d)"
git clone --filter=blob:none --sparse --depth 1 --branch "$BRANCH" "$REPO" "$tmp"
( cd "$tmp" && git sparse-checkout set drivers/rknpu )

rm -rf "$DEST"
cp -r "$tmp/drivers/rknpu" "$DEST"
rm -rf "$tmp"

ver=$(grep -E '#define DRIVER_(MAJOR|MINOR|PATCHLEVEL)' "$DEST/include/rknpu_drv.h" \
      | awk '{print $3}' | paste -sd. -)
echo "[kiln] fetched rknpu driver version: v$ver  (LLM needs >= 0.9.8)"
echo "[kiln] source now at: $DEST"

# Auto-apply the mainline (7.x) build shims in place. Idempotent; see the script
# header. This keeps GPL source out of the Kiln tree (fetched + patched, never
# committed) while producing a mainline-buildable driver/rknpu/.
"$(dirname "$0")/apply-mainline-shims.sh"
