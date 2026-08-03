#!/usr/bin/env bash
# ssh-trust-pair.sh — establish passwordless SSH trust between two hosts
#
# Recreates the hermesvm01 ↔ yogaman trust on fresh machines:
#   - ensures each host has the hermes automation account + hardened sshd
#     dropin (delegates to ssh-hermes-user.sh, run with sudo when needed)
#   - generates an ed25519 keypair for BOTH the admin user and the hermes
#     user if either is missing
#   - installs THIS host's pubkeys into the PEER's authorized_keys
#     (admin → admin, hermes → hermes)
#
# RUN ON BOTH HOSTS. Each run pushes one direction. After both hosts have
# run it, both directions are passwordless:
#     hermesvm01 → hermes@yogaman      rahlquist@yogaman → rahlquist@hermesvm01
#     hermes@yogaman... and the reverse legs, admin and hermes each way.
#
# The first push to a fresh peer needs the peer's password (ssh prompts).
# After the first run, subsequent runs are fully key-based.
#
# Usage:
#   bash ssh-trust-pair.sh --peer HOST [options]
#
# Options:
#   --peer HOST       peer hostname/IP (required)
#   --local-user U    admin user on THIS host (default: $USER)
#   --peer-user U     admin user on the peer (default: same as --local-user)
#   --user NAME       automation account to trust (default: hermes)
#   --key-only        skip the ssh-hermes-user.sh provisioning, only exchange keys
#   --dry-run         print what would be done without executing
#   -h|--help         show this help

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
PEER=""
LOCAL_USER="${SUDO_USER:-$USER}"
PEER_USER=""
SSH_USER="hermes"
KEY_ONLY=0
DRY_RUN=0

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() { grep '^#' "$0" | sed -n '2,24p' | sed 's/^# \?//'; exit 0; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --peer)        PEER="$2"; shift 2 ;;
        --local-user)  LOCAL_USER="$2"; shift 2 ;;
        --peer-user)   PEER_USER="$2"; shift 2 ;;
        --user)        SSH_USER="$2"; shift 2 ;;
        --key-only)    KEY_ONLY=1; shift ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

[[ -n "$PEER" ]] || { err "--peer HOST is required"; exit 1; }
PEER_USER="${PEER_USER:-$LOCAL_USER}"

LOCAL_HOME="$(getent passwd "$LOCAL_USER" | cut -d: -f6)"
[[ -n "$LOCAL_HOME" ]] || { err "Cannot resolve home for user '$LOCAL_USER'"; exit 1; }
PEER_HOME="/home/$PEER_USER"      # getent on the peer; fallback below if needed

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# ── Helpers ───────────────────────────────────────────────────────────────────
# Read a pubkey file, elevating if the caller can't (hermes' .ssh is 700).
read_pub() {
    local f="$1"
    if [[ -r "$f" ]]; then cat "$f"; else sudo cat "$f"; fi
}

# Install a local pubkey file into a peer account's authorized_keys, idempotently.
# Usage: install_key <local_pub_file> <peer_user> <peer_home>
install_key() {
    local pubfile="$1" puser="$2" phome="$3"
    local pub
    pub="$(read_pub "$pubfile")"

    info "Installing $(basename "$pubfile") → ${puser}@${PEER}:${phome}/.ssh/authorized_keys"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [DRY] ssh ${puser}@${PEER} — append $(basename "$pubfile")"
        return 0
    fi

    ssh "${SSH_OPTS[@]}" "${puser}@${PEER}" bash -s -- "$phome" "$pub" <<'REMOTE'
set -euo pipefail
phome="$1"; pub="$2"
mkdir -p "$phome/.ssh"
chmod 700 "$phome/.ssh"
touch "$phome/.ssh/authorized_keys"
chmod 600 "$phome/.ssh/authorized_keys"
if grep -qF -- "$pub" "$phome/.ssh/authorized_keys"; then
    echo "KEY_ALREADY_PRESENT"
else
    echo "$pub" >> "$phome/.ssh/authorized_keys"
    echo "KEY_INSTALLED"
fi
REMOTE
}

# Generate an ed25519 keypair for a user if missing. Runs as that user when
# the caller is someone else (admin → hermes), so ownership stays correct.
# Usage: ensure_key <user> <home>
ensure_key() {
    local user="$1" home="$2"
    local keydir="$home/.ssh"
    local priv="$keydir/id_ed25519"

    if [[ -f "$priv" ]]; then
        info "Key exists: ${user}@$(hostname) ($priv)"
        return 0
    fi

    log "Generating ed25519 keypair for $user"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [DRY] ssh-keygen -t ed25519 -N '' -C '${user}@$(hostname)' -f $priv"
        return 0
    fi

    if [[ "$user" == "$(id -un)" ]]; then
        mkdir -p "$keydir" && chmod 700 "$keydir"
        ssh-keygen -t ed25519 -N "" -C "${user}@$(hostname)" -f "$priv" >/dev/null
        chmod 600 "$priv" && chmod 644 "${priv}.pub"
    else
        sudo -u "$user" bash -c "
            mkdir -p '$keydir' && chmod 700 '$keydir' &&
            ssh-keygen -t ed25519 -N '' -C '${user}@$(hostname)' -f '$priv' >/dev/null &&
            chmod 600 '$priv' && chmod 644 '${priv}.pub'
        "
    fi
    log "Key created: $priv"
}

