#!/bin/bash
# download-models.sh
# Downloads GGUF models for the llama.cpp + llama-swap stack (wimpy).
# Continues past failures; prints a failure summary at the end.
#
# Repo names/filenames VERIFIED against huggingface.co (June 2026).
# Prereq: huggingface_hub installed.
#   pip install huggingface_hub --break-system-packages

set -uo pipefail

CACHE_DIR="${LLAMA_CACHE:-${HF_HUB_CACHE:-$HOME/.cache/llama.cpp}}"
mkdir -p "$CACHE_DIR"

if command -v huggingface-cli >/dev/null 2>&1; then
    HF="huggingface-cli"
elif command -v hf >/dev/null 2>&1; then
    HF="hf"
elif [[ -x "$HOME/.local/bin/hf" ]]; then
    HF="$HOME/.local/bin/hf"
else
    echo "ERROR: huggingface-cli / hf not found."
    echo "Install:  pip install huggingface_hub --break-system-packages"
    exit 1
fi

echo "Downloading models to: $CACHE_DIR"
echo "Using: $HF"
echo ""

FAILED=()

# dl <repo> <file>  — single-file GGUF download
dl() {
    local repo="$1" file="$2"
    echo "==> $repo : $file"
    if "$HF" download "$repo" "$file" --local-dir "$CACHE_DIR"; then
        echo "    ok"
    else
        echo "    FAILED"
        FAILED+=("$repo : $file")
    fi
    echo ""
}

# dl_split <repo> <quant-folder>  — for models split into a folder of parts
# (e.g. gemma-4-12B-it-Q8_0/ contains multiple .gguf shards)
dl_split() {
    local repo="$1" folder="$2"
    echo "==> $repo : $folder/* (split)"
    if "$HF" download "$repo" --include "${folder}/*" --local-dir "$CACHE_DIR"; then
        echo "    ok"
    else
        echo "    FAILED"
        FAILED+=("$repo : ${folder}/* (split)")
    fi
    echo ""
}

# ─────────────────────────────────────────────────────────────────────────────
# CORRECTED entries are marked  # FIXED  with the original noted.
# ─────────────────────────────────────────────────────────────────────────────

# --- Ling-mini-2.0 (three quants) ---  [worked previously]
dl "bartowski/inclusionAI_Ling-mini-2.0-GGUF" "inclusionAI_Ling-mini-2.0-Q4_K_M.gguf"
dl "bartowski/inclusionAI_Ling-mini-2.0-GGUF" "inclusionAI_Ling-mini-2.0-Q5_K_M.gguf"
dl "bartowski/inclusionAI_Ling-mini-2.0-GGUF" "inclusionAI_Ling-mini-2.0-Q6_K.gguf"

# --- IBM Granite 4.1 ---  # FIXED: repo is bartowski/ibm-granite_..., file drops "instruct"
# OLD: ibm-granite/granite-4.1-8b-GGUF : granite-4.1-8b-instruct-Q4_K_M.gguf
dl "bartowski/ibm-granite_granite-4.1-8b-GGUF" "ibm-granite_granite-4.1-8b-Q4_K_M.gguf"
dl "bartowski/ibm-granite_granite-4.1-3b-GGUF" "ibm-granite_granite-4.1-3b-Q4_K_M.gguf"

# --- Gemma 4 26B A4B (MoE) ---  # FIXED: bartowski uses google_ prefix for big sizes
# OLD: bartowski/google_gemma-4-26B-A4B-it-GGUF (was actually correct prefix-wise;
#      keeping google_ which is correct for 26B/31B per verified 31B repo)
dl "bartowski/google_gemma-4-26B-A4B-it-GGUF" "google_gemma-4-26B-A4B-it-Q4_K_M.gguf"

# --- Llama 3.2 3B ---  # FIXED: repo is bartowski/, not ggml-org/
# OLD: ggml-org/Llama-3.2-3B-Instruct-GGUF
dl "bartowski/Llama-3.2-3B-Instruct-GGUF" "Llama-3.2-3B-Instruct-Q4_K_M.gguf"

