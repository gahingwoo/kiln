#!/usr/bin/env bash
# Kiln buildroot ROOTFS_POST_BUILD_SCRIPT.
# Runs after the rootfs tree is populated, before it is packed into rootfs.ext2.
# Buildroot exports: TARGET_DIR, BUILD_DIR, HOST_DIR, BINARIES_DIR, BASE_DIR.
# Buildroot passes $1 = TARGET_DIR automatically; BR2_ROOTFS_POST_SCRIPT_ARGS
# are appended AFTER, so the Kiln repo path is $2.
#
# Does three things:
#   1. Fetch + shim + build the out-of-tree vendor rknpu.ko against the kernel
#      buildroot just built, and install it into the target rootfs.
#   2. Install the version-locked closed runtimes (librkllmrt v1.2.0, librknnrt).
#   3. Optionally bake the .rkllm model in (KILN_BAKE_MODEL=1); default is to
#      leave it out (668 MB) and scp it to the board (see docs/BRINGUP.md).
set -euo pipefail

KILN="${2:?Kiln repo path missing (BR2_ROOTFS_POST_SCRIPT_ARGS; note \$1 is TARGET_DIR)}"

# --- locate the kernel buildroot just built + its cross toolchain ------------
KDIR="$(ls -d "$BUILD_DIR"/linux-custom 2>/dev/null || ls -d "$BUILD_DIR"/linux-* 2>/dev/null | grep -v headers | head -1)"
[ -f "$KDIR/Module.symvers" ] || { echo "[kiln] ERROR: built kernel not found under $BUILD_DIR"; exit 1; }
CROSS="$HOST_DIR/bin/$(basename "$(ls "$HOST_DIR"/bin/*-linux-*-gcc | head -1)" | sed 's/gcc$//')"
KREL="$(cat "$KDIR/include/config/kernel.release")"
echo "[kiln] kernel=$KREL  KDIR=$KDIR  CROSS=$CROSS"

# --- 1. fetch + shim + build rknpu.ko ---------------------------------------
if [ ! -f "$KILN/driver/rknpu/rknpu_drv.c" ]; then
	"$KILN/driver/fetch-vendor-driver.sh"          # clones Armbian rknpu + auto-applies shims
fi
make -C "$KDIR" M="$KILN" ARCH=arm64 CROSS_COMPILE="$CROSS" modules
install -D -m0644 "$KILN/rknpu.ko" "$TARGET_DIR/lib/modules/$KREL/extra/rknpu.ko"
# refresh modules.dep so `modprobe rknpu` works on the board
"$HOST_DIR/sbin/depmod" -b "$TARGET_DIR" "$KREL" 2>/dev/null || \
	depmod -b "$TARGET_DIR" "$KREL" 2>/dev/null || true
echo "[kiln] installed rknpu.ko -> /lib/modules/$KREL/extra/"

# --- 2. install version-locked closed runtimes ------------------------------
[ -f "$KILN/buildroot/dl/librkllmrt.so" ] || "$KILN/buildroot/fetch-runtimes.sh"
install -D -m0755 "$KILN/buildroot/dl/librkllmrt.so" "$TARGET_DIR/usr/lib/librkllmrt.so"
install -D -m0755 "$KILN/buildroot/dl/librknnrt.so"  "$TARGET_DIR/usr/lib/librknnrt.so"
# librkllmrt NEEDs libgomp.so.1 at runtime; the buildroot toolchain has no OpenMP,
# so ship the staged glibc libgomp (GLIBC_2.38-compatible with the target).
install -D -m0755 "$KILN/buildroot/dl/libgomp.so.1" "$TARGET_DIR/usr/lib/libgomp.so.1"
echo "[kiln] installed librkllmrt.so + librknnrt.so + libgomp.so.1 -> /usr/lib/"

# --- 2b. cross-compile the turnkey rkllm_demo (v1.2.0 C API) -----------------
# -include cstdint: the v1.2.0 rkllm.h omits it and modern g++ needs it.
# -rpath-link dl: lets ld resolve librkllmrt.so's libgomp.so.1 dependency at link.
GXX="${CROSS}g++"
if [ -f "$KILN/buildroot/dl/llm_demo.cpp" ] && [ -x "$GXX" ]; then
	"$GXX" -include cstdint "$KILN/buildroot/dl/llm_demo.cpp" \
		-I"$KILN/buildroot/dl" -L"$KILN/buildroot/dl" \
		-Wl,-rpath-link,"$KILN/buildroot/dl" -lrkllmrt -lpthread \
		-o "$TARGET_DIR/usr/bin/rkllm_demo"
	echo "[kiln] built + installed /usr/bin/rkllm_demo (v1.2.0 C API)"
else
	echo "[kiln] WARN: rkllm_demo source or g++ missing; skipping demo build"
fi

# --- 3. model (default: NOT baked in; scp after boot) -----------------------
mkdir -p "$TARGET_DIR/opt/models"
if [ "${KILN_BAKE_MODEL:-0}" = "1" ]; then
	M="$KILN/model/TinyLlama-1.1B-Chat-v1.0-rk3576-w4a16.rkllm"
	[ -f "$M" ] && install -D -m0644 "$M" "$TARGET_DIR/opt/models/$(basename "$M")" \
		&& echo "[kiln] baked model into /opt/models/ (image will be ~700 MB larger)"
else
	echo "[kiln] model NOT baked in; scp it to /opt/models on the board (docs/BRINGUP.md 5)"
fi

# --- auto-load rknpu at boot (before anything tries to use the NPU) ---------
install -D -m0755 /dev/stdin "$TARGET_DIR/etc/init.d/S89rknpu" <<'INIT'
#!/bin/sh
case "$1" in
	start) modprobe rknpu 2>/dev/null || true ;;
	stop)  : ;;
esac
INIT
echo "[kiln] post-build done."
