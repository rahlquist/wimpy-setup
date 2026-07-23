#!/usr/bin/env bash
# fix-br0.sh — surgical fix for wimpy's br0 after the motherboard swap.
#
# Does NOT tear down your network. It only:
#   1. removes the standalone connection that is holding the IP on enp10s0
#      (that IP belongs on br0, per the 08-networking.sh design)
#   2. re-points br0's slave to the live NIC (enp10s0); br0 itself is kept
#   3. pins br0's MAC to enp10s0 so the OPNsense reservation -> 192.168.8.248 matches
#   4. brings br0 up so wimpy AND hermesvm01 reach the LAN through it
#
# Idempotent and safe to re-run. Run it in a real terminal (needs sudo password).
set -euo pipefail

NIC="enp10s0"
BRIDGE="br0"

[[ -e "/sys/class/net/${NIC}" ]] || { echo "NIC ${NIC} missing — check 'ip -br link'"; exit 1; }
MAC="$(cat /sys/class/net/${NIC}/address)"
echo "NIC ${NIC} MAC = ${MAC}"
echo "This will move the LAN IP off ${NIC} and onto ${BRIDGE}. ${BRIDGE} is kept."
read -rp "Proceed? [y/N] " a; [[ "${a,,}" == y ]] || { echo "Aborted."; exit 0; }

# 1. remove any standalone connection bound to the NIC (it bypasses the bridge)
while IFS=: read -r name dev; do
    if [[ "$dev" == "$NIC" ]]; then
        sudo nmcli con delete "$name" && echo "removed standalone conn: $name"
    fi
done < <(nmcli -t -f NAME,DEVICE con show)

# 2. re-point br0's slave to the live NIC (recreate the slave only; br0 stays)
sudo nmcli con delete "${BRIDGE}-slave" 2>/dev/null || true
sudo nmcli con add type ethernet con-name "${BRIDGE}-slave" ifname "$NIC" \
    master "$BRIDGE" connection.autoconnect yes
echo "enslaved ${NIC} into existing ${BRIDGE}"

# 3. keep br0, just pin its MAC + ensure DHCP
sudo nmcli con mod "$BRIDGE" bridge.mac-address "$MAC" ipv4.method auto

# 4. bring it up
sudo nmcli con up "${BRIDGE}-slave" || true
sudo nmcli con up "$BRIDGE" || true

sleep 4
echo; echo "=== result ==="
ip -br addr show "$BRIDGE"
bridge link | grep "$NIC" || echo "WARN: ${NIC} not showing as a ${BRIDGE} member yet"
ip route show default

BR_IP="$(ip -4 -br addr show "$BRIDGE" | awk '{print $3}')"
if [[ "$BR_IP" == 192.168.8.248/* ]]; then
    echo "OK: ${BRIDGE} has 192.168.8.248 — host side good"
else
    echo "NOTE: ${BRIDGE} IP is '${BR_IP}', expected 192.168.8.248."
    echo "If empty/wrong, static fallback:"
    echo "  sudo nmcli con mod ${BRIDGE} ipv4.method manual ipv4.addresses 192.168.8.248/24 ipv4.gateway 192.168.8.1 ipv4.dns 192.168.8.1 && sudo nmcli con up ${BRIDGE}"
fi

echo; echo "=== VM side ==="
sudo virsh net-start host-bridge 2>/dev/null || true
sudo virsh domiflist hermesvm01 2>/dev/null || true
echo "If hermesvm01 was up during the outage: sudo virsh reboot hermesvm01"
