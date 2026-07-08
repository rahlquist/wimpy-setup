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
    ("date", "date", "l"),
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


def fetch_runs(conn, model_id=None):
    """Return ALL benchmark_runs rows (optionally for one model). History is
    append-only and every run is shown — runs are told apart by the date
    column (2026-07-08: previously only each model's latest run was shown,
    which hid results from earlier GPU configs)."""
    where = "WHERE model_id = ?" if model_id else ""
    conn.row_factory = sqlite3.Row
    cur = conn.execute(
        f"SELECT * FROM benchmark_runs {where} ORDER BY model_id, id",
        (model_id,) if model_id else (),
    )
    return cur.fetchall()


def build_rows(conn, db_rows, include_file):
    filenames = {}
    if include_file:
        cur = conn.execute("SELECT id, filename FROM models")
        filenames = dict(cur.fetchall())

    rows = []
    for r in db_rows:
        keys = r.keys()
        epoch = r["date_run"] if "date_run" in keys and r["date_run"] else None
        if epoch:
            from datetime import datetime
            date_str = datetime.fromtimestamp(epoch).strftime("%Y-%m-%d")
        else:
            date_str = (r["run_time"] or "")[:10]
        row = {
            "date": date_str,
            "model": r["model_type"] or "",
            "size": fmt_size(r["model_size"]),
            "params": fmt_params(r["model_n_params"]),
            "backend": r["backends"] or "",
            "ngl": r["n_gpu_layers"] if r["n_gpu_layers"] is not None else "",
            "fa": r["flash_attn"] if r["flash_attn"] is not None else "",
            "test": r["test_name"] or "",
            "ts": fmt_ts(r["avg_ts"], r["stddev_ts"]),
            "_sort_test": test_sort_key(r["test_name"] or ""),
            "_date_run": epoch or 0,
            "_model_id": r["model_id"],
            "_size_bytes": r["model_size"] or 0,
            "_params_n": r["model_n_params"] or 0,
            "_avg_ts": r["avg_ts"] or 0,
        }
        if include_file:
            row["file"] = filenames.get(r["model_id"], "")
        rows.append(row)

    rows.sort(key=lambda r: (r.get("file", ""), r["_model_id"], r["_date_run"], r["date"], r["_sort_test"]))
    return rows


