# Proposal 001 — Initial software infrastructure plan

- **Status**: Accepted — §1 storage implemented 2026-07-09 (see
  [storage.md](../storage.md)); remaining sections pending
- **Date**: 2026-07-08 (updated 2026-07-09)
- **Scope**: cluster **kaermorhen** (nodes `geralt`, `yennefer`), see
  [hardware inventory](../hardware-inventory.md)

Plan for the first software build-out of the cluster: base infrastructure
(storage, network), monitoring, application hosting, LXC services, and backups.
Recommendations are driven by the hardware asymmetry: geralt (i7-8750H, 6C/12T,
16 GB, GTX 1060) is the workhorse; yennefer (i3-6006U, 2C/4T, 8 GB) is the
light infra node.

## 1. Base infrastructure: disks, network, VLANs

### Disks

Both nodes ship with stock LVM-thin on the boot SSD. The decision to make
before data accumulates is whether the *data* disks move to ZFS:

- **Pro ZFS**: checksumming (aging consumer disks — silent-corruption detection
  matters) and cheap snapshots. Single-disk ZFS is legitimate; mirrors are not
  required to benefit.
- **Con ZFS**: RAM appetite. Fine on geralt; on yennefer (8 GB total) the ARC
  must be capped tightly or ZFS skipped entirely.
- **Lean**: ZFS on geralt's 500 GB NVMe (guest disks) and both 1 TB HDDs
  (bulk/backup); keep the boot drives as installed.

Decision recorded: single-node ZFS pools only — **no cross-node replication**
with just 2 nodes.

### Cluster topology (decide early)

Two Proxmox nodes in a cluster lose quorum when either goes down, freezing
guest management on the survivor. Either:

- run both nodes **standalone** (simplest; unified viewing comes from the
  monitoring layer anyway) — *leaning this way*, or
- cluster them **plus a QDevice** (`corosync-qnetd` on a Pi or any always-on
  third box).

Never a bare 2-node cluster.

### Network / VLANs

The TL-SG108E supports 802.1Q, so a sensible segmentation is: management
(Proxmox UIs, switch), services (VMs/LXCs), trusted clients, and IoT (wanted
once Home Assistant arrives). Caveats:

- Inter-VLAN routing needs a VLAN-aware router. An ISP box can't do it — that
  means an OPNsense VM (doable on geralt) or accepting a flat network for now.
