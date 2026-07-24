#!/usr/bin/env bash
# migrate-to-lan0.sh — one-time migration: give the LAN NIC a permanent name
# (lan0, keyed on MAC via 10-lan.link) and point br0-slave at it, so PCI
# renames (enp10s0 -> enp8s0, etc.) can never break the bridge again.
#
# Prereq: the bridge should already be WORKING on the current kernel name
# (run fix-br0.sh first if br0 is down). This script only:
#   1. installs 10-lan.link into /etc/systemd/network/
#   2. re-points the br0-slave NM profile at lan0
#   3. offers a reboot (the rename applies at boot); until then the bridge
#      keeps running on the old name — nothing is torn down here
#
# Idempotent and safe to re-run. Run from the LOCAL CONSOLE — the reboot (and
# any rename) drops network. Needs sudo password.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK_FILE="${SCRIPT_DIR}/10-lan.link"
BRIDGE="br0"
NEWNAME="lan0"

[[ -f "$LINK_FILE" ]] || { echo "ERROR: ${LINK_FILE} not found"; exit 1; }
MAC="$(awk -F= '/^MACAddress=/{print tolower($2)}' "$LINK_FILE")"
[[ -n "$MAC" ]] || { echo "ERROR: no MACAddress= in ${LINK_FILE}"; exit 1; }

# find the live device that owns that MAC
CUR=""
for d in /sys/class/net/*; do
    [[ "$(cat "$d/address" 2>/dev/null)" == "$MAC" ]] || continue
    dev="$(basename "$d")"
    # the bridge clones the NIC MAC — skip bridges/taps, we want the ether NIC
    [[ -d "$d/device" ]] || continue
    CUR="$dev"; break
done
[[ -n "$CUR" ]] || { echo "ERROR: no physical NIC with MAC ${MAC} — check 'ip -br link' vs 10-lan.link"; exit 1; }
echo "NIC with MAC ${MAC}: ${CUR}"

if [[ "$CUR" == "$NEWNAME" ]] && nmcli -g connection.interface-name con show "${BRIDGE}-slave" 2>/dev/null | grep -qx "$NEWNAME"; then
    echo "Already migrated: ${NEWNAME} exists and ${BRIDGE}-slave points at it."
    ip -br addr show "$BRIDGE"
    exit 0
fi

echo "This will install 10-lan.link and point ${BRIDGE}-slave at ${NEWNAME}."
echo "The rename itself applies at REBOOT; run this from the local console."
read -rp "Proceed? [y/N] " a; [[ "${a,,}" == y ]] || { echo "Aborted."; exit 0; }

# 1. install the .link file
sudo install -m 644 "$LINK_FILE" /etc/systemd/network/10-lan.link
sudo udevadm control --reload
echo "installed /etc/systemd/network/10-lan.link"

# 2. point br0-slave at the permanent name (create it if it's missing)
if nmcli con show "${BRIDGE}-slave" &>/dev/null; then
    sudo nmcli con mod "${BRIDGE}-slave" connection.interface-name "$NEWNAME"
    echo "re-pointed ${BRIDGE}-slave: ${CUR} -> ${NEWNAME}"
else
    sudo nmcli con add type ethernet con-name "${BRIDGE}-slave" ifname "$NEWNAME" \
        master "$BRIDGE" connection.autoconnect yes
    echo "created ${BRIDGE}-slave on ${NEWNAME}"
fi

# leftover standalone profiles on the NIC would race the bridge after reboot
while IFS=: read -r name dev; do
    if [[ "$dev" == "$CUR" && "$name" != "${BRIDGE}-slave" ]]; then
        sudo nmcli con delete "$name" && echo "removed standalone conn: $name"
    fi
done < <(nmcli -t -f NAME,DEVICE con show)

echo
echo "Config done. The bridge keeps running on ${CUR} until reboot."
read -rp "Reboot now to apply the rename? [y/N] " a
if [[ "${a,,}" == y ]]; then
    sudo reboot
else
    echo "Reboot later, then verify:"
fi
cat <<EOF
  after reboot:
    ip -br link show ${NEWNAME}          # NIC has its permanent name
    bridge link                          # ${NEWNAME} is a ${BRIDGE} member
    ip -br addr show ${BRIDGE}           # ${BRIDGE} has 192.168.8.248
    ping -c2 192.168.8.249               # hermesvm01 reachable
  if the name did NOT stick, rebuild the initramfs and reboot once more:
    sudo mkinitcpio -P
  if hermesvm01 is up but unreachable, reattach its tap:
    sudo virsh reboot hermesvm01   (or: sudo ip link set vnet0 master ${BRIDGE})
EOF
