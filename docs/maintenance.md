# Maintenance & upgrades — operating doc

How the lab gets patched and upgraded, and the registry of what version
everything is on. Design and rationale:
[proposal 006](proposals/006-maintenance-and-upgrades.md). Tooling:
[`scripts/maintenance/`](../scripts/maintenance/).

**House policy: nothing auto-updates.** Every upgrade is a deliberate human
action. These procedures exist to make that action cheap and repeatable, not to
automate it away.

`unattended-upgrades` must stay off everywhere. On 2026-11-01 it was found enabled
on ciri, which is why ciri's kernel and NVIDIA driver had moved without a registry
entry, and the decision was to disable it. The nodes and all nine LXCs do not have
the package installed. Disabling `unattended-upgrades.service` is not enough:
`apt-daily-upgrade.timer` runs the updater directly, gated by
`APT::Periodic::Unattended-Upgrade`. ciri turns that off in
`/etc/apt/apt.conf.d/99-no-unattended-upgrades`; confirm with
`apt-config dump | grep Unattended-Upgrade`.

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

## Full pass — everything in one visit

Use this order when the weekly, monthly and quarterly work are all due. Each
stage names a section below for the detail. Stop at the first failed gate.

| # | Stage | Gate before moving on |
|---|---|---|
| 0 | **Baseline**: inventory, smoke, deep check, Tailscale primary, last night's backups | Failures understood and written down |
| 1 | **yennefer LXCs**, standby before primary: 204, 205, 201, 203, 202, then 200 | Smoke green; Caddy plugin present |
| 2 | **yennefer node**: upgrade + reboot. **This drops the whole LAN** (see below) | `--strict`, smoke, deep check |
| 3 | **geralt LXCs**: 103, then 101, then 104 | Smoke green |
| 4 | **ciri apt**: this restarts every container. Confirm DKMS built the new kernel | `dkms status` lists the new kernel |
| 5 | **geralt node**: `qm shutdown 150`, upgrade, reboot. ciri boots its new kernel here | `--strict` **inside the 68–124 s wedge window**, smoke, deep check |
| 6 | **Docker tiers** 0, then 1, then 2 | Each stack verified before the next |
| 7 | **Registry and sign-off**: record versions, then prune rollbacks later | — |

Why this order:

- **Docker last.** The hosts change first, so a broken app afterwards points at
  the app's own bump rather than at the platform under it.
- **ciri apt just before the geralt reboot.** Upgrading `docker-ce` restarts
  dockerd, which restarts every container (no `live-restore`). Doing it here
  means one disruption is absorbed rather than two.
- **Avoid ~21:50 IST**, where the WAN has been dropping for ~17 minutes every 72
  hours, and **04:00–05:00**, the PBS backup window. Do not upgrade LXC 200 while
  a backup is running.
- **Remote access can drop at any stage.** Tailscale upgrades restart the daemon
  and yennefer's reboot takes the LAN down. Be on site, or stop after stage 1.

**yennefer's reboot is a whole-lab outage.** The TL-SG108E switch is powered from
its USB port, so geralt, ciri and every guest lose LAN connectivity until it is
back. Expect Kuma to go red across the board, with alerts arriving late or not
at all, and don't read that as a fault in the upgrade. One node per window still
holds for risk, but the Pi-hole and Tailscale pairs give **no** redundancy during
this particular reboot.

## Weekly pass

```bash
# 1. Decide, and take a baseline BEFORE changing anything.
scripts/maintenance/lab-inventory.sh
scripts/maintenance/lab-smoke.sh
```

From a worktree, `lab-smoke.sh` cannot find the git-ignored secrets file. Run
`SECRETS_FILE=<main-checkout>/secrets.local.yaml scripts/maintenance/lab-smoke.sh`.

A failure in the *baseline* is pre-existing — understand it now, rather than
misattributing it to the upgrade later.