- Known TL-SG108E quirk: its management interface is reachable from any VLAN
  (it doesn't tag its own management traffic), weakening isolation.
- **Pragmatic path**: make `vmbr0` VLAN-aware on both nodes now (zero cost,
  future-proof), but only actually segment once IoT devices arrive.

## 2. Monitoring

Requirements: CPU, GPU, network, and disk metrics (usage, temperature, health)
across both nodes, one dashboard. The field consolidates into two camps:

- **Beszel** — hub + tiny Go agent (~12 MB RAM). Covers CPU, memory, disk
  usage/IO, network, temperatures, GPU, Docker container stats, and SMART out
  of the box; one dashboard for all hosts; built-in alerts. Consensus pick for
  1–20 servers.
- **Prometheus + Grafana** (+ `node_exporter`, `pve-exporter` for per-VM/LXC
  metrics, `smartctl_exporter`, `nvidia_gpu_exporter`) — the most complete
  single-pane UI, long retention, arbitrary dashboards; ~500 MB RAM and real
  setup effort. The TIG/InfluxDB variant with Proxmox's native metric-server
  integration is equivalent effort.
- **Netdata** — deepest auto-discovered metrics but ~300 MB per node and an
  overwhelming UI. Skip — yennefer can't spare the RAM.

**Recommendation**: start with **Beszel** — hub on geralt, agents on both nodes
and inside the docker VM(s). It covers the requirement list for essentially
zero resources. If per-guest Proxmox metrics, months of history, or custom
dashboards become wanted later, add Prometheus + Grafana on geralt then; Beszel
keeps working alongside as the at-a-glance view. Grafana-first only makes sense
as a deliberate learning exercise.

## 3. Application hosting: docker-compose VM per host

Planned apps: finance manager **sure**, diary **memos**, media streaming
(**Jellyfin** or Plex), document storage **paperless-ngx**, and more — all as
docker-compose stacks in an Ubuntu Server VM.

- **geralt: yes.** An Ubuntu Server VM (~8–10 GB RAM, 6–8 vCPU) hosting
  compose stacks is the classic, well-supported pattern: clean
  snapshots/backups of the whole app layer, no Docker-on-LXC
  unsupported-config headaches.
- **yennefer: reconsider.** A VM's RAM is carved out of 8 GB up front on a
  2-core CPU. Either (a) a small 4 GB VM with only 2–3 light apps, or
  (b) **no docker VM at all** — yennefer becomes the infra node (LXCs + backup
  target) and all compose apps live on geralt. *Leaning (b)*: less to
  maintain, and the i3 won't enjoy Paperless OCR jobs anyway.

App notes:

- **Jellyfin over Plex** — free, no account/phone-home, hardware transcoding
  without a Plex Pass.
- Transcoding on geralt, two good paths: pass the **iGPU (UHD 630,
  QuickSync)** to the VM/LXC — simplest, and QSV is excellent for media — or
  pass the **GTX 1060** through to the VM — more setup, but frees it for AI
  workloads too (it can only go to one VM).
- sure, memos, and paperless-ngx are light; all fine in the geralt VM.

## 4. LXC services

- **Pi-hole**: good LXC candidate — but run **two instances, one per node**
  (or Pi-hole + AdGuard Home). A single DNS server means the whole house's
  internet "breaks" whenever its host reboots; this is the #1 homelab regret.
- **Home Assistant**: the one *not* to run as LXC. HA Container lacks the
  add-on store and easy updates; **HAOS in a small VM** (2 GB) is the
  officially supported, dramatically nicer path. Put it on yennefer — light,
  and it spreads risk away from geralt.
- Other strong LXC candidates: **reverse proxy** (Caddy/Traefik/NPM) with
  internal DNS names, **Tailscale/WireGuard** subnet router for remote access,
  **Vaultwarden**, **Uptime-Kuma** (service-level "is it up" checks —
  complements Beszel's host-level view), and **Proxmox Backup Server** (§5).

## 5. Backups

Layered — guest-level and app-level are different problems:

1. **Proxmox Backup Server** on yennefer (LXC or small VM), datastore on
   yennefer's 1 TB HDD. Both nodes back up all guests to it daily —
   deduplicated, incremental, file-level restore. Cross-node is the point:
   geralt's guests survive geralt's disks dying. (geralt's 1 TB HDD can hold a
   second-copy sync or local vzdumps of yennefer's guests for symmetry.)
2. **Offsite/cloud**: sync the PBS datastore (or selected backups) to
   **Backblaze B2 via rclone** on a nightly timer — the price/simplicity sweet
   spot at this scale. Completes 3-2-1.
3. **App data**: nightly **restic or borgmatic** job inside the docker VM
   dumping databases (paperless, sure) and volumes straight to B2. VM images
   alone are a coarse restore unit; per-app `pg_dump`s make single-app
   recovery painless.
4. **Logs/state**: PBS captures guest state; journald plus the app-level
   restic job covers logs. Add Loki later only if log search proves actually
   wanted.

## Suggested end state

> geralt = docker VM (all apps, GPU) + monitoring hub + Pi-hole #1;
> yennefer = PBS + HAOS VM + Pi-hole #2 + reverse proxy/VPN LXCs;
> standalone nodes (or cluster + QDevice); Beszel dashboard; PBS → B2 nightly.

## Follow-ups

- **Storage: done (2026-07-09).** Final layout deviates from the §1 lean in two
  ways, both decided during execution: yennefer's HDD is **ext4, not ZFS** (the
  disk only holds backups — PBS checksums/compresses its own chunks, and the ARC
  would eat RAM the 8 GB node can't spare), and pool naming follows the node
  theme: geralt's two disks are `silver` (NVMe, guests) and `steel` (HDD, bulk).
  Data found on the previous install's disks (old sure/memos app data, scripts)
  was inspected and deliberately discarded before wiping. As-built layout and
  full command runbook: [storage.md](../storage.md).
- A 2 TB USB HDD will later attach permanently to geralt for replaceable bulk
  (Jellyfin media), freeing `steel` to grow as the photo/document disk. It never
  holds originals' backups and photos never live on it.
- Remaining build-out (monitoring, docker VM, LXCs, backups) proceeds per §§2–5.

## Appendix — sources

Monitoring research (2026):

- [The 7 Best Server Monitoring Tools in 2026 (instapods)](https://instapods.com/blog/best-server-monitoring-tools/)
- [Beszel vs Netdata vs Glances: Homelab Monitoring (techfuelhq)](https://techfuelhq.com/homelab/beszel-vs-netdata-vs-glances-2026/)
- [Self-hosted monitoring: from Netdata through Grafana to Beszel (denshub)](https://denshub.com/en/self-hosted-monitoring/)
- [Building a Homelab Monitoring Stack with Prometheus + Grafana: 2026 Edition (metasora)](https://metasora.com/blog/homelab-monitoring-stack-2026/)
- [Beszel vs Prometheus + Grafana — Simplicity vs Power (instapods)](https://instapods.com/apps/beszel/vs/prometheus/)
- [How to Monitor Proxmox with Beszel in 5 Minutes (dev.to)](https://dev.to/vikasprogrammer/how-to-monitor-proxmox-with-beszel-in-5-minutes-2026-45c8)
- [pve-monitoring — Proxmox temperature & disk-health stats to InfluxDB2 (GitHub)](https://github.com/MightySlaytanic/pve-monitoring)
- [Proxmox Monitoring With Real-Time Observability (Netdata)](https://www.netdata.cloud/solutions/technologies/proxmox-monitoring/)
