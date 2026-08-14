# Muse Glimmer comparison — five-model benchmark

Generated from the local llama-bench SQLite database. Each metric is ordered highest to lowest.

Today’s addition: **Muse Glimmer 30B UD-Q2_K_XL on NVIDIA RTX 5060 Ti**.

## pp512

| Rank | Model | tok/s | ± stddev | Backend |
|---:|---|---:|---:|---|
| 1 | Qwen3 30B A3B Q4_K_M | 3465.67 | 35.00 | ROCm / R9700 |
| 2 | Qwen3 30B A3B Q5_K_M | 3406.70 | 46.11 | ROCm / R9700 |
| 3 | Ornith 35B UD-Q4_K_XL | 3078.83 | 13.13 | ROCm / R9700 |
| 4 | Qwen3 30B A3B UD-Q5_K_XL | 2361.57 | 21.49 | ROCm / R9700 |
| 5 | Muse Glimmer 30B UD-Q6_K_XL | 964.59 | 28.49 | ROCm / R9700 |
| 6 | Muse Glimmer 30B UD-Q2_K_XL | 858.34 | 6.53 | CUDA / RTX 5060 Ti |

## tg128

| Rank | Model | tok/s | ± stddev | Backend |
|---:|---|---:|---:|---|
| 1 | Qwen3 30B A3B Q4_K_M | 99.22 | 1.48 | ROCm / R9700 |
| 2 | Qwen3 30B A3B Q5_K_M | 98.88 | 1.20 | ROCm / R9700 |
| 3 | Qwen3 30B A3B UD-Q5_K_XL | 96.54 | 0.73 | ROCm / R9700 |
| 4 | Ornith 35B UD-Q4_K_XL | 77.60 | 1.02 | ROCm / R9700 |
| 5 | Muse Glimmer 30B UD-Q2_K_XL | 31.65 | 0.07 | CUDA / RTX 5060 Ti |
| 6 | Muse Glimmer 30B UD-Q6_K_XL | 22.17 | 0.00 | ROCm / R9700 |

## pp512@d4096

| Rank | Model | tok/s | ± stddev | Backend |
|---:|---|---:|---:|---|
| 1 | Qwen3 30B A3B Q5_K_M | 2792.32 | 93.69 | ROCm / R9700 |
| 2 | Qwen3 30B A3B UD-Q5_K_XL | 2787.71 | 73.57 | ROCm / R9700 |
| 3 | Qwen3 30B A3B Q4_K_M | 2774.31 | 163.68 | ROCm / R9700 |
| 4 | Ornith 35B UD-Q4_K_XL | 2676.15 | 24.73 | ROCm / R9700 |
| 5 | Muse Glimmer 30B UD-Q6_K_XL | 914.75 | 12.35 | ROCm / R9700 |
| 6 | Muse Glimmer 30B UD-Q2_K_XL | 823.62 | 6.71 | CUDA / RTX 5060 Ti |

## tg128@d4096

| Rank | Model | tok/s | ± stddev | Backend |
|---:|---|---:|---:|---|
| 1 | Qwen3 30B A3B UD-Q5_K_XL | 92.50 | 1.28 | ROCm / R9700 |
| 2 | Qwen3 30B A3B Q4_K_M | 92.41 | 1.18 | ROCm / R9700 |
| 3 | Qwen3 30B A3B Q5_K_M | 92.12 | 1.04 | ROCm / R9700 |
| 4 | Ornith 35B UD-Q4_K_XL | 76.70 | 1.30 | ROCm / R9700 |
| 5 | Muse Glimmer 30B UD-Q2_K_XL | 30.47 | 0.01 | CUDA / RTX 5060 Ti |
| 6 | Muse Glimmer 30B UD-Q6_K_XL | 21.96 | 0.01 | ROCm / R9700 |

## Method

- `pp512`: prompt processing
- `tg128`: token generation
- `@d4096`: 4096-token KV-cache context
- Three repetitions, maximum GPU offload, llama.cpp `llama-bench`
