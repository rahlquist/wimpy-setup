#!/usr/bin/env python3
"""
report.py — Generate a shareable Markdown table from bench.db, formatted to
match llama-bench's own default (no -o flag) console/Markdown output, e.g.:

| model                          |       size |     params | backend    | ngl | fa |          test |                  t/s |
| ------------------------------ | ---------: | ---------: | ---------- | --: | -: | -------------: | -------------------: |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |  1 |          pp512 |      4200.32 ± 15.10 |
| llama 7B Q4_0                  |   3.56 GiB |     6.74 B | CUDA       |  99 |  1 |          tg128 |        142.87 ± 0.66 |

Two modes:
  --model PATH   single-model report: identical column layout to what
                 llama-bench itself prints for one file.
  --all          multi-model comparison: same columns, rows for every
                 benchmarked model stacked together (this is exactly what
                 llama-bench's own table looks like if you pass it several
                 -m flags in one invocation) plus a leading "file" column
                 so you can tell rows with identical model-type/quant
                 apart across different downloads.

Both print to stdout by default (so you can pipe straight into `pbcopy`,
a GitHub comment box, etc.) or write to a file with --out.
"""

import argparse
import sqlite3
import sys


def fmt_size(nbytes):
    if not nbytes:
        return ""
    gib = nbytes / (1024 ** 3)
    return f"{gib:.2f} GiB"


def fmt_params(n):
    if not n:
        return ""
    b = n / 1e9
    return f"{b:.2f} B"


def fmt_ts(avg, std):
    if avg is None:
        return ""
    std = std or 0.0
    return f"{avg:.2f} \u00b1 {std:.2f}"


def render_table(rows, columns):
    """rows: list of dicts, columns: list of (key, header, align) where
    align is 'l' or 'r', matching llama-bench's own left/right alignment
    (text columns left, numeric columns right)."""
    widths = {}
    for key, header, _ in columns:
        widths[key] = len(header)
    str_rows = []
    for row in rows:
        str_row = {}
        for key, _, _ in columns:
            val = str(row.get(key, ""))
            str_row[key] = val
            widths[key] = max(widths[key], len(val))
        str_rows.append(str_row)

    def pad(val, key, align):
        w = widths[key]
        return val.rjust(w) if align == "r" else val.ljust(w)

    header_line = "| " + " | ".join(
        pad(header, key, align) for key, header, align in columns
    ) + " |"
    sep_line = "| " + " | ".join(
        ("-" * widths[key] + ":") if align == "r" else ("-" * (widths[key] + 1))
        for key, _, align in columns
    ) + " |"
    # llama-bench's separator uses one fewer dash before the trailing ':'
    # for right-aligned columns; replicate that exactly.
    sep_cells = []
    for key, _, align in columns:
        w = widths[key]
        sep_cells.append(("-" * w + ":") if align == "r" else ("-" * w))
    sep_line = "| " + " | ".join(sep_cells) + " |"

    lines = [header_line, sep_line]
    for str_row in str_rows:
        lines.append("| " + " | ".join(pad(str_row[key], key, align) for key, _, align in columns) + " |")
    return "\n".join(lines)


COLUMNS_SINGLE = [
    ("model", "model", "l"),
    ("size", "size", "r"),
    ("params", "params", "r"),
    ("backend", "backend", "l"),
    ("ngl", "ngl", "r"),
    ("fa", "fa", "r"),
    ("test", "test", "r"),
    ("ts", "t/s", "r"),
]

COLUMNS_MULTI = [("file", "file", "l")] + COLUMNS_SINGLE


TEST_ORDER = {"pp512": 0, "tg128": 1}


def test_sort_key(name):
    return TEST_ORDER.get(name, 2), name


def fetch_latest_run_ids(conn, model_id=None):
    """Return the most recent run_time's benchmark_runs rows per model
    (so a comparison report reflects each model's latest numbers, not
    every historical run)."""
    q = """
        SELECT br.* FROM benchmark_runs br
        INNER JOIN (
            SELECT model_id, MAX(run_time) AS max_time
            FROM benchmark_runs
            {where}
            GROUP BY model_id
        ) latest ON br.model_id = latest.model_id AND br.run_time = latest.max_time
        ORDER BY br.model_id, br.id
    """
    where = "WHERE model_id = ?" if model_id else ""
    conn.row_factory = sqlite3.Row
    cur = conn.execute(q.format(where=where), (model_id,) if model_id else ())
    return cur.fetchall()


def build_rows(conn, db_rows, include_file):
    filenames = {}
    if include_file:
        cur = conn.execute("SELECT id, filename FROM models")
        filenames = dict(cur.fetchall())

    rows = []
    for r in db_rows:
        row = {
            "model": r["model_type"] or "",
            "size": fmt_size(r["model_size"]),
            "params": fmt_params(r["model_n_params"]),
            "backend": r["backends"] or "",
            "ngl": r["n_gpu_layers"] if r["n_gpu_layers"] is not None else "",
            "fa": r["flash_attn"] if r["flash_attn"] is not None else "",
            "test": r["test_name"] or "",
            "ts": fmt_ts(r["avg_ts"], r["stddev_ts"]),
            "_sort_test": test_sort_key(r["test_name"] or ""),
            "_model_id": r["model_id"],
        }
        if include_file:
            row["file"] = filenames.get(r["model_id"], "")
        rows.append(row)

    rows.sort(key=lambda r: (r.get("file", ""), r["_model_id"], r["_sort_test"]))
    return rows


def resolve_model_id(conn, model_arg):
    cur = conn.execute(
        "SELECT id FROM models WHERE filepath = ? OR filename = ?",
        (model_arg, model_arg),
    )
    row = cur.fetchone()
    if not row:
        print(f"no model found matching '{model_arg}' (tried exact filepath and filename)", file=sys.stderr)
        sys.exit(1)
    return row[0] if not isinstance(row, sqlite3.Row) else row["id"]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", required=True)
    group = ap.add_mutually_exclusive_group(required=True)
    group.add_argument("--model", help="filepath or filename of one model")
    group.add_argument("--all", action="store_true", help="comparison table across all benchmarked models")
    ap.add_argument("--out", help="write to this file instead of stdout")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row

    if args.model:
        model_id = resolve_model_id(conn, args.model)
        db_rows = fetch_latest_run_ids(conn, model_id)
        rows = build_rows(conn, db_rows, include_file=False)
        columns = COLUMNS_SINGLE
    else:
        db_rows = fetch_latest_run_ids(conn)
        rows = build_rows(conn, db_rows, include_file=True)
        columns = COLUMNS_MULTI

    if not rows:
        print("no benchmark data found for that selection", file=sys.stderr)
        sys.exit(1)

    table = render_table(rows, columns)

    if args.out:
        with open(args.out, "w") as f:
            f.write(table + "\n")
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        print(table)

    conn.close()


if __name__ == "__main__":
    main()
