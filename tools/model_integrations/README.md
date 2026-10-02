# Model-specific llama integrations

A model-specific exception belongs in this registry, not as an ad hoc edit to the fetch script. The integration launcher is placed in each model's `cmd`, so the selected adapter runs whenever that model is started.

## Add an integration

1. Add a module in this directory implementing the `ModelIntegration` contract in `base.py`:
   - `id`: stable integration identifier.
   - `match_score(repository, filename, architecture)`: return `None` for no match; prefer exact repository/file matches for model-specific behavior and exact architecture matches for architecture behavior. Never fuzzy-match identifiers.
   - `server_for_backend(backend)`: return a custom executable only when required.
   - `build_command(base_argv, backend)`: preserve the normal command by default; apply only the model-specific binary, flags, cache settings, or container invocation.
   - `estimate_kv_cache_bytes(...)`: implement a specialized fit estimate when the model's cache layout differs.
2. Register the adapter in `registry.py`. Ambiguous highest-specificity matches fail closed.
3. Add regression tests for selection, backend routing, command output, and any sizing/metadata behavior.
4. Keep `fetch_supported=False` for adapters requiring a dedicated model store or preparation workflow; the fetch pipeline then refuses instead of smoke-testing the wrong file.

`fetch-model.sh` resolves adapters by repository/file before download and by GGUF architecture after inspection. It uses the adapter for smoke tests, generated launch commands, and CUDA variants. Directly configured models invoke `launcher.py --integration <id> --backend <device> -- <base-command>`; the launcher `exec`s the adapter's command so the supervisor still owns the real server process.

## Registered integrations

- `gemma4-kv-array`: Gemma 4 metadata may provide one KV-head count per block. The fit estimator sums the per-layer values; the launcher preserves explicit cache-type settings and fills q4_0 defaults only when absent.
- `ternary-bonsai-prism`: exact `prism-ml/Ternary-Bonsai-2-27B-gguf` + `Ternary-Bonsai-2-27B-PQ2_0.gguf` match; selects the installed Prism binary for ROCm0 or CUDA0.
- `qwen38-ktopt-docker`: exact `wiklif/Qwen3.8-27B-KTopt-GGUF` + `Qwen3.8-27B-KTopt.gguf` match; invokes the existing dedicated CUDA Docker runtime and refuses generic fetch because it uses `~/kt-models`.
