#!/usr/bin/env bash
# fetch-model.sh (v3, ROCm-aware) — fetch a GGUF, smoke-test it on the GPU at
# full context, then register it in llama-swap-config.yaml. Auto-detects your
# setup so you can run it with just the paste from a HF model card.
#
# Usage:
#   ./fetch-model.sh [options] "<hf spec>"
#
# <hf spec> accepts any paste form:
#   "hf download hf://owner/repo/file.gguf"
#   "hf download owner/repo file.gguf"
#   "owner/repo/file.gguf"  |  "owner/repo"  |  a full huggingface.co URL
#
# Example:
#   ./fetch-model.sh "hf download hf://unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF/Qwen3-Coder-30B-A3B-Instruct-Q5_K_M.gguf"
#
# Options:
#   -n NAME   llama-swap model id            (default: derived from filename)
#   -q Q      quant tag if spec has no file  (default: Q6_K)
#   -c N      smoke-test context             (default: 65536)
#   -s hf|path  force reference style        (default: auto-detect from your config)
#   -d DEVICE force GPU device (e.g. ROCm0, CUDA0) (default: auto-detect)
#   -y        skip the "detected" confirmation prompt
#   --no-smoke / --no-register
#   -h        help
#
# Auto-detected, override via env if needed:
#   MODELS_DIR (default ~/.cache/llama.cpp)  LLAMA_SERVER  LLAMA_SWAP_CONFIG
#
# wimpy-specific behavior (see CLAUDE.md / CHANGELOG.md for why):
#   - GPU device pin is REQUIRED, not optional. This script refuses to
#     register a model without an explicit --device/env pin — that's the
#     exact silent-CPU-fallback bug the 2026-07-07 ROCm migration fixed.
#   - Registers into this repo's llama-swap-config.yaml (the source of
#     truth), NOT /etc/llama-swap/config.yaml directly. Deploying to
#     production is printed as a final manual step, not auto-run — matches
#     how every other config change in this project works, and llama-swap
#     runs with -watch-config so deploying is just a `cp`, no restart needed.
# ---------------------------------------------------------------------------
set -euo pipefail
err(){ printf '\033[31m[ERR]\033[0m  %s\n' "$*" >&2; }
ok(){  printf '\033[32m[OK]\033[0m   %s\n' "$*"; }
info(){ printf '\033[36m[..]\033[0m   %s\n' "$*"; }
warn(){ printf '\033[33m[!!]\033[0m   %s\n' "$*" >&2; }
die(){ err "$*"; exit 1; }

NAME=""; QUANT="Q6_K"; CTX="65536"; STYLE=""; ASSUME_YES=0
DO_SMOKE=1; DO_REGISTER=1; SPEC=""; DEVICE_OVERRIDE=""
while [[ $# -gt 0 ]]; do case "$1" in
  -n) NAME="$2"; shift 2;;  -q) QUANT="$2"; shift 2;;  -c) CTX="$2"; shift 2;;
  -s) STYLE="$2"; shift 2;; -y) ASSUME_YES=1; shift;;
  -d) DEVICE_OVERRIDE="$2"; shift 2;;
  --no-smoke) DO_SMOKE=0; shift;;  --no-register) DO_REGISTER=0; shift;;
  -h|--help) sed -n '2,50p' "$0"; exit 0;;
  -*) die "unknown option: $1";;  *) SPEC="$1"; shift;;
esac; done
[[ -n "$SPEC" ]] || die "no HF spec given. See -h."
command -v hf >/dev/null || die "'hf' not found (pip install -U huggingface_hub)."
: "${SMOKE_PORT:=18080}"   # smoke-test port, off your prod 8080

