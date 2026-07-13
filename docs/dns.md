# DNS & ad-blocking — Pi-hole pair

As-built runbook for network DNS, implemented 2026-07-11. Two Pi-hole v6
instances, one per node, so a single node reboot never takes the whole house's
DNS down — the #1 homelab regret this design avoids.

Addresses use the `<LAN_PREFIX>` placeholder per `CLAUDE.md` and the last-octet
convention from [network.md](network.md) (`.NN` = `<LAN_PREFIX>.NN`, and
VMID = last octet).

## Architecture

| Piece | Value |
|---|---|
| pihole-1 | LXC **101** on **geralt**, `.101`, rootfs `silver-guests:4` |
| pihole-2 | LXC **201** on **yennefer**, `.201`, rootfs `local-lvm:4` |
| Container profile | unprivileged, `nesting=1`, 1 core, 512 MB RAM / 256 MB swap, `onboot=1` |
| Container upstream (`--nameserver`) | `1.1.1.1` (so the box resolves for `apt` etc. **without** looping through itself once it becomes the LAN resolver) |
| Pi-hole upstream DNS | Cloudflare `1.1.1.1` / `1.0.0.1` — set *inside* each Pi-hole, identical on both |
| Conditional forwarding | `<LAN_PREFIX>.0/24` → router `<LAN_PREFIX>.1`, domain `kaermorhen.internal` (so the dashboard shows client hostnames, not bare IPs) — domain renamed from `kaermorhen.home.arpa` 2026-07-12, see gotchas |
| Router DHCP DNS handout | primary `<LAN_PREFIX>.101`, secondary `<LAN_PREFIX>.201` — **both Pi-holes, no public resolver in the client list** |
| DNSSEC | off (default) |
| `listeningMode` | `LOCAL` (answers only the local subnet) |
| FTL NTP sync | **disabled** (`ntp.sync.active = false`) — see gotchas |
| Blocklist | default StevenBlack |

### Two deliberate non-changes

- **The Proxmox nodes keep resolving via the router**, not via Pi-hole. Pointing
  a host at a DNS server that runs *on* that host (or its partner) creates a
  boot-order chicken-and-egg; the hosts gain nothing from ad-blocking.
- **Redundancy is two Pi-holes, never Pi-hole + a public resolver.** A client
  given `[.101, 1.1.1.1]` does **not** treat the second entry as failover — it
  races or round-robins them, so blocking becomes inconsistent *and* any blip on
  `.101` shows up as multi-second hangs before the client tries the other. Both
  DNS servers handed to clients must be blocking resolvers; each carries its own
  public upstream internally.

## Runbook (as executed)

### 0. Template

Already present on both nodes — no download needed:
`local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst`.

### 1. Create the containers

