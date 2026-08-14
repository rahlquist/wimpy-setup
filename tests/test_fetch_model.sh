#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/fetch-model.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_contains(){ grep -Fq -- "$2" "$1" || { printf '%s\n' "--- $1 ---" >&2; cat "$1" >&2; fail "missing: $2"; }; }

mkdir -p "$TMP/bin" "$TMP/models"
cat > "$TMP/bin/hf" <<'HF'
#!/usr/bin/env bash
set -euo pipefail
[[ "$1" == download ]]
repo="$2"; file="$3"
[[ "$repo" == "owner/repo-GGUF" ]]
[[ "$file" == "model-Q5_K_M.gguf" || "$file" == "quantize/gguf/model-Q5_K_M.gguf" ]]
local_dir=""
shift 3
while [[ $# -gt 0 ]]; do
  case "$1" in --local-dir) local_dir="$2"; shift 2;; *) shift;; esac
done
dest="$local_dir/$file"
mkdir -p "$(dirname "$dest")"
cp "$FAKE_GGUF" "$dest"
printf '%s\n' "$repo/$file" >> "$HF_CALLS"
HF
chmod +x "$TMP/bin/hf"

cat > "$TMP/bin/llama-server" <<'SERVER'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == --list-devices ]]; then printf 'ROCm0: fake GPU\n'; exit 0; fi
printf '%q ' "$@" > "$LLAMA_CALL"
# Persistent enough for health mock; test skips smoke in this test.
exit 0
SERVER
chmod +x "$TMP/bin/llama-server"

python3 - "$TMP/model-Q5_K_M.gguf" <<'PY'
import struct, sys
# Minimal GGUF v3 with qwen3moe metadata needed by the fetcher.
def s(v):
 b=v.encode(); return struct.pack('<Q',len(b))+b
fields=[
 ('general.architecture', 8, 'qwen3moe'),
 ('qwen3moe.context_length', 4, 262144),
 ('qwen3moe.block_count', 4, 48),
 ('qwen3moe.expert_count', 4, 128),
 ('qwen3moe.expert_used_count', 4, 8),
 ('general.description', 8, 'A test MoE model'),
]
out=bytearray(b'GGUF'+struct.pack('<IQQ',3,0,len(fields)))
for k,t,v in fields:
 out+=s(k)+struct.pack('<I',t)
 out+=s(v) if t==8 else struct.pack('<I',v)
open(sys.argv[1],'wb').write(out)
PY

cat > "$TMP/config.yaml" <<'YAML'
healthCheckTimeout: 180
models:
  "existing":
    ttl: 300
    env: ["HIP_VISIBLE_DEVICES=0"]
    cmd: |
      /usr/local/bin/llama-server --model /models/existing.gguf --ctx-size 65536 --device ROCm0
YAML
cp "$TMP/config.yaml" "$TMP/config-base.yaml"

FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config.yaml" MODELS_DIR="$TMP/models" MODEL_METADATA_DIR="$TMP/metadata" INVENTORY_PATH="$TMP/generated-inventory.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21' > "$TMP/run.out" 2> "$TMP/run.err" || {
  cat "$TMP/run.out" >&2; cat "$TMP/run.err" >&2; fail 'fetch-model invocation failed'; }
assert_contains "$TMP/config.yaml" '"model-q5-k-m":'
assert_contains "$TMP/config.yaml" '--ctx-size 65536'
assert_contains "$TMP/config.yaml" '--n-cpu-moe 21'
assert_contains "$TMP/config.yaml" '--model '
assert_contains "$TMP/models/model-Q5_K_M.gguf" 'GGUF'
assert_contains "$TMP/metadata/model-q5-k-m.json" '"native_context": 262144'
assert_contains "$TMP/hf.calls" 'owner/repo-GGUF/model-Q5_K_M.gguf'
python3 "$ROOT/tools/render_model_inventory.py" "$TMP/config.yaml" "$TMP/inventory.html" "$TMP/metadata"
assert_contains "$TMP/inventory.html" 'A test MoE model'
assert_contains "$TMP/inventory.html" '--n-cpu-moe 21'

