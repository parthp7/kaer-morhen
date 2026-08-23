# Maintenance & upgrades — operating doc

How the lab gets patched and upgraded, and the registry of what version
everything is on. Design and rationale:
[proposal 006](proposals/006-maintenance-and-upgrades.md). Tooling:
[`scripts/maintenance/`](../scripts/maintenance/).

**House policy: nothing auto-updates.** Every upgrade is a deliberate human
action. These procedures exist to make that action cheap and repeatable, not to
automate it away.

## The one hardware fact that shapes everything

**Neither node can be woken remotely** — WoL fails on both and there is no BMC
([hardware-inventory.md](hardware-inventory.md)). A reboot that does not come
back is a trip to the laptop. Therefore:

- **One node per window, never both.** Their mirror-paired services (Pi-hole,
  Tailscale) are only redundant if the other node is up.
- **yennefer first, geralt second** — prove the procedure on the low-stakes node
  while Kuma and every service are still alive to observe it.
- **Host reboots require physical presence.** Guest patching does not. That
  split is why the weekly pass is remote and the monthly one is not.

## Cadence

| Cadence | Scope | Time | Presence |
|---|---|---|---|
| **Weekly** | inventory → refresh caches → apt on LXCs + ciri (no host reboot) → smoke | ~30 min | Remote |
| **Monthly** | node apt + kernel + reboot, **one node per window**, invariants gated | ~1 h/node | **Physical** |
| **Quarterly** | docker tiers 0–2, staged | ~2 h | Remote |
| **Ad hoc** | a CVE with a working exploit; a feature you actually want | — | — |
| **Planned** | DB majors, PVE major version | own proposal | **Physical** |

## Weekly pass

```bash
# 1. Decide, and take a baseline BEFORE changing anything.
scripts/maintenance/lab-inventory.sh
scripts/maintenance/lab-smoke.sh
```

A failure in the *baseline* is pre-existing — understand it now, rather than
misattributing it to the upgrade later.

```bash
# 2. Refresh anything the report marked "cache Nd stale".  [on the node]
apt update
for id in $(pct list | awk 'NR>1 {print $1}'); do pct exec "$id" -- apt update; done

# 3. Upgrade guests: LXCs first, then ciri.  [on the node]
pct exec <id> -- apt full-upgrade -y
```

Then the **per-guest exceptions** below.

```bash
# 4. Prove it.
scripts/maintenance/lab-smoke.sh
scripts/maintenance/lab-deep-check.sh
```

### Per-guest exceptions

| Guest | Extra step |
|---|---|
| **202 `proxy`** | `apt upgrade` **drops the `caddy-dns/cloudflare` plugin.** Re-run `caddy add-package github.com/caddy-dns/cloudflare`, then confirm `caddy list-modules \| grep cloudflare`. Skip it and renewals fail ~30 days later with "no solvers available" |
| **104 `uptime-kuma`** | Not apt: `systemctl stop uptime-kuma` → `runuser -u uptime-kuma -- bash -c 'cd /opt/uptime-kuma && git fetch --all && npm run setup'` → start |
| **150 `ciri`** | Ubuntu apt + Docker's repo + NVIDIA's repo. After a toolkit bump, confirm the `docker.service.d/wait-for-cdi.conf` drop-in survived and `NVIDIA_CTK_CDI_OUTPUT_FILE_PATH` still points at `/etc/cdi/nvidia.yaml` |
| Both nodes | Nothing — the subscription-nag patch re-applies itself via `/etc/apt/apt.conf.d/no-nag-script` |

## Monthly pass (physical)

**One node.** yennefer first, geralt only after yennefer is fully green.

```bash
apt full-upgrade -y      # [on the node]
reboot
```

When it returns:

```bash
scripts/maintenance/lab-inventory.sh --strict    # invariants MUST pass
scripts/maintenance/lab-smoke.sh
scripts/maintenance/lab-deep-check.sh
```

### geralt's boot-critical invariants

Checked automatically by `lab-inventory.sh`. Each is a documented way this lab
has broken; all six live in the initramfs or in config a package can overwrite.

