# Running Ornith-1.5-35B-A3B GGUFs on a dual-GPU ROCm + CUDA host

Reproducible setup for serving `Ornith-1.5-35B-A3B` GGUFs from a wimpy-class
machine (AMD R9700 32 GB + NVIDIA 5060 Ti 16 GB) and wiring a remote Hermes
Desktop client to reach them.

Everything here is a setup requirement, not a post-mortem. Two of these look
like optional polish but are load-bearing — they are called out explicitly.

---

## 1. Prerequisites

| Component | Version / path |
|---|---|
| Kernel | 7.2.6-1-cachyos (any recent ROCm-capable kernel) |
| ROCm | `/opt/rocm`, `hipcc` on PATH |
| CUDA | `/opt/cuda`, `nvcc` on PATH, `nvidia-smi` working |
| llama.cpp (ROCm) | `/usr/local/bin/llama-server` |
| llama.cpp (CUDA) | `/opt/llama-cuda/bin/llama-server` |
| `hf` CLI | `huggingface_hub` 1.31+ |

Verify both backends see hardware before going further:

```bash
/usr/local/bin/llama-server --list-devices      # expect ROCm0 = R9700
/opt/llama-cuda/bin/llama-server --list-devices  # expect CUDA0 = 5060 Ti
```

The ROCm build must contain the `qwen35moe` architecture. Confirm:

```bash
strings -a /usr/local/lib/libllama.so.0 | grep -c llama_model_qwen35moe
```

A `0` means the build predates Qwen3.5 support — rebuild from
`~/src/llama.cpp` with `07-upgrade-llama-cpp.sh` before continuing.

Build both backends from the same source commit via `07-upgrade-llama-cpp.sh`.
It rebuilds ROCm into `/usr/local` and CUDA into `/opt/llama-cuda`, and leaves
llama-hugs untouched. Run it as the normal user, not under `sudo bash` (sudo
resets `HOME` and the checkout resolves to `/root`).

---

## 2. Fetch and register the model

```bash
cd ~/wimpy-setup
./fetch-model.sh -y -c 262144 \
  "hf://pfeifferj/Ornith-1.5-35B-A3B-GSQ-RCO-GGUF/Ornith-1.5-35B-A3B-GSQ-RCO-3.5bit.gguf"
```

What the pipeline does: downloads, verifies SHA256 against the repo's
`SHA256SUMS`, inspects GGUF metadata, smoke-tests on the target GPU, registers
in `llama-hugs-config.yaml`, regenerates the inventory, and deploys the live
config.

`-c 262144` is required here. Ornith-1.5's native context is 262144; without
it the script applies its 65536 working cap.

Two variants ship. The 3.5-bit build (15.2 GB) is the one to use — better
MMLU-Pro and IFEval than the 3-bit build, and the size difference is
irrelevant on a 32 GB card. The 3-bit build (13.0 GB) still will not fit CUDA.

### Expected result

```
[OK]   sha256 verified
[OK]   tool-call smoke activity: well-formed tool_calls emitted
[OK]   loaded, generated, and healthy at ctx=262144 on ROCm0
[OK]   registered 'ornith-1-5-35b-a3b-gsq-rco-3-5bit'
```

CUDA registration is expected to be refused:

```
CUDA decision: NOT SUPPORTED — estimated required 17G exceeds free 16G
```

That is correct. Do not try to force it.

---

## 3. Load-bearing: the `TOOL_BASES` allowlist

**This step is not optional. Skipping it makes the model appear broken in
agent use while everything reports healthy.**

`/opt/llama-hugs/gen-config.py` recomputes `capabilities.tools` for every
model from a hardcoded allowlist, and **overwrites** whatever
`llama-hugs-config.yaml` says. Editing the YAML alone has no effect on the
deployed runtime.

If the smoke test reports tool-call activity but the model id is missing from
`TOOL_BASES`, the generator strips the flag silently. Add it:

```bash
# back up first
cp -v /opt/llama-hugs/gen-config.py \
      /opt/llama-hugs/gen-config.py.bak.$(date +%Y%m%d%H%M%S)

# add "ornith-1-5-35b-a3b-gsq-rco-3-5bit" to the TOOL_BASES list (idempotent)
/usr/bin/python3 - <<'PYEOF'
p = "/opt/llama-hugs/gen-config.py"
MODEL = "ornith-1-5-35b-a3b-gsq-rco-3-5bit"
s = open(p).read()
if MODEL in s:
    print(f"already present in TOOL_BASES: {MODEL} (no change needed)")
elif '"qwen2.5-coder-14b"]' in s:
    open(p, "w").write(s.replace('"qwen2.5-coder-14b"]',
                                  f'"qwen2.5-coder-14b", "{MODEL}"]', 1))
    print(f"added {MODEL} to TOOL_BASES")
else:
    raise SystemExit("TOOL_BASES anchor not found - inspect gen-config.py and add the id by hand")
PYEOF
```

The file is user-owned (`rahlquist:rahlquist`, mode 755) — no sudo needed.
Redeploy afterwards:

```bash
./tools/llama-hugs-deploy
```

Then confirm the flag survived into the live config:

```bash
awk '/hugs-ornith-1-5-35b-a3b-gsq-rco-3-5bit:/{f=NR}
     f && NR>=f && NR<=f+13' ~/.config/llama-hugs/config.yaml | grep tools
# expect:  - tools: true
```

---

## 4. Verify locally on the inference host

```bash
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool | grep -A3 ornith
```

Then a real completion, and a real tool call:

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"lr-ornith-1-5-35b-a3b-gsq-rco-3-5bit",
       "messages":[{"role":"user","content":"What is 84 * 3 / 2?"}],
       "max_tokens":600,"temperature":0.6}'