# The ordinary, unquoted copy/paste form must mean the same thing.
cp "$TMP/config-base.yaml" "$TMP/config-unquoted.yaml"
FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-unquoted.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-unquoted.yaml" MODELS_DIR="$TMP/models-unquoted" MODEL_METADATA_DIR="$TMP/metadata-unquoted" INVENTORY_PATH="$TMP/generated-unquoted-inventory.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21 > "$TMP/unquoted.out" 2>&1 || {
  cat "$TMP/unquoted.out" >&2; fail 'unquoted fetch-model invocation failed'; }
assert_contains "$TMP/config-unquoted.yaml" '--n-cpu-moe 21'

# Nested HF repository paths must use the remote path for `hf` but only the
# basename for the local cache path, model ID, and dossier filename.
cp "$TMP/config-base.yaml" "$TMP/config-nested.yaml"
FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-nested.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-nested.yaml" MODELS_DIR="$TMP/models-nested" MODEL_METADATA_DIR="$TMP/metadata-nested" INVENTORY_PATH="$TMP/generated-nested-inventory.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke 'hf download hf://owner/repo-GGUF/quantize/gguf/model-Q5_K_M.gguf 21' > "$TMP/nested.out" 2>&1 || {
  cat "$TMP/nested.out" >&2; fail 'nested HF path invocation failed'; }
assert_contains "$TMP/config-nested.yaml" '"model-q5-k-m":'
assert_contains "$TMP/config-nested.yaml" '--model '
assert_contains "$TMP/models-nested/model-Q5_K_M.gguf" 'GGUF'
assert_contains "$TMP/hf-nested.calls" 'owner/repo-GGUF/quantize/gguf/model-Q5_K_M.gguf'

# A nested-path registration failure must still write a flat dossier filename.
cp "$TMP/config-base.yaml" "$TMP/config-nested-fail.yaml"
if FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-nested-fail.calls" \
  PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-nested-fail.yaml" MODELS_DIR="$TMP/models-nested-fail" MODEL_METADATA_DIR="$TMP/metadata-nested-fail" INVENTORY_PATH="$TMP/generated-nested-fail-inventory.html" INVENTORY_RENDERER=/dev/null \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke 'hf download hf://owner/repo-GGUF/quantize/gguf/model-Q5_K_M.gguf 21' > "$TMP/nested-fail.out" 2>&1; then
  fail 'nested path registration failure unexpectedly succeeded'
fi
dossier="$(find "$TMP" -maxdepth 1 -type f -name 'fetch-model-model-q5-k-m-*.dossier.md' -print -quit)"
[[ -n "$dossier" ]] || { cat "$TMP/nested-fail.out" >&2; fail 'nested path dossier was not written at DOSSIER_DIR root'; }
assert_contains "$dossier" 'complete run output:'
assert_contains "$dossier" 'Hermes'
assert_contains "$TMP/nested-fail.out" 'Hermes recovery command:'
runlog="$(find "$TMP" -maxdepth 1 -type f -name 'fetch-model-*.run.log' -print -quit)"
[[ -n "$runlog" ]] || fail 'complete run log was not written'
[[ -s "$runlog" ]] || fail 'complete run log was empty'

# The normal command is non-interactive by default: stdin must not be needed.
cp "$TMP/config-base.yaml" "$TMP/config-default-no-prompt.yaml"
FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-default.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-default-no-prompt.yaml" MODELS_DIR="$TMP/models-default" MODEL_METADATA_DIR="$TMP/metadata-default" INVENTORY_PATH="$TMP/generated-default-inventory.html" \
  DOSSIER_DIR="$TMP" timeout 10 "$SCRIPT" --no-smoke 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21' < /dev/null > "$TMP/default.out" 2>&1 || {
  cat "$TMP/default.out" >&2; fail 'default invocation unexpectedly needed interactive input'; }
assert_contains "$TMP/config-default-no-prompt.yaml" '"model-q5-k-m":'
python3 - "$TMP/config-default-no-prompt.yaml" <<'PYGROUP'
import sys
text=open(sys.argv[1]).read()
assert 'amd-r9700' not in text
PYGROUP

