# fetch-model.sh recovery dossier — 20260810092735

## What it was doing
STAGE: smoke
SRC_CLASS: hf   SPEC: hf download hf://unsloth/Muse-Glimmer-30B-GGUF/Muse-Glimmer-30B-UD-Q6_K_XL.gguf

## Stuck at
smoke test failed; model was not registered

## Environment
- llama-server : /usr/local/bin/llama-server
- gpu device   : ROCm0 (pin HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a)
- models dir   : /home/rahlquist/.cache/llama.cpp
- model path   : /home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf
- config       : /home/rahlquist/wimpy-setup/llama-swap-config.yaml
- config backup: <none / already cleaned>
- local src    : <n/a>

## Partial state / what already succeeded
- acquired model file present: yes
- config rolled back: no

## Smoke test log
- log: /tmp/fetch-model.smoke.JM6wY7.log

```
0.00.054.799 I cmn  common_param: common_params_print_info: verbosity = 3 (adjust with the `-lv N` CLI arg)
0.00.055.150 W srv  llama_server: -----------------
0.00.055.151 W srv  llama_server: CORS is set to allow all origins ('*') and no API key is set
0.00.055.151 W srv  llama_server: this can be a security risk (cross-origin attacks)
0.00.055.151 W srv  llama_server: more info: https://github.com/ggml-org/llama.cpp/pull/25655
0.00.055.151 W srv  llama_server: -----------------
0.00.056.475 I srv    load_model: loading model '/home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf'
0.00.140.396 E llama_model_load: error loading model: unknown model architecture: 'muse-glimmer'
0.00.140.400 E llama_model_load_from_file_impl: failed to load model
0.00.140.428 E common_fit_params: encountered an error while trying to fit params to free device memory: failed to load model
0.00.206.625 E llama_model_load: error loading model: unknown model architecture: 'muse-glimmer'
0.00.206.628 E llama_model_load_from_file_impl: failed to load model
0.00.206.633 E cmn  common_init_: failed to load model '/home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf'
0.00.206.636 E srv    load_model: failed to load model, '/home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf'
0.00.206.638 I srv    operator(): operator(): cleaning up before exit...
0.00.207.246 E srv  llama_server: exiting due to model loading error
```

## Resume command
  cd "/home/rahlquist/wimpy-setup" && ./fetch-model.sh hf\ download\ hf://unsloth/Muse-Glimmer-30B-GGUF/Muse-Glimmer-30B-UD-Q6_K_XL.gguf -y

## Prompt to paste to Hermes
```
fetch-model.sh got stuck at stage 'smoke' while handling 'hf download hf://unsloth/Muse-Glimmer-30B-GGUF/Muse-Glimmer-30B-UD-Q6_K_XL.gguf'.
Reason: smoke test failed; model was not registered
Model file present: yes. Config rolled back: no.
Config backup (if any): none. Help me recover — likely need to (re)run from the resume command above or fix the root cause, then re-run.
```