_HTML_TEMPLATE = """\
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>llama-bench results</title>
<style>
:root{--bg:#111214;--sur:#1c1e21;--bor:#2a2d31;--txt:#cdd9e5;--dim:#636e7b;--acc:#539bf5;--hi:rgba(83,155,245,.1)}
*{box-sizing:border-box;margin:0;padding:0}
body{background:var(--bg);color:var(--txt);font-family:ui-monospace,"Cascadia Code","Fira Mono","Consolas",monospace;padding:2rem;font-size:13px;line-height:1.5}
h1{font-size:1rem;font-weight:600;color:#e6edf3;margin-bottom:.3rem}
.meta{color:var(--dim);font-size:.8rem;margin-bottom:1.5rem}
.toolbar{display:flex;align-items:center;gap:.5rem;margin-bottom:.75rem;flex-wrap:wrap}
.lbl{color:var(--dim);font-size:.75rem}
.div{width:1px;height:1rem;background:var(--bor);margin:0 .25rem}
button{background:var(--sur);border:1px solid var(--bor);color:var(--dim);padding:.2rem .6rem;border-radius:4px;cursor:pointer;font-size:.75rem;font-family:inherit;transition:border-color .1s,color .1s}
button:hover{border-color:var(--acc);color:var(--txt)}
button.on{border-color:var(--acc);color:var(--acc);background:var(--hi)}
.wrap{overflow-x:auto}
table{border-collapse:collapse;min-width:100%}
th,td{padding:.35rem .75rem;border-bottom:1px solid var(--bor);white-space:nowrap}
th{background:var(--sur);color:var(--dim);font-weight:600;font-size:.7rem;text-transform:uppercase;letter-spacing:.07em;text-align:left;cursor:pointer;user-select:none;position:sticky;top:0;z-index:1}
th:hover{color:var(--acc)}
th[aria-sort="ascending"]::after{content:" ▲";color:var(--acc);font-size:.6rem}
th[aria-sort="descending"]::after{content:" ▼";color:var(--acc);font-size:.6rem}
.r{text-align:right}
td.file{color:var(--dim);max-width:24em;overflow:hidden;text-overflow:ellipsis}
td.ts{font-variant-numeric:tabular-nums}
tr.gap td{border-top:2px solid var(--bor)}
tr:hover td{background:var(--sur)}
.empty{padding:1.5rem .75rem;color:var(--dim);font-style:italic}
</style>
</head>
<body>
<h1>llama-bench results</h1>
<p class="meta" id="meta"></p>
<div class="toolbar">
  <span class="lbl">show:</span>
  <span id="filters"></span>
  <span class="div"></span>
  <button id="btn-copy">copy as markdown</button>
</div>
<div class="wrap">
  <table>
    <thead><tr id="hdr"></tr></thead>
    <tbody id="body"></tbody>
  </table>
</div>
<script>
const ROWS=__DATA_JSON__;
const GENERATED=__GENERATED__;
const COLS=[
  {k:"file",   label:"file",   cls:"file",num:false,fn:r=>r.file},
  {k:"date",   label:"date",   cls:"",    num:true, fn:r=>r.date_run},
  {k:"model",  label:"model",  cls:"",    num:false,fn:r=>r.model},
  {k:"size",   label:"size",   cls:"r",   num:true, fn:r=>r.size_bytes},
  {k:"params", label:"params", cls:"r",   num:true, fn:r=>r.params_n},
  {k:"backend",label:"backend",cls:"",    num:false,fn:r=>r.backend},
  {k:"ngl",    label:"ngl",    cls:"r",   num:true, fn:r=>+r.ngl||0},
  {k:"fa",     label:"fa",     cls:"r",   num:true, fn:r=>+r.fa||0},
  {k:"test",   label:"test",   cls:"r",   num:false,fn:r=>r.test},
  {k:"ts",     label:"t/s",    cls:"r ts",num:true, fn:r=>r.avg_ts},
];
const TEST_ORDER={pp512:0,tg128:1,"pp512@d4096":2,"tg128@d4096":3};
const ALL_TESTS=[...new Set(ROWS.map(r=>r.test))].sort((a,b)=>(TEST_ORDER[a]??9)-(TEST_ORDER[b]??9));
let active=new Set(ALL_TESTS),sCol=null,sDir=-1;

const hdrEl=document.getElementById("hdr");
COLS.forEach((c,i)=>{
  const th=document.createElement("th");
  th.className=c.cls; th.textContent=c.label;
  th.onclick=()=>{ sCol===i?sDir*=-1:(sCol=i,sDir=c.num?-1:1); render(); };
  hdrEl.appendChild(th);
});

const filtersEl=document.getElementById("filters");
ALL_TESTS.forEach(t=>{
  const b=document.createElement("button");
  b.textContent=t; b.className="on";
  b.onclick=()=>{ if(active.has(t)){if(active.size===1)return;active.delete(t);}else active.add(t); b.className=active.has(t)?"on":""; render(); };
  filtersEl.appendChild(b);
});

function visible(){return ROWS.filter(r=>active.has(r.test));}
function sorted(rows){
  if(sCol===null) return rows;
  const fn=COLS[sCol].fn;
  return [...rows].sort((a,b)=>{const av=fn(a),bv=fn(b);return av<bv?sDir:av>bv?-sDir:0;});
}
function render(){
  hdrEl.querySelectorAll("th").forEach((th,i)=>{
    th.removeAttribute("aria-sort");
    if(i===sCol) th.setAttribute("aria-sort",sDir>0?"ascending":"descending");
  });
  const rows=sorted(visible());
  const tbody=document.getElementById("body");
  tbody.innerHTML="";
  if(!rows.length){
    const tr=document.createElement("tr"),td=document.createElement("td");
    td.colSpan=COLS.length; td.className="empty"; td.textContent="no results";
    tr.appendChild(td); tbody.appendChild(tr); return;
  }
  let prev="";
  rows.forEach(r=>{
    const g=(r.file||r.model)+"|"+r.model+"|"+r.date;
    const tr=document.createElement("tr");
    if(g!==prev&&prev!=="") tr.classList.add("gap");
    prev=g;
    COLS.forEach(c=>{
      const td=document.createElement("td");
      td.className=c.cls; td.textContent=r[c.k]??"";
      if(c.k==="file"&&r.file) td.title=r.file;
      tr.appendChild(td);
    });
    tbody.appendChild(tr);
  });
}
(()=>{
  const n=new Set(ROWS.map(r=>r.file||r.model)).size;
  const gpus=[...new Set(ROWS.map(r=>r.backend).filter(Boolean))].join(", ");
  document.getElementById("meta").textContent=n+" model"+(n!==1?"s":"")+" · "+gpus+" · generated "+GENERATED;
})();
document.getElementById("btn-copy").onclick=()=>{
  const rows=sorted(visible());
  const hasFile=rows.some(r=>r.file);
  const cols=hasFile?COLS:COLS.filter(c=>c.k!=="file");
  const w={};
  cols.forEach(c=>{w[c.k]=c.label.length;});
  rows.forEach(r=>cols.forEach(c=>{w[c.k]=Math.max(w[c.k],String(r[c.k]??"").length);}));
  const pad=(v,c)=>{const s=String(v??""),n=w[c.k];return c.cls.includes("r")?s.padStart(n):s.padEnd(n);};
  const lines=["| "+cols.map(c=>pad(c.label,c)).join(" | ")+" |",
               "| "+cols.map(c=>"-".repeat(w[c.k])).join(" | ")+" |",
               ...rows.map(r=>"| "+cols.map(c=>pad(r[c.k]??"",c)).join(" | ")+" |")];
  navigator.clipboard.writeText(lines.join("\\n")).then(()=>{
    const b=document.getElementById("btn-copy");
    b.textContent="copied!"; setTimeout(()=>b.textContent="copy as markdown",1500);
  });
};
render();
</script>
</body>
</html>
"""


