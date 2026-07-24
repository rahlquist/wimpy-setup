# DNS and DHCP setup — OPNsense (Unbound + dnsmasq)

Network: 192.168.8.0/24  
Domain:  home.lan

| Host        | IP              |
|-------------|-----------------|
| wimpy       | 192.168.8.248   |
| hermesvm01  | 192.168.8.249   |

---

## 1. DHCP reservations (dnsmasq)

OPNsense → Services → DHCPv4 → [your LAN interface] → Static Mappings → Add

**wimpy**
- MAC address: printed at the end of step 08 on wimpy  
  (or: `ip link show lan0 | grep 'link/ether'` — lan0 is the permanent NIC name, see 10-lan.link)
- IP address: 192.168.8.248
- Hostname: wimpy

**hermesvm01**
- MAC address: visible in virt-manager (VM → NIC details)  
  (or inside the VM: `ip link show | grep -A1 'state UP'`)
- IP address: 192.168.8.249
- Hostname: hermesvm01

Save and apply. Both machines will receive their reserved IP on next DHCP request
(or immediately after: `sudo dhclient br0` on wimpy, `sudo dhclient` in the VM).

---

## 2. Forward DNS records (Unbound host overrides)

OPNsense → Services → Unbound DNS → Host Overrides → Add

**wimpy**
- Host: `wimpy`
- Domain: `home.lan`
- Type: A
- IP: `192.168.8.248`

**hermesvm01**
- Host: `hermesvm01`
- Domain: `home.lan`
- Type: A
- IP: `192.168.8.249`

Save and apply.

---

## 3. PTR records (reverse DNS)

Unbound in OPNsense does not have a GUI field for PTR records.
Use one of the two options below.

### Option A — Automatic via DHCP registration (recommended)

OPNsense → Services → Unbound DNS → General Settings

Enable both:
- ☑ Register DHCP leases
- ☑ Register DHCP static mappings

Save and apply. Unbound will automatically create PTR records for every
static DHCP mapping that has a hostname set. No manual PTR entry needed.

Verify it worked after saving:
```
dig @192.168.8.1 -x 192.168.8.248   # should return wimpy.home.lan
dig @192.168.8.1 -x 192.168.8.249   # should return hermesvm01.home.lan
```

### Option B — Manual PTR entries via custom config

If Option A is not available or not working, add the records manually.

OPNsense → Services → Unbound DNS → Custom Options

Paste:
```
local-data-ptr: "192.168.8.248 wimpy.home.lan"
local-data-ptr: "192.168.8.249 hermesvm01.home.lan"
```

Save and apply.

---

## 4. Verify everything

From any machine on the LAN:
```bash
dig wimpy.home.lan            # → 192.168.8.248
dig hermesvm01.home.lan       # → 192.168.8.249
dig -x 192.168.8.248          # → wimpy.home.lan
dig -x 192.168.8.249          # → hermesvm01.home.lan
ping wimpy.home.lan
ping hermesvm01.home.lan
```

From inside hermesvm01:
```bash
ping wimpy.home.lan                              # host reachable
curl http://wimpy.home.lan:8080/v1/models        # llama-swap reachable
```

---

## 5. Adding future VMs

Each new VM follows the same pattern:
1. Note the VM's virtual NIC MAC from virt-manager
2. Add a DHCP static mapping (next available IP, e.g. 192.168.8.250)
3. Add a Host Override in Unbound (forward A record)
4. If using Option B above, add a PTR line to Custom Options
5. Run `bash hermesvm-setup.sh --hostname <new-vm-name>` inside the VM