```

Tool-call check (expect `finish_reason: tool_calls` and a populated
`tool_calls[0].function.arguments`):

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"lr-ornith-1-5-35b-a3b-gsq-rco-3-5bit",
       "messages":[{"role":"user","content":"What is the weather in Paris? Use the tool."}],
       "tools":[{"type":"function","function":{"name":"get_weather",
         "description":"Get weather for a city",
         "parameters":{"type":"object","properties":{"city":{"type":"string"}},
                       "required":["city"]}}}],
       "max_tokens":300}'
```

VRAM expectation at ctx 262144: **~18 GB** of 34 GB. Weights 15.2 GB plus
roughly 1.5 GB of q4_0 KV. The KV figure is small because only every 4th layer
is full attention (2 KV heads × head_dim 256) — do **not** estimate this with a
dense-model formula, or you will over-predict and wrongly cap the context.

---

## 5. Point the Hermes gateway at it

On the gateway host (`hermesvm01`), `~/.hermes/config.yaml` needs a custom
provider. It may already exist; edit rather than duplicate.

```yaml
custom_providers:
  - name: Wimpy:8080
    base_url: http://wimpy:8080/v1
    max_tokens: 16384          # see below — load-bearing
    model: hugs-qwen3.5-9b-q4-cuda
    discover: true
    models:
      lr-ornith-1-5-35b-a3b-gsq-rco-3-5bit: {}
```

### Load-bearing: `max_tokens` must be 16384 or higher

Ornith-1.5 is a reasoning model. By default the assistant turn opens with a
thinking block, and that reasoning runs **3-4x the length of the final
answer**. With a small `max_tokens` the entire budget is consumed by
`reasoning_content` and the response truncates — `finish_reason: length`,
sometimes with empty `content`.

Measured on this model:

| Prompt difficulty | Tokens used | Finish |
|---|--:|---|
| Routine explanation | 2,604 | `stop` |
| Design / multi-step reasoning | 7,843 | `stop` |
| Proof + generalisation | 9,474 | `stop` |

Worst case observed is 9,474, so 16384 carries real margin. Note that
`max_tokens` is a cap, not a target — raising it does not make the model
generate more, it only prevents truncation.

The upstream model card's own evaluation budgets were 48K-131K output tokens.
If you hit `finish_reason: length` in real use, raise it further; truncation is
always observable, so this is monitor-and-adjust rather than guesswork.

Back up before editing:

```bash
cp -v ~/.hermes/config.yaml ~/.hermes/config.yaml.bak.$(date +%Y%m%d%H%M%S)
```

Verify after editing that only the intended provider changed — other providers
in the same file also declare `max_tokens`:

```bash
grep -n "max_tokens:" ~/.hermes/config.yaml
```

Restart the gateway and confirm the model appears:

```bash
systemctl --user restart hermes-gateway.service
curl -s http://wimpy:8080/v1/models | grep -o 'lr-ornith[^"]*' | head -1
```

---

## 6. Remote access (Hermes Desktop)

The desktop client does not reach the inference host directly. Path is:

```
Hermes Desktop  ──►  gateway host (hermesvm01)  ──►  wimpy:8080  ──►  GPU
```

The gateway runs as a KVM guest on the inference host and owns session state,
the tool catalog, and model selection. Remote reachability uses the iroh
relay, configured via `HERMES_IROH_RELAY` in the gateway's unit drop-in:

```bash
cat ~/.config/systemd/user/hermes-gateway.service.d/relay.conf
# [Service]
# Environment="HERMES_IROH_RELAY=default"
```

Confirm the relay is connected before debugging anything else:

```bash
python3 -c "import json;d=json.load(open('~/.hermes/gateway_state.json'));print(d['platforms'])"
# want: iroh state=connected, api_server state=connected
```

---

## 7. Operational notes

**Swap groups.** ROCm models belong to the ROCm group and CUDA models to the
CUDA group in `llama-hugs-config.yaml`. Each entry keeps its group-specific env
pin (`HIP_VISIBLE_DEVICES=GPU-<uuid>` / `CUDA_VISIBLE_DEVICES=0`) plus an
explicit `--device` flag. Never substitute a device index for the UUID pin.

**Large GGUF guard.** Files ≥19 GiB need `--no-mmap` in both smoke and
registered commands, and must not overlap with another large load. Ornith's
15.2 GB build is under that threshold, so it needs no special handling.

**No MTP.** The upstream config declares `mtp_num_hidden_layers: 1` but this
GGUF contains no MTP tensors. Speculative decoding is unavailable; trust the
smoke draft counters (`draft=0 accepted=0`), not the config metadata.

**Text-only.** The chat template carries vision tokens but the repo ships no
`mmproj`. A projector from a different Ornith build will not pair with it.

**Thinking on by default.** When driving the model from an API client with a
tight token budget, either budget for `reasoning_content` or disable thinking:

```json
"chat_template_kwargs": {"enable_thinking": false}
```

With thinking off, the same prompt that costs ~2,600 tokens costs ~995.
Thinking is worth keeping for hard problems and is pure overhead for routine
work.

---

## Troubleshooting

| Symptom | Check |
|---|---|
| Model missing from `/v1/models` | Registration failed — check the `fetch-model` run log |
| Loads fine, no tool calls in agent use | `TOOL_BASES` allowlist — step 3 |
| `finish_reason: length`, truncated or empty answer | `max_tokens` too low — step 5 |
| Model absent on the desktop client | Gateway `models:` allowlist and iroh relay state |
| `unknown model architecture` at load | ROCm build lacks `qwen35moe` — section 1 |
| OOM at ctx 262144 | Unexpected; should be ~18 GB. Check for a second model resident |

The `fetch-model.sh` run writes a full log and, on failure, a recovery dossier
naming the stage it reached. Both land in the directory you ran it from.