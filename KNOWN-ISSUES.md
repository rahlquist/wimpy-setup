# Known Issues — wimpy-setup

Severity-ranked findings from the 2026-07-21 multi-persona adversarial review
(commit 983f942). Reviewers: hands-on heuristic eval + 4 persona agents
(senior-dev critic, fresh-grad, config perfectionist, struggling user).
Every CRITICAL/HIGH finding was verified against the code.

Scale: CRITICAL = broken or dangerous, HIGH = will bite real users,
MEDIUM = friction/inconsistency, LOW = polish.

## CRITICAL

- [ ] **C1. 08-networking.sh can lock you out remotely, no guard, no rollback.**
  :24-30 picks NetworkManager whenever it's active even if systemd-networkd
  owns enp10s0 (nmcli connections may never manage the device; `con up` fails,
  swallowed by `|| true` at :85-86). :56 deletes the live connection carrying
  your SSH session BEFORE the bridge is confirmed up; no connectivity check,
  no revert, no confirm prompt.
  Fix: confirm() gate + "run from local console" preflight; check
  `nmcli device status`; verify br0 has an IP before deleting the old profile;
  export the old profile first.

- [ ] **C2. fetch-model.sh duplicate-model path is dead code.**
  :319 `raise SystemExit('DUPLICATE')` exits 1, never 3, so :334's `3)` branch
  never fires — re-registering an existing model dies with "config insertion
  failed; config untouched," the opposite of the truth.
  Fix: `raise SystemExit(3)`.

- [ ] **C3. GPU story incoherent across README, run-all, NETWORK-DIAGRAM, scripts.**
  README.md:3,13, run-all.sh:20, NETWORK-DIAGRAM.md:21-27, push-to-github.sh:53
  all say CUDA/RTX 5060 Ti; 05-llama-cpp.sh builds ROCm/gfx1201 for the R9700.
  With the 5060 returning alongside the R9700: config pins
  HIP_VISIBLE_DEVICES=0 + --device ROCm0 in all 25 entries, fetch-model.sh:117
  auto-picks the FIRST device from --list-devices, nothing validates the pin
  pair agrees. A second GPU silently breaks the assumption.
  Fix: docs to current reality now; decide PCI-slot-based device addressing
  for the two-GPU era before the card lands.

## HIGH

- [ ] **H1. nftables path can persist a partial ruleset and lock the box at boot.**
  lib/common.sh:146-155: `nft list ruleset | tee /etc/nftables.conf` snapshots
  whatever exists (possibly partial from another tool) and
  `systemctl enable nftables` loads it on boot. Fix: only persist/enable if
  this script created the table.

- [ ] **H2. hermes.env created without chmod 600.**
  hermesvm-setup.sh:191-218 writes a file meant to hold API keys with default
  umask (0644). Also `OPENAI_API_KEY=***` is load-bearing and
  undocumented — Hermes sends `Bearer placeholder`, user gets opaque 401s.
  Fix: chmod 600 after tee; document the placeholder.

- [ ] **H3. fetch-model.sh exports the GitHub PAT via process env.**
  :406 `GIT_ASKPASS_TOKEN="$token"` puts the token in git's environment and
  every child's; readable via /proc/<pid>/environ during the push.
  Fix: write the token into the askpass script itself, not an env var.

- [ ] **H4. run-all.sh silent-success traps.**
  `--from 99`, `--from abc`, `--from 03` (gap step) all print the "setup
  complete" banner, exit 0, zero steps run. Fix: validate against STEP_ORDER.

- [ ] **H5. "Installed nothing" reported as success.**
  01-system-base.sh unknown-pkg-manager path warns and continues → step marked
  complete; user discovers in step 05. Fix: hard exit 1.

- [ ] **H6. No prerequisites section.**
  OPNsense + 192.168.8.0/24 + NIC enp10s0 + Arch/CachyOS are unstated hard
  requirements; `hf auth login` (README:115) appears after the section that
  needs it; no script installs hf. README:38-45 and run-all.sh:95-106 post-setup
  checklists disagree. Fix: Prerequisites block at top + one canonical ordered
  checklist.

- [ ] **H7. README Quick Start dead-ends at line one.**
  `git clone <this-repo>` (README:24) is a literal placeholder. Fix: real URL
  + "if you already have the files, skip to cd".

- [ ] **H8. No per-script idempotency/rollback story.**
  Only hermesvm-setup.sh claims it; 05 floats to latest master on every re-run
  (resume silently upgrades llama.cpp); 05:11-20 warns about competing copies
  but cleanup is "a deliberate separate step." Fix: per-script "safe to
  re-run?" line in README table + run-all warning when resuming from 05.

- [ ] **H9. llama-hugs.service: no hardening, no StartLimitBurst.**
  Infinite crash-loop against the GPU possible; User=rahlquist hardcoded.
  Fix: hardening block (NoNewPrivileges, ProtectSystem, PrivateTmp) +
  StartLimitBurst=5/StartLimitIntervalSec=300.