# ---- auto-detect llama-server --------------------------------------------
detect_server(){
  [[ -n "${LLAMA_SERVER:-}" ]] && { echo "$LLAMA_SERVER"; return; }
  # Prefer the known-correct, canonical path explicitly over PATH resolution
  # — PATH shadowing by a stray build is exactly what caused wimpy's
  # 2026-07-07 ROCm migration incident (see CLAUDE.md). Never trust a bare
  # `llama-server` first.
  #
  # /usr/local/bin is canonical as of the "stop using pacman for llama.cpp"
  # switch (05-llama-cpp.sh, source build, version-pinned) — see
  # CHANGELOG.md. If /usr/bin/llama-server still exists, that's the OLD
  # llama-cpp-rocm package build; it's checked as a fallback only in case
  # the source build hasn't been done yet on this machine, not preferred.
  [[ -x /usr/local/bin/llama-server ]] && { echo /usr/local/bin/llama-server; return; }
  [[ -x /usr/bin/llama-server ]] && { echo /usr/bin/llama-server; return; }
  command -v llama-server 2>/dev/null && return
  local p; for p in "$HOME"/llama.cpp/build/bin/llama-server \
      "$HOME"/src/llama.cpp/build/bin/llama-server \
      /opt/llama.cpp/build/bin/llama-server; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
}
# ---- auto-detect llama-swap config ---------------------------------------
detect_config(){
  [[ -n "${LLAMA_SWAP_CONFIG:-}" && -f "${LLAMA_SWAP_CONFIG:-}" ]] && { echo "$LLAMA_SWAP_CONFIG"; return; }
  # Prefer this project's git-tracked source-of-truth file over the deployed
  # copy. Editing /etc/llama-swap/config.yaml directly would work (llama-swap
  # runs with -watch-config and hot-reloads) but silently drifts the repo out
  # of sync with production — that already happened once, see CHANGELOG.md's
  # "legacy entries" note. Editing the repo file keeps deploy a deliberate,
  # visible step instead.
  local git_root
  git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -n "$git_root" && -f "$git_root/llama-swap-config.yaml" ]]; then
    echo "$git_root/llama-swap-config.yaml"; return
  fi
  shopt -s nullglob
  local dirs=( "$HOME/wimpy-setup" "$HOME/.config/llama-swap" "$HOME/llama-swap" "$HOME/.llama-swap" /etc/llama-swap . ) d c
  for d in "${dirs[@]}"; do            # pass 1: prefer canonical config names
    for c in "$d/llama-swap-config.yaml" "$d/config.yaml" "$d/config.yml"; do
      [[ -f "$c" ]] && grep -qE '^[[:space:]]*models:' "$c" 2>/dev/null && { echo "$c"; shopt -u nullglob; return; }
    done
  done
  for d in "${dirs[@]}"; do            # pass 2: any other yaml, skipping NNNN-... backups
    for c in "$d"/*.y*ml; do
      [[ "$(basename "$c")" =~ ^[0-9]{8,}- ]] && continue
      grep -qE '^[[:space:]]*models:' "$c" 2>/dev/null && { echo "$c"; shopt -u nullglob; return; }
    done
  done
  shopt -u nullglob
}
# ---- auto-detect GPU device + its pinning env var -------------------------
# Asks llama-server itself which backend device it sees (most reliable —
# matches exactly what will be used at runtime), falling back to checking
# which vendor's smi tool exists. Refuses silently-CPU by design: if nothing
# is found, GPU_DEVICE stays empty and the caller must die() rather than
# register a model with no GPU pin at all.
detect_gpu_device(){
  local list dev
  if [[ -n "${LLAMA_SERVER:-}" && -x "${LLAMA_SERVER:-}" ]]; then
    list="$("$LLAMA_SERVER" --list-devices 2>/dev/null || true)"
    dev="$(printf '%s\n' "$list" | grep -oE '^(ROCm|CUDA|Vulkan)[0-9]+' | head -n1 || true)"
    [[ -n "$dev" ]] && { echo "$dev"; return; }
  fi
  if command -v rocm-smi >/dev/null 2>&1; then echo "ROCm0"; return; fi
  if command -v nvidia-smi >/dev/null 2>&1; then echo "CUDA0"; return; fi
}

LLAMA_SERVER="$(detect_server || true)"
CONFIG="$(detect_config || true)"
: "${MODELS_DIR:=$HOME/.cache/llama.cpp}"

if [[ -n "$DEVICE_OVERRIDE" ]]; then GPU_DEVICE="$DEVICE_OVERRIDE"
else GPU_DEVICE="$(detect_gpu_device || true)"; fi
case "$GPU_DEVICE" in
  ROCm*) GPU_ENV_VAR="HIP_VISIBLE_DEVICES";;
  CUDA*) GPU_ENV_VAR="CUDA_VISIBLE_DEVICES";;
  Vulkan*) GPU_ENV_VAR="GGML_VK_VISIBLE_DEVICES";;
  *) GPU_ENV_VAR="";;
esac
[[ -n "$GPU_DEVICE" && -n "$GPU_ENV_VAR" ]] || die \
  "couldn't determine a GPU device (\$LLAMA_SERVER --list-devices, rocm-smi, and nvidia-smi all came up empty). Pass -d ROCm0 (or -d CUDA0) explicitly. Refusing to register a model with no GPU pin at all — that's the exact silent-CPU-fallback bug this project already fixed once, see CHANGELOG.md."

# ---- detect reference style + ttl from the existing config ---------------
if [[ -z "$STYLE" ]]; then
  if [[ -n "$CONFIG" ]] && grep -qE '(^|[[:space:]])(-hf|--hf-repo)([[:space:]]|=)' "$CONFIG"; then
    STYLE="hf"; else STYLE="path"; fi
fi
TTL="$(grep -hoE 'ttl:[[:space:]]*[0-9]+' "${CONFIG:-/dev/null}" 2>/dev/null \
      | grep -oE '[0-9]+' | sort | uniq -c | sort -rn | awk 'NR==1{print $2}')"
TTL="${TTL:-300}"

# ---- normalize spec into REPO_ID + FILE + QTAG ---------------------------
norm="$SPEC"; norm="${norm#hf download }"; norm="${norm## }"; norm="${norm%% }"
norm="${norm#hf://}"; norm="${norm#https://huggingface.co/}"; norm="${norm#http://huggingface.co/}"
norm="${norm/\/resolve\/main\//\/}"; norm="${norm/\/blob\/main\//\/}"
if [[ "$norm" == *" "* && "$norm" != *"/"*" "*"/"* ]]; then norm="${norm// //}"; fi
IFS='/' read -r OWNER REPO FILE <<< "$norm"
[[ -n "${OWNER:-}" && -n "${REPO:-}" ]] || die "could not parse owner/repo from: $SPEC"
REPO_ID="$OWNER/$REPO"; FILE="${FILE:-}"
if [[ -n "$FILE" && "$FILE" =~ (IQ[0-9][A-Z0-9_]*|Q[0-9]+(_[A-Z0-9]+)*|BF16|F16|F32) ]]; then
  QTAG="${BASH_REMATCH[1]}"; else QTAG="$QUANT"; fi

# ---- show what we inferred, let the user bail ----------------------------
echo "  ┌─ detected ─────────────────────────────────────────────"
printf '  │ repo         : %s\n' "$REPO_ID"
printf '  │ quant        : %s\n' "$QTAG"
printf '  │ style        : %s\n' "$STYLE  ($([[ $STYLE == hf ]] && echo 'register as -hf repo:quant' || echo 'download + register as -m path'))"
printf '  │ llama-server : %s\n' "${LLAMA_SERVER:-<not found - set LLAMA_SERVER>}"
printf '  │ gpu device   : %s  (pin: %s=0)\n' "$GPU_DEVICE" "$GPU_ENV_VAR"
printf '  │ llama-swap   : %s\n' "${CONFIG:-<not found - set LLAMA_SWAP_CONFIG>}"
printf '  │ models dir   : %s\n' "$MODELS_DIR"
printf '  │ ttl / ctx    : %s / %s\n' "$TTL" "$CTX"
echo "  └────────────────────────────────────────────────────────"
[[ -n "$LLAMA_SERVER" ]] || die "llama-server not found. Set LLAMA_SERVER=/path/to/llama-server."
if [[ "$ASSUME_YES" -ne 1 ]]; then
  read -r -p "  proceed? [Y/n] " a; [[ "${a:-Y}" =~ ^[Yy]?$ ]] || { info "aborted."; exit 0; }
fi

# ---- fetch (path style only; hf style fetches during smoke test) ---------
MODEL_REF=()        # what we pass to llama-server, and later to llama-swap
if [[ "$STYLE" == "hf" ]]; then
  MODEL_REF=(-hf "$REPO_ID:$QTAG")
else
  if [[ -n "$FILE" ]]; then
    info "downloading $FILE -> $MODELS_DIR"
    hf download "$REPO_ID" "$FILE" --local-dir "$MODELS_DIR"
    MODEL_PATH="$MODELS_DIR/$FILE"
  else
    info "downloading *$QTAG* -> $MODELS_DIR"
    hf download "$REPO_ID" --include "*$QTAG*" --local-dir "$MODELS_DIR"
    MODEL_PATH="$(find "$MODELS_DIR" -type f -name "*$QTAG*.gguf" | sort | head -n1 || true)"
  fi
  [[ -n "${MODEL_PATH:-}" && -f "$MODEL_PATH" ]] || die "downloaded file not found in $MODELS_DIR"
  ok "downloaded: $MODEL_PATH ($(du -h "$MODEL_PATH" | cut -f1))"
  MODEL_REF=(-m "$MODEL_PATH")
fi

# default model id
if [[ -z "$NAME" ]]; then
  base="${FILE:-$REPO-$QTAG}"; base="${base%.gguf}"
  NAME="$(echo "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]\+/-/g; s/^-//; s/-$//')"
fi

# ---- smoke test -----------------------------------------------------------
SERVER_PID=""; SMOKE_LOG="$(mktemp /tmp/fetch-model.smoke.XXXXXX.log)"
cleanup(){ if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null||true; wait "$SERVER_PID" 2>/dev/null||true; fi; }
trap cleanup EXIT INT TERM

smoke_test(){
  # hf style may download multi-GB on first run, so give it room + a heartbeat
  local timeout=180; [[ "$STYLE" == "hf" ]] && timeout=1800
  info "smoke test: ${MODEL_REF[*]}  (ctx=$CTX, device=$GPU_DEVICE, full GPU, q4_0 KV)"
  env "${GPU_ENV_VAR}=0" "$LLAMA_SERVER" "${MODEL_REF[@]}" -ngl 99 --device "$GPU_DEVICE" \
    -fa on -ctk q4_0 -ctv q4_0 -c "$CTX" --jinja \
    --host 127.0.0.1 --port "$SMOKE_PORT" >"$SMOKE_LOG" 2>&1 &
  SERVER_PID=$!
  local ready=0 i code last=""
  for ((i=0; i<timeout; i++)); do
    kill -0 "$SERVER_PID" 2>/dev/null || break
    code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SMOKE_PORT/health" 2>/dev/null||true)"
    [[ "$code" == "200" ]] && { ready=1; break; }
    if (( i % 10 == 9 )); then   # heartbeat: surface download/load progress
      local cur; cur="$(tail -n1 "$SMOKE_LOG" 2>/dev/null||true)"
      [[ -n "$cur" && "$cur" != "$last" ]] && { printf '       … %s\n' "${cur:0:90}"; last="$cur"; }
    fi
    sleep 1
  done
  if [[ "$ready" -ne 1 ]]; then
    err "did NOT come up at ctx=$CTX — likely OOM / won't fit, arch unsupported, or the GPU device pin ($GPU_DEVICE) failed to bind."
    grep -iE 'out of memory|hipMalloc|cudaMalloc|HIP error|CUDA error|failed to allocate|unknown model architecture|error loading model|device.*not found|no devices' "$SMOKE_LOG"|tail -8 >&2||true
    warn "log: $SMOKE_LOG  — try -q Q4_K_M, a smaller -c, or --n-cpu-moe N if this is a MoE model."; return 1
  fi
  local gen offload nctx
  gen="$(curl -s --max-time 30 "http://127.0.0.1:$SMOKE_PORT/completion" -H 'Content-Type: application/json' \
        -d '{"prompt":"def add(a,b):\n    return","n_predict":12,"temperature":0}' \
        | python3 -c 'import sys,json;print(json.load(sys.stdin).get("content","").strip()[:60])' 2>/dev/null||true)"
  # Broadened on purpose: llama.cpp's exact offload-summary phrasing has
  # varied across builds/backends (dense vs. MoE models log this
  # differently), so this matches any line mentioning offload or gpu that
  # contains an N/M count, rather than requiring one specific sentence
  # shape. Still just a heuristic confirmation on top of the real check
  # below (rocm-smi/nvidia-smi VRAM usage), not the source of truth.
  offload="$(grep -iE 'offload|gpu' "$SMOKE_LOG"|grep -oE '[0-9]+/[0-9]+'|tail -1||true)"
  nctx="$(grep -oE 'n_ctx[^=]*= *[0-9]+' "$SMOKE_LOG"|tail -1||true)"
  echo; ok "loaded and healthy at ctx=$CTX on $GPU_DEVICE"
  [[ -n "$offload" ]] && info "layers: $offload" || warn "couldn't confirm offload from log"
  [[ -n "$nctx" ]] && info "context: $nctx"
  [[ -n "$gen" ]] && info "generation: '$gen'" || warn "generation probe empty"
  echo "    --- GPU memory while loaded ---"
  if [[ "$GPU_ENV_VAR" == "HIP_VISIBLE_DEVICES" ]] && command -v rocm-smi >/dev/null 2>&1; then
    rocm-smi --showmeminfo vram 2>/dev/null | sed 's/^/    /' || warn "rocm-smi failed"
  elif command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.used,memory.total --format=csv,noheader 2>/dev/null | sed 's/^/    /' || warn "nvidia-smi failed"
  else
    warn "no GPU memory tool found (rocm-smi/nvidia-smi)"
  fi
  echo
  if [[ -n "$offload" ]]; then
    local g="${offload%%/*}" t="${offload##*/}"
    [[ "$g" == "$t" ]] || { err "only $g/$t layers on GPU — spilled to CPU despite the --device pin. If this is a large MoE model, that may be intentional (--n-cpu-moe); otherwise don't register it as-is."; return 1; }
  fi
}
if [[ "$DO_SMOKE" -eq 1 ]]; then
  smoke_test || { cleanup; die "smoke test failed — not registering."; }
  cleanup; ok "smoke test passed."