# A fit estimator with incomplete KV metadata must decline rather than guess.
python3 - "$TMP/incomplete-meta.json" <<'PYINCOMPLETE'
import json,sys
json.dump({'block_count':52},open(sys.argv[1],'w'))
PYINCOMPLETE
python3 "$ROOT/tools/cuda_fit.py" --model-bytes 1000 --metadata "$TMP/incomplete-meta.json" --free-bytes 1000000 > "$TMP/incomplete-fit.json"
assert_contains "$TMP/incomplete-fit.json" '"decision": "unknown"'

# Native context below Hermes minimum: do not reject; force the 64000 compatibility context.
python3 - "$TMP/model-low.gguf" <<'PYLOW'
import struct, sys
def s(v):
 b=v.encode(); return struct.pack('<Q',len(b))+b
fields=[('general.architecture',8,'qwen3'),('qwen3.context_length',4,4096),('general.description',8,'Low context test model')]
out=bytearray(b'GGUF'+struct.pack('<IQQ',3,0,len(fields)))
for k,t,v in fields:
 out += s(k)+struct.pack('<I',t)
 out += s(v) if t == 8 else struct.pack('<I',v)
open(sys.argv[1],'wb').write(out)
PYLOW
cp "$TMP/config-base.yaml" "$TMP/config-low.yaml"
FAKE_GGUF="$TMP/model-low.gguf" HF_CALLS="$TMP/hf-low.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-low.yaml" MODELS_DIR="$TMP/models-low" MODEL_METADATA_DIR="$TMP/metadata-low" INVENTORY_PATH="$TMP/inventory-low.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke "$TMP/model-low.gguf" > "$TMP/low.out" 2>&1 || { cat "$TMP/low.out" >&2; fail 'low-context model was rejected'; }
assert_contains "$TMP/config-low.yaml" '--ctx-size 64000'
assert_contains "$TMP/low.out" 'using explicit ctx=64000'

# If inventory rendering fails, the earlier config registration must be rolled back.
cp "$TMP/config-base.yaml" "$TMP/config-rollback.yaml"
if FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-rollback.calls" \
  PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-rollback.yaml" MODELS_DIR="$TMP/models-rollback" MODEL_METADATA_DIR="$TMP/metadata-rollback" INVENTORY_PATH="$TMP/generated-rollback-inventory.html" INVENTORY_RENDERER=/dev/null \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21' > "$TMP/rollback.out" 2>&1; then
  fail 'registration succeeded despite inventory-render failure'
fi
cmp -s "$TMP/config-base.yaml" "$TMP/config-rollback.yaml" || fail 'config changed after inventory-render failure'
[[ ! -e "$TMP/metadata-rollback/model-q5-k-m.json" ]] || fail 'metadata sidecar survived inventory-render failure'

# An unusable inventory output path must fail before config registration starts.
cp "$TMP/config-base.yaml" "$TMP/config-output-path.yaml"
touch "$TMP/not-a-directory"
if FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf-output-path.calls" \
  PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-output-path.yaml" MODELS_DIR="$TMP/models-output-path" MODEL_METADATA_DIR="$TMP/metadata-output-path" INVENTORY_PATH="$TMP/not-a-directory/inventory.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21' > "$TMP/output-path.out" 2>&1; then
  fail 'registration succeeded with an unusable inventory output path'
fi
cmp -s "$TMP/config-base.yaml" "$TMP/config-output-path.yaml" || fail 'config changed after inventory output-path preflight failure'

# A malformed historical sidecar with gguf:null must still render as unknown.
mkdir -p "$TMP/metadata-null"
printf '{"alias":"existing","gguf":null}\n' > "$TMP/metadata-null/existing.json"
python3 "$ROOT/tools/render_model_inventory.py" "$TMP/config-base.yaml" "$TMP/inventory-null.html" "$TMP/metadata-null"
assert_contains "$TMP/inventory-null.html" '>unknown<'

FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config.yaml" MODELS_DIR="$TMP/models" INVENTORY_PATH="$TMP/generated-bounds-inventory.html" \
  DOSSIER_DIR="$TMP" "$SCRIPT" -y --no-smoke --no-register 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 49' > "$TMP/bounds.out" 2>&1 \
  && fail 'out-of-range --n-cpu-moe was accepted'
assert_contains "$TMP/bounds.out" 'must be between 0 and 48'

