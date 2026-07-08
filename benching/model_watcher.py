#!/usr/bin/env python3
"""
model_watcher.py — Nightly (3:00-5:00 AM America/New_York) scanner that finds
new GGUF models in your models folder, registers them in SQLite, and
benchmarks any that haven't been benchmarked yet, calling bench_model.py
for the actual measurement (kept as a separate script so it can also be
run standalone/manually against one file).

Intended to be launched ONCE by cron at 3:00 AM ET. It loops internally,
rescanning for new files periodically, and hard-stops starting new
benchmarks at 5:00 AM ET (it will let an in-flight model finish its own
per-model budget, then exit).

Example crontab entry (edit paths):
    CRON_TZ=America/New_York
    0 3 * * * /usr/bin/python3 /opt/llama-bench-suite/model_watcher.py \
        --models-dir /mnt/models --db /opt/llama-bench-suite/bench.db \
        --csv /opt/llama-bench-suite/bench_summary.csv \
        >> /opt/llama-bench-suite/watcher.log 2>&1
(Not all cron implementations support CRON_TZ; if yours doesn't, set the
system/cron timezone to America/New_York, or use a wrapper that computes
the ET-adjusted schedule.)
"""

import argparse
import fcntl
import os
import re
import subprocess
import sys
import time
from datetime import datetime, time as dtime

try:
    from zoneinfo import ZoneInfo
except ImportError:
    print("Python 3.9+ with zoneinfo required.", file=sys.stderr)
    sys.exit(1)

ET = ZoneInfo("America/New_York")
WINDOW_START = dtime(3, 0)
WINDOW_END = dtime(5, 0)

# Matches sharded GGUF filenames like "model-00002-of-00005.gguf" so we
# only register/benchmark the FIRST shard — llama-bench/llama.cpp will
# pull in the rest automatically when pointed at shard 1.
SHARD_RE = re.compile(r"-(\d{5})-of-(\d{5})\.gguf$", re.IGNORECASE)


def is_benchable_shard(filename):
    m = SHARD_RE.search(filename)
    if not m:
        return True  # not a sharded file, always fine
    return m.group(1) == "00001"


def now_et():
    return datetime.now(ET)


def in_window(dt):
    t = dt.time()
    return WINDOW_START <= t < WINDOW_END


def find_gguf_files(models_dir):
    found = []
    for root, _, files in os.walk(models_dir):
        for fn in files:
            if fn.lower().endswith(".gguf") and is_benchable_shard(fn):
                found.append(os.path.join(root, fn))
    return found