```bash
# 2. Refresh anything the report marked "cache Nd stale".  [on the node]
apt update
for id in $(pct list | awk 'NR>1 {print $1}'); do pct exec "$id" -- apt update; done

# 3. Upgrade guests: LXCs first, then ciri.  [on the node]
#    Order within a pair: the Tailscale/Pi-hole that is NOT primary goes first.
pct exec <id> -- apt full-upgrade -y

# ciri is a VM, so it is not in `pct list`.  [inside ciri]
sudo apt update && sudo apt full-upgrade -y
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
| **202 `proxy`** | **Only when `caddy` is in the upgrade set** (check `apt list --upgradable`). The package overwrites the custom build and **drops the `caddy-dns/cloudflare` plugin**. First `cp -a /usr/bin/caddy /root/caddy-<version>-cloudflare`, the rollback if the rebuild fails. After apt, run `caddy add-package github.com/caddy-dns/cloudflare`, `systemctl restart caddy`, then confirm `caddy list-modules --packages \| grep cloudflare` and `systemctl is-active caddy`. Skip it and renewals fail ~30 days later with "no solvers available". Caddy also **stops until the plugin is back**, taking down every proxied name at once: on 2026-11-01 (2.11.4 → 2.11.7) the service failed to start at 23:00:52 and came back at 23:01:31 once the plugin was restored. Have the fix ready to run straight after apt |
| **101, 201 Pi-hole** | Apt only moves `pihole-meta`, **not Pi-hole itself**. Run `/usr/local/bin/pihole -up` (`pct exec` has no `/usr/local/bin` on its `PATH`). pihole-2 (201) first, confirm it resolves, then 101. nebula-sync overwrites 201 from 101 hourly |
| **103, 203 Tailscale** | Apt, from Tailscale's own repo. The daemon restarts on upgrade, so upgrade the **standby first** ([which is which](#subnet-router-failover-is-expected-and-does-not-fail-back)), confirm it is online, then the primary |
| **104 `uptime-kuma`** | Not apt, and **`npm run setup` alone does not upgrade**: its script is `git checkout <installed version> && …`, so it reinstalls what you already have. Stop the service, then `runuser -u uptime-kuma -- bash -c 'cd /opt/uptime-kuma && git fetch --all --tags && git checkout <new tag> --force && npm ci --omit dev --no-audit && npm run download-dist'`, then start it. Run as root, `git` refuses this repo as dubious ownership. Confirm the version in the UI |
| **204 `beszel` + agents** | Not apt, and on no one's list until 2026-11-01. The hub is `/opt/beszel/beszel` and the agents are `beszel-agent` on geralt, yennefer and ciri. Keep hub and agents in step. Decline any offer of auto-update ([monitoring.md](monitoring.md)) |
| **150 `ciri`** | Ubuntu apt + Docker's repo + NVIDIA's repo. **`docker-ce` restarts dockerd, so every container restarts**, including the gluetun netns set: re-check `qbit-port-sync` and `suwayomi` afterwards. Before rebooting, `dkms status` must list `nvidia-srv` for the **new** kernel, or ciri boots without the GPU. A toolkit bump can raise a dpkg prompt for `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env`: **answer `N`**, because that file holds the fix for the [boot race](gpu-passthrough.md). Answering `Y` on 2026-11-01 dropped the setting, and the spec silently moved to tmpfs `/var/run/cdi`. Before rebooting, confirm the `docker.service.d/wait-for-cdi.conf` drop-in survived and that an **uncommented** `NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/etc/cdi/nvidia.yaml` is present (a `.dpkg-old` hit doesn't count) |
| Both nodes | Nothing — the subscription-nag patch re-applies itself via `/etc/apt/apt.conf.d/no-nag-script` |
| **205 `pulse`** | Not apt: `curl -fsSL <install.sh> -o /tmp/pulse-install.sh`, read it, then `bash /tmp/pulse-install.sh --version <next tag>`. Auto-update is deliberately off. After a PVE or PBS certificate is regenerated, its **pinned fingerprint in Pulse goes stale** and that instance goes Unreachable, then **paused** — re-pin and resume it explicitly ([proposal 008](proposals/008-lab-dashboard.md)) |
| **150 `ciri` — `homepage` stack** | The only stack with a **`build:`** (OliveTin plus `openssh-clients` and `jq`). Bump the `FROM` tag in `olivetin/Dockerfile`, then `docker compose build --pull` **before** `up -d`; a plain `pull` leaves the old local image in place |

## Monthly pass (physical)

**One node.** yennefer first, geralt only after yennefer is fully green.

**Geralt only:** shut ciri down first (`qm shutdown 150`), as the D7 pass did.
`onboot: 1` brings it back after the reboot. Do not change that flag.

```bash
apt full-upgrade -y      # [on the node]
# run the kernel-retention checks below, then:
reboot
```

When it returns:

```bash
scripts/maintenance/lab-inventory.sh --strict    # invariants MUST pass
scripts/maintenance/lab-smoke.sh
scripts/maintenance/lab-deep-check.sh
```

### Kernel retention — what to keep, what is safe to prune

The rollback for a kernel upgrade is **the previous kernel of the same series**.
Losing it turns a bad boot from a GRUB menu selection into a rescue-media job,
on nodes that already have no remote power-on.

| Rule | Why |
|---|---|
| Keep at least the previous kernel of the **running series** (upgrading to `7.0.14-26` → keep `7.0.14-12`) | It is the rollback. Nothing else substitutes for it |
| **Verify it is bootable, not merely installed**, before you reboot | `dpkg -l` proving the package is present is not the same as GRUB offering it |
| A superseded point release from a **different** series is safe to prune | Upgrading the `proxmox-kernel-6.17` meta orphans the old 6.17 point release; that is not the rollback for a 7.0 upgrade |
| Never run `apt autoremove` blind after a kernel upgrade | Dry-run it first and read the list |

```bash
# before rebooting: is the rollback actually in the boot menu?
ls -l /boot/vmlinuz-<previous>-pve /boot/initrd.img-<previous>-pve
grep -c "<previous>-pve" /boot/grub/grub.cfg        # expect > 0
apt-get autoremove --dry-run                        # read what it wants to take
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

### Subnet-router failover is expected, and does not fail back

Rebooting either node promotes the *other* Tailscale subnet router to primary
for the LAN route, and **Tailscale keeps the new primary until it goes away** —
it does not hand back. After the D6 yennefer pass, `tailscale-2` (103 on geralt)
holds the route and `tailscale-1` (203) is online but not serving.

That is correct behaviour, but check which node currently holds it *before* the
next window: whichever one does is carrying remote access, and it should not be
the node you are about to reboot.

```bash
ssh lab-geralt   'pct exec 103 -- tailscale status --json' | grep -o '"PrimaryRoutes":[^]]*]'
ssh lab-yennefer 'pct exec 203 -- tailscale status --json' | grep -o '"PrimaryRoutes":[^]]*]'
```

### Restarting ciri

**Never `qm reboot 150`.** Back-to-back stop/start races the IOMMU teardown and
fails with `Could not open '/dev/vfio/2': Device or resource busy`.

```bash
qm stop 150
until ! fuser -s /dev/vfio/2; do sleep 1; done
qm start 150
docker ps    # inside ciri — `qm start` succeeding does NOT mean jellyfin/ollama came up
```

