#!/usr/bin/env bash
# 01-system-base.sh — update system and install essential base tooling
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "01 — System base packages"
require_root_or_sudo

log "Updating package database and system"
pkg_update

# ── Core packages by distro ───────────────────────────────────────────────────
case "$PKG_MANAGER" in

  pacman)
    PKGS=(
        # Build tools
        base-devel git cmake ninja ccache
        # System utils
        curl wget rsync xz zip unzip p7zip
        # Shell & terminal
        tmux htop btop neovim tree bat fd ripgrep jq yq fzf
        # Network tools
        net-tools iproute2 nmap openssh
        # Dev libs commonly needed
        openssl libffi zlib sqlite
        # Python (system-level; hermes manages its own venv)
        python python-pip uv
        # Node / npm (for claude code)
        nodejs npm
        # Hardware info
        pciutils usbutils lshw dmidecode
    )
    sudo pacman -S --needed --noconfirm "${PKGS[@]}"
    ;;

  apt)
    sudo apt-get update -qq
    PKGS=(
        # Build tools
        build-essential git cmake ninja-build ccache pkg-config
        # System utils
        curl wget rsync xz-utils zip unzip p7zip-full
        # Shell & terminal
        tmux htop btop neovim tree bat fd-find ripgrep jq fzf
        # Network tools
        net-tools iproute2 nmap openssh-client openssh-server
        # Dev libs
        libssl-dev libffi-dev zlib1g-dev libsqlite3-dev
        # Python
        python3 python3-pip python3-venv
        # Node / npm
        nodejs npm
        # Hardware info
        pciutils usbutils lshw dmidecode
        # Misc
        ca-certificates gnupg lsb-release
    )
    sudo apt-get install -y "${PKGS[@]}"
    # uv (not in apt)
    if ! command -v uv &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    ;;

  dnf)
    PKGS=(
        gcc gcc-c++ make git cmake ninja-build ccache pkgconf-pkg-config
        curl wget rsync xz zip unzip
        tmux htop btop neovim tree bat fd-find ripgrep jq fzf
        net-tools iproute nmap openssh-clients openssh-server
        openssl-devel libffi-devel zlib-devel sqlite-devel
        python3 python3-pip
        nodejs npm
        pciutils usbutils lshw dmidecode
        ca-certificates
    )
    sudo dnf install -y "${PKGS[@]}"
    if ! command -v uv &>/dev/null; then
        curl -LsSf https://astral.sh/uv/install.sh | sh
    fi
    ;;

  *)
    warn "Unknown package manager — skipping automatic package install"
    ;;
esac

# ── Verify essentials ─────────────────────────────────────────────────────────
log "Verifying key tools"
for cmd in git cmake curl wget node npm python3 uv; do
    if command -v "$cmd" &>/dev/null; then
        info "  ✔ $cmd $(${cmd} --version 2>&1 | head -1)"
    else
        warn "  ✘ $cmd not found"
    fi
done

log "01-system-base complete"
info "Next: run 02-docker.sh"
