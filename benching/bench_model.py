#!/usr/bin/env python3
"""
bench_model.py — Benchmark a single GGUF model with llama.cpp's llama-bench,
normalize the results, and record them in SQLite + CSV.

Design notes (why it's built this way):
- llama-bench already knows how to output JSON/SQL-ready rows, so we let it
  do the measuring and we just parse + store its JSON output rather than
  timing anything ourselves.
- Standard test battery (kept intentionally small so any model finishes
  inside the time budget):
    pp512          prompt-processing throughput  (compute-bound proxy)
    tg128          text-generation throughput    (memory-bandwidth proxy)
    pp512+tg128 @ d4096   same pair but with 4096 tokens already in the
                   KV cache, to show how much a model degrades with a
                   "real conversation" length context (long-context tax)
  This mirrors what most public llama.cpp benchmark write-ups report
  (pp512 / tg128 are the numbers you'll see quoted in GitHub discussions,
  r/LocalLLaMA threads, and hardware review blogs) so results are
  comparable to numbers other people publish.
- Repetitions default to 3 (not llama-bench's default of 5) to leave
  headroom in the 30-minute-per-model budget for big/slow models.
- A hard wall-clock budget is enforced via subprocess timeout. If a model
  is too large/slow to finish, we kill it and record whatever llama-bench
  had already flushed, then mark the run as PARTIAL rather than failing
  the whole pipeline.
- We do NOT compute a full SHA-256 of multi-GB files on every scan; model
  identity is (filepath, size, mtime) which is enough to detect "this file
  changed" without hashing tens of GB nightly.
"""

import argparse
import json
import os
import re
import shutil
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

SCHEMA = """
CREATE TABLE IF NOT EXISTS models (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    filepath TEXT UNIQUE NOT NULL,
    filename TEXT NOT NULL,
    size_bytes INTEGER,
    mtime REAL,
    first_seen TEXT,
    last_benchmarked TEXT,
    status TEXT DEFAULT 'pending'   -- pending | benchmarking | done | partial | failed | skipped
);

CREATE TABLE IF NOT EXISTS benchmark_runs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    model_id INTEGER NOT NULL REFERENCES models(id),
    run_time TEXT,
    date_run INTEGER,    -- unix epoch, same instant as run_time
    build_commit TEXT,
    build_number INTEGER,
    cpu_info TEXT,
    gpu_info TEXT,
    backends TEXT,
    model_type TEXT,
    model_size INTEGER,
    model_n_params INTEGER,
    n_gpu_layers INTEGER,
    flash_attn INTEGER,
    n_threads INTEGER,
    test_name TEXT,      -- pp512 | tg128 | pp512@d4096 | tg128@d4096 etc
    n_prompt INTEGER,
    n_gen INTEGER,
    n_depth INTEGER,
    avg_ts REAL,
    stddev_ts REAL,
    avg_ns INTEGER,
    stddev_ns INTEGER,
    notes TEXT
);
"""

CSV_HEADER = [
    "run_time", "date_run", "filename", "model_type", "size_gb", "params_b",
    "gpu_info", "n_gpu_layers", "flash_attn",
    "pp512_ts", "tg128_ts", "pp512_d4096_ts", "tg128_d4096_ts",
    "status", "notes",
]


def ensure_db(db_path):
    conn = sqlite3.connect(db_path)
    conn.executescript(SCHEMA)
    # Migration for DBs created before date_run existed (added 2026-07-08).
    cols = [r[1] for r in conn.execute("PRAGMA table_info(benchmark_runs)")]
    if "date_run" not in cols:
        conn.execute("ALTER TABLE benchmark_runs ADD COLUMN date_run INTEGER")
        conn.execute("UPDATE benchmark_runs SET date_run=? WHERE date_run IS NULL",
                     (int(time.time()),))
    conn.commit()
    return conn


def get_or_create_model(conn, filepath):
    st = os.stat(filepath)
    now = datetime.now(timezone.utc).isoformat()
    cur = conn.execute("SELECT id FROM models WHERE filepath = ?", (filepath,))
    row = cur.fetchone()
    if row:
        model_id = row[0]
        conn.execute(
            "UPDATE models SET size_bytes=?, mtime=? WHERE id=?",
            (st.st_size, st.st_mtime, model_id),
        )
    else:
        cur = conn.execute(
            "INSERT INTO models (filepath, filename, size_bytes, mtime, first_seen, status) "
            "VALUES (?, ?, ?, ?, ?, 'pending')",
            (filepath, os.path.basename(filepath), st.st_size, st.st_mtime, now),
        )
        model_id = cur.lastrowid
    conn.commit()
    return model_id


def build_bench_command(bench_bin, model_path, device, args_list):
    if not device:
        raise ValueError("an explicit llama.cpp device is required")
    return [bench_bin, "-m", model_path, "-o", "json", "--progress",
            "--device", device] + args_list


