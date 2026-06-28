#!/usr/bin/env bash
# hermesvm-setup.sh — post-install configuration for a Hermes VM on wimpy
#
# Run this INSIDE the VM after CachyOS+MATE is installed and booted.
# Safe to re-run. Pass a different --hostname for each new VM.
#
# Usage:
#   bash hermesvm-setup.sh --hostname hermesvm01
#   bash hermesvm-setup.sh --hostname hermesvm02
#
# What it does:
#   - Sets the system hostname
#   - Installs system packages and Claude Code
#   - Installs Hermes Agent (--skip-browser, headless-safe)
#   - Writes hermes.env pointing at wimpy.home.lan:8080
#   - Installs and enables the hermes systemd service

set -euo pipefail

# ── Minimal inline helpers (no lib/common.sh dependency) ─────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✖${NC} $*" >&2; }
info() { echo -e "  $*"; }
step() {
    echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"
    echo -e "${BOLD}${CYAN}  $*${NC}"
    echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"
}

# ── Argument parsing ──────────────────────────────────────────────────────────
VM_HOSTNAME=""
WIMPY_HOST="wimpy.home.lan"   # change if your domain differs
LLAMA_PORT="8080"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hostname) VM_HOSTNAME="$2"; shift 2 ;;
        --wimpy)    WIMPY_HOST="$2";  shift 2 ;;
        --port)     LLAMA_PORT="$2";  shift 2 ;;
        -h|--help)
            grep '^#' "$0" | head -16 | sed 's/^# \?//'
            exit 0
            ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

if [[ -z "$VM_HOSTNAME" ]]; then
    err "--hostname is required"
    err "Usage: bash hermesvm-setup.sh --hostname hermesvm01"
    exit 1
fi

LLAMA_URL="http://${WIMPY_HOST}:${LLAMA_PORT}/v1"
CURRENT_USER="${SUDO_USER:-$USER}"
USER_HOME="$(getent passwd "$CURRENT_USER" | cut -d: -f6)"
HERMES_ENV="${USER_HOME}/.hermes/hermes.env"

echo ""
echo "  Hostname  : $VM_HOSTNAME"
echo "  Wimpy URL : $LLAMA_URL"
echo "  User      : $CURRENT_USER"
echo ""

# ── Require sudo ──────────────────────────────────────────────────────────────
if ! sudo -v &>/dev/null; then
    err "This script needs sudo access."; exit 1
fi

# ── 1. Hostname ───────────────────────────────────────────────────────────────
step "1 — Hostname → $VM_HOSTNAME"

CURRENT_HOSTNAME="$(hostname -s)"
if [[ "$CURRENT_HOSTNAME" != "$VM_HOSTNAME" ]]; then
    sudo hostnamectl set-hostname "$VM_HOSTNAME"
    # Update /etc/hosts — replace any existing 127.0.1.1 line
    if grep -q '127.0.1.1' /etc/hosts; then
        sudo sed -i "s/^127\.0\.1\.1.*/127.0.1.1\t${VM_HOSTNAME}/" /etc/hosts
    else
        echo -e "127.0.1.1\t${VM_HOSTNAME}" | sudo tee -a /etc/hosts > /dev/null
    fi
    log "Hostname set to $VM_HOSTNAME"
else
    info "Hostname already $VM_HOSTNAME — skipping"
fi

# ── 2. System packages ────────────────────────────────────────────────────────
step "2 — System packages"

sudo pacman -Syu --noconfirm

PKGS=(
    base-devel git curl wget rsync
    tmux htop btop neovim
    python uv
    nodejs npm
    xz zip unzip
    openssh
)
sudo pacman -S --needed --noconfirm "${PKGS[@]}"
log "Base packages installed"

# ── 3. Claude Code ───────────────────────────────────────────────────────────
step "3 — Claude Code"

install_claude_npm() {
    local npm_prefix="${USER_HOME}/.npm-global"
    sudo -u "$CURRENT_USER" npm config set prefix "$npm_prefix"

    # PATH for this session
    export PATH="${npm_prefix}/bin:$PATH"

    sudo -u "$CURRENT_USER" npm install -g @anthropic-ai/claude-code \
        --prefix "$npm_prefix"

    # Post-install script (same workaround as wimpy host)
    local postcjs="${npm_prefix}/lib/node_modules/@anthropic-ai/claude-code/scripts/install.cjs"
    [[ -f "$postcjs" ]] && sudo -u "$CURRENT_USER" node "$postcjs" 2>/dev/null || true

    sudo ln -sf "${npm_prefix}/bin/claude" /usr/local/bin/claude

    # Add to shell RC
    local rc="${USER_HOME}/.bashrc"
    if ! grep -qF '.npm-global/bin' "$rc" 2>/dev/null; then
        echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$rc"
    fi
}

if command -v claude &>/dev/null; then
    info "Claude Code already installed: $(claude --version 2>/dev/null | head -1)"
    info "Updating..."
    # Try pacman/AUR first, fall back to npm upgrade
    if pacman -Q claude-code &>/dev/null 2>&1; then
        sudo pacman -S --needed --noconfirm claude-code 2>/dev/null || true
    else
        install_claude_npm
    fi
else
    # Try CachyOS/AUR package first
    if sudo pacman -S --needed --noconfirm claude-code 2>/dev/null; then
        log "Claude Code installed via pacman"
    else
        warn "claude-code not in pacman repos — installing via npm"
        install_claude_npm
    fi
