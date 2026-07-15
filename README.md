# wimpy-setup

Reproducible setup scripts for **wimpy** (Ryzen 9 3900X / 64GB / RTX 5060 Ti).
Wimpy is the bare metal inference and VM host. See `HARDWARE.md` for full specs.

## Wimpy host steps

| Step | Script | What it does |
|------|--------|-------------|
| 01 | `01-system-base.sh` | Base packages, build tools |
| 02 | `02-docker.sh` | Docker CE + Compose |
| 04 | `04-vscodium.sh` | VSCodium |
| 05 | `05-llama-cpp.sh` | llama.cpp (CUDA sm_120, RTX 5060 Ti) + llama-swap on 0.0.0.0:8080 |
| 07 | `07-claude-code.sh` | Claude Code |
| 08 | `08-networking.sh` | br0 bridge on enp6s0 (DHCP), firewall open 8080 |
| 09 | `09-kvm.sh` | KVM / QEMU / libvirt / virt-manager, registers br0 as host-bridge |

Steps 03 (postgres) and 06 (hermes) are not on the host — postgres is manual,
hermes lives inside hermesvm01.

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

- `download-models.sh` — pulls 18 GGUF models into `~/.cache/llama.cpp/`.
  Continues past failures and prints a summary. Repo/filenames verified.
- `llama-swap-config.yaml` — deploy to `/etc/llama-swap/config.yaml`. Every
  model uses an explicit `--model` path to the downloaded file (one consistent
  method — no `-hf` re-downloads). All at 65536 context (Hermes minimum), with
  flash attention + Q4 quantized KV cache. MoE models use explicitly selected
  `--n-cpu-moe` values to keep expert tensors for the first N blocks in system
  RAM; the count must be smoke-tested for the hardware/context combination.
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

`download-models.sh` relies on the `hf` CLI being logged in. Authenticate once:

```bash
hf auth login        # paste a token from https://huggingface.co/settings/tokens
```

Do NOT commit token files to the repo. `.gitignore` blocks `*token*` and `*.env`
for this reason. The token is stored by the CLI in `~/.cache/huggingface/`.

## Network topology

See `NETWORK-DIAGRAM.md` for the host/VM bridge layout and traffic flow
(rendered diagram: `network-diagram.svg`).

## Files in this project

```
01-system-base.sh        04-vscodium.sh         08-networking.sh
02-docker.sh             05-llama-cpp.sh        09-kvm.sh
07-claude-code.sh        10-create-vm-example.sh
run-all.sh               lib/common.sh

download-models.sh       llama-swap-config.yaml llama-swap.service
hermesvm-setup.sh        (VM post-install, --hostname parameterised)

README.md                CLAUDE.md              HARDWARE.md
DNS-DHCP-INSTRUCTIONS.md NETWORK-DIAGRAM.md     CHANGELOG.md
```
