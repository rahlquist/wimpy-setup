#!/usr/bin/env bash
# fetch-model.sh — download a GGUF model file from Hugging Face, HTTP(S), or
# a local path, inspect its metadata, smoke-test on the configured GPU,
# register in llama-swap, and update the repository model inventory.
#
# Usage:
#   ./fetch-model.sh [options] "hf download hf://owner/repo/file.gguf [N]"
#   ./fetch-model.sh [options] "https://example.com/path/to/model.gguf [N]"
#   ./fetch-model.sh [options] /abs/or/rel/path/to/model.gguf
#
# The optional trailing N is --n-cpu-moe N. It is accepted only for models
# whose downloaded GGUF metadata proves they are MoE models. The script never
# evals a pasted command and never guesses a CPU-MoE layer count.
#
# Defaults are deliberate:
#   * native GGUF context is used when it is >= 64000; smaller native contexts
#     receive an explicit --ctx-size 64000 for Hermes compatibility;
#   * all entries use a downloaded local --model path; never llama.cpp -hf;
#   * CPU-MoE offload is absent unless the user explicitly supplies N;
#   * local source files are removed after a successful pipeline; pass
#     --keep-source to retain the original.
#   * HF vision repos get a repo-verified projector automatically; use
#     --no-mmproj only when deliberately forcing a text-only registration.
set -euo pipefail

err(){ printf '\033[31m[ERR]\033[0m  %s\n' "$*" >&2; }
ok(){  printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
info(){ printf '\033[36m[..]\033[0m   %s\n' "$*"; }
warn(){ printf '\033[33m[!!]\033[0m   %s\n' "$*" >&2; }
die(){
  if [[ -n "$STAGE" ]]; then
    fail "$*" 1
  else
    err "$*"; exit 1
  fi
}
STAGE=""
STUCK_REASON=""; LAST_RC=""; ROLLED_BACK=""
DOSSIER_DIR="${DOSSIER_DIR:-$PWD}"
set_stage(){ STAGE="$1"; }
fail(){
  local msg="$1" rc="${2:-1}"
  err "[$STAGE] $msg"
  STUCK_REASON="$msg"; LAST_RC="$rc"
  recover_dossier
  exit "$rc"
}
recover_dossier(){
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  local name="${NAME:-${FILE:-unknown}}"; name="${name%.gguf}"; name="${name:-unknown}"
  local dossier="${DOSSIER_DIR}/fetch-model-${name}-${ts}.dossier.md"
  {
    echo "# fetch-model.sh recovery dossier — $ts"
    echo
    echo "## What it was doing"
    echo "STAGE: ${STAGE:-unknown}"
    echo "SRC_CLASS: ${SRC_CLASS:-?}   SPEC: ${SPEC:-?}"
    echo
    echo "## Stuck at"
    echo "$STUCK_REASON"
    echo
    echo "## Environment"
    echo "- llama-server : ${LLAMA_SERVER:-?}"
    echo "- gpu device   : ${GPU_DEVICE:-?} (pin ${GPU_ENV_VAR:-?}=${GPU_PIN_VALUE:-?})"
    echo "- models dir   : ${MODELS_DIR:-?}"
    echo "- model path   : ${MODEL_PATH:-<not acquired>}"
    echo "- config       : ${CONFIG:-<none>}"
    echo "- config backup: ${CONFIG_BACKUP:-<none / already cleaned>}"
    echo "- local src    : ${LOCAL_SRC:-<n/a>}"
    echo
    echo "## Partial state / what already succeeded"
    echo "- acquired model file present: $([[ -f "${MODEL_PATH:-}" ]] && echo yes || echo no)"
    echo "- config rolled back: ${ROLLED_BACK:+yes}${ROLLED_BACK:-no}"
    echo
    echo "## Smoke test log"
    if [[ -n "${SMOKE_LOG:-}" && -f "$SMOKE_LOG" ]]; then
      echo "- log: $SMOKE_LOG"
      echo
      echo '```'
      tail -40 "$SMOKE_LOG"
      echo '```'
    else
      echo "- (no smoke log captured)"
    fi
    echo
    echo "## Resume command"
    local resume="cd \"$(pwd)\" && ./fetch-model.sh"
    local rspec; rspec="$(printf '%q' "${SPEC:-}")"; resume+=" ${rspec}"
    [[ -n "${CPU_MOE:-}" ]] && resume+=" --n-cpu-moe $CPU_MOE"
    (( ASSUME_YES )) && resume+=" -y"
    (( DO_SMOKE )) || resume+=" --no-smoke"
    (( DO_DEPLOY )) || resume+=" --no-deploy"
    echo "  $resume"
    echo
    echo "## Prompt to paste to Hermes"
    echo '```'
    echo "fetch-model.sh got stuck at stage '${STAGE:-?}' while handling '${SPEC:-?}'."
    echo "Reason: $STUCK_REASON"
    echo "Model file present: $([[ -f "${MODEL_PATH:-}" ]] && echo yes || echo no). Config rolled back: ${ROLLED_BACK:+yes}${ROLLED_BACK:-no}."
    echo "Config backup (if any): ${CONFIG_BACKUP:-none}. Help me recover — likely need to (re)run from the resume command above or fix the root cause, then re-run."
    echo '```'
  } > "$dossier" 2>&1
  err "Wrote recovery dossier: $dossier"
  err "Paste the fenced block at the bottom to Hermes to recover."
}

PIPELINE_OK=0
SMOKE_LOG=""
SMOKE_FAILED=0
cleanup_source(){
  [[ "$SRC_CLASS" == "local" && "$SOURCE_COPIED" == "1" && "$KEEP_SOURCE" == "0" ]] || return 0
  [[ -f "$LOCAL_SRC" ]] || return 0
  [[ ! "$LOCAL_SRC" -ef "$MODEL_PATH" ]] || return 0
  rm -f -- "$LOCAL_SRC" && ok "removed local source: $LOCAL_SRC (use --keep-source to retain)"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GGUF_INSPECTOR="${GGUF_INSPECTOR:-$SCRIPT_DIR/tools/gguf_metadata.py}"
INVENTORY_RENDERER="${INVENTORY_RENDERER:-$SCRIPT_DIR/tools/render_model_inventory.py}"
INVENTORY_PATH="${INVENTORY_PATH:-$SCRIPT_DIR/model-inventory.html}"
METADATA_DIR="${MODEL_METADATA_DIR:-$SCRIPT_DIR/model-metadata}"
DEPLOY_SOURCE_CONFIG="${DEPLOY_SOURCE_CONFIG:-$SCRIPT_DIR/llama-swap-config.yaml}"
DEPLOY_HELPER="${DEPLOY_HELPER:-/usr/local/sbin/llama-swap-deploy}"
MMPROJ_RESOLVER="${MMPROJ_RESOLVER:-$SCRIPT_DIR/tools/resolve_and_fetch_mmproj.py}"

NAME=""; CTX="64000"; CTX_REQUESTED=""; ASSUME_YES=0; DO_SMOKE=1; DO_REGISTER=1; DO_DEPLOY=1; DO_MMPROJ=1
SPEC=""; CPU_MOE=""; DEVICE_OVERRIDE=""
KEEP_SOURCE=0; SOURCE_COPIED=0; SRC_CLASS=""; LOCAL_SRC=""; URL=""; REMOTE_FILE=""
MMPROJ_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n) NAME="${2:-}"; shift 2;;
    -c) CTX="${2:-}"; CTX_REQUESTED=1; shift 2;;
    -d) DEVICE_OVERRIDE="${2:-}"; shift 2;;
    --n-cpu-moe) CPU_MOE="${2:-}"; shift 2;;
    -y) ASSUME_YES=1; shift;;
    --no-smoke) DO_SMOKE=0; shift;;
    --keep-source) KEEP_SOURCE=1; shift;;
    --no-register) DO_REGISTER=0; shift;;
    --no-deploy) DO_DEPLOY=0; shift;;
    --no-mmproj) DO_MMPROJ=0; shift;;
    -h|--help)
      sed -n '2,21p' "$0"
      exit 0;;
    -*) die "unknown option: $1";;
    *)
      # Accept both a safely quoted paste and the ordinary unquoted shell form:
      #   ./fetch-model.sh "hf download hf://owner/repo/file.gguf 21"
      #   ./fetch-model.sh hf download hf://owner/repo/file.gguf 21
      if [[ -z "$SPEC" ]]; then SPEC="$1"
      elif [[ "$SPEC" == "hf" && "$1" == "download" ]]; then SPEC="hf download"
      elif [[ "$SPEC" == "hf download" ]]; then SPEC="$SPEC $1"
      elif [[ -z "$CPU_MOE" && "$1" =~ ^[0-9]+$ ]]; then CPU_MOE="$1"
      else die "unexpected positional argument: $1"
      fi
      shift;;
  esac
