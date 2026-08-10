#!/usr/bin/env bash
# ssh-hermes-user.sh — create the hermes automation SSH account + hardened sshd dropin
#
# Run on ANY fresh Linux host (wimpy, hermesvm01, yogaman, ...) to recreate
# the Hermes automation SSH setup:
#   - Create the dedicated 'hermes' automation user (no sudo by default)
#   - Write /etc/ssh/sshd_config.d/99-hermes-automation.conf (hardened)
#     with a MULTI-USER AllowUsers list — never drops an existing allowed
#     user, so re-runs can't lock anyone out (the bug this fixes)
#   - Validate sshd -t and reload the service
#
# Safe to re-run. Idempotent. Does NOT install keys — that's
# ssh-trust-pair.sh's job.
#
# Usage:
#   sudo bash ssh-hermes-user.sh [options]
#
# Options:
#   --user NAME     automation account to create/use (default: hermes)
#   --allow USER    additional user allowed in AllowUsers (repeatable).
#                   Existing AllowUsers entries are always preserved and
#                   merged, so omitting --allow on a re-run is safe.
#   --grant-sudo    grant passwordless sudo to the automation account
#                   (NOT recommended — the account is for automation, not admin)
#   --no-reload     skip the sshd reload (containers, chroots, CI)
#   --dry-run       print what would be done without executing
#   -h|--help       show this help

set -euo pipefail

# ── Minimal inline helpers (no lib/common.sh dependency — runs on fresh hosts) ──
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

# ── Defaults ──────────────────────────────────────────────────────────────────
SSH_USER="hermes"
ALLOW_USERS=()
GRANT_SUDO=0
DO_RELOAD=1
DRY_RUN=0
SSH_DROPIN="/etc/ssh/sshd_config.d/99-hermes-automation.conf"
BACKUP_DIR="/etc/ssh/hermes-backups"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() { grep '^#' "$0" | sed -n '2,24p' | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          SSH_USER="$2"; shift 2 ;;
        --allow)         ALLOW_USERS+=("$2"); shift 2 ;;
        --grant-sudo)    GRANT_SUDO=1; shift ;;
        --no-reload)     DO_RELOAD=0; shift ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ "$SSH_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { err "Invalid username: $SSH_USER"; exit 1; }

# ── Preflight ─────────────────────────────────────────────────────────────────
require_root() {
    [[ "$DRY_RUN" -eq 1 ]] && return 0   # dry run makes no changes — no root needed
    if [[ "${EUID}" -ne 0 ]]; then
        if sudo -v &>/dev/null; then
            # re-exec under sudo so all writes are root-owned consistently
            if [[ "${SUDO_USER:-unset}" == "unset" ]]; then
                exec sudo -H bash "$0" "$@"
            fi
        else
            err "Run with sudo or as root:  sudo bash $0"
            exit 1
        fi
    fi
}

detect_service() {
    if systemctl list-unit-files --no-legend ssh.service 2>/dev/null | grep -q '^ssh.service'; then
        SSH_SERVICE="ssh"
    else
        SSH_SERVICE="sshd"
    fi
}

# ── 1. User ───────────────────────────────────────────────────────────────────
create_user() {
    step "1 — Automation account: $SSH_USER"

    if id "$SSH_USER" >/dev/null 2>&1; then
        info "Account '$SSH_USER' already exists — leaving UID/home intact"
    else
        log "Creating account '$SSH_USER'"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "  [DRY] useradd --create-home --shell /bin/bash --user-group $SSH_USER"
        else
            useradd --create-home --shell /bin/bash --user-group "$SSH_USER"
        fi
    fi

    if [[ "$DRY_RUN" -eq 0 ]]; then
        usermod --shell /bin/bash "$SSH_USER"   # ensure usable login shell
    fi
    info "Shell: /bin/bash"

    if [[ "$GRANT_SUDO" -eq 1 ]]; then
        local sudoers="/etc/sudoers.d/${SSH_USER}-hermes-automation"
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "  [DRY] write $sudoers  (NOPASSWD: ALL)"
        else
            printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$SSH_USER" > "$sudoers"
            chmod 440 "$sudoers"
            visudo -cf "$sudoers" >/dev/null || { err "sudoers failed validation"; exit 1; }
        fi
        warn "Passwordless sudo granted to '$SSH_USER' — audit this!"
    fi
}

# ── 2. sshd dropin ────────────────────────────────────────────────────────────
# Merge strategy: ALWAYS preserve the users already listed in AllowUsers and
# union them with --allow. This is the exact bug class that locked rahlquist
# out on 2026-08-03 — a script rewriting the dropin with a single user.
build_allowusers() {
    local existing=""
    if [[ -f "$SSH_DROPIN" ]]; then
        existing="$(grep -E '^AllowUsers[[:space:]]' "$SSH_DROPIN" 2>/dev/null \
            | sed 's/^AllowUsers[[:space:]]*//' || true)"
    fi
    local merged="$SSH_USER $existing ${ALLOW_USERS[*]}"
    echo "$merged" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ' | sed 's/ $//'
}

write_dropin() {
    step "2 — sshd dropin: $SSH_DROPIN"

    local allowusers
    allowusers="$(build_allowusers)"
    info "AllowUsers → ${allowusers}"

    if [[ -f "$SSH_DROPIN" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            info "  [DRY] backup existing dropin to $BACKUP_DIR/"
        else
            mkdir -p "$BACKUP_DIR"
            local ts; ts="$(date +%Y%m%d-%H%M%S)"
            cp -a "$SSH_DROPIN" "$BACKUP_DIR/$(basename "$SSH_DROPIN").$ts"
            chmod 600 "$BACKUP_DIR/$(basename "$SSH_DROPIN").$ts"
            info "Backed up to $BACKUP_DIR/$(basename "$SSH_DROPIN").$ts"
        fi
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [DRY] write $SSH_DROPIN:"
        info "        PermitRootLogin no | PasswordAuthentication yes"
        info "        PubkeyAuthentication yes | AllowUsers $allowusers"
        return 0
    fi

    mkdir -p /etc/ssh/sshd_config.d
    cat > "$SSH_DROPIN" <<EOF
# Managed by ssh-hermes-user.sh
# Dedicated Hermes automation account.
# Do not edit /etc/ssh/sshd_config for this configuration.

PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowAgentForwarding no
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 5
LoginGraceTime 30
AllowUsers $allowusers
EOF
    chmod 644 "$SSH_DROPIN"
    log "Dropin written"
}

# ── 3. Validate + reload ──────────────────────────────────────────────────────
apply_sshd() {
    step "3 — Validate and reload sshd"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [DRY] sshd -t"
        info "  [DRY] systemctl reload $SSH_SERVICE"
        return 0
    fi

    sshd -t || { err "sshd -t failed — NOT reloading. Fix the config."; exit 1; }
    log "sshd -t passed"

    if [[ "$DO_RELOAD" -eq 1 ]]; then
        systemctl reload "$SSH_SERVICE" || systemctl restart "$SSH_SERVICE"
        log "$SSH_SERVICE reloaded"
    else
        info "Reload skipped (--no-reload)"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
require_root "$@"
detect_service

echo ""
echo "  Host      : $(hostname)"
echo "  User      : $SSH_USER"
echo "  AllowUsers: $SSH_USER ${ALLOW_USERS[*]}"
echo "  Dry run   : $([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
echo ""

create_user
write_dropin
apply_sshd

echo ""
log "ssh-hermes-user.sh complete"
info "Next: run ssh-trust-pair.sh to exchange keys with the peer host."
echo ""
