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
| Memory | 32 GB (2× 16 GB SODIMM DDR4 2667 MT/s) | 8 GB SODIMM DDR4 2133 MT/s |
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
- **32 GB total** — both SODIMM slots populated, dual-channel, dual-rank,
  running at the full rated 2667 MT/s with no BIOS downclock (upgraded
  2026-07-31, verified via `dmidecode -t memory`):

| Slot | Vendor | Part number | Size | Rank | Configured |
|---|---|---|---|---|---|
| ChannelA-DIMM0 (BANK 0) | Samsung | `M471A2K43CB1-CTD` | 16 GB | 2 | 2667 MT/s |
| ChannelB-DIMM0 (BANK 2) | Micron | `16ATF2G64HZ-2G6E1` | 16 GB | 2 | 2667 MT/s |

  Mixed vendors but identical spec — both dual-rank DDR4-2667, so the pair runs
  symmetric in dual channel. Note the delivered part is **not** what was ordered
  (proposal 002 §5 specifies SK Hynix `HMA82GS6CJR8N-VK`); the seller shipped the
  equivalent Micron module. Functionally interchangeable here.

  This node has **no ECC and no EDAC memory controller** (`EDAC MC: Ver: 3.0.0`
  loads but registers no MC), so there are no correctable-error counters: memory
  faults surface only as MCE/oops/crashes, which makes memtest86+ the only real
  verification tool here.

- **Memory verified 2026-07-31 — memtest86+ 7.20, 2 full passes, 0 errors**
  across all 32 GB. `memtest86+` is already installed on geralt and GRUB carries
  the entries, so re-running it needs no setup:

  1. Reboot, hold `Esc`/`Shift` for the GRUB menu (if you land at a bare `grub>`
     prompt, type `normal` to get back to the menu).
  2. Choose **`Memory test (memtest86+x64.efi)`** — not `ia32` (32-bit, won't
     cover 32 GB), not the `serial console` variants (no serial rig on this node).
  3. Confirm the CPU mode is parallel/all-cores, then let it loop for **≥2 full
     passes** — roughly 1–1.5 h per pass on 32 GB of DDR4-2667.

  Requires Secure Boot to stay disabled (it is, since 2026-07-12) or the EFI
  binary won't load. memtest has no network: results are read off the laptop
  panel, and geralt is physical-access-only for power-on (no WoL). Plan it as a
  maintenance window — `uptime-kuma` lives on geralt, so monitoring goes blind
  for the duration, while DNS and Tailscale fail over to yennefer's `pihole-2` /
  `tailscale-1`.

- **Do not re-diagnose the 2026-07-31 boot hangs as a RAM fault.** Installing
  the second stick coincided with a burst of ~90 s host hangs, which looked
  like a bad DIMM but was not. Root cause was the Optimus dGPU D3cold /
  ACPI `PGON` bug — full writeup in
  [gpu-passthrough.md](gpu-passthrough.md) gotchas. Evidence that exonerated the
  RAM: the identical crash signature had already appeared on **2026-07-28
  22:13 and 22:20**, three days before the stick arrived; across 12 retained
  boots there were zero oops / BUG / bad-page / machine-check events and an
  empty `pstore`; kernel taint stayed `4097` (ZFS out-of-tree + proprietary
  only, MCE and oops bits clear); and both DIMMs train at full speed. The
  chassis-opening simply forced enough power cycles to expose an intermittent
  race that had been latent since at least 07-28.

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
| sdb/sdc¹ | HDD, USB 3.0 | 1 TB (931.5 GiB) | Seagate Backup Plus Slim (SRD00F1) | ext4 `media` at `/mnt/media` — Jellyfin library, virtiofs-shared to ciri. **See the dedicated section below — this disk is the lab's main source of unplanned outages.** |

¹ The device node is **not stable**: the USB bridge re-enumerates on every drop, so
the disk has appeared as both `sdb` and `sdc`. Always address it by
`/dev/disk/by-id/usb-Seagate_BUP_Slim_BK_<MEDIA_USB_SERIAL>-0:0` or `LABEL=media`,
never by `/dev/sdX`.

**External media disk (USB) — full catalogue**

Identified 2026-08-03 while root-causing the second media outage. The two
label numbers (`SRD00F1`, `1K9AP1-502`) identify the **external assembly only** —
neither names the bare drive inside, which matters because the bare drive's
recording technology is the root cause of the outages.

| Field | Value | Source |
|---|---|---|
| Product | Seagate Backup Plus Slim 1 TB, Black | retail label |
| Seagate model | `SRD00F1` | retail label (family-wide designator, 500 GB–5 TB) |
| Part number | `1K9AP1-502` | retail label (1 TB Black Slim SKU) |
| Purchased | March 2018 (Amazon) | order history |
| Chassis | 7 mm "Slim" | device string `BUP Slim BK` |
| USB VID:PID | `0bc2:ab24` | `lsusb` |
| Bridge firmware | rev `0304` | `smartctl -i -d scsi` |
| Serial | `<MEDIA_USB_SERIAL>` | `udevadm info` |
| Capacity | 1,000,204,885,504 B (931.5 GiB) | `smartctl -i -d scsi` |
| Sectors | 512 logical / 4096 physical | kernel log |
| Link | SuperSpeed 5 Gbps, xHCI bus 2 port 3 | `lsusb -t` |
| Driver | `uas`, `queue_depth 30`, `max_sectors_kb 512` | sysfs |
| Filesystem | ext4, `LABEL=media`, `errors=remount-ro` | `dumpe2fs -h` |
| Lifetime writes | 282 GB (as of 2026-08-03) | `dumpe2fs -h` |

