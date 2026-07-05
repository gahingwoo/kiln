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
