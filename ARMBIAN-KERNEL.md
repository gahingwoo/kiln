# Running the Kiln NPU on Armbian: the patched kernel

**The honest version.** The RK3576 NPU cannot run on a *stock* Armbian kernel.
Its power domain needs a built-in fix — a 15 µs settle delay in
`drivers/pmdomain/rockchip/pm-domains.c` before QoS is restored after de-idle —
without which the domain SErrors while the NoC is still settling: on ROCK 4D that
is a **hard freeze on the first NPU inference** (and a clean `pm runtime ... -110`
if the module loads while the domain is cold). This fix is a compiled-in driver
change; the out-of-tree `rknpu` module and the DT overlay cannot provide it.
See [`kernel-patches/README.md`](kernel-patches/README.md).

So the Armbian path is: **build an Armbian edge kernel with Kiln's patch, install
it, then install the module + overlay as usual.** The patch is small and applies
cleanly to Armbian **edge** (7.1, same `linux-next` base it was written on).

## 1. Build the patched kernel (on an x86_64 host)

Confirm your board slug and branch on the board first:

```sh
cat /etc/armbian-release | grep -E '^(BOARD|BRANCH)='
```

Then on an x86_64 build host (the Armbian framework cross-compiles):

```sh
git clone https://github.com/gahingwoo/kiln.git
cd kiln
BOARD=<slug-from-armbian-release> BRANCH=edge bash scripts/kiln-build-armbian-kernel.sh
```

That clones the Armbian build framework, drops `kernel-patches/0001-*.patch` into
`userpatches/kernel/archive/rockchip64-edge/`, and runs
`./compile.sh kernel BOARD=<slug> BRANCH=edge`. The result is a set of
`linux-image-*`, `linux-dtb-*`, `linux-headers-*` `.deb` files in
`~/kiln-armbian-build/output/debs/`.

To also fold in the optional patches: `KILN_KPATCHES="0001 0002 0003" BOARD=... bash scripts/kiln-build-armbian-kernel.sh`.

## 2. Install it on the board

Copy the three `.deb`s over and:

```sh
sudo dpkg -i linux-image-*.deb linux-dtb-*.deb linux-headers-*.deb
```

The `linux-headers` package lets DKMS rebuild `rknpu` for the new kernel
automatically. Then re-enable the NPU overlay and boot-time module load (they
were disabled during the stock-kernel bring-up) and reboot:

```sh
sudo sed -i 's/^user_overlays=.*/user_overlays=kiln-npu/' /boot/armbianEnv.txt
sudo mv /etc/modules-load.d/rknpu.conf.disabled /etc/modules-load.d/rknpu.conf 2>/dev/null \
  || echo rknpu | sudo tee /etc/modules-load.d/rknpu.conf
sudo reboot
```

## 3. Verify

```sh
sudo dmesg | grep -i rknpu
#   RKNPU ... kiln mmu enable_all: ... st=0x19/0x19/0x19/0x19
#   and NO 'failed to get pm runtime for npu0, ret: -110'
ls /dev/dri/renderD*          # renderD129 (NPU) present
kiln-vision /opt/models/test.jpg
kiln-chat
```

If the freeze is gone and inference returns, the settle-delay patch did its job.

## The real endgame

The proper fix is to land the settle-delay patch in **mainline** (and/or
Armbian's kernel patch set). Once it is upstream, a stock Armbian edge kernel
runs the NPU with no rebuild — and this whole page collapses back to "install the
module + overlay." Until then, this patched-kernel step is required.

## Why not just use a newer Armbian?

It will not help: the fix is not upstream, so Armbian 6.19, 7.0, 7.1, edge — any
stock version — has the same broken NPU power domain. The missing piece is the
patch, not the kernel version.
