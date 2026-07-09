# Network plan

Address plan and VMID convention for the home network (single flat /24 for now),
adopted 2026-07-10. Covers the whole network, not just Proxmox.

The subnet prefix is a placeholder per `CLAUDE.md`: `<LAN_PREFIX>` (e.g. the
`192.168.x` part), resolved in the git-ignored `secrets.local.yaml`. Addresses
below are written as last octets (`.NN` = `<LAN_PREFIX>.NN`).

## Core rule: VMID = last octet

Every Proxmox guest's VMID equals the last octet of its IP (`.150` ↔ VMID 150).
This works cleanly because Proxmox **does not allow VMIDs below 100**, which
naturally splits the /24: everything below .100 is physical/human space,
everything from .100 up is guest space.

Consequences:

- A guest's IP is derivable from its VMID (and vice versa) — nothing to look up.
- Guests get **static IPs in their own config** (`--net0 ip=...`), never DHCP —
  a guest's identity must not depend on the router being alive.
- The router's DHCP pool must be bounded to `.31–.99` so it can never wander
  into guest space.

## Address map

| Range | Purpose |
|---|---|
| .1 | Router / gateway |
| .2–.19 | Reserved — future network gear (APs, second switch) |
| .20–.30 | Infra tier: switch and Proxmox nodes |
| .31–.99 | DHCP pool — all normal home devices (phones, laptops, TV, printer, IoT until VLANs); router-side reservations for devices needing stable IPs |
| .100–.199 | geralt guests (VMID = octet) |
| .200–.254 | yennefer guests (VMID = octet) |
| .255 | Broadcast — unusable (hence yennefer's band ends at .254) |

The guest-space asymmetry (geralt 100 slots, yennefer 55) matches the hardware
asymmetry — the workhorse gets the bigger namespace.

### Infra tier assignments (.20–.30)

| Octet | Device |
|---|---|
| .20 | TP-Link TL-SG108E switch |
| .21 | geralt (Proxmox node, `vmbr0`) |
| .22 | yennefer (Proxmox node, `vmbr0`) |
| .23–.29 | Future nodes / corosync QDevice |
| .30 | Spare |

## Guest function bands

Loose bands — the goal is telling what something is from its ID, not rigid law.

### geralt (1xx)

| Band | Purpose | Planned/assigned |
|---|---|---|
| 100–109 | Core infra LXCs | 101 Pi-hole #1 · 102 Beszel hub · 103 Uptime-Kuma |
| 110–149 | Service LXCs | — |
| 150 | Docker VM (all compose apps) | 150 docker VM |
| 151–189 | Future VMs (AI/GPU workloads, OPNsense if VLANs) | — |
| 190–199 | Scratch / test guests | 199 restore-test (throwaway) |

### yennefer (2xx)

| Band | Purpose | Planned/assigned |
|---|---|---|
| 200–209 | Infra LXCs | 200 PBS · 201 Pi-hole #2 · 202 reverse proxy · 203 Tailscale/WireGuard |
| 210–219 | VMs | 210 HAOS (Home Assistant OS) |
| 220–249 | Service LXCs / future | — |
| 250–254 | Scratch / test | — |

Keep these tables current — they are the allocation registry. Claim an ID here
when a guest is created.

## Design notes

- **DNS**: Pi-holes at `.101` and `.201` (x01 = "first service on node x") —
  point the router's DHCP DNS at both, one per node so a single node reboot
  never takes the house's DNS down.
- **Cluster status**: nodes run standalone (no corosync cluster) until a third
  vote exists — a 2-node cluster freezes management on the survivor whenever
  either node is down. The VMID bands keep a future cluster merge collision-free.
- **VLANs (future)**: when IoT segmentation happens, each VLAN becomes its own
  /24 with the same internal shape (router .1, infra low, DHCP middle, static
  high); this map remains the management/services network unchanged. `vmbr0` on
  both nodes can be made VLAN-aware ahead of time at zero cost.
- **Switch caveat** (TL-SG108E): its management UI answers on any VLAN — it
  cannot tag its own management traffic — so VLAN isolation is soft where the
  switch itself is concerned.
