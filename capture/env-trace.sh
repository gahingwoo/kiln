#!/bin/sh
# ---------------------------------------------------------------------------
# env-trace.sh - same-kernel vendor-vs-rocket driver-ENVIRONMENT diff.
# POSIX sh (busybox-safe); baked into the Kiln image as /usr/bin/kiln-env-trace.
#
# Supersedes blindspot-trace.sh's cold-vs-warm approach for the rocket wall.
# Ground truth (rocket FINDINGS.md:705): the vendor's OWN captured regcmd bytes,
# replayed through the rocket driver, ALSO wall in task_number=N mode. So the
# command stream / payload is exonerated -- the wall is the rocket driver's
# task_number=N EXECUTION ENVIRONMENT: clocks/PVTPLL, genpd power, rk_iommu,
# soft-reset, PC write ordering -- everything the driver sets up AROUND the
# byte-identical submit.
#
# The old writel/clock/iommu audit compared vendor-on-6.1-BSP vs rocket-on-
# mainline: every environment difference was confounded by "different kernel."
# Kiln removes that confound -- the vendor rknpu.ko now runs on the SAME mainline
# kernel as rocket. So a vendor-vs-rocket environment diff is finally CLEAN
# (same clk driver, same genpd, same rk_iommu). The vendor MACs EVERY task in a
# chained submit; rocket only the first. On one kernel, that difference must be
# in the driver environment -- and these built-in tracepoints catch it, no patch.
#
# COVERAGE (built-in tracepoints, catch the framework calls):
#   regmap_reg_write  -> any GRF/CRU/PMU/PVTPLL syscon write that goes via regmap
#   clk_set_rate/enable -> NPU/PVTPLL clock rate + gate changes (PVTPLL's effect)
#   power_domain_target -> NPU power-domain on/off transitions
#   iommu map/unmap/attach -> rk_iommu setup around the submit
# NOT covered: a DIRECT ioremap+writel (e.g. PVTPLL if it bypasses regmap, or the
#   NPU block itself -- already audited byte-identical). If this diff comes back
#   IDENTICAL, that is the signal to escalate to wtrace on rknpu.ko (the fallback)
#   or to conclude the arm is below software (RTL/firmware) -- an honest negative.
#
# USAGE -- run ONCE per stack, same board, as root, then diff the two outputs:
#   ./env-trace.sh kiln                              # -> /tmp/env-kiln.txt
#   ./env-trace.sh rocket -- <your npu workload...>  # -> /tmp/env-rocket.txt
#   # then, with both files on ONE host (needs GNU coreutils comm):
#   comm -13 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)  # vendor-ONLY
#   comm -23 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)  # rocket-ONLY
#
# Trace is taken WARM (a throwaway inference first) so the one-time cold power-on
# (genpd bring-up + vdd_npu + QoS restore, already known common to both) does not
# drown out the per-submit environment activity that actually differs.
# ---------------------------------------------------------------------------
set -eu

LABEL="${1:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo stack)}"
[ "$#" -ge 1 ] && shift || true
# an optional explicit workload command follows a `--`; the rest of "$@" is it
if [ "${1:-}" = "--" ]; then shift; fi

T=/sys/kernel/tracing
[ -d "$T/events" ] || mount -t tracefs nodev "$T" 2>/dev/null || true
if [ ! -d "$T/events" ]; then
	T=/sys/kernel/debug/tracing
	mount -t debugfs nodev /sys/kernel/debug 2>/dev/null || true
fi
[ -d "$T/events" ] || {
	echo "ftrace not available. grep -w tracefs /proc/filesystems ; kernel needs CONFIG_FTRACE/CONFIG_TRACING"
	exit 1
}

SOC="$(tr -d '\0' < /proc/device-tree/compatible 2>/dev/null | grep -oE 'rk35[0-9][0-9]' | head -1 || true)"
MODEL_RKNN="/opt/models/mobilenetv2-12_${SOC:-rk3576}.rknn"
IMG="/opt/models/test.jpg"

run_infer() {  # runs the explicit "$@" workload if given, else auto-detects one
	if [ "$#" -gt 0 ]; then "$@" >/dev/null 2>&1 || true
	elif command -v kiln-vision    >/dev/null 2>&1; then kiln-vision    "$IMG" >/dev/null 2>&1 || true
	elif command -v rknn_mobilenet >/dev/null 2>&1; then rknn_mobilenet "$MODEL_RKNN" "$IMG" >/dev/null 2>&1 || true
	else echo "  (no workload found -- pass one:  $0 $LABEL -- <cmd>)"; return 1; fi
}

en() { echo 1 > "$T/events/$1/enable" 2>/dev/null || true; }
arm_events() {
	echo nop > "$T/current_tracer"
	echo 0 > "$T/tracing_on"; : > "$T/trace"
	en regmap/regmap_reg_write
	en clk/clk_set_rate
	en clk/clk_enable
	en power/power_domain_target
	# rk_iommu setup around the submit -- the FINDINGS-named suspect the old
	# audit could not compare on one kernel
	en iommu/map
	en iommu/unmap
	en iommu/attach_device_to_domain
}

# normalize a trace to comparable lines: drop pid/timestamp, keep event +
# device/reg/val (comparable across stacks: same kernel, same HW).
norm() {
	grep -aE 'regmap_reg_write|clk_set_rate|clk_enable|power_domain_target|iommu' "$1" \
		| sed -E 's/^[^:]*: //; s/ [0-9]+\.[0-9]+: / /; s/^ *//' | sort -u
}

echo "===== env-trace [$LABEL]: driver-environment writes around a CHAINED submit ====="
echo "SoC=${SOC:-unknown}"
arm_events

echo "=== warm-up inference (absorbs the one-time cold power-on; discarded) ==="
echo 1 > "$T/tracing_on"; run_infer "$@" || { echo "no workload ran -- aborting"; exit 1; }
echo 0 > "$T/tracing_on"; : > "$T/trace"

echo "=== measured inference (WARM -- per-submit environment only) ==="
echo 1 > "$T/tracing_on"; run_infer "$@"; echo 0 > "$T/tracing_on"

OUT="/tmp/env-${LABEL}.txt"
norm "$T/trace" > "$OUT"
echo "  -> $(wc -l < "$OUT") unique env events -> $OUT"
echo
echo "=== highlight: iommu / clk / genpd / pvtpll / grf on this stack ==="
grep -aiE 'iommu|clk_set_rate|power_domain|pvtpll|grf' "$OUT" | head -60 || true
echo
echo "next: copy /tmp/env-${LABEL}.txt off the board; run this on the OTHER stack;"
echo "then diff (vendor-ONLY writes = the arm suspect):"
echo "  comm -13 <(sort -u /tmp/env-rocket.txt) <(sort -u /tmp/env-kiln.txt)"
