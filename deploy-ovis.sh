#!/usr/bin/env bash
set -euo pipefail

HOST="Wimpy"
LOCAL_CONFIG="$HOME/wimpy-setup/llama-swap-config.yaml"
REMOTE_CONFIG="/home/rahlquist/wimpy-setup/llama-swap-config.yaml"
LIVE_CONFIG="/etc/llama-swap/config.yaml"

[[ -f "$LOCAL_CONFIG" ]] || {
  printf 'ERROR: missing %s\n' "$LOCAL_CONFIG" >&2
  exit 1
}

printf '[1/4] Uploading corrected source config to %s...\n' "$HOST"
scp "$LOCAL_CONFIG" "$HOST:$REMOTE_CONFIG"

printf '[2/4] Deploying config on %s...\n' "$HOST"
ssh "$HOST" bash -s -- "$REMOTE_CONFIG" "$LIVE_CONFIG" <<'REMOTE'
set -euo pipefail

SOURCE_CONFIG="$1"
LIVE_CONFIG="$2"
BACKUP="${LIVE_CONFIG}.$(date +%Y%m%d%H%M%S).bak"

sudo cp "$LIVE_CONFIG" "$BACKUP"
sudo cp "$SOURCE_CONFIG" "$LIVE_CONFIG"

printf 'Backup: %s\n' "$BACKUP"
REMOTE

printf '[3/4] Waiting for llama-swap to reload...\n'
sleep 3

printf '[4/4] Verifying both model registrations through %s...\n' "$HOST"
result="$(
  curl -fsS "http://${HOST}:8080/v1/models" |
  python3 -c '
import json
import sys

ids = {model["id"] for model in json.load(sys.stdin)["data"]}
checks = {
    "ovisocr2-f16": "ovisocr2-f16" in ids,
    "ovisocr2-f16-cuda": "ovisocr2-f16-cuda" in ids,
}

for name, present in checks.items():
    print(f"{name}: {present}")

if not all(checks.values()):
    raise SystemExit(1)
'
)"

printf '%s\n' "$result"
printf 'Deployment verified successfully.\n'
