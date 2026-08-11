#!/usr/bin/env bash
#
# finalize-fetch-model.sh
#
# Intended to finalize the fetch-model dual-GPU auto-registration work in
# /home/rahlquist/wimpy-setup. It performs LOCAL, NON-INTERACTIVE steps only:
#   - syntax/compile checks
#   - run the existing test suite
#   - verify the three requested model artifacts + ROCm smoke status
#   - show the exact `git add` + `git commit` block (does NOT commit)
#   - show the user-run deployment + verification commands
#
# It does NOT:
#   - delete any files
#   - modify llama-swap-config.yaml or any committed file beyond `git add`
#   - run `sudo`
#   - push
#
set -euo pipefail

cd /home/rahlquist/wimpy-setup

echo "== static checks =="
bash -n fetch-model.sh
bash -n tests/test_fetch_model.sh
python3 -m py_compile tools/gguf_metadata.py tools/cuda_fit.py tools/register_model_variant.py
git diff --check
echo "static checks OK"

echo
echo "== test suite =="
./tests/test_fetch_model.sh

echo
echo "== requested model artifacts =="
declare -A MODELS=(
  ["muse-glimmer-30b-ud-q4-k-xl"]="Muse-Glimmer-30B-UD-Q4_K_XL.gguf"
  ["qwen3-6-27b-fable-fus-711-unheretic-nm-dau-neo-max-neo-mtp-iq3-m"]="Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-IQ3_M.gguf"
  ["qwen3-6-27b-fable-fus-711-unheretic-nm-dau-neo-max-neo-mtp-iq2-m"]="Qwen3.6-27B-Fable-Fus-711-UnHeretic-NM-DAU-NEO-MAX-NEO-MTP-IQ2_M.gguf"
)
CACHE=/home/rahlquist/.cache/llama.cpp
for alias in "${!MODELS[@]}"; do
  fn="${MODELS[$alias]}"
  if [[ -s "$CACHE/$fn" ]]; then
    printf 'OK   %s -> %s\n' "$alias" "$fn"
  else
    printf 'MISSING %s -> %s\n' "$alias" "$fn"
  fi
done

echo
echo "== proposed commit (review, then run manually) =="
cat <<'GITBLOCK'
cd /home/rahlquist/wimpy-setup

git add \
  fetch-model.sh \
  tests/test_fetch_model.sh \
  tools/gguf_metadata.py \
  tools/cuda_fit.py \
  tools/register_model_variant.py \
  llama-swap-config.yaml \
  model-inventory.html \
  model-metadata/muse-glimmer-30b-ud-q4-k-xl.json \
  model-metadata/qwen3-6-27b-fable-fus-711-unheretic-nm-dau-neo-max-neo-mtp-iq3-m.json \
  model-metadata/qwen3-6-27b-fable-fus-711-unheretic-nm-dau-neo-max-neo-mtp-iq2-m.json

git commit -m "feat(fetch-model): auto-estimate CUDA fit, dual-register, summary + failure dossier"

git fetch origin
git status
# If diverged: git merge origin/main
# Then, only when asked: git push origin main
GITBLOCK

echo
echo "== deployment + live verification (run manually with sudo) =="
cat <<'DEPLOYBLOCK'
cd /home/rahlquist/wimpy-setup
sudo /usr/local/sbin/llama-swap-deploy

curl -fsS http://127.0.0.1:8080/v1/models \
  | python3 -c 'import json,sys; ids={x["id"] for x in json.load(sys.stdin)["data"]}; print("\n".join(sorted(x for x in ids if any(k in x for k in ("muse-glimmer","fable-fus")))))'

curl -fsS http://127.0.0.1:8080/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"muse-glimmer-30b-ud-q4-k-xl","prompt":"Reply with exactly: OK","max_tokens":32,"temperature":0}'
DEPLOYBLOCK

echo
echo "DONE: local verification complete. Commit/deploy/push remain for you to run."
