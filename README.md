# wimpy-setup

Reproducible setup scripts for **wimpy** (Ryzen 7 7700 / 32GB / dual GPU:
AMD R9700 32GB + NVIDIA RTX 5060 Ti 16GB). Wimpy is the bare metal inference
and VM host, running both GPUs concurrently. See `HARDWARE.md` for full specs.

## Wimpy host steps

| Step | Script | What it does |
|------|--------|-------------|
| 01 | `01-system-base.sh` | Base packages, build tools |
| 02 | `02-docker.sh` | Docker CE + Compose |
| 04 | `04-vscodium.sh` | VSCodium |
| 05 | `05-llama-cpp.sh` | llama.cpp (ROCm/HIP gfx1201, R9700) → `/usr/local` + llama-swap on 0.0.0.0:8080 |
| 06 | `06-llama-cpp-cuda.sh` | Second llama.cpp (CUDA sm_120, RTX 5060 Ti) → isolated `/opt/llama-cuda` |
| 07 | `07-claude-code.sh` | Claude Code |
| 08 | `08-networking.sh` | br0 bridge on enp10s0 (DHCP), firewall open 8080 |
| 09 | `09-kvm.sh` | KVM / QEMU / libvirt / virt-manager, registers br0 as host-bridge |

Step 03 (postgres) is not on the host — it's manual. Hermes is not a host step
either; it lives inside hermesvm01. Step 06 is optional: run it only if you want
the RTX 5060 Ti serving models alongside the R9700 (see "Dual-GPU" below).

## Quick start

```bash
git clone <this-repo> ~/Downloads/wimpy-setup
cd ~/Downloads/wimpy-setup
chmod +x *.sh lib/*.sh

bash run-all.sh           # run all steps
bash run-all.sh --from 05 # resume from step 5
bash run-all.sh --only 08 # run one step
bash run-all.sh --list    # list steps
```

## Order dependency

Run step 08 before 09 — the bridge must exist before libvirt can register it.

## After the host scripts

1. `ip addr show br0` — confirm it got an IP from DHCP
2. Add DHCP reservation in OPNsense (MAC is printed at the end of step 08)
3. Add DNS records in Unbound (see DNS section below)
4. Add model paths to `/etc/llama-swap/config.yaml`
5. `sudo systemctl enable --now llama-swap`
6. Re-login for docker/libvirt groups

## hermesvm01 VM

### Create the VM manually in virt-manager
- 4 vCPU, 16 GB RAM, 500 GB qcow2
- Network: host-bridge (br0)
- Install CachyOS + MATE desktop

### After first boot, run inside the VM
```bash
bash hermesvm-setup.sh --hostname hermesvm01
```

### For every future Hermes VM
1. Clone the hermesvm01 template in virt-manager
2. Boot the clone
3. Run `bash hermesvm-setup.sh --hostname <new-name>`

The script is fully idempotent and parameterised — same script, different hostname.

### Optional overrides
```bash
# If your domain or port differs from defaults
bash hermesvm-setup.sh --hostname hermesvm02 --wimpy wimpy.home.lan --port 8080
```

## DNS and DHCP (OPNsense)

See `DNS-DHCP-INSTRUCTIONS.md` for step-by-step Unbound and dnsmasq config.

## Service cheatsheet

```bash
# On wimpy host
sudo systemctl status llama-swap
journalctl -u llama-swap -f
sudo virsh list --all
sudo virsh domifaddr hermesvm01    # get VM's IP after boot

# Inside hermesvm01
sudo systemctl status hermes
journalctl -u hermes -f
hermes doctor
curl http://wimpy.home.lan:8080/v1/models   # verify wimpy reachable
```

## Models (llama.cpp + llama-swap)

- Models are added one at a time with `fetch-model.sh` (see below), which
  downloads the GGUF into `~/.cache/llama.cpp/` and registers it in the config.
