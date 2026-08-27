#!/usr/bin/env bash
# One-time installation for automatic post-smoke-test llama-hugs deployment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER=/usr/local/sbin/llama-hugs-deploy
SUDOERS=/etc/sudoers.d/llama-hugs-autodeploy
SOURCE="$SCRIPT_DIR/llama-hugs-config.yaml"

[[ "${EUID:-$(id -u)}" -eq 0 ]] || { printf '[ERR] run as root\n' >&2; exit 1; }
[[ -f "$SOURCE" ]] || { printf '[ERR] source config missing: %s\n' "$SOURCE" >&2; exit 1; }
[[ -f "$SCRIPT_DIR/tools/llama-hugs-deploy" ]] || { printf '[ERR] helper file missing: %s/tools/llama-hugs-deploy\n' "$SCRIPT_DIR" >&2; exit 1; }
[[ -f /etc/llama-hugs/config.yaml ]] || { printf '[ERR] live config missing: /etc/llama-hugs/config.yaml\n' >&2; exit 1; }

install -o root -g root -m 0755 "$SCRIPT_DIR/tools/llama-hugs-deploy" "$HELPER"
printf '%s\n' "rahlquist ALL=(root) NOPASSWD: $HELPER" > "$SUDOERS"
chown root:root "$SUDOERS"
chmod 0440 "$SUDOERS"

if command -v visudo >/dev/null 2>&1; then
  visudo -cf "$SUDOERS"
fi

printf '[OK] installed %s\n' "$HELPER"
printf '[OK] installed %s\n' "$SUDOERS"
printf '[OK] test with: sudo -n %s\n' "$HELPER"
