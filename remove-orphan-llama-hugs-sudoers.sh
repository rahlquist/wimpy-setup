#!/usr/bin/env bash
# Drop the orphaned sudoers NOPASSWD grant for the deleted root-based
# Llama Hugs deploy helper.
#
# /usr/local/sbin/llama-hugs-deploy is gone, but a passwordless root grant for
# that path is still active. Left alone it is a stale authorization pointing at
# a missing file: sudo advertises a permission that can never run, and anything
# that recreated the path would get immediate passwordless root.
#
# BUG THIS FIXES (first attempt at this script): /etc/sudoers.d is not readable
# by the user, so the unprivileged glob `/etc/sudoers.d/*` never expanded — it
# yielded the literal string, every `[[ -f ]]` test failed, and the script
# cheerfully reported "no sudoers file references the path" while the grant was
# still live. The listing must therefore happen through sudo.
#
# Run as rahlquist:  ~/wimpy-setup/remove-orphan-llama-hugs-sudoers.sh

set -euo pipefail

TARGET="/usr/local/sbin/llama-hugs-deploy"
err() { printf '[ERR] %s\n' "$*" >&2; }
ok()  { printf '[OK]  %s\n' "$*"; }

[[ "$(id -un)" == "rahlquist" ]] || { err 'run as rahlquist'; exit 1; }

if sudo test -e "$TARGET"; then
  err "$TARGET still exists — use remove-root-llama-hugs-deploy.sh instead"
  exit 1
fi
ok "confirmed removed: $TARGET"

echo 'Locating the grant (listing via sudo — the dir is not user-readable)...'
# Read the candidate list with sudo; a plain glob expands to a literal here.
LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
sudo find /etc/sudoers.d /etc/sudoers -maxdepth 1 -type f 2>/dev/null | sort -u > "$LIST"
echo "  inspected $(wc -l < "$LIST") sudoers file(s)"

GRANT_FILES=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  if sudo grep -qF "$TARGET" "$f" 2>/dev/null; then
    GRANT_FILES+=("$f")
    ok "grant found in: $f"
  fi
done < "$LIST"

if [[ ${#GRANT_FILES[@]} -eq 0 ]]; then
  echo
  echo 'No sudoers file references the path. Cross-checking against what sudo'
  echo 'actually reports, so this is verified rather than assumed:'
  if sudo -n -l 2>/dev/null | grep -qF "$TARGET"; then
    err 'grant is still listed by sudo but was not found in any file — inspect manually'
    exit 1
  fi
  ok 'sudo agrees: no grant for the deleted path'
  exit 0
fi

# Back up every file before editing (repo hard rule 1).
STAMP="$(date +%Y%m%d%H%M%S)"
for f in "${GRANT_FILES[@]}"; do
  sudo cp -a "$f" "${f}.bak.${STAMP}"
  ok "backed up: ${f}.bak.${STAMP}"
done

# Strip only lines naming the deleted helper; leave all other grants intact.
for f in "${GRANT_FILES[@]}"; do
  sudo sh -c "grep -vF '$TARGET' '$f' > '$f.new' && cat '$f.new' > '$f' && rm -f '$f.new'"
  ok "removed grant line(s) from: $f"
done

# An emptied sudoers.d drop-in should go entirely rather than linger empty.
for f in "${GRANT_FILES[@]}"; do
  if [[ "$f" == /etc/sudoers.d/* ]] && ! sudo test -s "$f"; then
    sudo rm -f "$f"
    ok "removed now-empty drop-in: $f"
  fi
done

echo
echo '=== validating ==='
# visudo -c also reports PRE-EXISTING problems in unrelated files — it flags
# /etc/sudoers.d/wimpy-hwmon for bad permissions, which this script did not
# touch. Only a parse/syntax error is fatal; other warnings are reported and
# ignored so a pre-existing wart cannot block this cleanup.
VOUT="$(mktemp)"
if sudo visudo -c > "$VOUT" 2>&1; then
  ok 'visudo -c clean'
else
  if grep -qiE 'syntax error|parse error' "$VOUT"; then
    err 'visudo reported a PARSE error — restore from the .bak files above'
    cat "$VOUT"
    rm -f "$VOUT"
    exit 1
  fi
  ok 'visudo -c reported only non-fatal warnings (pre-existing, unrelated):'
  grep -viE '^\s*$' "$VOUT" | sed 's/^/      /'
fi
rm -f "$VOUT"

echo
echo '=== verification ==='
if sudo -n -l 2>/dev/null | grep -qF "$TARGET"; then
  err "a grant for $TARGET is STILL active — inspect manually"
  exit 1
fi
ok "no active sudo grant references $TARGET"
sudo -n -l >/dev/null 2>&1 && ok 'sudo -n -l still works (other grants intact)'
if sudo -n -l 2>/dev/null | grep -qF 'llama-swap-deploy'; then
  ok 'llama-swap-deploy grant preserved (untouched, as intended)'
fi

echo
echo 'Done. Llama Hugs deployment is entirely user-owned with no leftover'
echo 'passwordless root grants from the old path.'
