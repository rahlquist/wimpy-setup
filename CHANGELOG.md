# Changelog — wimpy-setup

## Add fetch-model.sh: single-model download + auto-register (2026-07-08)

`download-models.sh` only ever downloaded the fixed curated list — adding one
new model meant a manual `hf download` plus hand-editing `llama-swap-config.yaml`.
`fetch-model.sh` replaces that manual step for the common case: paste a HF
model-card download line, it downloads, smoke-tests on the real GPU at full
context (same `--device`/env pin as production, refuses to register anything
without one), and inserts a validated entry into `llama-swap-config.yaml`
(structural + YAML-parse checks before writing, backup + auto-restore on
failure). Deploying to `/etc/llama-swap/config.yaml` is left as a printed
manual step rather than automatic, consistent with how every other config
change in this project works.

## GPU migration: CUDA (RTX 5060 Ti) -> ROCm (Radeon AI PRO R9700) (2026-07-07)

RTX 5060 Ti was removed and an AMD Radeon AI PRO R9700 installed. An initial
migration attempt the previous night left the machine with two competing
llama.cpp installs and the R9700 not actually being used (silent CPU fallback).
This entry covers the cleanup.

### Root cause
Two independent bugs compounded:
1. **Orphaned CUDA-only build.** This repo's old `05-llama-cpp.sh`
   build-from-source flow had left a CUDA-only llama.cpp build at
   `/usr/local/bin`/`/usr/local/lib`, owned by no package. The properly
   ROCm-enabled `llama-cpp-rocm`/`ggml-rocm` pacman packages were installed
   at `/usr/bin`/`/usr/lib`, but:
   - `/etc/ld.so.conf.d/local-lib.conf` (added months earlier, specifically
     *to* help the old CUDA build find its libs) put `/usr/local/lib` ahead
     of `/usr/lib` in the dynamic linker search path — so even
     `/usr/bin/llama-server` resolved `libggml*`/`libllama*` to the stale
     CUDA-only copies instead of the real ROCm ones.
   - Separately, `/usr/local/bin` preceded `/usr/bin` on `$PATH`, and
     `llama-swap-config.yaml` invoked bare `llama-server` — so it wasn't even
     running the package's binary, it was running the orphaned one.
   - Both problems shared one fix: delete the orphaned `/usr/local` build and
     the shadowing `ld.so.conf.d` entry.
2. **NVIDIA driver failure (unrelated, GT 710 display only).** `nvidia-smi`
   failed; `journalctl -k` showed `NVRM: ... not supported by open nvidia.ko
   because it does not include the required GPU System Processor (GSP)`. The
   GT 710 (Kepler, 2014) is hardware-incompatible with the installed
   `nvidia-open` 610.x driver branch — no current NVIDIA branch supports
   Kepler; only the legacy 470xx branch does. Lowest-risk fix: let GT 710 fall
   back to `nouveau` (never used for compute, display-only). This surfaced a
   second wrinkle: `nouveau` isn't blacklisted in `/etc/modprobe.d` (as
   initially assumed) but in `/usr/lib/modprobe.d/nvidia-utils.conf`, shipped
   by the `nvidia-utils` package itself — can't edit a package-owned file
   directly, so the fix is an `/etc/modprobe.d` override with the same
   filename (full override, not merge, per modprobe.d(5) search-path rules).
   **This part of the fix is tracked separately and had not been applied as
   of this changelog entry** — see HARDWARE.md's "GT 710 display driver
   status" section for current state.

### What changed
- Removed: `/usr/local/bin/llama-*` (orphaned CUDA build, keeping
  `/usr/local/bin/llama-swap` — the unrelated router binary, not part of the
  orphaned build), `/usr/local/lib/libggml*`/`libllama*`, stray source clones
  `~/src/llama.cpp` and `~/llama.cpp`, and `/etc/ld.so.conf.d/local-lib.conf`.
- `llama-swap-config.yaml`: every model's `cmd:` now uses the explicit
  `/usr/bin/llama-server` path (never bare `llama-server`); every `env:`
  changed from `CUDA_VISIBLE_DEVICES=0` to `HIP_VISIBLE_DEVICES=0`; every
  `cmd:` also gained `--device ROCm0` (`-dev ROCm0` for the 3 legacy
  short-flag entries), which makes a missing/wrong GPU a hard startup failure
  instead of a silent CPU fallback — proven by testing a bogus device name
  (refuses to start, exit 1) before setting the real one.
- Ported 3 legacy model entries (`deepseek-coder-v2-lite-instruct-q4-k-m`,
  `ornith-1-0-9b-q8-0`, `gemma4-coding-q6-k`) into `llama-swap-config.yaml`
  from the deployed `/etc/llama-swap/config.yaml` — they existed in
  production but had drifted out of this repo file at some prior point.
- Context (65536), `--model` path style, and MoE `--n-cpu-moe` tuning values
  were left untouched — out of scope for this migration.

### Validation
Real end-to-end requests (not just "service started") across 4 models/tiers,
watching `rocm-smi` live during generation:
| Model | Tier | Peak GPU% | Notes |
|---|---|---|---|
| llama3.2-3b | small dense | 94-95% | |
| qwen2.5-coder-14b | mid dense | 100% | ~13GB VRAM |
| qwen3-30b-a3b | MoE | 72% | partial CPU offload expected (`--n-cpu-moe 36`) |
| qwen3.5-9b-q4 | — | 94-96% | same model previously clocked at ~57s in the broken CPU-fallback state; now 1.3s generation time |

`/usr/bin/llama-server --list-devices` confirms `ROCm0: AMD Radeon AI PRO
R9700 (32624 MiB, 32558 MiB free)`.

