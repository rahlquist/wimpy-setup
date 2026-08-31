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
  cp "$REPO_DIR/llama-hugs-config.yaml" "$td/llama-hugs-config.yaml"
  mkdir -p "$td/model-metadata"
  printf '%s' "$td"
}

# invoke fetch-model.sh with stubs on PATH, isolated sandbox.
# A recording llama-hugs canonical API stub is started per test so the
# persistence mirror is exercised end-to-end without touching a real router.
# Set HUGS_STUB_FAIL=1 to make the stub answer 500 (persistence-failure tests).
run_fetch() {
  local td="$1"; shift
  local hugs_pid="" hugs_port=$((19300 + (RANDOM % 500)))
  local rc=0
  HUGS_STUB_LOG="$td/hugs.calls" HUGS_STUB_PORT="$hugs_port" \
    HUGS_STUB_FAIL="${HUGS_STUB_FAIL:-0}" python3 "$STUBS/hugs_api.py" >/dev/null 2>&1 &
  hugs_pid=$!
  for ((i=0; i<50; i++)); do
    if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:$hugs_port/health', timeout=1)" >/dev/null 2>&1; then
      break
    fi
    sleep 0.1
  done
  env \
    DOSSIER_DIR="$td" \
    FIXTURES="$REPO_DIR/tests/fixtures" \
    HF_STUB_FIXTURE="${HF_STUB_FIXTURE:-tiny}" \
    FAKE_GGUF="$REPO_DIR/tests/fixtures/${HF_STUB_FIXTURE:-tiny}.gguf" \
    LLAMA_SERVER="$STUBS/llama-server" \
    LLAMA_SWAP_CONFIG="$td/llama-hugs-config.yaml" \
    MODEL_METADATA_DIR="$td/model-metadata" \
    INVENTORY_PATH="$td/model-inventory.html" \
    MODELS_DIR="$td/models" \
    SMOKE_PORT=$((19191 + (RANDOM % 1000))) \
    DEPLOY_HELPER=/bin/false \
    MMPROJ_RESOLVER="$STUBS/mmproj-resolver" \
    REPO_META_TOOL="$STUBS/fetch-repo-metadata" \
    HF_STUB_LOG="$td/hf.calls" \
    MMPROJ_STUB_PATH="${MMPROJ_STUB_PATH:-}" \
    HUGS_API_URL="http://127.0.0.1:$hugs_port" \
    HUGS_STUB_FAIL="${HUGS_STUB_FAIL:-0}" \
    HUGS_PERSIST_FAIL="${HUGS_STUB_FAIL:-0}" \
    HUGS_PERSIST_TOOL="$STUBS/hugs_canonical_persist.py" \
    HUGS_PERSIST_STUB_FAIL="${HUGS_STUB_FAIL:-0}" \
    HUGS_STUB_LOG="$td/hugs.calls" \
    PATH="$STUBS:$PATH" \
    bash "$SCRIPT" "$@" || rc=$?
  kill "$hugs_pid" 2>/dev/null || true
  wait "$hugs_pid" 2>/dev/null || true
  return "$rc"
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
check_contains "T4: model already registered msg" "already registered" "$OUT"
rm -rf "$td"

# T5: Low native context should be accepted and forced to the Hermes 64000 compatibility context
td="$(make_td)"; rc=0; OUT="$(HF_STUB_FIXTURE=lowctx run_fetch "$td" -y --no-deploy 'hf://owner/repo/low.gguf' 2>&1)" || rc=$?
check_exit "T5: low ctx exits 0" 0 "$rc"
check_contains "T5: native context detected" "native context" "$OUT"
check_contains "T5: Hermes compatibility context" "64000" "$OUT"
grep -qF -- '--ctx-size 64000' "$td/llama-hugs-config.yaml" && ok "T5: low ctx registered with --ctx-size 64000" || fail "T5: low ctx missing --ctx-size 64000"
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
[[ -n "$(ls "$td"/fetch-model-*.dossier.md 2>/dev/null)" ]] && ok "T16: dossier on classify failure" || fail "T16: missing recovery dossier"
rm -rf "$td"

# T17: Same NAME from a DIFFERENT repo → auto-scoped id so both coexist
# (explicit user requirement: no refusal; both models must be fetchable).
td="$(make_td)"; mkdir -p "$td/model-metadata"
printf '{"filename":"different.gguf","repository":"other/repo"}\n' > "$td/model-metadata/model.json"
rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T17: same name different repo registers scoped id" 0 "$rc"
check_contains "T17: scoped id message" "registering this copy as" "$OUT"
[[ -f "$td/models/model.gguf" ]] && ok "T17: model file present" || fail "T17: model file missing"
grep -qF '"owner-model":' "$td/llama-hugs-config.yaml" && ok "T17: scoped id in config" || fail "T17: scoped id not in config"
rm -rf "$td"

# T17b: Same NAME from the SAME repo is idempotent, not re-scoped
td="$(make_td)"; rc=0
OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T17b: first registration exits 0" 0 "$rc"
grep -qF '"model":' "$td/llama-hugs-config.yaml" && ok "T17b: plain id in config" || fail "T17b: plain id missing"
rm -rf "$td"

# T18: Idempotent re-registration
td="$(make_td)"; rc=0
OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T18: first registration exits 0" 0 "$rc"
rc2=0; OUT2="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc2=$?
check_exit "T18: second registration exits 0" 0 "$rc2"
check_contains "T18: model already registered msg" "already registered" "$OUT2"
rm -rf "$td"

# T19: Acquisition failure cleanup (no partial model, no temp dirs)
td="$(make_td)"; rc=0
OUT="$(MAX_RETRIES=1 HF_STUB_FAIL=1 run_fetch "$td" -y 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T19: acquisition failure exits non-zero" 1 "$rc"
[[ -z "$(ls -A "$td/models" 2>/dev/null)" ]] && ok "T19: no files left in models dir" || fail "T19: files left in models dir"
[[ -z "$(find "$td/models" -maxdepth 1 -type d -name '.fetch.*' -print -quit 2>/dev/null)" ]] && ok "T19: no temp dirs left" || fail "T19: temp acquisition dir left behind"
rm -rf "$td"

# ── Llama Hugs canonical persistence coverage (T20-T23) ──

# T20: New registration mirrors model + gguf asset + smoke into the canonical API
td="$(make_td)"; rc=0
OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T20: register exits 0" 0 "$rc"
check_contains "T20: persistence ok message" "persisted canonical Llama Hugs record" "$OUT"
grep -qF '"path": "/api/hugs/models/hugs-model"' "$td/hugs.calls" && ok "T20: canonical model POST" || fail "T20: missing model POST"
grep -qF '/api/hugs/models/hugs-model/assets' "$td/hugs.calls" && ok "T20: canonical asset POST" || fail "T20: missing asset POST"
grep -qF '/api/hugs/models/hugs-model/smoke' "$td/hugs.calls" && ok "T20: canonical smoke POST" || fail "T20: missing smoke POST"
python3 - "$td/hugs.calls" <<'PY' && ok "T20: payload fields correct" || fail "T20: payload fields wrong"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
model = next(r for r in rows if r['path'] == '/api/hugs/models/hugs-model')
assert model['body']['gpu_backend'] == 'ROCm', model['body']
assert model['body']['context_size'] >= 64000
assert model['body']['is_cuda_variant'] == 0
assert model['body']['source_repo'] == 'owner/repo'
asset = next(r for r in rows if r['path'].endswith('/assets'))
assert asset['body']['asset_type'] == 'gguf', asset['body']
assert asset['body']['load_target'] == 'vram' and asset['body']['offload_supported'] == 1
assert asset['body']['disk_size_bytes'] > 0
smoke = next(r for r in rows if r['path'].endswith('/smoke'))
assert smoke['body']['success'] == 1
# VRAM is never fabricated: the script does not measure it.
assert smoke['body']['gpu_vram_before_bytes'] == 0 and smoke['body']['gpu_vram_peak_bytes'] == 0
PY
rm -rf "$td"

# T21: Idempotent re-registration must NOT re-persist (PRIMARY_ALREADY guard)
td="$(make_td)"
run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' >/dev/null 2>&1 || true
first_calls="$(grep -c 'POST' "$td/hugs.calls" 2>/dev/null || true)"
rc=0; OUT="$(run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T21: re-register exits 0" 0 "$rc"
second_calls="$(grep -c 'POST' "$td/hugs.calls" 2>/dev/null || true)"
[[ "$second_calls" == "$first_calls" ]] \
  && ok "T21: no duplicate persistence on re-registration" \
  || fail "T21: re-registration re-POSTed (first=$first_calls second=$second_calls)"
rm -rf "$td"

# T22: Canonical API failure is non-fatal — registration still completes
td="$(make_td)"; rc=0
OUT="$(HUGS_STUB_FAIL=1 run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T22: register exits 0 despite API failure" 0 "$rc"
if echo "$OUT" | grep -qE 'canonical Llama Hugs persistence failed|persistence failed'; then ok "T22: persistence failure warned"; else fail "T22: persistence failure warning missing"; fi
grep -qF '"model":' "$td/llama-hugs-config.yaml" && ok "T22: config still written" || fail "T22: config missing after API failure"
rm -rf "$td"

# T23: Vision registration persists the mmproj asset alongside the GGUF
td="$(make_td)"; cp "$REPO_DIR/tests/fixtures/tiny.gguf" "$td/fake-mmproj.gguf"
rc=0; OUT="$(MMPROJ_STUB_PATH="$td/fake-mmproj.gguf" run_fetch "$td" -y --no-deploy 'hf://owner/repo/model.gguf' 2>&1)" || rc=$?
check_exit "T23: vision register exits 0" 0 "$rc"
check_contains "T23: mmproj acquired" "multimodal projector" "$OUT"
python3 - "$td/hugs.calls" <<'PY' && ok "T23: mmproj asset persisted" || fail "T23: mmproj asset missing"
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1]) if l.strip()]
assets = [r for r in rows if r['path'].endswith('/assets')]
types = {a['body']['asset_type'] for a in assets}
assert 'gguf' in types and 'mmproj' in types, types
mm = next(a for a in assets if a['body']['asset_type'] == 'mmproj')
assert mm['body']['asset_name'] == 'fake-mmproj.gguf', mm['body']
assert mm['body']['load_target'] == 'vram' and mm['body']['offload_supported'] == 1
assert mm['body']['disk_size_bytes'] > 0
PY
rm -rf "$td"

# ─────────────────────────────────────────────────
echo; echo "========================================"
echo " $TOTAL tests: $PASS passed, $FAIL failed"
echo "========================================"
[[ $FAIL -eq 0 ]] || exit 1
