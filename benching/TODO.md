# benching/TODO

Operational follow-ups for the wimpy benchmark suite. See README.md for how the
nightly sweep works.

## TODO: replace the committed static HTML with a served, always-current resource

**Problem observed (2026-08-01):** `bench_results.html` is a *static artifact
committed to git* and regenerated only when someone runs `report.py` by hand.
The CUDA (RTX 5060 Ti) pass ran on 2026-07-30, but the committed HTML still
showed only the 2026-07-26 ROCm results — the CUDA data was in `bench.db`
(100 rows, `backends='CUDA'`) the whole time, just not rendered. The report
predated the CUDA results and nobody re-ran `report.py`. Lesson: a
git-committed snapshot drifts from the DB whenever a GPU pass lands between
manual regenerations.

**Goal:** a *served* resource that reflects `bench.db` live (or is regenerated
automatically by the nightly timer), so both GPUs' results are always visible
without a manual commit.

**Open design questions (decide before building):**
- Reachability: serve off-box like llama-swap (port 8080, reachable from
  hermesvm01 over br0) or local-only on wimpy for now?
- Existing web stack on wimpy to slot into (nginx/caddy), or a standalone
  minimal static server on its own port (e.g. 8081)?
- Render strategy:
  1. Nightly timer regenerates HTML AND drops it into a web-served path
     (no git commit; always fresh). Lowest effort.
  2. Small read-only endpoint over `bench.db` (datasette / Flask / FastAPI)
     that renders live — no regen step at all. Most robust, heavier to stand up.

**Acceptance:** after a nightly pass completes, the served page shows both
`ROCm` (R9700) and `CUDA` (RTX 5060 Ti) rows with no manual intervention or
git commit.

---

## Notes / non-blocking
- `bench.db`, `bench_summary.csv`, `watcher.log` are gitignored (generated
  runtime data, not source). Only `bench_results.html` has historically been
  committed — that's the artifact this TODO proposes retiring.
- `run-nightly-bench.sh` does NOT commit/push; the report regeneration is the
  last step. Any "served resource" should be driven from the same script/timer.
