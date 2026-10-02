#!/usr/bin/env bash
# Remove the superseded root-based Llama Hugs deploy helper.
#
# Background: llama-hugs now runs as the rahlquist USER service with its config
# at ~/.config/llama-hugs/config.yaml. Deployment is done by the user-owned
# tools/llama-hugs-deploy, which needs no sudo. The old root-based helper at
# /usr/local/sbin/llama-hugs-deploy deployed to /etc/llama-hugs/config.yaml and
# is dead weight.
#
# TWO things must be removed together:
#   1. /usr/local/sbin/llama-hugs-deploy      — the stale helper itself
#   2. the sudoers NOPASSWD rule for it       — otherwise the grant survives
#      pointing at a missing file, and sudoers keeps a stale entry that looks
#      authorized but can never run. Verified: nothing in the repo references
#      the root path any more (fetch-model.sh and
#      install-llama-hugs-autodeploy.sh both default to tools/llama-hugs-deploy).
#
# Run as rahlquist:  bash remove-root-llama-hugs-deploy.sh
# It will prompt for your sudo password.

set -euo pipefail

HELPER="/usr/local/sbin/llama-hugs-deploy"
USER_HELPER="$HOME/wimpy-setup/tools/llama-hugs-deploy"
SUDOERS_FILE="/etc/sudoers.d/llama-hugs-deploy"

err() { printf '[ERR] %s\n' "$*" >&2; }
ok()  { printf '[OK]  %s\n' "$*"; }

[[ "$(id -un)" == "rahlquist" ]] || { err 'run as rahlquist'; exit 1; }

# ── Preconditions: never remove the old path until the new one demonstrably works
[[ -x "$USER_HELPER" ]] || { err "user helper missing/not executable: $USER_HELPER"; exit 1; }
systemctl --user is-active --quiet llama-hugs.service \
  || { err 'llama-hugs user service is not active; fix that first'; exit 1; }
curl -fsS --max-time 10 http://127.0.0.1:8080/v1/models >/dev/null \
  || { err 'router API not reachable; refusing to remove the old helper'; exit 1; }
ok 'preconditions met: user deploy path is live and serving'

# Prove the user path can still deploy before we take away the old one.
SOURCE_CONFIG="$HOME/wimpy-setup/llama-hugs-config.yaml" "$USER_HELPER" >/dev/null \
  || { err 'user deploy helper failed; aborting so we do not remove a working path'; exit 1; }
ok 'user deploy helper verified working'

# ── Back up before deleting (per repo hard rule 1)
if sudo test -f "$HELPER"; then
  backup="$HOME/wimpy-setup/removed-root-llama-hugs-deploy-$(date +%Y%m%d%H%M%S).txt"
  sudo cp -a "$HELPER" "$backup"
  ok "backed up old helper to: $backup"
fi

# ── Remove the sudoers grant first, so there is never a window where the
#    passwordless rule exists without its target.
if sudo test -f "$SUDOERS_FILE"; then
  sudo cp -a "$SUDOERS_FILE" "$SUDOERS_FILE.bak.$(date +%Y%m%d%H%M%S)"
  sudo rm -f "$SUDOERS_FILE"
  ok "removed sudoers grant: $SUDOERS_FILE"
else
  ok 'no dedicated sudoers file at the expected path; skipping'
fi
sudo visudo -c >/dev/null 2>&1 || { err 'sudoers validation FAILED after edit'; exit 1; }
ok 'visudo -c passes'

# ── Now remove the helper itself
if sudo test -f "$HELPER"; then
  sudo rm -f "$HELPER"
  ok "removed: $HELPER"
fi

# ── Verify
echo
echo '=== verification ==='
sudo -n -l 2>/dev/null | grep -q "$HELPER" \
  && { err "a sudo grant for $HELPER still exists — inspect manually"; exit 1; }
ok "no sudo grant references $HELPER"
sudo test -e "$HELPER" && { err "$HELPER still exists"; exit 1; }
ok "$HELPER is gone"
systemctl --user is-active --quiet llama-hugs.service \
  && ok 'llama-hugs user service still active'
curl -fsS --max-time 10 http://127.0.0.1:8080/v1/models >/dev/null \
  && ok 'router API still serving'

echo
echo 'Done. Deployment is now entirely user-owned:'
echo "  cd ~/wimpy-setup && SOURCE_CONFIG=llama-hugs-config.yaml ./tools/llama-hugs-deploy"
echo
echo 'Also now dead: enable-llama-hugs-deploy.sh — it exists only to install the'
echo 'sudoers grant and chown the root helper, so it would recreate exactly what'
echo 'was just removed. Delete it, or keep it only as history.'