| Invariant | Expected | If wrong |
|---|---|---|
| `vfio_pci disable_idle_d3` | `Y` | The host **wedges hard** 68–124 s after boot — no panic, empty pstore |
| `usb_storage quirks` | `0bc2:ab24:u` | `uas` re-binds the SMR media disk; SMART goes away. **Never re-add this to GRUB** — that caused boot hangs 3-in-6 |
| VM 150 `onboot` | `1` | `onboot: 0` **arms** the D3cold bug. Do not "safely" disable autostart |
| `GRUB_CMDLINE_LINUX_DEFAULT` | empty | `quiet` hides the boot hang it was removed to expose |
| `zfs_arc_max` | `2147483648` | ARC eats RAM the guests need |
| `/mnt/media` | `ext4`, exported | Media stack is serving nothing |

### Restarting ciri

**Never `qm reboot 150`.** Back-to-back stop/start races the IOMMU teardown and
fails with `Could not open '/dev/vfio/2': Device or resource busy`.

```bash
qm stop 150
until ! fuser -s /dev/vfio/2; do sleep 1; done
qm start 150
docker ps    # inside ciri — `qm start` succeeding does NOT mean jellyfin/ollama came up
```

The GTX 1060 has no FLR: a wedged GPU means a full geralt reboot.

## Quarterly: docker upgrades

Per stack: read the release notes → **record the current tag as the rollback**
in the registry below → bump the tag in `configs/ciri/<stack>/compose.yaml` →
`scp` to `ciri:/data/stacks/<stack>/` → `docker compose pull && docker compose up -d`
→ verify → smoke test.

**Pre-flight:** mount guards (`create_host_path: false`) make jellyfin,
qbittorrent, sonarr, radarr, bazarr and ollama **refuse to start** on recreate if
`/mnt/media/library`, `/mnt/torrents/incomplete` or `/mnt/ai-models` is missing.
Check mounts *before* pulling; `docker image prune` after.

| Tier | Services | Handling |
|---|---|---|
| 0 | nebula-sync, flaresolverr, searxng, alpine, memos | Bulk, one pass |
| 1 | jellyseerr, bazarr, prowlarr, open-webui, ollama, couchdb (3.x) | One stack at a time |
| 2 | Immich, Paperless, Sonarr, Radarr, qBittorrent, gluetun, Jellyfin, Sure | Own window each |
| 3 | postgres majors, redis 7.4→8, valkey, Immich's pg14+VectorChord | **Own proposal** — dump+restore |

### Tier-2 hard rules

- **Never restart `gluetun` alone** — it destroys the netns under qBittorrent.
  Recovery: `docker restart gluetun && sleep 8 && docker restart qbittorrent`.
- **Check any gluetun bump against `/v1/portforward`** — the sidecar hardcodes it.
- **Jellyfin + Ollama are one change unit** (shared GPU via CDI).
- **After a Jellyfin major, re-run the Samsung Tizen sideload.**
- **Sure**: verify AI chat still answers — a bind-mounted initializer
  monkeypatches `Chat::UNDELIVERED_RESPONSE_TIMEOUT` and an upstream refactor
  breaks it silently.
- **`docker compose pull` skips profile-gated services** — the
  `postgres-backup-local` sidecars need `--profile backup` and must track the
  postgres major.
- **Immich**: `database`/`redis` service names are load-bearing DNS; `.immich`
  markers must exist; never substitute plain `postgres:16`.
- **Restarting dockerd restarts every container on ciri** — schedule it.

## Rollback

| Broken | Path |
|---|---|
| A guest | PBS restore (`pct restore` / `qm restore`) — loop proven 2026-07-10 |
| A container | Re-pin the previous tag from the registry, `docker compose up -d` |
| A host, not booting | **Physical access. There is no host-level backup.** |

---

# Version registry

Single source of truth for "what is everything on, and when was it last
checked". Update every cycle. **Fill in "Previous" before bumping** — a rollback
cannot name a version it never recorded.

## Platform (verified 2026-08-23)

| Host | Component | Current | Notes |
|---|---|---|---|
| geralt | pve-manager | **9.2.4** | **98 pending, incl. security — behind yennefer** |
| geralt | kernel | 7.0.14-4-pve | |
| yennefer | pve-manager | **9.2.11** | 2 pending (both kernels) |
| yennefer | kernel | 7.0.14-4-pve | |
| 200 `pbs` | Proxmox Backup Server | 4.x | 39 pending |
| 201 `pihole-2` | Pi-hole | v6 | 35 pending |
| 202 `proxy` | Caddy | 2.11.4 | cloudflare plugin **present** |
| 104 `uptime-kuma` | Uptime-Kuma | 2.4.0 | per as-built doc; not re-verified |
| 150 `ciri` | Ubuntu | 26.04 LTS | kernel 7.0.0-30-generic, 8 pending |
| 150 `ciri` | Docker Engine | **29.7.2** | docs said 29.6.1 — drift corrected |
| 150 `ciri` | Docker Compose | **v5.5.0** | docs said v5.3.1 — drift corrected |
| 150 `ciri` | nvidia-container-toolkit | **1.20.0** | docs said 1.19.1 — drift corrected |

