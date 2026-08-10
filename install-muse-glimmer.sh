#!/usr/bin/env bash
# Install the freshly built llama.cpp backends and deploy Muse-Glimmer to llama-swap.
# Run from wimpy as the normal user: sudo bash ./install-muse-glimmer.sh
set -euo pipefail

REPO_DIR="/home/rahlquist/wimpy-setup"
SRC_DIR="/home/rahlquist/src/llama.cpp"
ROCM_BUILD="$SRC_DIR/build"
CUDA_BUILD="$SRC_DIR/build-cuda"
ROCM_PREFIX="/usr/local"
CUDA_PREFIX="/opt/llama-cuda"
MODEL_CONFIG="$REPO_DIR/llama-swap-config.yaml"
LIVE_CONFIG="/etc/llama-swap/config.yaml"
MODEL_ID="muse-glimmer-30b-ud-q6-k-xl"

log() { printf '[..] %s\n' "$*"; }
ok() { printf '[OK] %s\n' "$*"; }
die() { printf '[ERR] %s\n' "$*" >&2; exit 1; }

[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "run as the normal user with: sudo bash $0"
[[ -f "$ROCM_BUILD/cmake_install.cmake" ]] || die "ROCm build is missing: $ROCM_BUILD"
[[ -f "$CUDA_BUILD/cmake_install.cmake" ]] || die "CUDA build is missing: $CUDA_BUILD"
[[ -f "$MODEL_CONFIG" ]] || die "model config is missing: $MODEL_CONFIG"
[[ -f "$LIVE_CONFIG" ]] || die "live llama-swap config is missing: $LIVE_CONFIG"

grep -q 'muse-glimmer-30b-ud-q6-k-xl' "$MODEL_CONFIG" || die "Muse-Glimmer entry is missing from $MODEL_CONFIG"

log "Installing ROCm llama.cpp to $ROCM_PREFIX"
cmake --install "$ROCM_BUILD" --prefix "$ROCM_PREFIX"
ok "installed ROCm llama.cpp"

log "Installing CUDA llama.cpp to $CUDA_PREFIX"
cmake --install "$CUDA_BUILD" --prefix "$CUDA_PREFIX"
ok "installed CUDA llama.cpp"

log "Verifying installed GPU backends"
"$ROCM_PREFIX/bin/llama-server" --list-devices 2>&1 | grep -q '^ *ROCm0' || die "installed ROCm binary does not report ROCm0"
"$CUDA_PREFIX/bin/llama-server" --list-devices 2>&1 | grep -q '^ *CUDA0' || die "installed CUDA binary does not report CUDA0"
ok "ROCm0 and CUDA0 are visible"

ROCM_LIB="$ROCM_PREFIX/lib/libllama.so.0.0.10354"
[[ -f "$ROCM_LIB" ]] || ROCM_LIB="$(find "$ROCM_PREFIX" -type f -name 'libllama.so.0.0.*' -print -quit)"
[[ -n "${ROCM_LIB:-}" && -f "$ROCM_LIB" ]] || die "installed libllama was not found"
grep -a -q 'muse-glimmer' "$ROCM_LIB" || die "installed ROCm libllama has no Muse-Glimmer support"
ok "installed ROCm build contains Muse-Glimmer support"

backup="${LIVE_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
log "Backing up live llama-swap config to $backup"
cp -a "$LIVE_CONFIG" "$backup"
install -o root -g root -m 0644 "$MODEL_CONFIG" "$LIVE_CONFIG"
ok "deployed $MODEL_ID config to $LIVE_CONFIG"

if systemctl is-active --quiet llama-swap; then
  systemctl kill -s HUP llama-swap 2>/dev/null || true
  log "llama-swap is active; waiting for config reload"
fi

printf '\n[OK] Installation and deployment complete.\n'
printf '     Test model id: %s\n' "$MODEL_ID"
printf '     API: http://127.0.0.1:8080/v1/models\n'
printf '     Model file: /home/rahlquist/.cache/llama.cpp/Muse-Glimmer-30B-UD-Q6_K_XL.gguf\n'
