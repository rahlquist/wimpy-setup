#!/usr/bin/env bash
# 05-llama-cpp.sh — build llama.cpp (ROCm/HIP, R9700) from source + install llama-swap
#
# Hardware: AMD Radeon AI PRO R9700 (Navi 48, gfx1201, 32GB) = inference GPU
#           NVIDIA GT 710 (GK208B)  = display only, driven by nouveau (not
#           ROCm/CUDA-visible at all, so no exclusion flag is even needed)
#
# This REPLACES the llama-cpp-rocm/ggml-rocm pacman packages as the single
# source of truth for llama.cpp on this box (see CHANGELOG.md's "stop using
# pacman for llama.cpp" entry for why). If those packages are still
# installed when you run this, remove them afterward once the source build
# is verified working — do NOT run both, that recreates the exact
# competing-copies problem the 2026-07-07 ROCm migration fixed. This script
# does not remove them itself; that's a deliberate separate step.
#
# Version floats to the tip of master on every run (git pull --ff-only) —
# same behavior as the original CUDA-era version of this script. Each
# rebuild can land on a different upstream commit; llama.cpp tags builds
# very frequently (dozens per week), so re-run the GPU validation from
# CHANGELOG.md after any rebuild rather than assuming it still works.
#
# llama-swap listens on 0.0.0.0:8080 so hermesvm01 can reach it over br0.
# Verify GPU after install: /usr/local/bin/llama-server --list-devices
# (expect "ROCm0: AMD Radeon AI PRO R9700 ...")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "05 — llama.cpp (ROCm/HIP, gfx1201) + llama-swap"
require_root_or_sudo

BUILD_DIR="$HOME/src/llama.cpp"
JOBS="$(nproc)"
AMDGPU_TARGET="${AMDGPU_TARGET:-gfx1201}"  # R9700 = Navi 48 = gfx1201; override if hardware changes

# ── ROCm/HIP toolchain ───────────────────────────────────────────────────────
log "Checking ROCm/HIP toolchain"
if ! command -v hipcc &>/dev/null || [[ ! -d /opt/rocm ]]; then
    warn "hipcc / /opt/rocm not found — installing rocm-hip-sdk"
    case "$PKG_MANAGER" in
        pacman) sudo pacman -S --needed --noconfirm rocm-hip-sdk rocm-hip-runtime ;;
        *)      err "Install the ROCm HIP SDK manually: https://rocm.docs.amd.com/"; exit 1 ;;
    esac
fi
log "  hipcc: $(hipcc --version 2>/dev/null | head -1 || echo present)"

# ── GPU inventory ─────────────────────────────────────────────────────────────
log "GPU inventory (verify the R9700 shows up as a ROCm agent):"
if command -v rocminfo &>/dev/null; then
    rocminfo 2>/dev/null | grep -A1 'Marketing Name' | grep -v '^--' \
        | paste -d' ' - - | sed 's/^/  /' || true
else
    warn "rocminfo not found — GPU inventory check skipped, continuing anyway"
fi

# ── Clone / update ────────────────────────────────────────────────────────────
if [[ -d "$BUILD_DIR/.git" ]]; then
    log "Updating llama.cpp"
    git -C "$BUILD_DIR" pull --ff-only
else
    log "Cloning llama.cpp"
    mkdir -p "$(dirname "$BUILD_DIR")"
    git clone https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"
fi
log "  llama.cpp @ $(git -C "$BUILD_DIR" describe --tags --always)"

# ── Build ─────────────────────────────────────────────────────────────────────
log "Configuring cmake — ROCm/HIP, target $AMDGPU_TARGET (R9700)"
export HIPCXX="$(hipconfig -l 2>/dev/null)/clang"
export HIP_PATH="$(hipconfig -R 2>/dev/null)"
cmake -S "$BUILD_DIR" -B "$BUILD_DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_RPATH=/usr/local/lib \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="$AMDGPU_TARGET" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_SERVER_VERBOSE=OFF

log "Building with $JOBS jobs (ROCm builds are slower than CUDA — this will take a while)"
cmake --build "$BUILD_DIR/build" -j "$JOBS"

log "Installing to /usr/local"
sudo cmake --install "$BUILD_DIR/build" --prefix /usr/local

/usr/local/bin/llama-server --version 2>&1 | head -1 && log "llama-server installed OK"

# ── Verify the ROCm backend actually loaded, not just that the binary runs ───
log "Verifying ROCm device is visible to the freshly-built binary"
if /usr/local/bin/llama-server --list-devices 2>&1 | grep -q '^ *ROCm0'; then
    log "  confirmed: $(/usr/local/bin/llama-server --list-devices 2>&1 | grep '^ *ROCm0')"