## Container images (verified 2026-08-23)

| Stack | Service | Current | Previous (rollback) | Tier |
|---|---|---|---|---|
| ai | ollama | `ollama/ollama:0.32.5` | — | 1 |
| ai | open-webui | `ghcr.io/open-webui/open-webui:v0.11.0` | — | 1 |
| ai | searxng | `searxng/searxng:2026.7.28-c01178d03` | — | 0 |
| immich | server | `ghcr.io/immich-app/immich-server:v3.0.2` | — | 2 |
| immich | machine-learning | `ghcr.io/immich-app/immich-machine-learning:v3.0.2` | — | 2 |
| immich | database | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` | — | 3 |
| immich | redis | `valkey/valkey:9` ⚠️ **floating** | — | 3 |
| jellyfin | jellyfin | `jellyfin/jellyfin:10.11.11` | — | 2 |
| memos | memos | `neosmemo/memos:0.29.1` | — | 0 |
| nebula-sync | nebula-sync | `ghcr.io/lovelaze/nebula-sync:v0.11.2` | — | 0 |
| obsidian-sync | couchdb | `couchdb:3.5.2.1` | — | 1 |
| paperless | webserver | `ghcr.io/paperless-ngx/paperless-ngx:2.20.15` | — | 2 |
| paperless | db | `postgres:16` | — | 3 |
| paperless | broker | `redis:7.4-alpine` | — | 3 |
| paperless | backup | `prodrigestivill/postgres-backup-local:16` | — | 3 |
| servarr | gluetun | `qmcgaw/gluetun:v3.41.1` | — | 2 |
| servarr | qbittorrent | `lscr.io/linuxserver/qbittorrent:version-5.2.3_v2.0.13` | — | 2 |
| servarr | qbit-port-sync | `alpine:3.21` | — | 0 |
| servarr | prowlarr | `lscr.io/linuxserver/prowlarr:version-2.5.2.5491` | — | 1 |
| servarr | sonarr | `lscr.io/linuxserver/sonarr:version-4.0.19.2979` | — | 2 |
| servarr | radarr | `lscr.io/linuxserver/radarr:version-6.3.0.10514` | — | 2 |
| servarr | flaresolverr | `ghcr.io/flaresolverr/flaresolverr:v3.5.0` | — | 0 |
| servarr | bazarr | `lscr.io/linuxserver/bazarr:version-v1.6.0` | — | 1 |
| servarr | jellyseerr | `fallenbagel/jellyseerr:2.7.3` | — | 1 |
| sure | web / worker | `ghcr.io/we-promise/sure:stable` ⚠️ **floating** → v0.7.2 | — | 2 |
| sure | db | `postgres:16` | — | 3 |
| sure | redis | `redis:7.4-alpine` | — | 3 |
| sure | backup | `prodrigestivill/postgres-backup-local:16` | — | 3 |
| audiobookshelf | audiobookshelf | `ghcr.io/advplyr/audiobookshelf:2.35.1` | — | **NOT DEPLOYED** |

⚠️ **Floating tags violate the pinning policy.** `sure:stable` and `valkey:9`
both move on their own, so an incident cannot answer "what changed?" and a
rollback has no version to name. Pin them (`sure:stable` currently resolves to
**v0.7.2**).

## Open items

- **Kuma `resend_interval = 0` on ~29 monitors** — notifies once, then never
  again. Caused a 12-day silent outage. **Highest-value fix in the lab**; do it
  before relying on any post-upgrade monitoring.
- **`books.kaermorhen.fyi` → 502** — Caddy routes to an audiobookshelf backend
  that was never deployed. Deploy the stack or remove the route.
- **Pin the two floating tags.**
- **geralt is 98 packages behind**, including security updates.
- **Node version divergence was unexplained** (geralt 9.2.4 vs yennefer 9.2.11).
  This registry exists so it cannot recur silently.
- **No host-level backup exists** — the one rollback path the lab does not have.