- [ ] **H10. Run-as-root silently misconfigures everything.**
  CURRENT_USER="${SUDO_USER:-$USER}" in 02/05/09 — run directly as root, root
  gets the docker/libvirt groups, llama-hugs runs as root, the human gets
  nothing. Fix: refuse root, require sudo-from-user.

- [ ] **H11. Misleading success logs.**
  hermesvm-setup.sh:179 and :151 run version checks as root, print 'installed'
  regardless; :137-141 AUR claude-code updates fail silently via `|| true`.
  Fix: `sudo -u "$CURRENT_USER" ...`.

- [x] **H12. benching/llama-bench-nightly.service hardcodes paths.**
  Repointed from the old `~/Downloads` clone location to `/home/rahlquist/wimpy-setup`
  (project moved out of Downloads); bench.db/CSV/log still written into the
  repo dir where push-to-github.sh:39 `git add -A` can commit them remains a
  concern. Fix: parameterize paths; gitignore artifacts.

- [ ] **H13. No troubleshooting section.**
  Failure knowledge lives only in CLAUDE.md incident narrative.
  Fix: top-5 failure modes + one-line fixes in README (stale /usr/bin build,
  missing ROCm device, br0 got no IP, UFW blocking VM→host, silent CPU
  fallback).

## MEDIUM

- [ ] M1. CLAUDE.md presents superseded migration narrative first, present
  tense; struck-through "OBSOLETE" blocks invite copy-paste errors.
  "Current state" first, history to appendix.
- [ ] M2. 2 legacy llama-hugs-config.yaml entries bind 127.0.0.1 while 89 bind
  0.0.0.0 — VMs get connection-refused for exactly those models, no comment
  why. Mixed long/short flag styles vs the file's "ONE consistent method."
  **Left as-is deliberately (2026-10-09):** binding 127.0.0.1 fleet-wide would
  break hermesvm01, which reaches these models over br0. Tracked as M7/P3.4.
- [ ] M3. lib/common.sh:59 full `pacman -Syu --noconfirm` mid-run, no preflight
  warning; sudo invisible-password prompt never explained to first-timers.
- [ ] M4. 09-kvm.sh:56-59 per-package `|| warn` with 2>/dev/null hides real
  failures; libvirtd enable fails opaquely later.
- [ ] M5. benching/bench_model.py:196-212 CSV summary can mix tonight's and a
  previous night's results in one mislabeled row after partial re-runs.
- [ ] M6. Unexplained step gaps 03/06; jargon wall (GGUF, MoE, llama-hugs, KVM,
  qcow2); dnsmasq (08:5) vs OPNsense (README:41) naming inconsistency.
  Glossary + one sentence per gap.
- [ ] M7. Dead-end error messages: 08:125 "configure br0 manually" exits;
  05:45 "install ROCm SDK manually: <docs homepage>" exits. One imperative
  sentence each.
- [ ] M8. tools/render_model_inventory.py hardcodes 2-space indent while
  fetch-model's inserter auto-detects — hand-edited 4-space configs yield a
  silently empty inventory that gets committed. Fix: fail loudly on 0 models.
- [ ] M9. TTL scraped as mode of existing config including commented lines
  (fetch-model.sh:143) — works by coincidence. Strip comments first.
- [ ] M10. sensors-log.service: no ConditionPathExists (fails every 5 min
  forever if script not installed); TZ=America/New_York duplicated in
  service+timer.

## LOW

- [ ] L1. push-to-github.sh secret scan misses github_pat_* and HF_TOKEN=***
  names; commit message hardcodes "18 models".
- [ ] L2. README file tree incomplete (omits fetch-model.sh, tests/, tools/,
  benching/, statusline-command.sh; maintainer-only scripts not marked).