The GTX 1060 has no FLR: a wedged GPU means a full geralt reboot, so a ciri
restart is only low-risk while someone can reach geralt. When a geralt reboot is
already planned, let that restart ciri rather than doing it twice.

## Quarterly: docker upgrades

Per stack: read the release notes → **record the current tag as the rollback**
in the registry below → bump the tag in `configs/ciri/<stack>/compose.yaml` →
`scp` to `ciri:/data/stacks/<stack>/` → `docker compose pull && docker compose up -d`
→ verify → smoke test.

**Pre-flight:** mount guards (`create_host_path: false`) make jellyfin,
qbittorrent, sonarr, radarr, bazarr and ollama **refuse to start** on recreate if
`/mnt/media/library`, `/mnt/torrents/incomplete` or `/mnt/ai-models` is missing.
Check mounts *before* pulling; `docker image prune` after — but **only once the stack is
signed off**, since the previous image is half the rollback.

| Tier | Services | Handling |
|---|---|---|
| 0 | nebula-sync, flaresolverr (both), searxng, alpine, mazanoke, socket-proxy, static-web-server | Bulk, one pass |
| 1 | homepage, olivetin, seerr, bazarr, prowlarr, open-webui, ollama, couchdb (3.x), stirling-pdf, memos, suwayomi, komga, kavita | One stack at a time |
| 2 | Immich, Paperless, Sonarr, Radarr, qBittorrent, gluetun (both), Jellyfin, Sure, n8n, Vaultwarden | Own window each |
| 3 | postgres majors, redis 7.4→8, valkey, Immich's pg14+VectorChord | **Own proposal** — dump+restore |

### Tier-2 hard rules

- **Never restart `gluetun` alone** — it destroys the netns under qBittorrent.
  Recovery: `docker restart gluetun && sleep 8 && docker restart qbittorrent`.
- **`qbit-port-sync` shares that same netns and is the one everyone forgets.** It is
  joined to gluetun's *container ID* exactly as qBittorrent is
  (`NetworkMode=container:<gluetun-id>`), but its image (`alpine:3.21`) rarely changes, so
  `docker compose up -d` recreates gluetun and qBittorrent and leaves the sidecar attached
  to a destroyed namespace. It fails **silently** — no crash, the forwarded port simply
  stops tracking, and you notice days later. When bumping gluetun or qBittorrent, recreate
  the whole triple in one go and let `depends_on` order it:
  `docker compose up -d --force-recreate gluetun qbittorrent qbit-port-sync`.
  Do **not** append the manual `docker restart gluetun && …` recovery afterwards — after a
  correct compose recreate it destroys the namespace a second time and re-pairs only
  qBittorrent, causing the exact fault the rule above prevents.
- **A qBittorrent-only bump can leave gluetun alone**: `docker compose up -d
  --no-deps qbittorrent` keeps the same netns, listen port and sidecar, and avoids
  risking Proton's port forward (proven 2026-11-02, 5.2.3 → 5.3.0). The triple
  recreate is for gluetun bumps.
- **Pull only the services you are changing** in this stack. A bare `docker compose pull`
  also re-points `alpine:3.21`, stranding the running `qbit-port-sync` on an untagged
  image ID — the shared-tag drift described at the end of this file.
- **The same netns rule applies to `manga-gluetun`.** `suwayomi` and
  `manga-flaresolverr` both run on `network_mode: service:manga-gluetun`, so
  recreate all three together. `komga` and `kavita` are outside the tunnel.
- **Stop the auto-fix while you work on gluetun.** `servarr-vpn-health.timer`
  triggers `servarr-vpn-remediate@`, which restarts containers. Run
  `sudo systemctl stop servarr-vpn-health.timer` first and start it again once
  the triple is verified, so the two cannot fight over the same containers.
- **Check any gluetun bump against `/v1/portforward`** — the sidecar hardcodes it.
- **Jellyfin + Ollama are one change unit** (shared GPU via CDI).
- **Jellyfin 10.11 → 12.x is a one-way migration** (decided 2026-11-01, target
  `jellyfin/jellyfin:12.4`; a direct upgrade from 10.11.x is supported). The
  sideloaded Samsung Tizen build is checked and refreshed **after** the server is
  done, so the TV may misbehave until then. In order:
  1. Stop the container, then tar `/data/stacks/jellyfin/config` into
     `/data/backups/` and confirm it with `ls -lh`. That tarball is the rollback;
     re-pinning `10.11.11` is not.
  2. Confirm no two usernames differ only by case. The migration needs them
     unique, and they must be fixed before upgrading.
  3. Bump, `up -d`, and watch the first boot log until migrations finish.
  4. Run a **full library scan**, which upstream requires. It restores
     alternative versions, takes much longer than usual, and some films may
     appear newly added.
     Homepage's widget needs `version: 2` in `services.yaml`, because v1 calls
     the removed `/emby` routes.
  5. Check for what the migration switched off. **Legacy authorization is forced
     off on existing installs** (ours was `true`) and `/emby/*` and
     `/mediabrowser/*` are gone. Test the Homepage widget, Seerr, the Sonarr and
     Radarr connections, then the TV, Infuse and Streamyfin.
  6. Confirm `lab-deep-check.sh --only gpu` and that Ollama still shares the GPU.
  7. Re-run the Tizen sideload once a build for 12.x is confirmed.
- **n8n carries the bank-alert pipeline** ([proposal 010](proposals/010-bank-alerts-to-sure.md)).
  After a bump, confirm the workflow is active and a real alert reaches Sure. A
  200 from the UI proves nothing about that path.