**Internal bare drive — CONFIRMED 2026-08-04** by clearing the ATA pass-through
block (see the UAS quirk below) and reading the drive directly. The earlier
inference — `ST1000LM035` or `ST1000LM048`, DM-SMR either way — was correct:

| Field | Value |
|---|---|
| Device model | **`ST1000LM035-1RK172`** |
| Model family | Seagate Mobile HDD ("Rosewood") |
| Recording | **DM-SMR (shingled)** — Rosewood is exclusively SMR |
| Drive serial | `<MEDIA_HDD_SERIAL>` (distinct from the enclosure serial) |
| Firmware | `SBM3` |
| WWN | `5 000c50 0b0497b19` |
| Rotation / form factor | 5400 RPM, 2.5", 7 mm |
| SATA | 3.1, 6.0 Gb/s capable (bridge negotiates 3.0 Gb/s) |

**SMART health, first ever reading (2026-08-04) — the media is clean:**

| Attribute | Raw | Reading |
|---|---|---|
| Overall self-assessment | — | **PASSED** |
| `Reallocated_Sector_Ct` | **0** | no bad sectors |
| `Current_Pending_Sector` | **0** | none awaiting reallocation |
| `Offline_Uncorrectable` | **0** | — |
| `Reported_Uncorrect` | **0** | — |
| `UDMA_CRC_Error_Count` | **0** | SATA link integrity perfect |
| SMART error log | — | **No Errors Logged** |
| `Power_On_Hours` | 1687 | ~70 days powered in 8.4 years — barely used |
| `Power_Cycle_Count` | 311 | — |
| `Load_Cycle_Count` | 15064 | fine against a ~600k rating |
| `Temperature_Celsius` | 39 | min/max 26/45 — fine |
| `Head_Flying_Hours` | 317 | mostly idle/parked |
| **`Command_Timeout`** | **65557** | **value 100, worst 98 — the one degraded counter** |

**Read this table the right way.** Every *media* health counter is pristine zero,
while `Command_Timeout` is nonzero and is the only attribute whose `WORST` has
dropped below 100. That is the diagnosis in one line: **nothing is wrong with the
platters; commands are failing to complete in time.** It corroborates the SMR-stall
→ UAS-timeout → bus-drop chain in [storage.md](storage.md) from the drive's own
telemetry.

**Do not be alarmed by `Raw_Read_Error_Rate` (233696008) or `Seek_Error_Rate`
(12426425).** On Seagate drives these raw fields are packed counters
(errors / total operations), not error tallies. Both normalised values sit well
above their thresholds (084 vs 006, 071 vs 045). They are normal and are recorded
here so they are not "discovered" and re-investigated later.

**Consequence: the drive does not need replacing on health grounds.** It is young
(1687 h), unworn, and defect-free. The problem is architectural — SMR write stalls
meeting a strict UAS command timeout — which is why disabling UAS (below) is the
targeted fix rather than new hardware.

**Known limitations (do not re-diagnose these):**

- **RESOLVED 2026-08-04 — SMART now works.** `usb-storage.quirks=0bc2:ab24:u`
  makes `uas` decline the device (it binds `usb-storage`/BOT instead) **and**
  clears the vendor-wide `US_FL_NO_ATA_1X`, so `smartctl -d sat` works and
  `smartd` can finally monitor this disk. Verified: `lsusb -t` shows
  `Driver=usb-storage`, `/sys/module/usb_storage/parameters/quirks` =
  `0bc2:ab24:u`. The historical limitation is kept below for context.
- **SMART was blocked by the kernel, not by the enclosure.** Linux commit
  [`7fee72d`](https://github.com/torvalds/linux/commit/7fee72d5e8f1e7b8d8212e28291b1a0243ecf2f1)
  applies `US_FL_NO_ATA_1X` to **every** Seagate device by vendor ID
  (`idVendor == 0x0bc2`), because most Seagate bridges hang on ATA12. So
  `smartctl -d sat` fails with `unsupported field in scsi command`, and only
  generic `-d scsi` works (`SMART Health Status: OK`, but
  `Error Counter logging not supported` and no self-test support). This is
  overridable — see the runbook in [storage.md](storage.md).
- **Consequence**: `smartd` (`DEVICESCAN`, both nodes) silently monitors nothing
  on this disk. There are **no reallocated/pending-sector counters** for it, so
  its media health is genuinely unobserved.
- **No per-device UAS quirk**: `0bc2:ab24` is absent from the kernel's
  `unusual_uas.h` (only `0bc2:331a` "Expansion Desk" is listed), so `uas` always
  binds and nothing is auto-mitigated.
- **SMR write behaviour is the root cause** of the 2026-07-26 and 2026-08-03
  outages: the small CMR persistent cache exhausts under sustained write, forcing
  read-modify-write on shingled tracks; commands stall for seconds; the UAS
  command timeout fires (`uas_zap_pending … inflight: CMD`) and the bridge drops
  off the bus (`cmd cmplt err -108`). Full analysis in
  [storage.md](storage.md#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr).

**Network**
- Ethernet: Qualcomm Atheros Killer E2400 Gigabit Ethernet Controller (rev 10) — bridged
  as `vmbr0`, IP `<GERALT_IP>/24`.
  **Known defective under sustained inbound load (RCA 2026-08-24):** drops ~5% of
  received packets to RX FIFO overflow, which is invisible on the LAN (26–65 MB/s)
  but collapses WAN throughput ~500× at 172 ms RTT (126 kB/s from a mirror yennefer
  pulls at 6.7 MB/s). `alx` exposes no ring or coalescing controls, so it is not
  tunable. Two adjacent defects were fixed and were *not* the cause: ASPM L0s (a
  3.9-million-error PCIe storm, now 0/hr) and 802.3x flow control. Full analysis and
  mitigations: [geralt-nic-throughput.md](geralt-nic-throughput.md).
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
