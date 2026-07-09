#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# wtrace-diff.py -- decode + diff the vendor rknpu and open rocket direct-writel
# traces (Kiln B) captured on the SAME mainline-7.1.3 dual-boot image.
#
# The regmap env-diff cannot see a direct ioremap+readl/writel. This closes that
# gap ON THIS STACK (not by transferring the rocket project's audit): does the
# vendor touch an NPU-block register the open rocket driver doesn't, or vice versa?
#
# Capture (see capture/README):
#   kiln mode:   echo 1 > /sys/module/rknpu/parameters/rknpu_wtrace; kiln-vision ...
#                dmesg | grep 'rknpu wt' > wt-kiln.txt
#   rocket mode: echo 1 > /sys/module/rocket/parameters/wtrace; kiln-rocket-run
#                dmesg | grep 'rocket wt' > wt-rocket.txt
#
#   ./wtrace-diff.py wt-kiln.txt wt-rocket.txt
#
# The two stacks run DIFFERENT workloads (rknn vision vs the captured conv replay),
# so values differ; the diff is value-agnostic -- it compares the SET of register
# ADDRESSES each stack reads/writes. A vendor-only address = a register the vendor
# touches that rocket never does = a concrete arm candidate.
# ---------------------------------------------------------------------------
import re, sys

# rknn_core sub-blocks (RK3576 NPU @ 0x2770_0000) for annotating addresses
BLOCKS = [
    (0x27700000, 0x27701000, "pc"),
    (0x27701000, 0x27702000, "cna"),
    (0x27702000, 0x27703000, "mmu0"),      # vendor MMU bank regs live here
    (0x27703000, 0x27704000, "core"),
    (0x27704000, 0x27705000, "dpu"),
    (0x27705000, 0x27708000, "rdma"),
    (0x27708000, 0x27710000, "core1"),     # vendor base[1]
    (0x2770a000, 0x2770b000, "mmu1"),
    (0x26018000, 0x26018100, "npu_grf"),
]
def blk(a):
    for lo, hi, n in BLOCKS:
        if lo <= a < hi:
            return f"{n}+{a-lo:#05x}"
    return f"?{a:#010x}"

def parse_vendor(path):
    """rknpu wt map baseN=<ptr> phys=0x..  +  rknpu wt <w|r> <ptr> <off> <val>"""
    base = {}
    w, r = set(), set()
    for ln in open(path, errors="ignore"):
        m = re.search(r"rknpu wt map \S*base(\d+)=(\S+) phys=0x([0-9a-fA-F]+)", ln)
        if m:
            base[m.group(2)] = int(m.group(3), 16)
            continue
        m = re.search(r"rknpu wt ([wr]) (\S+) ([0-9a-fA-F]+) ([0-9a-fA-F]+)", ln)
        if m:
            rw, ptr, off = m.group(1), m.group(2), int(m.group(3), 16)
            ph = base.get(ptr)
            if ph is None:
                continue
            (w if rw == "w" else r).add(ph + off)
    return w, r, base

def parse_rocket(path):
    """rocket wt <w|r> <abs> <val>"""
    w, r = set(), set()
    for ln in open(path, errors="ignore"):
        m = re.search(r"rocket wt ([wr]) ([0-9a-fA-F]+) ([0-9a-fA-F]+)", ln)
        if m:
            (w if m.group(1) == "w" else r).add(int(m.group(2), 16))
    return w, r

def show(title, s):
    print(f"\n===== {title} ({len(s)}) =====")
    for a in sorted(s):
        print(f"  {a:#010x}  {blk(a)}")

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: wtrace-diff.py wt-kiln.txt wt-rocket.txt")
    vw, vr, base = parse_vendor(sys.argv[1])
    rw, rr = parse_rocket(sys.argv[2])
    print(f"vendor base map: {base}")
    print(f"vendor: {len(vw)} write-addrs, {len(vr)} read-addrs")
    print(f"rocket: {len(rw)} write-addrs, {len(rr)} read-addrs")
    # the decisive lists: what each stack touches that the other never does
    show("VENDOR-only WRITES (vendor writes, rocket never) = arm candidate", vw - rw)
    show("ROCKET-only WRITES (rocket writes, vendor never)", rw - vw)
    show("VENDOR-only READS (vendor reads, rocket never)", vr - rr)
    show("ROCKET-only READS", rr - vr)

if __name__ == "__main__":
    main()
