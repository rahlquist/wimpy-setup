#!/usr/bin/env bash
# push-to-github.sh — create a PRIVATE GitHub repo and push this project.
#
# Run this on a machine where you're authenticated to GitHub (wimpy is fine if
# you've run `gh auth login`). It uses the GitHub CLI (gh) if available, else
# falls back to plain git with a remote you provide.
#
# Usage:
#   ./push-to-github.sh                      # repo name defaults to wimpy-setup
#   ./push-to-github.sh my-repo-name         # custom repo name

set -euo pipefail

REPO_NAME="${1:-wimpy-setup}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Safety: refuse to push if a secret is detected ───────────────────────────
echo "Scanning for secrets before push..."
if grep -rniE 'hf_[a-z0-9]{30,}|sk-[a-z0-9]{20,}|ghp_[a-z0-9]{30,}|AKIA[0-9A-Z]{16}' . \
        --exclude-dir=.git 2>/dev/null; then
    echo "✖ ABORT: possible secret found above. Remove it before pushing."
    exit 1
fi
if find . -type f \( -iname '*token*' -o -name '*.env' \) -not -path './.git/*' | grep -q .; then
    echo "✖ ABORT: a token/env file is present. It must be removed or gitignored."
    find . -type f \( -iname '*token*' -o -name '*.env' \) -not -path './.git/*'
    exit 1
fi
echo "✔ No secrets detected."
echo ""

# ── Init git if needed ───────────────────────────────────────────────────────
if [[ ! -d .git ]]; then
    git init
    git branch -M main
fi

git add -A
git status --short
echo ""

# Show what WILL be committed — confirm no secrets slipped through gitignore
echo "Files staged for commit:"
git diff --cached --name-only
echo ""
read -r -p "Proceed with commit and push to a PRIVATE repo '$REPO_NAME'? [y/N] " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

git commit -m "wimpy inference host + hermesvm01 setup

Bare-metal llama.cpp/llama-swap inference host (CachyOS, RTX 5060 Ti) with
bridged KVM guest running Hermes Agent. 18 models, all loading at 64K context.
See CHANGELOG.md for details." || echo "(nothing new to commit)"

# ── Create + push via gh CLI if available ────────────────────────────────────
if command -v gh >/dev/null 2>&1; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "gh is installed but not authenticated. Run: gh auth login"
        exit 1
    fi
    # Create the private repo and push in one step (idempotent-ish: errors if it
    # already exists, in which case we just push to the existing remote).
    if gh repo view "$REPO_NAME" >/dev/null 2>&1; then
        echo "Repo $REPO_NAME already exists — pushing to it."
        git remote get-url origin >/dev/null 2>&1 || \
            git remote add origin "$(gh repo view "$REPO_NAME" --json sshUrl -q .sshUrl)"
        git push -u origin main
    else
        gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
    fi
    echo ""
    echo "✔ Done. View it:  gh repo view $REPO_NAME --web"
else
    echo "gh CLI not found. Manual path:"
    echo "  1. Create a PRIVATE repo named '$REPO_NAME' at https://github.com/new"
    echo "  2. Then run:"
    echo "       git remote add origin git@github.com:<you>/$REPO_NAME.git"
    echo "       git push -u origin main"
fi
