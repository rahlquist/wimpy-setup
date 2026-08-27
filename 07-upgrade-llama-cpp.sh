#!/usr/bin/env bash
# 07-upgrade-llama-cpp.sh — update and rebuild both llama.cpp backends
#
# This script intentionally does ONLY the two llama.cpp builds/installations:
#   ROCm/HIP -> /usr/local
#   CUDA     -> /opt/llama-cuda
#
# It does NOT install, update, restart, or configure llama-hugs. The shared
# llama.cpp checkout is pulled once, then both isolated build trees are rebuilt
# from that same commit. Run this script as the normal user, not via sudo bash;
# sudo resets HOME and can make the source checkout resolve to /root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/common.sh"

detect_os

if [[ "$EUID" -eq 0 ]]; then
    err "Run this script as the normal user, not with sudo bash."
    exit 1
fi

step "07 — update llama.cpp (ROCm, then CUDA) — llama-hugs untouched"

BUILD_DIR="${HOME}/src/llama.cpp"
ROCM_BUILD_DIR="${BUILD_DIR}/build"
CUDA_BUILD_DIR="${BUILD_DIR}/build-cuda"
ROCM_PREFIX="/usr/local"
CUDA_PREFIX="/opt/llama-cuda"
JOBS="$(nproc)"
AMDGPU_TARGET="${AMDGPU_TARGET:-gfx1201}"
CUDA_ARCH="${CUDA_ARCH:-120}"
CUDA_ROOT="${CUDA_ROOT:-/opt/cuda}"
CUDA_HOST_COMPILER="${CUDA_HOST_COMPILER:-}"

# ── Check toolchains before changing the checkout ─────────────────────────────
log "Checking ROCm/HIP toolchain"
if ! command -v hipcc &>/dev/null || [[ ! -d /opt/rocm ]]; then
    err "hipcc / /opt/rocm not found. Install the ROCm HIP SDK first."
    exit 1
fi

NVCC="${CUDA_ROOT}/bin/nvcc"
if [[ ! -x "$NVCC" ]]; then
    NVCC="$(command -v nvcc 2>/dev/null || true)"
fi
if [[ -z "$NVCC" || ! -x "$NVCC" ]]; then
    err "nvcc not found at ${CUDA_ROOT}/bin/nvcc or on PATH."
    exit 1
fi
if ! command -v nvidia-smi &>/dev/null; then
    err "nvidia-smi not found. A working NVIDIA driver is required."
    exit 1
fi

# ── Update the shared source exactly once ─────────────────────────────────────
if [[ -d "$BUILD_DIR/.git" ]]; then
    log "Updating shared llama.cpp checkout"
    git -C "$BUILD_DIR" pull --ff-only
else
    log "Cloning llama.cpp"
    mkdir -p "$(dirname "$BUILD_DIR")"
    git clone https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"
fi

SOURCE_COMMIT="$(git -C "$BUILD_DIR" rev-parse --short HEAD)"
log "Using llama.cpp commit ${SOURCE_COMMIT} for both backends"

# ── ROCm/HIP build ────────────────────────────────────────────────────────────
step "Building ROCm/HIP (${AMDGPU_TARGET})"
export HIPCXX="$(hipconfig -l 2>/dev/null)/clang"
export HIP_PATH="$(hipconfig -R 2>/dev/null)"

cmake -S "$BUILD_DIR" -B "$ROCM_BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$ROCM_PREFIX" \
    -DCMAKE_INSTALL_RPATH="${ROCM_PREFIX}/lib" \
    -DGGML_HIP=ON \
    -DAMDGPU_TARGETS="$AMDGPU_TARGET" \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_EXAMPLES=ON \
    -DLLAMA_SERVER_VERBOSE=OFF
cmake --build "$ROCM_BUILD_DIR" -j "$JOBS"

ROCM_BIN="${ROCM_BUILD_DIR}/bin/llama-server"
if [[ ! -x "$ROCM_BIN" ]]; then
    err "ROCm build did not produce ${ROCM_BIN}"
    exit 1
fi
if ! "$ROCM_BIN" --list-devices 2>&1 | grep -q '^ *ROCm0'; then
    err "Fresh ROCm build does not report ROCm0; refusing to install it."
    "$ROCM_BIN" --list-devices 2>&1 || true
    exit 1
fi
# Before installation, CMake's build-tree RPATH correctly points at build/bin.
# The installed binary is checked against the final prefix below.
if ! readelf -d "$ROCM_BIN" 2>/dev/null | grep -q "RPATH.*${ROCM_BUILD_DIR}/bin\|RUNPATH.*${ROCM_BUILD_DIR}/bin"; then
    warn "ROCm build has no build-tree RPATH; continuing because installed RPATH is checked after install."
fi
log "ROCm build verified: $("$ROCM_BIN" --list-devices 2>&1 | grep '^ *ROCm0')"

