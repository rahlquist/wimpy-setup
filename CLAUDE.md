# CLAUDE.md — wimpy llama.cpp + llama-swap project

Context for Claude Code working in this directory on the host **wimpy**.

## What this machine is

wimpy is a bare-metal inference + VM host. It replaced an older box ("slug").
- CPU: Ryzen 9 3900X (12c/24t) · RAM: 64 GB · NVMe: 2 TB
- GPU 0: **RTX 5060 Ti 16 GB** — the inference GPU
- GPU 1: GeForce GT 710 — display only, must be EXCLUDED from inference
- OS: CachyOS (Arch-based), bash shell, KDE
- Network: bridge `br0` on `enp6s0`, static-via-DHCP at **192.168.8.248**,
  hostname **wimpy.home.lan** (DNS/DHCP on OPNsense: Unbound + dnsmasq)

A KVM guest **hermesvm01** (192.168.8.249) runs Hermes Agent and reaches this
host's llama-swap at `http://wimpy.home.lan:8080/v1`.

## The inference stack

- `llama-server` / `llama-cli` built from source with CUDA sm_120 → /usr/local/bin
- `llama-swap` (model router) → /usr/local/bin, systemd service `llama-swap`,
  listens on **0.0.0.0:8080** so the VM can reach it
- Models downloaded by `download-models.sh` into `~/.cache/llama.cpp/`
- `llama-swap-config.yaml` → deploys to `/etc/llama-swap/config.yaml`

## Files here

- `download-models.sh` — pulls GGUF models via `hf download` to ~/.cache/llama.cpp/.
  Continues on failure, prints a failure summary. Repo/filenames verified June 2026.
- `llama-swap-config.yaml` — model definitions. EVERY entry uses an explicit
  `--model /home/rahlquist/.cache/llama.cpp/<file>.gguf` path (NOT `-hf`).
- `llama-swap.service` — systemd unit file. Deploy with:
  `sudo cp llama-swap.service /etc/systemd/system/ && sudo systemctl daemon-reload`
- `05-llama-cpp.sh` etc. — host setup scripts (already run).

## System state (as of 2026-06-28)

- **llama-swap** is running and enabled (`sudo systemctl status llama-swap`).
- **libggml-cuda** fix: `/etc/ld.so.conf.d/local-lib.conf` contains `/usr/local/lib`
  so llama-server can find its CUDA shared libraries. Without this, every model fails
  with "libggml-cuda.so.0: No such file or directory".
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
- **All 18 models load cleanly** — see load test results below.

## Hard rules (do not violate)

1. **Back up before modifying any working config.** Timestamped copy first:
   `cp /path/config /path/$(date +%Y%m%d%H%M%S)-config-filename`
   This applies to /etc/llama-swap/config.yaml and any systemd unit.
2. **GPU pinning is intentional.** Every model entry sets
   `CUDA_VISIBLE_DEVICES=0` to exclude the GT 710. Do NOT remove it.
3. **Use local --model paths, not -hf.** The config deliberately points at the
   files download-models.sh already fetched. Do NOT convert entries to `-hf`
   (that triggers a second, separate download).
4. **Context is 65536 everywhere.** Hermes Agent requires a 64K minimum. Do not
   lower a model's ctx below 65536 unless explicitly told to for an OOM fix, and
   if you do, call it out as a deviation.
5. **Confirm before sudo / service / network changes.** Show the command and
   wait for approval. This is a live inference box.
6. **Tune one model at a time.** For VRAM fixes, change one value, reload, check
   `nvidia-smi`, then proceed. No batch edits.

## Standard bring-up sequence

### On a host that already has llama-server/llama-swap installed

1. Verify model files exist with sane sizes:
   `ls -la ~/.cache/llama.cpp/*.gguf`
   Cross-check against the `--model` paths in llama-swap-config.yaml.
2. Confirm GPU index: `nvidia-smi --query-gpu=index,name --format=csv`
   (RTX 5060 Ti must be index 0; if not, flag it — pinning assumes 0.)
3. **Fix the CUDA library path** (required on fresh installs — llama-server will fail
   with "libggml-cuda.so.0: No such file or directory" without this):
   `echo "/usr/local/lib" | sudo tee /etc/ld.so.conf.d/local-lib.conf && sudo ldconfig`
   Verify: `ldconfig -p | grep libggml-cuda` should return a hit.
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
9. Check VRAM with a model loaded: `nvidia-smi`

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

**Download models** (use `hf`, not `huggingface-cli` — the latter is deprecated):
`bash download-models.sh`

## Load test results (2026-06-28, all 18 models)

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

- `phi-4` — config and download-models.sh use **Q4_K_M** (not Q8_0). Q8_0 confirmed
  OOM at 64K even with 15.8 GB free — weights alone consume ~15.5 GB.
- `qwen2.5-coder-14b` — training context is 32768; llama-server silently caps
  `--ctx-size 65536` to 32768. Hermes prompts longer than 32K will be rejected.
- `gemma-3-12b` — Q8_0 (~12.5 GB) fits at 64K on 16 GB with room to spare. Was
  flagged as "tight" but confirmed OK in isolation.
- MoE models (`qwen3-30b-a3b`, `gemma-4-26b-moe`, `ling-mini-2-*`): use
  `-ngl 99 --n-cpu-moe N`. N is a conservative starting point — lower it to push
  more experts onto the GPU for speed, watching `nvidia-smi` for headroom.
  `--n-cpu-moe` counts from the highest-numbered layers down.

## Verify from the VM (end-to-end)

From hermesvm01: `curl http://wimpy.home.lan:8080/v1/models` should return the
model list. If it fails but localhost works, check UFW: `sudo ufw status` should
show `allow in on br0`. Do NOT add nftables rules alongside UFW — they conflict.
