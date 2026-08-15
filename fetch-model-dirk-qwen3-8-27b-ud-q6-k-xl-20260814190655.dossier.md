# fetch-model.sh recovery dossier — 20260814190655

## What it was doing
STAGE: smoke
SRC_CLASS: hf   SPEC: hf download hf://peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF/Dirk-Qwen3.8-27B-UD-Q6_K_XL.gguf

## Stuck at
smoke test failed; model was not registered

## Environment
- llama-server : /usr/local/bin/llama-server
- gpu device   : ROCm0 (pin HIP_VISIBLE_DEVICES=GPU-61fe9ba05af1939a)
- models dir   : /home/rahlquist/.cache/llama.cpp
- model path   : /home/rahlquist/.cache/llama.cpp/Dirk-Qwen3.8-27B-UD-Q6_K_XL.gguf
- config       : /home/rahlquist/wimpy-setup/llama-swap-config.yaml
- config backup: <none / already cleaned>
- local src    : <n/a>
- complete run output: /home/rahlquist/wimpy-setup/fetch-model-20260814190334.run.log

## Partial state / what already succeeded
- acquired model file present: yes
- config rolled back: no

## Smoke test log
- log: /tmp/fetch-model.smoke.w2XoXt.log

```
0.00.019.962 I cmn  common_param: common_params_print_info: verbosity = 3 (adjust with the `-lv N` CLI arg)
0.00.021.481 W srv  llama_server: -----------------
0.00.021.482 W srv  llama_server: CORS is set to allow all origins ('*') and no API key is set
0.00.021.482 W srv  llama_server: this can be a security risk (cross-origin attacks)
0.00.021.482 W srv  llama_server: more info: https://github.com/ggml-org/llama.cpp/pull/25655
0.00.021.482 W srv  llama_server: -----------------
0.00.022.674 I srv    load_model: loading model '/home/rahlquist/.cache/llama.cpp/Dirk-Qwen3.8-27B-UD-Q6_K_XL.gguf'
0.00.488.891 W model has unused tensor blk.64.attn_norm.weight (size = 20480 bytes) -- ignoring
0.00.488.896 W model has unused tensor blk.64.post_attention_norm.weight (size = 20480 bytes) -- ignoring
0.00.488.900 W model has unused tensor blk.64.attn_q.weight (size = 66846720 bytes) -- ignoring
0.00.488.902 W model has unused tensor blk.64.attn_k.weight (size = 5570560 bytes) -- ignoring
0.00.488.903 W model has unused tensor blk.64.attn_v.weight (size = 5570560 bytes) -- ignoring
0.00.488.909 W model has unused tensor blk.64.attn_output.weight (size = 33423360 bytes) -- ignoring
0.00.488.910 W model has unused tensor blk.64.attn_q_norm.weight (size = 1024 bytes) -- ignoring
0.00.488.912 W model has unused tensor blk.64.attn_k_norm.weight (size = 1024 bytes) -- ignoring
0.00.488.913 W model has unused tensor blk.64.ffn_gate.weight (size = 73113600 bytes) -- ignoring
0.00.488.915 W model has unused tensor blk.64.ffn_down.weight (size = 94699520 bytes) -- ignoring
0.00.488.916 W model has unused tensor blk.64.ffn_up.weight (size = 73113600 bytes) -- ignoring
0.00.488.919 W model has unused tensor blk.64.nextn.eh_proj.weight (size = 55705600 bytes) -- ignoring
0.00.488.921 W model has unused tensor blk.64.nextn.enorm.weight (size = 20480 bytes) -- ignoring
0.00.488.922 W model has unused tensor blk.64.nextn.hnorm.weight (size = 20480 bytes) -- ignoring
0.00.488.927 W model has unused tensor blk.64.nextn.shared_head_norm.weight (size = 20480 bytes) -- ignoring
```

## GPU support summary
not evaluated

## Resume command
  cd "/home/rahlquist/wimpy-setup" && ./fetch-model.sh hf\ download\ hf://peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF/Dirk-Qwen3.8-27B-UD-Q6_K_XL.gguf

## Prompt to paste to Hermes
```
fetch-model.sh got stuck at stage 'smoke' while handling 'hf download hf://peculiar-ragdoll/Dirk-Qwen3.8-27B-GGUF/Dirk-Qwen3.8-27B-UD-Q6_K_XL.gguf'.
Reason: smoke test failed; model was not registered
Model file present: yes. Config rolled back: no.
Config backup (if any): none. Complete output is in /home/rahlquist/wimpy-setup/fetch-model-20260814190334.run.log. Read that file and help me recover while preserving the evidence.
```
