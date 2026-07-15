# llama.cpp nightly benchmark suite

Three scripts:

- **`bench_model.py`** — benchmarks *one* GGUF file with `llama-bench`
  (the official tool built into [ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp/tree/master/tools/llama-bench))
  and writes normalized rows into SQLite + appends a summary row to CSV.
  Can be run standalone against any file at any time.
- **`model_watcher.py`** — the nightly orchestrator. Scans your models
  folder for new `.gguf` files, registers them, and calls `bench_model.py`
  on anything not yet benchmarked, but only between **3:00–5:00 AM
  America/New_York**, and only up to a 30-minute cap per model.
- **`report.py`** — generates a shareable Markdown table from the SQLite
  data, formatted to match `llama-bench`'s own default console/Markdown
  output (the format people paste into GitHub issues/discussions and
  r/LocalLLaMA). Either a single-model report or a multi-model comparison
  table. See "Sharing results" below.

## Requirements

- A built `llama-bench` binary from llama.cpp (`cmake --build build
  --target llama-bench`, or use a release binary from the
  [releases page](https://github.com/ggml-org/llama.cpp/releases)).
  Make sure it's on `PATH` or pass `--bench-bin /path/to/llama-bench`.
- Python 3.9+ (uses `zoneinfo` for correct ET/DST handling).

## Install as a nightly cron job

```
crontab -e
```

Add — wimpy's real paths (models live in `~/.cache/llama.cpp`; the
package-managed ROCm `llama-bench` is at `/usr/bin/llama-bench` — do NOT
point this at `/usr/local/bin/llama-bench`, that was a stale hand-built
CUDA copy removed during the R9700 migration):

```
0 3 * * * TZ=America/New_York /usr/bin/python3 /home/rahlquist/Downloads/wimpy-setup/benching/model_watcher.py \
    --models-dir /home/rahlquist/.cache/llama.cpp \
    --db /home/rahlquist/Downloads/wimpy-setup/benching/bench.db \
    --csv /home/rahlquist/Downloads/wimpy-setup/benching/bench_summary.csv \
    --bench-bin /usr/bin/llama-bench \
    >> /home/rahlquist/Downloads/wimpy-setup/benching/watcher.log 2>&1
```

`TZ=America/New_York` on the cron line makes cron itself fire at 3:00 AM
ET regardless of the server's local timezone; the script's own window
check is also ET-aware (via `zoneinfo`) as a second safety net, and it
self-terminates at 5:00 AM ET even if cron's `TZ` handling is flaky on
your system.

The watcher loops internally (default: rescans every 5 minutes) so it
will pick up a model that finishes downloading at 3:40 AM without needing
a separate cron line.

## Manual / one-off test run

```
# benchmark a single file right now, ignoring the time window:
python3 bench_model.py --model ~/.cache/llama.cpp/some-model.Q4_K_M.gguf \
    --bench-bin /usr/bin/llama-bench --db bench.db --csv bench_summary.csv

# run the full watcher logic right now, ignoring the 3-5am window:
python3 model_watcher.py --models-dir ~/.cache/llama.cpp --db bench.db \
    --csv bench_summary.csv --bench-bin /usr/bin/llama-bench --force-run
```

## What gets measured, and why

`llama-bench` measures raw model-evaluation throughput only (no
tokenization/sampling overhead), reported as tokens/sec with stddev over
multiple repetitions — this is the standard, widely-quoted way people
compare llama.cpp performance across hardware and models (GitHub
discussions, r/LocalLLaMA, hardware-review blogs all report the same
`pp512` / `tg128` numbers).

Each model gets:

| test | what it proxies | why it matters |
|---|---|---|
| `pp512` | prompt processing (batch, compute-bound) | how long you wait before the model starts responding, given prior context |
| `tg128` | token generation (batch=1, memory-bandwidth-bound) | how fast the model "talks" once it's replying — the number most people mean by "tok/s" |
| `pp512+tg128 @ d4096` | same pair, but with 4096 tokens already in the KV cache | shows how much a model slows down in a realistic, longer conversation — this gap is often much bigger than people expect and varies a lot model-to-model |

`-ngl 999` forces max GPU layer offload (auto-clamped to the model's real
layer count) so you're comparing best-case configs; `-fa auto` lets
llama.cpp pick the best flash-attention setting for your backend (manually
forcing it on can be *slower* on some non-CUDA backends).

Repetitions default to 3 instead of llama-bench's default of 5, to leave
headroom in the 30-minute cap for big models — variance is still visible,
it's just estimated from 3 samples instead of 5.

### What this intentionally does NOT do

- **No perplexity/quality scoring** in the default nightly run — a
  meaningful perplexity pass (e.g. against a wikitext-2 slice) commonly
  takes much longer than 30 minutes on a 70B+ model on consumer hardware,
  and comparing perplexity *across different model families* isn't
  meaningful anyway (only across quants of the *same* model). If you want
  this, run `llama-perplexity` manually on models you're actively
  comparing quant levels of — it's a separate llama.cpp tool, not part of
  this pipeline.
- **No multi-user/batched throughput testing** — llama.cpp's own kernels
  aren't optimized for concurrent-request serving the way vLLM/SGLang/TGI
  are; if that's what you're actually trying to measure, this isn't the
  right tool.
- **No CPU-only fallback pass** — added time cost roughly doubles per
  model. If you want a GPU-vs-CPU comparison, run `bench_model.py`
  manually with a modified `-ngl 0` pass.

## Database schema

Two tables in `bench.db`:

- `models` — one row per file (`filepath`, size/mtime "fingerprint" so we
  detect re-downloads without hashing multi-GB files nightly, `status`:
  `pending` / `benchmarking` / `done` / `partial` / `failed`).
- `benchmark_runs` — one row per (model, test) combo per run, mirroring
  llama-bench's own JSON schema (cpu/gpu info, build commit, tokens/sec,
  stddev, etc.) so you can track regressions across llama.cpp versions
  too, not just across models.

