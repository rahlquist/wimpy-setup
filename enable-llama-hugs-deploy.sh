#!/usr/bin/env bash
set -euo pipefail

HELPER="/usr/local/sbin/llama-hugs-deploy"
SUDOERS="/etc/sudoers.d/llama-hugs-deploy"
USER_NAME="$(id -un)"

if [[ "$USER_NAME" != "rahlquist" ]]; then
    echo "Run this as rahlquist, not root or another user." >&2
    exit 1
fi

echo "Checking deployment helper..."
sudo test -f "$HELPER"
sudo chown root:root "$HELPER"
sudo chmod 0755 "$HELPER"

# Ensure every directory in the helper path is root-owned and not
# writable by the deploying user.
sudo namei -l "$HELPER"

echo "Installing narrow sudoers rule..."
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

printf '%s\n' \
  'rahlquist ALL=(root) NOPASSWD: /usr/local/sbin/llama-hugs-deploy' \
  > "$TMP"

sudo install -o root -g root -m 0440 "$TMP" "$SUDOERS"

echo "Validating sudoers configuration..."
sudo visudo -c

echo "Checking effective permission..."
if ! sudo -n -l | grep -Fq \
  '/usr/local/sbin/llama-hugs-deploy'; then
    echo "The narrow sudo permission was not found." >&2
    exit 1
fi

echo "Testing the permitted helper..."
sudo -n "$HELPER"

echo "Verifying service health..."
systemctl is-active --quiet llama-hugs
curl --fail --silent --show-error \
  http://127.0.0.1:8080/health
printf '\n'

echo
echo "Narrow passwordless access is configured."
echo "Permitted command:"
echo "  sudo -n $HELPER"
echo
echo "The following commands remain outside this rule:"
echo "  sudo -n /bin/bash"
echo "  sudo -n systemctl restart llama-hugs"
echo "  sudo -n /usr/bin/install"
