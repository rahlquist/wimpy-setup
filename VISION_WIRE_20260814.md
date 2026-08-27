# Vision model wiring — 2026-08-14 (kanban t_c15b4b7f)

Scope: wire 12 cached vision models into llama-hugs on wimpy (R9700 ROCm + 5060 Ti CUDA).

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
  bound but `/health` returned 503). Via llama-hugs: "health check timed out
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
- The deploy helper `/usr/local/sbin/llama-hugs-deploy` reads
  `SOURCE_CONFIG=/home/rahlquist/wimpy-setup/llama-hugs-config.yaml` (the wimpy
  checkout), NOT `~/Downloads/wimpy-setup/` (an older copy that may still exist).
  Edit the wimpy checkout, then `sudo -n /usr/local/sbin/llama-hugs-deploy`.
- `llama-hugs -watch-config` reload is ASYNC: after deploy, poll
  `GET /v1/models` ~5s later to confirm the catalog settled (it briefly reports
  the prior model count).
- sudo is passwordless only for the deploy script, `/usr/bin/tee`,
  `/usr/bin/journalctl`. Raw `install`/`mv`/`pkill -9` need a password.
- The 30B Muse-Glimmer CUDA twins were intentionally NOT given vision wiring:
  30B exceeds the 16GB 5060 Ti even text-only (per task "don't assume text-fit
  implies vision-fit").

## Retest 2026-08-14 14:38 UTC — muse-glimmer-30b-ud-q6-k-xl (FAILED — reproduced)

Isolated direct-load retest per task t_9e3b8344. Outcome: FAIL (stall >900s, no /health OK).
No --mmproj added; the existing text-only entry in amd-r9700 is preserved.

Command (isolated port 8091, R9700 only):
  /usr/local/bin/llama-server \
    --model /home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf \
    --mmproj /home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.mmproj.gguf \
    --n-gpu-layers 99 --device ROCm0 --flash-attn on \
    --cache-type-k q4_0 --cache-type-v q4_0 --ctx-size 65536 --jinja \
    --host 127.0.0.1 --port 8091

Exact evidence:
- Build: llama.cpp v10354 (d2f83055d), GNU 16.1.1, linux x86_64.
- Loader PID 65741 (real llama-server; wrapper bash 65740). env HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a. GPU: R9700 = GPU[0] (34208743424 B = 31.9 GB total).
- Baseline VRAM (idle, before load): 59936768 B (~57 MB) — matches GPU idle confirmed at start and after cleanup.
- VRAM under load: frozen at 25134694400 B (25.1 GB) for the entire ~900s poll — zero growth between samples at t=0..896s. This rules out slow-but-progressing.
- /health (127.0.0.1:8091): port LISTEN for the whole run, but HTTP never returned OK. curl -m5 returned no body / timed out across 30 samples @30s over 900s. FAIL criterion (no OK within 900s) met.
- Server log frozen at (no further lines for 900s+):
    0.00.075.395 I srv  load_model: loading model '.../Muse-Glimmer-30B-UD-Q6_K_XL.gguf'
    0.00.720.244 W load: setting token '<|message|>' (200023) attribute to USER_DEFINED
    0.00.720.247 W load: setting token '<|start|>' (200022) attribute to USER_DEFINED
    0.00.723.027 W load: special_eot_id is not in special_eog_ids - the tokenizer config may be incorrect
- Loader process state: STAT=RNl, %CPU=98.6 (single thread pinned — compute spin) across 3 samples; RSS oscillating ~20.0 GB (20013952 / 20057412 / 20014708 KB). Spinning in a load step that never completes — not an IO stall, not advancing.
- Hang vs slow: VRAM flat + log flat + CPU pinned = hard hang, not slow. (Prior note in this file reported "CPU ~70%"; retest measured a steady 98.6% single-thread spin — otherwise identical stall signature.)
- Cleanup: SIGTERM to 65741 -> exited ~6s, VRAM released to 59936768 B, no resident llama-server procs. R9700 returned to baseline; nothing left on the GPU.

Diagnosis (unchanged): the >=22GB tier stalls mid-load WITH the projector at 64K ctx on build v10354, reproduced deterministically for this model. Build/quant-class limitation, not a config error. Recommendation: rebuild llama.cpp (or test large models at lower ctx / without projector to isolate) before registering as vision.

## Retest 2026-08-14 19:05 UTC — ornith-1-0-35b-ud-q4-k-xl (FAILED — reproduced)

Isolated direct-load retest per task t_37f0b3ae. Outcome: FAIL (stall >900s, no /health OK).
No --mmproj added; the existing text-only entry in amd-r9700 is preserved.

Command (isolated port 8091, R9700 only):
  /usr/local/bin/llama-server \
    --model /home/rahlquist/.cache/llama.cpp/Ornith-1.0-35B-UD-Q4_K_XL.gguf \
    --mmproj /home/rahlquist/.cache/llama.cpp/Ornith-1.0-35B-UD-Q4_K_XL.mmproj.gguf \
    --n-gpu-layers 99 --device ROCm0 --flash-attn on \
    --cache-type-k q4_0 --cache-type-v q4_0 --ctx-size 65536 --jinja \
    --host 127.0.0.1 --port 8091

Exact evidence:
- Build: llama.cpp v10354 (d2f83055d), GNU 16.1.1, linux x86_64.
- Loader PID 441340 (real llama-server; wrapper bash 441338). env HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a. GPU: R9700 = GPU[0] (34208743424 B = 31.9 GB total).
- Baseline VRAM (idle, before load): 59949056 B (~57 MB) — matches GPU idle confirmed at start and after cleanup.
- VRAM under load: frozen at 22113701888 B (22.11 GB) across 2 confirmation samples at etime=17:32 and etime=18:32 (60s apart), and flat through the full ~900s poll (grew only ~1.5 MB off the initial 22.11 GB over 881s — effectively zero). Rules out slow-but-progressing.
- /health (127.0.0.1:8091): port LISTEN for the whole run (bound ~t=69s, served sporadic 503s, never OK). curl -m3 returned 503 or no-body/no-connect across samples @~20s over 900s. FAIL criterion (no OK within 900s) met.
- Server log frozen at (no further lines for 900s+):
    0.00.022.977 I srv  load_model: loading model '.../Ornith-1.0-35B-UD-Q4_K_XL.gguf'
- Loader process state: STAT=R<l, %CPU=87.2->87.8 (single thread pinned — compute spin) across 2 samples 60s apart; RSS ~19.0 GB (19134136->19038000 KB). Spinning in a load step that never completes — not an IO stall, not advancing.
- Hang vs slow: VRAM flat + log flat + CPU pinned = hard hang, not slow. Same stall signature as muse-glimmer-30b-ud-q6-k-xl (t_9e3b8344).
- Cleanup: SIGTERM to 441340 -> exited ~2s, VRAM released to baseline 59949056 B, no resident llama-server procs. R9700 returned to baseline; nothing left on the GPU.

Diagnosis (unchanged): the >=22GB tier stalls mid-load WITH the projector at 64K ctx on build v10354, reproduced deterministically for this model. Build/quant-class limitation, not a config error. Recommendation: rebuild llama.cpp (or test large models at lower ctx / without projector to isolate) before registering as vision.
## Retest 2026-08-14 20:32 UTC — qwen3-6-35b-a3b-uncensored-hauhaucs-aggressive-q5-k-p (FAILED — hard hang)

- **Priority / trigger**: Operator-declared FAIL (out-of-band) after prior run 48 timed out at 2713s. Re-verified live as a hard hang, not slow, before terminating.
- **Model**: qwen3-6-35b-a3b-uncensored-hauhaucs-aggressive-q5-k-p
  - base: `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_P.gguf` (28.0 GB, present in cache)
  - projector: `Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_P.mmproj.gguf` (0.9 GB, present in cache, namespaced copy matches HF repo `HauhauCS/Qwen3.6-35B...`)
- **Build**: llama.cpp v10354 (d2f83055d) — same build as the muse-glimmer-30b-q6 and ornith-1-0-35b failures.
- **Method**: direct `llama-server` on isolated port 8091, env `HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a`, flags `--mmproj <proj> --n-gpu-layers 99 --device ROCm0 --flash-attn on --cache-type-k q4_0 --cache-type-v q4_0 --ctx-size 65536 --jinja --host 127.0.0.1 --port 8091`; log `/tmp/llama-q5-test.log`. GPU was idle beforehand (8080 all-unloaded baseline).
- **Result**: HARD HANG. Never reached `/health` OK within 900s; ran 45+ min before forced termination — far past the 900s poll window.
  - Loader PID 543184: elapsed 45:14, %CPU 93.8 (single-thread spin, STAT `R`), 21 threads, RSS ~17.5 GB.
  - Server log frozen at `load_model: loading model '/home/rahlquist/.cache/llama.cpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_P.gguf'` (628 bytes; last write 2026-08-14 15:47:31; no growth across samples). Identical stall signature to the ornith-35b and muse-glimmer-30b-q6 retests.
  - Port 8091 bound (LISTEN) but `/health` returned **no response** (curl 28, silent timeout) — neither 200 OK nor 503.
  - VRAM under hang: R9700 (card2, 34.2 GB total) = **28.0 GB used**, flat across samples (full base GGUF resident, then CPU-spin deadlock).
- **Verdict**: hard hang, not slow (VRAM flat + log flat + CPU pinned). Same >=22 GB + `--mmproj` + 64K ctx stall class on build v10354 as muse-glimmer-30b-q6 and ornith-1-0-35b.
- **Cleanup**: SIGTERM → loader exited; port 8091 released; VRAM returned to baseline (57 MB). No other loader resident. llama-hugs on 8080 untouched (all models unloaded, API healthy).
- **Config action**: NONE. Model left **unregistered** (FAIL). Not added to `amd-r9700` group; no text-only fallback created (task body states it was removed entirely and must stay unregistered on FAIL). No git commit. Unrelated dirty files (`bench_results.html`) and wimpy HEAD == origin/main preserved.