else warn "smoke test skipped."; fi

# ---- register -------------------------------------------------------------
[[ "$DO_REGISTER" -eq 1 ]] || { info "registration skipped. id would be: $NAME"; exit 0; }

# llama-swap launch line, in the same reference style as your other models
CMD_REF="${MODEL_REF[*]}"
read -r -d '' CMD_BLOCK <<EOF || true
$LLAMA_SERVER $CMD_REF
-ngl 99 --device $GPU_DEVICE -fa on -ctk q4_0 -ctv q4_0 -c $CTX --jinja
--host 0.0.0.0 --port \${PORT} --metrics
EOF
print_snippet(){ cat <<EOF
# --- paste under your 'models:' key (match sibling indentation) ---
  "$NAME":
    ttl: $TTL
    env: ["$GPU_ENV_VAR=0"]
    cmd: |
$(printf '%s\n' "$CMD_BLOCK"|sed 's/^/      /')
EOF
}
if [[ -z "$CONFIG" ]]; then
  warn "llama-swap config not found. Add this manually:"; print_snippet; exit 0; fi
command -v python3 >/dev/null || {
  warn "python3 not found — can't safely edit YAML. Paste this under 'models:':"
  print_snippet; exit 0; }

# Use sudo only for the privileged file ops if the config dir isn't user-writable
# (only relevant if CONFIG resolved to /etc/llama-swap/config.yaml directly).
WRITE=""
if [[ ! -w "$(dirname "$CONFIG")" || ( -e "$CONFIG" && ! -w "$CONFIG" ) ]]; then
  WRITE="sudo"; info "config dir is root-owned — using sudo for the backup + edit."