- **Memos changed version scheme** (`0.30.0` → `26.11.0`). It is tier 1 now, not
  bulk: read the migration notes and treat it as a data migration, not a patch.
  **Anything older than `0.31.0` must run `0.31.0` first.** Going straight to
  26.x fails in a restart loop with `database schema … is too old to upgrade
  directly`, before touching the database (hit 2026-11-02).
- **Read each release's own "upgrade path" section.** A keyword scan of release
  notes is a triage aid and missed the memos requirement above. A major jump, or
  a version scheme change, gets its notes read in full.
- **Vaultwarden has no second chance at a bad upgrade.** Before any bump, confirm
  last night's backup exists, and afterwards confirm a client can sync and unlock.
- **After a Jellyfin major, re-run the Samsung Tizen sideload.**
- **Seerr**: after any move that resets it, re-check Settings → Network → **Enable
  Proxy Support** and Settings → General → **Application URL**. Off, Express rejects
  Caddy's `X-Forwarded-For` and rate limiting keys on the proxy instead of the client.
  Never hand-edit `settings.json` — Seerr rewrites it, like Jellyfin's `system.xml`.
- **Sure**: verify AI chat still answers. Since the 0.7.6 upgrade the reply
  timeout is upstream's `AI_RESPONSE_TIMEOUT`, fed from
  `LLM_UNDELIVERED_RESPONSE_TIMEOUT` in `.env`. The bind-mounted initializer that
  patched `Chat::UNDELIVERED_RESPONSE_TIMEOUT` is inert there, because the
  constant is gone, and can be removed once 0.7.3 stops being the rollback. "No reply" is far more often
  **latency** than breakage: check `docker exec ollama ollama ps` for
  `100% GPU` before suspecting the patch — a model larger than the 6 GB card
  runs on CPU and a multi-tool reply can take 5 minutes, while the browser
  watchdog gives up at a hardcoded 90 s.
- **Paperless majors rewrite the DB one way.** For v3, `PAPERLESS_DBENGINE`
  became mandatory — without it the app starts on an **empty SQLite** database
  and looks exactly like total data loss while Postgres sits untouched. Verify
  the engine after any major, not just that the page loads.
- **`docker compose pull` skips profile-gated services** — the
  `postgres-backup-local` sidecars need `--profile backup` and must track the
  postgres major.
- **Immich**: `database`/`redis` service names are load-bearing DNS; `.immich`
  markers must exist; never substitute plain `postgres:16`.
- **Restarting dockerd restarts every container on ciri** — schedule it.
- **A pull re-points shared tags lab-wide.** `postgres:16` and
  `redis:7.4-alpine` are used by both `sure` and `paperless`; pulling in one
  stack moves the tag for the other, leaving its running containers on an
  untagged image that `docker ps` shows as a bare ID. After pulling a stack
  that shares an image, check `docker ps` for bare IDs and bring the other
  stack in line deliberately rather than letting it jump on some later,
  unrelated `up -d`.

## Rollback

> ⚠️ **"Re-pin the previous tag" is only a complete rollback for ordinary version
> bumps.** It does **not** hold for images that migrate their data on first start —
> `seerr` (the Jellyseerr merge) and any Jellyfin major both rewrite their DB one-way. For
> those, the rollback is restoring the pre-migration config tarball; the tag alone will
> leave the old binary staring at a newer schema. Take that tarball with the container
> **stopped**, and keep it until the upgrade is signed off.

| Broken | Path |
|---|---|
| A guest | PBS restore (`pct restore` / `qm restore`) — loop proven 2026-07-10 |
| A container | Re-pin the previous tag from the registry, `docker compose up -d` |
| A host, not booting | **Physical access. There is no host-level backup.** |
| A host kernel | Pin the previous kernel, below |

### Kernel rollback: pin the previous kernel

Both nodes boot plain GRUB on UEFI (`/etc/kernel/proxmox-boot-uuids` does not exist,
so `proxmox-boot-tool status` errors). On such hosts `proxmox-boot-tool kernel pin`
writes `GRUB_DEFAULT` to `/etc/default/grub.d/proxmox-kernel-pin.cfg` and runs
`update-grub` itself. `/etc/default/grub` (`GRUB_DEFAULT=0`) is left alone, and so
is the `GRUB_CMDLINE_LINUX_DEFAULT` invariant. A pin survives later kernel installs
until it is removed.

**One node per window, physically present** (rules above). yennefer first. Its
reboot drops the whole LAN, because it powers the switch.

```bash
# [on the node] 1. the rollback must be bootable, not merely installed
ls -l /boot/vmlinuz-7.0.14-12-pve /boot/initrd.img-7.0.14-12-pve
grep -c "7.0.14-12-pve" /boot/grub/grub.cfg            # expect > 0
proxmox-boot-tool kernel list                          # 7.0.14-12-pve listed

# 2. pin it. Prints "Setting '7.0.14-12-pve' as grub default entry and running update-grub."
proxmox-boot-tool kernel pin 7.0.14-12-pve

# 3. verify BEFORE rebooting: both must name 7.0.14-12-pve
cat /etc/default/grub.d/proxmox-kernel-pin.cfg         # GRUB_DEFAULT="gnulinux-advanced-…>gnulinux-7.0.14-12-pve-advanced-…"
grep -m1 '^set default=' /boot/grub/grub.cfg

# 4. geralt only: stop ciri first (onboot: 1 brings it back)
qm shutdown 150

# 5.
reboot
```

When it returns:

```bash
uname -r                                               # [on the node] 7.0.14-12-pve
scripts/maintenance/lab-inventory.sh --strict          # [from the repo] invariants must pass
scripts/maintenance/lab-smoke.sh
```

