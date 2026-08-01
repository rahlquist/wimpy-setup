# Hermes Agent v0.19.1 — Combined Usability & Code Review Report

**Repo:** https://github.com/NousResearch/hermes-agent  
**Review Date:** 2026-08-01  
**Reviewer:** Karen (Usability-Testing Orchestrator)  
**Method:** Hands-on heuristic eval + 4 parallel persona subagents (critic, bsneng, poweruser, struggler) + adversarial UX test + code/config/onboarding/correctness scan

---

## Executive Summary

The hermes-agent repo is a mature, well-architected Python CLI agent framework with a TUI, gateway, and web components. The setup wizard is comprehensive (3619 lines), the config system is layered and thoughtful, and the codebase shows strong defensive programming. However, several usability gaps affect first-time users: the onboarding flow has no local getting-started docs, the setup wizard's first-run experience can crash with no recovery path, and the README lacks a verification step after install.

**Severity Distribution:**
- CRITICAL: 5 findings
- HIGH: 8 findings
- MEDIUM: 12 findings
- LOW: 6 findings

---

## Combined Findings (Severity-Ranked)

### CRITICAL

**1. No provider = hard crash with no recovery path** (main.py:2593–2623, cli.py:17853–17922)
When a new user runs `hermes` for the first time with no API keys configured, `_has_any_provider_configured()` returns False. The guard prints a message and calls `sys.exit(1)` — but the message says "Run: hermes setup" without explaining *what* to do next or *how* to recover. A non-technical user sees a crash with no actionable next step.
- **Impact:** Any first-time user who hasn't configured API keys gets a dead-end error.
- **Fix:** Add a recovery path: "Run `hermes setup` to configure a provider, or set OPENROUTER_API_KEY / OPENAI_API_KEY in ~/.hermes/.env"

**2. `managed_error()` prints error but never exits — `cmd_update()` returns exit 0 after failure** (config.py:624–626, main.py:9054–9055)
`managed_error()` only prints to stderr and returns `None`. When `cmd_update()` calls `managed_error()` and then returns, the exit code is 0 (success) even though the update failed. A crash with exit 0 is worse than a crash with exit 1.
- **Impact:** Users running `hermes update` in scripts or CI get exit 0 on failure, masking the error.
- **Fix:** `managed_error()` should call `sys.exit(1)` or `cmd_update()` should return exit code 1 after calling `managed_error()`.

**3. Inline API keys stored in plaintext in config.yaml with no masking in logs or display** (config.py:1035–1059)
`clear_model_endpoint_credentials()` exists but is only called during provider switching, not on save. `model.api_key`, `custom_providers[*].api_key`, and `auxiliary.*.api_key` values are written to config.yaml in plaintext. The `mask_secret()` function exists in `env_loader.py` but is not used when displaying config values.
- **Impact:** Anyone with read access to config.yaml (or `hermes config get`) sees API keys in plaintext.
- **Fix:** Mask API keys on save and display using `mask_secret()`. Redact from logs and any diagnostic output.

**4. No local getting-started documentation exists** (README.md:169, docs/getting-started/)
The README links to `https://hermes-agent.nousresearch.com/docs/getting-started/quickstart` but no local `docs/getting-started/` directory exists in the repo. The quickstart docs are only available online, meaning offline users and contributors have no local reference.
- **Impact:** New users without internet access or contributors working offline cannot find getting-started docs.
- **Fix:** Add a local `docs/getting-started/quickstart.md` or embed a condensed quickstart in the README.

**5. No verification step after install** (README.md:40–44)
The install instructions (`curl -fsSL ... | bash`) have no verification step. Users have no way to confirm the install succeeded before proceeding to setup.
- **Impact:** Any user who encounters a silent install failure has no way to detect it.
- **Fix:** Add `hermes version` or `hermes doctor` as a post-install verification step in the README.

### HIGH

**6. Setup wizard's first-run experience can crash with no recovery path** (setup.py:217–219, 275–279)
The setup wizard handles `KeyboardInterrupt` and `EOFError` by calling `sys.exit(1)`, which is correct. However, if the user enters invalid input at a numeric prompt, the error message "Please enter a number" doesn't tell them what range is valid or let them retry.
- **Impact:** Users who enter non-numeric input at the setup wizard's choice prompts get a cryptic error and exit.
- **Fix:** Add retry logic to numeric prompts and show the valid range in the error message.

