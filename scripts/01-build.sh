#!/usr/bin/env bash
# Build the Kiln rknpu module against your mainline kernel.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${KDIR:=/lib/modules/$(uname -r)/build}"
[ -d driver/rknpu ] || { echo "run driver/fetch-vendor-driver.sh first"; exit 1; }
echo "[kiln] building against KDIR=$KDIR"
make KDIR="$KDIR"
echo "[kiln] built: $(ls -1 rknpu.ko 2>/dev/null || echo '(no rknpu.ko - fix build errors per docs/PORTING.md)')"
