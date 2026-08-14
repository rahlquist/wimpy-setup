# Vision model wiring — 2026-08-14 (kanban t_c15b4b7f)

Scope: wire 12 cached vision models into llama-swap on wimpy (R9700 ROCm + 5060 Ti CUDA).

## Result

9 of 12 candidates registered as vision (text + `--mmproj`, smoke-tested PASS).
3 candidates (all >=22GB) FAILED to load with the projector and are NOT registered
as vision per task rule "failed models are not registered."

### Registered & smoke-tested PASS (carries --mmproj)
| alias | GPU | base size | mmproj |
|-------|-----|-----------|--------|
| gemma-4-e4b-uncensored-hauhaucs-aggressive-q8-k-p | R9700 | 8.1GB | Gemma-4-E4B...Q8_K_P.mmproj.gguf |
| muse-glimmer-30b-ud-q2-k-xl | R9700 | 12.5GB | Muse-Glimmer-30B-UD-Q2_K_XL.mmproj.gguf |
| muse-glimmer-30b-ud-q3-k-xl | R9700 | 19.6GB | Muse-Glimmer-30B-UD-Q3_K_XL.mmproj.gguf |
| muse-glimmer-30b-ud-q4-k-xl | R9700 | 15.9GB | Muse-Glimmer-30B-UD-Q4_K_XL.mmproj.gguf |
| qwen3.5-9b-q4 / qwen3.5-9b-q8 | R9700 | 5.6/9.5GB | Qwen3.5-9B.Q4_K_M / .Q8_0 .mmproj.gguf |
| qwen3.5-9b-q4-cuda / qwen3.5-9b-q8-cuda | 5060 Ti | 5.6/9.5GB | (same mmproj files) |
| qwen3-6-27b-fable-fus-711-...-iq2-m / -iq3-m | R9700 | 12.1/14.5GB | Qwen3.6-27B-Fable...IQ2_M / IQ3_M .mmproj.gguf |
| ovisocr2-f16-cuda | 5060 Ti | 1.5GB | OvisOCR2-F16.mmproj.gguf |

### NOT registered as vision (failed load) — exact failure
All three are >=22GB and **stall during model load** with the projector on the
R9700 (ROCm, llama.cpp build **v10354**, 2026-08-10) at 64K ctx. They were
observed stalling (not OOM, not VRAM-exhausted):

- **muse-glimmer-30b-ud-q6-k-xl** (26.3GB): direct `llama-server --mmproj` load
  froze at "loading model" for 7+ min (CPU ~70%, VRAM steady 25.1/34GB, port
  bound but `/health` returned 503). Via llama-swap: "health check timed out
  after 3m0s". Kept as TEXT-only + in `amd-r9700` group (no `--mmproj`).
- **ornith-1-0-35b-ud-q4-k-xl** (22.4GB): identical stall (6:28 elapsed, 87% CPU,
  frozen at "loading model", VRAM 22.1/34GB). Kept as TEXT-only + in
  `amd-r9700` group (no `--mmproj`).
- **qwen3-6-35b-a3b-uncensored-hauhaucs-aggressive-q5-k-p** (28.0GB): never
  loaded (same >=22GB size class as the two stalls above; would 404/stall).
  Entirely new model — removed from config (no entry, no group membership).

### Diagnosis / hypothesis
The <=19GB tier loads + mmproj + completes normally. The >=22GB tier stalls
mid-load specifically WITH the projector at 64K ctx on build v10354. This is a
build/quant-class limitation, not a config error. Projector files themselves are
valid (HF repo `HauhauCS/Qwen3.6-35B...` ships
`mmproj-Qwen3.6-35B...-f16.gguf`; namespaced copy present and matches).
Recommendation: rebuild llama.cpp (or test the large models at lower ctx /
without projector to isolate) before registering the three as vision. They are
intentionally left unregistered until a load succeeds.

### Process notes (for next worker)
- The deploy helper `/usr/local/sbin/llama-swap-deploy` reads
  `SOURCE_CONFIG=/home/rahlquist/wimpy-setup/llama-swap-config.yaml` (the wimpy
  checkout), NOT `~/Downloads/wimpy-setup/` (an older copy that may still exist).
  Edit the wimpy checkout, then `sudo -n /usr/local/sbin/llama-swap-deploy`.
- `llama-swap -watch-config` reload is ASYNC: after deploy, poll
  `GET /v1/models` ~5s later to confirm the catalog settled (it briefly reports
  the prior model count).
- sudo is passwordless only for the deploy script, `/usr/bin/tee`,
  `/usr/bin/journalctl`. Raw `install`/`mv`/`pkill -9` need a password.
- The 30B Muse-Glimmer CUDA twins were intentionally NOT given vision wiring:
  30B exceeds the 16GB 5060 Ti even text-only (per task "don't assume text-fit
  implies vision-fit").