done
[[ -n "$SPEC" ]] || die "no Hugging Face GGUF spec supplied. See --help."
# A common paste form puts the optional CPU-MoE count inside the quoted command.
# Extract it before validating the strict one-file Hugging Face URL.
if [[ "$SPEC" =~ ^(.*\.gguf)[[:space:]]+([0-9]+)$ ]]; then
  [[ -z "$CPU_MOE" ]] || die "MoE count was supplied twice"
  SPEC="${BASH_REMATCH[1]}"
  CPU_MOE="${BASH_REMATCH[2]}"
fi
[[ "$CTX" =~ ^[0-9]+$ ]] && (( CTX >= 64000 )) || die "--ctx-size must be an integer >= 64000"
[[ -z "$CPU_MOE" || "$CPU_MOE" =~ ^[0-9]+$ ]] || die "--n-cpu-moe must be a non-negative integer"
command -v python3 >/dev/null || die "python3 is required"
[[ -f "$GGUF_INSPECTOR" ]] || die "GGUF inspector missing: $GGUF_INSPECTOR"
: "${SMOKE_PORT:=18080}"
: "${SMOKE_TRIES:=180}"
: "${MODELS_DIR:=$HOME/.cache/llama.cpp}"
: "${MAX_RETRIES:=3}"

classify_input() {
  local value="$1"
  # LOCAL FILE
  if [[ -f "$value" ]]; then
    SRC_CLASS="local"
    LOCAL_SRC="$(cd "$(dirname "$value")" && pwd)/$(basename "$value")"
    FILE="$(basename "$value")"
    REMOTE_FILE="$FILE"
    OWNER="local"; REPO="local"
    [[ "$FILE" == *.gguf ]] || return 1
    return 0
  fi
  # URL: http(s):// (not huggingface.co — those go through the HF path below)
  if [[ "$value" == https://huggingface.co/* || "$value" == http://huggingface.co/* \
     || "$value" == https://www.huggingface.co/* || "$value" == http://www.huggingface.co/* ]]; then
    # Fall through to HF parser below
    :
  elif [[ "$value" == http://* || "$value" == https://* ]]; then
    SRC_CLASS="url"
    URL="$value"
    local base="${value%%\?*}"; base="${base%%#*}"
    FILE="${base##*/}"
    REMOTE_FILE="$FILE"
    [[ "$FILE" == *.gguf ]] || return 1
    OWNER="url"; REPO="$(printf '%s' "$URL" | sed -E 's#https?://##; s#/.*$##; s/\./-/g')"
    return 0
  fi
  # HF: hf://  |  hf download hf://  |  https://huggingface.co/
  SRC_CLASS="hf"
  value="${value#hf download }"
  value="${value#hf://}"
  value="${value#https://huggingface.co/}"
  value="${value#http://huggingface.co/}"
  value="${value#https://www.huggingface.co/}"
  value="${value#http://www.huggingface.co/}"
  value="${value/\/resolve\/main\//\/}"
  value="${value/\/blob\/main\//\/}"
  [[ "$value" =~ ^([^/[:space:]]+)/([^/[:space:]]+)/(.+\.gguf)$ ]] || return 1
  OWNER="${BASH_REMATCH[1]}"; REPO="${BASH_REMATCH[2]}"; REMOTE_FILE="${BASH_REMATCH[3]}"
  [[ "$REMOTE_FILE" != /* && "$REMOTE_FILE" != *".."* ]] || return 1
  FILE="${REMOTE_FILE##*/}"
  return 0
}
# Dep checks: hf only for hf class, curl only for url class
classify_input "$SPEC" || die "unsupported spec: $SPEC (expected hf://..., http(s)://....gguf, or local .gguf path)"
set_stage "classify"
[[ "$FILE" == *.gguf && "$FILE" != *[[:space:]]* ]] || die "model filename must be one .gguf file"
case "$SRC_CLASS" in
  hf) command -v hf >/dev/null || die "'hf' not found. Install Hugging Face Hub CLI first.";;
  url) command -v curl >/dev/null || die "'curl' not found. Install curl first.";;
  local) [[ -r "$LOCAL_SRC" ]] || die "local source not readable: $LOCAL_SRC";;
esac
REPO_ID="${OWNER}/${REPO}"

# The example may be supplied as an unquoted command with a separate final N.
# The main parser has already put that N in CPU_MOE.

detect_server(){
  [[ -n "${LLAMA_SERVER:-}" && -x "${LLAMA_SERVER:-}" ]] && { printf '%s\n' "$LLAMA_SERVER"; return; }
  [[ -x /usr/local/bin/llama-server ]] && { printf '%s\n' /usr/local/bin/llama-server; return; }
  [[ -x /usr/bin/llama-server ]] && { printf '%s\n' /usr/bin/llama-server; return; }
  command -v llama-server 2>/dev/null || true
}
detect_config(){
  [[ -n "${LLAMA_SWAP_CONFIG:-}" && -f "${LLAMA_SWAP_CONFIG:-}" ]] && { printf '%s\n' "$LLAMA_SWAP_CONFIG"; return; }
  local root
  root="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$root" && -f "$root/llama-swap-config.yaml" ]] && { printf '%s\n' "$root/llama-swap-config.yaml"; return; }
}
detect_gpu_device(){
  local list device
  list="$("$LLAMA_SERVER" --list-devices 2>/dev/null || true)"
  device="$(printf '%s\n' "$list" | grep -oE '^[[:space:]]*(ROCm|CUDA|Vulkan)[0-9]+' | tr -d ' ' | head -n1 || true)"
  [[ -n "$device" ]] && { printf '%s\n' "$device"; return; }
  command -v rocm-smi >/dev/null 2>&1 && { printf '%s\n' ROCm0; return; }
  command -v nvidia-smi >/dev/null 2>&1 && { printf '%s\n' CUDA0; return; }
}