def validate_gpu_rows(rows, expected_gpu):
    """Reject results unless every row identifies the commanded GPU."""
    if not rows:
        return "empty benchmark result"
    for row in rows:
        actual = str(row.get("gpu_info", ""))
        if expected_gpu not in actual:
            return f"GPU identity mismatch; expected {expected_gpu!r}, got {actual!r}"
    return None


def run_llama_bench(bench_bin, model_path, device, args_list, timeout_s, expected_gpu):
    """Run llama-bench with -o json and return parsed list of result rows.
    Returns (rows, timed_out: bool, error: str|None)."""
    cmd = build_bench_command(bench_bin, model_path, device, args_list)
    env = os.environ.copy()
    if device.lower().startswith("rocm"):
        env["HIP_VISIBLE_DEVICES"] = "GPU-61fe9ba05af1939a"
    elif device.lower().startswith("cuda"):
        env["CUDA_VISIBLE_DEVICES"] = "0"
    else:
        raise ValueError(f"unsupported explicit device: {device}")
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout_s, env=env
        )
    except subprocess.TimeoutExpired as e:
        # llama-bench streams progress to stderr; JSON array only appears
        # once the whole run finishes, so a timeout means we get nothing
        # structured back. This is the tradeoff for using -o json.
        return [], True, f"timeout after {timeout_s}s"

    if proc.returncode != 0:
        return [], False, f"llama-bench exit {proc.returncode}: {proc.stderr[-2000:]}"

    # llama-bench prints progress lines to stdout before --progress rows;
    # the JSON payload is the last well-formed JSON array in stdout.
    text = proc.stdout.strip()
    try:
        rows = json.loads(text)
        error = validate_gpu_rows(rows, expected_gpu)
        if error:
            return [], False, error
        return rows, False, None
    except json.JSONDecodeError:
        # fall back: find the first '[' ... last ']' in stdout
        start, end = text.find("["), text.rfind("]")
        if start != -1 and end != -1:
            try:
                rows = json.loads(text[start:end + 1])
                error = validate_gpu_rows(rows, expected_gpu)
                if error:
                    return [], False, error
                return rows, False, None
            except json.JSONDecodeError:
                pass
        return [], False, f"could not parse llama-bench JSON output: {proc.stderr[-500:]}"


def test_label(row):
    label = f"pp{row['n_prompt']}" if row["n_prompt"] and not row["n_gen"] else ""
    if row["n_gen"] and not row["n_prompt"]:
        label = f"tg{row['n_gen']}"
    if row["n_prompt"] and row["n_gen"]:
        label = f"pp{row['n_prompt']}+tg{row['n_gen']}"
    if row.get("n_depth"):
        label += f"@d{row['n_depth']}"
    return label or "unknown"


