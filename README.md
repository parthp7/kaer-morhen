# kaer-morhen

## Docs
- [Hardware inventory](docs/hardware-inventory.md) — cluster/node specs (CPU, GPU, memory, storage, network) and switch config for the kaermorhen homelab
- [Storage layout & runbook](docs/storage.md) — as-built disk configuration (ZFS pools `silver`/`steel` on geralt, ext4 backup disk on yennefer) with the full build commands
- [Network plan](docs/network.md) — /24 address map, VMID = last-octet convention, guest ID bands per node, and the allocation registry
- [Backup setup & runbook](docs/backups.md) — PBS on yennefer (LXC 200, datastore `vault`), nightly all-guest jobs from both nodes, prune/GC/verify schedules, and the tested restore procedure

## Proposals
- [001 — Initial software infrastructure plan](docs/proposals/001-initial-infrastructure-plan.md) — storage/network/VLAN baseline, monitoring stack, docker VM layout, LXC services, and backup design (accepted; storage implemented)
