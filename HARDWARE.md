# wimpy — hardware reference

| Component | Detail |
|-----------|--------|
| Board     | ASUS TUF GAMING B550M-PLUS |
| CPU       | AMD Ryzen 9 3900X — 12 cores / 24 threads |
| RAM       | 64 GiB DDR4-3200 (4 × 16 GiB) |
| GPU 0     | AMD Radeon AI PRO R9700 (Navi 48, gfx1201, 32 GB VRAM) — inference, PCI `09:00.0` |
| GPU 1     | NVIDIA GeForce GT 710 (GK208B) — display head only, PCI `04:00.0` |
| Storage   | WD_BLACK SN770 2 TB NVMe (`/dev/nvme0n1`) |
| NIC       | Realtek RTL8125 2.5 GbE (`enp6s0`) |

**RTX 5060 Ti (GB206, 16 GB VRAM, `sm_120`) is temporarily removed** (as of
2026-07-07) pending re-install "very soon." It previously occupied the primary
inference role above; when it returns, decide whether it replaces the R9700 or
runs alongside it (dual-GPU pinning would need to change from a single
`HIP_VISIBLE_DEVICES=0`/`--device ROCm0` pin to something that accounts for
both a ROCm and a CUDA device). NVIDIA driver/CUDA toolkit packages remain
installed and untouched specifically so this slots back in cleanly.

## Partition layout
| Device         | Size    | Role           |
|----------------|---------|----------------|
| nvme0n1p1      | 4 GiB   | Windows FAT/EFI|
| nvme0n1p2      | 1.8 TiB | Linux root     |
| nvme0n1p3      | 31 GiB  | Linux swap     |

## ROCm notes (current inference GPU: R9700)
- R9700 = RDNA4-class, `gfx1201`. Built from source via `05-llama-cpp.sh`
  (`-DGGML_HIP=ON -DAMDGPU_TARGETS=gfx1201`), version floats to latest
  master on each rebuild. As of 2026-07-08 this replaced the
  `llama-cpp-rocm`/`ggml-rocm` pacman packages used during the initial
  2026-07-07 migration — see CLAUDE.md's "Stop using pacman for llama.cpp"
  and CHANGELOG.md for why.
- Binary: `/usr/local/bin/llama-server`. If `/usr/bin/llama-server` still
  exists, that's the old pacman package build — remove `llama-cpp-rocm`/
  `ggml-rocm` once the source build is verified working; don't leave both
  installed (recreates the exact competing-copies problem from the original
  migration, just with the paths' roles reversed).
- GPU pinning: `HIP_VISIBLE_DEVICES=0` + `--device ROCm0` (the latter also
  makes missing-GPU a hard startup failure instead of a silent CPU fallback).
- Verify device name/index: `/usr/local/bin/llama-server --list-devices`

## GT 710 display driver status
- GT 710 = Kepler, `sm_35` — too old for llama.cpp inference regardless of
  which primary GPU is installed; always excluded from inference.
- **As of 2026-07-07, GT 710 runs on `nouveau`**, confirmed bound at actual
  boot time (not just a live `modprobe`) — `nouveau 0000:04:00.0: NVIDIA
  GK208B`, registers `fb0: nouveaudrmfb`, and `nvidia`/`nvidia-open` correctly
  backs off (`NVRM: GPU already bound to nouveau`). `nvidia-open` (610.x)
  cannot drive this GPU at all: Kepler requires GSP firmware support the
  open-kernel-module driver doesn't provide for pre-Turing GPUs.
- Fix: `/etc/modprobe.d/nvidia-utils.conf` overrides the package-shipped
  `/usr/lib/modprobe.d/nvidia-utils.conf` (which ships a blanket `blacklist
  nouveau`) to drop just that line, keeping `blacklist nova_core`/`nova_drm`
  (the experimental Rust driver — unrelated, left alone). `sudo mkinitcpio -P`
  was run after creating the override so nouveau is available at initramfs
  time, not just after userspace comes up.
- **Known gotcha hit during this fix**: applying the override live via
  `modprobe` without a reboot left the already-running Plasma/Wayland session
  (`plasmalogin.service`) rendering against stale DRM state from before
  nouveau claimed the device — display went blank even though the kernel-level
  fix was already correct. `systemctl restart plasmalogin.service` alone
  didn't resolve it; a full reboot did (nouveau then loads before the
  graphical session starts, so there's no stale state to begin with). If this
  ever needs to be redone, **reboot immediately** rather than trying to hot-
  apply and restart just the display manager.
- Harmless, unrelated log noise: `nouveau: Direct firmware load for
  nouveau/nv106_fuc084* failed`, `msvld: init failed` — nouveau has no
  redistributable firmware for this GPU's video-decode engine, so hardware
  video decode isn't available via nouveau. Doesn't affect display output;
  GT 710's only job here is driving the monitor, not decoding video.
- Also unrelated, seen repeating in kernel logs, not a regression: `amdgpu
  0000:09:00.0: [drm] Cannot find any crtc or sizes` — the R9700 is a
  compute-oriented card with no display output for KMS to enumerate; expected.

## CUDA notes (historical / for when the RTX 5060 Ti returns)
- RTX 5060 Ti = Blackwell, `sm_120`
- Build flag: `-DCMAKE_CUDA_ARCHITECTURES=120`
- Verify GPU indices before setting `CUDA_VISIBLE_DEVICES`:
  `nvidia-smi --query-gpu=index,name --format=csv`
- NVIDIA driver/CUDA toolkit packages (`nvidia-utils`, `linux-cachyos-nvidia-open`,
  etc.) remain installed and untouched through the ROCm migration specifically
  so the 5060 Ti slots back in without a driver reinstall.
