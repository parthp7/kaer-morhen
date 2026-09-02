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
| Container nameserver | `1.1.1.1` — deliberate: the monitor must not depend on the Pi-holes it watches. **Consequence:** it cannot resolve `*.kaermorhen.fyi`, which lives only in Pi-hole — those monitors need an `/etc/hosts` entry, see gotchas |
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
- **Gotcha — "Resend Notification if Down X times" defaults to `0`**, i.e.
  *notify once on the down transition, then never again*, and **every monitor
  here is still on that default except `media-export` and `media-mount`**, which
  were set to 30 on 2026-08-23; the remaining ~30 are batched with the timer work
  below. (The exact total drifts — the table above is not exhaustive, and 003
  added two more on 2026-08-23 — so treat "all but those two" as the figure, not
  a count.) It cost the lab a **12-day** media outage on
  2026-08-10: the push monitor detected the fault in 10 s, Kuma fired exactly one
  ntfy at 00:16 AM, and nothing ever repeated it
  ([storage.md](storage.md#incident-2026-08-10--22--usb-link-fault-12-day-silent-outage)).
  A single midnight buzz is not an alerting strategy — an alert has to survive
  being ignored once. Setting it to a 30–60 min equivalent across all monitors is
  **still the highest-value change in the lab**, and remains mostly undone —
  originally [proposal 004 §5](proposals/004-media-mount-self-healing.md#5-companion-fix-make-the-alert-survive-being-ignored),
  carried forward unchanged into
  [proposal 005 §8](proposals/005-nfs-media-share.md). Note that self-healing does
  **not** replace it: autoheal shrinks the outages it can repair to seconds, but
  the class it cannot repair — the disk that does not come back — still depends
  entirely on a notification reaching a human.

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
| seerr | HTTP-Keyword | `http://<LAN_PREFIX>.150:5055/api/v1/status` → `version` | servarr (requests); renamed from `jellyseerr` 2026-08-24 — URL and keyword unchanged, the label is cosmetic |
| qbittorrent | HTTP | `http://<LAN_PREFIX>.150:8080/` | servarr; **doubles as gluetun liveness** — the port is published through gluetun, so it reddens if the VPN container dies |
| flaresolverr | HTTP-Keyword | `http://<LAN_PREFIX>.150:8191/` → `FlareSolverr is ready` | servarr (Cloudflare solver) |
| photos-backup | **Push** (86400 s → **90000 s**) | fed by `restic-photos.sh` on geralt, daily 05:00 IST | dead-man switch for the nightly restic backup ([backups](../scripts/backup/README.md)); silent from 2026-07-16, fixed 2026-07-30 — see below |
| ciri media mount | **Push** (360 s) | fed by `media-mount-health.sh` on ciri | **functional, not liveness** — added 2026-07-29; became an **NFS** probe 2026-08-23, see below |
| media-export geralt | **Push** (60 s) | fed by `media-export-health.sh` on geralt | **functional, not liveness** — added 2026-08-23; the *server-side* half of the media path, see below |
| servarr vpn health | **Push** (360 s) | fed by `servarr-vpn-health.sh` on ciri | **functional, not liveness** — added 2026-07-29; leak = hard alert, PF=0 = soft, see below |
| ciri gpu health | **Push** (360 s) | fed by `gpu-health.sh` on ciri | **functional, not liveness** — deployed 2026-08-05; runs a real NVENC encode inside the jellyfin container, see below |
| proxy-caddy | Ping | `<LAN_PREFIX>.202` | reverse proxy liveness — added 2026-08-23 ([proposal 003](proposals/003-reverse-proxy.md)) |
| proxy-tls | HTTPS | `https://memos.kaermorhen.fyi` | proxy **plus** certificate expiry (expiry notification on, TLS errors not ignored). Backend up + proxy-tls down isolates the fault to the proxy. Needs a static `/etc/hosts` entry on 104 — see gotchas |
| pdf-stirling | HTTP | `http://<LAN_PREFIX>.150:8081` | Stirling-PDF, added 2026-09-02 ([shrink](../configs/ciri/shrink/README.md)). Green on a **plain** monitor despite login being on: Spring answers a browser `Accept` with 302 → `/login` → 200, and only `Accept: */*` gets a bare 401 |
| image-mazanoke | HTTP + Basic Auth | `http://<LAN_PREFIX>.150:3474` | Mazanoke, added 2026-09-02. **Needs Kuma's HTTP Basic Auth**: nginx answers every HTML path with 401 regardless of `Accept`, so a plain monitor reports a healthy service down. See below |

servarr monitors added 2026-07-26. The `/ping` endpoints answer 200 without auth (cleanest
liveness). `gluetun` and `qbit-port-sync` have no LAN HTTP endpoint — covered by Beszel's
per-container view (and gluetun indirectly by the qbittorrent monitor). Note these are
liveness only: **they cannot see a VPN leak or port-forwarding degraded to 0** — see Next steps.

Shrink monitors added 2026-09-02 ([proposal 009](proposals/009-document-shrinker.md)).
Both services require a login, and the two behaved differently, which is worth
knowing before adding any monitor to an authenticated app:

- **Stirling passes a plain HTTP monitor.** Spring Security content-negotiates
  its rejection: an API-style `Accept: */*` gets a bare **401**, while a
  browser-style `Accept: text/html` gets a **302** to `/login`, which renders
  200. Kuma sends browser-ish headers and follows the redirect, so the monitor
  is green *and* is genuinely proving the app renders a page. A `curl -I` by
  hand returns 401 and looks alarming; it is not.
- **Mazanoke does not.** Its nginx basic auth answers **401** to every HTML
  path regardless of `Accept`, so a default monitor calls a healthy service
  down. Fixed by setting the monitor's authentication method to **HTTP Basic
  Auth** with the stack's credentials, which also proves the real page is
  served. Two alternatives were rejected: adding `401` to the accepted status
  codes (keeps credentials out of Kuma, but then a broken bundle behind a
  working nginx still reads green), and pointing at `/manifest.json`, which is
  one of the few paths that answers 200 unauthenticated but is undocumented
  and could vanish in a version bump.

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
| Green when | `/mnt/media` is a real **`nfs4`** mount (**virtiofs** until 2026-08-23) **and** `library/` exists **and** the fs is **≥ 800 GiB** **and** `.mount-health` reads back as bytes |
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

**Refinement 2026-08-23 — widening the window treated the symptom.** The
diagnosis above is right, but 360 s / retries 1 only buys 60 s of slack against a
producer that drifts *without bound*, and it costs a minute of detection latency.
The actual fix is on the producer: use **`OnCalendar=`** (absolute wall-clock, so
error cannot accumulate) plus **`AccuracySec=1s`** (systemd's default of 1 min is
pure additive lateness), and push at roughly **half** the Kuma interval so one
dropped push cannot trip anything. Measured on `media-export-health` before and
after: `OnUnitActiveSec=60` + default accuracy gave **61 / 72 / 75 / 90 s**
against a 60 s window — every beat late; `OnCalendar=*:*:0/30` + `AccuracySec=1s`
gives **30.0 s with no drift**, beats landing on exact `:00`/`:30` boundaries, and
1133 consecutive beats overnight with zero misses. **ciri's three producers
(`media-mount-health`, `gpu-health`, `servarr-vpn-health`) still have the old
defect** — all `AccuracySec=30s`, measured at ~330 s against a nominal 300 s —
and are queued for the same treatment.

### The media-export Push monitor (added 2026-08-23) — the server-side half

`media-mount-health` on ciri sees the **end-to-end** truth but cannot say *where*
a fault is, and it goes silent entirely if ciri itself is down. This is the other
half, on geralt.

| | |
|---|---|
| Type | Push, heartbeat **60 s**, retries **2**, `resend_interval` **30** |
| Fed by | `scripts/monitoring/media-export-health.sh` on geralt, `OnCalendar=*:*:0/30` |
| Push URL | `/etc/kuma-push.media-export` on geralt (0600) + `secrets.local.yaml` |
| Green when | `/mnt/media` is an `ext4` mount **and** `library/` enumerates **and** `.mount-health` reads back **and** `nfs-server` is active **and** the export is listed **and** nfsd is listening on the storage IP |
| Red when | any of those fails, or the heartbeat stops |

The pairing is the point: on 2026-08-23 the two monitors disagreed usefully —
geralt reported `FAIL — /mnt/media is not a mount point` for exactly one beat
during the repair window and recovered, while ciri's monitor showed the
client-visible `Input/output error`. A single end-to-end monitor could not have
told those apart.

**Two deployment traps, both of which produce a monitor that lies rather than one
that errors:**

- **Address Kuma by IP, never by name.** geralt resolves via the router and
  cannot resolve `kaermorhen.internal` *or* the public domain — those records
  live only in the Pi-holes. `push()` deliberately swallows curl failures so a
  dead Kuma cannot corrupt the check's verdict, so a name-based URL fails
  *silently, forever*. This is the same fault that made `photos-backup` silent
  for 14 days (below); it cost nothing the second time only because it was
  caught during deployment.
- **Store the bare base URL, with no query string.** The script appends its own
  `status=`/`msg=` via `curl --get --data-urlencode`. A URL copied from Kuma's UI
  ends in `?status=up&msg=OK&ping=`; curl would append after it, leaving two
  `status` parameters — and Kuma reads the **first**. The monitor would report
  `up` forever regardless of what the check found: a dead-man switch welded shut,
  strictly worse than having no monitor at all.

Full deploy steps in
[scripts/monitoring/README.md](../scripts/monitoring/README.md#media-export-healthsh).

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
| **Hard** | `tun0` missing from gluetun's netns | kill-switch failed open (vendor-neutral; replaced a provider check that false-alarmed — see below) |
| **Hard** | no egress at all from the netns | tunnel down / kill-switch shut — torrenting stopped |
| **Hard** | gluetun control server unreachable | can't verify anything |
| **Hard** | qBittorrent API unreachable | dead client behind a live tunnel |
| **Soft** (green, reason logged) | forwarded port == 0 | Proton drops PF server-side intermittently; qbit-port-sync keeps the last good port so torrenting continues |
| **Soft** | forwarded port != qBit's `listen_port` | the sidecar polls every 30 s; a brief mismatch after a rotation is normal |
| **Soft** | egress comparison unverifiable | ciri's public-IP lookup failed *and* no cached value — an ipify outage must not fake a leak |

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

**Proven end-to-end on day one (2026-07-29).** At deploy, Proton's forwarded port
was already **0**, with qBit holding its last good port `34936` — so the soft path
was live and correct immediately, which is exactly the case that would have been
pure noise without the strike counter. It stayed 0 for ~90 minutes, the strikes
climbed 1→6, and at **23:02:56** the monitor escalated to a hard failure and fired
ntfy. Restarting `gluetun qbittorrent qbit-port-sync` (all three — restarting
gluetun alone strands qBit in a stale netns, see the
[servarr README](../configs/ciri/servarr/README.md)) got port `64991`,
`qbit-port-sync` applied it, and the monitor returned to `ok` at 23:08:25. The
whole soft→hard→recover cycle ran in production, not just in the
`MAX_STRIKES=1` simulation.

**The provider check was removed within a day — it raised a false leak alert.**
The monitor originally hard-failed unless the exit IP's `organization` contained
`proton`. Three exits were observed within 24 hours:

```
AS208172  Proton AG                   matched
AS199218  Proton AG                   matched
AS43350   NForce Entertainment B.V.   FALSE LEAK ALERT ×4
                                      2026-07-29 23:45 → 2026-07-30 00:01
```

The alert was false: egress was `185.107.44.113` (Breda, NL) while ciri's own
public IP was unchanged and `tun0` was up at `10.2.0.2/32` — traffic was going
through the tunnel exactly as intended, from a Proton server on rented address
space. The fix was verified on **that same exit IP** at 2026-07-30 00:07:08,
which now reads `ok: egress 185.107.44.113 (AS43350 NForce Entertainment B.V.),
port-forward 46247 matches qBit, no leak` — same address, same org, correct
verdict.

All three are the same VPN. **Proton rents capacity and does not own all the IP
space it exits from**, so blocks stay registered to the upstream datacenter. The
first version of this doc argued the substring match was the careful choice
because ASN-pinning would cry wolf — that reasoning was right about ASNs and
wrong about its own fix: the org string is no more stable than the ASN, and
pinning either just relocates the whack-a-mole to a less obvious place.

What replaced it:

- **The leak test is now only `egress != ciri's own public IP`** — the actual
  definition of the failure. It needs no allowlist and cannot go stale.
- **A tunnel-interface check** (`tun0` present in gluetun's netns) covers the case
  the org check was reaching for — a kill-switch that has failed open — without
  depending on any vendor string.
- **The exit's org is still reported** in the heartbeat message, for human
  context. It never decides the verdict.
- **An unverifiable comparison is now soft, not hard.** If ciri's public-IP lookup
  fails the script falls back to a cached value, and only degrades (escalating via
  the strike counter) when there is no cache either — so an `api.ipify.org` outage
  cannot fake a leak, while a persistent inability to verify still pages.

The general lesson, worth carrying to any future egress check: **assert the
invariant, not the vendor.** "Traffic must not exit from my own address" is
permanent; "the exit must belong to company X" is a fact about a business
relationship that changes without warning.

### The gpu-health Push monitor (added 2026-08-02) — the blind spot, third time

On 2026-08-01 the jellyfin container lost its cgroup device access to the GTX
1060 while still running. Every transcode died instantly at
`cuInit(0) -> CUDA_ERROR_NO_DEVICE`, and it ran **~21 hours undetected**
([jellyfin README](../configs/ciri/jellyfin/README.md#all-transcodes-fail-after-a-systemd-daemon-reload-2026-08-01)).

This is the same lesson as the two monitors above, and it is worth naming that
it has now recurred three times in three different guises:

| Incident | Everything said | Actually broken |
|---|---|---|
| 2026-07-27 media mount | all 18 monitors green, 16 h | serving the wrong filesystem |
| (hypothetical) VPN leak | 7 servarr monitors green | egress bypassing the tunnel |
| 2026-08-01 GPU loss | jellyfin `:8096` green, 21 h | container could not encode |

The GPU case had an extra trap: **Beszel's GPU panel was healthy the whole
time**, because it watches the card from the *host*. The host was genuinely
fine. Only the container had lost access — and Direct Play kept working, so
most playback was normal and nothing looked wrong.

**The check is an encode, not a `nvidia-smi`.** `nvidia-smi` proves NVML is
reachable; it does not prove the *encoder* is usable, and those can disagree —
a container missing `video` in `NVIDIA_DRIVER_CAPABILITIES` runs `nvidia-smi`
happily with NVENC invisible. So the monitor runs a real one-second
`h264_nvenc` encode using Jellyfin's own ffmpeg inside the container, to the
null muxer. Same discipline as the VPN monitor making a real outbound request
from inside the netns rather than asking "is gluetun running".

| Field | Value |
|---|---|
| Type | Push, heartbeat **360 s**, retries **1** |
| Fed by | `scripts/monitoring/gpu-health.sh` on ciri, systemd timer every 5 min |
| Push URL | `/etc/kuma-push.gpu-health` on ciri (0600) + `secrets.local.yaml` |
| Green when | jellyfin runs, `nvidia-smi` works inside it, `h264_nvenc` is present, and a test encode succeeds |
| Soft (green, strike-counted) | test encode fails with ≥ 3000 MiB VRAM in use — a resident Ollama model on the shared card; escalates after 6 runs (~30 min) |
| Red when | any hard check fails, the encode fails with the card **idle**, or the heartbeat stops |

The soft path exists because the 1060 is shared with the `ai` stack, and it
encodes the same distinction as the jellyfin README's
[contention-vs-device-loss table](../configs/ciri/jellyfin/README.md#is-it-the-daemon-reload-or-vram-contention-with-ollama):
contention fails *after* CUDA initialises and only while a model is loaded;
lost device access fails before any allocation, with the card idle. Fail-closed
throughout — if VRAM usage cannot be read, an encode failure is hard, never
excused.

Deploy steps, unit, timer, and how to force both the hard and soft paths are in
[scripts/monitoring/README.md](../scripts/monitoring/README.md#gpu-healthsh).

**Deployed and verified 2026-08-05**: timer enabled and active, drop-in applied
(`TimeoutStartUSec=1min 30s`), strike counter at `0`, every run reporting
`ok: 'jellyfin' encoded on the GPU (h264_nvenc)`, no push failures, monitor
green. Measured timer period **323 s** against the 360 s heartbeat. Full
as-built table in the script README.

**The smoke test failed on first deploy, and the monitor was wrong — not the
GPU.** The encoder check was `… -encoders | grep -q h264_nvenc` under
`set -o pipefail`: `grep -q` exits at the first match and closes the pipe,
ffmpeg takes SIGPIPE with most of its 227-line listing still to write, and
pipefail reports the pipeline as failed. Measured exit 141 with pipefail, 0
without, encoder present throughout. Fixed by capturing the output and matching
in-shell. **Every script in this lab runs `set -euo pipefail`, so this is a
general trap** — the rule and the audit of the one sibling instance are in
[scripts/monitoring/README.md](../scripts/monitoring/README.md#set--o-pipefail--grep--q--false-failure-fixed-2026-08-05).

Worth noting what this near-miss would have cost: a monitor that hard-fails on a
healthy system is not a harmless bug. Left undiagnosed it would have paged
nightly, trained everyone to ignore the GPU alert, and made the *real* fault it
exists to catch invisible again — the alert-fatigue path back to a 21-hour
outage.

### The photos-backup Push monitor — silent for 14 days (fixed 2026-07-30)

Configured 2026-07-16 with the restic job and **never received a single push**.
Kuma's own record is unambiguous — monitor 14, entire history to 2026-07-30:

| status | beats | window |
|---|---|---|
| 0 (down) | 11 | 2026-07-16 → 2026-07-26, all `No heartbeat in the time window` |
| 2 (pending) | 2 | 2026-07-16, at creation |
| **1 (up)** | **0** | — |

The backups ran correctly every night the whole time; only the heartbeat was
lost. `KUMA_PUSH_URL` on geralt pointed at
`http://uptime-kuma.kaermorhen.internal:3001/…`, and **geralt cannot resolve
that name** — the Proxmox nodes resolve via the router by design
([dns.md](dns.md)), while `kaermorhen.internal` records exist only in the
Pi-holes:

| Resolver | `uptime-kuma.kaermorhen.internal` |
|---|---|
| `<LAN_PREFIX>.1` (router — what geralt uses) | timed out / NXDOMAIN |
| `<LAN_PREFIX>.101`, `<LAN_PREFIX>.201` (Pi-holes) | `<LAN_PREFIX>.104` |

Fixed by addressing Kuma by IP, the form both ciri producers already used. Full
write-up in [scripts/backup/README.md](../scripts/backup/README.md).

**Two lessons that generalise past this monitor:**

- **A push URL must be resolvable from the host that sends it.** Name resolution
  is not uniform across this lab — it is deliberately different on the Proxmox
  nodes than on every guest. A URL that works from a laptop proves nothing about
  the host running the job. Prefer the IP for push URLs; there is no
  ad-blocking or failover benefit to a name here, only a dependency.
- **A dead-man switch that fails dead is indistinguishable from health.** The
  monitor alerted once, on the day it was created, and then went quiet forever
  (`resend_interval=0`). Two weeks of silence read exactly like two weeks of
  working backups. Any new push producer should be verified by watching the
  monitor turn **green** once — a monitor that has never been green has not
  been tested, it has only been created.

Its interval was also **86400 s, exactly the producer's nominal period** — the
same mistake as the two monitors above, caught here before it bit: the gap
between consecutive pushes is 24 h ± the backup's duration, currently ~25 s but
growing with the library. Raised to **90000 s** (25 h).

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
