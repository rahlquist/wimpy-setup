#!/usr/bin/env bash
# fetch-model.sh test harness
# Behavior tests for fetch-model.sh.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
REPO_DIR="$PWD"
STUBS="$REPO_DIR/tests/stubs"
SCRIPT="$REPO_DIR/fetch-model.sh"

PASS=0; FAIL=0; TOTAL=0

plan()   { echo; echo "=== $* ==="; }
ok()     { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo "  [OK] $*"; }
fail()   { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  [FAIL] $*"; }
check_exit() { local d="$1" w="$2" g="$3"
  if [[ "$g" -eq "$w" ]]; then ok "$d (exit=$g)"; else fail "$d (want exit=$w, got $g)"; fi; }
check_contains() { local d="$1" n="$2" h="$3"
  if echo "$h" | grep -qF "$n"; then ok "$d"; else fail "$d (expected: '$n')"; fi; }

make_td() {
  local td="$(mktemp -d)"
  cp "$REPO_DIR/llama-swap-config.yaml" "$td/llama-swap-config.yaml"
  mkdir -p "$td/model-metadata"
  printf '%s' "$td"
}

# invoke fetch-model.sh with stubs on PATH, isolated sandbox
run_fetch() {
  local td="$1"; shift
  env \
    DOSSIER_DIR="$td" \
    FIXTURES="$REPO_DIR/tests/fixtures" \
    HF_STUB_FIXTURE="${HF_STUB_FIXTURE:-tiny}" \
    LLAMA_SERVER="$STUBS/llama-server" \
    LLAMA_SWAP_CONFIG="$td/llama-swap-config.yaml" \
    MODEL_METADATA_DIR="$td/model-metadata" \
    INVENTORY_PATH="$td/model-inventory.html" \
    MODELS_DIR="$td/models" \
    SMOKE_PORT=$((19191 + (RANDOM % 1000))) \
    DEPLOY_HELPER=/bin/false \
    MMPROJ_RESOLVER="$STUBS/mmproj-resolver" \
    HF_STUB_LOG="$td/hf.calls" \
    PATH="$STUBS:$PATH" \
    bash "$SCRIPT" "$@"
}

# ── First: verify the stub server works in isolation ──
plan "STUB SANITY CHECK"
python3 -c "
import subprocess, time, urllib.request, os, signal
p = subprocess.Popen(
    ['$STUBS/llama-server', '--port', '19555'],
    stderr=subprocess.DEVNULL, stdout=subprocess.DEVNULL
)
time.sleep(0.5)
try:
    r = urllib.request.urlopen('http://127.0.0.1:19555/health', timeout=3)
    body = r.read().decode()
    import json
    assert r.status == 200 and 'ok' in body, f'health: {r.status} {body}'
    r = urllib.request.urlopen(
        'http://127.0.0.1:19555/completion', data=b'{}', timeout=3
    )
    body = r.read().decode()
    d = json.loads(body)
    assert r.status == 200 and d.get('content') == 'OK.', f'completion: {r.status} {body}'
    print('  [OK] stub server health+completion')
except Exception as e:
    print(f'  [FAIL] stub server error: {e}')
finally:
    p.send_signal(signal.SIGTERM)
    p.wait(timeout=3)
"

# ── characterization tests ──
plan "BEHAVIOR: HF paste forms"

# T1: Quoted HF download paste
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y 'hf download hf://user/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T1: quoted HF paste exits 0" 0 "$rc"
check_contains "T1: repo user/repo" "user/repo" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T1: acquired file present" || fail "T1: file missing"
rm -rf "$td"

# T2: Unquoted HF download form
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y hf download 'hf://owner/repo/file.gguf' 2>&1)" || rc=$?
check_exit "T2: unquoted HF exits 0" 0 "$rc"
check_contains "T2: repo owner/repo" "owner/repo" "$OUT"
rm -rf "$td"

# T3: MoE fixture + trailing --n-cpu-moe count
td="$(make_td)"; rc=0; OUT="$(HF_STUB_FIXTURE=moe run_fetch "$td" -y 'hf://owner/repo/moe.gguf 4' 2>&1)" || rc=$?
check_exit "T3: MoE + --n-cpu-moe 4 exits 0" 0 "$rc"
check_contains "T3: cpu-moe in output" "cpu" "$OUT"
rm -rf "$td"