verify_leg() {
    local from="$1" to="$2"
    local target
    target="${to}@${PEER}"
    info "  ${from}@$(hostname) → ${to}@${PEER}:"

    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "    [DRY] ssh -o BatchMode=yes ${target} true"
        return 0
    fi

    local -a cmd=(ssh -o BatchMode=yes -o ConnectTimeout=10 "${target}" true)
    if [[ "$from" != "$(id -un)" ]]; then
        # the hermes leg must present HERMES' key — run the test as that user
        cmd=(sudo -u "$from" ssh -o BatchMode=yes -o ConnectTimeout=10 "${target}" true)
    fi

    if "${cmd[@]}" 2>/dev/null; then
        log "    ✔ passwordless OK"
        return 0
    fi
    err "    ✖ FAILED — ${target} rejected the key"
    return 1
}

# ── 1. Provision (unless --key-only) ─────────────────────────────────────────
provision() {
    step "1 — Provision hermes account + sshd dropin (this host)"

    if [[ "$KEY_ONLY" -eq 1 ]]; then
        info "Skipped (--key-only)"
        return 0
    fi

    local self
    self="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ssh-hermes-user.sh"
    if [[ ! -f "$self" ]]; then
        self="/tmp/ssh-hermes-user.sh"
        if [[ ! -f "$self" ]]; then
            err "ssh-hermes-user.sh not found next to this script or at $self"
            err "Fetch it from the wimpy-setup repo, or run with --key-only."
            exit 1
        fi
    fi

    info "Running: sudo bash $self --user $SSH_USER --allow $LOCAL_USER"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        info "  [DRY] sudo bash $self --user $SSH_USER --allow $LOCAL_USER"
        return 0
    fi
    sudo bash "$self" --user "$SSH_USER" --allow "$LOCAL_USER"
}

# ── 2. Keys on this host ─────────────────────────────────────────────────────
ensure_local_keys() {
    step "2 — Keys on this host"

    ensure_key "$LOCAL_USER" "$LOCAL_HOME"
    if id "$SSH_USER" >/dev/null 2>&1; then
        local hermes_home
        hermes_home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
        ensure_key "$SSH_USER" "$hermes_home"
    else
        warn "Account '$SSH_USER' missing locally — run ssh-hermes-user.sh first (or --key-only with provisioning already done)"
    fi
}

# ── 3. Push keys to peer ─────────────────────────────────────────────────────
push_keys() {
    step "3 — Push keys → ${PEER}"

    install_key "$LOCAL_HOME/.ssh/id_ed25519.pub" "$PEER_USER" "$PEER_HOME"

    if id "$SSH_USER" >/dev/null 2>&1; then
        local hermes_home
        hermes_home="$(getent passwd "$SSH_USER" | cut -d: -f6)"
        if [[ -f "$hermes_home/.ssh/id_ed25519.pub" ]]; then
            install_key "$hermes_home/.ssh/id_ed25519.pub" "$SSH_USER" "/home/$SSH_USER"
        else
            warn "No pubkey yet at $hermes_home/.ssh/id_ed25519.pub (dry-run or key not generated) — skipping hermes→peer-hermes leg"
        fi
    else
        warn "Skipping hermes→peer-hermes leg (no local $SSH_USER account)"
    fi
}

# ── 4. Verify this direction ─────────────────────────────────────────────────
verify() {
    step "4 — Verify passwordless (this host → peer)"

    local ok=0
    verify_leg "$LOCAL_USER" "$PEER_USER" || ok=1
    if id "$SSH_USER" >/dev/null 2>&1; then
        verify_leg "$SSH_USER" "$SSH_USER" || ok=1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        return 0
    fi
    if [[ "$ok" -eq 0 ]]; then
        log "This direction is passwordless ✔"
    else
        warn "Some legs failed — check the errors above."
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo ""
echo "  This host : $(hostname)  (admin: $LOCAL_USER, automation: $SSH_USER)"
echo "  Peer      : $PEER  (admin: $PEER_USER)"
echo "  Dry run   : $([[ "$DRY_RUN" -eq 1 ]] && echo yes || echo no)"
echo ""

provision
ensure_local_keys
push_keys
verify

echo ""
if [[ "$DRY_RUN" -eq 0 ]]; then
    log "ssh-trust-pair.sh complete for this direction"
    echo ""
    echo "  ╔══════════════════════════════════════════════════════════════╗"
    echo "  ║  REMEMBER: run this SAME script on the PEER host too.        ║"
    echo "  ║                                                              ║"
    echo "  ║    bash ssh-trust-pair.sh --peer $(hostname)                 ║"
    echo "  ║                                                              ║"
    echo "  ║  That completes the reverse direction.                       ║"
    echo "  ╚══════════════════════════════════════════════════════════════╝"
fi
echo ""