def render_html(rows):
    import json
    from datetime import datetime, timezone

    js_rows = []
    for r in rows:
        js_rows.append({
            "file":       r.get("file", ""),
            "date":       r.get("date", ""),
            "date_run":   r.get("_date_run", 0),
            "model":      r.get("model", ""),
            "size":       r.get("size", ""),
            "size_bytes": r.get("_size_bytes", 0),
            "params":     r.get("params", ""),
            "params_n":   r.get("_params_n", 0),
            "backend":    r.get("backend", ""),
            "ngl":        str(r.get("ngl", "")),
            "fa":         str(r.get("fa", "")),
            "test":       r.get("test", ""),
            "ts":         r.get("ts", ""),
            "avg_ts":     r.get("_avg_ts", 0),
        })

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    return (_HTML_TEMPLATE
            .replace("__DATA_JSON__", json.dumps(js_rows))
            .replace("__GENERATED__", json.dumps(generated)))


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
    ap.add_argument("--html", action="store_true", help="generate self-contained HTML instead of Markdown")
    args = ap.parse_args()

    conn = sqlite3.connect(args.db)
    conn.row_factory = sqlite3.Row

    if args.model:
        model_id = resolve_model_id(conn, args.model)
        db_rows = fetch_runs(conn, model_id)
        rows = build_rows(conn, db_rows, include_file=False)
        columns = COLUMNS_SINGLE
    else:
        db_rows = fetch_runs(conn)
        rows = build_rows(conn, db_rows, include_file=True)
        columns = COLUMNS_MULTI

    if not rows:
        print("no benchmark data found for that selection", file=sys.stderr)
        sys.exit(1)

    output = render_html(rows) if args.html else render_table(rows, columns)

    if args.out:
        with open(args.out, "w") as f:
            f.write(output + ("\n" if not args.html else ""))
        print(f"wrote {args.out}", file=sys.stderr)
    else:
        print(output)

    conn.close()


if __name__ == "__main__":
    main()