# --- Model exclusion rules -------------------------------------------------
# Models that must never be registered on wimpy (wrong platform / wrong build).
# Checked immediately after GGUF inspect, BEFORE smoke-test and registration, so
# a flagged model is deleted and reported without spending GPU time. A match
# aborts the pipeline, deletes the freshly downloaded GGUF, and exits cleanly
# with a clear notification.
#
# To add a rule: append an `elif` matching on $REPO_ID / $FILE / $ARCH /
# $DESCRIPTION, and set EXCLUDE_REASON. Keep matches specific (e.g. an exact
# bad version token) so you do not over-block an otherwise-good sibling build.
EXCLUDE_REASON=""
is_excluded_model(){
  EXCLUDE_REASON=""
  local lrepo lcfile
  lrepo="$(printf '%s' "${REPO_ID:-}" | tr '[:upper:]' '[:lower:]')"
  lcfile="$(printf '%s' "${FILE:-}" | tr '[:upper:]' '[:lower:]')"
  # Vicuna v1.1 is the macOS-only build (no Linux/ROCm/CUDA llama.cpp support).
  # v1.3+ / v1.5 are normal cross-platform GGUFs, so match ONLY the 1.1 series.
  if [[ "$lrepo" == *vicuna* && ( "$lcfile" == *v1.1* || "$lcfile" == *1.1* ) ]]; then
    EXCLUDE_REASON="Vicuna v1.1 is a macOS-only build (no Linux/ROCm/CUDA support); excluded per wimpy policy."
    return 0
  fi
  return 1
}

LLAMA_SERVER="$(detect_server)"
CONFIG="$(detect_config || true)"
[[ -n "$LLAMA_SERVER" ]] || die "llama-server not found. Set LLAMA_SERVER=/path/to/llama-server."
GPU_DEVICE="${DEVICE_OVERRIDE:-$(detect_gpu_device || true)}"
case "$GPU_DEVICE" in
  ROCm*) GPU_ENV_VAR="HIP_VISIBLE_DEVICES";;
  CUDA*) GPU_ENV_VAR="CUDA_VISIBLE_DEVICES";;
  Vulkan*) GPU_ENV_VAR="GGML_VK_VISIBLE_DEVICES";;
  *) die "could not determine GPU device. Pass -d ROCm0/CUDA0 explicitly.";;
