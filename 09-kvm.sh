#!/usr/bin/env bash
# 09-kvm.sh — install KVM/QEMU + libvirt + virt-manager on wimpy
#
# After this runs:
#   - KVM/QEMU is the hypervisor
#   - libvirtd manages VM lifecycle (start on boot, etc.)
#   - virt-manager is the GUI frontend
#   - br0 is registered as a libvirt bridge network so VMs get real LAN IPs
#   - Current user is added to the libvirt and kvm groups
#
# Assumes 08-networking.sh has already created br0.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "09 — KVM / QEMU / libvirt / virt-manager"
require_root_or_sudo

# ── Check KVM support ─────────────────────────────────────────────────────────
log "Checking CPU virtualisation support"
if ! grep -qE 'vmx|svm' /proc/cpuinfo; then
    err "CPU does not report VMX or SVM — check BIOS and enable AMD-V / Intel VT-x"
    exit 1
fi
log "  ✔ SVM (AMD-V) detected"

if [[ ! -e /dev/kvm ]]; then
    warn "/dev/kvm not present — loading kvm_amd module"
    sudo modprobe kvm_amd
    echo 'kvm_amd' | sudo tee /etc/modules-load.d/kvm.conf > /dev/null
fi
log "  ✔ /dev/kvm present"

# ── Install packages ──────────────────────────────────────────────────────────
step "Installing KVM stack"
case "$PKG_MANAGER" in

  pacman)
    PKGS=(
        qemu-full          # QEMU with all targets + tools
        libvirt            # VM management daemon
        virt-manager       # GUI
        virt-viewer        # SPICE/VNC console viewer
        dnsmasq            # libvirt's internal DHCP (needed even when using bridged)
        bridge-utils       # brctl — useful for diagnostics
        iptables-nft       # libvirt network filtering
        dmidecode          # SMBIOS info for VMs
        swtpm              # TPM emulator (for Windows 11 VMs etc.)
        ovmf               # UEFI firmware for VMs
        edk2-ovmf          # alt UEFI package name on some Arch builds
    )
    # edk2-ovmf and ovmf are mutually exclusive on some repos, try both
    for pkg in "${PKGS[@]}"; do
        sudo pacman -S --needed --noconfirm "$pkg" 2>/dev/null || \
            warn "  skipped (not found): $pkg"
    done
    ;;

  apt)
    sudo apt-get update -qq
    PKGS=(
        qemu-kvm
        qemu-utils
        libvirt-daemon-system
        libvirt-clients
        virt-manager
        virt-viewer
        bridge-utils
        dnsmasq-base
        iptables
        swtpm
        ovmf
    )
    sudo apt-get install -y "${PKGS[@]}"
    ;;

  dnf)
    sudo dnf install -y @virtualization
    sudo dnf install -y virt-manager virt-viewer swtpm edk2-ovmf
    ;;

  *)
    err "Unknown package manager — install KVM stack manually"
    exit 1
    ;;
esac

# ── Enable and start libvirtd ─────────────────────────────────────────────────
step "Starting libvirtd"
sudo systemctl enable --now libvirtd
sudo systemctl enable --now virtlogd

log "libvirtd status: $(systemctl is-active libvirtd)"

# ── Add user to groups ────────────────────────────────────────────────────────
INSTALL_USER="${SUDO_USER:-$USER}"
log "Adding $INSTALL_USER to libvirt and kvm groups"
sudo usermod -aG libvirt "$INSTALL_USER"
sudo usermod -aG kvm     "$INSTALL_USER"
warn "Group membership takes effect on next login (or: newgrp libvirt)"

# ── Register br0 as a libvirt bridge network ──────────────────────────────────
step "Registering br0 as libvirt 'host-bridge' network"

# Check br0 exists first
if ! ip link show br0 &>/dev/null; then
    warn "br0 not found — run 08-networking.sh first, then re-run this step:"
    warn "  bash run-all.sh --only 09"