fi

# Standing rule: back up a working config before touching it — unless it's
# git-tracked, in which case git itself is already the backup and a
# timestamped copy is just repo clutter (restore via `git checkout` instead).
GIT_TRACKED=0
if git -C "$(dirname "$CONFIG")" ls-files --error-unmatch "$(basename "$CONFIG")" >/dev/null 2>&1; then
  GIT_TRACKED=1
fi
if [[ "$GIT_TRACKED" -eq 1 ]]; then
  info "config is git-tracked — skipping timestamped backup file (git history covers it)."
else
  BACKUP="$(dirname "$CONFIG")/$(date +%Y%m%d%H%M%S)-$(basename "$CONFIG")"
  $WRITE cp "$CONFIG" "$BACKUP"; ok "backed up -> $BACKUP"
fi

CMDFILE="$(mktemp /tmp/fetch-model.cmd.XXXXXX)"; printf '%s\n' "$CMD_BLOCK" > "$CMDFILE"
set +e
$WRITE python3 - "$CONFIG" "$NAME" "$TTL" "$CMDFILE" "$GPU_ENV_VAR" <<'PY'
import sys, re, os
cfg, name, ttl, cmdfile, gpu_env = sys.argv[1:6]
name = name.strip('"').strip("'")
with open(cmdfile) as f:
    cmd_lines = [l.rstrip('\n') for l in f if l.strip()]
