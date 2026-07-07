# capture/ — NPU per-op capture + the "cold-start arm" breakthrough probe

A small capture toolkit for RK3576/RK3568 NPU bring-up. Two jobs:

1. **Per-op capture** (`run-capture.sh`) — dump one inference's register-command
   stream + buffers, decoded, from userspace. General bring-up / diff tool.
2. **The breakthrough probe** (`blindspot-trace.sh`) — aimed squarely at the wall
   the open [`rocket`](https://github.com/gahingwoo/linux-rk3576-npu) driver is
   stuck on.

## The wall this targets (why Kiln can crack it)

`rocket` (the open RK3576 NPU driver) can only make the NPU do **real MACs on the
first task per power session**. Every later/chained task engages and DMAs its
input, but the CMAC never fires — the output comes back zero-point / empty. A
complete writel audit proved the **vendor and rocket write the *same* NPU
registers** (block `0x2770_xxxx`). So the arming difference is *not* an NPU
register — it is in the surface the audit never covered: the **non-NPU blocks the
vendor touches once per power-on — GRF / CRU / PMU / PVTPLL / memory-repair**.
Prime suspect: a **memory-repair bit in `npu_grf`** (RK3576 `syscon@26018000`,
`rockchip,rk3576-npu-grf`) — "calibrate once per power-on" matches the symptom
("only the cold-start first op does real MACs") exactly.

Kiln runs the **working vendor stack** on the **same mainline kernel + same
hardware** as rocket. That makes the once-impossible comparison possible: capture
what the working stack does to the non-NPU blocks, and diff it against rocket.

## Files

| file | what |
|---|---|
| `blindspot-trace.sh` | **the breakthrough probe.** ftraces `regmap:regmap_reg_write` + `clk` across the NPU's cold power-on + first inference vs a warm second inference; prints COLD-minus-WARM = the once-per-power-session GRF/CRU/PVTPLL/memory-repair writes. No kernel rebuild — pure built-in tracepoints. |
| `run-capture.sh` | LD_PRELOAD one inference, dump submit + BOs + regcmd to `/rknpu_replay/`, decode. |
| `capture.c` | the LD_PRELOAD shim (intercepts DRM `MEM_CREATE`/`SUBMIT`). |
| `extract_regcmd.py` | decode a regcmd/`.rknn` blob into `tgt/reg/val` lines (diffs directly vs rocket's dump). |
| `rknpu-regcmd-dump.patch` | optional kernel-side dump of the regcmd stream in `commit_pc` (apply to `driver/rknpu` + rebuild the module) for the deeper per-task view. |

## Use

On the board (a Kiln install with `rknn_mobilenet` + a `*_${soc}.rknn` model):

```sh
# 1) breakthrough probe — RUN ON A FRESH BOOT (NPU must be cold), capture serial
./blindspot-trace.sh
#    -> COLD-minus-WARM regmap/clk writes; hand any *grf / pvtpll / repair line to rocket

# 2) per-op capture of one inference
./run-capture.sh
#    -> /rknpu_replay/{meta.txt,submit.bin,boNN.bin} + decoded regcmd
```

Then, on the **same board**, take the same `blindspot-trace.sh` capture on a
`rocket` run and diff the two COLD traces. The delta is the concrete lead:

- **a non-NPU write the vendor does and rocket doesn't** (e.g. an `npu_grf`
  memory-repair bit) → a specific, likely-cheap fix for rocket; or
- **identical non-NPU writes** → the arm is below the register bus (true HW /
  RTL state), an honest negative that closes the software theory.

## Honest status

The per-op capture is proven (it's the RK3576 bring-up tooling, adapted here).
The **blindspot probe is a hypothesis-driven experiment, not a fix** — it's the
next attack on a wall where the whole software + NPU-register surface has already
been exhausted and byte-matched to the vendor. It may hand rocket a fix, or it
may prove the difference is unreachable HW state. Both are real answers.

Adapted from the `vendor-capture/` toolkit in
[`gahingwoo/linux-rk3576-npu`](https://github.com/gahingwoo/linux-rk3576-npu)
(the open rocket + Mesa Teflon effort). GPL-2.0 / MIT as noted per file.
