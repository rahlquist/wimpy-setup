#!/usr/bin/env bash
# lib/common.sh — shared functions for wimpy-setup scripts
# Source this file: source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "$LOG_DIR"

log()  { echo -e "${GREEN}[$(date +%H:%M:%S)] ✔${NC} $*"; }
warn() { echo -e "${YELLOW}[$(date +%H:%M:%S)] ⚠${NC} $*"; }
err()  { echo -e "${RED}[$(date +%H:%M:%S)] ✖${NC} $*" >&2; }
info() { echo -e "${BLUE}[$(date +%H:%M:%S)] ℹ${NC} $*"; }
step() { echo -e "\n${BOLD}${CYAN}══════════════════════════════════════${NC}"; \
         echo -e "${BOLD}${CYAN}  $*${NC}"; \
         echo -e "${BOLD}${CYAN}══════════════════════════════════════${NC}"; }

# ── OS detection ────────────────────────────────────────────────────────────
detect_os() {
    if [[ ! -f /etc/os-release ]]; then err "Cannot detect OS — no /etc/os-release"; exit 1; fi
    # shellcheck disable=SC1091
    source /etc/os-release
    export OS_ID="${ID}"
    export OS_ID_LIKE="${ID_LIKE:-}"
    export OS_PRETTY="${PRETTY_NAME}"
    export OS_VERSION="${VERSION_ID:-rolling}"

    if [[ "$OS_ID" == "arch" || "$OS_ID_LIKE" == *"arch"* ]]; then
        export PKG_MANAGER="pacman"
    elif [[ "$OS_ID" == "cachyos" ]]; then
        export PKG_MANAGER="pacman"
        export OS_ID="arch"     # treat CachyOS as Arch for package purposes
    elif [[ "$OS_ID" == "ubuntu" || "$OS_ID" == "debian" || "$OS_ID_LIKE" == *"debian"* ]]; then
        export PKG_MANAGER="apt"
    elif [[ "$OS_ID" == "fedora" || "$OS_ID_LIKE" == *"rhel"* ]]; then
        export PKG_MANAGER="dnf"
    else
        warn "Unknown OS: $OS_ID — package install commands may need adjustment"
        export PKG_MANAGER="unknown"
    fi
}

# ── Package management ───────────────────────────────────────────────────────
pkg_install() {
    case "${PKG_MANAGER:-}" in
        pacman) sudo pacman -S --needed --noconfirm "$@" ;;
        apt)    sudo apt-get install -y "$@" ;;
        dnf)    sudo dnf install -y "$@" ;;
        *) err "Unknown package manager '$PKG_MANAGER'"; exit 1 ;;
    esac
}

pkg_update() {
    case "${PKG_MANAGER:-}" in
        pacman) sudo pacman -Syu --noconfirm ;;
        apt)    sudo apt-get update -qq && sudo apt-get upgrade -y ;;
        dnf)    sudo dnf update -y ;;
    esac
}

# Detect or install an AUR helper (Arch only)
ensure_aur_helper() {
    if command -v paru &>/dev/null;  then AUR_HELPER="paru";  return; fi
    if command -v yay  &>/dev/null;  then AUR_HELPER="yay";   return; fi
    info "No AUR helper found — installing paru..."
    sudo pacman -S --needed --noconfirm base-devel git
    local tmp; tmp=$(mktemp -d)
    git clone https://aur.archlinux.org/paru-bin.git "$tmp/paru-bin"
    (cd "$tmp/paru-bin" && makepkg -si --noconfirm)
    rm -rf "$tmp"
    AUR_HELPER="paru"
}

# ── Shell detection ──────────────────────────────────────────────────────────
detect_shell() {
    DETECTED_SHELL="$(basename "$SHELL")"
    case "$DETECTED_SHELL" in
        bash) RC_FILE="$HOME/.bashrc" ;;
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
        *)    RC_FILE="$HOME/.profile" ;;
    esac
    export DETECTED_SHELL RC_FILE
}

# Add a line to shell RC if not already present
add_to_rc() {
    local line="$1"
    detect_shell
    if ! grep -qF "$line" "$RC_FILE" 2>/dev/null; then
        echo "$line" >> "$RC_FILE"
        info "Added to $RC_FILE: $line"
    fi
}

# ── Misc helpers ─────────────────────────────────────────────────────────────
require_root_or_sudo() {
    if ! sudo -v &>/dev/null; then err "This script needs sudo access."; exit 1; fi
}

confirm() {
    local prompt="${1:-Continue?}"
    echo -en "${YELLOW}${prompt} [y/N] ${NC}"
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

check_command() {
    command -v "$1" &>/dev/null
}

# ── Firewall helper ──────────────────────────────────────────────────────────
# Open a TCP port inbound from any source. Handles firewalld or nftables, and
# creates a minimal nftables table/chain if none exists (CachyOS default has
# no host firewall active). Non-fatal: always returns 0.
# Usage: open_firewall_port 8080 [bridge_iface]
open_firewall_port() {
    local port="$1"
    local bridge="${2:-}"

    # Path 1: firewalld running
    if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
        [[ -n "$bridge" ]] && sudo firewall-cmd --permanent --zone=trusted --add-interface="$bridge" 2>/dev/null || true
        sudo firewall-cmd --permanent --add-port="${port}/tcp" 2>/dev/null || true
        sudo firewall-cmd --reload 2>/dev/null || true
        log "firewalld: ${port}/tcp open"
        return 0
    fi

    # Path 2: UFW (CachyOS ships it). MUST come before the raw-nftables path:
    # UFW uses iptables-nft, and adding our own nftables table / enabling
    # nftables.service alongside it causes the rule-fighting incidents in
    # CHANGELOG.md. ufw allow is idempotent.
    if command -v ufw &>/dev/null && sudo ufw status 2>/dev/null | grep -q "^Status: active"; then
        [[ -n "$bridge" ]] && sudo ufw allow in on "$bridge" 2>/dev/null || true
        sudo ufw allow "${port}/tcp" 2>/dev/null || true
        log "ufw: ${port}/tcp allowed"
        return 0
    fi

    # Path 3: nftables — create table/chain if absent, then add rule
    if command -v nft &>/dev/null; then
        if ! sudo nft list table inet filter &>/dev/null; then
            sudo nft add table inet filter 2>/dev/null || true
        fi
        if ! sudo nft list chain inet filter input &>/dev/null; then
            sudo nft 'add chain inet filter input { type filter hook input priority 0 ; policy accept ; }' 2>/dev/null || true
        fi
        sudo nft add rule inet filter input tcp dport "$port" accept 2>/dev/null || true
        sudo nft list ruleset 2>/dev/null | sudo tee /etc/nftables.conf > /dev/null 2>&1 || true
        sudo systemctl enable nftables 2>/dev/null || true
        log "nftables: ${port}/tcp accept rule added"
        return 0
    fi

    warn "No firewall active — ${port} is already reachable (nothing to do)"
    return 0
}
