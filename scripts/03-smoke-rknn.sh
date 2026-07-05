#!/usr/bin/env bash
# Stage 3: prove the whole kernel<->userspace path with a vision RKNN model.
# Requires: version-matched librknnrt (>= the driver's HAL) + a .rknn model.
set -euo pipefail
echo "Install librknnrt matching driver v0.9.8, then run rknn_toolkit_lite2"
echo "or the rknn C demo on a MobileNet/ResNet .rknn. If it infers, the UABI,"
echo "IOMMU and DMA paths are correct -> proceed to Stage 4 (LLM)."
