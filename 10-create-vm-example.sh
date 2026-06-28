#!/usr/bin/env bash
# 10-create-vm-example.sh — example: create a new VM on wimpy with a real LAN IP
#
# This is a template. Copy and edit for each VM you create.
# The VM will appear on your LAN via br0 — give it a static IP and DNS record.
#
# Usage: bash 10-create-vm-example.sh
#
# Prereqs:
#   - 08-networking.sh ran (br0 exists)
#   - 09-kvm.sh ran (libvirt installed)
#   - ISO downloaded to /var/lib/libvirt/images/

set -euo pipefail

# ════════════════════════════════════════════════════════════
# EDIT THESE for each VM
VM_NAME="myvm"
VM_VCPUS="4"
VM_RAM_MB="8192"          # 8 GB
VM_DISK_GB="100"
VM_DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
VM_ISO="/var/lib/libvirt/images/ubuntu-24.04-live-server-amd64.iso"
# ════════════════════════════════════════════════════════════

if [[ ! -f "$VM_ISO" ]]; then
    echo "ERROR: ISO not found at $VM_ISO"
    echo "Download with:"
    echo "  wget -P /var/lib/libvirt/images/ https://releases.ubuntu.com/24.04/ubuntu-24.04-live-server-amd64.iso"
    exit 1
fi

echo "Creating VM: $VM_NAME"
echo "  vCPUs : $VM_VCPUS"
echo "  RAM   : ${VM_RAM_MB} MB"
echo "  Disk  : ${VM_DISK_GB} GB → $VM_DISK_PATH"
echo "  ISO   : $VM_ISO"
echo "  Net   : host-bridge (real LAN IP via br0)"
echo ""

sudo virt-install \
    --name         "$VM_NAME" \
    --vcpus        "$VM_VCPUS" \
    --memory       "$VM_RAM_MB" \
    --disk         "path=${VM_DISK_PATH},size=${VM_DISK_GB},format=qcow2,bus=virtio" \
    --cdrom        "$VM_ISO" \
    --network      "network=host-bridge,model=virtio" \
    --os-variant   "ubuntu24.04" \
    --graphics     "spice,listen=127.0.0.1" \
    --video        "qxl" \
    --boot         "cdrom,hd" \
    --noautoconsole

echo ""
echo "VM '$VM_NAME' created and installing."
echo ""
echo "Connect to console:  virt-manager  (or: sudo virsh console $VM_NAME)"
echo ""
echo "Once the VM is up and has a LAN IP, add DNS records:"
echo "  Forward : ${VM_NAME}    IN  A    <vm-ip>"
echo "  Reverse : <last-octet>  IN  PTR  ${VM_NAME}.your.domain.local."
echo ""
echo "Find the VM's DHCP-assigned IP with:"
echo "  sudo virsh domifaddr $VM_NAME"
