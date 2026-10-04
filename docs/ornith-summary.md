# Ornith-1.5-35B-A3B on wimpy — summary

Full setup guide: `docs/ornith-gguf-setup.md`

## Topology

```
Hermes Desktop ──► hermesvm01 (gateway VM) ──► wimpy:8080 (llama-hugs) ──► R9700 32GB (ROCm)
                                                                      └► 5060 Ti 16GB (CUDA)
```

Desktop never talks to wimpy directly. The gateway owns session state, tools, and model selection.

## Hardware / builds

| | |
|---|---|
| R9700 | 32 GB, ROCm, pinned `HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a`, `--device ROCm0` |
| 5060 Ti | 16 GB, CUDA, `CUDA_VISIBLE_DEVICES=0`, `--device CUDA0` |
| ROCm build | `/usr/local/bin/llama-server` — v0.5.0-dev b11147 `a596c7395` |
| CUDA build | `/opt/llama-cuda/bin/llama-server` |
| Config | `~/wimpy-setup/llama-hugs-config.yaml` → `~/.config/llama-hugs/config.yaml` |

Both GPUs use an env UUID pin **and** an explicit `--device` flag. Never a bare device index.

## Model

`ornith-1-5-35b-a3b-gsq-RCO-3.5bit` — 15.2 GB, arch `qwen35moe`, ROCm group.

| | |
|---|---|
| Context | **262144** (native, uncapped) |
| VRAM @ that ctx | **~18 GB** of 34 GB (q4_0 KV ≈ 1.5 GB) |
| Throughput | ~83 tok/s |
| MTP | none (config declares one; file has no tensors) |
| Vision | text-only, no `mmproj` |
| CUDA | does not fit (17 GB needed > 16 GB free) |
| Router total | 88 models |

KV is unusually cheap: only every 4th of 40 layers is full attention (2 KV heads × head_dim 256). Don't estimate with a dense-model formula — you'll over-predict and wrongly cap context.

## Two load-bearing settings

**`TOOL_BASES` in `/opt/llama-hugs/gen-config.py`** — the generator recomputes and *overrides* `capabilities.tools`. Editing `llama-hugs-config.yaml` alone has no effect on the deployed runtime.

**`max_tokens: 16384` on the gateway's `Wimpy:8080` provider** — the model reasons by default, and reasoning runs 3–4× the answer length.

| Prompt | Tokens | Finish |
|---|--:|---|
| routine | 2,604 | `stop` |
| design / multi-step | 7,843 | `stop` |
| proof + generalise | 9,474 | `stop` |

Below ~12k it truncates to `reasoning_content` alone (`finish_reason: length`). `max_tokens` is a cap, not a target — raising it doesn't cause longer output, it only prevents truncation. Upstream evals used 48K–131K; raise further if you see truncation.

## Commands

```bash
# register
cd ~/wimpy-setup && ./fetch-model.sh -y -c 262144 \
  "hf://pfeifferj/Ornith-1.5-35B-A3B-GSQ-RCO-GGUF/Ornith-1.5-35B-A3B-GSQ-RCO-3.5bit.gguf"

# redeploy after editing gen-config.py or the source config
./tools/llama-hugs-deploy

# verify
curl -s http://127.0.0.1:8080/v1/models | grep -o 'lr-ornith[^"]*' | head -1

# remote reachability
ssh hermesvm01 'python3 -c "import json;d=json.load(open(\"/home/rahlquist/.hermes/gateway_state.json\"));print(d[\"platforms\"])"'
```

## Smoke test coverage

Probes tool-call support (`max_tokens: 128` — small on purpose, so it can't fall into the reasoning-truncation trap). Warns, never fails. Also warns when a tool-capable model is absent from `TOOL_BASES`.

## Gotchas

- GGUF ≥ 19 GiB needs `--no-mmap`; don't overlap large loads. (15.2 GB is under this.)
- Thinking off costs ~995 tokens where thinking on costs ~2,604, for the same prompt. Disable with `"chat_template_kwargs": {"enable_thinking": false}`.
- The Ornith-1.0 `mmproj` won't pair with this GGUF.
- Backup before editing anything under `/opt/llama-hugs` or `~/.hermes/config.yaml`.

## Open

`hermes-gateway.service` (user unit) and `/etc/systemd/system/hermes.service` (system unit) both enabled and both owning the gateway. The user unit has restarted 1,012+ times against the system unit's PID 625. Live and serving; not fixed because the user unit's drop-in carries `HERMES_IROH_RELAY=default`, and iroh is how Desktop reaches the gateway — killing the wrong unit drops the remote session.