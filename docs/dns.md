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
| Conditional forwarding | `<LAN_PREFIX>.0/24` → router `<LAN_PREFIX>.1`, domain `kaermorhen.home.arpa` (so the dashboard shows client hostnames, not bare IPs) |
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
  `<LAN_PREFIX>.0/24`, router `<LAN_PREFIX>.1`, domain `kaermorhen.home.arpa`.

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

## Backups

Both containers are covered automatically by the existing PBS `--all 1` jobs
(geralt 04:00, yennefer 04:30 → datastore `vault`); `101` is geralt's first
backed-up guest. See [backups.md](backups.md).

## Next steps

- **nebula-sync** to keep the two instances in lockstep (adlists, allowlists,
  local DNS records) — deferred until the docker VM (150) exists. **Until then,
  any list change must be made in both UIs by hand.**
- **Local DNS records** (lab hostnames → IPs) deferred to land together with
  nebula-sync, so they sync rather than drift.
- **Failover acceptance test**: reboot one node and confirm the house still
  resolves through the other — the reason the pair exists, not yet proven.
- **Uptime-Kuma** (penciled at LXC 103 on geralt) as a service-level "is `.101`/
  `.201` answering on 53" check, complementing Beszel's host-level view.
