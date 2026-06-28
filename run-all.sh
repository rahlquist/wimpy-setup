#!/usr/bin/env bash
# run-all.sh — orchestrate the wimpy host setup
#
# Usage:
#   ./run-all.sh              # run all steps
#   ./run-all.sh --from 05   # resume from a step
#   ./run-all.sh --only 07   # run one step
#   ./run-all.sh --list      # show steps

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
source "${SCRIPT_DIR}/lib/common.sh"

declare -A STEPS=(
    [01]="01-system-base.sh|System base packages"
    [02]="02-docker.sh|Docker CE + Compose"
    [04]="04-vscodium.sh|VSCodium"
    [05]="05-llama-cpp.sh|llama.cpp + llama-swap (CUDA sm_120)"
    [07]="07-claude-code.sh|Claude Code"
    [08]="08-networking.sh|Host bridge br0 on enp6s0 (DHCP)"
    [09]="09-kvm.sh|KVM / QEMU / libvirt / virt-manager"
)
STEP_ORDER=(01 02 04 05 07 08 09)

FROM_STEP="01"
ONLY_STEP=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --from)  FROM_STEP="$2"; shift 2 ;;
        --only)  ONLY_STEP="$2"; shift 2 ;;
        --dry)   DRY_RUN=true; shift ;;
        --list)
            echo "Wimpy host setup steps:"
            for n in "${STEP_ORDER[@]}"; do
                script="${STEPS[$n]%%|*}"
                desc="${STEPS[$n]##*|}"
                printf "  %s  %-35s  %s\n" "$n" "$script" "$desc"
            done
            exit 0
            ;;
        -h|--help)
            grep '^#' "$0" | head -8 | sed 's/^# \?//'
            exit 0
            ;;
        *) err "Unknown arg: $1"; exit 1 ;;
    esac
done

run_step() {
    local num="$1"
    local entry="${STEPS[$num]}"
    local script="${entry%%|*}"
    local desc="${entry##*|}"
    local logfile="${SCRIPT_DIR}/logs/${num}-${script%.sh}-$(date +%H%M%S).log"

    [[ ! -f "${SCRIPT_DIR}/${script}" ]] && { err "Not found: ${script}"; exit 1; }
    $DRY_RUN && { info "  [DRY] $script"; return 0; }

    step "${num} — ${desc}"
    info "Log: $logfile"

    if bash "${SCRIPT_DIR}/${script}" 2>&1 | tee "$logfile"; then
        log "Step ${num} complete ✔"
    else
        err "Step ${num} FAILED — see $logfile"
        err "Resume: ./run-all.sh --from ${num}"
        exit 1
    fi
}

mkdir -p "${SCRIPT_DIR}/logs"

if [[ -n "$ONLY_STEP" ]]; then
    ONLY_STEP="$(printf '%02d' "$((10#$ONLY_STEP))")"
    [[ -z "${STEPS[$ONLY_STEP]:-}" ]] && { err "Unknown step: $ONLY_STEP"; exit 1; }
    run_step "$ONLY_STEP"
else
    STARTED=false
    TARGET="$(printf '%02d' "$((10#$FROM_STEP))")"
    for n in "${STEP_ORDER[@]}"; do
        [[ "$n" == "$TARGET" ]] && STARTED=true
        $STARTED && run_step "$n"
    done
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  wimpy host setup complete                                   ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║                                                              ║"
echo "║  Post-setup checklist:                                       ║"
echo "║  1. Check br0 got its IP: ip addr show br0                   ║"
echo "║  2. Add DHCP reservation in OPNsense (MAC printed by step 8) ║"
echo "║  3. Add DNS records in Unbound (see README.md)               ║"
echo "║  4. Add model paths to /etc/llama-swap/config.yaml           ║"
echo "║     then: sudo systemctl enable --now llama-swap             ║"
echo "║  5. newgrp docker && newgrp libvirt  (or re-login)           ║"
echo "║  6. claude auth                                              ║"
echo "║  7. Create hermesvm01 in virt-manager, then run:             ║"
echo "║     bash hermesvm-setup.sh --hostname hermesvm01             ║"
echo "║     (inside the VM, after CachyOS+MATE install)              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