with open(cfg) as f:
    text = f.read()
lines = text.split('\n')

# locate the top-level 'models:' key (column 0)
mi = next((i for i,l in enumerate(lines) if re.match(r'^models:\s*(#.*)?$', l)), None)
if mi is None:
    sys.stderr.write("no top-level 'models:' key found\n"); sys.exit(2)

# detect child-key indent (ind1) and the indent step used under an entry
ind1, first = None, None
for j in range(mi+1, len(lines)):
    l = lines[j]
    if not l.strip() or l.lstrip().startswith('#'): continue
    m = re.match(r'^(\s+)\S', l)
    if not m: break                      # dedented to col 0 -> models is empty
    ind1, first = m.group(1), j; break
if ind1 is None: ind1 = '  '

existing, step = set(), '  '
if first is not None:
    base = len(ind1)
    for l in lines[mi+1:]:
        if not l.strip() or l.lstrip().startswith('#'): continue
        m = re.match(r'^(\s*)\S', l)
        if len(m.group(1)) == 0: break    # next top-level key -> end of models
        if len(m.group(1)) == base:
            km = re.match(r'^\s+(["\']?)([^"\':]+)\1\s*:', l)
            if km: existing.add(km.group(2).strip())
    for l in lines[first+1:]:             # find field indent -> infer step
        if not l.strip() or l.lstrip().startswith('#'): continue
        m = re.match(r'^(\s+)\S', l)
        if not m or len(m.group(1)) <= base: break
        step = ' ' * (len(m.group(1)) - base); break