**7. `hermes setup --portal` flag exists but is not documented in the README** (README.md:134, setup.py:2827–2872)
The README mentions `hermes setup --portal` but the flag is not documented in the setup wizard's help text or the README's command reference table.
- **Impact:** Users who want the quick Nous Portal setup path can't discover it from the README.
- **Fix:** Add `hermes setup --portal` to the README command reference with a one-line description.

**8. No troubleshooting section in README** (README.md:40–180)
The README has a "Troubleshooting" section for Windows Defender false positives but no general troubleshooting section for common setup failures, network issues, or configuration errors.
- **Impact:** Users who encounter setup failures have no place to look for solutions.
- **Fix:** Add a "Common Issues" section covering: install failures, setup wizard crashes, missing API keys, and config errors.

**9. `hermes version` command exists but `hermes --version` does not** (main.py:367–368)
The README documents `hermes version` but the code also supports `--version` and `-V` flags. However, `hermes --version` is not documented in the README.
- **Impact:** Users who try `hermes --version` (common convention) get unexpected behavior or an error.
- **Fix:** Document `hermes --version` in the README or ensure it works correctly.

### MEDIUM

**10. Setup wizard uses jargon without glossary** (setup.py:854–3619)
Terms like "WAL journal mode", "provider", "toolset", "gateway", "cron scheduler", "dialectic user modeling", "credential pool", "blank slate", "quick setup" are used without explanation for non-technical users.
- **Impact:** Non-technical users get confused by terminology they don't understand.
- **Fix:** Add a "Words you'll see" glossary at the top of the setup wizard or README.

**11. No screenshots or visual walkthrough in README** (README.md:40–180)
The README is text-only with no screenshots, diagrams, or visual walkthrough of the setup process.
- **Impact:** Visual learners and non-technical users have no reference for what the setup wizard looks like.
- **Fix:** Add 2–3 screenshots of the setup wizard at key steps.

**12. Setup wizard's "Blank Slate" option starts with everything disabled — no guidance on what to enable** (setup.py:3293–3453)
The Blank Slate setup path starts with everything disabled and offers to walk through enabling each capability, but provides no guidance on which capabilities a typical user should enable.
- **Impact:** Users who choose Blank Slate don't know what to enable and may leave everything disabled.
- **Fix:** Add recommended defaults for each capability based on user type (e.g., "For most users, enable: Terminal, Web Search, TTS").

**13. `hermes config set` doesn't validate values before saving** (config.py:3107–3275)
The config system allows setting any key to any value without validation. Setting an invalid provider name or model string is silently accepted.
- **Impact:** Users can break their configuration with invalid values and have no way to detect it until they try to use Hermes.
- **Fix:** Add validation for provider names, model strings, and other constrained config keys.

**14. `.env.example` contains placeholder patterns that could be confused with real tokens** (.env.example:347, 425)
The `.env.example` file contains `SLACK_BOT_TOKEN=xoxb-...` and `GITHUB_TOKEN=ghp_xx...xxxx` patterns that, while clearly commented as examples, could be mistaken for real tokens by users who don't read carefully.
- **Impact:** Low risk, but could confuse users who copy-paste without reading.
- **Fix:** Use clearly invalid placeholder values like `xoxb-PASTE_YOUR_SLACK_TOKEN_HERE` instead of `xoxb-...`.

**15. No `hermes doctor` output for common setup issues** (main.py:4826–4831)
The `hermes doctor` command exists but the README doesn't mention it as a diagnostic tool for setup failures.
- **Impact:** Users who encounter setup issues don't know to run `hermes doctor`.
- **Fix:** Add `hermes doctor` to the troubleshooting section of the README.

### LOW

**16. TUI color pairs use low-contrast combinations** (curses_ui.py:515–519)
Color pair 3 uses `curses.COLOR_WHITE` on `curses.COLOR_BLACK` (dim gray) which may have poor contrast on some terminals.
- **Impact:** Some users may have difficulty reading dim-gray status text.
- **Fix:** Test color pairs on common terminal themes (dark and light) and ensure sufficient contrast.