- `llama-swap-config.yaml` — deploy to `/etc/llama-swap/config.yaml`. Every
  model uses an explicit `--model` path to the downloaded file (one consistent
  method — no `-hf` re-downloads). All at 65536 context (Hermes minimum), with
  flash attention + Q4 quantized KV cache. Split into two GPU groups (see
  "Dual-GPU" below): the R9700 entries pin by UUID + `--device ROCm0`, the
  `-cuda` entries use `/opt/llama-cuda/bin/llama-server` + `--device CUDA0`. On
  the 32GB R9700 all MoE experts now fit on the GPU (`--n-cpu-moe 0`); if you
  re-tune for tighter VRAM, smoke-test the count per hardware/context.
- `fetch-model.sh` — accepts a pasted one-file Hugging Face command such as
  `./fetch-model.sh "hf download hf://owner/repo/file.gguf 21"`. It downloads an
  explicit local GGUF, inspects its metadata, validates the optional CPU-MoE
  block count, smoke-tests the final llama.cpp command, registers the model,
  updates `model-inventory.html`, then commits and pushes the two tracked files.
  `--no-push` disables that final remote write.
- `model-inventory.html` — generated tracked inventory: llama-swap alias,
  filename, added date, GGUF architecture/native context, description, and
  effective custom llama.cpp parameters.
- `llama-swap.service` — the systemd unit (also installed by `05-llama-cpp.sh`).

### Hugging Face authentication

`fetch-model.sh` relies on the `hf` CLI being logged in. Authenticate once:

```bash
hf auth login        # paste a token from https://huggingface.co/settings/tokens
```

Do NOT commit token files to the repo. `.gitignore` blocks `*token*` and `*.env`
for this reason. The token is stored by the CLI in `~/.cache/huggingface/`.

## Dual-GPU (R9700 + RTX 5060 Ti)

Both GPUs serve inference at the same time, behind one `llama-swap`:

- **Two llama.cpp builds, isolated.** The ROCm/HIP build (`05-llama-cpp.sh`)
  installs to `/usr/local`; the CUDA build (`06-llama-cpp-cuda.sh`) installs to
  `/opt/llama-cuda`. They must stay in separate prefixes — llama.cpp's HIP and
  CUDA backends share library filenames, so a shared prefix would clobber one.
  You can't combine both backends in a single binary.
- **One llama-swap, two groups.** `llama-swap-config.yaml` defines `amd-r9700`
  (26 models, `--device ROCm0`) and `nvidia-5060ti` (19 `<16GB` models,
  `--device CUDA0`). Both groups are `exclusive: false`, so one model per GPU
  can be resident at once and two agents run in parallel — one per card.
  Every model must belong to a group or it lands in the default exclusive
  group and breaks concurrency.
- **Same model, both cards.** A `-cuda` entry is the same GGUF as its AMD twin
  with the CUDA binary + pin, so either GPU can serve it (routed by model name).
- **Pinning.** R9700 by stable UUID (`HIP_VISIBLE_DEVICES=GPU-…`) so the Ryzen
  iGPU — which also enumerates as a ROCm device — can't be picked by accident;
  5060 Ti by `CUDA_VISIBLE_DEVICES=0`. Both add `--device …0` as a hard-fail
  guard against silent CPU fallback.

## Network topology

See `NETWORK-DIAGRAM.md` for the host/VM bridge layout and traffic flow
(rendered diagram: `network-diagram.svg`).

## Files in this project

```
01-system-base.sh        05-llama-cpp.sh        08-networking.sh
02-docker.sh             06-llama-cpp-cuda.sh   09-kvm.sh
04-vscodium.sh           07-claude-code.sh      10-create-vm-example.sh
run-all.sh               lib/common.sh

fetch-model.sh           llama-swap-config.yaml llama-swap.service
hermesvm-setup.sh        (VM post-install, --hostname parameterised)

README.md                CLAUDE.md              HARDWARE.md
DNS-DHCP-INSTRUCTIONS.md NETWORK-DIAGRAM.md     CHANGELOG.md
```