# CUDA fit estimator and variant registrar: use a temp config and fixture metadata.
python3 - "$TMP/cuda-meta.json" <<'PYCUDA'
import json,sys
json.dump({"architecture":"muse-glimmer","block_count":52,"attention_head_count_kv":2,"attention_key_length":128,"attention_value_length":128,"context_length":131072,"name":"Muse-Glimmer-30B"},open(sys.argv[1],'w'))
PYCUDA
python3 "$ROOT/tools/cuda_fit.py" --model-bytes 13360983072 --metadata "$TMP/cuda-meta.json" --free-bytes 16579313664 > "$TMP/cuda-fit.json"
assert_contains "$TMP/cuda-fit.json" '"decision": "fit"'
cat > "$TMP/cuda-config.yaml" <<'YAMLCUDA'
healthCheckTimeout: 180
groups:
  nvidia-5060ti:
    swap: true
    exclusive: false
    members:
      - "existing-cuda"
models:
  "existing":
    ttl: 300
    env: ["HIP_VISIBLE_DEVICES=0"]
    cmd: |
      /usr/local/bin/llama-server --model /models/existing.gguf
YAMLCUDA
printf '%s\n' '/opt/llama-cuda/bin/llama-server --model /models/muse.gguf' '--ctx-size 65536 --device CUDA0' > "$TMP/cuda-command.txt"
printf '%s\n' 'import pathlib,sys' 'pathlib.Path(sys.argv[2]).write_text("ok")' > "$TMP/render.py"
python3 "$ROOT/tools/register_model_variant.py" --config "$TMP/cuda-config.yaml" --name muse-glimmer-cuda --group nvidia-5060ti --ttl 300 --env CUDA_VISIBLE_DEVICES=0 --command-file "$TMP/cuda-command.txt" --metadata-dir "$TMP/cuda-metadata" --inventory "$TMP/cuda-inventory.html" --inventory-renderer "$TMP/render.py" --metadata-json "$(cat "$TMP/cuda-meta.json")" --repository unsloth/Muse-Glimmer-30B-GGUF --filename Muse-Glimmer.gguf --model-path /models/Muse-Glimmer.gguf --effective-context 65536 --native-context 131072 --description Muse-Glimmer
assert_contains "$TMP/cuda-config.yaml" '"muse-glimmer-cuda":'
assert_contains "$TMP/cuda-config.yaml" '- "muse-glimmer-cuda"'
assert_contains "$TMP/cuda-config.yaml" 'CUDA_VISIBLE_DEVICES=0'
[[ -f "$TMP/cuda-metadata/muse-glimmer-cuda.json" ]] || fail 'CUDA sidecar missing'

# CUDA variant registration must roll back config, sidecar, and inventory if
# inventory rendering fails after the sidecar has been written.
cp "$TMP/cuda-config.yaml" "$TMP/cuda-rollback-config.yaml"
printf 'before' > "$TMP/cuda-rollback-inventory.html"
printf '%s\n' 'raise SystemExit("renderer failure")' > "$TMP/failing-renderer.py"
if python3 "$ROOT/tools/register_model_variant.py" --config "$TMP/cuda-rollback-config.yaml" --name rollback-cuda --group nvidia-5060ti --ttl 300 --env CUDA_VISIBLE_DEVICES=0 --command-file "$TMP/cuda-command.txt" --metadata-dir "$TMP/cuda-rollback-metadata" --inventory "$TMP/cuda-rollback-inventory.html" --inventory-renderer "$TMP/failing-renderer.py" --metadata-json "$(cat "$TMP/cuda-meta.json")" --repository unsloth/Muse-Glimmer-30B-GGUF --filename Muse-Glimmer.gguf --model-path /models/Muse-Glimmer.gguf --effective-context 65536 --native-context 131072; then
  fail 'CUDA variant registration succeeded despite renderer failure'
fi
cmp -s "$TMP/cuda-config.yaml" "$TMP/cuda-rollback-config.yaml" || fail 'CUDA config was not rolled back'
[[ ! -e "$TMP/cuda-rollback-metadata/rollback-cuda.json" ]] || fail 'CUDA sidecar was not rolled back'
[[ "$(cat "$TMP/cuda-rollback-inventory.html")" == before ]] || fail 'CUDA inventory was not rolled back'

printf 'PASS: fetch-model parses pasted HF command, derives native context, validates MoE bounds, and registers safely\n'
