# Uptime-Kuma — service-level checks

As-built runbook, implemented 2026-07-11; renumbered & renamed 2026-07-13
(103 `uptime-kuma` → **104 `philippa`**, see the dated section below).
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
| Container | LXC **104** on **geralt**, `.104`, hostname `philippa` (lore naming per [network.md](network.md) — the owl on night watch, rival-spymaster pair with `dijkstra`/Beszel on 204), rootfs `silver-guests:8` |
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
  --hostname philippa --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 1024 \
  --rootfs silver-guests:8 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.104/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

(Equivalent alternative: create with `--memory 1024` for a faster
`npm run setup`, then `pct set 104 --memory 512 --swap 1024` — applies live,
lands on the same config. As originally executed this was
`pct create 103 … --hostname uptime-kuma`; command updated to what a rebuild
should use — see the renumber section.)

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

Weighted toward yennefer's side (the blind spot), 60 s default interval:

| Monitor | Type | Target | Note |
|---|---|---|---|
| pihole-1 DNS | DNS | `example.com` via `<LAN_PREFIX>.101` | the [dns.md](dns.md) "is 53 answering" check |
| pihole-2 DNS | DNS | `example.com` via `<LAN_PREFIX>.201` | ditto |
| beszel-hub | HTTP | `http://<LAN_PREFIX>.204:8090` | watches the watcher |
| PBS | HTTPS | `https://<LAN_PREFIX>.200:8007` | "Ignore TLS error" — self-signed cert |
| yennefer host | Ping | `<LAN_PREFIX>.22` | the blind spot this container exists for |
| router | Ping | `<LAN_PREFIX>.1` | distinguishes "node down" from "network down" |

**No geralt-host monitor** — Kuma runs on geralt and dies with it; that alert
is owned by the Beszel hub on yennefer.

## Renumber & rename 103 → 104 (as executed 2026-07-13)

Built as LXC **103** `uptime-kuma`; renumbered so the watcher pair mirrors
across nodes (Kuma **104** ↔ Beszel **204**, like the Pi-holes' 101/201),
freeing 103 for the Tailscale twin `tor-zireael` (↔ `tor-lara` 203), and
renamed `philippa` under the lore-naming convention
([network.md](network.md)). PVE has no VMID rename — backup → restore *is*
the renumber, and doubles as a live PBS restore drill:

```bash
# geralt — fresh stopped-mode backup first: the only existing snapshot
# predated that morning's monitor changes
pct stop 103
vzdump 103 --storage pbs-vault --mode stopped

pvesm list pbs-vault --content backup | grep ct/103 | tail -1
pct restore 104 'pbs-vault:backup/ct/103/<TIMESTAMP>' --storage silver-guests
pct set 104 --hostname philippa \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.104/24,gw=<LAN_PREFIX>.1
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
pct config 104                                    # 512/1024, onboot, nameserver, hostname philippa
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

Renumber verified 2026-07-13: `philippa` running as 104 on `.104` (restored
from the fresh PBS snapshot, config intact), UI answering 302, old 103
destroyed.

## Next steps (not yet built)

- **External dead-man heartbeat** (healthchecks.io-style): a Push monitor here
  can't do it — Kuma is inside the failure domain. Something *outside* the
  house must notice silence. Closes the "whole-house outage" gap.
- **Add monitors as services land**: docker VM 150 apps, HAOS, reverse proxy.
- **Pi-hole node-reboot failover test** still pending ([dns.md](dns.md)) — the
  pihole DNS monitors here will provide the alerting evidence during it.
