#!/usr/bin/env bash
# run-nightly-bench.sh — drive the nightly llama.cpp benchmark sweep across BOTH
# GPUs on wimpy:
#   * ROCm build  -> AMD Radeon AI PRO R9700   (/usr/local/bin/llama-bench)
#   * CUDA build  -> NVIDIA RTX 5060 Ti 16 GB  (/opt/llama-cuda/bin/llama-bench)
#
# model_watcher.py is GPU-aware: it detects the GPU from the bench binary's
# sibling llama-server --list-devices and only benchmarks models that have NEVER
# been benchmarked on that GPU. Running it once per --bench-bin therefore covers
# each card independently, both writing into the same bench.db keyed by gpu_info.
# A model already covered on the R9700 is NOT re-run there, and vice-versa.
#
# Each invocation uses its own lockfile so the two passes never collide.
#
# Optional flag:
#   --force-run   Passed through to model_watcher.py so a manual catch-up runs
#                 OUTSIDE the normal 3:00-5:00 AM ET window. The scheduled nightly
#                 run fires inside that window, so it does not need this flag.
#                 Usage:  ./run-nightly-bench.sh --force-run
set -uo pipefail

# Parse optional args (only --force-run is supported). Anything else is rejected
# so a typo can't silently launch a full sweep.
FORCE_RUN=""
for a in "$@"; do
  case "$a" in
    --force-run) FORCE_RUN="--force-run" ;;
    -h|--help)   echo "usage: $0 [--force-run]" >&2; exit 0 ;;
    *)           echo "unknown arg: $a (only --force-run accepted)" >&2; exit 2 ;;
  esac
done

BENCH_DIR="/home/rahlquist/wimpy-setup/benching"
MODELS_DIR="/home/rahlquist/.cache/llama.cpp"
DB="$BENCH_DIR/bench.db"
CSV="$BENCH_DIR/bench_summary.csv"
PY="/usr/bin/python3"
WATCHER="$BENCH_DIR/model_watcher.py"
REPORTER="$BENCH_DIR/report.py"
LOG="$BENCH_DIR/watcher.log"
CONFIG="/home/rahlquist/wimpy-setup/llama-hugs-config.yaml"

ROCm_BIN="/usr/local/bin/llama-bench"      # ROCm build -> AMD R9700
CUDA_BIN="/opt/llama-cuda/bin/llama-bench" # CUDA build -> RTX 5060 Ti

run_pass() {
  local label="$1" bin="$2" lock="$3"
  echo "[$(date -u +%FT%TZ)] === benchmark pass: $label ($bin)${FORCE_RUN:+ [force-run]} ===" | tee -a "$LOG"
  if [[ ! -x "$bin" ]]; then
    echo "[$(date -u +%FT%TZ)] SKIP $label: bench binary not found: $bin" | tee -a "$LOG"
    return 0
  fi
  # Build the command as an array so we only append --force-run when set
  # (an empty string would otherwise be passed as a stray arg to the watcher).
  local gpu_class device expected_gpu
  if [[ "$label" == amd-* ]]; then
    gpu_class="rocm"; device="ROCm0"; expected_gpu="AMD Radeon AI PRO R9700"
  else
    gpu_class="cuda"; device="CUDA0"; expected_gpu="NVIDIA GeForce RTX 5060 Ti"
  fi
  local args=(
    "$PY" "$WATCHER"
    --models-dir "$MODELS_DIR"
    --db "$DB" --csv "$CSV"
    --config "$CONFIG"
    --bench-bin "$bin"
    --lockfile "$lock"
    --gpu-class "$gpu_class"
    --device "$device"
    --expected-gpu "$expected_gpu"
  )
  [[ -n "$FORCE_RUN" ]] && args+=(--force-run)
  "${args[@]}" 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  echo "[$(date -u +%FT%TZ)] === $label pass done (rc=$rc) ===" | tee -a "$LOG"
  return "$rc"
}

# R9700 (ROCm) first, then RTX 5060 Ti (CUDA). Sequential to avoid both GPUs
# being monopolized at once (the R9700 is also the live inference card).
run_pass "amd-r9700-rocm" "$ROCm_BIN" "/tmp/model_watcher.rocm.lock" || exit $?
run_pass "nvidia-5060ti-cuda" "$CUDA_BIN" "/tmp/model_watcher.cuda.lock" || exit $?