def scan_and_register(models_dir, db_path):
    """Import bench_model's DB helpers so schema/identity logic lives in
    one place."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import bench_model as bm

    conn = bm.ensure_db(db_path)
    new_count = 0
    for path in find_gguf_files(models_dir):
        cur = conn.execute("SELECT id, size_bytes, mtime, status FROM models WHERE filepath=?", (path,))
        row = cur.fetchone()
        st = os.stat(path)
        if row is None:
            bm.get_or_create_model(conn, path)
            new_count += 1
        elif row[1] != st.st_size or row[2] != st.st_mtime:
            # File changed (re-downloaded/re-quantized) -> re-benchmark it.
            conn.execute(
                "UPDATE models SET size_bytes=?, mtime=?, status='pending' WHERE id=?",
                (st.st_size, st.st_mtime, row[0]),
            )
            conn.commit()
    conn.close()
    return new_count


def detect_current_gpu(bench_bin, log):
    """Name of the GPU llama-bench will run on, matching the gpu_info string
    llama-bench writes to benchmark_runs (e.g. 'AMD Radeon AI PRO R9700').
    Uses llama-server --list-devices from the same install dir as bench_bin.
    Returns None if detection fails."""
    server = os.path.join(os.path.dirname(os.path.abspath(bench_bin)), "llama-server")
    try:
        out = subprocess.run([server, "--list-devices"], capture_output=True,
                             text=True, timeout=60).stdout + ""
    except (OSError, subprocess.TimeoutExpired) as e:
        log(f"GPU detection failed ({e}); falling back to status-based selection")
        return None
    for line in out.splitlines():
        m = re.match(r"\s*\w+\d+:\s+(.+?)\s+\(\d+ MiB", line)
        if m:
            return m.group(1)
    log("GPU detection failed (no device line in --list-devices output); "
        "falling back to status-based selection")
    return None


def get_pending_models(db_path, current_gpu=None):
    """Models to benchmark tonight. With a detected GPU, a model qualifies
    only if it has NEVER been benchmarked on that GPU (so a GPU swap
    automatically re-benchmarks everything, and models already covered on
    this GPU are never re-run). status pending/failed still qualifies —
    those are new/changed/never-succeeded files. Existing records are never
    deleted; re-benchmarks only append new benchmark_runs rows."""
    import sqlite3
    conn = sqlite3.connect(db_path)
    if current_gpu:
        cur = conn.execute(
            """SELECT filepath FROM models m
               WHERE m.status IN ('pending','failed')
                  OR NOT EXISTS (SELECT 1 FROM benchmark_runs r
                                 WHERE r.model_id = m.id AND r.gpu_info = ?)
               ORDER BY m.first_seen ASC""",
            (current_gpu,),
        )
    else:
        cur = conn.execute(
            "SELECT filepath FROM models WHERE status IN ('pending','failed') ORDER BY first_seen ASC"
        )
    rows = [r[0] for r in cur.fetchall()]
    conn.close()
    return rows


def seconds_until(dt, target_time):
    target = dt.replace(hour=target_time.hour, minute=target_time.minute, second=0, microsecond=0)
    if target < dt:
        target = target.replace(day=target.day + 1)  # shouldn't happen inside window
    return (target - dt).total_seconds()


def run_one(model_path, db_path, csv_path, bench_bin, budget_s, repetitions, log):
    log(f"benchmarking: {model_path} (budget={int(budget_s)}s)")
    cmd = [
        sys.executable,
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "bench_model.py"),
        "--model", model_path,
        "--db", db_path,
        "--csv", csv_path,
        "--bench-bin", bench_bin,
        "--budget-seconds", str(int(budget_s)),
        "--repetitions", str(repetitions),
    ]
    # Give the subprocess a little extra wall-clock room over its own
    # internal budget so it can finish writing DB/CSV before we kill it.
    try:
        proc = subprocess.run(cmd, timeout=budget_s + 120)
        log(f"  -> exit code {proc.returncode}")
    except subprocess.TimeoutExpired:
        log(f"  -> hard-killed after exceeding budget+grace period")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--models-dir", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--bench-bin", default="llama-bench")
    ap.add_argument("--per-model-budget-seconds", type=int, default=1750)
    ap.add_argument("--repetitions", type=int, default=3)
    ap.add_argument("--rescan-interval-seconds", type=int, default=300,
                     help="how often to re-scan for newly-downloaded models while idle in-window")
    ap.add_argument("--lockfile", default="/tmp/model_watcher.lock")
    ap.add_argument("--force-run", action="store_true",
                     help="ignore the 3-5am ET window (for manual testing)")
    args = ap.parse_args()

    def log(msg):
        print(f"[{now_et().isoformat()}] {msg}", flush=True)

    lock_fp = open(args.lockfile, "w")
    try:
        fcntl.flock(lock_fp, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log("another watcher instance holds the lock, exiting")
        return

    log("watcher started")
    new_models = scan_and_register(args.models_dir, args.db)
    log(f"scan complete, {new_models} new model(s) registered")

    if not args.force_run and not in_window(now_et()):
        log("outside 3:00-5:00 AM ET window, exiting without benchmarking")
        return

    attempted_this_session = set()
    current_gpu = detect_current_gpu(args.bench_bin, log)
    if current_gpu:
        log(f"current GPU: {current_gpu} — selecting models never benchmarked on it")

    while args.force_run or in_window(now_et()):
        pending = [p for p in get_pending_models(args.db, current_gpu) if p not in attempted_this_session]
        if not pending:
            if args.force_run:
                log("no pending models, force-run batch complete, exiting")
                break
            log("no pending models, idling until next rescan")
            time.sleep(args.rescan_interval_seconds)
            scan_and_register(args.models_dir, args.db)
            if not args.force_run and not in_window(now_et()):
                break
            continue

        model_path = pending[0]
        attempted_this_session.add(model_path)
        if not os.path.exists(model_path):
            log(f"skipping missing file: {model_path}")
            continue

        remaining_in_window = (
            args.per_model_budget_seconds if args.force_run
            else seconds_until(now_et(), WINDOW_END)
        )
        budget = min(args.per_model_budget_seconds, max(60, remaining_in_window))
        if not args.force_run and remaining_in_window < 60:
            log("less than a minute left in window, stopping before starting a new model")
            break

        run_one(model_path, args.db, args.csv, args.bench_bin, budget, args.repetitions, log)
        scan_and_register(args.models_dir, args.db)  # pick up anything dropped in mid-run

    log("watcher exiting (window closed or force-run batch complete)")


if __name__ == "__main__":
    main()