- **If the pin did not take**, select the kernel by hand at the GRUB menu (Advanced
  options for Proxmox VE GNU/Linux, then `7.0.14-12-pve`). Then check step 3 again.
- **Only want to try it for one boot?** Use `proxmox-boot-tool kernel pin 7.0.14-12-pve --next-boot`.
- **To undo:** `proxmox-boot-tool kernel unpin`, then reboot. The snippet is removed and
  GRUB goes back to entry 0, the newest kernel.
- **While pinned, `lab-inventory.sh` reports `REBOOT NEEDED`** (running `-12`, newest
  installed `-26`). That is expected. Do not "fix" it with a reboot.
- **Never `apt autoremove` while a pin is in place** without a dry-run. Once the meta
  package moves on, the pinned kernel is exactly what autoremove offers to remove.

## Releasing rollbacks (image pruning)

> **Class A was released 2026-11-02.** Class B is done; class C has its own gate.
> The 2026-11-02 pass left its own rollbacks behind: release those once the pass
> is signed off. Nothing is broken and there is no deadline —
> `/data` had **32 G free** on 2026-11-02. Check that before a large pull: the
> images are the rollbacks for this pass, so don't release them to make room for it.

Old images are half the rollback, so pruning is the *last* step of an upgrade
cycle, never part of it. On ciri there are three distinct classes and only one
is safe to remove today.

### How pruning actually behaves here — read before typing

- **`docker image prune` frees nothing.** It removes only *dangling* (untagged)
  images and ciri has **zero**. Verify: `docker images -f dangling=true -q | wc -l`.
- **`docker system df` "RECLAIMABLE" is misleading.** It reported 22 G, and
  every byte of it is *tagged* rollback material.
- **Never `docker image prune -a` / `docker system prune -a`** — that is what
  the 22 G figure tempts you into, and it deletes every rollback in one go.
  **Always remove images by explicit name**; `docker rmi` refuses to delete an
  image a container is using, so naming them is self-protecting.
- **`docker system prune --volumes` is destructive** — data loss, never run it.
- **Two tags can share one image ID.** `sure:0.7.2` and `sure:stable` are the
  same ID (`96155b20c0b7`); removing one tag frees **0 bytes**. Untag both.

Find true candidates by image ID, not by name:

```bash
used=$(docker ps -aq | xargs -r docker inspect -f '{{.Image}}' | sort -u)
docker images --no-trunc --format '{{.ID}}|{{.Repository}}:{{.Tag}}|{{.Size}}' \
  | grep -v '<none>' \
  | while IFS='|' read -r id name size; do
      echo "$used" | grep -qxF "$id" || printf '%-58s %s\n' "$name" "$size"
    done
```

### Sign-off gate

Release the 2026-08-24 rollbacks only when **all** are true:

- Paperless v3 used for real for several days: search returns expected hits,
  the consume directory ingests, no OCR regressions.
- Immich v3.1.0: library browses, ML jobs complete.
- Sure 0.7.3: AI chat answers, balances correct.
- Ollama 0.32.15 + Jellyfin still share the GPU without contention.

### Class A — the 2026-08-24 upgrade rollbacks (~17.0 G) · **DONE 2026-11-02**

`ollama:0.32.5` (8.04 G) · `immich-server:v3.0.2` (3.11 G) ·
`paperless-ngx:2.20.15` (2.04 G) · `immich-machine-learning:v3.0.2` (1.85 G) ·
`sure:0.7.2` **and** `sure:stable` (1.38 G, shared ID) ·
`searxng:2026.7.28-c01178d03` (377 M) · `valkey:9.1.0` (167 M) ·
`memos:0.29.1` (90 M)

```bash
# ONLY after the sign-off gate above
docker rmi ollama/ollama:0.32.5 \
           ghcr.io/immich-app/immich-server:v3.0.2 \
           ghcr.io/immich-app/immich-machine-learning:v3.0.2 \
           ghcr.io/paperless-ngx/paperless-ngx:2.20.15 \
           ghcr.io/we-promise/sure:0.7.2 ghcr.io/we-promise/sure:stable \
           searxng/searxng:2026.7.28-c01178d03 \
           valkey/valkey:9.1.0 \
           neosmemo/memos:0.29.1
```

Then clear the *Previous (rollback)* column in the registry for those rows —
a tag that no longer exists is worse than an empty cell, because it reads as a
rollback that is available.

### Class B — unrelated leftovers · **DONE 2026-08-24**

Removed 2026-08-24: **3.28 G reclaimed** (images 43 → 38, 56.99 → 53.71 G).
Verified afterwards: 28/28 containers Up, no unhealthy or restarting, **0
dangling images left behind**, and all class A + C rollbacks intact. Kept here
as the worked example of what "safe to prune" looks like — nothing below is
anyone's rollback:

| Image | Size | Why safe |
|---|---|---|
| `ghcr.io/georift/install-jellyfin-tizen:latest` | 2.66 G | run as `docker run --rm`, re-pulls on demand; next needed after a Jellyfin major, which is deferred |
| `lscr.io/linuxserver/readarr:develop-…` | 278 M | decommissioned service, unreferenced anywhere in the repo |
| `valkey/valkey:9` | 183 M | superseded floating tag; the pinned `9.1.0` is the real rollback |
| `ubuntu:latest` | 160 M | unreferenced |
| `hello-world:latest` | 26 K | appears in `docker-vm.md` only as a smoke test that re-pulls |

```bash
# already executed 2026-08-24 — re-running is harmless (no such image)
docker rmi ghcr.io/georift/install-jellyfin-tizen:latest \
           lscr.io/linuxserver/readarr:develop-version-0.4.18.2805 \
           valkey/valkey:9 ubuntu:latest hello-world:latest
```

