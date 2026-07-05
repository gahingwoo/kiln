#!/usr/bin/env bash
# Load the module and verify the NPU bound + driver version.
set -euo pipefail
cd "$(dirname "$0")/.."
sudo insmod rknpu.ko || sudo modprobe rknpu || true
sleep 1
echo "--- dmesg (rknpu) ---"; sudo dmesg | grep -i rknpu | tail -20
echo "--- version ---";       sudo cat /sys/kernel/debug/rknpu/version 2>/dev/null || echo "(no debugfs version yet)"
echo "--- device node ---";   ls -l /dev/dri/renderD* /dev/rknpu 2>/dev/null || echo "(no node yet)"
