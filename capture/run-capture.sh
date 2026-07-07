#!/bin/sh
# ---------------------------------------------------------------------------
# run-capture.sh — capture one NPU inference's per-op command stream.
#
# LD_PRELOADs capture.so over the vision runner: it records every BO the runtime
# creates and, on the first RKNPU_SUBMIT, dumps the submit struct + the task
# array + every BO (incl. the regcmd BO) to /rknpu_replay/, then decodes the
# regcmd stream. Runs on the board as-is — no kernel rebuild.
#
#   ./run-capture.sh [model.rknn] [image.jpg]
#
# For the deeper in-kernel view (per-task engage / S_POINTER snapshots) apply
# rknpu-regcmd-dump.patch to driver/rknpu and rebuild the module — see README.
# ---------------------------------------------------------------------------
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
SOC="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | grep -oE 'rk35[0-9][0-9]' | head -1 || true)"
MODEL="${1:-/opt/models/mobilenetv2-12_${SOC:-rk3576}.rknn}"
IMG="${2:-/opt/models/test.jpg}"

# build the shim on-board if it isn't there yet
if [ ! -f "$HERE/capture.so" ]; then
	echo "building capture.so ..."
	cc -shared -fPIC -o "$HERE/capture.so" "$HERE/capture.c" -ldl \
		|| { echo "need a C compiler (apt install gcc) to build capture.so"; exit 1; }
fi

rm -rf /rknpu_replay
echo "=== capturing one inference (model=$MODEL) ==="
# capture.so must live in the process that issues the DRM ioctls -> the runner
# binary, not the kiln-vision wrapper.
if command -v rknn_mobilenet >/dev/null 2>&1; then
	LD_PRELOAD="$HERE/capture.so" rknn_mobilenet "$MODEL" "$IMG" 2>&1 \
		| grep -aiE 'CAPTURE|Top|class|npu' || true
else
	echo "rknn_mobilenet not found; run your own NPU binary under:"
	echo "  LD_PRELOAD=$HERE/capture.so <binary> ..."
	exit 1
fi

echo "=== /rknpu_replay/ ==="; ls -la /rknpu_replay/ 2>/dev/null || true
echo "=== submit meta ==="; cat /rknpu_replay/meta.txt 2>/dev/null | head -20
echo "=== regcmd decode (the small BOs are the regcmd/task stream) ==="
for b in /rknpu_replay/bo0*.bin; do
	[ -f "$b" ] || continue
	sz=$(stat -c%s "$b")
	[ "$sz" -gt 262144 ] && continue   # skip big weight/scratch BOs
	echo "--- $b ($sz bytes) ---"
	python3 "$HERE/extract_regcmd.py" "$b" 20 2>/dev/null | head -30
done
echo "=== done. raw BOs + submit in /rknpu_replay/ ==="
