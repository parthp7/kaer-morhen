# Remote access — Tailscale subnet router

As-built runbook, implemented 2026-07-13. (The pair was briefly
`tor-lara`/`tor-zireael` — reverted the same day with the lore-naming
rollback; LXCs keep functional names, see [network.md](network.md).)
The remote-access piece from [Proposal 001 §4](proposals/001-initial-infrastructure-plan.md),
claiming the **LXC 203** slot reserved in [network.md](network.md). One
container runs `tailscaled` advertising the whole LAN (`<LAN_PREFIX>.0/24`) to
the tailnet, so every tailnet device (phone, laptop) reaches every service —
ciri's docker apps, the Proxmox UIs, Kuma, Beszel — by its real IP, with
nothing installed on the services themselves. Split DNS makes
`*.kaermorhen.internal` names resolve remotely through the Pi-holes.

Addresses use the `<LAN_PREFIX>` placeholder per `CLAUDE.md` and the
last-octet convention from [network.md](network.md).

## Architecture

| Piece | Value |
|---|---|
| Container | LXC **203** on **yennefer**, `.203`, hostname `tailscale-1`, rootfs `local-lvm:4` |
| Warm standby | LXC **103** `tailscale-2` on **geralt**, `.103` — same profile & config, route approved with tailscale-1 primary (built 2026-07-13, see dated section) |
| Profile | Debian 13, unprivileged, `nesting=1` (for systemd, not tailscaled — see gotchas), 1 core, 512 MB RAM / 256 MB swap, `onboot=1`, `/dev/net/tun` passed through via `--dev0` |
| Container nameserver | `1.1.1.1` — infra-tier convention ([dns.md](dns.md)): the box remote DNS flows *through* must not depend on the Pi-holes to boot |
| App | tailscaled from the official Tailscale apt repo (Debian trixie channel); updates manual via `apt` (house policy — nothing auto-updates) |
| Tailnet role | subnet router: `--advertise-routes=<LAN_PREFIX>.0/24`, `--accept-dns=false`, default SNAT on |
| Admin console | route approved; **key expiry disabled**; split DNS `kaermorhen.internal` → `.101`, `.201` |
| Monitoring | Uptime-Kuma ping monitor on `.203` (LAN-side liveness; see design notes for what it can't see) |
| Backups | covered by yennefer's nightly 04:30 `--all 1` PBS job automatically; node identity lives in `/var/lib/tailscale` and travels with the container |

## Design notes

- **Why a subnet router, not Tailscale-per-guest**: one install grants the
  tailnet the entire LAN — services keep zero remote-access config, and new
  stacks on ciri are remotely reachable the moment they exist. Per-guest
  Tailscale would re-create the agent-sprawl this design avoids.
- **Why Tailscale at all**: the Boa/GPON router can't be scripted and may be
  behind CGNAT — anything needing an inbound port forward (plain WireGuard,
  Headscale) is fragile-to-impossible here. Tailscale is outbound-only.
- **SNAT stays on** (the default): LAN devices see subnet-routed traffic as
  coming from `.203`, so no LAN device needs a return route. Cost: Pi-hole
  dashboards attribute all remote clients' queries to `tailscale-1` — accepted.
- **`--accept-dns=false` on the router itself**: tailnet DNS settings will
  point at the Pi-holes *via this container's route* — the router taking its
  own advertised DNS is a loop waiting for a bad moment. It keeps `1.1.1.1`
  like the other infra LXCs.
- **Split DNS failure domain**: remote name resolution (and remote everything)
  depends on this one container on yennefer, while most services live on
  geralt — a yennefer reboot takes remote access down. Addressed by the
  `tailscale-2` warm standby (built 2026-07-13, dated section below) —
  modulo the untested failover, see next steps.
- **What Kuma can't see**: a ping monitor on `.203` proves the LXC is alive,
  not that the tailnet path works — the real end-to-end check is a tailnet
  device off-LAN. The Tailscale admin console's machine "last seen" is the
  outside view.

## Runbook (as executed)

### 1. Create the container (yennefer)

Same template as the Pi-holes, already on both nodes.

```bash
pct create 203 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname tailscale-1 --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.203/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

(`nesting=1` is for Debian's systemd, not tailscaled — the container was
first built without it and warned at every start; see gotchas. Added
post-build via `pct set 203 --features nesting=1`, folded into the create
command above for the next build.)

### 2. Pass through `/dev/net/tun` (yennefer)

tailscaled wants a kernel TUN device; an unprivileged LXC doesn't get one by
default. PVE ≥ 8 does this cleanly as a device passthrough — no raw
`lxc.cgroup2.devices.allow` lines in the conf:

```bash
pct set 203 --dev0 /dev/net/tun
pct reboot 203
pct exec 203 -- ls -l /dev/net/tun   # crw-rw-rw- 10,200
```

### 3. Install Tailscale (inside the container)

Official repo, Debian 13 "trixie" channel:

```bash
pct enter 203
apt update && apt install -y curl ca-certificates
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg
curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list \
  -o /etc/apt/sources.list.d/tailscale.list
apt update && apt install -y tailscale
```

### 4. Enable forwarding (inside the container)

Both sysctls are per-network-namespace (same story as Kuma's
`ping_group_range`), so this touches nothing on the host:

```bash
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
sysctl -p /etc/sysctl.d/99-tailscale.conf
```

### 5. Bring it up (inside the container)

```bash
tailscale up --advertise-routes=<LAN_PREFIX>.0/24 --accept-dns=false
```

Prints an auth URL — open it in a browser, log in to the tailnet. The flags
are persisted in tailscaled state; they don't need repeating on restarts.

### 6. Admin console (https://login.tailscale.com/admin)

- **Machines → tailscale-1 → Edit route settings** → approve
  `<LAN_PREFIX>.0/24`. Until approved, the advertisement does nothing.
- **Machines → tailscale-1 → … → Disable key expiry** — otherwise remote
  access silently dies when the node key expires (~180 days), likely
  discovered while traveling. Do the same for any always-on device.
- **DNS → Nameservers → Add nameserver → Custom**: `<LAN_PREFIX>.101`,
  **Restrict to domain** `kaermorhen.internal`; repeat for `<LAN_PREFIX>.201`.
  Remote clients now resolve internal names through the Pi-holes over the
  subnet route; all other queries stay on the client's normal resolver.

### 7. Wiring

- **Uptime-Kuma** (`http://<LAN_PREFIX>.104:3001`): Ping monitor for `.203`,
  60 s, default ntfy — Kuma sits on geralt, so this survives a yennefer-side
  view loss and vice versa per the watcher split.
- **pihole-1**: add `tailscale-1.kaermorhen.internal` → `.203` to `dns.hosts`
  (nebula-sync propagates to 201 within the hour) — keeps the
  [dns.md](dns.md) registry rule "every network.md entry has a name".
- **network.md**: bold the 203 entry in yennefer's band table (built + date).

## Gotchas hit (and the fixes)

- **Services unreachable by LAN IP from the phone even though `tailscale
  status` on tailscale-1 looked healthy** — the route was advertised but never
  **approved** in the admin console (step 6's first bullet had been skipped).
  The two states are easy to conflate and nothing shouts about it:
  `tailscale debug prefs` showing `AdvertiseRoutes: [<LAN_PREFIX>.0/24]` only
  proves the container's half. The control-plane truth is
  `tailscale status --json` → `Self.AllowedIPs` / `Self.PrimaryRoutes`: the
  `/24` appears in both **only after console approval** (before it, only the
  node's own `100.x/32`). Fix: Machines → tailscale-1 → Edit route settings →
  enable the route; propagates to connected clients in seconds.
- **Warning at every container start when built without `nesting=1`.**
  tailscaled itself doesn't need nesting, but Debian 13's systemd in an
  unprivileged LXC wants it (PVE recommends nesting for any unprivileged
  container running systemd). Fixed with `pct set 203 --features nesting=1`;
  the create command above now includes it. Same trade-off as the Pi-holes
  and Kuma, which were built with it from day one.

Known sharp edges (not hit, kept for the next build):

- **Testing from the home Wi-Fi proves nothing** — a client on both the
  tailnet and the LAN reaches services directly. Always verify from LTE with
  Wi-Fi off.
- **Linux clients default to `--accept-routes` off** (mobile/macOS accept
  subnet routes automatically) — a future Linux laptop needs
  `tailscale set --accept-routes`.
- **`tailscale up` may warn about UDP GRO forwarding** (suggests `ethtool -K`
  tuning). That targets physical NICs; the LXC veth usually rejects it, and at
  residential-uplink throughput it's a performance nicety, not correctness.

## Warm standby — tailscale-2 (built 2026-07-13)

Same runbook, run on **geralt** as LXC **103** (`.103` — mirrors tailscale-1's
203 per the pair rule in [network.md](network.md), slot freed by the Kuma
renumber the same day): advertising the same `/24`, `--accept-dns=false`,
key expiry disabled. Deviations & findings:

- **rootfs initially landed on `local-lvm`** — the yennefer create command
  was reused verbatim, but geralt guests live on `silver-guests`. Fixed
  same day with
  `pct stop 103 && pct move-volume 103 rootfs silver-guests --delete 1 && pct start 103`;
  tailscaled came back clean.
- **Route approved rather than left disabled**: the original warm-standby
  plan was a manual console flip, but the route got enabled alongside
  tailscale-1's. Control keeps tailscale-1 primary (its `PrimaryRoutes` carries
  the `/24`; tailscale-2's is empty) with tailscale-2 approved-but-idle.
  Automatic failover is nominally a Premium feature — whether the Personal
  plan actually fails over is untested (next steps).
- **Cosmetic health warning** on both routers now — "Some peers are
  advertising routes but --accept-routes is false": each router sees the
  other's advertisement. A subnet router must not accept the very route it
  advertises; ignore it.
- **Wiring**: `tailscale-2.kaermorhen.internal` → `.103` set on pihole-1
  and synced to both (done 2026-07-13). Kuma ping monitor on `.103` still
  pending.

## Verification (read-only)

```bash
# yennefer
pct status 203
pct config 203                                   # dev0 tun, onboot, .203, no nesting
pct exec 203 -- tailscale status                 # self + peers, no Health warnings
pct exec 203 -- tailscale status --json | grep -A3 AdvertisedRoutes
pct exec 203 -- sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding   # both 1
pct exec 203 -- systemctl is-active tailscaled
pct exec 203 -- free -m
```

From a tailnet device **off the LAN** (phone on LTE, Wi-Fi off):

- `http://<LAN_PREFIX>.150:5230` (memos by IP) loads → subnet route works
- `http://ciri.kaermorhen.internal:5230` loads → split DNS works
- Proxmox UIs at `https://<LAN_PREFIX>.21:8006` / `.22:8006` reachable

Verified 2026-07-13: container running with the profile above (`dev0` tun,
`nesting=1`, `onboot=1`), tailscaled active and online, both forwarding
sysctls = 1, prefs advertising `<LAN_PREFIX>.0/24` with `CorpDNS=false`;
after route approval the `/24` shows in `Self.AllowedIPs` **and**
`Self.PrimaryRoutes`, health empty. End-to-end from phone on LTE: memos by
IP (`.150:5230`) loads. `tailscale-1.kaermorhen.internal` → `.203` answered by
both Pi-holes (record set on pihole-1, nebula-sync propagated to 201).
Split-DNS name path verified from LTE same day (`ciri.kaermorhen.internal`).

Twin verified 2026-07-13: `tailscale-2` running as 103 on `.103` (`dev0`
tun, `nesting=1`, `onboot=1`), tailscaled active and online, both
forwarding sysctls = 1, advertising the `/24` with `CorpDNS=false`, route
approved with tailscale-1 primary, key expiry disabled on **both** routers
(`KeyExpiry: None` in `tailscale status --json`). Post-fixes re-verified
same day: rootfs on `silver-guests`, tailscaled active after the move,
`tailscale-2.kaermorhen.internal` → `.103` from both Pi-holes.

## Next steps (not yet built)

- **Failover acceptance test** (twin built 2026-07-13, behavior unproven):
  with a phone on LTE watching a `.150` service, `pct stop 203` on yennefer
  — does the `/24` shift to tailscale-2 on the Personal plan (automatic
  failover is nominally Premium)? If not, the outage drill is the console
  route flip (doable from the phone). Record the result here either way,
  then `pct start 203`.
- **Optional — exit node** (`--advertise-exit-node`): full-tunnel browsing
  through home (Pi-hole ad-blocking everywhere). Off by default; decide when
  there's a use case.
- **Reverse proxy interplay** (LXC 202, still unbuilt): once a proxy serves
  `https://<app>.kaermorhen.internal` with real certs, remote clients get the
  same clean URLs via this route — no Tailscale-side changes needed.