### Class C — other stacks' rollbacks · **hold, separate sign-off**

`fallenbagel/jellyseerr:2.7.3` (2.12 G) · `qbittorrent:…v2.0.13` (291 M) ·
`gluetun:v3.41.1` (60 M) · `rollback/paperless-postgres:16.14` (642 M) ·
`rollback/paperless-redis:7.4.9` (58 M).

These belong to the servarr/seerr migration and the floating-tag pins, not to
this pass. **Jellyseerr especially**: the seerr merge rewrote its DB one-way,
so its rollback is the tarball in `/data/backups/`, and the tag is only useful
alongside it.

---

# Version registry

Single source of truth for "what is everything on, and when was it last
checked". Update every cycle. **Fill in "Previous" before bumping** — a rollback
cannot name a version it never recorded.

## Platform (verified 2026-11-02, after the full pass)

| Host | Component | Current | Notes |
|---|---|---|---|
| geralt | pve-manager | **9.2.24** | 0 pending |
| geralt | kernel | **7.0.14-12-pve, pinned 2026-11-06** | Rolled back from `7.0.14-26`, which is still installed but ⚠️ **suspect** after the 2026-11-06 hard freeze ([geralt-hard-freeze.md](geralt-hard-freeze.md)). `7.0.14-28` pending, held until the test ends (~11-20) |
| yennefer | pve-manager | **9.2.24** | 0 pending |
| yennefer | kernel | **7.0.14-12-pve, pinned 2026-11-06** | Rolled back from `7.0.14-26`, which is still installed but ⚠️ **suspect**: boot SSD dropped 11-05 and 11-06, never on `-12` ([storage.md](storage.md) § Incident 2026-11-06). `7.0.14-28` pending, held until the test ends (~11-20) |
| geralt, yennefer, ciri | beszel-agent | **0.21.1** | was 0.18.7 |
| 200 `pbs` | Proxmox Backup Server | **4.2.8** | 0 pending |
| 101, 201 Pi-hole | Core / Web / FTL | **v6.5 / v6.6.1 / v6.8** | 0 pending |
| 103, 203 Tailscale | Tailscale | **1.104.4** | 0 pending |
| 202 `proxy` | Caddy | **2.11.7** | cloudflare plugin present; 2.11.4 build kept at `/root/caddy-2.11.4-cloudflare` |
| 104 `uptime-kuma` | Uptime-Kuma | **2.5.9** | was 2.4.0 |
| 204 `beszel` | Beszel hub | **0.21.1** | was 0.18.7; data backup at `/root/beszel-pre-0.21.1.tar.gz` |
| 205 `pulse` | Pulse | **v6.6.0** | auto-update off; config backup at `/root/pulse-pre-6.6.0.tar.gz`; upgrade = re-run `install.sh --version <tag>` |
| 150 `ciri` | Ubuntu | 26.04.1 LTS | kernel **7.0.0-42-generic**; 2 pending, both `software-properties`, held back by apt |
| 150 `ciri` | Docker Engine | **29.9.2** | |
| 150 `ciri` | Docker Compose | **v5.6.1** | |
| 150 `ciri` | nvidia-container-toolkit | **1.20.1** | |
| 150 `ciri` | nvidia-driver-580-server | **580.178.04** | DKMS (`nvidia-srv`), built for 7.0.0-34, -38 and -42 ([gpu-passthrough.md](gpu-passthrough.md)) |
| 150 `ciri` | `/data` disk (scsi1) | **128 G** | grown from 64 G on 2026-08-24 (`qm resize` + online `resize2fs`, no downtime); **32 G free** on 2026-11-02, after the pass |

## Container images (verified against live compose files 2026-11-01)