On **geralt** (Pi-hole #1):

```bash
pct create 101 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname pihole-1 --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs silver-guests:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.101/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

On **yennefer** (Pi-hole #2) — identical but `rootfs local-lvm:4` (yennefer's
HDD is the ext4 backup disk, not a guest pool) and `.201`:

```bash
pct create 201 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname pihole-2 --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.201/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

### 2. Install Pi-hole (both containers, identical choices)

The installer is a whiptail dialog and needs a real controlling terminal, which
`pct enter` does **not** provide (see gotchas). Give it one with `script`:

```bash
pct enter 101        # then 201 on yennefer
apt update && apt -y install curl ca-certificates
curl -sSL https://install.pi-hole.net -o basic-install.sh
export TERM=xterm
script -qec "bash basic-install.sh" /dev/null
```

Installer picks (same on both): static-IP warning → Continue; upstream →
Cloudflare; blocklist → default; logging/privacy → defaults. Then set the admin
password identically on both:

```bash
pihole setpassword
```

### 3. Post-install (web UI `http://<LAN_PREFIX>.101/admin` and `.201/admin`)

- **Upstream DNS**: Cloudflare `1.1.1.1` + `1.0.0.1` (confirm it matches on both).
- **Conditional forwarding** (Settings → DNS, Expert mode): network
  `<LAN_PREFIX>.0/24`, router `<LAN_PREFIX>.1`, domain `kaermorhen.internal`.

### 4. NTP fix (both)

FTL ships an NTP client that tries to *step the system clock*; an unprivileged
LXC drops `CAP_SYS_TIME`, so it fails with "Insufficient permissions." The
container already inherits the host's (correct) clock, so the sync is redundant —
turn it off:

```bash
pct exec 101 -- pihole-FTL --config ntp.sync.active false   # and 201 on yennefer
```

### 5. Router DNS handout

On the router's **DHCP/LAN** settings (not WAN): DNS servers →
primary `<LAN_PREFIX>.101`, secondary `<LAN_PREFIX>.201`. Confirm the DHCP pool
stays bounded to `.31–.99`. Clients pick it up on lease renewal.

### 6. Verify

```bash
dig @<LAN_PREFIX>.101 example.com +short       # resolves
dig @<LAN_PREFIX>.201 example.com +short       # resolves
dig @<LAN_PREFIX>.101 doubleclick.net +short   # 0.0.0.0 → blocking works
dig @<LAN_PREFIX>.201 doubleclick.net +short
```

Then confirm a renewed client lists both servers and queries appear on both
dashboards.

## Gotchas hit (and the fixes)

- **Installer exits with `Installer exited at static IP message` / `cannot open
  tty-output`.** `pct enter` (lxc-attach) has stdin/stdout on a pty but **no
  controlling terminal**, so whiptail's menus can't open `/dev/tty`. Fix: wrap
  the installer in `script -qec "bash basic-install.sh" /dev/null` (allocates a
  real pty), or use `pct console <id>` (set a root password first with
  `pct exec <id> -- passwd root`). Piping `curl … | bash` also breaks the dialog
  (stdin is the script stream) — download the script, then run it.
- **House internet flapped when the router used `.101` primary + `1.1.1.1`
  secondary.** Not a Pi-hole fault — the primary/secondary split is the
  anti-pattern (see "two deliberate non-changes"). Fix is the two-Pi-hole handout.
- **A one-time few-minute outage right after changing the router's DNS is
  expected** — the router restarts its DHCP/DNS service and clients keep the old
  resolver until their lease renews and their local cache expires.
- **`ntp.sync` "Insufficient permissions"** — unprivileged LXC can't set the
  clock; disable `ntp.sync.active` (step 4). Leave `ntp.ipv4/ipv6` alone — that's
  Pi-hole *serving* NTP, a separate optional feature.
- **`dig` timing out against a Pi-hole that is actually healthy** — check the
  address for a typo (`191.168…` vs `192.168…`); a wrong first octet is a
  different network and just times out.
- **Apple clients never resolve `home.arpa` names** (hit 2026-07-12; the pair
  was originally built on `kaermorhen.home.arpa`). macOS/iOS mDNSResponder
  treats RFC 8375's `home.arpa` as a special-use Thread/HomeKit domain and
  synthesizes "No Such Record" locally — the query never reaches the
  configured DNS servers. Signature: `dig` works (it bypasses mDNSResponder)
  while browsers/apps fail, on every Apple device; `dscacheutil -q host -a
  name <fqdn>` reproduces the failure, `dns-sd -Q` shows the instant
  synthesized NXDOMAIN. A per-Mac `/etc/resolver/home.arpa` override exists,
  but iPhones/Apple TVs have no equivalent — so the internal domain was
  renamed to **`kaermorhen.internal`** (ICANN-reserved for private use, 2024).
  Renamed in: both Pi-holes (`dns.revServers` + `dns.hosts` via
  `pihole-FTL --config`), both nodes (`/etc/resolv.conf`, `/etc/hosts`,
  postfix `myhostname=`), and ciri's cloud-init `--searchdomain` (full
  `qm stop && qm start` to regenerate the cloud-init ISO). LXCs created
  without `--searchdomain` inherit the node's on their next restart.

## Backups

Both containers are covered automatically by the existing PBS `--all 1` jobs
(geralt 04:00, yennefer 04:30 → datastore `vault`); `101` is geralt's first
backed-up guest. See [backups.md](backups.md).

## List sync & local DNS records (2026-07-12)

- **nebula-sync** — compose stack on ciri
  ([as-built](../configs/ciri/nebula-sync/README.md)): full Teleporter sync
  pihole-1 → pihole-2 hourly, on-demand via
  `docker compose run --rm sync-now` in the VM. Consequence: **pihole-1 is
  the only place to edit** — lists, records, and config changed on pihole-2
  are overwritten within the hour.
- **Local DNS records** — every entry of [network.md](network.md)'s registry
  as `<name>.kaermorhen.internal`, one record per guest, name = hostname
  (switch `.20`, geralt `.21`, yennefer `.22`, pihole-1 `.101`,
  tailscale-2 `.103`, uptime-kuma `.104`, ciri `.150`, pbs `.200`,
  pihole-2 `.201`, tailscale-1 `.203`, beszel `.204`), set on pihole-1 via
  `pihole-FTL --config dns.hosts '[...]'` and synced to 201. (A 2026-07-13
  dual-record lore-alias scheme was rolled back the same day with the
  naming experiment.) Records coexist
  with conditional forwarding: dnsmasq answers locally-defined names itself
  and forwards only *unknown* `kaermorhen.internal` names to the router.

## Next steps

- **nebula-sync + local DNS records: done (2026-07-12)** — see the section
  above; the edit-both-UIs-by-hand tax is gone.
- **Failover acceptance test — done (2026-07-13, node-down variant)**: the
  container-stop half was done 2026-07-11 (stopping 101, then 201, left
  new-site browsing working — fail-fast case). The harder silent-drop case
  was proven in the yennefer outage drill: with the node halted (pihole-2
  dropping packets, not refusing), a full macOS resolver-stack lookup
  (`dscacheutil`, not `dig`) answered in ~48 ms via pihole-1 — no
  multi-second hang. `onboot=1` brought pihole-2 back resolving *and*
  blocking on power-up, and Kuma's pihole-2 DNS monitor alerted via ntfy
  through the window.
- **Uptime-Kuma: done (2026-07-11)** — LXC 104 on geralt (103 until the
  2026-07-13 renumber) runs DNS checks
  against `.101`/`.201` every 60 s, alerting via ntfy. As-built:
  [uptime-kuma.md](uptime-kuma.md).