# ── CUDA build ────────────────────────────────────────────────────────────────
step "Building CUDA (sm_${CUDA_ARCH})"
CMAKE_ARGS=(
    -S "$BUILD_DIR" -B "$CUDA_BUILD_DIR"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$CUDA_PREFIX"
    -DCMAKE_INSTALL_RPATH="${CUDA_PREFIX}/lib"
    -DGGML_CUDA=ON
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    -DCMAKE_CUDA_COMPILER="$NVCC"
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=ON
    -DLLAMA_SERVER_VERBOSE=OFF
)
if [[ -n "$CUDA_HOST_COMPILER" ]]; then
    CMAKE_ARGS+=( -DCMAKE_CUDA_HOST_COMPILER="$CUDA_HOST_COMPILER" )
fi
cmake "${CMAKE_ARGS[@]}"
cmake --build "$CUDA_BUILD_DIR" -j "$JOBS"

CUDA_BIN="${CUDA_BUILD_DIR}/bin/llama-server"
if [[ ! -x "$CUDA_BIN" ]]; then
    err "CUDA build did not produce ${CUDA_BIN}"
    exit 1
fi
if ! "$CUDA_BIN" --list-devices 2>&1 | grep -q '^ *CUDA0'; then
    err "Fresh CUDA build does not report CUDA0; refusing to install it."
    "$CUDA_BIN" --list-devices 2>&1 || true
    exit 1
fi
# As with ROCm, the uninstalled binary resolves shared libraries from its
# build/bin directory. The installed binary is checked against ${CUDA_PREFIX}
# after installation.
if ! readelf -d "$CUDA_BIN" 2>/dev/null | grep -q "RPATH.*${CUDA_BUILD_DIR}/bin\|RUNPATH.*${CUDA_BUILD_DIR}/bin"; then
    warn "CUDA build has no build-tree RPATH; continuing because installed RPATH is checked after install."
fi
log "CUDA build verified: $("$CUDA_BIN" --list-devices 2>&1 | grep '^ *CUDA0')"

# ── Install only the two llama.cpp prefixes ───────────────────────────────────
if ! confirm "Install both verified builds? This changes only ${ROCM_PREFIX} and ${CUDA_PREFIX}; llama-hugs will not be touched."; then
    warn "Install cancelled; build artifacts remain in ${BUILD_DIR}."
    exit 0
fi
require_root_or_sudo

log "Installing ROCm llama.cpp to ${ROCM_PREFIX}"
sudo cmake --install "$ROCM_BUILD_DIR" --prefix "$ROCM_PREFIX"

log "Installing CUDA llama.cpp to ${CUDA_PREFIX}"
sudo cmake --install "$CUDA_BUILD_DIR" --prefix "$CUDA_PREFIX"

# ── Post-install regression checks ────────────────────────────────────────────
if ! "$ROCM_PREFIX/bin/llama-server" --list-devices 2>&1 | grep -q '^ *ROCm0'; then
    err "Installed ROCm binary no longer reports ROCm0."
    exit 1
fi
if ! "$CUDA_PREFIX/bin/llama-server" --list-devices 2>&1 | grep -q '^ *CUDA0'; then
    err "Installed CUDA binary no longer reports CUDA0."
    exit 1
fi
ROCM_INSTALLED_BAD_LIBS="$(ldd "$ROCM_PREFIX/bin/llama-server" | grep -E 'libllama|libggml|libmtmd' | grep -v "${ROCM_PREFIX}/lib" || true)"
if [[ -n "$ROCM_INSTALLED_BAD_LIBS" ]]; then
    err "Installed ROCm binary resolves llama/ggml libraries outside ${ROCM_PREFIX}/lib."
    printf '%s\n' "$ROCM_INSTALLED_BAD_LIBS"
    exit 1
fi
CUDA_INSTALLED_BAD_LIBS="$(ldd "$CUDA_PREFIX/bin/llama-server" | grep -E 'libllama|libggml|libmtmd' | grep -v "${CUDA_PREFIX}/lib" || true)"
if [[ -n "$CUDA_INSTALLED_BAD_LIBS" ]]; then
    err "Installed CUDA binary resolves llama/ggml libraries outside ${CUDA_PREFIX}/lib."
    printf '%s\n' "$CUDA_INSTALLED_BAD_LIBS"
    exit 1
fi

log "Both llama.cpp backends upgraded from commit ${SOURCE_COMMIT}."
info "ROCm: ${ROCM_PREFIX}/bin/llama-server"
info "CUDA: ${CUDA_PREFIX}/bin/llama-server"
info "llama-hugs was not installed, configured, restarted, or otherwise touched."
info "Source checkout: ${BUILD_DIR}"
chmod +x "$0" 2>/dev/null || true
log "07-upgrade-llama-cpp complete"

# Deliberately no llama-hugs commands, config writes, service operations, or
# firewall changes in this script.
