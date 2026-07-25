# wimpy-setup

Reproducible setup scripts for **wimpy** (Ryzen 7 7700 / 32GB / dual GPU:
AMD R9700 32GB + NVIDIA RTX 5060 Ti 16GB). Wimpy is the bare metal inference
and VM host, running both GPUs concurrently. See `HARDWARE.md` for full specs.

> This is not a guide. It comes with no promise of support or assistance. It is merely a way for me to safely share my setup in a manner I can restore my system with and perhaps give others some inspiration.

## Wimpy host steps

| Step | Script | What it does |
|------|--------|-------------|
| 01 | `01-system-base.sh` | Base packages, build tools |
| 02 | `02-docker.sh` | Docker CE + Compose |
| 04 | `04-vscodium.sh` | VSCodium |
| 05 | `05-llama-cpp.sh` | llama.cpp (ROCm/HIP gfx1201, R9700) → `/usr/local` + llama-swap on 0.0.0.0:8080 |
| 06 | `06-llama-cpp-cuda.sh` | Second llama.cpp (CUDA sm_120, RTX 5060 Ti) → isolated `/opt/llama-cuda` |
| 07 | `07-claude-code.sh` | Claude Code |
| 08 | `08-networking.sh` | br0 bridge on lan0 (MAC-pinned NIC name, DHCP), firewall open 8080 |
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
- `fetch-model.sh` — multi-source GGUF acquisition pipeline. Accepts a
  Hugging Face paste, a direct HTTP(S) URL, or a local `.gguf` path. Covers
  inspection, metadata validation, GPU smoke-test, registration, and automatic
  commit+push. See "Adding a model" below.
- `model-inventory.html` — generated tracked inventory: llama-swap alias,
  filename, added date, GGUF architecture/native context, description, and
  effective custom llama.cpp parameters.
- `llama-swap.service` — the systemd unit (also installed by `05-llama-cpp.sh`).

### Adding a model

```bash
./fetch-model.sh [options] <spec>
```

**Source classes:**

| Class | Examples |
|-------|----------|
| Hugging Face | `hf download hf://owner/repo/file.gguf 21`, `hf://owner/repo/file.gguf`, `https://huggingface.co/owner/repo/resolve/main/file.gguf` |
| HTTP(S) URL | `https://example.com/path/model.gguf` (uses `curl`) |
| Local file | `/abs/or/rel/path/to/model.gguf` |

A trailing number (e.g. `21`) sets `--n-cpu-moe N` — only accepted when GGUF
metadata confirms the model is MoE. Rejected for dense models.

**Key flags:**

| Flag | Effect |
|------|--------|
| `-n <id>` | Explicit model id (default: derived from filename) |
| `-c <ctx>` | Requested context (default and minimum 65536; must not exceed the model's native GGUF context) |
| `-d ROCm0|CUDA0` | Override GPU device detection |
| `--keep-source` | Retain original local file after pipeline success (default: deleted) |
| `--no-smoke` | Skip GPU smoke test |
| `--no-register` | Download and inspect only, skip config registration |
| `--no-push` | Disable automatic git commit and push after registration |

**Error recovery:** Mid-pipeline failures (inspect/validate/smoke/register) write
a `*.dossier.md` containing the stage, partial state, and a ready-to-run resume
command. Paste the fenced block to Hermes to recover. Bad specs (classify
failure) produce no dossier — that is a usage error, not a pipeline stall.

**Idempotency:** Re-registering the same model (same name, same repo/file) exits
0 with a warning. Registering the same name with different content exits 1
(name collision) — config and existing model are untouched.

**Models directory:** `MODELS_DIR` env var (default `~/.cache/llama.cpp/`).

**Tests:** `bash tests/run_tests.sh` — uses stubs for `hf`, `curl`, and
`llama-server`; no network or GPU required.

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