`bench_summary.csv` is a flattened, append-only "latest numbers per
model" view meant for quickly eyeballing in a spreadsheet — the SQLite DB
is the source of truth if you want to slice by build/GPU/date.

## Sharing results

`report.py` reads `bench.db` and renders the same Markdown table style
`llama-bench` itself prints by default (`model | size | params | backend |
ngl | fa | test | t/s`), so a comparison you generate here looks the same
as what people already post in llama.cpp GitHub discussions or
r/LocalLLaMA.

Single model:
```
python3 report.py --db bench.db --model llama-2-7b.Q4_0.gguf
```
```
| model         |     size | params | backend | ngl | fa |  test |             t/s |
| ------------- | -------: | -----: | ------- | --: | -: | ----: | ---------------: |
| llama 7B Q4_0 | 3.56 GiB | 6.74 B | CUDA    |  99 |  1 | pp512 | 4200.32 ± 15.10 |
| llama 7B Q4_0 | 3.56 GiB | 6.74 B | CUDA    |  99 |  1 | tg128 |   142.87 ± 0.66 |
```

All benchmarked models, side by side (each model's *latest* run only):
```
python3 report.py --db bench.db --all --out comparison.md
```
This adds one extra leading `file` column (not present in vanilla
llama-bench output) so you can tell apart files that happen to share a
model-type/quant label — everything else matches llama-bench's own
column order, alignment, and `avg ± stddev` formatting exactly.

Both modes print to stdout by default, so you can pipe them (e.g. into
`pbcopy`/`xclip`) straight into a GitHub comment or forum post.

Add `--html` to either mode to generate a self-contained, sortable,
filterable HTML report instead of a Markdown table (e.g.
`python3 report.py --db bench.db --all --html --out bench_results.html`).
`bench_results.html` in this directory is a committed snapshot from a
real run — regenerate it after new benchmark data comes in rather than
hand-editing it.

## Multi-part (sharded) GGUF files

`model-00001-of-00005.gguf`, `model-00002-of-00005.gguf`, etc. are one
logical model. `model_watcher.py` only registers/benchmarks shard
`00001`; llama.cpp automatically pulls in the remaining shards when
pointed at the first one.
