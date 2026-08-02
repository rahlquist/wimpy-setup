# CLAUDE.md — wimpy llama.cpp + llama-swap project

Context for Claude Code working in this directory on the host **wimpy**.

## What this machine is

wimpy is a bare-metal inference + VM host. It replaced an older box ("slug").
As of the 2026-07-23 AM4→AM5 platform swap:
- CPU: Ryzen 7 7700 (8c/8t, SMT off) · RAM: 32 GB DDR5 · NVMe: 2 TB
- GPU 0: **AMD R9700 32 GB** (ROCm/HIP gfx1201) — primary inference GPU
- GPU 1: **RTX 5060 Ti 16 GB** (CUDA sm_120) — second inference GPU; runs
  concurrently via a separate `/opt/llama-cuda` build (see "Dual-GPU" in README)
- iGPU: Ryzen 7700 Raphael (gfx1036) — enumerates as a ROCm device, so the
  R9700 is pinned by UUID to avoid selecting it. (The old GT 710 was removed.)
- OS: CachyOS (Arch-based), bash shell, KDE
- Network: bridge `br0` on `lan0` (permanent MAC-pinned NIC name via
  `10-lan.link` — kernel names drifted enp10s0→enp8s0 across PCI changes and
  broke the bridge twice), static-via-DHCP at **192.168.8.248**,
  hostname **wimpy.home.lan** (DNS/DHCP on OPNsense: Unbound + dnsmasq)

A KVM guest **hermesvm01** (192.168.8.249) runs Hermes Agent and reaches this
host's llama-swap at `http://wimpy.home.lan:8080/v1`.

## GPU migration (2026-07-07): CUDA -> ROCm

The RTX 5060 Ti was removed and an AMD Radeon AI PRO R9700 installed in its
place (RTX 5060 Ti is expected back "very soon" — see HARDWARE.md for the
dual-GPU question that raises). This was a two-part fix, not just a driver
swap — see CHANGELOG.md for the full incident writeup. Short version:

- `llama-server`/`llama-cli` now come from the **pacman packages**
  `llama-cpp-rocm` + `ggml-rocm`, installed at `/usr/bin/llama-server` etc.
  This repo's old build-from-source flow (`05-llama-cpp.sh`) is **superseded**
  by these packages — the script is not currently rewritten for ROCm and
  should not be treated as the current path (see note under Files below).
- An orphaned CUDA-only build from the old source-build flow was left behind
  at `/usr/local/bin`/`/usr/local/lib`, undated-package, silently shadowing
  the real package via `$PATH` order and an `/etc/ld.so.conf.d/local-lib.conf`
  entry that put `/usr/local/lib` ahead of `/usr/lib` for the dynamic linker.
  Both are now removed. **Do not recreate `/etc/ld.so.conf.d/local-lib.conf`**
  — the old bring-up instructions below referencing it are obsolete precisely
  because that file caused this incident.

## Stop using pacman for llama.cpp (2026-07-08)

Switched back to building llama.cpp from source (`05-llama-cpp.sh`, now
rewritten for ROCm/HIP) as the single source of truth, superseding the
`llama-cpp-rocm`/`ggml-rocm` pacman packages from the migration above.
Reasons: explicit control over build flags/version, consistent with this
project's general preference for pinned/explicit setups over whatever a
distro package happens to track, and the pacman packages were already 10
days / 73 releases behind upstream by the time this was noticed.

- Canonical binary is now `/usr/local/bin/llama-server`, built to
  `$HOME/src/llama.cpp` with `-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201`.
  Version **floats to latest master** on every run of `05-llama-cpp.sh`
  (`git pull --ff-only`, same behavior the original CUDA-era script had) —
  re-run the GPU validation from CHANGELOG.md after any rebuild, don't
  assume a new build still works.
- The `llama-cpp-rocm`/`ggml-rocm` pacman packages should be removed once
  the source build is verified working. **Do not leave both installed** —
  that recreates the exact competing-copies-on-`$PATH` problem the
  2026-07-07 migration fixed, just with the roles reversed (`/usr/bin` now
  the stale one instead of `/usr/local/bin`).
- If `/usr/bin/llama-server` still exists, that's the old package build.
  Every config/script in this repo now points at `/usr/local/bin/llama-server`
  explicitly — `/usr/bin` is never used, but isn't guaranteed empty until
  the packages are actually removed.

## The inference stack

- `llama-server` / `llama-cli` — built from source via `05-llama-cpp.sh`
  (ROCm/HIP) → `/usr/local/bin`. Always use the explicit
  `/usr/local/bin/llama-server` path in configs/units, never a bare
  `llama-server` (PATH resolution to whichever build happens to be first on
  `$PATH` is exactly what broke this project twice now).
