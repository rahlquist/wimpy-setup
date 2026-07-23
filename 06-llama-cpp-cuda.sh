#!/usr/bin/env bash
# 06-llama-cpp-cuda.sh — build a SECOND llama.cpp (CUDA, RTX 5060 Ti) from source
#
# Hardware: NVIDIA GeForce RTX 5060 Ti (GB206, Blackwell, sm_120, 16GB) at PCI 04:00.0
#
# WHY THIS IS SEPARATE FROM 05-llama-cpp.sh:
#   05- builds the ROCm/HIP binary for the R9700 and installs it to /usr/local
#   (bin/llama-server + lib/libggml*.so). llama.cpp's HIP backend is the CUDA
#   backend hipified — both export the SAME ggml_cuda_* symbols and produce libs
#   with the SAME filenames (libggml.so.0, libggml-base.so.0, libggml-cpu.so.0).
#   You CANNOT put both backends in one binary (symbol collision; GGML_HIP and
#   GGML_CUDA are mutually exclusive), and installing a CUDA build into /usr/local
#   would OVERWRITE the ROCm libs and break the working R9700 build.
#
#   So this build lives in a fully isolated prefix: /opt/llama-cuda. Its binary
#   and libs never touch /usr/local. The two builds coexist:
#     /usr/local/bin/llama-server        -> R9700  (ROCm0), built by 05-
#     /opt/llama-cuda/bin/llama-server   -> 5060 Ti (CUDA0), built by this script
#
#   This does NOT install llama-swap, a config, or a systemd unit — 05- already
#   did that and there is ONE llama-swap for both GPUs. To use the 5060 Ti, add
#   model entries to llama-swap-config.yaml whose cmd points at
#   /opt/llama-cuda/bin/llama-server with env: ["CUDA_VISIBLE_DEVICES=0"], in a
#   different llama-swap group from the R9700 models so both can stay resident.
#
# Version floats to the tip of master (shares the ~/src/llama.cpp checkout with
# 05-; git pull --ff-only). Re-run the GPU validation after any rebuild.
# Verify GPU after install: /opt/llama-cuda/bin/llama-server --list-devices
# (expect "CUDA0: NVIDIA GeForce RTX 5060 Ti ...")

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "06 — llama.cpp (CUDA, sm_120, RTX 5060 Ti) — isolated build"
require_root_or_sudo

BUILD_DIR="$HOME/src/llama.cpp"          # shared checkout with 05-
BUILD_SUBDIR="$BUILD_DIR/build-cuda"     # separate build tree; never 05-'s build/
PREFIX="/opt/llama-cuda"                 # isolated install prefix; NOT /usr/local
JOBS="$(nproc)"
CUDA_ARCH="${CUDA_ARCH:-120}"            # RTX 5060 Ti = Blackwell = sm_120
CUDA_ROOT="${CUDA_ROOT:-/opt/cuda}"
# Optional: some CUDA/nvcc versions reject a too-new host GCC. If the configure
# or build fails complaining about the host compiler, re-run with e.g.
#   CUDA_HOST_COMPILER=/usr/bin/gcc-14 bash 06-llama-cpp-cuda.sh
CUDA_HOST_COMPILER="${CUDA_HOST_COMPILER:-}"

# ── CUDA toolchain ────────────────────────────────────────────────────────────
log "Checking CUDA toolchain"
NVCC="${CUDA_ROOT}/bin/nvcc"
if [[ ! -x "$NVCC" ]]; then
    if command -v nvcc &>/dev/null; then
        NVCC="$(command -v nvcc)"
    else
        err "nvcc not found at ${CUDA_ROOT}/bin/nvcc or on PATH."
        err "Install the CUDA toolkit (pacman: 'cuda') or set CUDA_ROOT=/path/to/cuda."
        exit 1
    fi
fi
log "  nvcc: $("$NVCC" --version 2>/dev/null | grep -i release | sed 's/^ *//' || echo present)"

# ── GPU inventory (verify the 5060 Ti is present to the driver) ───────────────
log "GPU inventory (verify the RTX 5060 Ti shows up to the NVIDIA driver):"
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader \
        | sed 's/^/  /' || true
else
    err "nvidia-smi not found — the NVIDIA driver is not installed/loaded."
    err "This build needs a working NVIDIA driver at runtime. Aborting."
    exit 1
fi

# ── Clone / update (shared checkout with 05-) ─────────────────────────────────
if [[ -d "$BUILD_DIR/.git" ]]; then
    log "Updating llama.cpp (shared with 05-)"
    git -C "$BUILD_DIR" pull --ff-only
else
    log "Cloning llama.cpp"
    mkdir -p "$(dirname "$BUILD_DIR")"
    git clone https://github.com/ggml-org/llama.cpp.git "$BUILD_DIR"
fi
log "  llama.cpp @ $(git -C "$BUILD_DIR" describe --tags --always)"

