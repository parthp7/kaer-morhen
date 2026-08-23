# kaer-morhen

## Docs
- [Hardware inventory](docs/hardware-inventory.md) — cluster/node specs (CPU, GPU, memory, storage, network) and switch config for the kaermorhen homelab
- [Storage layout & runbook](docs/storage.md) — as-built disk configuration (ZFS pools `silver`/`steel` on geralt, ext4 backup disk on yennefer) with the full build commands
- [Network plan](docs/network.md) — /24 address map, VMID = last-octet convention, guest ID bands per node, and the allocation registry
- [Backup setup & runbook](docs/backups.md) — PBS on yennefer (LXC 200, datastore `vault`), nightly all-guest jobs from both nodes, prune/GC/verify schedules, and the tested restore procedure
- [Monitoring & alerting](docs/monitoring.md) — Beszel hub (LXC 204 on yennefer) + agents on both nodes, alert thresholds, and native failure alerting (PVE notifications, zed, smartd) all delivering to one ntfy topic
- [DNS & ad-blocking](docs/dns.md) — Pi-hole pair (LXC 101 on geralt, 201 on yennefer), Cloudflare upstream, conditional forwarding, and the two-server router handout that keeps house DNS up across a node reboot
- [Maintenance & upgrades](docs/maintenance.md) — the weekly/monthly/quarterly cadence, per-guest upgrade exceptions, geralt's boot-critical invariants, rollback paths, and the version registry for every host and container image
- [Docker VM](docs/docker-vm.md) — ciri (VM 150): disk split, mounts, and the stack inventory
- [GPU passthrough](docs/gpu-passthrough.md) — GTX 1060 via VFIO to ciri, the D3cold/PGON trap, and CDI wiring
- [Uptime-Kuma](docs/uptime-kuma.md) — LXC 104: the monitor list, push monitors, and alerting gaps
- [Tailscale](docs/tailscale.md) — subnet-router pair (203 primary, 103 standby) and split DNS
- [Jellyfin clients](docs/jellyfin-clients.md) — client compatibility matrix and the Samsung Tizen sideload

## Scripts
- [scripts/maintenance/](scripts/maintenance/) — `lab-inventory.sh`, `lab-smoke.sh`, `lab-deep-check.sh`: read-only tooling run from the laptop to decide what to upgrade and to prove nothing broke afterwards
- [scripts/monitoring/](scripts/monitoring/) — health checks feeding Uptime-Kuma push monitors, plus `smartd-ntfy.sh`, the smartd → ntfy alert handler on both nodes
- [scripts/backup/](scripts/backup/) — `restic-photos.sh` and its systemd timers: daily backup of `steel/photos` to yennefer, with a monthly read-data verify
- [scripts/proxmox/](scripts/proxmox/) — the media-disk udev autoheal and the VM 150 pre-start mount guard

## Proposals
- [001 — Initial software infrastructure plan](docs/proposals/001-initial-infrastructure-plan.md) — storage/network/VLAN baseline, monitoring stack, docker VM layout, LXC services, and backup design (accepted; storage implemented)
- [002 — Local AI stack](docs/proposals/002-local-ai-stack.md) — Ollama + Open WebUI + SearXNG on ciri (deployed)
- [003 — Reverse proxy](docs/proposals/003-reverse-proxy.md) — Caddy in LXC 202 serving every service as `<app>.kaermorhen.fyi` behind one wildcard cert (deployed)
- [004 — Media mount self-healing](docs/proposals/004-media-mount-self-healing.md) — superseded by 005, never implemented
- [005 — NFS media share](docs/proposals/005-nfs-media-share.md) — `/mnt/media` served to ciri over NFS on an isolated storage network (deployed and verified)
- [006 — Maintenance and upgrades](docs/proposals/006-maintenance-and-upgrades.md) — how patching and version upgrades are decided, performed, and proven not to have broken anything (tooling built and verified; first pass pending)