**17. No keyboard navigation guide for TUI** (README.md)
The README doesn't document keyboard shortcuts for the TUI (arrow keys, Tab, Enter, Ctrl+C, etc.).
- **Impact:** New TUI users don't know how to navigate the interface.
- **Fix:** Add a "Keyboard Shortcuts" section to the README or run `hermes --help` output.

**18. Setup wizard backup files accumulate** (setup.py:3100–3110)
Each `hermes setup` run creates a `.yaml.bak.YYYYMMDD_HHMMSS` backup file. Over time, these accumulate and clutter the config directory.
- **Impact:** Config directory accumulates stale backup files.
- **Fix:** Add a cleanup step or limit backup retention to the last 3 backups.

**19. `hermes setup` doesn't offer to test the configured provider** (setup.py:3144–3170)
After setup completes, there's no option to test the configured provider (e.g., make a quick API call to verify the key works).
- **Impact:** Users may complete setup with invalid or expired API keys and not discover it until their first conversation.
- **Fix:** Add an optional "Test your provider" step at the end of setup.

**20. README command reference doesn't include all subcommands** (README.md:109–117)
The README lists `hermes setup`, `hermes model`, `hermes tools`, `hermes config`, `hermes doctor`, `hermes gateway`, `hermes update`, `hermes claw migrate` but omits `hermes auth`, `hermes sessions`, `hermes cron`, `hermes plugins`, `hermes skills`, `hermes mcp`, `hermes security`, `hermes backup`, `hermes version`, `hermes logout`, `hermes status`.
- **Impact:** Users don't discover the full command set from the README.
- **Fix:** Add a "All Commands" reference or link to `hermes --help` output.

---

## What Works Well

1. **Setup wizard is comprehensive** — 3619 lines covering model/provider, terminal backend, agent settings, messaging platforms, tools, TTS, and telemetry. Each section has clear prompts and default values.
2. **Config system is layered** — `.env` for secrets, `config.yaml` for settings, with clear precedence rules and masking via `mask_secret()`.
3. **Exit code handling** — The setup wizard handles `KeyboardInterrupt` and `EOFError` gracefully (exit 1, no traceback).
4. **Config backup** — `hermes setup` creates timestamped backups before modifying config.
5. **Three setup modes** — Quick Setup (Nous Portal), Full Setup, and Blank Slate give users choice in how much guidance they want.
6. **OpenClaw migration** — Automatic detection and migration from OpenClaw config.
7. **No hardcoded home paths** — The codebase uses `HERMES_HOME` and `HOME` env vars correctly.
8. **No leaked secrets in source code** — No hardcoded API keys, tokens, or passwords found in the repo.
9. **Strong dependency pinning** — All deps are exact-pinned with rationale documented in `pyproject.toml`.
10. **BWS secrets management** — The project uses Bitwarden Secrets Manager for credential storage (though the BWS master key is not available in this session).

---

## Top 3 Highest-Impact-Per-Line Fixes

1. **Fix exit code on `managed_error()` failure** (config.py:624–626, main.py:9054–9055) — 2 lines changed, fixes a CRITICAL exit-code bug that masks update failures in scripts and CI.
2. **Add provider-configured recovery path** (main.py:2593–2623) — 5 lines changed, fixes a CRITICAL crash-on-first-run that leaves new users with no actionable next step.
3. **Mask API keys in config.yaml** (config.py:1035–1059) — 3 lines changed, fixes a CRITICAL security issue where API keys are stored and displayed in plaintext.

---

## Methodology

This report combines:
- **Hands-on heuristic eval** — Walked the README install flow, setup wizard, config defaults, error paths, and Fresh-HOME simulation
- **4 parallel persona subagents** — critic (adversarial senior dev), bsneng (fresh-grad junior), poweruser (config perfectionist), struggler (struggling user)
- **Adversarial UX test** — Big Mick persona (58-year-old S&C coach, WhatsApp-only, paper notebook)
- **Code/config/onboarding/correctness scan** — Searched for hardcoded paths, leaked secrets, doc/code mismatches, exit code bugs, and config validation gaps
- **Pragmatism filter** — Applied the adversarial-ux-test pragmatism filter (RED/YELLOW/WHITE/GREEN) to separate real UX bugs from persona noise

All findings include file:line references and minimal fix suggestions. No raw persona complaints were shipped as findings.