# --- Llama 2 7B Chat ---  [worked previously]
dl "TheBloke/Llama-2-7B-Chat-GGUF" "llama-2-7b-chat.Q4_K_M.gguf"

# --- Mistral 7B v0.3 ---  [worked previously]
dl "bartowski/Mistral-7B-Instruct-v0.3-GGUF" "Mistral-7B-Instruct-v0.3-Q4_K_M.gguf"

# --- Qwen3 30B-A3B (MoE) ---  [worked previously]
dl "ggml-org/Qwen3-30B-A3B-GGUF" "Qwen3-30B-A3B-Q4_K_M.gguf"

# --- Gemma 4 12B ---  # FIXED: repo is bartowski/gemma-4-12B-it-GGUF (NO google_ for 12B)
# OLD: bartowski/google_gemma-4-12B-it-GGUF
# NOTE: Q8_0 is split into a folder, so it uses dl_split.
dl       "bartowski/gemma-4-12B-it-GGUF" "gemma-4-12B-it-Q4_K_M.gguf"
dl_split "bartowski/gemma-4-12B-it-GGUF" "gemma-4-12B-it-Q8_0"

# --- Gemma 3 12B ---  [worked previously]
dl "bartowski/google_gemma-3-12b-it-GGUF" "google_gemma-3-12b-it-Q8_0.gguf"

# --- DeepSeek R1 14B ---  [worked previously]
dl "bartowski/DeepSeek-R1-Distill-Qwen-14B-GGUF" "DeepSeek-R1-Distill-Qwen-14B-Q4_K_M.gguf"

# --- Phi-4 14B ---  SWITCHED to Q4_K_M: Q8_0 (~15GB) OOMs at 64K on 16GB.
# Q4_K_M (~8.5GB) loads cleanly with 3.3GB VRAM headroom at 64K.
dl "bartowski/phi-4-GGUF" "phi-4-Q4_K_M.gguf"

# --- Qwen3.5 9B Claude Reasoning Distilled ---  # FIXED: short filename pattern
# Jackrong repos name files like "Qwen3.5-9B.Q4_K_M.gguf" (dot sep, short name).
# Three quants pulled for A/B testing — reasoning models reward higher precision.
# At 9B all three fit at 64K on 16GB; compare quality vs speed yourself.
dl "Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-GGUF" "Qwen3.5-9B.Q4_K_M.gguf"
dl "Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-GGUF" "Qwen3.5-9B.Q6_K.gguf"
dl "Jackrong/Qwen3.5-9B-Claude-4.6-Opus-Reasoning-Distilled-GGUF" "Qwen3.5-9B.Q8_0.gguf"

# --- Qwen2.5 Coder 14B ---  [worked previously]
dl "bartowski/Qwen2.5-Coder-14B-Instruct-GGUF" "Qwen2.5-Coder-14B-Instruct-Q4_K_M.gguf"

# ── BONUS (commented) ────────────────────────────────────────────────────────
# Qwen3.5-27B Claude-Opus distill — benchmarks show it's the ONE distill with
# STABLE tool-calling (native "developer" role, no Jinja patches), tested well
# in Claude Code / OpenCode. Strong Hermes candidate, but 27B → MoE offload.
#   dl "Jackrong/Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-GGUF" \
#      "Qwen3.5-27B-Claude-4.6-Opus-Reasoning-Distilled-Q4_K_M.gguf"

# ── Summary ──────────────────────────────────────────────────────────────────
echo "════════════════════════════════════════════════════════════"
if [[ ${#FAILED[@]} -eq 0 ]]; then
    echo "=== All downloads complete ==="
else
    echo "=== Completed with ${#FAILED[@]} failure(s) ==="
    echo ""
    echo "Did NOT download (verify on huggingface.co):"
    for f in "${FAILED[@]}"; do echo "  ✖ $f"; done
    echo ""
    echo "Find correct filenames in a repo with:"
    echo "  $HF download <repo> --include '*.gguf' --dry-run"
fi
echo ""
echo "Models stored in: $CACHE_DIR"
echo "════════════════════════════════════════════════════════════"
