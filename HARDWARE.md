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
- R9700 = RDNA4-class, `gfx1201`. Packages: `llama-cpp-rocm` (b9833-1.1),
  `ggml-rocm` (0.15.3-3.1) — installed via pacman, not built from source.
- Binary: `/usr/bin/llama-server` (NOT `/usr/local/bin` — that path was an
  orphaned CUDA-only build from this repo's old build-from-source flow and
  was removed during the 2026-07-07 ROCm migration; see CHANGELOG.md).
- GPU pinning: `HIP_VISIBLE_DEVICES=0` + `--device ROCm0` (the latter also
  makes missing-GPU a hard startup failure instead of a silent CPU fallback).
- Verify device name/index: `/usr/bin/llama-server --list-devices`

## GT 710 display driver status
- GT 710 = Kepler, `sm_35` — too old for llama.cpp inference regardless of
  which primary GPU is installed; always excluded from inference.
- **As of 2026-07-07, GT 710 has no real display driver bound** — it's
  running on the raw UEFI/GOP framebuffer (`simple-framebuffer`, works but
  unaccelerated). `nvidia-open` (610.x) cannot drive it: Kepler requires GSP
  firmware support the open-kernel-module driver doesn't provide for
  pre-Turing GPUs. `nouveau` would work but is blocked by a `blacklist
  nouveau` line the `nvidia-utils` package itself ships in
  `/usr/lib/modprobe.d/nvidia-utils.conf` (not `/etc`). Fix is planned as a
  separate, explicitly-confirmed step (creating an `/etc/modprobe.d`
  override) — not yet applied as of this doc update.

## CUDA notes (historical / for when the RTX 5060 Ti returns)
- RTX 5060 Ti = Blackwell, `sm_120`
- Build flag: `-DCMAKE_CUDA_ARCHITECTURES=120`
- Verify GPU indices before setting `CUDA_VISIBLE_DEVICES`:
  `nvidia-smi --query-gpu=index,name --format=csv`
- NVIDIA driver/CUDA toolkit packages (`nvidia-utils`, `linux-cachyos-nvidia-open`,
  etc.) remain installed and untouched through the ROCm migration specifically
  so the 5060 Ti slots back in without a driver reinstall.
