# Homelab Hardware Inventory

Cluster **kaermorhen** — repurposed laptops running Proxmox VE.
FQDN pattern: `<node>.kaermorhen.home.arpa`

Real IPs/serials/UUIDs referenced below are placeholders (`<NAME>`) resolved in the
git-ignored `secrets.local.yaml` at the repo root, per `CLAUDE.md`.

Last verified against live hosts: 2026-07-08 (`hostnamectl`, `lscpu`, `lsblk`, `lspci` on
each node over SSH).

## Cluster summary

| | geralt | yennefer |
|---|---|---|
| Model | MSI GP63 Leopard 8RE | HP Laptop 15-bs0xx |
| CPU | Intel Core i7-8750H @ 2.20GHz (6C/12T) | Intel Core i3-6006U @ 2.00GHz (2C/4T) |
| Memory | 16 GB SODIMM DDR4 2667 MT/s | 8 GB SODIMM DDR4 2133 MT/s |
| GPU (dGPU) | NVIDIA GeForce GTX 1060 Mobile (GP106M, 6 GB) | none |
| GPU (iGPU) | Intel UHD Graphics 630 | Intel HD Graphics 520 |
| Boot storage | 256 GB NVMe SSD | 256 GB NVMe SSD |
| Extra storage | 500 GB NVMe SSD + 1 TB HDD | 1 TB HDD |
| Primary NIC | Killer E2400 GbE | Realtek RTL8111/8168/8211/8411 GbE |
| Wireless | Intel CNVi WiFi (Cannon Lake PCH) | Realtek RTL8723DE 802.11b/g/n |
| Boot mode | UEFI | UEFI |
| Proxmox VE | 9.2.4 (kernel 7.0.14-4-pve, Debian 13 trixie) | 9.2.4 (kernel 7.0.14-4-pve, Debian 13 trixie) |
| Management IP | `<GERALT_IP>` (vmbr0) | `<YENNEFER_IP>` (vmbr0) |

## Node: geralt