| Stack | Service | Current | Previous (rollback) | Tier |
|---|---|---|---|---|
| homepage | homepage | `ghcr.io/gethomepage/homepage:v2.7.0` | `ghcr.io/gethomepage/homepage:v2.2.0` | 1 |
| homepage | olivetin | `kaermorhen/olivetin:3000.21.0` (local build from `jamesread/olivetin:3000.21.0`) | `kaermorhen/olivetin:3000.19.0` | 1 |
| homepage | socket-proxy | `lscr.io/linuxserver/socket-proxy:3.4.7` | `lscr.io/linuxserver/socket-proxy:3.4.4` | 0 |
| homepage | results | `joseluisq/static-web-server:2.44.1` | `joseluisq/static-web-server:2.44.0` | 0 |
| ai | ollama | `ollama/ollama:0.40.13` | `ollama/ollama:0.32.15` | 1 |
| ai | open-webui | `ghcr.io/open-webui/open-webui:v0.12.5` | `ghcr.io/open-webui/open-webui:v0.11.0` + data tarball in `/data/backups/` | 1 |
| ai | searxng | `searxng/searxng:2026.11.1-9ded3bec1` | `searxng/searxng:2026.8.22-9fea41204` | 0 |
| immich | server | `ghcr.io/immich-app/immich-server:v3.3.5` | `ghcr.io/immich-app/immich-server:v3.1.0` + DB dump in `/data/backups/` | 2 |
| immich | machine-learning | `ghcr.io/immich-app/immich-machine-learning:v3.3.5` | `ghcr.io/immich-app/immich-machine-learning:v3.1.0` | 2 |
| immich | database | `ghcr.io/immich-app/postgres:14-vectorchord0.4.3-pgvectors0.2.0` | — | 3 |
| immich | redis | `valkey/valkey:9.1.1` | — | 3 |
| jellyfin | jellyfin | `jellyfin/jellyfin:12.4` | `jellyfin/jellyfin:10.11.11` ⚠️ **tag alone is not a rollback: restore the config tarball in `/data/backups/`** | 2 |
| memos | memos | `neosmemo/memos:26.11.0` | `neosmemo/memos:0.30.0` + data tarball in `/data/backups/` | 1 |
| nebula-sync | nebula-sync | `ghcr.io/lovelaze/nebula-sync:v0.11.3` | `ghcr.io/lovelaze/nebula-sync:v0.11.2` | 0 |
| obsidian-sync | couchdb | `couchdb:3.5.3` | `couchdb:3.5.2.1` | 1 |
| paperless | webserver | `ghcr.io/paperless-ngx/paperless-ngx:3.4.1` | `ghcr.io/paperless-ngx/paperless-ngx:3.0.5` + DB dump in `/data/backups/` | 2 |
| paperless | db | `postgres:16` ⚠️ **floating** — now **16.15** | `rollback/paperless-postgres:16.14` | 3 |
| paperless | broker | `redis:7.4-alpine` ⚠️ **floating** — now **7.4.11** | `rollback/paperless-redis:7.4.9` | 3 |
| paperless | backup | `prodrigestivill/postgres-backup-local:16` | — | 3 |
| servarr | gluetun | `qmcgaw/gluetun:v3.41.3` | `qmcgaw/gluetun:v3.41.1` | 2 |
| servarr | qbittorrent | `lscr.io/linuxserver/qbittorrent:version-5.3.0_v2.1.2` | `lscr.io/linuxserver/qbittorrent:version-5.2.3_v2.0.14` + config tarball in `/data/backups/` | 2 |
| servarr | qbit-port-sync | `alpine:3.21` | — | 0 |
| servarr | prowlarr | `lscr.io/linuxserver/prowlarr:version-2.7.0.5723` | `lscr.io/linuxserver/prowlarr:version-2.5.2.5491` | 1 |
| servarr | sonarr | `lscr.io/linuxserver/sonarr:version-4.0.20.3014` | `lscr.io/linuxserver/sonarr:version-4.0.19.2979` | 2 |
| servarr | radarr | `lscr.io/linuxserver/radarr:version-6.4.4.10685` | `lscr.io/linuxserver/radarr:version-6.3.0.10514` | 2 |
| servarr | flaresolverr | `ghcr.io/flaresolverr/flaresolverr:v3.5.2` | `ghcr.io/flaresolverr/flaresolverr:v3.5.0` | 0 |
| servarr | bazarr | `lscr.io/linuxserver/bazarr:version-v1.6.2` | `lscr.io/linuxserver/bazarr:version-v1.6.0` | 1 |
| servarr | seerr | `ghcr.io/seerr-team/seerr:v3.5.1` | `ghcr.io/seerr-team/seerr:v3.4.1` + config tarball in `/data/backups/` | 1 |
| shrink | stirling | `docker.io/stirlingtools/stirling-pdf:3.2.2` | `docker.io/stirlingtools/stirling-pdf:2.14.3` + config tarball in `/data/backups/` | 1 |
| shrink | mazanoke | `ghcr.io/civilblur/mazanoke:v1.1.7` | `ghcr.io/civilblur/mazanoke:v1.1.6` | 0 |
| n8n | n8n | `docker.io/n8nio/n8n:2.45.7` | `docker.io/n8nio/n8n:2.37.10` + data tarball in `/data/backups/` | 2 |
| sure | web / worker | `ghcr.io/we-promise/sure:0.7.6` | `ghcr.io/we-promise/sure:0.7.3` + DB dump in `/data/backups/` | 2 |
| sure | db | `postgres:16` ⚠️ **floating** — now **16.15** | — | 3 |
| sure | redis | `redis:7.4-alpine` ⚠️ **floating** — now **7.4.11** | — | 3 |
| sure | backup | `prodrigestivill/postgres-backup-local:16` | — | 3 |
| vaultwarden | vaultwarden | `vaultwarden/server:1.37.4` | — | 2 |
| manga | manga-gluetun | `qmcgaw/gluetun:v3.41.3` | — | 2 |
| manga | suwayomi | `ghcr.io/suwayomi/suwayomi-server:v2.4.2366` | `ghcr.io/suwayomi/suwayomi-server:v2.3.2243` | 1 |
| manga | manga-flaresolverr | `ghcr.io/flaresolverr/flaresolverr:v3.5.2` | `ghcr.io/flaresolverr/flaresolverr:v3.5.0` | 0 |
| manga | komga | `gotson/komga:1.29.2` | `gotson/komga:1.27.0` | 1 |
| books | kavita | `lscr.io/linuxserver/kavita:version-v0.9.1.4` | — | 1 |

⚠️ **Floating tags violate the pinning policy** — an incident cannot answer
"what changed?" and a rollback has no version to name. `sure:stable` and
`valkey:9` were pinned 2026-08-23. The remaining four are the shared
`postgres:16` / `redis:7.4-alpine` pairs, deferred as tier 3.

**They drifted once already, and it was caught by the inventory.** Pinning `sure`
pulled newer builds of both shared images and moved the tags, leaving
`paperless-db` (16.14) and `paperless-redis` (7.4.9) on *untagged* images —
visible as bare image IDs in `docker ps` — while `sure-db` and `sure-redis`
moved ahead. Resolved 2026-08-24 by recreating paperless's pair onto the current
tagged builds, so both stacks now run **16.15 / 7.4.11** and every container
references a real tag again. The old images were retagged under `rollback/`
first, because an untagged image in use is one `docker image prune` away from
being unrecoverable.

That the fix was needed at all is the argument for pinning these four.

## Held back after the 2026-11-02 pass