if name in existing:
    sys.stderr.write("DUPLICATE\n"); sys.exit(3)

i2, i3 = ind1+step, ind1+step+step
block = [f'{ind1}"{name}":', f'{i2}ttl: {ttl}', f'{i2}env: ["{gpu_env}=0"]', f'{i2}cmd: |'] \
        + [f'{i3}{c}' for c in cmd_lines]
new = lines[:mi+1] + block + lines[mi+1:]
new_text = '\n'.join(new)

# validate BEFORE writing: top-level shape unchanged, and (if PyYAML present) it parses
top = lambda t: [l for l in t.split('\n') if re.match(r'^\S', l)]
if top(new_text) != top(text):
    sys.stderr.write("top-level structure would change\n"); sys.exit(4)
try:
    import yaml
    d = yaml.safe_load(new_text)
    if not isinstance(d.get('models'), dict) or name not in d['models']:
        sys.stderr.write("post-parse check failed\n"); sys.exit(4)
except ImportError:
    pass
except Exception as e:
    sys.stderr.write(f"yaml parse error: {e}\n"); sys.exit(4)

tmp = os.path.join(os.path.dirname(os.path.abspath(cfg)), f".{os.path.basename(cfg)}.tmp")
with open(tmp,'w') as f: f.write(new_text)
os.replace(tmp, cfg)
PY
rc=$?; set -e
rm -f "$CMDFILE"
case "$rc" in
  0)
    ok "registered '$NAME' in $CONFIG."
    if [[ "$CONFIG" == "/etc/llama-swap/config.yaml" ]]; then
      warn "this IS the live deployed config — llama-swap runs with -watch-config, so it has likely already hot-reloaded. Remember to sync this into the wimpy-setup repo (git add/commit) so it doesn't drift out of git, same issue as the legacy entries noted in CHANGELOG.md."
    else
      info "this is the repo copy — not deployed yet. To go live:"
      info "  sudo cp /etc/llama-swap/config.yaml /etc/llama-swap/\$(date +%Y%m%d%H%M%S)-config.yaml.bak"
      info "  sudo cp \"$CONFIG\" /etc/llama-swap/config.yaml"
      info "  # no restart needed — llama-swap runs with -watch-config and hot-reloads automatically"
      info "Then commit: git -C \"$(dirname "$CONFIG")\" add \"$(basename "$CONFIG")\" && git -C \"$(dirname "$CONFIG")\" commit -m \"Add $NAME to llama-swap config\""
    fi
    exit 0;;
  3) warn "model id '$NAME' already present — config untouched. Use -n for another id."
     [[ "$GIT_TRACKED" -eq 0 ]] && $WRITE rm -f "$BACKUP"   # nothing changed; drop the redundant backup
     exit 0;;
  *) err "insert/validate failed (code $rc) — restoring."
     if [[ "$GIT_TRACKED" -eq 1 ]]; then
       git -C "$(dirname "$CONFIG")" checkout -- "$(basename "$CONFIG")"
       warn "restored via git checkout. Add manually instead:"
     else
       $WRITE cp "$BACKUP" "$CONFIG"
       warn "restored from $BACKUP. Add manually instead:"
     fi
     print_snippet; exit 1;;
esac
