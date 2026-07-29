# Uptime-Kuma — service-level checks

As-built runbook, implemented 2026-07-11; renumbered 2026-07-13
(103 → **104**, see the dated section below).
Service-level "is it answering"
monitoring (DNS, HTTP, ping) complementing Beszel's host-level metrics view —
see [monitoring.md](monitoring.md) and [Proposal 001 §4](proposals/001-initial-infrastructure-plan.md).

**Why it exists and why on geralt**: the Beszel hub lives on yennefer and
cannot alert its own host's death. Uptime-Kuma on geralt watches yennefer's
side (hub, PBS, Pi-hole #2), closing that blind spot; Beszel on yennefer
already covers geralt going down. The two watchers cover each other. Residual
gap: both nodes down *simultaneously* (power outage) alerts nothing — both
watchers are inside the house (see next steps).

## Architecture

| Piece | Value |
|---|---|
| Container | LXC **104** on **geralt**, `.104`, rootfs `silver-guests:8` |
| Profile | Debian 13, unprivileged, `nesting=1`, 1 core, **512 MiB RAM / 1024 MiB swap**, `onboot=1` |
| App | Uptime-Kuma **2.4.0**, non-Docker (git checkout + `npm run setup`), Node v20.19.2 (Debian's stock `nodejs`) |
| Service | `uptime-kuma.service` (plain systemd unit, runs as user `uptime-kuma`), UI `http://<LAN_PREFIX>.104:3001` |
| Admin account | `KUMA_ADMIN_USER` / `KUMA_ADMIN_PASSWORD` in `secrets.local.yaml` |
| Container nameserver | `1.1.1.1` — deliberate: the monitor must not depend on the Pi-holes it watches |
| Alerts | native ntfy provider → `https://ntfy.sh/<NTFY_TOPIC>` (same topic as everything else), default-enabled on all monitors |
| Data | SQLite under `/opt/uptime-kuma/data/` — travels with the container in PBS backups |
| Backups | covered by geralt's nightly 04:00 `--all 1` PBS job automatically |

**Memory sizing**: an LXC memory value is a cgroup *cap*, not a reservation —
the container only costs what it uses (~130 MiB at runtime), and the low cap
is a leash on the Node process, not a carve-out from geralt's RAM. The
one-time `npm run setup` spike is allowed to grind through swap instead
(LXC "swap" = the host's swap — confirm the host has some with
`swapon --show`; geralt has 8 G).

## Runbook (as executed)

### 1. Create the container (geralt)

```bash
pct create 104 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname uptime-kuma --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 1024 \
  --rootfs silver-guests:8 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.104/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

(Equivalent alternative: create with `--memory 1024` for a faster
`npm run setup`, then `pct set 104 --memory 512 --swap 1024` — applies live,
lands on the same config. As originally executed this was `pct create 103 …`;
command updated to what a rebuild should use — see the renumber section.)

### 2. Install (inside the container)

Non-Docker install per the [official wiki](https://github.com/louislam/uptime-kuma/wiki/%F0%9F%94%A7-How-to-Install):
needs Node ≥ 20.4, and Debian 13's stock package (20.19.x) satisfies it — no
NodeSource repo, no Docker-in-LXC.

```bash
pct enter 104
apt update && apt install -y git nodejs npm
node -v    # >= 20.4 required

useradd -r -m -d /opt/uptime-kuma-home -s /usr/sbin/nologin uptime-kuma
git clone https://github.com/louislam/uptime-kuma.git /opt/uptime-kuma
chown -R uptime-kuma: /opt/uptime-kuma
runuser -u uptime-kuma -- bash -c 'cd /opt/uptime-kuma && npm run setup'
```

`npm run setup` checks out the latest release tag and installs production
deps — several minutes on one core.

### 3. systemd unit (inside the container)

The wiki suggests pm2; a plain systemd unit does the same job with nothing
extra installed and matches how everything else here runs.

```bash
cat > /etc/systemd/system/uptime-kuma.service <<'EOF'
[Unit]
Description=Uptime Kuma
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=uptime-kuma
WorkingDirectory=/opt/uptime-kuma
ExecStart=/usr/bin/node server/server.js
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl enable --now uptime-kuma
```

### 4. Allow ping for the service user (inside the container)

Ping monitors shell out to `/usr/bin/ping` as `uptime-kuma`, which fails in an
unprivileged LXC out of the box (see gotchas). Allow unprivileged ICMP echo
sockets — per-network-namespace, so this touches nothing on the host:

```bash
echo "net.ipv4.ping_group_range = 0 65535" > /etc/sysctl.d/99-ping.conf
sysctl -p /etc/sysctl.d/99-ping.conf
runuser -u uptime-kuma -- ping -c1 <LAN_PREFIX>.22   # must succeed
```

### 5. UI setup — `http://<LAN_PREFIX>.104:3001`

- Create the admin account (→ `secrets.local.yaml`).
- **Settings → Notifications → ntfy**: server `https://ntfy.sh`, topic
  `<NTFY_TOPIC>`, "Default enabled" so every monitor inherits it. Test → phone.

### 6. Monitors

Weighted toward yennefer's side (the blind spot), 60 s default interval.
Full set as of 2026-07-13:

| Monitor | Type | Target | Note |
|---|---|---|---|
| pihole-1 DNS | DNS | `example.com` via `<LAN_PREFIX>.101` | the [dns.md](dns.md) "is 53 answering" check |
| pihole-2 DNS | DNS | `example.com` via `<LAN_PREFIX>.201` | ditto |
| beszel-hub | HTTP | `http://<LAN_PREFIX>.204:8090` | watches the watcher |
| PBS | HTTPS | `https://<LAN_PREFIX>.200:8007` | "Ignore TLS error" — self-signed cert |
| yennefer host | Ping | `<LAN_PREFIX>.22` | the blind spot this container exists for |
| router | Ping | `<LAN_PREFIX>.1` | distinguishes "node down" from "network down" |
| ciri | Ping | `<LAN_PREFIX>.150` | added 2026-07-11 with the docker VM ([docker-vm.md](docker-vm.md)) |
| tailscale-1 | Ping | `<LAN_PREFIX>.203` | LXC liveness only — the tailnet path isn't provable from inside ([tailscale.md](tailscale.md)) |
| tailscale-2 | Ping | `<LAN_PREFIX>.103` | ditto; the warm standby |
| memos | HTTP | `http://<LAN_PREFIX>.150:5230` | first app-level check — a dead container doesn't stop ciri answering pings |
| jellyfin | HTTP | `http://<LAN_PREFIX>.150:8096` | media server, added 2026-07-22 ([jellyfin](../configs/ciri/jellyfin/README.md)) |
| prowlarr | HTTP-Keyword | `http://<LAN_PREFIX>.150:9696/ping` → `OK` | servarr, added 2026-07-26 ([servarr](../configs/ciri/servarr/README.md)) |
| sonarr | HTTP-Keyword | `http://<LAN_PREFIX>.150:8989/ping` → `OK` | servarr (TV) |
| radarr | HTTP-Keyword | `http://<LAN_PREFIX>.150:7878/ping` → `OK` | servarr (Movies) |
| bazarr | HTTP-Keyword | `http://<LAN_PREFIX>.150:6767/` → `Bazarr` | servarr (subtitles) |
| jellyseerr | HTTP-Keyword | `http://<LAN_PREFIX>.150:5055/api/v1/status` → `version` | servarr (requests) |
| qbittorrent | HTTP | `http://<LAN_PREFIX>.150:8080/` | servarr; **doubles as gluetun liveness** — the port is published through gluetun, so it reddens if the VPN container dies |
| flaresolverr | HTTP-Keyword | `http://<LAN_PREFIX>.150:8191/` → `FlareSolverr is ready` | servarr (Cloudflare solver) |
| ciri media mount | **Push** (360 s) | fed by `media-mount-health.sh` on ciri | **functional, not liveness** — added 2026-07-29, see below |
| servarr vpn health | **Push** (360 s) | fed by `servarr-vpn-health.sh` on ciri | **functional, not liveness** — added 2026-07-29; leak = hard alert, PF=0 = soft, see below |

servarr monitors added 2026-07-26. The `/ping` endpoints answer 200 without auth (cleanest
liveness). `gluetun` and `qbit-port-sync` have no LAN HTTP endpoint — covered by Beszel's
per-container view (and gluetun indirectly by the qbittorrent monitor). Note these are
liveness only: **they cannot see a VPN leak or port-forwarding degraded to 0** — see Next steps.

### The media-mount Push monitor (added 2026-07-29) — and what it fixes

Every monitor above is a **liveness** check, and on 2026-07-27 that was proven
insufficient in the most expensive way available: all 18 stayed **green for ~16
hours** while the media stack ran against the wrong filesystem
([storage.md](storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem)).
Nothing was down. Jellyfin answered on `:8096`, all six servarr `/ping`
endpoints returned `OK`, Beszel showed every container healthy — while
qBittorrent had marked all 20 torrents `missingFiles` and Radarr had lost its
root folder, because virtiofsd was serving a 68 GB empty directory instead of
the 916 GB USB disk.

This monitor asks a question liveness cannot: **is the thing it answers about
the right thing?**

| Field | Value |
|---|---|
| Type | Push, heartbeat interval **360 s**, retries **1** — must exceed the 5 min timer's real period, see below |
| Fed by | `scripts/monitoring/media-mount-health.sh` on ciri, systemd timer every 5 min |
| Push URL | in `/etc/kuma-push.media-mount` on ciri (0600) + `secrets.local.yaml` — never in git |
| Green when | `/mnt/media` is a real **virtiofs** mount **and** `library/` exists **and** the fs is **≥ 800 GiB** |
| Red when | any check fails (explicit `status=down` with the reason) **or** the heartbeat stops |

The **size check is the load-bearing one**. Existence alone would not have caught
the incident: Docker's default `create_host_path` auto-created `downloads/` on
the placeholder, so the tree looked plausible. Only the 68 G vs 916 G difference
was unambiguous.

Two independent signals by design: an explicit `down` push gives a fast, labelled
alert; heartbeat silence covers the script or timer itself dying. Deploy steps,
unit and timer are in
[scripts/monitoring/README.md](../scripts/monitoring/README.md#media-mount-healthsh).

**Both Push monitors flapped red on first deploy (fixed 2026-07-29).** They were
set to a 300 s heartbeat to match the 300 s timer. A systemd timer's real period
is always longer than `OnUnitActiveSec`: `AccuracySec=30s` lets systemd defer the
trigger to batch it with other timers, and `OnUnitActiveSec` counts from the last
*activation*, so the run's own duration adds on top. Measured periods were 301–330 s
— every heartbeat arrived after a 300 s window had already closed, so Kuma went
red on every beat while the checks themselves were passing. **A push monitor's
heartbeat interval must exceed the producer's worst-case period, never equal its
nominal one.** Both are now 360 s / retries 1. The scripts also gained
`curl --retry 2` after a real dropped push at 22:21:43 — one lost push is one
missed heartbeat, and Kuma cannot tell that apart from the disk being gone.

### The servarr-vpn Push monitor (added 2026-07-29) — and what it actually proves

qBittorrent shares gluetun's network namespace, so gluetun's kill-switch is the
only thing standing between the torrent client and the home IP. That protection
is **invisible to every other monitor in this file**: if it stopped working, all
7 servarr HTTP monitors would stay green and the first symptom would arrive by
post. Same shape as the media-mount blind spot — liveness cannot see wrong
egress, only absent egress.

So the check does not ask "is gluetun running". It makes a **real outbound
request from inside the torrent netns** (`docker exec gluetun wget https://…`)
and compares where the internet says it came from against ciri's own public IP.
Running that probe on ciri instead of inside the namespace would measure ciri
and prove nothing — that distinction is the whole monitor.

**Two severities, deliberately:**

| | Condition | Why |
|---|---|---|
| **Hard** (red immediately) | egress IP == ciri's public IP | a leak; must never happen |
| **Hard** | egress IP not owned by Proton | tunnel up, wrong exit |
| **Hard** | no egress at all from the netns | tunnel down / kill-switch shut — torrenting stopped |
| **Hard** | gluetun control server unreachable | can't verify anything |
| **Hard** | qBittorrent API unreachable | dead client behind a live tunnel |
| **Soft** (green, reason logged) | forwarded port == 0 | Proton drops PF server-side intermittently; qbit-port-sync keeps the last good port so torrenting continues |
| **Soft** | forwarded port != qBit's `listen_port` | the sidecar polls every 30 s; a brief mismatch after a rotation is normal |

Soft conditions escalate to a hard alert after **6 consecutive runs** (~30 min at
the 300 s timer), counted in `/var/lib/servarr-vpn-health/degraded.strikes`. The
counter lives outside `/tmp` on purpose: a reboot must not reset a genuinely
stuck port back to zero strikes. A leak pages at once; a missing forwarded port
only means slower torrents, and only pages once it stops being transient.

**Fail-closed:** "cannot determine" is never treated as "fine". If ciri's public
IP lookup fails, the IP comparison is impossible and the verdict falls back to
the provider check; if that can't be made either, the run is a hard failure. The
one thing this monitor must never do is report green because a lookup broke.

**What it does not prove:** it samples egress every 300 s, so a leak lasting less
than one interval can slip through unseen. It is an assurance check, not a packet
filter — the kill-switch is still the actual protection, and this only tells you
whether the kill-switch is doing its job.

Note the state at first deploy (2026-07-29): PF was **0** with qBit holding its
last good port `34936` — i.e. the soft path was live and correct on day one,
which is exactly the case that would have been noisy without the strike counter.

Rule of thumb for future additions: **one ping per guest** (liveness) +
**one protocol-level check per user-facing service** (HTTP/DNS/HTTPS —
"answering" beats "alive"). Deliberate absences: geralt (owned by the
Beszel hub on yennefer — Kuma dies with geralt), Kuma itself (needs the
external dead-man heartbeat, see next steps), nebula-sync (no listening
port; an hourly batch job — its failure mode is Pi-hole drift, not an
endpoint).

**No geralt-host monitor** — Kuma runs on geralt and dies with it; that alert
is owned by the Beszel hub on yennefer.

## Renumber & rename 103 → 104 (as executed 2026-07-13)

Built as LXC **103** `uptime-kuma`; renumbered so the watcher pair mirrors
across nodes (Kuma **104** ↔ Beszel **204**, like the Pi-holes' 101/201),
freeing 103 for the Tailscale standby (↔ 203). (A same-day lore rename to
`philippa` was rolled back hours later — LXCs keep functional names,
[network.md](network.md).) PVE has no VMID rename — backup → restore *is*
the renumber, and doubles as a live PBS restore drill:

```bash
# geralt — fresh stopped-mode backup first: the only existing snapshot
# predated that morning's monitor changes
pct stop 103
vzdump 103 --storage pbs-vault --mode stopped

pvesm list pbs-vault --content backup | grep ct/103 | tail -1
pct restore 104 'pbs-vault:backup/ct/103/<TIMESTAMP>' --storage silver-guests
pct set 104 --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.104/24,gw=<LAN_PREFIX>.1
pct start 104
# verify (section below), then:
pct destroy 103
```

- Only the **LXC hostname** changed — the systemd unit, service user, and
  `/opt/uptime-kuma` path keep the app's name.
- `pct restore` carries the whole config (onboot, nesting, nameserver,
  swap); re-IP **before** first start. Replacing `--net0` regenerates the
  MAC — irrelevant with static IPs.
- PBS snapshot groups are per-VMID: history stays under `ct/103` (delete
  that group once confident); the nightly job starts a fresh `ct/104` chain
  automatically.
- Kuma down = no service-level alerting and nothing watching yennefer's
  side — keep the window short, don't overlap other maintenance.

## Gotchas hit (and the fixes)

- **Ping monitors fail: `ping: socktype: SOCK_RAW … missing cap_net_raw+p
  capability or setuid?`** On bare Debian, ping works for non-root via a file
  capability on the binary; in an unprivileged LXC that doesn't take, and raw
  sockets are denied. Fix: `net.ipv4.ping_group_range` (step 4) — it's
  namespaced, persists via `sysctl.d`, and unlike
  `setcap cap_net_raw+ep /usr/bin/ping` it survives iputils package upgrades.
- **`sysctl: setting key "net.ipv4.ping_group_range": Invalid argument`** when
  using the canonical `0 2147483647` found in every online guide. Both GIDs
  must be mappable inside the container's user namespace, which only maps
  0–65535 — use `0 65535` (equivalent in effect: every group that can exist in
  the container).
- **`git describe` as root fails: `detected dubious ownership in repository`**
  — the repo is owned by `uptime-kuma`; run git commands as that user
  (`runuser -u uptime-kuma -- git -C /opt/uptime-kuma …`).

## Updating

```bash
# inside the container
systemctl stop uptime-kuma
runuser -u uptime-kuma -- bash -c 'cd /opt/uptime-kuma && git fetch --all && npm run setup'
systemctl start uptime-kuma
```

(`npm run setup` checks out the latest release tag itself.) Updates happen
when we choose — nothing auto-updates, same policy as Beszel.

## Verification (read-only)

```bash
# geralt
pct status 104
pct config 104                                    # 512/1024, onboot, nameserver
pct exec 104 -- systemctl is-active uptime-kuma
curl -s -o /dev/null -w '%{http_code}\n' http://<LAN_PREFIX>.104:3001   # 302 → login
pct exec 104 -- sysctl net.ipv4.ping_group_range  # 0 65535
pct exec 104 -- runuser -u uptime-kuma -- ping -c1 <LAN_PREFIX>.22
pct exec 104 -- runuser -u uptime-kuma -- git -C /opt/uptime-kuma describe --tags
pct exec 104 -- free -m
```

Verified 2026-07-11: container running with the profile above, service
active, UI 302, v2.4.0 on Node 20.19.2, ping working as service user, all six
monitors green, ntfy test delivered to phone. Runtime footprint ~130 MiB, swap
untouched.

Outage drill 2026-07-13 (yennefer halted — [tailscale.md](tailscale.md)):
all five yennefer-side monitors (yennefer, pihole-2 DNS, beszel-hub, PBS,
tailscale-1) alerted via ntfy during the window and cleared on recovery —
the exact blind-spot coverage this container exists for, now proven live.

Renumber verified 2026-07-13: running as 104 on `.104` (restored
from the fresh PBS snapshot, config intact), UI answering 302, old 103
destroyed.

## Next steps (not yet built)

- **External dead-man heartbeat** (healthchecks.io-style): a Push monitor here
  can't do it — Kuma is inside the failure domain. Something *outside* the
  house must notice silence. Closes the "whole-house outage" gap.
- **Add monitors as services land**: docker VM 150 apps, HAOS, reverse proxy.
- ~~**Functional check that the media stack is pointed at the real disk**~~ done
  2026-07-29 — the `ciri media mount` Push monitor above, built after the
  2026-07-27 incident proved the liveness-only gap was not hypothetical.
- ~~**servarr VPN leak + port-forward health monitor**~~ done 2026-07-29 — the
  `servarr vpn health` Push monitor above, fed by
  [`servarr-vpn-health.sh`](../scripts/monitoring/servarr-vpn-health.sh). See
  the section below for what it does and does not prove.
- **Pi-hole node-reboot failover test** still pending ([dns.md](dns.md)) — the
  pihole DNS monitors here will provide the alerting evidence during it.
