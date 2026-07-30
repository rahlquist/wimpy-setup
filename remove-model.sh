#!/usr/bin/env bash
# remove-model.sh — remove a model from the wimpy llama-swap fleet.
#
# What it does (all reversible except --purge, which deletes files):
#   1. Backs up the repo config AND the live config (hard rule).
#   2. Removes the model's entry from llama-swap-config.yaml (models: map),
#      AND any group membership (e.g. amd-r9700 / nvidia-5060ti) so the next
#      reload does not fail with "no model config for <id>" (the ovisocr2 trap).
#   3. Deploys the edited repo config to /etc/llama-swap/config.yaml
#      (llama-swap hot-reloads via -watch-config; no restart).
#   4. Verifies the model is gone from the live API and the reload was clean.
#   5. (--purge) deletes the GGUF from ~/.cache/llama.cpp and its sidecar.
#
# Safety:
#   * Refuses if the model is not present in the repo config.
#   * --dry-run prints the plan and changes nothing.
#   * --purge only deletes files under ~/.cache/llama.cpp (never a local path).
#   * Confirms unless --yes is given.
#
# Usage:
#   ./remove-model.sh <model-id> [--purge] [--dry-run] [--yes]
# Example:
#   ./remove-model.sh nero-tron-30b-q4-k-m --purge
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_CFG="$SCRIPT_DIR/llama-swap-config.yaml"
LIVE_CFG="/etc/llama-swap/config.yaml"
CACHE_DIR="${GGUF_CACHE:-$HOME/.cache/llama.cpp}"
METADATA_DIR="$SCRIPT_DIR/model-metadata"
TS="$(date +%Y%m%d%H%M%S)"

MODEL_ID=""
PURGE=0
DRY=0
YES=0
for a in "$@"; do
  case "$a" in
    --purge) PURGE=1;;
    --dry-run) DRY=1;;
    --yes|-y) YES=1;;
    -*) echo "unknown option: $a" >&2; exit 2;;
    *) MODEL_ID="$a";;
  esac
done
[[ -n "$MODEL_ID" ]] || { echo "usage: $0 <model-id> [--purge] [--dry-run] [--yes]" >&2; exit 2; }
[[ -f "$REPO_CFG" ]] || { echo "repo config not found: $REPO_CFG" >&2; exit 1; }

ok(){ printf '[OK]   %s\n' "$*"; }
err(){ printf '[ERR]  %s\n' "$*" >&2; }
warn(){ printf '[!!]  %s\n' "$*" >&2; }
info(){ printf '[..]  %s\n' "$*"; }

# --- presence check -------------------------------------------------------
if ! grep -qE "^  \"$MODEL_ID\":|^\s*-\s*\"$MODEL_ID\"" "$REPO_CFG"; then
  err "model '$MODEL_ID' not found in $REPO_CFG (models: map or groups:)."
  exit 1
fi
info "found '$MODEL_ID' in repo config."

# --- live API state (informational) ---------------------------------------
LIVE_PRESENT=0
if curl -s --max-time 8 http://127.0.0.1:8080/v1/models >/dev/null 2>&1; then
  if curl -s --max-time 8 http://127.0.0.1:8080/v1/models 2>/dev/null \
     | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if any('$MODEL_ID' in m['id'] for m in d.get('data',[])) else 1)" 2>/dev/null; then
    LIVE_PRESENT=1
    warn "'$MODEL_ID' is currently listed by the live API (it will be unloaded on reload)."
  fi
fi

# --- plan / confirm -------------------------------------------------------
info "plan: remove '$MODEL_ID' from models: and any group membership in $REPO_CFG"
[[ "$PURGE" -eq 1 ]] && info "plan: --purge will also delete the GGUF + sidecar under $CACHE_DIR"
if [[ "$DRY" -eq 1 ]]; then
  ok "dry-run: no changes made."
  # show what would be removed
  echo "--- models: block that would be removed (if any) ---"
  awk -v id="$MODEL_ID" '/^  "[^"]*":/{ if($0 ~ "^  \""id"\":"){d=1;next} d=0 } d{print}' "$REPO_CFG" || true
  echo "--- group membership lines that would be removed ---"
  grep -nE "^\s*-\s*\"$MODEL_ID\"" "$REPO_CFG" || echo "(none)"
  exit 0
fi

