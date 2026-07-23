#!/usr/bin/env bash
# 08-networking.sh — configure wimpy as a VM host with bridged networking
#
# Creates br0 bridged to enp10s0 in DHCP mode.
# Your dnsmasq DHCP reservation (MAC → 192.168.8.248) assigns the IP.
# VMs plug into br0 and get their own DHCP-reserved IPs.
#
# Also opens port 8080 (llama-swap) in firewalld so VMs can reach it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/common.sh"
detect_os

step "08 — Host bridge networking (br0 on enp10s0, DHCP)"
require_root_or_sudo

HOST_NIC="enp10s0"
BRIDGE="br0"

# Prefer NetworkManager if it's running (CachyOS/KDE default).
# Both can be active at once; NetworkManager wins for bridge management.
if systemctl is-active --quiet NetworkManager; then
    NET_MANAGER="NetworkManager"
elif systemctl is-active --quiet systemd-networkd; then
    NET_MANAGER="systemd-networkd"
else
    NET_MANAGER="unknown"
fi

info "Network manager : $NET_MANAGER"
info "Physical NIC    : $HOST_NIC"
info "Bridge          : $BRIDGE  (IP assigned by DHCP reservation)"
echo ""

# ── Build the bridge ──────────────────────────────────────────────────────────
case "$NET_MANAGER" in

  NetworkManager)
    log "Creating bridge $BRIDGE via nmcli (DHCP mode)"

    # Capture the physical NIC's real MAC BEFORE we touch anything.
    # We pin this MAC onto the bridge so DHCP reservations (keyed on this MAC)
    # match — otherwise the bridge invents a random MAC and gets a pool address.
    NIC_MAC="$(cat /sys/class/net/${HOST_NIC}/address 2>/dev/null)"
    if [[ -n "$NIC_MAC" ]]; then
        log "Physical NIC MAC: $NIC_MAC (will pin to bridge)"
    else
        warn "Could not read ${HOST_NIC} MAC — bridge will use a random MAC"
    fi

    # Remove any existing connection on the physical NIC
    EXISTING="$(nmcli -g NAME,DEVICE con show | grep ":${HOST_NIC}$" | cut -d: -f1 | head -1 || true)"
    if [[ -n "$EXISTING" ]]; then
        sudo nmcli con delete "$EXISTING" 2>/dev/null || true
        log "Removed existing connection: $EXISTING"
    fi

    # Remove any stale bridge connections
    sudo nmcli con delete "$BRIDGE"        2>/dev/null || true
    sudo nmcli con delete "${BRIDGE}-slave" 2>/dev/null || true

    # Create the bridge — DHCP, STP off (not needed for a single-uplink VM bridge)
    # Pin the bridge MAC to the physical NIC's MAC so DHCP reservations match.
    BRIDGE_MAC_ARGS=()
    [[ -n "$NIC_MAC" ]] && BRIDGE_MAC_ARGS=(bridge.mac-address "$NIC_MAC")

    sudo nmcli con add type bridge \
        con-name            "$BRIDGE" \
        ifname              "$BRIDGE" \
        ipv4.method         auto \
        bridge.stp          no \
        "${BRIDGE_MAC_ARGS[@]}" \
        connection.autoconnect yes

    # Enslave the physical NIC into the bridge
    sudo nmcli con add type ethernet \
        con-name            "${BRIDGE}-slave" \
        ifname              "$HOST_NIC" \
        master              "$BRIDGE" \
        connection.autoconnect yes

    log "Bringing up bridge (connection will drop for a few seconds)"
    sudo nmcli con up "$BRIDGE"        || true
    sudo nmcli con up "${BRIDGE}-slave" || true
    ;;

  systemd-networkd)
    log "Writing systemd-networkd bridge config (DHCP mode)"

    # Pin the bridge MAC to the physical NIC's MAC so DHCP reservations match
    NIC_MAC="$(cat /sys/class/net/${HOST_NIC}/address 2>/dev/null)"

    sudo tee /etc/systemd/network/10-br0.netdev > /dev/null <<NETDEV
[NetDev]
Name=${BRIDGE}
Kind=bridge
${NIC_MAC:+MACAddress=${NIC_MAC}}

[Bridge]
STP=no
NETDEV

    sudo tee /etc/systemd/network/20-br0.network > /dev/null <<BRNET
[Match]
Name=${BRIDGE}

[Network]
DHCP=yes
BRNET

    sudo tee /etc/systemd/network/20-${HOST_NIC}.network > /dev/null <<NICNET
[Match]
Name=${HOST_NIC}

[Network]
Bridge=${BRIDGE}
NICNET

    sudo systemctl restart systemd-networkd
    ;;

  *)
    err "Could not detect network manager — configure br0 manually"
    exit 1
    ;;
esac

# ── SSH ───────────────────────────────────────────────────────────────────────
step "SSH server"
sudo pacman -S --needed --noconfirm openssh 2>/dev/null || \
    sudo apt-get install -y openssh-server 2>/dev/null || true
sudo systemctl enable --now sshd

# ── Firewall — open port 8080 (llama-swap) inbound from any ──────────────────
# Per design: wimpy host firewall is low-priority (score 3), accept from ANY.
step "Firewall — port 8080 (llama-swap)"
open_firewall_port 8080 "$BRIDGE"

# ── Summary ───────────────────────────────────────────────────────────────────
log "08-networking complete"
echo ""
echo "  br0 is up in DHCP mode — waiting for dnsmasq reservation to assign IP"
echo "  Once the reservation is active: ip addr show br0"
echo ""
echo "  Wimpy MAC address for your dnsmasq reservation:"
ip link show "$HOST_NIC" | grep 'link/ether' | awk '{print "    enp10s0 MAC: " $2}'
echo "  → reserve this MAC → 192.168.8.248 in OPNsense DHCP"
echo ""
echo "  Next: run 09-kvm.sh"
