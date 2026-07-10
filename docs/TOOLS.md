# kiln-doctor & kiln-config

Two helpers installed to `/usr/bin` alongside `kiln-chat` / `kiln-vision` /
`kiln-serve`: a health check and a config TUI. Both read the same
`/etc/kiln/config.ini` (see [`CONFIG.md`](CONFIG.md)).

## kiln-doctor — health check

`kiln-doctor` prints a plain-English ✓/✗ report and **exits non-zero if any critical
check fails**, so it is scriptable and is the "paste this before opening an issue"
tool. It is also the engine behind kiln-config's Status page.

```sh
kiln-doctor          # full report
kiln-doctor -q       # quiet: only failures + the final verdict
sudo kiln-doctor     # run as root so it can read dmesg (MMU checks)
```

What it checks:

- **Kernel & install** — running the Kiln patched kernel? the phase-2 install marker
  (`/etc/kiln/phase2-done` / `phase2-failed`).
- **Driver** — `rknpu` loaded (+ version) and a `/dev/dri/renderD*` render node.
- **MMU state** — parses `dmesg` for all four banks armed
  (`mmu enable_all … st=0x19/0x19/0x19/0x19`) and flags the power-domain wedge
  (`failed to get pm runtime for npu0, ret: -110`).
- **Runtimes** — `librkllmrt` / `librknnrt` in `/usr/lib` (+ reported versions).
- **Tools** — `kiln-chat` / `kiln-vision` / `kiln-config` / the demos on `PATH`.
- **Models** — the `[llm]` / `[vision]` models from the config exist on disk, and the
  vision `.rknn`'s embedded `rknn-toolkit2` version matches the `librknnrt` 2.3.x
  runtime (a mismatch throws `std::out_of_range` in `rknn_inputs_set`).
- **Network** — onboard wifi (optional; ethernet always works).

Exit code: `1` if any critical check fails (rknpu not loaded, no render node, MMU
wedge, a missing configured model, or a failed phase-2 install), else `0`.

## kiln-config — config TUI

`sudo kiln-config` is a `whiptail` (fallback `dialog`) menu tool, modelled on
`armbian-config`. It is a **front-end** to `/etc/kiln/config.ini`, never a
replacement: it edits the file **in place**, preserving your comments and any unknown
fields. It needs root (the config is root-owned and the Status page reads `dmesg`), so
it re-execs via `sudo` if you didn't.

Top menu:

| page | what |
|---|---|
| **Status & Diagnostics** | runs `kiln-doctor`, renders the ✓/✗ report, with a Re-run button |
| **LLM Settings** | `[llm]` — model (picker), temperature, top_k/top_p, max_new_tokens, max_context_len, repeat_penalty, keep_history, system_prompt |
| **Vision Settings** | `[vision]` — model (picker), labels, top_n, core_mask, priority |
| **Server** | `[server]` host/port + `systemctl` control of `kiln-serve` |
| **Models** | list / inspect (sizes, `.rknn` toolkit version), set the active LLM/vision model, add-from-path, remove |
| **Advanced** | reload `rknpu`, rebuild the DKMS driver + restore wifi, re-run the installer — each behind a yes/no confirm |

Conventions:

- **`<Save>` writes, `<Back>` discards** — nothing is persisted until you confirm, so
  a wrong turn never corrupts the config.
- **Model pickers scan `/opt/models`** — pick a `*.rkllm` / `*.rknn` from a menu
  instead of typing a path.
- **Enums are radio lists** — `core_mask` (`auto`/`0`/`1`/`0_1`), `priority`
  (`high`/`medium`/`low`), `keep_history` (`1`/`0`).
- **Vision is classification-only** — the vision model picker says so; detection /
  YOLO is not supported.
- Most changes apply the **next time** you start `kiln-chat` / `kiln-vision` /
  `kiln-serve`; Advanced driver actions may need a reload or reboot (stated per action).
