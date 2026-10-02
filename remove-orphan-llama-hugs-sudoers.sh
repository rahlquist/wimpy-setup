#!/usr/bin/env bash
# Remove the now-orphaned sudoers NOPASSWD grant for the deleted root-based
# Llama Hugs deploy helper.
#
# /usr/local/sbin/llama-hugs-deploy has already been deleted, but a
# passwordless root grant for that path is still active. Left alone it is a
# stale rule pointing at a missing file: sudoers shows an authorization that
# can never run, and if anything ever recreated that path it would be
# immediately passwordless root.
#
# Finds the grant wherever it actually lives (main sudoers or any sudoers.d
# drop-in), edits only that one line, validates with visudo, and verifies.
#
# Run as rahlquist:  bash remove-orphan-llama-hugs-sudoers.sh

set -euo pipefail

TARGET="/usr/local/sbin/llama-hugs-deploy"
err() { printf '[ERR] %s\n' "$*" >&2; }
ok()  { printf '[OK]  %s\n' "$*"; }

[[ "$(id -un)" == "rahlquist" ]] || { err 'run as rahlquist'; exit 1; }

# The helper itself must already be gone, or this is the wrong script.
if sudo test -e "$TARGET"; then
  err "$TARGET still exists — use remove-root-llama-hugs-deploy.sh instead"
  exit 1
fi
ok "confirmed removed: $TARGET"

echo 'Locating the grant...'
CANDIDATES=(/etc/sudoers.d/* /etc/sudoers)
GRANT_FILES=()
for f in "${CANDIDATES[@]}"; do
  [[ -f "$f" ]] || continue
  if sudo grep -qF "$TARGET" "$f" 2>/dev/null; then
    GRANT_FILES+=("$f")
    ok "grant found in: $f"
  fi
done

if [[ ${#GRANT_FILES[@]} -eq 0 ]]; then
  ok 'no sudoers file references the path; nothing left to remove'
else
  # Back up every file we touch before editing (repo hard rule 1).
  STAMP="$(date +%Y%m%d%H%M%S)"
  for f in "${GRANT_FILES[@]}"; do
    sudo cp -a "$f" "${f}.bak.${STAMP}"
    ok "backed up: ${f}.bak.${STAMP}"
  done

  # Strip only lines naming the deleted helper; leave every other grant alone.
  for f in "${GRANT_FILES[@]}"; do
    sudo tee "$f" >/dev/null < <(sudo grep -vF "$TARGET" "$f" || true)
    ok "removed grant line from: $f"
  done

  # A sudoers.d drop-in that is now empty should be removed entirely, or
  # sudo reads an empty file pointlessly.
  for f in "${GRANT_FILES[@]}"; do
    if [[ "$f" == /etc/sudoers.d/* ]]; then
      if [[ ! -s "$f" ]]; then
        sudo rm -f "$f"
        ok "removed now-empty drop-in: $f"
      else
        remaining="$(sudo grep -cvE '^\s*(#|$)' "$f" || true)"
        ok "kept $f (${remaining} active rule(s) remain)"
      fi
    fi
  done
fi

# Validate before declaring success — an invalid sudoers file locks out sudo.
echo
echo '=== validating ==='
if ! sudo visudo -c; then
  err 'visudo -c FAILED — restore from the .bak files printed above'
  exit 1
fi
ok 'visudo -c passes'

echo
echo '=== verification ==='
if sudo -n -l 2>/dev/null | grep -qF "$TARGET"; then
  err "a grant for $TARGET is STILL active — inspect manually"
  exit 1
fi
ok "no active sudo grant references $TARGET"
sudo -n -l >/dev/null 2>&1 && ok 'sudo -n -l still works (other grants intact)'

echo
echo 'Done. Llama Hugs deployment is now entirely user-owned, with no'
echo 'passwordless root grants left over from the old path.'