| Service | Running | Available | Why |
|---|---|---|---|
| n8n | 2.45.7 | 3.0.1 | Pre-release; stable releases only |
| valkey (immich) | 9.1.1 | 9.1.3 | Tier 3 |
| postgres, redis | floating `16`, `7.4-alpine` | 16.15 is current for 16; redis 7.4.12 | Tier 3, shared between stacks |
| alpine (`qbit-port-sync`) | `3.21` | 3.21.9 | Pulling it strands the running sidecar |
| Tizen client | built 2026-07-20 | not checked | Works on 12.4, so no rebuild is needed yet |

## Open items

- **Kernel `7.0.14-26-pve` is under suspicion on both nodes (2026-11-06).** Within
  four days of it, yennefer's boot SSD dropped out twice and geralt hard-froze. Neither
  had happened on `7.0.14-12` (70 clean days on both). **Pinned `7.0.14-12-pve` on
  both 2026-11-06** (§ Rollback), verified live: running kernel, pin snippet and GRUB
  default all on `-12`, invariants pass. **Test runs until ~2026-11-20; no kernel change
  before then.** If yennefer's SSD drops on `-12`, replace the drive. If both stay
  clean, skip `-26` and decide on `7.0.14-28` (already pending in apt) before
  unpinning. `apt full-upgrade` during the test is safe: the pin keeps `-12` booting. Records: [storage.md](storage.md) § Incident 2026-11-06,
  [geralt-hard-freeze.md](geralt-hard-freeze.md).
- **n8n stays on 2.x until 3.x is stable.** 3.0.0 and 3.0.1 are pre-releases
  (decided 2026-11-02: stable releases only), and n8n's blog gives early December
  for stable 3.x. Before moving, run Settings › Migration Report, available from
  2.39, and review [the breaking changes](https://docs.n8n.io/changelog/v30-breaking-changes).
- **Ollama `qwen3:8b` no longer fits the GPU.** Since 0.40.13 it loads at 6.0 GB
  and splits 14% CPU / 86% GPU, where `configs/ciri/ai/README.md` says 100% GPU.
  The first things to try are a lower `OLLAMA_CONTEXT_LENGTH` or `qwen3:4b`.
  Also check that `OLLAMA_KV_CACHE_TYPE` still applies to the new engine.
- **Upgraded Ollama models keep a backup copy** on `/mnt/ai-models`. Watch that
  disk as models get used; the 0.40.2 notes describe how to remove them.
- **The Samsung Tizen client still runs the 2026-07-20 build.** It plays on 12.4
  with no rebuild, so refreshing it is optional. Upstream has one open 12.0 issue
  about photos failing to open full screen.
- **Remove Sure's inert initializer** once 0.7.3 stops being the rollback.
- **Pulse's monitoring token holds two privileges wider than read-only**
  (deferred 2026-09-07, [proposal 008](proposals/008-lab-dashboard.md)). Its
  setup script created `pulse-monitor@pve` with `PVEDatastoreAdmin` on
  `/storage` — which can *allocate and delete* storage content, backups
  included — and `VM.GuestAgent.FileRead`, which reads files inside any guest
  running the agent. Both are the installer's defaults and both are live on
  geralt and yennefer today. To narrow them, drop the two grants and re-verify
  that Pulse's Backups tab and per-guest disk figures still populate
  (`Datastore.Audit` may be enough, possibly with
  `Datastore.AllocateSpace`); PBS's own token is already `Audit`-only and needs
  nothing. Nothing about the dashboard depends on the wider rights, so this is
  a tightening exercise, not a fix.
- **Kuma `resend_interval = 0` on ~29 monitors — status unverified.** The D6
  result says it was 30 minutes by 2026-08-24, while this list and proposal 006
  §8 still call it open. Check it in the Kuma UI and delete this item if done.
  It matters: `0` notifies once, then never again, and caused a 12-day silent
  outage.
- **Pin `postgres:16` and `redis:7.4-alpine`** — the last four floating tags,
  now demonstrably drifting between stacks (see the registry note).
- **Remove the pre-upgrade backups from the 2026-11-02 pass** once it is signed
  off. They are the rollbacks until then, so keep them through a few weeks of real
  use. Check each path before deleting it:
  - ciri, `/data/backups/`: every `*2026-11-02*` file (seerr, open-webui, stirling,
    memos ×2, immich, paperless, n8n, sure, qbittorrent, jellyfin). The Jellyfin
    tarball is the only way back from 12.x, so it goes last.
  - LXC 202: `/root/caddy-2.11.4-cloudflare`
  - LXC 204: `/root/beszel-pre-0.21.1.tar.gz`
  - LXC 205: `/root/pulse-pre-6.6.0.tar.gz`
  - ciri, `/etc/nvidia-container-toolkit/nvidia-cdi-refresh.env.dpkg-old`
  - ciri, the old images: remove by explicit name, as in
    [Releasing rollbacks](#releasing-rollbacks-image-pruning).
- **A pre-major `pg_dump` was planned and not taken** (paperless v3). The PBS
  snapshot happened to cover it. Add "verify the artifact exists with `ls -lh`"
  to the pre-flight for any future one-way migration.
- **`/mnt/torrents` is 100 G committed against ~32 M used** — thin, so it costs
  nothing today, but it is the first place to reclaim under pool pressure.
- **A LAN apt cache** — deferred by decision. geralt's D7 download phase ran at
  ~130 kB/s; every future pass pays that until the cache exists.
- **Node version divergence was unexplained** (geralt 9.2.4 vs yennefer 9.2.11).
  This registry exists so it cannot recur silently.
- **No host-level backup exists** — the one rollback path the lab does not have.