# T3b: Nested HF file paths use the remote path for hf but a flat local name.
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/quantize/gguf/model.gguf' 2>&1)" || rc=$?
check_exit "T3b: nested HF path exits 0" 0 "$rc"
grep -qF 'download owner/repo quantize/gguf/model.gguf' "$td/hf.calls" && ok "T3b: nested remote path passed to hf" || fail "T3b: nested remote path not passed to hf"
[[ -f "$td/models/model.gguf" ]] && ok "T3b: flat local model file present" || fail "T3b: flat local model file missing"
[[ ! -e "$td/models/quantize/gguf/model.gguf" ]] && ok "T3b: nested local path not created" || fail "T3b: nested local path was created"
rm -rf "$td"

# T4: Duplicate registration (same spec twice)
td="$(make_td)"
run_fetch "$td" -y 'hf://owner/repo/model.gguf' >/dev/null 2>&1 || true
rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
# Script now idempotent — consistent re-registration exits 0
check_exit "T4: duplicate exits 0 (idempotent)" 0 "$rc"
check_contains "T4: sidecar already exists msg" "already registered" "$OUT"
rm -rf "$td"

# T5: Low native context should be accepted and forced to the Hermes 64000 compatibility context
td="$(make_td)"; rc=0; OUT="$(HF_STUB_FIXTURE=lowctx run_fetch "$td" -y --no-deploy 'hf://owner/repo/low.gguf' 2>&1)" || rc=$?
check_exit "T5: low ctx exits 0" 0 "$rc"
check_contains "T5: native context detected" "native context" "$OUT"
check_contains "T5: Hermes compatibility context" "64000" "$OUT"
grep -qF -- '--ctx-size 64000' "$td/llama-swap-config.yaml" && ok "T5: low ctx registered with --ctx-size 64000" || fail "T5: low ctx missing --ctx-size 64000"
rm -rf "$td"

# T6: Non-MoE model + --n-cpu-moe dies
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y 'hf://owner/repo/model.gguf 4' 2>&1)" || rc=$?
check_exit "T6: non-MoE + --n-cpu-moe exits non-zero" 1 "$rc"
check_contains "T6: says not an MoE" "not an MoE" "$OUT"
rm -rf "$td"

# T7: Bad spec exits 1 with helpful message
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y 'not-a-spec' 2>&1)" || rc=$?
check_exit "T7: invalid spec exits 1" 1 "$rc"
check_contains "T7: unsupported message" "unsupported" "$OUT"
rm -rf "$td"

# T8: --no-register with --no-smoke (acquire+inspect only)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-register --no-smoke 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T8: --no-register exits 0" 0 "$rc"
check_contains "T8: shows 'skipped'" "skipped" "$OUT"
check_contains "T8: file shown" "model.gguf" "$OUT"
rm -rf "$td"

# T9: Full smoke+register with stub server (port collision handled by randomized SMOKE_PORT)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T9: full smoke+register exits 0" 0 "$rc"
check_contains "T9: healthy message" "healthy" "$OUT"
check_contains "T9: registered message" "registered" "$OUT"
rm -rf "$td"

# T10: --no-smoke (acquire+inspect, no register)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-smoke --no-register 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T10: no-smoke+no-register exits 0" 0 "$rc"
[[ -f "$td/models/model.gguf" ]] && ok "T10: model file present" || fail "T10: model file missing"
rm -rf "$td"

# ── URL/LOCAL/DOSSIER COVERAGE (T11-T19) ──

# T11: URL-class acquisition via curl stub
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-smoke --no-register 'https://example.com/path/model.gguf' 2>&1)" || rc=$?
check_exit "T11: URL acquisition exits 0" 0 "$rc"
check_contains "T11: source class" "url" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T11: model file present" || fail "T11: model file missing"
rm -rf "$td"

# T12: Local-file acquisition + default cleanup (source removed after success)
td="$(make_td)"; cp "$REPO_DIR/tests/fixtures/tiny.gguf" "$td/model.gguf"
rc=0; OUT="$(run_fetch "$td" -y --no-smoke --no-register "$td/model.gguf" 2>&1)" || rc=$?
check_exit "T12: local acquisition exits 0" 0 "$rc"
[[ -f "$td/models/model.gguf" ]] && ok "T12: model file present" || fail "T12: model file missing"
[[ ! -e "$td/model.gguf" ]] && ok "T12: local source removed after success" || fail "T12: local source still exists"
rm -rf "$td"

