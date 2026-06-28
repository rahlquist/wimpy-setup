#!/usr/bin/env bash
# 02-docker.sh — install Docker CE + Compose plugin, add user to docker group
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "02 — Docker CE + Compose"
require_root_or_sudo

if command -v docker &>/dev/null; then
    DOCKER_VER="$(docker --version)"
    warn "Docker already installed: $DOCKER_VER"
    warn "Skipping Docker engine install."
    # Docker present but compose plugin may be missing — ensure it
    if ! docker compose version &>/dev/null; then
        log "Compose plugin missing — installing"
        case "$PKG_MANAGER" in
            pacman) sudo pacman -S --needed --noconfirm docker-compose docker-buildx ;;
            apt)    sudo apt-get install -y docker-compose-plugin docker-buildx-plugin ;;
            dnf)    sudo dnf install -y docker-compose-plugin docker-buildx-plugin ;;
        esac
    fi
else
    case "$PKG_MANAGER" in

      pacman)
        log "Installing Docker via pacman"
        sudo pacman -S --needed --noconfirm docker docker-compose docker-buildx
        ;;

      apt)
        log "Installing Docker via official apt repo"
        # Remove old packages
        for pkg in docker docker-engine docker.io containerd runc; do
            sudo apt-get remove -y "$pkg" 2>/dev/null || true
        done

        sudo apt-get update -qq
        sudo apt-get install -y ca-certificates curl gnupg lsb-release

        # Add Docker GPG key
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg

        # Add repo
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
          https://download.docker.com/linux/ubuntu \
          $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
          | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

        sudo apt-get update -qq
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        ;;

      dnf)
        log "Installing Docker via dnf"
        sudo dnf remove -y docker docker-client docker-client-latest \
            docker-common docker-latest docker-latest-logrotate \
            docker-logrotate docker-engine 2>/dev/null || true
        sudo dnf -y install dnf-plugins-core
        sudo dnf config-manager --add-repo \
            https://download.docker.com/linux/fedora/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
        ;;

      *)
        err "Unknown package manager — install Docker manually"
        exit 1
        ;;
    esac
fi

# ── Enable and start ──────────────────────────────────────────────────────────
log "Enabling Docker service"
sudo systemctl enable --now docker

# ── Add current user to docker group ─────────────────────────────────────────
CURRENT_USER="${SUDO_USER:-$USER}"
if ! groups "$CURRENT_USER" | grep -q docker; then
    log "Adding $CURRENT_USER to docker group"
    sudo usermod -aG docker "$CURRENT_USER"
    warn "Group change requires a new shell session to take effect."
    warn "After this script completes: 'newgrp docker' or log out/in."
else
    info "$CURRENT_USER already in docker group"
fi

# ── Verify ────────────────────────────────────────────────────────────────────
log "Docker version:"
docker --version || true
log "Compose version:"
if docker compose version 2>/dev/null; then
    :
else
    warn "docker compose not available — check 'sudo pacman -S docker-compose'"
fi

log "Running hello-world test (as root since group not active yet)"
sudo docker run --rm hello-world 2>&1 | grep -E 'Hello|error' || true

# ── docker-compose compat shim ────────────────────────────────────────────────
# Some older scripts use `docker-compose` (v1 syntax)
if ! command -v docker-compose &>/dev/null; then
    log "Creating docker-compose v1-compat shim"
    sudo tee /usr/local/bin/docker-compose > /dev/null <<'SHIM'
#!/usr/bin/env bash
# Shim: redirect docker-compose v1 calls to docker compose v2
exec docker compose "$@"
SHIM
    sudo chmod +x /usr/local/bin/docker-compose
fi

log "02-docker complete"
info "Next: run 04-vscodium.sh"
