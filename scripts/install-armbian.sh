#!/usr/bin/env bash
# Install Kiln on Armbian: the out-of-tree vendor rknpu NPU driver (via DKMS),
# the NPU device-tree overlay, and the RKLLM runtime + chat demo -- so you can
# run LLMs on the RK3576 NPU under Armbian's mainline kernel.
#
# STATUS: best-effort, developed against a hand-built linux-next 7.1 image and
# NOT yet tested end-to-end on an Armbian release. Read ARMBIAN.md first.
#
# Requires: an aarch64 Armbian with a mainline kernel that has RK3576 support
# (>= 6.13), the matching linux-headers, dkms, device-tree-compiler, git, gcc.
set -euo pipefail

PKG=kiln-rknpu
VER=0.9.8
SRC="/usr/src/${PKG}-${VER}"
HERE="$(cd "$(dirname "$0")/.." && pwd)"        # repo root
KREL="$(uname -r)"
KBUILD="/lib/modules/${KREL}/build"

say() { echo "[kiln] $*"; }
need() { command -v "$1" >/dev/null 2>&1 || { echo "[kiln] ERROR: install '$1' ($2)"; exit 1; }; }

# --- 0. prerequisites -------------------------------------------------------
need dkms   "apt install dkms"
need dtc    "apt install device-tree-compiler"
need git    "apt install git"
need gcc    "apt install build-essential"
[ -d "$KBUILD" ] || { echo "[kiln] ERROR: kernel headers missing: apt install linux-headers-${KREL}"; exit 1; }

# --- 1. stage the module source for DKMS ------------------------------------
say "staging source at ${SRC}"
sudo rm -rf "$SRC"
sudo mkdir -p "$SRC"
# Kbuild/Makefile/dkms.conf + driver/ (fetch + apply-shims + patches + compat).
sudo cp -r "$HERE/Kbuild" "$HERE/Makefile" "$HERE/dkms.conf" "$HERE/driver" "$SRC/"

# --- 2. DKMS build + install (PRE_BUILD fetches + patches the vendor source) -
say "building rknpu via DKMS (fetches GPL source, applies kiln-mainline.patch)"
sudo dkms remove "${PKG}/${VER}" --all >/dev/null 2>&1 || true
sudo dkms add "$SRC"
sudo dkms build "${PKG}/${VER}"
sudo dkms install "${PKG}/${VER}"

# --- 3. NPU device-tree overlay ---------------------------------------------
say "building + installing the NPU overlay"
DTSO="$HERE/dts/rk3576-rock-4d-kiln-npu.dtso"
tmp="$(mktemp -d)"
cpp -nostdinc -undef -x assembler-with-cpp -I "$KBUILD/include" \
    -I "$KBUILD/scripts/dtc/include-prefixes" "$DTSO" "$tmp/kiln-npu.pre"
dtc -@ -I dts -O dtb -o "$tmp/rk3576-rock-4d-kiln-npu.dtbo" "$tmp/kiln-npu.pre" 2>/dev/null
# Armbian applies overlays from /boot/overlay-user via user_overlays=.
OVL=/boot/overlay-user
sudo mkdir -p "$OVL"
sudo cp "$tmp/rk3576-rock-4d-kiln-npu.dtbo" "$OVL/"
rm -rf "$tmp"
if ! grep -q "rk3576-rock-4d-kiln-npu" /boot/armbianEnv.txt 2>/dev/null; then
	if grep -q "^user_overlays=" /boot/armbianEnv.txt 2>/dev/null; then
		sudo sed -i 's/^user_overlays=.*/& rk3576-rock-4d-kiln-npu/' /boot/armbianEnv.txt
	else
		echo "user_overlays=rk3576-rock-4d-kiln-npu" | sudo tee -a /boot/armbianEnv.txt >/dev/null
	fi
	say "added overlay to /boot/armbianEnv.txt"
fi

# --- 4. RKLLM runtime + chat demo -------------------------------------------
DL="$HERE/buildroot/dl"
if [ ! -f "$DL/librkllmrt.so" ]; then
	say "fetching runtimes"; "$HERE/buildroot/fetch-runtimes.sh" || true
fi
[ -f "$DL/librkllmrt.so" ] && sudo install -m0644 "$DL/librkllmrt.so" /usr/lib/
[ -f "$DL/libgomp.so.1" ]  && sudo install -m0644 "$DL/libgomp.so.1"  /usr/lib/
sudo install -m0755 "$HERE/buildroot/rootfs/usr/bin/kiln-chat" /usr/bin/ 2>/dev/null || true

# demo: build against the fetched rkllm.h; static libstdc++ so it runs regardless
# of the target's libstdc++ version.
if [ -f "$DL/rkllm.h" ]; then
	say "building rkllm_demo"
	g++ -include cstdint "$HERE/buildroot/board/rock4d/rkllm_chat.cpp" \
	    -I "$DL" -L "$DL" -static-libstdc++ -static-libgcc \
	    -Wl,-rpath-link,"$DL" -lrkllmrt -lpthread -o /tmp/rkllm_demo \
	  && sudo install -m0755 /tmp/rkllm_demo /usr/bin/rkllm_demo
fi

sudo mkdir -p /opt/models
say "put your <name>-rk3576-w4a16.rkllm into /opt/models/ and point kiln-chat's MODEL= at it"
sudo depmod -a "$KREL" || true

echo
say "done. Reboot, then run: kiln-chat"
say "verify the NPU came up:  dmesg | grep -i rknpu   (expect 'RKNPU ... kiln mmu enable_all')"
