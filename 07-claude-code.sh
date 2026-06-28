#!/usr/bin/env bash
# 07-claude-code.sh — install Claude Code via npm (user-prefix, no sudo needed)
#
# Installs to: ~/.npm-global/bin/claude
# Works with bash, zsh, and fish

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "07 — Claude Code"

INSTALL_USER="${SUDO_USER:-$USER}"

install_claude_code() {
    local user_home
    user_home="$(getent passwd "$INSTALL_USER" | cut -d: -f6)"
    local npm_prefix="${user_home}/.npm-global"

    # ── Ensure Node.js is present ─────────────────────────────────────────────
    if ! command -v node &>/dev/null; then
        err "Node.js not found. Run 01-system-base.sh first."
        exit 1
    fi
    log "Node: $(node --version)  npm: $(npm --version)"

    # ── Configure npm global prefix (user-writable, no sudo npm -g) ──────────
    log "Setting npm global prefix to ${npm_prefix}"
    sudo -u "$INSTALL_USER" npm config set prefix "$npm_prefix"

    # ── Add npm-global/bin to PATH for each shell ─────────────────────────────
    SHELL_NAME="$(getent passwd "$INSTALL_USER" | cut -d: -f7 | xargs basename)"
    log "Detected shell: $SHELL_NAME"

    case "$SHELL_NAME" in
      bash)
        RC="${user_home}/.bashrc"
        EXPORT_LINE='export PATH="$HOME/.npm-global/bin:$PATH"'
        if ! grep -qF ".npm-global/bin" "$RC" 2>/dev/null; then
            echo "$EXPORT_LINE" >> "$RC"
            log "Added npm-global to $RC"
        fi
        ;;

      zsh)
        RC="${user_home}/.zshrc"
        EXPORT_LINE='export PATH="$HOME/.npm-global/bin:$PATH"'
        if ! grep -qF ".npm-global/bin" "$RC" 2>/dev/null; then
            echo "$EXPORT_LINE" >> "$RC"
            log "Added npm-global to $RC"
        fi
        ;;

      fish)
        FISH_CFG="${user_home}/.config/fish/config.fish"
        mkdir -p "$(dirname "$FISH_CFG")"
        FISH_LINE='fish_add_path $HOME/.npm-global/bin'
        if ! grep -qF ".npm-global/bin" "$FISH_CFG" 2>/dev/null; then
            echo "$FISH_LINE" >> "$FISH_CFG"
            log "Added npm-global to $FISH_CFG"
        fi
        ;;

      *)
        warn "Unknown shell $SHELL_NAME — add ~/.npm-global/bin to PATH manually"
        ;;
    esac

    # Also make it available in the current session for the install step
    export PATH="${npm_prefix}/bin:$PATH"

    # ── Install Claude Code ───────────────────────────────────────────────────
    if command -v claude &>/dev/null; then
        CURRENT_VER="$(claude --version 2>/dev/null | head -1 || echo 'unknown')"
        info "Claude Code already installed: $CURRENT_VER"
        log "Upgrading Claude Code"
        sudo -u "$INSTALL_USER" npm install -g @anthropic-ai/claude-code \
            --prefix "$npm_prefix"
    else
        log "Installing Claude Code"
        sudo -u "$INSTALL_USER" npm install -g @anthropic-ai/claude-code \
            --prefix "$npm_prefix"
    fi

    # ── Run post-install script if blocked (same workaround as slug) ──────────
    INSTALL_CJS="${npm_prefix}/lib/node_modules/@anthropic-ai/claude-code/scripts/install.cjs"
    if [[ -f "$INSTALL_CJS" ]]; then
        log "Running post-install script"
        sudo -u "$INSTALL_USER" node "$INSTALL_CJS" 2>/dev/null || \
            warn "Post-install script failed (non-fatal — claude may still work)"
    fi

    # ── Symlink to /usr/local/bin for system-wide access ─────────────────────
    CLAUDE_BIN="${npm_prefix}/bin/claude"
    if [[ -f "$CLAUDE_BIN" ]]; then
        sudo ln -sf "$CLAUDE_BIN" /usr/local/bin/claude
        log "Symlinked to /usr/local/bin/claude"
    fi

    # ── Verify ────────────────────────────────────────────────────────────────
    if "${npm_prefix}/bin/claude" --version &>/dev/null; then
        log "Claude Code installed: $("${npm_prefix}/bin/claude" --version)"
    else
        warn "claude binary not responding — check PATH after opening new shell"
    fi
}

install_claude_code

log "07-claude-code complete"
info ""
info "  Binary: $(command -v claude 2>/dev/null || echo '~/.npm-global/bin/claude')"
info ""
info "  First run: open a NEW shell (or source your rc file), then:"
info "    claude auth     # authenticate with your Anthropic account"
info "    claude          # start interactive session"
info ""
info "  If 'claude' not found: source ~/.bashrc (or restart shell)"
info ""
info "Next: run 08-networking.sh"