esac
# Pin VALUE. Default to index 0, but on ROCm wimpy now has TWO ROCm devices —
# the R9700 (inference) and the Ryzen 7700 Raphael iGPU (gfx1036). An index pin
# is fragile (a reorder could select the iGPU), so pin the R9700 by its stable
# UUID; it always remaps to ROCm0 so --device ROCm0 stays correct. Override with
# GPU_PIN_VALUE=... if the discrete card's UUID ever changes (get it from rocminfo).
R9700_UUID="GPU-61fe9ba05af1939a"
case "$GPU_DEVICE" in
  ROCm*) GPU_PIN_VALUE="${GPU_PIN_VALUE:-$R9700_UUID}";;
  *)     GPU_PIN_VALUE="${GPU_PIN_VALUE:-0}";;
esac
TTL="$(grep -hoE 'ttl:[[:space:]]*[0-9]+' "${CONFIG:-/dev/null}" 2>/dev/null | grep -oE '[0-9]+' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
TTL="${TTL:-300}"

printf '%s\n' '  ┌─ detected ─────────────────────────────────────────────'
printf '  │ source       : %s\n' "${SRC_CLASS:-?}"
printf '  │ repo         : %s\n' "$REPO_ID"
printf '  │ file         : %s\n' "$FILE"
printf '  │ llama-server : %s\n' "$LLAMA_SERVER"
printf '  │ gpu device   : %s  (pin: %s=%s)\n' "$GPU_DEVICE" "$GPU_ENV_VAR" "$GPU_PIN_VALUE"
printf '  │ llama-swap   : %s\n' "${CONFIG:-<not found>}"
printf '  │ models dir   : %s\n' "$MODELS_DIR"
printf '  │ ctx request  : %s\n' "$CTX"
printf '  │ cpu MoE      : %s\n' "${CPU_MOE:-none}"
printf '%s\n' '  └────────────────────────────────────────────────────────'
if (( ! ASSUME_YES )); then
  read -r -p '  proceed? [Y/n] ' reply
  [[ "${reply:-Y}" =~ ^[Yy]?$ ]] || { info 'aborted.'; exit 0; }
fi

acquire_model(){
  mkdir -p "$MODELS_DIR" || die "cannot create models directory: $MODELS_DIR"
  MODEL_PATH="$MODELS_DIR/$FILE"
  if [[ -f "$MODEL_PATH" ]]; then
    ok "already acquired: $MODEL_PATH (skipping)"
    return 0
  fi
  local workdir candidate attempt
  workdir="$(mktemp -d "$MODELS_DIR/.fetch.XXXXXX")" || die "cannot create acquire temp dir"
  case "$SRC_CLASS" in
    hf)
      for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
        if hf download "$REPO_ID" "$REMOTE_FILE" --local-dir "$workdir" &&
           [[ -f "$workdir/$REMOTE_FILE" ]]; then
          candidate="$workdir/$REMOTE_FILE"; break; fi
        rm -f -- "$workdir/$REMOTE_FILE"
        if (( attempt < MAX_RETRIES )); then sleep "$attempt"; fi
      done ;;
    url)
      candidate="$workdir/$FILE"
      for ((attempt=1; attempt<=MAX_RETRIES; attempt++)); do
        if curl -fL --retry 2 --retry-delay 1 --output "$candidate" "$URL" &&
           [[ -s "$candidate" ]]; then
          break; fi
        rm -f -- "$candidate"
        if (( attempt < MAX_RETRIES )); then sleep "$attempt"; fi
      done ;;
    local)
      candidate="$workdir/$FILE"
      if ! cp -- "$LOCAL_SRC" "$candidate"; then
        rm -rf -- "$workdir"
        die "cannot copy local source: $LOCAL_SRC"
      fi
      SOURCE_COPIED=1 ;;
  esac
  [[ -n "${candidate:-}" && -f "$candidate" ]] || { rm -rf -- "$workdir"; die "acquisition failed for $SPEC"; }
  mv -- "$candidate" "$MODEL_PATH" || { rm -rf -- "$workdir"; die "cannot install acquired model: $MODEL_PATH"; }
  rm -rf -- "$workdir"
  [[ -f "$MODEL_PATH" ]] || die "acquire completed but model file not found: $MODEL_PATH"
  ok "acquired: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
}
set_stage "acquire"
acquire_model

set_stage "inspect"
METADATA_JSON="$(python3 "$GGUF_INSPECTOR" "$MODEL_PATH")" || die "could not inspect downloaded GGUF metadata"
read -r ARCH NATIVE_CTX BLOCKS EXPERTS EXPERTS_USED <<EOF_META
$(python3 - "$METADATA_JSON" <<'PY'
import json, sys
m=json.loads(sys.argv[1])
print(m.get('architecture',''), m.get('context_length',''), m.get('block_count',''), m.get('expert_count',0), m.get('expert_used_count',0))
PY
)
EOF_META
# Description is recovered separately so spaces do not corrupt shell fields.
DESCRIPTION="$(python3 - "$METADATA_JSON" <<'PY'
import json,sys
print(json.loads(sys.argv[1]).get('description','').replace('\n',' ').strip())
PY
)"
# --- Exclusion gate: flag Mac-only / unsupported models BEFORE smoke/register.
set_stage "exclude"
if is_excluded_model; then
  warn "MODEL EXCLUDED: $EXCLUDE_REASON"
  info "deleting freshly downloaded GGUF so it is not registered: $MODEL_PATH"
  [[ "$SRC_CLASS" != local ]] && rm -f -- "$MODEL_PATH"
  ok "aborted: model flagged and excluded (not registered)."
  exit 0
