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
[[ "$file" == "model-Q5_K_M.gguf" ]]
local_dir=""
shift 3
while [[ $# -gt 0 ]]; do
  case "$1" in --local-dir) local_dir="$2"; shift 2;; *) shift;; esac
done
mkdir -p "$local_dir"
cp "$FAKE_GGUF" "$local_dir/$file"
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
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config.yaml" MODELS_DIR="$TMP/models" MODEL_METADATA_DIR="$TMP/metadata" \
  "$SCRIPT" -y --no-push --no-smoke 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21' > "$TMP/run.out" 2> "$TMP/run.err" || {
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
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config-unquoted.yaml" MODELS_DIR="$TMP/models-unquoted" MODEL_METADATA_DIR="$TMP/metadata-unquoted" \
  "$SCRIPT" -y --no-push --no-smoke hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 21 > "$TMP/unquoted.out" 2>&1 || {
  cat "$TMP/unquoted.out" >&2; fail 'unquoted fetch-model invocation failed'; }
assert_contains "$TMP/config-unquoted.yaml" '--n-cpu-moe 21'

FAKE_GGUF="$TMP/model-Q5_K_M.gguf" HF_CALLS="$TMP/hf.calls" \
PATH="$TMP/bin:$PATH" LLAMA_SERVER="$TMP/bin/llama-server" LLAMA_SWAP_CONFIG="$TMP/config.yaml" MODELS_DIR="$TMP/models" \
  "$SCRIPT" -y --no-smoke --no-register 'hf download hf://owner/repo-GGUF/model-Q5_K_M.gguf 49' > "$TMP/bounds.out" 2>&1 \
  && fail 'out-of-range --n-cpu-moe was accepted'
assert_contains "$TMP/bounds.out" 'must be between 0 and 48'
printf 'PASS: fetch-model parses pasted HF command, derives native context, validates MoE bounds, and registers safely\n'