if [[ "$YES" -ne 1 ]]; then
  read -r -p "Remove '$MODEL_ID'? [y/N] " ans
  [[ "$ans" == y || "$ans" == Y ]] || { info "aborted."; exit 0; }
fi

# --- backups (hard rule) --------------------------------------------------
cp "$REPO_CFG" "${REPO_CFG}.bak.$TS"
ok "backed up repo config -> ${REPO_CFG}.bak.$TS"
if [[ -f "$LIVE_CFG" ]]; then
  sudo cp "$LIVE_CFG" "${LIVE_CFG}.bak.$TS"
  ok "backed up live config -> ${LIVE_CFG}.bak.$TS"
fi

# --- edit repo config: drop models: entry + group memberships ------------
# models: block: from the `  "ID":` line through its continuation (indent >2)
# until the next top-level `  "...":` entry or EOF.
awk -v id="$MODEL_ID" '
/^  "[^"]*":/ {
  if ($0 ~ "^  \"" id "\":") { d=1; next }
  d=0
}
d { next }
{ print }
' "$REPO_CFG" > "${REPO_CFG}.tmp" && mv "${REPO_CFG}.tmp" "$REPO_CFG"
# group memberships: block-style list items `    - "ID"`
sed -i -E "/^[[:space:]]*-[[:space:]]*\"$MODEL_ID\"[[:space:]]*$/d" "$REPO_CFG"
ok "removed '$MODEL_ID' from repo config."

# --- validate edited config ----------------------------------------------
if ! python3 -c "import yaml,sys;yaml.safe_load(open('$REPO_CFG'))" 2>/dev/null; then
  err "edited config failed YAML parse — restoring backup."
  mv "${REPO_CFG}.bak.$TS" "$REPO_CFG"
  exit 1
fi
if grep -qE "^  \"$MODEL_ID\":|^\s*-\s*\"$MODEL_ID\"" "$REPO_CFG"; then
  err "removal verification failed — '$MODEL_ID' still present. Restoring backup."
  mv "${REPO_CFG}.bak.$TS" "$REPO_CFG"
  exit 1
fi
ok "removal: '$MODEL_ID' confirmed absent from edited repo config."

# --- optional purge -------------------------------------------------------
if [[ "$PURGE" -eq 1 ]]; then
  GGUF="$(grep -oE "$CACHE_DIR/[^ \"'\']+\.gguf" "$REPO_CFG.bak.$TS" | head -1 || true)"
  # derive from the backup we just made (pre-removal) so we read the --model path
  if [[ -n "$GGUF" && "$GGUF" == "$CACHE_DIR"/* ]]; then
    rm -f "$GGUF" && ok "purged GGUF: $GGUF" || warn "could not delete GGUF: $GGUF"
  else
    warn "no GGUF path under $CACHE_DIR derived; skipping file delete."
  fi
  SIDECAR="$METADATA_DIR/$MODEL_ID.json"
  [[ -f "$SIDECAR" ]] && { rm -f "$SIDECAR" && ok "purged sidecar: $SIDECAR" || warn "could not delete sidecar"; }
fi

# --- deploy to live (hot reload) ------------------------------------------
sudo cp "$REPO_CFG" "$LIVE_CFG" && ok "deployed repo config to $LIVE_CFG (hot reload)"
sleep 3

# --- verify live ----------------------------------------------------------
if curl -s --max-time 8 http://127.0.0.1:8080/v1/models >/dev/null 2>&1; then
  if curl -s --max-time 8 http://127.0.0.1:8080/v1/models 2>/dev/null \
     | python3 -c "import sys,json;d=json.load(sys.stdin);sys.exit(0 if not any('$MODEL_ID' in m['id'] for m in d.get('data',[])) else 1)" 2>/dev/null; then
    ok "verified: '$MODEL_ID' absent from live API."
  else
    err "verified FAILED: '$MODEL_ID' still in live API after reload."
  fi
  if sudo journalctl -u llama-swap --since -30s 2>/dev/null | grep -iE 'error|fail|no model config' | grep -viE 'reloading|reloaded' >/dev/null; then
    err "llama-swap reload reported errors (see: sudo journalctl -u llama-swap)"
  else
    ok "llama-swap reload clean."
  fi
else
  warn "live API not reachable; could not verify (config still deployed)."
fi

ok "done. Backup retained: ${REPO_CFG}.bak.$TS"
