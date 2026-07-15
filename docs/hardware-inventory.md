# Homelab Hardware Inventory

Cluster **kaermorhen** — repurposed laptops running Proxmox VE.
FQDN pattern: `<node>.kaermorhen.internal` (renamed from `….home.arpa`
2026-07-12 — Apple resolvers refuse `home.arpa`, see [dns.md](dns.md) gotchas)

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
| Boot storage | 256 GB NVMe SSD | 256 GB SATA SSD |
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
- **Firmware**: E16P5IMS.110 (2019-05-20), UEFI boot; EC firmware 16P5EMS1.109 (read
  from EC RAM offset 0xA0). Secure Boot disabled 2026-07-12 — it forced kernel lockdown
  `integrity`, which blocks raw EC access (`ec_sys write_support=1`); Proxmox doesn't
  need it. BIOS "Wake up On LAN S5" enabled the same day, but WoL does not work on this
  node — see notes below.
- **Battery**: MSI BIF0_9, Li-ion, 64% of design capacity remaining (3150/4902 mAh),
  0 charge cycles reported, currently reports "Full" — verified 2026-07-08. No charge
  cap possible on this hardware — see battery note below

**CPU**
- Intel(R) Core(TM) i7-8750H @ 2.20GHz — 6 cores / 12 threads, max 4.1 GHz, 9 MiB L3

**Memory**
- 16 GB SODIMM DDR4 @ 2667 MT/s

**GPU**
- NVIDIA GeForce GTX 1060 Mobile (GP106M rev a1, 6 GB GDDR5) — VFIO-passed to
  VM 150 (`ciri`) since 2026-07-16 for transcoding/AI workloads; host-side it is
  bound to `vfio-pci` and invisible to tools. See [gpu-passthrough.md](gpu-passthrough.md)
- Intel UHD Graphics 630 (integrated, CoffeeLake-H GT2)

**Storage**

| Device | Type | Size | Model | Role |
|---|---|---|---|---|
| nvme1n1 | NVMe SSD | 256 GB (238.5 GiB) | WDC PC SN520 SDAPNUW-256G | Proxmox boot drive (`pve` VG: root/swap/data-thin) |
| nvme0n1 | NVMe SSD | 500 GB (465.8 GiB) | KINGSTON SNVSE500G | ZFS pool `silver` — guest (VM/LXC) disks |
| sda | HDD, SATA | 1 TB (931.5 GiB) | Seagate ST1000LM049-2GH172 | ZFS pool `steel` — media/photos/dumps (see [storage.md](storage.md)) |

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
  0 charge cycles reported, currently reports "Full" — verified 2026-07-08. No charge
  cap possible on this hardware — see battery note below. Battery is externally
  removable (bottom latch) if it ever degrades badly

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
| sdb | SSD, SATA | 256 GB (238.5 GiB) | NFORCE 256M2 G2-PN43SY | Proxmox boot drive (`pve` VG: root/swap/data-thin); all yennefer guest disks on `local-lvm` |
| sda | HDD, SATA | 1 TB (931.5 GiB) | WDC WD10JPVX-60JC3T1 | ext4 `backup` at `/mnt/backup` — vzdump + future PBS datastore (see [storage.md](storage.md)) |
| sr0 | DVD-RW (SATA) | 1 GB (media dependent) | HP DVDRW GUE1N | Unused optical drive |

Note: the boot SSD on this node is SATA (`/dev/sdb`, `ID_BUS=ata`, no NVMe controller
present on the PCI bus) — the M.2 slot on this chassis is SATA-only, unlike geralt's
true NVMe drives.

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
- **Management IP**: `<SWITCH_IP>`
- **Port assignments**:

| Port | Connection |
|---|---|
| 1 | Uplink — input from router |
| 2–6 | Unused |
| 7 | geralt |
| 8 | yennefer |

## Proxmox-specific notes

- Both nodes run Proxmox VE 9.2.4 on Debian 13 (trixie), kernel 7.0.14-4-pve, and boot
  UEFI.
- Neither node has out-of-band management (no IPMI/BMC/iDRAC) — being consumer laptops,
  remote power-cycling depends on OS-level tools (WoL if enabled) or physical access.
  Keep this in mind for outage runbooks.