else
    BRIDGE_XML="/tmp/wimpy-host-bridge.xml"
    cat > "$BRIDGE_XML" <<'BXML'
<network>
  <name>host-bridge</name>
  <forward mode="bridge"/>
  <bridge name="br0"/>
</network>
BXML

    # Remove existing definition if present
    sudo virsh net-destroy  host-bridge 2>/dev/null || true
    sudo virsh net-undefine host-bridge 2>/dev/null || true

    sudo virsh net-define  "$BRIDGE_XML"
    sudo virsh net-start   host-bridge
    sudo virsh net-autostart host-bridge
    rm -f "$BRIDGE_XML"

    log "libvirt network 'host-bridge' defined, started, and set to autostart"
    info "When creating a VM: Network → host-bridge → VM gets a real LAN IP"
fi

# ── UEFI / OVMF firmware path ─────────────────────────────────────────────────
step "Verifying OVMF UEFI firmware"
OVMF_PATHS=(
    /usr/share/edk2/x64/OVMF_CODE.fd
    /usr/share/edk2-ovmf/x64/OVMF_CODE.fd
    /usr/share/OVMF/OVMF_CODE.fd
    /usr/share/qemu/OVMF.fd
)
OVMF_FOUND=""
for p in "${OVMF_PATHS[@]}"; do
    if [[ -f "$p" ]]; then OVMF_FOUND="$p"; break; fi
done
if [[ -n "$OVMF_FOUND" ]]; then
    log "  ✔ OVMF found: $OVMF_FOUND"
else
    warn "  OVMF not found at expected paths — UEFI VMs may need manual firmware path"
fi

# ── Default storage pool ──────────────────────────────────────────────────────
step "Configuring default storage pool"
VM_IMAGE_DIR="/var/lib/libvirt/images"
sudo mkdir -p "$VM_IMAGE_DIR"

if ! sudo virsh pool-info default &>/dev/null; then
    sudo virsh pool-define-as default dir --target "$VM_IMAGE_DIR"
    sudo virsh pool-build   default
    sudo virsh pool-start   default
    sudo virsh pool-autostart default
    log "Default storage pool created at $VM_IMAGE_DIR"
else
    log "Default storage pool already exists"
    sudo virsh pool-autostart default 2>/dev/null || true
fi

# ── Useful aliases ────────────────────────────────────────────────────────────
detect_shell
add_to_rc "# KVM aliases"
add_to_rc "alias vms='sudo virsh list --all'"
add_to_rc "alias vmstart='sudo virsh start'"
add_to_rc "alias vmstop='sudo virsh shutdown'"
add_to_rc "alias vmkill='sudo virsh destroy'"

# ── Summary ───────────────────────────────────────────────────────────────────
log "09-kvm complete"
echo ""
echo "  ┌──────────────────────────────────────────────────────────────────┐"
echo "  │  KVM stack installed                                            │"
echo "  │                                                                  │"
echo "  │  Quick reference:                                                │"
echo "  │    virt-manager                   # GUI (needs display)         │"
echo "  │    sudo virsh list --all          # list VMs                    │"
echo "  │    sudo virsh start   <vm>        # start VM                    │"
echo "  │    sudo virsh shutdown <vm>       # graceful stop               │"
echo "  │    sudo virsh console  <vm>       # serial console              │"
echo "  │    sudo virsh domifaddr <vm>      # VM's IP address             │"
echo "  │                                                                  │"
echo "  │  Creating a VM with a real LAN IP:                              │"
echo "  │    virt-install ...               # see 10-create-vm-example.sh │"
echo "  │    Network → host-bridge → VM appears on your LAN              │"
echo "  │                                                                  │"
echo "  │  Storage pool : /var/lib/libvirt/images                         │"
echo "  │  Bridge net   : host-bridge (br0)                               │"
echo "  │                                                                  │"
echo "  │  ⚠ Log out and back in for libvirt/kvm group to take effect     │"
echo "  └──────────────────────────────────────────────────────────────────┘"
