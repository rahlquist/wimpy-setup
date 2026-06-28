# Changelog — wimpy-setup

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
