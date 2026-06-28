# wimpy — hardware reference

| Component | Detail |
|-----------|--------|
| Board     | ASUS TUF GAMING B550M-PLUS |
| CPU       | AMD Ryzen 9 3900X — 12 cores / 24 threads |
| RAM       | 64 GiB DDR4-3200 (4 × 16 GiB) |
| GPU 0     | NVIDIA GeForce RTX 5060 Ti (GB206, 16 GB VRAM) — inference |
| GPU 1     | NVIDIA GeForce GT 710 (GK208B) — display head only |
| Storage   | WD_BLACK SN770 2 TB NVMe (`/dev/nvme0n1`) |
| NIC       | Realtek RTL8125 2.5 GbE (`enp6s0`) |

## Partition layout
| Device         | Size    | Role           |
|----------------|---------|----------------|
| nvme0n1p1      | 4 GiB   | Windows FAT/EFI|
| nvme0n1p2      | 1.8 TiB | Linux root     |
| nvme0n1p3      | 31 GiB  | Linux swap     |

## CUDA notes
- RTX 5060 Ti = Blackwell, `sm_120`
- GT 710 = Kepler, `sm_35` — too old for llama.cpp inference; excluded via `CUDA_VISIBLE_DEVICES`
- Build flag: `-DCMAKE_CUDA_ARCHITECTURES=120`
- Verify GPU indices before setting `CUDA_VISIBLE_DEVICES`:
  `nvidia-smi --query-gpu=index,name --format=csv`