fi
set_stage "validate"
[[ "$NATIVE_CTX" =~ ^[0-9]+$ ]] || die "GGUF has no usable native context metadata"
# Context policy:
#   * An explicit -c override always wins (validated against native below).
#   * native < 64000 -> force 64000 (Hermes compatibility).
#   * native >= 64000 -> use the model's native context, UNLESS the native
#     context exceeds the GPU's practical VRAM headroom. On wimpy the R9700 is
#     32 GB; a 1M-context MoE KV cache cannot load within llama-swap's health
#     window, so we cap at the project's working context (65536). If even that
#     will not fit, the smoke test announces it and fails with a clear reason.
#     (This was the exact failure mode for Nero-Tron-30B: registered at native
#     1,048,576 it timed out the health check; capped at 65536 it loads fine.)
CTX_CAP=65536
CTX_CAPPED=0
if [[ -n "${CTX_REQUESTED:-}" ]]; then
  EFFECTIVE_CTX="$CTX"
  CTX_MODE="explicit override (-c $CTX)"
  if (( NATIVE_CTX >= 64000 )) && (( CTX > NATIVE_CTX )); then
    die "requested context $CTX exceeds GGUF native context $NATIVE_CTX; config untouched."
  fi
  info "GGUF native context: $NATIVE_CTX; using explicit ctx=$EFFECTIVE_CTX (override)."
elif (( NATIVE_CTX < 64000 )); then
  EFFECTIVE_CTX="$CTX"
  CTX_MODE="hermes-compatibility override"
  info "GGUF native context: $NATIVE_CTX; using explicit ctx=$EFFECTIVE_CTX for Hermes compatibility."
elif (( NATIVE_CTX > CTX_CAP )); then
  EFFECTIVE_CTX="$CTX_CAP"
  CTX_CAPPED=1
  CTX_MODE="capped at $CTX_CAP (native $NATIVE_CTX exceeds R9700 VRAM headroom)"
  warn "GGUF native context $NATIVE_CTX exceeds the $CTX_CAP working cap; registering at ctx=$CTX_CAP."
  warn "If the model fails to load within the health window at ctx=$CTX_CAP, lower -c further to fit VRAM."
else
  EFFECTIVE_CTX="$NATIVE_CTX"
  CTX_MODE="native model context"
  info "GGUF native context: $NATIVE_CTX; omitting --ctx-size so llama.cpp uses the model context."
fi
printf '  │ architecture : %s\n  │ native ctx   : %s\n' "$ARCH" "$NATIVE_CTX"
if (( EXPERTS > 0 )); then
  printf '  │ MoE          : %s experts/layer, %s active; %s blocks\n' "$EXPERTS" "$EXPERTS_USED" "$BLOCKS"
fi
if [[ -n "$CPU_MOE" ]]; then
  (( EXPERTS > 0 )) || die "--n-cpu-moe was supplied but GGUF metadata says this is not an MoE model"
  [[ "$BLOCKS" =~ ^[0-9]+$ ]] || die "GGUF lacks block_count; cannot validate --n-cpu-moe"
  (( CPU_MOE <= BLOCKS )) || die "--n-cpu-moe must be between 0 and $BLOCKS for this model"
fi

if [[ -z "$NAME" ]]; then
  base="${FILE%.gguf}"
  NAME="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
