#!/usr/bin/env bash
# Kiln RK3588 (ROCK 5B) ROOTFS_POST_BUILD_SCRIPT.
#
# SKELETON, not hardware-validated. The rootfs userspace is SoC-agnostic (the
# demos call librkllmrt / librknnrt, which handle RK3588 internally) and the
# vendor rknpu.ko is the SAME binary as RK3576 (it already carries the
# rockchip,rk3588-rknpu match). So this is a thin wrapper over the shared RK3576
# post-build with two RK3588-specific overrides:
#
#   1. KILN_VISION_RKNN -- an .rknn is target-platform-specific, so the RK3576
#      MobileNet must NOT be baked (librknnrt rejects it on RK3588). Point at an
#      rk3588 model if you ship one; otherwise nothing is baked and the user
#      converts on-board with `kiln-convert mobilenet` (it targets the running
#      SoC).
#
# Buildroot passes $1 = TARGET_DIR and $2 = Kiln repo path (POST_SCRIPT_ARGS);
# both are forwarded verbatim to the shared script.
set -euo pipefail

KILN="${2:?Kiln repo path missing (BR2_ROOTFS_POST_SCRIPT_ARGS; \$1 is TARGET_DIR)}"

# Default to an rk3588-built MobileNet name; if absent in model/, the shared
# script bakes nothing (kiln-convert handles it on-board).
export KILN_VISION_RKNN="${KILN_VISION_RKNN:-mobilenetv2-12_rk3588.rknn}"

exec "$KILN/buildroot/board/rock4d/post-build.sh" "$@"