# T13: Canonical HF URL (resolve/main) — HIGH RISK parser regression
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-smoke --no-register 'https://huggingface.co/owner/repo/resolve/main/model.gguf' 2>&1)" || rc=$?
check_exit "T13: canonical HF URL exits 0" 0 "$rc"
check_contains "T13: resolved owner/repo" "owner/repo" "$OUT"
check_contains "T13: file is model.gguf" "model.gguf" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T13: model file present" || fail "T13: model file missing"
rm -rf "$td"

# T14: --keep-source preserves local source
td="$(make_td)"; cp "$REPO_DIR/tests/fixtures/tiny.gguf" "$td/model.gguf"
rc=0; OUT="$(run_fetch "$td" -y --no-smoke --no-register --keep-source "$td/model.gguf" 2>&1)" || rc=$?
check_exit "T14: keep-source exits 0" 0 "$rc"
[[ -f "$td/models/model.gguf" ]] && ok "T14: model file present" || fail "T14: model file missing"
[[ -f "$td/model.gguf" ]] && ok "T14: local source preserved" || fail "T14: local source removed despite --keep-source"
rm -rf "$td"

# T15: Mid-stage failure dossier (smoke failure) — verify STAGE + resume in content
td="$(make_td)"; rc=0
OUT="$(SMOKE_TRIES=3 LLAMA_SERVER_HEALTH_FAIL=1 run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T15: smoke failure exits non-zero" 1 "$rc"
check_contains "T15: dossier msg" "Wrote recovery dossier" "$OUT"
dossier="$(ls "$td"/fetch-model-*.dossier.md 2>/dev/null | head -1 || true)"
[[ -f "$dossier" ]] && ok "T15: dossier file created" || fail "T15: no dossier file found"
grep -qF 'STAGE:' "$dossier" && ok "T15: dossier contains STAGE" || fail "T15: dossier missing STAGE field"
grep -qF '## Resume command' "$dossier" && ok "T15: dossier has resume command" || fail "T15: dossier missing resume section"
grep -qF '## Smoke test log' "$dossier" && ok "T15: dossier captures smoke log" || fail "T15: dossier missing smoke log"
rm -rf "$td"

# T16: No dossier on classify failure
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y 'not-a-spec' 2>&1)" || rc=$?
check_exit "T16: classify failure exits 1" 1 "$rc"
[[ -z "$(ls "$td"/fetch-model-*.dossier.md 2>/dev/null)" ]] && ok "T16: no dossier on classify failure" || fail "T16: unexpected dossier"
rm -rf "$td"

# T17: Name collision (same NAME, different repo/file in sidecar)
td="$(make_td)"; mkdir -p "$td/model-metadata"
printf '{"filename":"different.gguf","repository":"other/repo"}\n' > "$td/model-metadata/model.json"
config_hash="$(md5sum "$td/llama-swap-config.yaml" 2>/dev/null | awk '{print $1}')"
rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T17: name collision exits 1" 1 "$rc"
check_contains "T17: name collision msg" "name collision" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T17: model file still present" || fail "T17: model file removed"
new_hash="$(md5sum "$td/llama-swap-config.yaml" 2>/dev/null | awk '{print $1}')"
[[ "$config_hash" == "$new_hash" ]] && ok "T17: config untouched" || fail "T17: config was modified"
rm -rf "$td"

# T18: Idempotent re-registration
td="$(make_td)"; rc=0
OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T18: first registration exits 0" 0 "$rc"
rc2=0; OUT2="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc2=$?
check_exit "T18: second registration exits 0" 0 "$rc2"
check_contains "T18: already registered msg" "already registered" "$OUT2"
rm -rf "$td"

# T19: Acquisition failure cleanup (no partial model, no temp dirs)
td="$(make_td)"; rc=0
OUT="$(MAX_RETRIES=1 HF_STUB_FAIL=1 run_fetch "$td" -y 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T19: acquisition failure exits non-zero" 1 "$rc"
[[ -z "$(ls -A "$td/models" 2>/dev/null)" ]] && ok "T19: no files left in models dir" || fail "T19: files left in models dir"
[[ -z "$(find "$td/models" -maxdepth 1 -type d -name '.fetch.*' -print -quit 2>/dev/null)" ]] && ok "T19: no temp dirs left" || fail "T19: temp acquisition dir left behind"
rm -rf "$td"

# ─────────────────────────────────────────────────
echo; echo "========================================"
echo " $TOTAL tests: $PASS passed, $FAIL failed"
echo "========================================"
[[ $FAIL -eq 0 ]] || exit 1
