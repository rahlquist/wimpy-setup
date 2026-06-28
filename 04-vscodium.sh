#!/usr/bin/env bash
# 04-vscodium.sh — install VSCodium (open-source VS Code without telemetry)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "04 — VSCodium"
require_root_or_sudo

if command -v codium &>/dev/null; then
    info "VSCodium already installed: $(codium --version | head -1)"
    info "Skipping — delete /usr/bin/codium to force reinstall"
else
    case "$PKG_MANAGER" in

      pacman)
        log "Installing vscodium-bin from AUR"
        ensure_aur_helper
        # Run AUR builds as the real user, not root
        BUILD_USER="${SUDO_USER:-$USER}"
        sudo -u "$BUILD_USER" "$AUR_HELPER" -S --needed --noconfirm vscodium-bin
        ;;

      apt)
        log "Adding VSCodium apt repository"
        wget -qO - https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg \
            | gpg --dearmor \
            | sudo dd of=/usr/share/keyrings/vscodium-archive-keyring.gpg

        echo 'deb [signed-by=/usr/share/keyrings/vscodium-archive-keyring.gpg] \
            https://download.vscodium.com/debs vscodium main' \
            | sudo tee /etc/apt/sources.list.d/vscodium.list > /dev/null

        sudo apt-get update -qq
        sudo apt-get install -y codium
        ;;

      dnf)
        log "Adding VSCodium rpm repository"
        sudo rpm --import https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg
        printf "[vscodium]\nname=VSCodium\nbaseurl=https://download.vscodium.com/rpms/\nenabled=1\ngpgcheck=1\nrepo_gpgcheck=1\ngpgkey=https://gitlab.com/paulcarroty/vscodium-deb-rpm-repo/raw/master/pub.gpg\nmetadata_expire=1h" \
            | sudo tee /etc/yum.repos.d/vscodium.repo > /dev/null
        sudo dnf install -y codium
        ;;

      *)
        warn "Unknown package manager — download VSCodium manually from:"
        warn "  https://github.com/VSCodium/vscodium/releases"
        exit 1
        ;;
    esac
fi

# ── Useful default extensions (install as current user) ──────────────────────
EXT_USER="${SUDO_USER:-$USER}"
install_ext() {
    local ext="$1"
    sudo -u "$EXT_USER" codium --install-extension "$ext" \
        --force 2>/dev/null && log "  ✔ $ext" || warn "  ✘ $ext (may need GUI)"
}

step "Installing VSCodium extensions"
info "Attempting headless extension install (may need X display for some)"

# Check for display
if [[ -z "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
    warn "No display detected — run extension installs manually or connect via SSH -X"
    warn "Commands to run in a desktop session:"
    for ext in \
        "ms-python.python" \
        "charliermarsh.ruff" \
        "ms-toolsai.jupyter" \
        "mtxr.sqltools" \
        "mtxr.sqltools-driver-pg" \
        "esbenp.prettier-vscode" \
        "eamodio.gitlens" \
        "redhat.vscode-yaml" \
        "tamasfe.even-better-toml" \
        "ms-vscode.live-server"; do
        echo "  codium --install-extension $ext"
    done
else
    for ext in \
        "ms-python.python" \
        "charliermarsh.ruff" \
        "mtxr.sqltools" \
        "mtxr.sqltools-driver-pg" \
        "esbenp.prettier-vscode" \
        "eamodio.gitlens" \
        "redhat.vscode-yaml" \
        "tamasfe.even-better-toml"; do
        install_ext "$ext"
    done
fi

log "04-vscodium complete"
info "Launch with: codium"
info "Next: run 05-llama-cpp.sh"