# ── Configure ─────────────────────────────────────────────────────────────────
log "Configuring cmake — CUDA, sm_${CUDA_ARCH}, install prefix ${PREFIX}"
CMAKE_ARGS=(
    -S "$BUILD_DIR" -B "$BUILD_SUBDIR"
    -DCMAKE_BUILD_TYPE=Release
    -DCMAKE_INSTALL_PREFIX="$PREFIX"
    -DCMAKE_INSTALL_RPATH="${PREFIX}/lib"   # so this binary loads ITS OWN libggml
    -DGGML_CUDA=ON
    -DCMAKE_CUDA_ARCHITECTURES="$CUDA_ARCH"
    -DCMAKE_CUDA_COMPILER="$NVCC"
    -DLLAMA_BUILD_TESTS=OFF
    -DLLAMA_BUILD_EXAMPLES=ON
    -DLLAMA_SERVER_VERBOSE=OFF
)
if [[ -n "$CUDA_HOST_COMPILER" ]]; then
    log "  using CUDA host compiler override: $CUDA_HOST_COMPILER"
    CMAKE_ARGS+=( -DCMAKE_CUDA_HOST_COMPILER="$CUDA_HOST_COMPILER" )
fi
cmake "${CMAKE_ARGS[@]}"

log "Building with $JOBS jobs (CUDA compile of the ggml kernels — takes a while)"
cmake --build "$BUILD_SUBDIR" -j "$JOBS"

# ── Install to the ISOLATED prefix ────────────────────────────────────────────
log "Installing to ${PREFIX} (does NOT touch /usr/local — the ROCm build)"
sudo cmake --install "$BUILD_SUBDIR" --prefix "$PREFIX"

CUDA_BIN="${PREFIX}/bin/llama-server"
"$CUDA_BIN" --version 2>&1 | head -1 && log "llama-server (CUDA) installed OK"

# ── Verify the CUDA backend actually loaded, not just that the binary runs ────
log "Verifying CUDA device is visible to the freshly-built binary"
if "$CUDA_BIN" --list-devices 2>&1 | grep -q '^ *CUDA0'; then
    log "  confirmed: $("$CUDA_BIN" --list-devices 2>&1 | grep '^ *CUDA0')"
else
    err "llama-server built but does NOT report a CUDA0 device — --list-devices output:"
    "$CUDA_BIN" --list-devices 2>&1 | sed 's/^/    /' || true
    err "Do not use this build. Check the cmake configure log above for GGML_CUDA warnings."
    exit 1
fi

# ── Verify this binary links ITS OWN libs, not the ROCm build's /usr/local ────
# Critical: if the CUDA binary resolved libggml from /usr/local/lib it would be
# loading the ROCm libraries — same filenames, wrong backend. The RPATH above
# must win. All libggml/libllama/libmtmd MUST come from ${PREFIX}/lib.
log "Verifying library resolution (must come from ${PREFIX}/lib, NOT /usr/local/lib)"
BAD_LIBS=$(ldd "$CUDA_BIN" | grep -E 'libllama|libggml|libmtmd' | grep -v "${PREFIX}/lib" || true)
if [ -n "$BAD_LIBS" ]; then
    err "CUDA llama-server resolves llama/ggml libraries OUTSIDE ${PREFIX}/lib:"
    echo "$BAD_LIBS" | sed 's/^/    /'
    err "The RPATH did not take effect — this would load the ROCm libs. Do not use this build."
    exit 1
fi
log "  confirmed: all libllama/libggml/libmtmd resolve from ${PREFIX}/lib"

# ── Regression check: the ROCm build must still be intact ─────────────────────
log "Regression check — the R9700 ROCm build (/usr/local) must be untouched"
if [[ -x /usr/local/bin/llama-server ]]; then
    if /usr/local/bin/llama-server --list-devices 2>&1 | grep -q '^ *ROCm0'; then
        log "  confirmed: ROCm build still reports $(/usr/local/bin/llama-server --list-devices 2>&1 | grep '^ *ROCm0')"
    else
        err "The ROCm build at /usr/local no longer reports ROCm0 — something clobbered it."
        err "Investigate before deploying. The two builds must not share libraries."
        exit 1
    fi
else
    warn "/usr/local/bin/llama-server not found — run 05-llama-cpp.sh first (ROCm build)."
fi

log "06-llama-cpp-cuda complete"
info ""
info "  CUDA llama-server : $("$CUDA_BIN" --version 2>&1 | head -1)"
info "  CUDA device       : $("$CUDA_BIN" --list-devices 2>&1 | grep '^ *CUDA0')"
info "  Binary            : ${CUDA_BIN}"
info ""
info "  This build is NOT wired into llama-swap yet. To use the 5060 Ti, add"
info "  model entries to llama-swap-config.yaml with:"
info "    cmd: ${CUDA_BIN} ... --device CUDA0 ..."
info "    env: [\"CUDA_VISIBLE_DEVICES=0\"]"
info "  Put them in a different llama-swap group from the R9700 models so both"
info "  GPUs can stay resident and serve concurrently. Then deploy the config"
info "  (cp to /etc/llama-swap/config.yaml; -watch-config reloads, no restart)."
