#!/usr/bin/env bash
# 05-llama-cpp.sh — build llama.cpp (CUDA sm_120) + install llama-swap
#
# Hardware: RTX 5060 Ti (GB206, sm_120) = inference GPU
#           GT 710 (GK208B, sm_35)      = display only, excluded via CUDA_VISIBLE_DEVICES
#
# llama-swap listens on 0.0.0.0:8080 so hermesvm01 can reach it over br0.
# Verify GPU indices after install: nvidia-smi --query-gpu=index,name --format=csv

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "05 — llama.cpp (CUDA sm_120) + llama-swap"
require_root_or_sudo

BUILD_DIR="$HOME/src/llama.cpp"
JOBS="$(nproc)"

# ── CUDA toolkit ──────────────────────────────────────────────────────────────
log "Checking CUDA toolkit"
if ! command -v nvcc &>/dev/null; then
    warn "nvcc not found — installing cuda"
    case "$PKG_MANAGER" in
        pacman) sudo pacman -S --needed --noconfirm cuda ;;
        *)      err "Install CUDA toolkit manually from https://developer.nvidia.com/cuda-downloads"; exit 1 ;;
    esac
fi
log "  nvcc: $(nvcc --version | grep 'release' | awk '{print $6}' | tr -d ',')"

# ── GPU inventory ─────────────────────────────────────────────────────────────
log "GPU inventory (verify index 0 is the RTX 5060 Ti):"
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader 2>/dev/null \
    | while IFS=',' read -r idx name vram; do
        info "  GPU ${idx} :$(echo "$name" | xargs) —$(echo "$vram" | xargs)"
    done

# ── Clone / update ────────────────────────────────────────────────────────────
if [[ -d "$BUILD_DIR/.git" ]]; then
    log "Updating llama.cpp"
    git -C "$BUILD_DIR" pull --ff-only
else
    log "Cloning llama.cpp"
    mkdir -p "$(dirname "$BUILD_DIR")"
    git clone https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"
fi

# ── Build ─────────────────────────────────────────────────────────────────────
log "Configuring cmake — CUDA sm_120 (Blackwell / RTX 5060 Ti)"
cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_CUDA=ON \
    -DCMAKE_CUDA_ARCHITECTURES=120 \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_SERVER_VERBOSE=OFF

log "Building with $JOBS jobs"
cmake --build "$BUILD_DIR/build" -j "$JOBS"

log "Installing to /usr/local"
sudo cmake --install "$BUILD_DIR/build" --prefix /usr/local

llama-server --version 2>/dev/null | head -1 && log "llama-server installed OK"

# ── llama-swap binary ─────────────────────────────────────────────────────────
# Release asset is a tarball named: llama-swap_<ver>_linux_amd64.tar.gz
# (underscores, gzipped archive — not a bare binary). Whole block is non-fatal
# so a download/network hiccup never kills the step; build is already done.
step "Installing llama-swap"

install_llama_swap() {
    local api="https://api.github.com/repos/mostlygeek/llama-swap/releases/latest"
    local url tmp dir

    url="$(curl -fsSL "$api" 2>/dev/null \
        | grep '"browser_download_url"' \
        | grep 'linux_amd64.tar.gz' \
        | head -1 \
        | cut -d'"' -f4)" || true

    if [[ -z "$url" ]]; then
        warn "Could not auto-detect llama-swap release URL (GitHub API rate limit?)"
        warn "Install manually: https://github.com/mostlygeek/llama-swap/releases"
        return 1
    fi

    info "Downloading: $(basename "$url")"
    tmp="$(mktemp -d)"
    if ! curl -fsSL "$url" -o "${tmp}/llama-swap.tar.gz"; then
        warn "Download failed — install llama-swap manually later"
        rm -rf "$tmp"
        return 1
    fi

    tar -xzf "${tmp}/llama-swap.tar.gz" -C "$tmp"
    # The binary inside the tarball is named 'llama-swap'
    local bin
    bin="$(find "$tmp" -type f -name 'llama-swap' | head -1)"
    if [[ -z "$bin" ]]; then
        warn "llama-swap binary not found inside tarball"
        rm -rf "$tmp"
        return 1
    fi

    sudo install -m 0755 "$bin" /usr/local/bin/llama-swap
    rm -rf "$tmp"
    log "llama-swap installed: $(/usr/local/bin/llama-swap --version 2>/dev/null | head -1 || echo OK)"
}

install_llama_swap || warn "llama-swap install skipped — see message above"

# ── llama-swap config ─────────────────────────────────────────────────────────
SWAP_CFG="/etc/llama-swap/config.yaml"
sudo mkdir -p /etc/llama-swap

if [[ ! -f "$SWAP_CFG" ]]; then
    log "Writing llama-swap config skeleton"
    sudo tee "$SWAP_CFG" > /dev/null <<'CFG'
# /etc/llama-swap/config.yaml — wimpy
#
# GPU layout:
#   0 = RTX 5060 Ti (16 GB) — inference
#   1 = GT 710              — display only
#
# CUDA_VISIBLE_DEVICES=0 excludes the GT 710.
# llama-swap listens on 0.0.0.0:8080 — reachable from hermesvm01 over br0.
#
# Verify GPU indices: nvidia-smi --query-gpu=index,name --format=csv

healthCheckTimeout: 120

models:
  # Uncomment and fill in your model paths.
  # Same proven flags from slug: 64K ctx, flash attn, quantized KV.

  # qwen2.5-coder-14b:
  #   ttl: 300
  #   env:
  #     CUDA_VISIBLE_DEVICES: "0"
  #   cmd: >
  #     llama-server
  #       --model /path/to/qwen2.5-coder-14b-instruct-q8_0.gguf
  #       --ctx-size 65536
  #       --n-gpu-layers 99
  #       --flash-attn
  #       --cache-type-k q4_0
  #       --cache-type-v q4_0
  #       --parallel 1
  #       --host 0.0.0.0
  #       --port ${PORT}
  #       --jinja
  #       --metrics
CFG
    log "Config written to $SWAP_CFG — add your model paths before starting"
fi

# ── systemd service ───────────────────────────────────────────────────────────
SVCUSER="${SUDO_USER:-$USER}"
sudo tee /etc/systemd/system/llama-swap.service > /dev/null <<SVC
[Unit]
Description=llama-swap model router (wimpy)
After=network.target

[Service]
Type=simple
User=${SVCUSER}
Environment=CUDA_VISIBLE_DEVICES=0
ExecStart=/usr/local/bin/llama-swap --config /etc/llama-swap/config.yaml
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

sudo systemctl daemon-reload

# ── Open firewall port 8080 ───────────────────────────────────────────────────
step "Firewall — port 8080 (llama-swap, inbound from any)"
open_firewall_port 8080

log "05-llama-cpp complete"
info ""
info "  llama-server : $(llama-server --version 2>/dev/null | head -1)"
info "  Config       : $SWAP_CFG  ← add model paths, then:"
info "  Start        : sudo systemctl enable --now llama-swap"
info "  hermesvm01 connects to : http://wimpy.home.lan:8080/v1"