fi
[[ "$NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "model id must contain only lowercase letters, digits, and hyphens"

# --- Multimodal projector (external mmproj-F16.gguf and friends) ------------
# Vision / image-text models frequently ship an external projector file with a
# shared upstream name (e.g. mmproj-F16.gguf) that would collide with other
# models' projectors if downloaded verbatim. This script finds that projector
# from the Hugging Face repo tree (NOT from local GGUF keys — the repo is the
# source of truth for whether a model is multimodal), downloads it, and renames
# it to <model-stem>.mmproj.gguf so it never collides in the shared models dir.
#
# Rules:
#   * For HF-sourced models, resolve the projector via the repo tree
#     (resolve_and_fetch_mmproj.py). A failed lookup is fatal by default: this
#     prevents registering a vision model as text-only. Use --no-mmproj only
#     when deliberately forcing a text-only registration.
#   * For URL / local sources there is no repo context to resolve against, so the
#     projector is left unset (the operator can place it by hand and re-run, or
#     request it explicitly).
MMPROJ_PATH=""
fetch_mmproj() {
  # Sets MMPROJ_PATH (empty if none / not fetchable). Must be called AFTER NAME
  # and FILE are known and only for HF-sourced models.
  if (( DO_MMPROJ == 0 )); then
    return 0
  fi
  if [[ "$SRC_CLASS" != hf ]]; then
    return 0
  fi
  local resolver="$MMPROJ_RESOLVER"
  if [[ ! -f "$resolver" ]]; then
    die "mmproj resolver helper missing: $resolver (use --no-mmproj to override)"
  fi
  local rc=0 resolver_output resolver_error
  resolver_error="$(mktemp /tmp/fetch-model.mmproj.XXXXXX.err)"
  resolver_output="$(python3 "$resolver" "$REPO_ID" "$FILE" 2>"$resolver_error")" || rc=$?
  if (( rc != 0 )); then
    local reason
    reason="$(tr '\n' ' ' <"$resolver_error")"
    rm -f -- "$resolver_error"
    die "mmproj resolution failed; refusing text-only registration: $reason (use --no-mmproj to override)"
  fi
  rm -f -- "$resolver_error"
  MMPROJ_PATH="${resolver_output:-}"
  if [[ -z "$MMPROJ_PATH" ]]; then
    # Empty stdout means the HF repo has no external projector.
    return 0
  fi
  [[ -f "$MMPROJ_PATH" ]] || {
    warn "mmproj resolver returned a missing path; continuing without projector: $MMPROJ_PATH"
    MMPROJ_PATH=""
    return 0
  }
  ok "acquired multimodal projector: $MMPROJ_PATH ($(du -h "$MMPROJ_PATH" | cut -f1))"
  return 0
}
#
# NOTE: HF_TOKEN must be available in the environment for projector resolution
# on private/gated repos. A failed lookup aborts registration; use --no-mmproj
# only when deliberately forcing a text-only registration.

# Fetch the external projector for multimodal models (HF-sourced only).
fetch_mmproj

MOE_ARG=()
[[ -n "$CPU_MOE" ]] && MOE_ARG=(--n-cpu-moe "$CPU_MOE")
CTX_ARG=()
MMPROJ_ARG=()
if [[ -n "$MMPROJ_PATH" ]]; then
  MMPROJ_ARG=(--mmproj "$MMPROJ_PATH")
fi
# Emit --ctx-size when the model needs the Hermes-compatibility floor (native < 64000),
# when the operator explicitly requested a context via -c, OR when we capped the
# native context to fit VRAM headroom (CTX_CAPPED).
if (( NATIVE_CTX < 64000 )) || [[ -n "${CTX_REQUESTED:-}" ]] || (( CTX_CAPPED )); then
  CTX_ARG=(--ctx-size "$EFFECTIVE_CTX")
fi
CTX_TEXT="${CTX_ARG[*]:-}"
CMD_LINES=(
  "$LLAMA_SERVER --model $MODEL_PATH"
  "--n-gpu-layers 99 ${MOE_ARG[*]:-} --device $GPU_DEVICE --flash-attn on --cache-type-k q4_0 --cache-type-v q4_0 $CTX_TEXT ${MMPROJ_ARG[*]:-} --jinja"
  '--host 0.0.0.0 --port ${PORT} --metrics'
)
# Remove the harmless double space when MoE offload is not configured.
CMD_LINES[1]="$(printf '%s' "${CMD_LINES[1]}" | tr -s ' ')"

SERVER_PID=""; SMOKE_LOG=""
cleanup(){
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  # Do NOT delete SMOKE_LOG here; on failure it is preserved for the dossier.

  if (( PIPELINE_OK )); then
    cleanup_source
  fi
  return 0
}
trap cleanup EXIT INT TERM
smoke_test(){
  SMOKE_LOG="$(mktemp /tmp/fetch-model.smoke.XXXXXX.log)"
  info "smoke test: ctx=$EFFECTIVE_CTX ($CTX_MODE) device=$GPU_DEVICE cpu-moe=${CPU_MOE:-none}"
  env "${GPU_ENV_VAR}=${GPU_PIN_VALUE}" "$LLAMA_SERVER" --model "$MODEL_PATH" --n-gpu-layers 99 "${MOE_ARG[@]}" \
    --device "$GPU_DEVICE" --flash-attn on --cache-type-k q4_0 --cache-type-v q4_0 "${CTX_ARG[@]}" "${MMPROJ_ARG[@]}" --jinja \
    --host 127.0.0.1 --port "$SMOKE_PORT" >"$SMOKE_LOG" 2>&1 &
  SERVER_PID=$!
  local i code ready=0
  for ((i=0; i<SMOKE_TRIES; i++)); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null || true)"
    [[ "$code" == 200 ]] && { ready=1; break; }
    sleep 1
  done
  if (( ! ready )); then
    SMOKE_FAILED=1
    if (( CTX_CAPPED )); then
      err "smoke test did not become healthy at ctx=$EFFECTIVE_CTX (capped from native $NATIVE_CTX for VRAM headroom)."
      err "The model still failed to load within the health window at the $CTX_CAP cap."
      err "Likely VRAM exhaustion on $GPU_DEVICE — re-run with a smaller -c (e.g. -c 32768) to fit, or use a smaller quant."
    else
      err "smoke test did not become healthy at ctx=$EFFECTIVE_CTX"
    fi
    grep -iE 'out of memory|hipMalloc|cudaMalloc|failed to allocate|unknown model architecture|error loading model|device.*not found|no devices' "$SMOKE_LOG" | tail -10 >&2 || true
    return 1
  fi
  if grep -qiE 'no GPU.*offload|offload.*CPU only|using CPU backend only' "$SMOKE_LOG"; then
    err "smoke test indicates CPU-only fallback; refusing registration"
    return 1
  fi
  # NOTE: reasoning models (e.g. nemotron_h_moe with reasoning_format=deepseek)
  # may emit only reasoning tokens for the first N predictions, leaving
  # `content` empty even though generation is healthy. Request enough tokens to
  # clear the reasoning phase (n_predict>=64), and treat a probe as success when
  # the server produced real generation — non-empty `content` OR non-empty
  # `reasoning_content` OR a token-producing, non-error completion. HTTP errors,
  # malformed JSON, empty bodies, and server errors remain failures.
  local completion http_code
  http_code="$(curl -sS --max-time 60 -o /tmp/fetch-model.completion.$$ \
    -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/completion" \
    -H 'Content-Type: application/json' \
    -d '{"prompt":"Reply with exactly: OK","n_predict":64,"temperature":0,"cache_prompt":false}' 2>/dev/null || true)"
  completion="$(cat /tmp/fetch-model.completion.$$ 2>/dev/null || true)"
  rm -f -- /tmp/fetch-model.completion.$$
  if ! python3 - "$completion" "$http_code" <<'PY'
import json, sys
raw, http_code = sys.argv[1], sys.argv[2]
# HTTP-level failure: anything other than 2xx is a hard failure.
try:
    if int(http_code) < 200 or int(http_code) >= 300:
        raise SystemExit(1)
except ValueError:
    raise SystemExit(1)
# Empty or malformed body is a failure.
if not raw.strip():
    raise SystemExit(1)
try:
    response = json.loads(raw)
except (json.JSONDecodeError, ValueError):
    raise SystemExit(1)
# Server-reported error field.
if isinstance(response.get('error'), str) and response['error'].strip():
    raise SystemExit(1)
# Success: the model produced real generation.
content = response.get('content')
reasoning = response.get('reasoning_content')
tokens_predicted = response.get('tokens_predicted', response.get('tokens'))
if isinstance(content, str) and content.strip():
    raise SystemExit(0)
if isinstance(reasoning, str) and reasoning.strip():
    raise SystemExit(0)
# Fall back to "tokens were generated", which proves the model ran end-to-end.
try:
    if tokens_predicted and int(tokens_predicted) > 0:
        raise SystemExit(0)
except (ValueError, TypeError):
    pass
raise SystemExit(1)
PY
  then
    err "smoke test health endpoint passed but completion probe failed"
    err "completion response: ${completion:0:400}"
    return 1
  fi
  ok "loaded, generated, and healthy at ctx=$EFFECTIVE_CTX on $GPU_DEVICE"
  if [[ -n "$CPU_MOE" ]]; then info "intentional MoE expert CPU placement: first $CPU_MOE blocks"; fi
  cleanup; SERVER_PID=""; rm -f -- "$SMOKE_LOG"; SMOKE_LOG=""
}
set_stage "smoke"
if (( DO_SMOKE )); then
  command -v curl >/dev/null || die "'curl' not found — required for smoke test"
  smoke_test || die "smoke test failed; model was not registered"