- **Role**: Proxmox VE node
- **Model**: MSI GP63 Leopard 8RE (15.6" gaming laptop chassis, Coffee Lake generation)
- **Serial / Product UUID**: `<GERALT_SERIAL>` / `<GERALT_UUID>`
- **Firmware**: E16P5IMS.110 (2019-05-20), UEFI boot
- **Battery**: MSI BIF0_9, Li-ion, 64% of design capacity remaining (3150/4902 mAh),
  0 charge cycles reported, currently reports "Full" — verified 2026-07-08

**CPU**
- Intel(R) Core(TM) i7-8750H @ 2.20GHz — 6 cores / 12 threads, max 4.1 GHz, 9 MiB L3

**Memory**
- 16 GB SODIMM DDR4 @ 2667 MT/s

**GPU**
- NVIDIA GeForce GTX 1060 Mobile (GP106M rev a1, 6 GB GDDR5) — not currently passed
  through to any VM/LXC; candidate for PCIe passthrough (transcoding/AI workloads)
- Intel UHD Graphics 630 (integrated, CoffeeLake-H GT2)

**Storage**

| Device | Type | Size | Model | Role |
|---|---|---|---|---|
| nvme1n1 | NVMe SSD | 256 GB (238.5 GiB) | WDC PC SN520 SDAPNUW-256G | Proxmox boot drive (`pve` VG: root/swap/data-thin) |
| nvme0n1 | NVMe SSD | 500 GB (465.8 GiB) | KINGSTON SNVSE500G | Secondary storage (`ssd-vg` thin pool) |
| sda | HDD, SATA | 1 TB (931.5 GiB) | Seagate ST1000LM049-2GH172 | Bulk/backup storage |

**Network**
- Ethernet: Qualcomm Atheros Killer E2400 Gigabit Ethernet Controller (rev 10) — bridged
  as `vmbr0`, IP `<GERALT_IP>/24`
- Wireless: Intel Corporation Cannon Lake PCH CNVi WiFi (rev 10) — present, unused
  (interface down)

## Node: yennefer

- **Role**: Proxmox VE node
- **Model**: HP Laptop 15-bs0xx (15.6" consumer laptop chassis, Skylake generation)
- **Serial / Product UUID**: `<YENNEFER_SERIAL>` / `<YENNEFER_UUID>`
- **Firmware**: F.52 (2019-03-04), UEFI boot
- **Battery**: HP PABAS0241231, Li-ion, 86% of design capacity remaining (2440/2850 mAh),
  0 charge cycles reported, currently reports "Full" — verified 2026-07-08

**CPU**
- Intel(R) Core(TM) i3-6006U @ 2.00GHz — 2 cores / 4 threads, fixed 2.0 GHz (no Turbo), 3 MiB L3

**Memory**
- 8 GB SODIMM DDR4 @ 2133 MT/s

**GPU**
- No dedicated GPU
- Intel HD Graphics 520 (integrated, Skylake GT2)

**Storage**

| Device | Type | Size | Model | Role |
|---|---|---|---|---|
| sdb | NVMe-class SSD, SATA | 256 GB (238.5 GiB) | NFORCE 256M2 G2-PN43SY | Proxmox boot drive (`pve` VG: root/swap/data-thin) |
| sda | HDD, SATA | 1 TB (931.5 GiB) | WDC WD10JPVX-60JC3T1 | Bulk/backup storage |
| sr0 | DVD-RW (SATA) | 1 GB (media dependent) | HP DVDRW GUE1N | Unused optical drive |

Note: the "ssd1" boot drive on this node is a SATA SSD (`/dev/sdb`, `ata` transport),
not NVMe — the M.2 slot on this chassis is SATA-only, unlike geralt's true NVMe drives.

**Network**
- Ethernet: Realtek RTL8111/8168/8211/8411 PCI Express Gigabit Ethernet Controller
  (rev 15) — bridged as `vmbr0`, IP `<YENNEFER_IP>/24`
- Wireless: Realtek RTL8723DE 802.11b/g/n PCIe Adapter — present, unused (interface down)

## Switch

- **Model**: TP-Link TL-SG108E — 8-port Gigabit "Easy Smart" switch
- **Type**: Easy Smart (L2 lite-managed) — web GUI management, not CLI/SSH-managed.
  Supports port-based/802.1Q VLANs (up to 32), port-based & 802.1p/DSCP QoS (4 queues),
  port mirroring, static link aggregation (LAG), IGMP snooping, and broadcast storm
  control. Switching capacity 16 Gbps, 4K MAC address table.
- **Ports**: 8x 10/100/1000 Mbps RJ45
- **Management IP**: `<SWITCH_IP>` (TODO — record once assigned/reserved)
- **Port assignments**: TODO — not yet documented; fill in as ports are wired
  (e.g. Port 1 → geralt, Port 2 → yennefer, uplink port, etc.)

## Proxmox-specific notes

- Both nodes run Proxmox VE 9.2.4 on Debian 13 (trixie), kernel 7.0.14-4-pve, and boot
  UEFI.
- Neither node has out-of-band management (no IPMI/BMC/iDRAC) — being consumer laptops,
  remote power-cycling depends on OS-level tools (WoL if enabled) or physical access.
  Keep this in mind for outage runbooks.
- Both nodes use LVM-thin (`pve` VG) for the boot/root pool; geralt additionally has a
  second LVM-thin pool (`ssd-vg`) on its extra NVMe drive for VM/LXC storage.
- geralt's GTX 1060 is a strong candidate for GPU passthrough (Jellyfin/Plex
  transcoding, local AI inference) — not yet configured as of this writing.
- Laptop chassis implies real constraints vs. rack hardware: no redundant PSU, limited
  cooling under sustained load. Both batteries report "Full" and act as an incidental
  UPS, though geralt's is down to 64% of design capacity (yennefer 86%) — worth
  monitoring for further degradation but not an immediate concern (0 charge cycles
  logged on both, consistent with sitting on AC power as servers).
- Lid-switch suspend risk: verified both nodes already set
  `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, and
  `HandleLidSwitchDocked=ignore` in `/etc/systemd/logind.conf` — closing the lid will
  not suspend either host.
- Wi-Fi radios: on both nodes the driver is loaded and `rfkill` reports neither a soft
  nor hard block (`iwlwifi`/`iwlmvm` on geralt, `rtw88_8723de` on yennefer) — the
  adapters are not disabled at firmware/rfkill level, they're simply administratively
  down and unconfigured in Proxmox (no bridge/interface config), i.e. wired-only by
  choice, not by restriction.

## Open items to fill in

- [ ] Switch management IP and per-port cabling map