- `llama-swap` (model router) → /usr/local/bin, systemd service `llama-swap`,
  listens on **0.0.0.0:8080** so the VM can reach it
- Models downloaded by `fetch-model.sh` into `~/.cache/llama.cpp/`
- `llama-swap-config.yaml` → deploys to `/etc/llama-swap/config.yaml`

## Files here

- `fetch-model.sh` — for adding a single new model from a HuggingFace paste
  (`./fetch-model.sh "hf download hf://owner/repo/file.gguf"`). Downloads, smoke-tests
  on the real GPU at full context with the same `--device`/env pin as production
  (refuses to register a model with no GPU pin at all — that's the exact
  silent-CPU-fallback bug the ROCm migration fixed), then registers it into this repo's
  `llama-swap-config.yaml` (not the deployed copy — deploying is a printed manual step,
  since llama-swap runs with `-watch-config` so it's just a `cp`, no restart needed).
  `-y` to skip the confirmation prompt, `--no-smoke`/`--no-register` to split the steps.
- `llama-swap-config.yaml` — model definitions. EVERY entry uses an explicit
  `--model /home/rahlquist/.cache/llama.cpp/<file>.gguf` path (NOT `-hf`).
- `llama-swap.service` — systemd unit file. Deploy with:
  `sudo cp llama-swap.service /etc/systemd/system/ && sudo systemctl daemon-reload`
- `05-llama-cpp.sh` — **canonical build path** (rewritten 2026-07-08 for
  ROCm/HIP, replacing the earlier pacman-package approach — see "Stop using
  pacman for llama.cpp" above). Builds llama.cpp from source
  (`-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201`) to `/usr/local/bin`, version
  floats to latest master each run. Also installs `llama-swap` and the
  systemd unit. Verifies `--list-devices` reports `ROCm0` before declaring
  success; refuses to finish otherwise.
- other `0N-*.sh` — host setup scripts (already run).

## System state (as of 2026-07-07, post ROCm migration)

- **llama-swap** is running and enabled (`sudo systemctl status llama-swap`).
- ~~**libggml-cuda fix**: `/etc/ld.so.conf.d/local-lib.conf` contains
  `/usr/local/lib`...~~ **OBSOLETE AND WRONG — do not do this.** This note
  described the old CUDA build-from-source setup. That exact file is what
  caused the 2026-07-07 incident (it shadowed the real ROCm package's
  libraries with a stale orphaned CUDA build). The file has been removed and
  must stay removed. See CHANGELOG.md.
- **Firewall (wimpy)**: CachyOS ships UFW. `sudo ufw allow in on br0` trusts all VM traffic
  on the bridge — do NOT add nftables rules on top of UFW, they fight each other.
- **Firewall (hermesvm01)**: UFW is the active firewall (ports 22, 8080, 9119 open).
  The `nftables` package is present (required by `iptables` and `dnsmasq`) but its
  **service is disabled** — do not enable it. `/etc/nftables.conf` exists and has been
  corrected to include port 9119, but if the service is re-enabled it will conflict with
  UFW. The nftables ruleset previously blocked port 9119 with `icmpx admin-prohibited`
  (2026-06-28 incident).
- **SSH**: passwordless keys set up wimpy↔hermesvm01 (ed25519, both directions).
- **HuggingFace CLI**: `huggingface-cli` is deprecated on this system; use `hf`.
- **Models load cleanly** — see load test results below. (Model set has since
  grown and split across two GPU groups — 26 on the R9700, 19 `-cuda` aliases
  on the 5060 Ti; the historical table below is the pre-migration 18.)

## Build/install gotcha (one-off wrappers)

If you wrap the install steps in a helper script and run it as `sudo bash wrapper.sh`, `$HOME` resets to `/root` at the first line, so any `$HOME/src/llama.cpp` path resolves under `/root` and `cmake --install` fails with `Not a file: /root/src/llama.cpp/build/cmake_install.cmake` (the build is fine; the path just points at the wrong home). The repo's own `05-llama-cpp.sh`/`06-llama-cpp-cuda.sh` avoid this: they set `BUILD_DIR=$HOME/src/llama.cpp` as the unprivileged user (the variable already holds the literal `/home/rahlquist/...` string), run build steps unprivileged, and only the final `sudo cmake --install` is elevated — `cmake --install` never re-expands `$HOME`. For a one-off wrapper, either let each `sudo` line self-escalate (don't wrap the whole script in `sudo bash`), hardcode `/home/rahlquist/src/llama.cpp`, or run `sudo -E bash wrapper.sh` to preserve env. (Also captured as GOTCHA 5 in the wimpy-model-bringup skill.)

## Hard rules (do not violate)

1. **Back up before modifying any working config.** Timestamped copy first:
   `cp /path/config /path/$(date +%Y%m%d%H%M%S)-config-filename`
   This applies to /etc/llama-swap/config.yaml and any systemd unit.
2. **GPU pinning is intentional (per-GPU).** Two groups, two pins:
   - **R9700 entries** (group `amd-r9700`): `env HIP_VISIBLE_DEVICES=GPU-<uuid>`
     (pin by stable UUID, NOT index — the Raphael iGPU also enumerates as a ROCm
     device, so an index pin could select it) + `--device ROCm0`.
   - **5060 Ti entries** (group `nvidia-5060ti`, the `-cuda` aliases): `env
     CUDA_VISIBLE_DEVICES=0` + `--device CUDA0`, running the `/opt/llama-cuda`
     build.
   `--device` doubles as a hard-fail: if the named device isn't available,
   `llama-server` refuses to start instead of silently falling back to CPU (how
   the 2026-07-07 silent-CPU-fallback mode got closed — see CHANGELOG.md). Do
   NOT remove either the env pin or the `--device` flag on any entry. (History:
   pre-migration this was a single `CUDA_VISIBLE_DEVICES=0` on the lone 5060 Ti;
   the 2026-07-24 dual-GPU work is what split it into the two-group scheme above
   — see CHANGELOG.md and HARDWARE.md.)
3. **Use local --model paths, not -hf.** The config deliberately points at the
   files `fetch-model.sh` already fetched. Do NOT convert entries to `-hf`
   (that triggers a second, separate download).
4. **Context is 65536 everywhere.** Hermes Agent requires a 64K minimum. Do not
   lower a model's ctx below 65536 unless explicitly told to for an OOM fix, and
   if you do, call it out as a deviation.
5. **Confirm before sudo / service / network changes.** Show the command and
   wait for approval. This is a live inference box.
6. **Tune one model at a time.** For VRAM fixes, change one value, reload, check
   `rocm-smi`, then proceed. No batch edits.

## Standard bring-up sequence

### On a host that already has llama-server/llama-swap installed

1. Verify model files exist with sane sizes:
   `ls -la ~/.cache/llama.cpp/*.gguf`
   Cross-check against the `--model` paths in llama-swap-config.yaml.
2. Confirm GPU device: `/usr/local/bin/llama-server --list-devices`
   (expect `ROCm0: AMD Radeon AI PRO R9700 ...`; pinning assumes `ROCm0`.)
3. ~~Fix the CUDA library path...~~ **Do NOT do this.** Do not create
   `/etc/ld.so.conf.d/local-lib.conf` or add `/usr/local/lib` to the linker
   search path — this is exactly what caused the 2026-07-07 incident (see
   CHANGELOG.md), and it's doubly pointless now: `/usr/local/lib` is where
   the *current* build's libs already live natively. If `llama-server`
   reports a missing `libggml-*`/`libllama-*` library, the fix is to re-run
   `05-llama-cpp.sh`, not to add a library search path.
4. **Install the systemd unit** (skip if `/etc/systemd/system/llama-swap.service` exists):
   `sudo cp llama-swap.service /etc/systemd/system/ && sudo systemctl daemon-reload`
5. Back up then install config:
   `[ -f /etc/llama-swap/config.yaml ] && sudo cp /etc/llama-swap/config.yaml /etc/llama-swap/$(date +%Y%m%d%H%M%S)-config.yaml.bak`
   `sudo mkdir -p /etc/llama-swap && sudo cp llama-swap-config.yaml /etc/llama-swap/config.yaml`
6. Start + watch: `sudo systemctl enable --now llama-swap` and
   `journalctl -u llama-swap -f`
7. Verify routing: `curl http://localhost:8080/v1/models`
8. Test load (start with the small, certain-to-fit model):
   `curl http://localhost:8080/v1/chat/completions -H "Content-Type: application/json" -d '{"model":"qwen3.5-9b-q4","messages":[{"role":"user","content":"Hello in one sentence."}]}'`
9. Check VRAM with a model loaded: `rocm-smi`

### Additional steps for a new host+VM setup

**Open the bridge to VMs** (CachyOS ships UFW; do this once per host):
```
sudo ufw allow in on br0
sudo ufw reload
```
This trusts ALL traffic from any VM on the bridge — no per-port rules needed.
Do NOT add nftables rules alongside UFW; they conflict (UFW uses iptables-nft).

**Verify from the VM:**
`curl http://wimpy.home.lan:8080/v1/models`

**Set up passwordless SSH between host and VM** (run on the host):
```bash
# Host → VM (one-time password prompt for the VM)
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "rahlquist@wimpy"
ssh-keyscan -H <VM-IP> >> ~/.ssh/known_hosts
ssh-copy-id rahlquist@<VM-IP>          # prompts for VM password once

# VM → Host (no password needed once host→VM is set up)
ssh rahlquist@<VM-IP> 'ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N "" -C "rahlquist@<VM-hostname>"'
ssh rahlquist@<VM-IP> 'cat ~/.ssh/id_ed25519.pub' >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ssh rahlquist@<VM-IP> 'bash -c "ssh-keyscan -H <HOST-IP> >> ~/.ssh/known_hosts"'
```
Note: VMs on this host run fish shell — always wrap remote commands in `bash -c "..."`.

**Add models** one at a time with `fetch-model.sh` (use `hf`, not
`huggingface-cli` — the latter is deprecated):
`./fetch-model.sh "hf download hf://owner/repo/file.gguf"`

## Load test results (2026-06-28, all 18 models — pre-migration, RTX 5060 Ti)

**Historical — from the CUDA/RTX 5060 Ti era, kept for the per-model tuning
notes (quant choices, OOM history).** Not re-verified on the R9700. Post-ROCm-
migration (2026-07-07) spot checks covered llama3.2-3b, qwen2.5-coder-14b,
qwen3.5-9b-q4, and qwen3-30b-a3b (MoE) — all confirmed working on GPU via
`rocm-smi` and `--list-devices`; see CHANGELOG.md. The other 14 models plus
the 3 legacy entries (`deepseek-coder-v2-lite-instruct-q4-k-m`,
`ornith-1-0-9b-q8-0`, `gemma4-coding-q6-k`) have not been individually
re-tested on the R9700 yet — the R9700 has 32 GB vs. the 5060 Ti's 16 GB, so
any tight-fit / OOM notes below no longer apply as written but haven't been
revisited.

All 18 models load and respond cleanly in isolation on the RTX 5060 Ti 16 GB.

| Model | Notes |
|---|---|
| mistral-7b | OK |
| llama3.2-3b | OK |
| granite-4.1-3b | OK |
| granite-4.1-8b | OK |
| llama-2-7b | OK (14.3 GB VRAM — large KV cache, no GQA) |
| gemma-4-12b | OK |
| qwen2.5-coder-14b | OK — self-caps at 32768 ctx (training limit); Hermes long prompts >32K will fail |
| deepseek-r1-14b | OK (12.2 GB VRAM) |
| gemma-3-12b | OK (14.3 GB VRAM — tight but fits) |
| qwen3.5-9b-q4 | OK |
| qwen3.5-9b-q6 | OK |
| qwen3.5-9b-q8 | OK |
| ling-mini-2-q4 | OK (MoE) |
| ling-mini-2-q5 | OK (MoE) |
| ling-mini-2-q6 | OK (MoE) |
| qwen3-30b-a3b | OK (MoE) |
| gemma-4-26b-moe | OK (MoE) |
| phi-4 | **Q4_K_M** (12.3 GB, 3.3 GB headroom) — Q8_0 OOMed at 64K even with clean VRAM |

Sequential swap test note: rapid-fire swaps between large models (12-14 GB) can
transiently OOM if the previous model's VRAM hasn't fully released. In normal
one-at-a-time request cadence this is not an issue.

## Known model caveats

- `phi-4` — config uses **Q4_K_M** (not Q8_0). Q8_0 confirmed
  OOM at 64K even with 15.8 GB free — weights alone consume ~15.5 GB.
- `qwen2.5-coder-14b` — training context is 32768; llama-server silently caps
  `--ctx-size 65536` to 32768. Hermes prompts longer than 32K will be rejected.
- `gemma-3-12b` — Q8_0 (~12.5 GB) fits at 64K on 16 GB with room to spare. Was
  flagged as "tight" but confirmed OK in isolation.
- MoE models (`qwen3-30b-a3b`, `gemma-4-26b-moe`, `ling-mini-2-*`): use
  `-ngl 99 --n-cpu-moe N` only after a fit/smoke test. N is hardware- and
  context-dependent; lower it only after checking `rocm-smi` headroom. Current
  llama.cpp applies CPU expert placement to the first N transformer blocks
  (`0..N-1`), not the highest-numbered blocks.

## Verify from the VM (end-to-end)

From hermesvm01: `curl http://wimpy.home.lan:8080/v1/models` should return the
model list. If it fails but localhost works, check UFW: `sudo ufw status` should
show `allow in on br0`. Do NOT add nftables rules alongside UFW — they conflict.