else
  warn 'smoke test skipped.'
fi

deploy_live_config(){
  if (( ! DO_DEPLOY )); then
    info 'automatic deployment skipped (--no-deploy).'
    return 0
  fi
  if (( ! DO_SMOKE )); then
    info 'automatic deployment skipped because the smoke test was disabled.'
    return 0
  fi
  if [[ "$CONFIG" != "$DEPLOY_SOURCE_CONFIG" ]]; then
    info "automatic deployment skipped: config is not the canonical source ($CONFIG)."
    return 0
  fi
  [[ -x "$DEPLOY_HELPER" ]] || die "automatic deployment helper missing: $DEPLOY_HELPER (run sudo $SCRIPT_DIR/install-llama-swap-autodeploy.sh)"
  command -v sudo >/dev/null || die "sudo is required for automatic deployment"
  # Pass the resolved repo config to the helper so it never depends on its own
  # hardcoded default (the project moved out of ~/Downloads; ~/$REPO is canonical).
  export SOURCE_CONFIG="$CONFIG"
  set_stage "deploy"
  sudo -n "$DEPLOY_HELPER" || die "automatic deployment failed; live config was not verified"
  ok "deployed live llama-swap config and verified its API model list"
}

set_stage "register"
(( DO_REGISTER )) || { PIPELINE_OK=1; info "registration skipped. id would be: $NAME"; exit 0; }
[[ -n "$CONFIG" ]] || die "llama-swap config not found. Set LLAMA_SWAP_CONFIG."
[[ -w "$CONFIG" ]] || die "config is not writable: $CONFIG"
SIDECAR="$METADATA_DIR/$NAME.json"
if [[ -e "$SIDECAR" ]]; then
  set +e
  python3 - "$SIDECAR" "$FILE" "$REPO_ID" <<'PY'
import json,sys
sc=json.load(open(sys.argv[1]))
ok=sc.get('filename')==sys.argv[2] and sc.get('repository')==sys.argv[3]
raise SystemExit(0 if ok else 2)
PY
  sidecar_rc=$?
  set -e
  case "$sidecar_rc" in
    0)
      warn "metadata sidecar already exists: $SIDECAR (consistent); nothing to do."
      deploy_live_config
      ok "model already registered as '$NAME'."
      PIPELINE_OK=1
      exit 0
      ;;
    2) die "name collision: '$NAME' already registered for a different model ($SIDECAR)";;
    *) die "cannot read existing sidecar: $SIDECAR";;
  esac
fi
mkdir -p "$METADATA_DIR" || die "cannot create metadata directory: $METADATA_DIR"
mkdir -p "$(dirname "$INVENTORY_PATH")" || die "cannot create inventory directory: $(dirname "$INVENTORY_PATH")"
SIDECAR_TMP="$(mktemp "$METADATA_DIR/.${NAME}.XXXXXX")" || die "cannot create metadata temporary file"
INVENTORY_TMP="$(mktemp "${INVENTORY_PATH}.XXXXXX")" || { rm -f -- "$SIDECAR_TMP"; die "cannot create inventory temporary file"; }
CONFIG_BACKUP="$(mktemp "${CONFIG}.fetch-model.XXXXXX")" || { rm -f -- "$SIDECAR_TMP" "$INVENTORY_TMP"; die "cannot create config backup"; }
cp -- "$CONFIG" "$CONFIG_BACKUP" || { rm -f -- "$SIDECAR_TMP" "$INVENTORY_TMP" "$CONFIG_BACKUP"; die "cannot back up config"; }
rollback_registration(){
  ROLLED_BACK=1
  [[ -n "${CONFIG_BACKUP:-}" && -f "$CONFIG_BACKUP" ]] && cp -- "$CONFIG_BACKUP" "$CONFIG" || true
  rm -f -- "${SIDECAR:-}" "${SIDECAR_TMP:-}" "${INVENTORY_TMP:-}"
}

