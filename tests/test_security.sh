#!/usr/bin/env bash
# Security regression tests for fetch-model diagnostics and CLI fallback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REDACTOR="$ROOT/tools/redact-output.py"
SCRIPT="$ROOT/fetch-model.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

input='BWS_ACCESS_TOKEN=machine-secret HF_TOKEN="hf-secret" GITHUB_TOKEN=gh-secret
Authorization: Bearer bearer-secret
https://user:password@example.test/path?token=query-secret&api_key=key-secret'
printf '%s\n' "$input" | python3 "$REDACTOR" > "$TMP/redacted"

for secret in machine-secret hf-secret gh-secret bearer-secret password query-secret key-secret; do
  if grep -Fq -- "$secret" "$TMP/redacted"; then
    printf 'FAIL: redactor leaked %s\n' "$secret" >&2
    exit 1
  fi
done

grep -Fq '[REDACTED]' "$TMP/redacted"

# Bad input is a usage error, not an interrupted pipeline. It must not create
# a recovery dossier containing the rejected source string.
mkdir -p "$TMP/usage"
if DOSSIER_DIR="$TMP/usage" "$SCRIPT" -y 'not-a-model-spec' > "$TMP/usage.out" 2>&1; then
  printf 'FAIL: invalid input unexpectedly succeeded\n' >&2
  exit 1
fi
if find "$TMP/usage" -type f -name '*.dossier.md' -print -quit | grep -q .; then
  printf 'FAIL: invalid input created a recovery dossier\n' >&2
  exit 1
fi

# A traced invocation must turn tracing off before the script can inspect or
# use any credential-bearing environment. The warning is intentional and the
# help path must still work.
HF_TOKEN='sentinel-that-must-not-appear' bash -x "$SCRIPT" --help > "$TMP/help.out" 2> "$TMP/help.err"
grep -Fq 'shell tracing was enabled; disabled for credential safety' "$TMP/help.err"
if grep -Fq -- 'sentinel-that-must-not-appear' "$TMP/help.out" "$TMP/help.err"; then
  printf 'FAIL: traced fetch-model invocation exposed HF_TOKEN\n' >&2
  exit 1
fi

printf 'PASS: diagnostic redaction and xtrace guard\n'
