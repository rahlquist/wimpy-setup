#!/usr/bin/env bash
# Install the user-owned Llama Hugs service and no-sudo deployment path.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG="$SCRIPT_DIR/llama-hugs-config.yaml"
USER_UNIT_SOURCE="$SCRIPT_DIR/llama-hugs.user.service"
USER_UNIT_DIR="$HOME/.config/systemd/user"
USER_UNIT="$USER_UNIT_DIR/llama-hugs.service"
RUNTIME_CONFIG="$HOME/.config/llama-hugs/config.yaml"
DEPLOY_HELPER="$SCRIPT_DIR/tools/llama-hugs-deploy"

err() { printf '[ERR] %s\n' "$*" >&2; }
ok() { printf '[OK]  %s\n' "$*"; }
die() { err "$*"; exit 1; }

[[ "${EUID:-$(id -u)}" -ne 0 ]] || die 'run as rahlquist, not root'
[[ -f "$SOURCE_CONFIG" ]] || die "source config missing: $SOURCE_CONFIG"
[[ -f "$USER_UNIT_SOURCE" ]] || die "user service unit missing: $USER_UNIT_SOURCE"
[[ -x "$DEPLOY_HELPER" ]] || die "user deploy helper missing or not executable: $DEPLOY_HELPER"

if systemctl is-active --quiet llama-hugs.service; then
  die 'system Llama Hugs service is still active; one-time migration step: sudo systemctl disable --now llama-hugs.service, then rerun this script'
fi

linger="$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null || true)"
[[ "$linger" == yes ]] || die 'user lingering is not enabled; one-time admin step required: sudo loginctl enable-linger rahlquist'

mkdir -p -- "$USER_UNIT_DIR" "$(dirname "$RUNTIME_CONFIG")"
if [[ -f "$USER_UNIT" ]]; then
  unit_backup="${USER_UNIT}.bak.$(date +%Y%m%d%H%M%S)"
  cp -p -- "$USER_UNIT" "$unit_backup"
  ok "saved prior user unit: $unit_backup"
fi
install -m 0644 -- "$USER_UNIT_SOURCE" "$USER_UNIT"

systemctl --user daemon-reload
systemctl --user enable llama-hugs.service
SOURCE_CONFIG="$SOURCE_CONFIG" "$DEPLOY_HELPER"
ok 'user Llama Hugs installed; model deployment no longer invokes sudo'