### Not yet done
- The other 14 non-legacy models plus the 3 ported legacy entries haven't
  been individually re-validated on the R9700 (only spot-checked above); the
  June 2026 load-test table in CLAUDE.md predates this migration and was run
  on the RTX 5060 Ti.

## GT 710 / nouveau display driver fix (2026-07-07, follow-up)

Applied the fix described as "not yet done" above, with one incident along
the way. Full detail in HARDWARE.md's "GT 710 display driver status"; summary
here for the changelog trail.

- Created `/etc/modprobe.d/nvidia-utils.conf`, overriding the package-shipped
  `/usr/lib/modprobe.d/nvidia-utils.conf` to drop its blanket `blacklist
  nouveau` line (kept `blacklist nova_core`/`nova_drm` — unrelated,
  experimental Rust driver). Ran `sudo mkinitcpio -P` afterward.
- Applied live via `modprobe` rather than an immediate reboot. `nouveau`
  bound to the GT 710 correctly at the kernel level (confirmed via
  `journalctl -k`: `nouveau 0000:04:00.0: NVIDIA GK208B`, `fb0:
  nouveaudrmfb` registered, `nvidia`/`nvidia-open` backed off cleanly) — but
  **physical display output broke anyway**. Root cause: `plasmalogin.service`
  (Plasma/Wayland session) had been running since the prior boot, well
  before nouveau claimed the device, and doesn't hot-adopt a DRM device that
  appears underneath an already-running compositor session.
- `sudo systemctl restart plasmalogin.service` did **not** fix it. A full
  `sudo reboot` did — nouveau loads before the graphical session starts on a
  clean boot, so there's no stale state. Confirmed post-reboot: `nouveau`
  bound at actual boot time (not just live-loaded), `plasmalogin.service`
  started fresh (`Active: active ... since <post-reboot timestamp>`), display
  working normally.
- **Lesson for next time a kernel/DRM-level driver change is needed on this
  box: reboot immediately after applying, don't try to hot-apply-and-restart-
  just-the-display-manager.** That intermediate state (correct kernel driver,
  stale compositor) looks identical to "the fix didn't work" from the
  physical console and cost real troubleshooting time.
- Two lines of harmless log noise identified during troubleshooting, not
  regressions, documented in HARDWARE.md: nouveau's missing video-decode
  firmware (`msvld: init failed` — no redistributable firmware for this
  GPU's decode engine, doesn't affect display), and repeating `amdgpu ...
  Cannot find any crtc or sizes` (R9700 has no display output for KMS to
  enumerate — expected for a compute-oriented card).

GT 710 display driver fix is now fully applied and confirmed stable across a
real reboot. No outstanding items from the original ROCm migration remain
except re-validating the 17 not-yet-individually-tested models above.

## Build-out (June 2026)

Initial bring-up of wimpy as the bare-metal inference + VM host replacing slug.

### Host setup
- System base, Docker, VSCodium, llama.cpp (CUDA sm_120), Claude Code installed
  via numbered scripts (`01`–`09`) orchestrated by `run-all.sh`.
- Bridge networking: `enp6s0` enslaved into `br0`, bridge MAC pinned to the NIC's
  real MAC so the OPNsense DHCP reservation assigns 192.168.8.248.
- KVM/libvirt/virt-manager installed; `br0` registered as libvirt `host-bridge`.

### Inference stack
- llama.cpp built with `-DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120` for the
  RTX 5060 Ti; GT 710 excluded via `CUDA_VISIBLE_DEVICES=0`.
- llama-swap installed, bound to 0.0.0.0:8080 for LAN/VM access.
- 18 models downloaded and configured. All load cleanly.

### hermesvm01
- KVM guest (CachyOS + MATE, 4 vCPU / 16GB / 500GB) on the host-bridge,
  192.168.8.249. `hermesvm-setup.sh --hostname` configures Hermes + Claude Code
  and points inference at wimpy.home.lan:8080.

### Fixes applied during bring-up
- `detect_os` call restored in 02/04/07 (a sed edit had stripped it).
- `02-docker.sh`: install compose plugin even when Docker pre-exists; version
  checks made non-fatal.
- `05-llama-cpp.sh`: corrected llama-swap release asset (linux_amd64 tarball,
  not a bare binary); download made non-fatal.
- `08-networking.sh`: NET_MANAGER detection rewritten (if/elif, prefer
  NetworkManager); firewall logic creates the nftables table/chain if absent;
  bridge MAC pinned to the physical NIC.
- `run-all.sh`: step-number parsing forced to base-10 (08/09 octal bug).
- Firewall logic centralised into `open_firewall_port` in lib/common.sh.
- `download-models.sh`: switched to the `hf` CLI; corrected repo paths and
  filenames for Granite, Llama-3.2-3B, Gemma-4-12B, and the Jackrong distill;
  added Q6_K and Q8_0 of the Qwen3.5-9B reasoning distill.
- **phi-4 changed Q8_0 → Q4_K_M** — Q8_0 (~15GB) OOMed at 64K on 16GB.
  Synced in both `download-models.sh` and `llama-swap-config.yaml`.
- llama-swap config converted to a single consistent method: explicit `--model`
  paths everywhere (was a mix of `-hf` and `--model`).

### Repository hygiene
- Removed a stray Hugging Face token file from the tree.
- `.gitignore` hardened to block `*token*`, `*.env`, `logs/`, and
  `.claude/settings.local.json`.
- Added `NETWORK-DIAGRAM.md` (with rendered `network-diagram.svg`) and this `CHANGELOG.md`.
