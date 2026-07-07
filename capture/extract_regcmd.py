#!/usr/bin/env python3
"""
Scan an .rknn (or any binary) for the NPU register-command stream and decode it
in the SAME format as our rocket/rknpu dump, so it diffs directly.

Each regcmd entry is a little-endian u64:  [63:48]=target [47:16]=value [15:0]=reg
Valid targets we expect in a conv stream:
  0x0201 CNA, 0x0801 CORE, 0x1001 DPU, 0x2001 DPU_RDMA, 0x0041 sync, 0x0081 bcast
Find the longest run of consecutive u64s whose target is one of these and print it.

Usage: extract_regcmd.py <file.rknn> [min_run]
"""
import sys, struct

TARGETS = {0x0201: "CNA", 0x0801: "CORE", 0x1001: "DPU",
           0x2001: "RDMA", 0x0041: "SYNC", 0x0081: "BCAST",
           0x0202: "CNA?", 0x4001: "PPU?", 0x8001: "PPU_RDMA?"}

def decode(e):
    tgt = (e >> 48) & 0xffff
    val = (e >> 16) & 0xffffffff
    reg = e & 0xffff
    return tgt, val, reg

def main():
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(1)
    path = sys.argv[1]
    min_run = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    data = open(path, "rb").read()
    n = len(data) // 8
    words = struct.unpack("<%dQ" % n, data[:n*8])

    runs = []          # (start_idx, length)
    i = 0
    while i < n:
        if ((words[i] >> 48) & 0xffff) in TARGETS:
            j = i
            while j < n and ((words[j] >> 48) & 0xffff) in TARGETS:
                j += 1
            if j - i >= min_run:
                runs.append((i, j - i))
            i = j
        else:
            i += 1

    if not runs:
        print("no regcmd-like run found (min_run=%d). Try lowering min_run or"
              " check the .rknn is rk3576." % min_run)
        return

    runs.sort(key=lambda r: -r[1])
    for ri, (start, length) in enumerate(runs[:8]):
        print("==== run %d: offset=0x%x  entries=%d ====" %
              (ri, start*8, length))
        for k in range(start, start + length):
            tgt, val, reg = decode(words[k])
            print("  [%4d] tgt=%04x(%-5s) reg=%04x val=%08x" %
                  (k - start, tgt, TARGETS.get(tgt, "?"), reg, val))
        print()

if __name__ == "__main__":
    main()