else
    err "llama-server built but does NOT report a ROCm0 device — --list-devices output:"
    /usr/local/bin/llama-server --list-devices 2>&1 | sed 's/^/    /' || true
    err "Do not deploy this build. Check the cmake configure log above for GGML_HIP-related warnings."
    exit 1
fi

# ── Verify the binary links its OWN libs, not a stale copy elsewhere ──────────
# (llama-server is a thin launcher; without an RPATH it can silently resolve
# libllama/libggml from /usr/lib if a pacman build is installed — the reversed
# form of the 2026-07-07 shadowing incident.)
log "Verifying library resolution (must come from /usr/local/lib)"
BAD_LIBS=$(ldd /usr/local/bin/llama-server | grep -E 'libllama|libggml|libmtmd' | grep -v '/usr/local/lib' || true)
if [ -n "$BAD_LIBS" ]; then
    err "llama-server resolves llama/ggml libraries OUTSIDE /usr/local/lib:"
    echo "$BAD_LIBS" | sed 's/^/    /'
    err "The RPATH did not take effect — do not deploy this build."
    exit 1
fi
log "  confirmed: all libllama/libggml/libmtmd resolve from /usr/local/lib"

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

# Back up any existing config before we touch this path (CLAUDE.md hard rule #1).
# The write below is guarded by [[ ! -f ]], so this is a no-op on a fresh
# install; it becomes a real safety net if that guard is ever relaxed.
[ -f "$SWAP_CFG" ] && sudo cp "$SWAP_CFG" \
    "/etc/llama-swap/$(date +%Y%m%d%H%M%S)-config.yaml.bak"

if [[ ! -f "$SWAP_CFG" ]]; then
    log "Writing llama-swap config skeleton"
    sudo tee "$SWAP_CFG" > /dev/null <<'CFG'
# /etc/llama-swap/config.yaml — wimpy
#
# GPU layout:
#   R9700 (32GB, ROCm)  — inference
#   GT 710              — display only, driven by nouveau, not ROCm/CUDA-visible
#
# HIP_VISIBLE_DEVICES=0 + --device ROCm0 pin every model to the R9700.
# --device also makes a missing/wrong GPU a hard startup failure instead of
# a silent CPU fallback — do not drop it, see CHANGELOG.md's 2026-07-07 entry
# for exactly what happens when GPU pinning is missing.
# llama-swap listens on 0.0.0.0:8080 — reachable from hermesvm01 over br0.
#
# Verify GPU: /usr/local/bin/llama-server --list-devices

healthCheckTimeout: 120

models:
  # Uncomment and fill in your model paths.
  # Same proven flags from slug: 64K ctx, flash attn, quantized KV.

  # qwen2.5-coder-14b:
  #   ttl: 300
  #   env: ["HIP_VISIBLE_DEVICES=0"]
  #   cmd: >
  #     /usr/local/bin/llama-server
  #       --model /path/to/qwen2.5-coder-14b-instruct-q8_0.gguf
  #       --ctx-size 65536
  #       --n-gpu-layers 99
  #       --device ROCm0
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
# This tee overwrites the unit unconditionally on every run — back it up first
# (CLAUDE.md hard rule #1).
[ -f /etc/systemd/system/llama-swap.service ] && \
  sudo cp /etc/systemd/system/llama-swap.service \
          "/etc/systemd/system/$(date +%Y%m%d%H%M%S)-llama-swap.service.bak"
sudo tee /etc/systemd/system/llama-swap.service > /dev/null <<SVC
[Unit]
Description=llama-swap model router (wimpy)
After=network.target

[Service]
Type=simple
User=${SVCUSER}
ExecStart=/usr/local/bin/llama-swap --config /etc/llama-swap/config.yaml -watch-config
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
info "  llama-server : $(/usr/local/bin/llama-server --version 2>&1 | head -1)"
info "  ROCm device  : $(/usr/local/bin/llama-server --list-devices 2>&1 | grep '^ *ROCm0')"
info "  Config       : $SWAP_CFG  ← add model paths, then:"
info "  Start        : sudo systemctl enable --now llama-swap"
info "  hermesvm01 connects to : http://wimpy.home.lan:8080/v1"
info ""
info "  If llama-cpp-rocm/ggml-rocm pacman packages are still installed,"
info "  remove them once you've verified this build works — see"
info "  CHANGELOG.md. Do not leave both installed."