fi
log "Claude Code: $(claude --version 2>/dev/null | head -1 || echo 'installed')"

# ── 4. Hermes Agent ───────────────────────────────────────────────────────────
step "4 — Hermes Agent"

HERMES_BIN="$(sudo -u "$CURRENT_USER" which hermes 2>/dev/null || echo '')"

if [[ -n "$HERMES_BIN" ]]; then
    info "Hermes already installed — updating"
    sudo -u "$CURRENT_USER" hermes update --yes 2>/dev/null || true
else
    log "Installing Hermes (--skip-browser)"
    # Ensure git + curl + xz available (already installed above)
    sudo -u "$CURRENT_USER" bash -c \
        'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --skip-browser'

    # Resolve binary path
    for candidate in \
        "${USER_HOME}/.local/bin/hermes" \
        "${USER_HOME}/.hermes/hermes-agent/venv/bin/hermes"; do
        if [[ -f "$candidate" ]]; then
            HERMES_BIN="$candidate"
            break
        fi
    done

    [[ -n "$HERMES_BIN" ]] && sudo ln -sf "$HERMES_BIN" /usr/local/bin/hermes
fi
log "Hermes: $(hermes --version 2>/dev/null | head -1 || echo 'installed')"

# ── 5. hermes.env ─────────────────────────────────────────────────────────────
step "5 — hermes.env"

sudo -u "$CURRENT_USER" mkdir -p "${USER_HOME}/.hermes"

if [[ -f "$HERMES_ENV" ]]; then
    warn "hermes.env already exists — leaving unchanged"
    warn "Delete it and re-run to regenerate: rm ${HERMES_ENV}"
else
    log "Writing hermes.env → $LLAMA_URL"
    sudo -u "$CURRENT_USER" tee "$HERMES_ENV" > /dev/null <<HENV
# hermes.env — ${VM_HOSTNAME}
# Generated by hermesvm-setup.sh — edit to add your API keys

# ── Primary inference: wimpy llama-swap ───────────────────────────────────────
OPENAI_BASE_URL=${LLAMA_URL}
OPENAI_API_KEY=placeholder

# ── Cloud fallbacks (uncomment and fill in) ───────────────────────────────────
# GEMINI_API_KEY=
# GROQ_API_KEY=
# OPENROUTER_API_KEY=

# ── Hermes core ───────────────────────────────────────────────────────────────
HERMES_CONTEXT_LENGTH=65536

# API server — other tools can talk to Hermes via this endpoint
API_SERVER_ENABLED=true
API_SERVER_HOST=0.0.0.0
API_SERVER_PORT=8642

# Dashboard
DASHBOARD_PORT=9119

# ── Telegram gateway (optional) ───────────────────────────────────────────────
# TELEGRAM_BOT_TOKEN=
# TELEGRAM_CHAT_ID=
HENV
    log "hermes.env written — add your fallback API keys when ready"
fi

# ── 6. systemd service ────────────────────────────────────────────────────────
step "6 — Hermes systemd service"

HERMES_LAUNCH="$(sudo -u "$CURRENT_USER" which hermes 2>/dev/null || echo /usr/local/bin/hermes)"

sudo tee /etc/systemd/system/hermes.service > /dev/null <<SVC
[Unit]
Description=Hermes Agent (${VM_HOSTNAME})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${CURRENT_USER}
WorkingDirectory=${USER_HOME}
EnvironmentFile=${HERMES_ENV}
ExecStart=${HERMES_LAUNCH} gateway
Restart=on-failure
RestartSec=10
TimeoutStartSec=60
TimeoutStopSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVC

sudo systemctl daemon-reload
sudo systemctl enable hermes
log "hermes.service installed and enabled"
info "Not started yet — add API keys to hermes.env first, then:"
info "  sudo systemctl start hermes"
info "  hermes doctor"

# ── 7. Verify connectivity to wimpy ──────────────────────────────────────────
step "7 — Connectivity check → $WIMPY_HOST"

if curl -fsSL --max-time 5 "http://${WIMPY_HOST}:${LLAMA_PORT}/v1/models" \
        -o /dev/null 2>/dev/null; then
    log "llama-swap at $LLAMA_URL is reachable ✔"
else
    warn "Cannot reach $LLAMA_URL right now"
    warn "This is expected if llama-swap isn't started yet on wimpy."
    warn "After adding models and starting llama-swap on wimpy, verify with:"
    warn "  curl http://${WIMPY_HOST}:${LLAMA_PORT}/v1/models"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "hermesvm-setup.sh complete"
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  ${VM_HOSTNAME} is configured                                   "
echo "  │                                                                  │"
echo "  │  Hermes inference endpoint:                                      │"
printf "  │    %s\n" "$LLAMA_URL"
echo "  │                                                                  │"
echo "  │  Next steps:                                                     │"
echo "  │  1. Edit ~/.hermes/hermes.env — add API keys if needed          │"
echo "  │  2. sudo systemctl start hermes                                  │"
echo "  │  3. hermes doctor                                                │"
echo "  │  4. hermes setup  — choose your model, configure providers      │"
echo "  │  5. claude auth   — authenticate Claude Code (new shell first)  │"
echo "  │                                                                  │"
echo "  │  For the next VM: boot it, then run:                            │"
echo "  │    bash hermesvm-setup.sh --hostname <new-vm-name>              │"
echo "  └──────────────────────────────────────────────────────────────────┘"
echo ""
warn "Open a new shell (or source ~/.bashrc) before running claude or hermes"
