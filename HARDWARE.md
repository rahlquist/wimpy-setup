# wimpy — hardware reference

| Component | Detail |
|-----------|--------|
| Board     | ASRock X870 Taichi Creator (AM5) |
| CPU       | AMD Ryzen 9 9900X — 12 cores / 24 threads |
| RAM       | 64 GiB (installed capacity; kernel reports 60.4 GiB usable) |
| GPU 0     | AMD Radeon AI PRO R9700 (Navi 48, gfx1201, 32 GiB VRAM), PCI `03:00.0` |
| GPU 1     | AMD Radeon AI PRO R9700 (Navi 48, gfx1201, 32 GiB VRAM), PCI `07:00.0` |
| iGPU      | AMD Raphael integrated graphics, PCI `76:00.0` (2 GiB aperture; 0.8 GiB currently in use) |
| NVIDIA    | No NVIDIA PCI display adapter or kernel driver is currently detected. NVIDIA/CUDA userspace packages remain installed, but `nvidia-smi` cannot communicate with a driver. |
| Storage   | Predator SSD GM7000 4 TB NVMe (`/dev/nvme0n1`, system); WD_BLACK SN770 2 TB NVMe (`/dev/nvme1n1`, secondary) |
| OS/kernel | CachyOS, x86-64; running kernel `7.3.1-1-cachyos` |
| NIC       | Verify current interface and bridge mapping with `ip -br link`; older inventory below described the prior platform. |

**Platform swap (2026-11-02):** live inspection now shows a Ryzen 9 9900X,
64 GiB installed RAM, and two AMD Radeon AI PRO R9700 cards at PCI `03:00.0`
and `07:00.0`, both exposed as ROCm `gfx1201`. The Raphael iGPU is at
`76:00.0`. No NVIDIA PCI GPU or loaded NVIDIA kernel module is present, and
`nvidia-smi` cannot communicate with a driver; NVIDIA/CUDA packages remain
installed, but CUDA serving is currently unavailable. The primary NVMe is now
a 4 TB Predator GM7000 (`/dev/nvme0n1`); a 2 TB WD_BLACK SN770 is also present
at `/dev/nvme1n1`. The host runs CachyOS kernel `7.3.1-1-cachyos`.

The earlier July 2026 platform notes below are retained as history, not current
hardware facts. In particular, the old Ryzen 7 7700 / 32 GiB / single-R9700 /
RTX 5060 Ti inventory and the single-card ROCm pin are stale. Re-check GPU
UUIDs, installed drivers, service config, and any model group before reusing
older setup instructions. Current PCI addresses and kernel enumeration are
observed values and can change after hardware or firmware changes.

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

## GT 710 display driver status (HISTORICAL — GT 710 removed in the 2026-07-23 platform swap)
> The GT 710 is no longer in the machine; display is now handled by the Raphael
> iGPU (or the RTX 5060 Ti). The notes below are retained only as a record of
> the nouveau troubleshooting done while it was installed.
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
  ...: [drm] Cannot find any crtc or sizes` — the R9700 is a compute-oriented
  card with no display output for KMS to enumerate; expected. (PCI address is
  now `03:00.0` on the X870 board, was `09:00.0` on the old B550.)

## CUDA notes (RTX 5060 Ti — reinstalled 2026-07-23, PCI `04:00.0`)
- RTX 5060 Ti = Blackwell, `sm_120`
- Build flag: `-DCMAKE_CUDA_ARCHITECTURES=120`
- Verify GPU indices before setting `CUDA_VISIBLE_DEVICES`:
  `nvidia-smi --query-gpu=index,name --format=csv`
- NVIDIA driver/CUDA toolkit packages (`nvidia-utils`, `linux-cachyos-nvidia-open`,
  etc.) remain installed and untouched through the ROCm migration specifically
  so the 5060 Ti slots back in without a driver reinstall.

## More hardware details
- https://linux-hardware.org/?probe=9826016cac
