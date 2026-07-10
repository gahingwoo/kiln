#!/usr/bin/env python3
"""
Add a one-shot regcmd-dump probe to the (already fetched + kiln-mainline-patched)
vendor rknpu_job.c.

Why this is a separate script and NOT part of kiln-mainline.patch: it is a debug
probe, not a fix. Fold it in only when you want to read a real inference's
per-task register recipe off the silicon -- the CNA/CORE/DPU/RDMA register
values (CORE_MISC_CFG.PROC_PRECISION for int8-vs-fp16 mode, DPU OUT_CVT_* for the
requant) that live INSIDE a task's regcmd stream in DRAM and are fed to the
sub-blocks by the PC autonomously. Those never appear as direct writels, so
rknpu_wtrace can't see them; a live w4a16/fp16 librkllmrt run is the only way to
capture the true recipe on THIS chip instead of guessing it for the open rocket
port.

Usage (on the board, AFTER fetch-vendor-driver.sh has populated driver/rknpu/):
    python3 driver/patches/add-regcmd-dump.py
    make KDIR=/lib/modules/$(uname -r)/build      # direct build, NOT via DKMS --
    sudo rmmod rknpu; sudo insmod rknpu.ko         # DKMS PRE_BUILD would re-fetch
                                                   # pristine and wipe this.
    echo 1 | sudo tee /sys/module/rknpu/parameters/rknpu_dump_regcmd
    # ...run ONE inference (kiln-chat turn / kiln-vision)...  it self-clears
    dmesg | grep "rknpu regcmd" > /tmp/regcmd_dump.txt

Decode the dump with vendor-capture/extract_regcmd.py (same 64-bit
[target|value|reg] word layout). Idempotent: re-running is a no-op once applied.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
P = os.path.normpath(os.path.join(HERE, "..", "rknpu", "rknpu_job.c"))

if not os.path.exists(P):
    sys.exit("[dump-hook] ERROR: %s not found -- run driver/fetch-vendor-driver.sh first" % P)

s = open(P).read()

if "rknpu_dump_regcmd" in s:
    print("[dump-hook] already present in", P)
    sys.exit(0)

# 1. Includes. Pristine rknpu_job.c pulls in none of iommu.h (iommu_iova_to_phys /
#    iommu_get_domain_for_dev), mm.h (pfn_valid / PFN_DOWN), or moduleparam.h.
inc_anchor = "#include <linux/io.h>\n"
if inc_anchor not in s:
    sys.exit("[dump-hook] ERROR: '#include <linux/io.h>' not found -- source layout changed")
s = s.replace(
    inc_anchor,
    inc_anchor +
    "#include <linux/iommu.h>\n"
    "#include <linux/mm.h>\n"
    "#include <linux/moduleparam.h>\n", 1)

# 2. The module_param, right after the driver's local includes.
mp_anchor = '#include "rknpu_job.h"\n'
if mp_anchor not in s:
    sys.exit("[dump-hook] ERROR: '#include \"rknpu_job.h\"' not found")
mp = mp_anchor + '''
/*
 * Kiln (fp16 register-recipe capture): dump the first task's regcmd words to
 * dmesg on the NEXT job, then self-clear. Those words carry the CNA/CORE/DPU/
 * RDMA register values (CORE_MISC_CFG.PROC_PRECISION, DPU OUT_CVT_*) fed to the
 * sub-blocks by the PC -- they are not direct writels, so a live inference is the
 * only way to read the real recipe off this silicon. Layout matches
 * vendor-capture/extract_regcmd.py: 64-bit [63:48]=target [47:16]=value [15:0]=reg.
 *   echo 1 > /sys/module/rknpu/parameters/rknpu_dump_regcmd ; <one inference>
 */
static int rknpu_dump_regcmd;
module_param(rknpu_dump_regcmd, int, 0644);
MODULE_PARM_DESC(rknpu_dump_regcmd, "dump the first task's regcmd words to dmesg on the next job, then self-clear");
'''
s = s.replace(mp_anchor, mp, 1)

# 3. The dump block, right before the KILN MMU-flush comment (guaranteed present
#    via kiln-mainline.patch). At that point first_task / task_start / rknpu_dev
#    are all in scope in rknpu_job_subcore_commit_pc().
blk_anchor = "\t/*\n\t * KILN: flush this core's MMU TLB before every job."
if blk_anchor not in s:
    sys.exit("[dump-hook] ERROR: KILN MMU-flush anchor not found -- was kiln-mainline.patch applied?")
block = '''\tif (rknpu_dump_regcmd) {
\t\tstruct iommu_domain *dom = iommu_get_domain_for_dev(rknpu_dev->dev);
\t\tphys_addr_t rp = dom ? iommu_iova_to_phys(dom, first_task->regcmd_addr) : 0;

\t\tif (rp && pfn_valid(PFN_DOWN(rp))) {
\t\t\tu64 *rv = (u64 *)phys_to_virt(rp);
\t\t\tu32 amt = first_task->regcfg_amount;
\t\t\tu32 cap = amt > 2048 ? 2048 : amt;
\t\t\tu32 i;

\t\t\tpr_info("rknpu regcmd dump: task_start=%d regcmd_addr=0x%llx amount=%u (capped %u)\\n",
\t\t\t\ttask_start, first_task->regcmd_addr, amt, cap);
\t\t\tfor (i = 0; i < cap; i++)
\t\t\t\tpr_info("rknpu regcmd[%04u] = %016llx\\n", i, rv[i]);
\t\t} else {
\t\t\tpr_info("rknpu regcmd dump: could not resolve regcmd_addr=0x%llx to phys (dom=%px)\\n",
\t\t\t\tfirst_task->regcmd_addr, dom);
\t\t}
\t\trknpu_dump_regcmd = 0;
\t}

'''
s = s.replace(blk_anchor, block + blk_anchor, 1)

open(P, "w").write(s)
print("[dump-hook] patched", P)