# Insert using a constrained textual transformation. It preserves comments and
# formatting, validates before replacement, and never uses yq or git checkout.
CMDFILE="$(mktemp /tmp/fetch-model.cmd.XXXXXX)"
printf '%s\n' "${CMD_LINES[@]}" > "$CMDFILE"
set +e
python3 - "$CONFIG" "$NAME" "$TTL" "$CMDFILE" "$GPU_ENV_VAR" "$GPU_PIN_VALUE" <<'PY'
import os, re, sys
cfg, name, ttl, cmdfile, gpu_env, gpu_pin = sys.argv[1:]
with open(cfg, encoding='utf-8') as f: text=f.read()
lines=text.splitlines()
mi=next((i for i,l in enumerate(lines) if re.match(r'^models:\s*(?:#.*)?$', l)), None)
if mi is None: raise SystemExit('no top-level models: key found')
child_indent='  '
for line in lines[mi+1:]:
    if not line.strip() or line.lstrip().startswith('#'): continue
    if not line.startswith((' ', '\t')): break
    child_indent=re.match(r'^(\s+)',line).group(1); break
field_indent=child_indent+'  '
cmd_indent=field_indent+'  '
existing=set()
for line in lines[mi+1:]:
    if not line.strip() or line.lstrip().startswith('#'): continue
    if not line.startswith((' ', '\t')): break
    m=re.match(r'^'+re.escape(child_indent)+r'["\']?([^"\':]+)["\']?\s*:',line)
    if m: existing.add(m.group(1))
if name in existing: raise SystemExit(3)
with open(cmdfile, encoding='utf-8') as f: command=[x.rstrip('\n') for x in f]
block=[f'{child_indent}"{name}":', f'{field_indent}ttl: {ttl}', f'{field_indent}env: ["{gpu_env}={gpu_pin}"]', f'{field_indent}cmd: |'] + [cmd_indent+x for x in command]
new='\n'.join(lines[:mi+1]+block+lines[mi+1:])+'\n'
if [l for l in new.splitlines() if re.match(r'^\S',l)] != [l for l in text.splitlines() if re.match(r'^\S',l)]:
    raise SystemExit('top-level structure would change')
tmp=cfg+'.tmp'
with open(tmp,'w',encoding='utf-8') as f: f.write(new)
os.replace(tmp,cfg)
PY
rc=$?
set -e
rm -f "$CMDFILE"
case "$rc" in
  0) ok "registered '$NAME' in $CONFIG.";;
  3) rm -f -- "$CONFIG_BACKUP" "$SIDECAR_TMP" "$INVENTORY_TMP"; PIPELINE_OK=1; warn "model id '$NAME' already exists; config untouched."; exit 0;;
  *) rm -f -- "$CONFIG_BACKUP" "$SIDECAR_TMP" "$INVENTORY_TMP"; die "config insertion failed; config untouched.";;
esac

# Store metadata in the repository. It makes inventory generation reproducible,
# avoids putting untracked sidecars in a model cache, and retains inspection
# evidence even when a model is moved or re-downloaded.
set +e
python3 - "$SIDECAR_TMP" "$NAME" "$REPO_ID" "$FILE" "$MODEL_PATH" "$EFFECTIVE_CTX" "$NATIVE_CTX" "$CPU_MOE" "$MMPROJ_PATH" "$METADATA_JSON" "$DESCRIPTION" <<'PY'
import json,sys,datetime
out,alias,repo,file,path,ctx,native,cpu,mmproj_path,metadata,description=sys.argv[1:]
m=json.loads(metadata)
data={
  'alias':alias, 'repository':repo, 'filename':file, 'model_path':path,
  'downloaded_at':datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
  'requested_context':int(ctx), 'native_context':int(native),
  'n_cpu_moe':int(cpu) if cpu else None,
  'mmproj_path':mmproj_path or None,
  'gguf':m,
  'description':description or m.get('name') or f'GGUF from {repo}',
}
with open(out,'w',encoding='utf-8') as f: json.dump(data,f,indent=2,sort_keys=True); f.write('\n')
PY
rc=$?
if (( rc == 0 )); then mv -- "$SIDECAR_TMP" "$SIDECAR"; fi
if (( rc == 0 )) && [[ -f "$INVENTORY_RENDERER" ]]; then
  python3 "$INVENTORY_RENDERER" "$CONFIG" "$INVENTORY_TMP" "$METADATA_DIR"
  rc=$?
else
  rc=1
fi
set -e
if (( rc != 0 )); then
  rm -f -- "$SIDECAR_TMP" "$INVENTORY_TMP"
  rollback_registration
  rm -f -- "$CONFIG_BACKUP"
  die "metadata or inventory generation failed; registration rolled back"
fi
mv -- "$INVENTORY_TMP" "$INVENTORY_PATH"
rm -f -- "$CONFIG_BACKUP"
ok "wrote metadata sidecar: $SIDECAR"
ok "updated model inventory: $INVENTORY_PATH"

deploy_live_config

info 'repository changes are local only; review, commit, and push manually if desired.'

PIPELINE_OK=1
exit 0