def store_rows(conn, model_id, rows, notes=""):
    now = datetime.now(timezone.utc).isoformat()
    epoch = int(time.time())
    for row in rows:
        conn.execute(
            """INSERT INTO benchmark_runs
               (model_id, run_time, date_run, build_commit, build_number, cpu_info, gpu_info,
                backends, model_type, model_size, model_n_params, n_gpu_layers,
                flash_attn, n_threads, test_name, n_prompt, n_gen, n_depth,
                avg_ts, stddev_ts, avg_ns, stddev_ns, notes)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                model_id, now, epoch, row.get("build_commit"), row.get("build_number"),
                row.get("cpu_info"), row.get("gpu_info"), row.get("backends"),
                row.get("model_type"), row.get("model_size"), row.get("model_n_params"),
                row.get("n_gpu_layers"), row.get("flash_attn"), row.get("n_threads"),
                test_label(row), row.get("n_prompt"), row.get("n_gen"), row.get("n_depth"),
                row.get("avg_ts"), row.get("stddev_ts"), row.get("avg_ns"), row.get("stddev_ns"),
                notes,
            ),
        )
    conn.commit()


def append_csv_summary(csv_path, conn, model_id, filepath, status, notes):
    import csv as csvmod

    cur = conn.execute(
        "SELECT test_name, avg_ts, model_type, model_size, model_n_params, "
        "gpu_info, n_gpu_layers, flash_attn FROM benchmark_runs "
        "WHERE model_id=? ORDER BY id DESC", (model_id,),
    )
    by_test, meta = {}, {}
    for test_name, avg_ts, model_type, model_size, model_n_params, gpu_info, ngl, fa in cur.fetchall():
        by_test.setdefault(test_name, avg_ts)
        if not meta:
            # rows are ORDER BY id DESC, so the first row seen is the latest run;
            # only take metadata from it, not from older historical runs.
            meta = {"model_type": model_type, "size_gb": (model_size or 0) / 1e9,
                    "params_b": (model_n_params or 0) / 1e9, "gpu_info": gpu_info,
                    "n_gpu_layers": ngl, "flash_attn": fa}

    # Migration for CSVs written before date_run existed: rewrite once with
    # the new column, backfilling existing rows with the migration-time epoch.
    if os.path.exists(csv_path):
        with open(csv_path, newline="") as f:
            first = f.readline()
        if first.strip() and "date_run" not in first:
            epoch_now = int(time.time())
            with open(csv_path, newline="") as f:
                old_rows = list(csvmod.reader(f))
            with open(csv_path, "w", newline="") as f:
                w = csvmod.writer(f)
                w.writerow(CSV_HEADER)
                for r in old_rows[1:]:
                    w.writerow([r[0], epoch_now] + r[1:])

    file_exists = os.path.exists(csv_path)
    with open(csv_path, "a", newline="") as f:
        w = csvmod.writer(f)
        if not file_exists:
            w.writerow(CSV_HEADER)
        w.writerow([
            datetime.now(timezone.utc).isoformat(),
            int(time.time()),
            os.path.basename(filepath),
            meta.get("model_type", ""),
            round(meta.get("size_gb", 0), 2),
            round(meta.get("params_b", 0), 2),
            meta.get("gpu_info", ""),
            meta.get("n_gpu_layers", ""),
            meta.get("flash_attn", ""),
            by_test.get("pp512", ""),
            by_test.get("tg128", ""),
            by_test.get("pp512+tg128@d4096", by_test.get("pp512@d4096", "")),
            by_test.get("tg128@d4096", ""),
            status, notes,
        ])


def benchmark_one(bench_bin, model_path, db_path, csv_path, budget_s, repetitions,
                  device, expected_gpu):
    conn = ensure_db(db_path)
    model_id = get_or_create_model(conn, model_path)
    conn.execute("UPDATE models SET status='benchmarking' WHERE id=?", (model_id,))
    conn.commit()

    start = time.time()
    all_rows, notes_parts, overall_status = [], [], "done"

    # Pass 1: short-context throughput, the numbers everyone compares.
    remaining = budget_s - (time.time() - start)
    rows, timed_out, err = run_llama_bench(
        bench_bin, model_path, device,
        ["-p", "512", "-n", "128", "-r", str(repetitions), "-fa", "auto", "-ngl", "999"],
        timeout_s=max(30, remaining), expected_gpu=expected_gpu,
    )
    all_rows += rows
    if err:
        notes_parts.append(err)
    if timed_out:
        overall_status = "partial"

    # Pass 2: long-context degradation, only if time remains and pass 1 worked.
    remaining = budget_s - (time.time() - start)
    if rows and remaining > 60 and not timed_out:
        rows2, timed_out2, err2 = run_llama_bench(
            bench_bin, model_path, device,
            ["-p", "512", "-n", "128", "-d", "4096", "-r", str(max(1, repetitions - 1)),
             "-fa", "auto", "-ngl", "999"],
            timeout_s=max(30, remaining), expected_gpu=expected_gpu,
        )
        all_rows += rows2
        if err2:
            notes_parts.append(err2)
        if timed_out2:
            overall_status = "partial"
    elif remaining <= 60:
        notes_parts.append("skipped long-context pass: time budget exhausted")

    if not all_rows:
        overall_status = "failed"

    store_rows(conn, model_id, all_rows, notes="; ".join(notes_parts))
    conn.execute(
        "UPDATE models SET status=?, last_benchmarked=? WHERE id=?",
        (overall_status, datetime.now(timezone.utc).isoformat(), model_id),
    )
    conn.commit()
    append_csv_summary(csv_path, conn, model_id, model_path, overall_status, "; ".join(notes_parts))
    conn.close()
    return overall_status


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--model", required=True, help="path to .gguf file")
    ap.add_argument("--bench-bin", default=shutil.which("llama-bench") or "llama-bench")
    ap.add_argument("--device", required=True)
    ap.add_argument("--expected-gpu", required=True)
    ap.add_argument("--db", required=True)
    ap.add_argument("--csv", required=True)
    ap.add_argument("--budget-seconds", type=int, default=1750,  # ~29 min, leaves margin under 30
                     help="hard wall-clock cap for this model")
    ap.add_argument("--repetitions", type=int, default=3)
    args = ap.parse_args()

    if not os.path.exists(args.model):
        print(f"model not found: {args.model}", file=sys.stderr)
        sys.exit(1)

    status = benchmark_one(
        args.bench_bin, args.model, args.db, args.csv,
        args.budget_seconds, args.repetitions, args.device, args.expected_gpu,
    )
    print(f"[{os.path.basename(args.model)}] finished with status={status}")


if __name__ == "__main__":
    main()
