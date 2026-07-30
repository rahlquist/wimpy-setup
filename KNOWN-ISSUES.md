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

- [ ] **H9. llama-swap.service: no hardening, no StartLimitBurst.**
  Infinite crash-loop against the GPU possible; User=rahlquist hardcoded.
  Fix: hardening block (NoNewPrivileges, ProtectSystem, PrivateTmp) +
  StartLimitBurst=5/StartLimitIntervalSec=300.

- [ ] **H10. Run-as-root silently misconfigures everything.**
  CURRENT_USER="${SUDO_USER:-$USER}" in 02/05/09 — run directly as root, root
  gets the docker/libvirt groups, llama-swap runs as root, the human gets
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
- [ ] M2. 3 legacy llama-swap-config.yaml entries bind 127.0.0.1 while 23 bind
  0.0.0.0 — VMs get connection-refused for exactly those models, no comment
  why. Mixed long/short flag styles vs the file's "ONE consistent method."
- [ ] M3. lib/common.sh:59 full `pacman -Syu --noconfirm` mid-run, no preflight
  warning; sudo invisible-password prompt never explained to first-timers.
- [ ] M4. 09-kvm.sh:56-59 per-package `|| warn` with 2>/dev/null hides real
  failures; libvirtd enable fails opaquely later.
- [ ] M5. benching/bench_model.py:196-212 CSV summary can mix tonight's and a
  previous night's results in one mislabeled row after partial re-runs.
- [ ] M6. Unexplained step gaps 03/06; jargon wall (GGUF, MoE, llama-swap, KVM,
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
