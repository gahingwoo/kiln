#!/bin/bash
# ---------------------------------------------------------------------------
# blindspot-trace.sh — the "cold-start arm" breakthrough capture.
# (bash: uses process substitution for the cold-minus-warm diff)
#
# The open `rocket` RK3576 driver hits one wall: only the FIRST NPU task per
# power session does real MACs; every later/chained task engages and DMAs its
# input but the CMAC never fires (output = zero-point / empty). A complete
# writel audit proved the vendor and rocket write the *same* NPU registers
# (block 0x2770_xxxx) — so the arming difference is NOT an NPU register. It is
# in the surface the audit never covered: the NON-NPU blocks the vendor touches
# once per power-on — GRF / CRU / PMU / PVTPLL / memory-repair. Prime suspect:
# an `npu_grf` (RK3576: syscon@26018000, "rockchip,rk3576-npu-grf") memory-repair
# bit — a "calibrate once per power-on" mechanism whose shape matches the symptom
# exactly.
#
# On Rockchip ALL of those blocks are driven through `regmap`, so the kernel's
# built-in `regmap:regmap_reg_write` tracepoint records every write to them, with
# the regmap (device) and the register offset+value — no custom kernel needed.
# Kiln runs the WORKING vendor stack on the SAME mainline kernel + SAME hardware
# as rocket, so this trace is the once-impossible apples-to-apples reference:
# what does the working stack write to the non-NPU blocks that rocket doesn't?
#
# METHOD: trace the non-NPU regmap/clk writes across (1) the NPU's cold power-on
# + first inference, then (2) a second inference while it is warm. The writes
# present on the COLD run but absent on the WARM run are the once-per-power-session
# arming sequence — exactly the window the memory-repair suspect lives in, and the
# thing rocket has no equivalent of.
#
# RUN ON A FRESH BOOT (NPU must be cold), capture the console/serial.
#   ./blindspot-trace.sh [model.rknn] [image.jpg]
# ---------------------------------------------------------------------------
set -eu

T=/sys/kernel/tracing
[ -d "$T/events" ] || T=/sys/kernel/debug/tracing
[ -d "$T/events" ] || { echo "ftrace not mounted (need CONFIG_FTRACE + tracefs)"; exit 1; }

# infer the on-board vision command / model for whichever SoC this is
SOC="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | grep -oE 'rk35[0-9][0-9]' | head -1 || true)"
MODEL="${1:-/opt/models/mobilenetv2-12_${SOC:-rk3576}.rknn}"
IMG="${2:-/opt/models/test.jpg}"

run_infer() {  # one NPU inference, quietly, whatever launcher exists
	if command -v kiln-vision >/dev/null 2>&1; then kiln-vision "$IMG" >/dev/null 2>&1 || true
	elif command -v rknn_mobilenet >/dev/null 2>&1; then rknn_mobilenet "$MODEL" "$IMG" >/dev/null 2>&1 || true
	else echo "  (no kiln-vision / rknn_mobilenet found — run any NPU job here)"; fi
}

arm_events() {
	echo nop > "$T/current_tracer"
	echo 0 > "$T/tracing_on"; : > "$T/trace"
	# every regmap write catches GRF / CRU / PMU / PVTPLL / memory-repair syscons
	echo 1 > "$T/events/regmap/regmap_reg_write/enable"
	# clock rate/gate + genpd give the power/clock context around the arm
	echo 1 > "$T/events/clk/clk_set_rate/enable"  2>/dev/null || true
	echo 1 > "$T/events/clk/clk_enable/enable"    2>/dev/null || true
	echo 1 > "$T/events/power/power_domain_target/enable" 2>/dev/null || true
}

capture() {  # $1 = output file
	echo 1 > "$T/tracing_on"; run_infer; echo 0 > "$T/tracing_on"
	cp "$T/trace" "$1"
	echo "  -> $(grep -acE 'regmap_reg_write|clk_set_rate' "$1") reg/clk events -> $1"
}

echo "===== blindspot-trace: non-NPU (GRF/CRU/PMU/PVTPLL) writes around NPU arm ====="
echo "SoC=${SOC:-unknown}  model=$MODEL"
arm_events

echo "=== [1] NPU is COLD — first inference (includes power-on + the once-only arm) ==="
capture /tmp/blindspot-cold.txt

echo "=== [2] NPU now WARM — second inference (should skip the once-only writes) ==="
: > "$T/trace"
capture /tmp/blindspot-warm.txt

echo
echo "=== [3] COLD-minus-WARM: writes done once per power session (the arm suspect) ==="
echo "    Anything to an npu_grf / *grf / pvtpll / repair regmap here is the lead to"
echo "    hand to rocket. RK3576 npu_grf = syscon@26018000."
norm() { grep -aE 'regmap_reg_write|clk_set_rate' "$1" \
	| sed -E 's/^[^:]*: //; s/ [0-9]+\.[0-9]+: / /g' | sed -E 's/^ *//'; }
comm -23 <(norm /tmp/blindspot-cold.txt | sort -u) <(norm /tmp/blindspot-warm.txt | sort -u) \
	| head -100
echo
echo "=== GRF/PVTPLL/repair writes seen on the COLD run (highlight) ==="
grep -aiE 'grf|pvtpll|repair|npu' /tmp/blindspot-cold.txt | grep -a regmap_reg_write | head -40 || true

echo
echo "raw traces kept: /tmp/blindspot-cold.txt  /tmp/blindspot-warm.txt"
echo "next: diff these against the SAME trace taken on a rocket run — the delta is"
echo "what the working stack arms and rocket omits (or, if identical, the wall is"
echo "below the bus = true HW, an honest negative)."