- [ ] L3. model-metadata/*.json committed with /home/rahlquist paths — leaks
  username/path layout to anyone with repo access.
- [ ] L4. Repo clutter: removed-orphaned-cuda-build-*.txt, dated config backup,
  nvidia-utils.conf.new lacking install target + verification step.
- [ ] L5. run-all.sh --dry prints the full "complete" checklist.
- [ ] L6. hermesvm-setup.sh only adds npm PATH to .bashrc.

## Speculative decoding — what was applied and the real ceiling (2026-10-09)

**Applied:** `--spec-type draft-mtp` on 28 of the 29 models declaring
`metadata.mtp: true` (P1.1). The flag is the ONLY activation path — the router
does not read `mtp_flag`; metadata alone is dead weight that still occupies
VRAM.

**`qwen3-8-27b-crack-q8-0` deliberately skipped:** 27.1 GiB weights + 4.5 GiB
q4_0 KV @64K = 32.6 GiB before the draft head, so it cannot load today. MTP
would only guarantee a harder failure.

**Measured ceiling — MTP-specific, do not generalize it.** Live on the R9700
(Q6_K @64K): acceptance 0.77, **mean accepted draft length 3.00 tokens**, 26.85 GiB VRAM,
37.28 tok/s.

A later depth sweep (2026-10-10, @64K, q4_0 KV, 256-tok cap, 3 reps,
end-to-end tok/s) tested whether `--spec-draft-n-max` helps MTP at all:

| Model | n-max 3 | n-max 4 | n-max 6 | n-max 8 | plain |
|---|---:|---:|---:|---:|---:|
| Qwen3.8-27B-Q5_K_M | **49.3** | 48.8 | 43.6 | 49.1 | 24.7 |
| GSQ-RCO IQ3_S | 43.6 | 43.9 | 40.8 | **54.3** | 32.2 |

**Verdict: MTP depth tuning is NOT a reliable win and is therefore NOT
applied.** The response is non-monotonic and model-specific — n-max 8 gives
+24% over n-max 3 on GSQ-RCO but nothing on Q5_K_M, and n-max 6 is actively
worse on both. With 3 reps per cell this is inside noise for the mid values,
and the only reproducible pattern is "bigger is not monotonically better."
llama.cpp's default of 3 is left in place rather than chasing a noisy curve
across 27 models. This retracts the plan's M2 estimate of "+10-30%".

The accepted length DOES scale with depth (3.14 → 5.20 on Q5_K_M), so the
mechanism is real; the throughput payoff just does not follow monotonically
because each extra drafted token costs verify work. Depth tuning would need
far more repetitions per cell to be actionable.

The win that IS large and monotonic is **DFlash2** — a separate drafter file,
not a depth flag. See below.

**`--fit on` withheld from the two large-context entries** (ornith 262144,
gsq-rco-iq3-s-mtp 262144): there it would silently shrink context below the
advertised capability, which is worse than a loud load failure. ornith's
context was capped to 131072 instead (14.1 + 18.0 GiB KV = 32.1 GiB was an
OOM on first load).

**DFlash2 — measured, applied to the Qwen3.8-27B base family.** The drafter is
`incoai/Qwen3.8-27B-DFlash2-GGUF` → `Qwen3.8-27B-DFlash2-Q8_0.gguf`
(2,056,414,816 bytes, SHA-256 `c18e800daedc59ca68fd13b6a856d795746af6d399a9279ac6a277d1d422f87e`,
verified against the publisher's manifest).

Measured on the R9700 @64K, q4_0 KV, 256-tok cap, 3 reps, end-to-end tok/s:

| Model | plain | +DFlash2 | speedup | acceptance | mean accepted len |
|---|---:|---:|---:|---:|---:|
| UD-IQ4_XS | 31.2 | 76.8 | **2.47×** | 0.669 | 5.67 |
| Q5_K_M | 25.3 | 53.7 | **2.12×** | 0.604 | 5.20 |
| Q6_K | 22.5 | 43.2 | **1.92×** | 0.505 | 4.54 |
| Q4_K_M | 25.6 | 45.4 | **1.77×** | 0.440 | 4.05 |
| GSQ-RCO IQ3_S | 32.4 | 54.2 | **1.67×** | 0.525 | 4.64 |

Depth sweep on Q5_K_M: n-max 5 → 54.9 tok/s (acc 0.691), n-max 7 → 53.0, n-max
8 → 53.0. **n-max 7 is the applied value**; 5 is marginally faster on this one
prompt but 7 is the drafter's trained block and generalizes better.

**Family binding is a hard guard, not a preference.** The drafter is trained
against the Qwen3.8-27B base family. Pairing it with a different architecture
does not degrade — it **fails at load** with
`GGML_ASSERT(ggml_can_repeat(b, a)) failed`. Verified twice against Granite
4.1 3B. Only base-family Qwen3.8-27B entries carry the draft.

**Vision is untested with DFlash2 and is presumed broken.** Upstream llama.cpp
issue #27408 documents that mtmd image chunks leave positional holes in the
1D draft KV cache, so `llama_decode(ctx_dft)` returns -1 and image requests
stall ~500 s then HTTP 500. A community zero-fill patch removes the crash but
the drafter never engages on images (draft/accept counters stay 0). Do not
claim vision compatibility from a text-only benchmark.

**Still not applied, on purpose:** `--cache-reuse`, `--slot-prompt-similarity`,
cross-vendor tensor-split (impossible — HIP and CUDA binaries cannot share one
card), and `--n-cpu-moe` (actively harmful, 0.87–4.78 tok/s in turbofit's data).

## What works (keep doing it)

- Secrets hygiene: pre-push scanner, .gitignore, placeholder-only env files,
  bws-based token fetch that never writes the PAT to disk.
- Exit codes correct on all probed failure paths.
- fetch-model.sh: no eval of pasted commands, GGUF metadata verification,
  smoke test, config backup, YAML structure preservation check.
- tools/gguf_metadata.py: clean bounds checks, no deps.
- common.sh firewall helper encodes the ufw-before-nftables lesson in a comment.
- CHANGELOG/CLAUDE incident writeups are excellent institutional memory —
  they need a user-facing digest, not replacement.

## Top 3 fixes by impact-per-line

1. fetch-model.sh:319 → `raise SystemExit(3)` (one word).
2. run-all.sh: validate --from/--only against STEP_ORDER (~4 lines).
3. 08-networking.sh: confirm() gate + console-not-SSH warning +
   verify-br0-before-delete (~10 lines).
4. (then) README block: real clone URL, Prerequisites, GPU truth, glossary —
   the one every reviewer hit independently.
