#!/usr/bin/env bash
# fetch-model.sh test harness
# Characterization tests against the UNMODIFIED script.
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
    HF_STUB_FIXTURE="${HF_STUB_FIXTURE:-tiny}" \
    LLAMA_SERVER="$STUBS/llama-server" \
    LLAMA_SWAP_CONFIG="$td/llama-swap-config.yaml" \
    MODEL_METADATA_DIR="$td/model-metadata" \
    INVENTORY_PATH="$td/model-inventory.html" \
    MODELS_DIR="$td/models" \
    SMOKE_PORT=$((19191 + (RANDOM % 1000))) \
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
plan "CHARACTERIZATION: HF paste forms"

# T1: Quoted HF download paste
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push 'hf download hf://user/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T1: quoted HF paste exits 0" 0 "$rc"
check_contains "T1: repo user/repo" "user/repo" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T1: acquired file present" || fail "T1: file missing"
rm -rf "$td"

# T2: Unquoted HF download form
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push hf download 'hf://owner/repo/file.gguf' 2>&1)" || rc=$?
check_exit "T2: unquoted HF exits 0" 0 "$rc"
check_contains "T2: repo owner/repo" "owner/repo" "$OUT"
rm -rf "$td"

# T3: MoE fixture + trailing --n-cpu-moe count
td="$(make_td)"; rc=0; OUT="$(HF_STUB_FIXTURE=moe run_fetch "$td" -y --no-push 'hf://owner/repo/moe.gguf 4' 2>&1)" || rc=$?
check_exit "T3: MoE + --n-cpu-moe 4 exits 0" 0 "$rc"
check_contains "T3: cpu-moe in output" "cpu" "$OUT"
rm -rf "$td"

# T4: Duplicate registration (same spec twice)
td="$(make_td)"
run_fetch "$td" -y --no-push 'hf://owner/repo/model.gguf' >/dev/null 2>&1 || true
rc=0; OUT="$(run_fetch "$td" -y --no-push 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
# Current behaviour: sidecar guard fires first → exit 1 + "already exists"
check_exit "T4: duplicate exits 1 (current char)" 1 "$rc"
check_contains "T4: sidecar already exists msg" "sidecar" "$OUT"
rm -rf "$td"

# T5: Low native context (<65536) should die
td="$(make_td)"; rc=0; OUT="$(HF_STUB_FIXTURE=lowctx run_fetch "$td" -y --no-push 'hf://owner/repo/low.gguf' 2>&1)" || rc=$?
check_exit "T5: low ctx exits non-zero" 1 "$rc"
check_contains "T5: native context error" "native context" "$OUT"
rm -rf "$td"

# T6: Non-MoE model + --n-cpu-moe dies
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push 'hf://owner/repo/model.gguf 4' 2>&1)" || rc=$?
check_exit "T6: non-MoE + --n-cpu-moe exits non-zero" 1 "$rc"
check_contains "T6: says not an MoE" "not an MoE" "$OUT"
rm -rf "$td"

# T7: Bad spec exits 1 with helpful message
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y 'not-a-spec' 2>&1)" || rc=$?
check_exit "T7: invalid spec exits 1" 1 "$rc"
check_contains "T7: unsupported message" "unsupported" "$OUT"
rm -rf "$td"

# T8: --no-register with --no-smoke (acquire+inspect only)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push --no-register --no-smoke 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T8: --no-register exits 0" 0 "$rc"
check_contains "T8: shows 'skipped'" "skipped" "$OUT"
check_contains "T8: file shown" "model.gguf" "$OUT"
rm -rf "$td"

# T9: Full smoke+register with stub server (port collision handled by randomized SMOKE_PORT)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T9: full smoke+register exits 0" 0 "$rc"
check_contains "T9: healthy message" "healthy" "$OUT"
check_contains "T9: registered message" "registered" "$OUT"
rm -rf "$td"

# T10: --no-smoke (acquire+inspect, no register)
td="$(make_td)"; rc=0; OUT="$(run_fetch "$td" -y --no-push --no-smoke --no-register 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T10: no-smoke+no-register exits 0" 0 "$rc"
[[ -f "$td/models/model.gguf" ]] && ok "T10: model file present" || fail "T10: model file missing"
rm -rf "$td"

# ─────────────────────────────────────────────────
echo; echo "========================================"
echo " $TOTAL tests: $PASS passed, $FAIL failed"
echo "========================================"
[[ $FAIL -eq 0 ]] || exit 1