- WoL tested 2026-07-12: **geralt cannot be woken remotely.** With BIOS "Wake up On LAN
  S5" enabled and ERP disabled, a magic packet from yennefer did not wake it from a
  clean shutdown. Root cause: the Killer E2400's `alx` driver has no WoL support in
  mainline kernels (removed years ago over spurious-wake bugs), so the OS never arms
  the PHY, and the firmware doesn't arm it on its own. geralt is physical-access-only
  for power-on. **yennefer tested 2026-07-13: also cannot be woken.** Opposite failure
  layer to geralt: the `r8169` driver armed fine (`ethtool -s nic0 wol g`, confirmed
  `Wake-on: g`) and the PHY stayed powered through S5 (switch link LED lit), but two
  bursts of magic packets (UDP 7+9, subnet + limited broadcast) did not wake it — the
  consumer HP firmware simply has no S5 wake path, and F10 setup offers no WoL toggle.
  One untried long-shot: enabling the BIOS "Network Boot" (PXE) option sometimes
  powers the wake path on consumer firmware — deliberately skipped, WoL judged not
  worth another test cycle for this lab. **Accepted: both nodes are
  physical-access-only for power-on**; remote resilience comes from the service
  layer instead (Pi-hole pair, Tailscale subnet-router pair — failover of both
  proven in the same 2026-07-13 outage drill, see [dns.md](dns.md) /
  [tailscale.md](tailscale.md)).
- Both nodes use LVM-thin (`pve` VG) for the boot/root pool. Data disks were rebuilt
  2026-07-09: geralt runs single-disk ZFS pools `silver` (500 GB NVMe, guests) and
  `steel` (1 TB HDD, bulk); yennefer's 1 TB HDD is ext4 at `/mnt/backup` (backup
  target). Full layout and build runbook: [storage.md](storage.md).
- geralt's GTX 1060 is passed through to VM 150 (`ciri`) as of 2026-07-16
  (Jellyfin transcoding, Immich ML, local AI inference) — runbook and gotchas
  in [gpu-passthrough.md](gpu-passthrough.md).
- Laptop chassis implies real constraints vs. rack hardware: no redundant PSU, limited
  cooling under sustained load. Both batteries report "Full" and act as an incidental
  UPS, though geralt's is down to 64% of design capacity (yennefer 86%) — worth
  monitoring for further degradation but not an immediate concern (0 charge cycles
  logged on both, consistent with sitting on AC power as servers).
- Battery charge cap (80%) investigated 2026-07-12: **not achievable in software on
  either node**; accepted the batteries sitting at 100% as the cost of the incidental
  UPS. Details, so this isn't re-litigated:
  - geralt: neither battery exposes `charge_control_end_threshold` in sysfs. The
    in-kernel `msi-ec` driver doesn't list EC firmware `16P5EMS1`; the upstream
    [msi-ec](https://github.com/BeardOverflow/msi-ec) project knows the MS-16P5 EC
    family (`16P5EMS1.103`, GE63 Raider 8RE) and marks `charge_control_address` as
    unsupported. Both known MSI threshold registers (`0xEF`, `0xD7`) read 0x00 in an
    EC dump. Untried fallback: booting Windows once and setting Dragon Center
    "Battery Master" (stores its setting in the EC; may not survive full power drain).
  - yennefer: consumer HP firmware has no charge-limit mechanism — `hp-bioscfg`
    exposes only `Sure_Start`, no Battery Health Manager (business lines only), and
    `hp_wmi` has no threshold support. Physical fallback: the battery is removable.
- Lid-switch suspend risk: verified both nodes already set
  `HandleLidSwitch=ignore`, `HandleLidSwitchExternalPower=ignore`, and
  `HandleLidSwitchDocked=ignore` in `/etc/systemd/logind.conf` — closing the lid will
  not suspend either host.
- Wi-Fi radios: on both nodes the driver is loaded and `rfkill` reports neither a soft
  nor hard block (`iwlwifi`/`iwlmvm` on geralt, `rtw88_8723de` on yennefer) — the
  adapters are not disabled at firmware/rfkill level, they're simply administratively
  down and unconfigured in Proxmox (no bridge/interface config), i.e. wired-only by
  choice, not by restriction.