# Regenerate the HTML report from whatever is now in the DB.
echo "[$(date -u +%FT%TZ)] === regenerating report ===" | tee -a "$LOG"
"$PY" "$REPORTER" --db "$DB" --all --html --out "$BENCH_DIR/bench_results.html" 2>&1 | tee -a "$LOG"

# --- Commit + push the nightly results to origin/main ----------------------
# Only bench_results.html is committed (bench.db / bench_summary.csv /
# watcher.log are git-ignored generated data). Runs as the repo owner so the
# push uses rahlquist's registered SSH deploy key (the systemd service runs as
# root, which has no GitHub credentials of its own). Never force-push: if the
# remote has commits we don't, merge them first so nothing is discarded.
echo "[$(date -u +%FT%TZ)] === syncing results to origin/main ===" | tee -a "$LOG"
REPO="/home/rahlquist/wimpy-setup"
# Path is repo-relative (run-nightly-bench.sh lives in <repo>/benching/).
REPORT_REL="benching/bench_results.html"
GIT_OWNER="rahlquist"
GIT_ENV="GIT_SSH_COMMAND='ssh -i /home/rahlquist/.ssh/id_ed25519 -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' HOME=/home/rahlquist"
sync_results() {
  local rc
  # Stage only the regenerated report. Untracked/source files stay out of the
  # nightly commit on purpose. Use the repo-relative path so the pathspec
  # actually matches (a bare 'bench_results.html' from the repo root matches
  # nothing and silently commits nothing).
  sudo -u "$GIT_OWNER" env $GIT_ENV \
    git -C "$REPO" add -A -- "$REPORT_REL" 2>&1 | tee -a "$LOG"
  # Nothing to commit? exit quietly (e.g. report was byte-identical).
  if sudo -u "$GIT_OWNER" env $GIT_ENV \
       git -C "$REPO" diff --cached --quiet -- "$REPORT_REL"; then
    echo "[$(date -u +%FT%TZ)] no report changes to commit, skipping push" | tee -a "$LOG"
    return 0
  fi
  sudo -u "$GIT_OWNER" env $GIT_ENV \
    git -C "$REPO" commit -m "benching: nightly sweep results ($(date -u +%F))" 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  if [[ $rc -ne 0 ]]; then
    echo "[$(date -u +%FT%TZ)] commit failed (rc=$rc), skipping push" | tee -a "$LOG"
    return $rc
  fi
  # Fetch and check for divergence before pushing. A non-fast-forward remote
  # means another source added commits; merge them (never --force) so the
  # nightly commit rides on top instead of clobbering remote history.
  sudo -u "$GIT_OWNER" env $GIT_ENV \
    git -C "$REPO" fetch origin main 2>&1 | tee -a "$LOG"
  local local_rev remote_rev base_rev
  local_rev=$(sudo -u "$GIT_OWNER" env $GIT_ENV git -C "$REPO" rev-parse HEAD)
  remote_rev=$(sudo -u "$GIT_OWNER" env $GIT_ENV git -C "$REPO" rev-parse origin/main)
  if [[ "$local_rev" != "$remote_rev" ]]; then
    base_rev=$(sudo -u "$GIT_OWNER" env $GIT_ENV git -C "$REPO" merge-base HEAD origin/main)
    if [[ "$base_rev" != "$remote_rev" ]]; then
      echo "[$(date -u +%FT%TZ)] remote has newer commits — merging origin/main (no force-push)" | tee -a "$LOG"
      sudo -u "$GIT_OWNER" env $GIT_ENV \
        git -C "$REPO" merge --no-edit origin/main 2>&1 | tee -a "$LOG"
      rc=${PIPESTATUS[0]}
      if [[ $rc -ne 0 ]]; then
        echo "[$(date -u +%FT%Z)] merge of origin/main FAILED (rc=$rc) — leaving local commit, manual fix needed" | tee -a "$LOG"
        return $rc
      fi
    fi
  fi
  sudo -u "$GIT_OWNER" env $GIT_ENV \
    git -C "$REPO" push origin HEAD:main 2>&1 | tee -a "$LOG"
  rc=${PIPESTATUS[0]}
  echo "[$(date -u +%FT%TZ)] push rc=$rc" | tee -a "$LOG"
  return $rc
}
sync_results

echo "[$(date -u +%FT%TZ)] nightly benchmark sweep complete" | tee -a "$LOG"
