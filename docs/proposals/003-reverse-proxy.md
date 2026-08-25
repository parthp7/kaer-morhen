# Proposal 003 — Reverse proxy: clean URLs, no ports (Caddy in LXC 202)

- **Status**: **Built 2026-08-12, wiring in progress.** LXC 202 is up on
  yennefer serving all 22 names behind a **production** wildcard cert
  (`*.kaermorhen.fyi`, Let's Encrypt, DNS-01 via Cloudflare). Full Caddyfile
  deployed, all 36 Pi-hole records in place and synced to pihole-2, and
  Tailscale split DNS confirmed routing `kaermorhen.fyi` to both Pi-holes
  (2026-08-21). Sweep of all 22 URLs verified below. Claims the **LXC 202**
  slot reserved in [network.md](../network.md) since 2026-07-10, and closes
  the "reverse proxy interplay" next-step in
  [tailscale.md](../tailscale.md).
  Per-app fixes done for Paperless (`PAPERLESS_URL`), Sure
  (`RAILS_ASSUME_SSL`) and Immich (app repointed); Kuma monitors `proxy-caddy`
  and `proxy-tls` live with certificate-expiry alerting (2026-08-23).
  **One item outstanding: Jellyfin's published server URI — parked
  2026-08-23, state and next experiment in §7.** Audiobookshelf was retired
  2026-08-24 — the plan was abandoned rather than deployed, and its route and
  DNS record were removed, so `books.kaermorhen.fyi` no longer exists (§3).
- **Date**: 2026-08-08 (domain settled 2026-08-09)
- **Scope**: new LXC 202 on `yennefer`; DNS records on pihole-1
  ([dns.md](../dns.md)); Tailscale split-DNS addition
  ([tailscale.md](../tailscale.md)); per-app config touch-ups on `ciri`
- **Decisions taken up front**: real registered domain with a wildcard Let's
  Encrypt cert via DNS-01 (2026-08-08); the proxy lives in **LXC 202**, not as
  a compose stack on ciri (2026-08-08); the domain is **`kaermorhen.fyi`**,
  registered at Porkbun, with service names directly under it and no `home.`
  label (2026-08-09). Rationale in §2, cost and registrar comparison in §7.

Addresses use the `<LAN_PREFIX>` placeholder per `CLAUDE.md` and the last-octet
convention from [network.md](network.md). **The domain is written out in full**
— a registered domain is public information by construction, carries no secret,
and masking it would make every example here unreadable. The credentials that
*are* secret stay as placeholders: `<ACME_EMAIL>` and `<CF_API_TOKEN>`, with
real values in `secrets.local.yaml`.

## 1. The problem

Sixteen web services are reachable only as `<host>:<port>`, and the port is the
only thing distinguishing them:

| Service | Today | After |
|---|---|---|
| Jellyfin | `<LAN_PREFIX>.150:8096` | `jellyfin.kaermorhen.fyi` |
| Immich | `<LAN_PREFIX>.150:2283` | `immich.kaermorhen.fyi` |
| memos | `<LAN_PREFIX>.150:5230` | `memos.kaermorhen.fyi` |
| Paperless | `<LAN_PREFIX>.150:8000` | `paperless.kaermorhen.fyi` |
| Sure | `<LAN_PREFIX>.150:3000` | `sure.kaermorhen.fyi` |
| Open WebUI | `<LAN_PREFIX>.150:8090` | `chat.kaermorhen.fyi` |
| Ollama API | `<LAN_PREFIX>.150:11434` | `ollama.kaermorhen.fyi` |
| CouchDB (Obsidian) | `<LAN_PREFIX>.150:5984` | `obsidian.kaermorhen.fyi` |
| qBittorrent | `<LAN_PREFIX>.150:8080` | `qbit.kaermorhen.fyi` |
| Prowlarr | `<LAN_PREFIX>.150:9696` | `prowlarr.kaermorhen.fyi` |
| Sonarr | `<LAN_PREFIX>.150:8989` | `sonarr.kaermorhen.fyi` |
| Radarr | `<LAN_PREFIX>.150:7878` | `radarr.kaermorhen.fyi` |
| Bazarr | `<LAN_PREFIX>.150:6767` | `bazarr.kaermorhen.fyi` |
| Jellyseerr | `<LAN_PREFIX>.150:5055` | `requests.kaermorhen.fyi` |
| Uptime-Kuma | `<LAN_PREFIX>.104:3001` | `kuma.kaermorhen.fyi` |
| Beszel | `<LAN_PREFIX>.204:8090` | `beszel.kaermorhen.fyi` |
| PBS | `<LAN_PREFIX>.200:8007` | `pbs.kaermorhen.fyi` |
| Proxmox geralt | `<LAN_PREFIX>.21:8006` | `geralt.kaermorhen.fyi` |
| Proxmox yennefer | `<LAN_PREFIX>.22:8006` | `yennefer.kaermorhen.fyi` |

The existing Pi-hole records (`jellyfin.kaermorhen.internal` →
`<LAN_PREFIX>.150`) only removed the need to remember the *IP* — they point at
the host, so the port is still mandatory. A name→port mapping needs something
that terminates HTTP and dispatches on `Host`, i.e. a reverse proxy.

FlareSolverr (`8191`) and SearXNG stay unproxied: the first is an internal API
for Prowlarr, the second has no published host port at all.

**Audiobookshelf was routed, then retired (2026-08-24).** The `@books` block and
the `books.kaermorhen.fyi` DNS record were added ahead of a stack that was never
built, so the name returned 502 for twelve days (confirmed 2026-08-12) and then
showed up as the only failure in the first post-upgrade smoke test. Rather than
carry a permanently-red assertion, the audiobooks plan was dropped: route
removed from the `Caddyfile`, A record removed from pihole-1, and the local
scaffolding deleted, and the empty `library/audiobooks` folder removed from the
media disk. **Lesson kept: do not publish a route or a DNS record ahead
of the service.** An advertised name that always fails trains you to ignore a
red check, which is the one thing a check must never do.

## 2. Decisions and why

### Why a real domain instead of `kaermorhen.internal`

`.internal` is ICANN-reserved for private use, which is exactly why
[dns.md](../dns.md) chose it after the `home.arpa` fiasco — and exactly why no
public CA will ever issue a certificate for it. The three ways out:

- **Caddy's internal CA** — free and keeps the short names, but every device
  must trust a custom root. Fine on laptops, a per-device profile chore on
  iPhone, and awkward on Apple TV. Rejected: the Apple-client tax is the same
  tax `home.arpa` was renamed to avoid.
- **Plain HTTP** — solves the port problem outright and works everywhere, but
  Obsidian LiveSync on mobile requires HTTPS, and Immich/Paperless logins would
  ride in clear over the tailnet-to-LAN hop. Rejected on those two.
- **Real domain + wildcard cert via DNS-01** — chosen. A single
  `*.kaermorhen.fyi` cert, real green padlock on every device including
  Apple TV, zero trust-store work.

**Nothing is exposed to the internet by this.** DNS-01 proves domain control by
writing a TXT record via the registrar's API — no inbound port forward, no
HTTP-01 challenge, no listener reachable from outside. This matters here: the
Boa/GPON router can't be scripted and may be behind CGNAT
([tailscale.md](../tailscale.md) §Design notes), so HTTP-01 was never available
anyway. The `A` records live **only in Pi-hole**, never in public DNS.

`kaermorhen.internal` is *not* retired — it keeps naming hosts and infra
(the [dns.md](../dns.md) registry rule stands). The new domain names
*services*. Two namespaces, two jobs.

### Why names sit directly under the domain, with no `home.` label

An earlier draft used `jellyfin.home.kaermorhen.fyi`, reserving the rest of the
namespace for anything public later. Dropped on 2026-08-09: this domain has
exactly one job — proving control to the CA so the lab can have clean URLs —
and the extra label costs five characters on every name you type for years.

The trade-off, stated plainly: the wildcard now sits at the apex, so **every**
subdomain of `kaermorhen.fyi` resolves internally to `.202`. If a genuinely
public subdomain is ever wanted (a mail host, a status page), it must be carved
out as an explicit Pi-hole record and an explicit Caddy block, or moved to a
different domain. At this scale that is a cheap future problem; the daily
typing tax was not.

### Why LXC 202 on yennefer, not a compose stack on ciri

Every proxied app except five lives on ciri, so co-locating would avoid a LAN
hop. It was rejected because the proxy also fronts **Proxmox, PBS, Kuma and
Beszel** — the things you reach for precisely when ciri is down or rebooting
for updates. A proxy that dies with the docker VM takes the recovery UIs with
it. The extra geralt→yennefer→geralt hop is sub-millisecond on a wired /24.

The residual cost is honest: a yennefer reboot takes the pretty URLs down. That
is the same failure domain remote access already accepted for `tailscale-1`,
and the port-based URLs keep working throughout as the fallback path.

### Why Caddy

Automatic cert issuance and renewal with a two-line DNS-01 block, HTTP→HTTPS
redirect by default, websockets proxied without configuration, and a single
`Caddyfile` that mirrors into git the way `compose.yaml` files already do.
Nginx Proxy Manager keeps its state in a database, which cannot be
version-controlled the way this repo works; Traefik's label-driven discovery
only pays off when the proxy shares a docker host with its backends, which §2
just decided against.

### Why explicit A records, not a dnsmasq wildcard

A wildcard (`address=/kaermorhen.fyi/<LAN_PREFIX>.202`) means never
touching DNS again when adding an app — but it must be written as a file under
`/etc/dnsmasq.d/` on **both** Pi-holes and needs `misc.etc_dnsmasq_d` flipped
on (currently `false`, confirmed 2026-08-08). Teleporter does not carry that
directory, so **nebula-sync would not replicate it** — it would silently drift,
which is the exact class of bug the hourly sync exists to prevent.

Explicit records in `dns.hosts` sync automatically and keep pihole-1 the single
source of truth. Adding an app already means editing the Caddyfile; adding one
more line next to it is not the bottleneck.

## 3. Architecture

| Piece | Value |
|---|---|
| Container | LXC **202** on **yennefer**, `<LAN_PREFIX>.202`, hostname `proxy`, rootfs `local-lvm:4` |
| Profile | Debian 13, unprivileged, `nesting=1`, 1 core, 512 MB RAM / 256 MB swap, `onboot=1` |
| Container nameserver | `1.1.1.1` — infra-tier convention ([dns.md](../dns.md)); the proxy must not need the Pi-holes to boot, and ACME must resolve the registrar's API regardless of LAN DNS state |
| App | Caddy 2 from the official apt repo + `caddy-dns/cloudflare` plugin; updates manual via `apt` (house policy) |
| Certificate | one wildcard `*.kaermorhen.fyi` from Let's Encrypt, DNS-01, auto-renewed by Caddy |
| Public DNS | **none** — the domain's only job is proving control for ACME |
| Internal DNS | one A record per service in pihole-1's `dns.hosts` → `<LAN_PREFIX>.202`, synced to pihole-2 by nebula-sync |
| Remote access | Tailscale split DNS gains `kaermorhen.fyi` → `.101`, `.201`, alongside the existing `kaermorhen.internal` entry |
| Monitoring | Uptime-Kuma HTTP monitor on a proxied URL (proves the whole chain), plus a ping monitor on `.202` |
| Backups | covered automatically by yennefer's nightly 04:30 `--all 1` PBS job |

Request path, LAN and remote alike:

```
client → Pi-hole: jellyfin.kaermorhen.fyi? → <LAN_PREFIX>.202
client → :443 on .202 → Caddy matches Host → <LAN_PREFIX>.150:8096
```

Remotely the only difference is that the first hop reaches the Pi-holes through
`tailscale-1`'s subnet route, which already works. **No Tailscale-side change
beyond adding the second split-DNS domain** — as [tailscale.md](../tailscale.md)
predicted.

## 4. Runbook

### 0. Register the domain (prerequisite, done in a browser)

Any registrar works; the constraint is an **API-accessible DNS provider** that
Caddy has a plugin for. Cloudflare DNS is free, and its plugin is the
best-tested — the recommended shape is: register anywhere (Porkbun, Cloudflare
Registrar), then point the nameservers at Cloudflare.

**Then empty the zone.** Cloudflare's "Add site" scan imports whatever the
registrar was serving — for a fresh Porkbun domain that is a parking wildcard,
proxied through Cloudflare's edge. Delete **every** A, AAAA and CNAME record so
the DNS tab is empty. Leaving them there does not merely leak nothing useful;
it actively breaks the setup, because clients that prefer IPv6 will reach
Cloudflare instead of the proxy (§6, first bullet — this cost real debugging
time on 2026-08-12). The zone's only job is holding the transient ACME TXT
records Caddy writes and deletes during issuance.

In the Cloudflare dashboard, create a **scoped** API token:
`Permissions: Zone → DNS → Edit`, `Zone Resources: Include → Specific zone →
kaermorhen.fyi`. Nothing broader — this token can only write DNS records for
one zone, which is all DNS-01 needs.

Record in `secrets.local.yaml`:

```yaml
ACME_EMAIL: <email for LE expiry notices>
CF_API_TOKEN: <scoped token>
```

### 1. Create the container (yennefer)

Same template as the Pi-holes and Tailscale routers, already on both nodes.

```bash
pct create 202 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname proxy --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.202/24,gw=<LAN_PREFIX>.1 \
  --nameserver 1.1.1.1 \
  --onboot 1 --start 1
```

(`nesting=1` from the start — the lesson from `tailscale-1`, which warned at
every boot until it was added.)

### 2. Install Caddy + the Cloudflare DNS plugin (inside the container)

```bash
pct enter 202
apt update && apt install -y curl ca-certificates debian-keyring debian-archive-keyring apt-transport-https
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
  -o /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

DNS-01 needs a plugin the stock binary doesn't ship. Caddy replaces its own
binary with a rebuilt one:

```bash
caddy add-package github.com/caddy-dns/cloudflare
systemctl restart caddy
caddy list-modules | grep dns.providers.cloudflare   # must print the module
```

> `caddy add-package` fetches a fresh build from Caddy's download server, so
> the container needs outbound internet at this step. It must be re-run after
> any `apt upgrade` of Caddy — an apt update ships the *stock* binary and
> silently drops the plugin. See §6.

### 3. Supply the API token as a systemd credential (inside the container)

The token must not sit in the Caddyfile, which is git-tracked:

```bash
install -d -m 0700 /etc/caddy
cat > /etc/caddy/cloudflare.env <<'EOF'
CF_API_TOKEN=<CF_API_TOKEN>
EOF
chmod 600 /etc/caddy/cloudflare.env

mkdir -p /etc/systemd/system/caddy.service.d
cat > /etc/systemd/system/caddy.service.d/10-env.conf <<'EOF'
[Service]
EnvironmentFile=/etc/caddy/cloudflare.env
EOF
systemctl daemon-reload
```

Same shape as the compose stacks' `.env` convention: real value in the VM at
`chmod 600`, an `.env.example` with placeholders in git.

### 4. Write the Caddyfile

Full file in [configs/yennefer/proxy/Caddyfile](../../configs/yennefer/proxy/Caddyfile);
the shape is a single wildcard site block so exactly **one** certificate is
issued, with per-service dispatch inside it:

```caddyfile
*.kaermorhen.fyi {
	tls <ACME_EMAIL> {
		dns cloudflare {env.CF_API_TOKEN}
	}

	@jellyfin host jellyfin.kaermorhen.fyi
	handle @jellyfin {
		reverse_proxy <LAN_PREFIX>.150:8096
	}

	# … one matcher+handle pair per service …

	handle {
		respond "no such service" 404
	}
}
```

Then check it and watch it get the cert:

```bash
# Syntax check. `adapt` only converts Caddyfile -> JSON, so it needs no token.
caddy adapt --config /etc/caddy/Caddyfile

# Full check. `validate` provisions the DNS module, so CF_API_TOKEN must be in
# *this shell* — systemd's EnvironmentFile only applies to the service.
set -a; . /etc/caddy/cloudflare.env; set +a
caddy validate --config /etc/caddy/Caddyfile

systemctl reload caddy
journalctl -u caddy -f          # "certificate obtained successfully"
```

### 5. DNS records (pihole-1 only — nebula-sync propagates)

Append one entry per service to the existing `dns.hosts` array, all pointing at
`<LAN_PREFIX>.202`. **The whole array must be passed** — `pihole-FTL --config`
replaces it wholesale rather than appending, so read the current value first
(the 13 existing records) and re-send it with the new ones added.

```bash
pct exec 101 -- pihole-FTL --config dns.hosts    # read current, build the new list from it
```

Then force the sync rather than waiting the hour, on ciri:

```bash
docker compose -f /data/stacks/nebula-sync/compose.yaml run --rm sync-now
```

### 6. Tailscale split DNS (admin console)

**DNS → Nameservers → Add nameserver → Custom**: `<LAN_PREFIX>.101`, *Restrict
to domain* `kaermorhen.fyi`; repeat for `<LAN_PREFIX>.201`. This is in
addition to — not a replacement for — the existing `kaermorhen.internal`
entries. Without it, remote clients resolve the domain against public DNS,
find nothing, and every URL breaks off-LAN while working perfectly at home.

### 7. Per-app fixes on ciri

Several apps reject requests whose `Host` no longer matches what they were
told to expect. Each needs a one-line change, then a stack restart:

- **Paperless** — set `PAPERLESS_URL=https://paperless.kaermorhen.fyi`
  in its `.env`, else every login POST fails CSRF origin checks.
- **Sure** (Rails) — add the new host to its allowed hosts / `APP_DOMAIN`
  equivalent, same CSRF-origin reason.
- **qBittorrent** — set **Web UI → "Trust the following reverse proxies list"**
  to `<LAN_PREFIX>.202` (done 2026-08-25; `WebUI\ReverseProxySupportEnabled=true`,
  `WebUI\TrustedReverseProxiesList=<LAN_PREFIX>.202` in `qBittorrent.conf`).
  This section previously prescribed `header_up Host {upstream_hostport}`
  instead, which is what left the WebUI dead by name for weeks: qBit's CSRF
  guard compares the browser's `Referer`/`Origin` against the target origin, so
  a `Host` rewritten to `<LAN_PREFIX>.150:8080` mismatched every POST
  (`WebUI: Referer header & Target origin mismatch!` in its log, 401 on the
  login POST) while a plain `GET /` still returned the login page — hence the
  "works on the bare IP, dead by name" shape that made it look like a proxy
  problem. Trusting the proxy fixes it because qBit then takes the target
  origin from `X-Forwarded-Host`, which Caddy sets to the original
  `qbit.kaermorhen.fyi` regardless of the rewrite, and takes the client IP from
  `X-Forwarded-For` — so logins are now logged and rate-limited against the
  real client instead of all appearing as `.202` (five failed logins by name
  used to ban the proxy and lock every user out over the domain).
  The `header_up Host` line was then dropped from the qbit block as well
  (2026-08-25, commented out and `systemctl reload caddy`), so the fix no
  longer leans on `X-Forwarded-Host` or on the trust list surviving an LXC
  rebuild: `WebUI\ServerDomains` is `*`, the original `Host` passes validation
  on its own, and `Referer` matches it directly. Either change alone clears the
  CSRF check — both are in place, and the trust list still earns its keep by
  giving qBit the real client IP. Verified end-to-end after the reload: a
  request through Caddy carrying a browser-like `Referer` now returns 403
  (unauthenticated, CSRF passed) where it returned 401 (origin mismatch)
  before, and the log records logins against the client rather than `.202`.
- **Ollama** — `Host`-sensitive the *other* way from qBittorrent above: it
  rejects a foreign `Host` outright, so its Caddyfile block does carry
  `header_up Host {upstream_hostport}`. Do not generalise that to other
  backends by reflex — check which way each one is sensitive.
- **Immich** — set `request_body { max_size 0 }` on its block or large photo
  and video uploads fail at Caddy's default limit. Repoint the mobile app's
  server URL afterwards.
- **CouchDB / Obsidian LiveSync** — same body-size treatment; this is the one
  service that *gains* function, since mobile LiveSync requires HTTPS.
- **Jellyfin** — **UNRESOLVED, parked 2026-08-23.** `KnownProxies` is set to
  `<LAN_PREFIX>.202` and that part is done. The published-server-URI half is
  not, and is the reason native/remote clients misbehave: Jellyfin
  self-detects its address and advertises its *Docker bridge IP*
  (`"LocalAddress":"http://172.24.0.2:8096"` — note it moved from `172.23.0.2`
  when the container was recreated, which is the point: the value is not
  stable). A LAN browser survives it because the web UI uses relative paths;
  native clients and every remote client build stream and API URLs from
  `LocalAddress` and land on an address that exists only inside ciri.

  What has been established, so it is not re-derived:

  - **10.11 has no "Publish server URL based on client request" checkbox.** It
    exposes *Published Server URIs* (`PublishedServerUriBySubnet`) instead,
    with `internal=` / `external=` / `all=` syntax. The
    `EnablePublishedServerUriByRequest` field still exists in `network.xml`
    but has no UI; whether it is still honoured or vestigial is **untested**.
  - **`internal=` / `external=` cannot express the goal here.** Tailscale
    SNATs remote clients to `<LAN_PREFIX>.103`, a LAN address, so Jellyfin
    files them as internal. The split silently misclassifies every remote
    client.
  - **Do not set LAN Networks (`LocalNetworkSubnets`) to the LAN subnet.**
    Tried 2026-08-23 and it *regressed* things: the setting also filters which
    of Jellyfin's own interfaces it will publish, and in a bridged container
    none are in `<LAN_PREFIX>.0/24`, so it fell back to publishing
    `127.0.0.1`. Reverted to empty.
  - **`PublishedServerUriBySubnet` takes precedence over request-based
    publishing**, so it must be cleared to test the latter at all.
  - Jellyfin's Dashboard rewrites `network.xml` wholesale on save, so a
    UI change will silently drop any field edited by hand.

  **Next step when resumed**: clear `LocalNetworkSubnets` and
  `PublishedServerUriBySubnet`, set `EnablePublishedServerUriByRequest` to
  `true`, restart the *container* (`docker restart jellyfin` — the Dashboard's
  restart button reloads in-process and does not change Docker's `StartedAt`),
  then compare:

  ```bash
  curl -s https://jellyfin.kaermorhen.fyi/System/Info/Public | grep -o '"LocalAddress":"[^"]*"'
  curl -s http://<LAN_PREFIX>.150:8096/System/Info/Public | grep -o '"LocalAddress":"[^"]*"'
  ```

  Different per path = request-based works, and gives the desired split (TV
  direct by IP, Mac/phone proxied). Both `172.24.0.2` = the field is vestigial;
  fall back to `all=https://jellyfin.kaermorhen.fyi` and accept that the TV
  streams through the proxy too.
- **Proxmox and PBS** — self-signed HTTPS backends, so their blocks need
  `reverse_proxy https://… { transport http { tls_insecure_skip_verify } }`.
  Skipping verification is correct here: the connection is a wired LAN hop to
  an IP, and the certs are self-signed by definition.

### 8. Wiring

- **Uptime-Kuma** (`http://<LAN_PREFIX>.104:3001`): two monitors, both in the
  `yennefer` group with the existing `ntfy-alerts` notification.
  - `proxy-caddy` — Ping on `<LAN_PREFIX>.202`: is the container alive.
  - `proxy-tls` — HTTP(s) on `https://memos.kaermorhen.fyi`: exercises DNS,
    the proxy, the certificate and a backend in one check, with
    **Certificate Expiry Notification enabled** and **Ignore TLS/SSL error
    left off** (ticking it silently defeats the whole point).

  Cert expiry is a *property of an HTTPS monitor* in Kuma
  (`expiry_notification`), not a monitor type of its own — there is nothing
  separate to create. The lead time is global: Settings → Notifications →
  Certificate Expiry, default `7,14,21` days. Caddy renews at ~30 days
  remaining, so a 21-day warning means renewal has already been failing for
  over a week; **`25,14,7` is the better setting** here.

  The pairing with the existing backend monitors is what makes this
  diagnosable: `memos` (monitor 10) already watches `<LAN_PREFIX>.150:5230`
  directly, so backend-up + `proxy-tls`-down isolates the fault to the proxy,
  while both down means memos itself. A wildcard that fails to renew takes all
  22 URLs down at once, and Caddy renews silently until it doesn't.
- **pihole-1**: `proxy.kaermorhen.internal` → `<LAN_PREFIX>.202`, keeping the
  [dns.md](../dns.md) rule that every network.md entry has a name.
- **network.md**: bold the 202 entry in yennefer's band table with the date.
- **configs/yennefer/proxy/**: `Caddyfile`, `.env.example`, `README.md` — the
  first non-ciri config directory, so it extends `CLAUDE.md`'s mirror rule to
  LXC-hosted configs (`scp` the live file into the repo verbatim after changes).

## 5. Verification

```bash
# yennefer
pct status 202
pct config 202                                   # nesting, onboot, .202
pct exec 202 -- systemctl is-active caddy
pct exec 202 -- caddy list-modules | grep cloudflare
pct exec 202 -- ls /var/lib/caddy/.local/share/caddy/certificates -R   # the wildcard
```

From a LAN client:

```bash
dig +short jellyfin.kaermorhen.fyi         # → <LAN_PREFIX>.202
curl -sI https://memos.kaermorhen.fyi | head -1     # 200, no -k needed
curl -sI http://memos.kaermorhen.fyi | head -1      # 308 → https
```

The `curl` without `-k` is the real test: it proves the cert chains to a public
root, which is the entire reason for choosing a real domain.

**Always check IPv6 separately.** `dig +short <name>` returning `.202` proves
nothing on its own — it did exactly that throughout the 2026-08-12 AAAA
incident while every client silently went to Cloudflare. Add:

```bash
dig +short AAAA memos.kaermorhen.fyi @1.1.1.1   # must be empty
curl -sIL http://memos.kaermorhen.fyi -o /dev/null \
  -w "final: %{http_code}  scheme: %{scheme}  ip: %{remote_ip}\n"
```

The last line is the single best one-shot check: it follows the redirect and
prints the address actually served, so a Cloudflare-shadowed name is obvious.

**Smoke test verified 2026-08-12** (memos only, before the full Caddyfile):
`http://` → `308` → `https://`, final `200` served from `<LAN_PREFIX>.202`,
certificate `CN=*.kaermorhen.fyi` issued by Let's Encrypt **production**
(no `(STAGING)` in the issuer) and validated by `curl` without `-k`; AAAA
empty from both the public resolver and pihole-1. Note the production
re-issue takes a minute or two after `systemctl restart caddy` — a `curl` run
inside that window still shows the old behaviour and is not a failure.

From a tailnet device **off the LAN** (phone on LTE, Wi-Fi off) — per
[tailscale.md](../tailscale.md), testing on home Wi-Fi proves nothing:

- `https://memos.kaermorhen.fyi` loads with a valid padlock
- `https://geralt.kaermorhen.fyi` reaches the Proxmox UI
- Obsidian LiveSync syncs against `https://obsidian.kaermorhen.fyi`

Then reboot 202 and confirm it comes back serving unattended (`onboot=1`), and
reboot ciri to confirm Caddy recovers when backends return rather than caching
a failure.

## 6. Known sharp edges

- **`apt upgrade` silently removes the DNS plugin.** The Caddy package installs
  the stock binary; `caddy add-package` replaced it with a custom build. After
  any Caddy upgrade, re-run the `add-package` command and check
  `caddy list-modules`. Symptom: renewals start failing ~30 days later with
  "no solvers available" — long after the upgrade, so the cause is not obvious.
- **Certificate renewal is invisible until it breaks.** Everything works for 60
  days after a broken token or removed plugin. The Kuma cert-expiry monitor in
  §8 is not optional garnish; it is the only thing that catches this.
- **The global options block must be the first block in the file** (hit
  2026-08-12 on the smoke test). A `{ email … }` block preceded by so much as a
  comment header is parsed as a *nameless site block*, and Caddy rejects it with
  `unrecognized directive: email` plus a misleading "Did you mean to define a
  second site?" hint. Since the deployed `Caddyfile` carries a 17-line header by
  design, the ACME contact is given as an argument — `tls <ACME_EMAIL> { … }` —
  and no global block is used at all. Don't reintroduce one.
- **Uptime-Kuma cannot resolve `*.kaermorhen.fyi` without help** (hit
  2026-08-23). Two individually-correct decisions collide: LXC 104 runs
  `nameserver 1.1.1.1` on purpose so the monitor does not depend on the
  Pi-holes it watches ([uptime-kuma.md](../uptime-kuma.md)), while these names
  exist **only** in Pi-hole because the public zone is deliberately empty.
  Result: `getaddrinfo ENOTFOUND memos.kaermorhen.fyi` and a monitor that can
  never come up. Fix is a static mapping in the monitor container rather than
  repointing its resolver:
  `pct exec 104 -- sh -c 'echo "<LAN_PREFIX>.202 memos.kaermorhen.fyi" >> /etc/hosts'`.
  Cost: that monitor no longer exercises the Pi-hole DNS path — acceptable,
  since `pihole1-dns` / `pihole2-dns` cover resolution directly. Any future
  monitor on a `.fyi` name needs the same entry.
- **Don't verify with `curl -I`.** Proxmox and PBS do not implement `HEAD` and
  answer `501` / `400`, which reads as a broken route when a plain `GET` returns
  `200` (hit 2026-08-12 across `geralt`, `yennefer`, `pbs`). Use
  `curl -s -o /dev/null -w '%{http_code}'` for the sweep. Equally, `401` from
  CouchDB and the \*arr apps is a **healthy** result — the backend answered
  through the proxy and asked for credentials.
- **AAAA queries shadow the whole setup if the public zone has records** (hit
  2026-08-12, cost the most time of anything here). A `dns.hosts` entry defines
  an **A** record only. Pi-hole does not treat itself as authoritative for a
  real public domain, so the matching **AAAA** query is forwarded upstream — and
  if Cloudflare still holds the wildcard/apex records its "Add site" scan
  imported from Porkbun's parking page, it answers with its own edge IPv6.
  macOS and iOS prefer IPv6, so clients reach **Cloudflare instead of the lab**.
  Signature: `dig +short <name>` returns `.202` and looks perfect, while
  `curl -sI https://<name>` returns `301` with `server: cloudflare` and a
  `cf-ray` header, redirecting to the apex. `curl -4` reaches Caddy correctly.
  Fix: **delete every A/AAAA/CNAME record in the Cloudflare zone** — it must be
  empty. The zone exists only to host the transient ACME TXT records; nothing
  about this design ever wants a public address record.
  Hardening (optional, not applied): `local=/kaermorhen.fyi/` in
  `/etc/dnsmasq.d/` makes Pi-hole authoritative so AAAA is answered NODATA
  locally and never forwarded, removing the dependency on the public zone
  staying empty. Costs the same nebula-sync problem as the wildcard — it must
  be written on **both** Pi-holes by hand and will not replicate.
- **A staging certificate failing `curl` without `-k` is correct, not a bug.**
  `SSL certificate problem: unable to get local issuer certificate` against
  `issuer=(STAGING) …` means DNS-01 worked and the smoke test passed. Confirm
  with `openssl s_client -connect <ip>:443 -servername <name>` before assuming
  something is broken.
- **`caddy validate` run by hand reports `API token '' appears invalid`** (hit
  2026-08-12). Not a bad token — `{env.CF_API_TOKEN}` reads the *process*
  environment, and the token is supplied by systemd's `EnvironmentFile`, which
  applies to the service and not to your login shell. Either source the env file
  first (`set -a; . /etc/caddy/cloudflare.env; set +a`) or use `caddy adapt`,
  which checks syntax without provisioning modules. The message is misleading:
  it describes the empty string it received, not the file's contents.
- **`dns.hosts` is replace-not-append.** Passing only the new records wipes the
  13 existing ones, breaking every `kaermorhen.internal` name at once. Read
  first, send the union.
- **The wildcard cert covers exactly one label.** `*.kaermorhen.fyi` matches
  `jellyfin.kaermorhen.fyi` but **not** `a.b.kaermorhen.fyi`. Keep service
  names flat — this is the cost of dropping the `home.` label (§2), and it
  only bites if you later want grouped names like `arr.sonarr.…`.
- **A per-service HSTS surprise**: once a browser sees HSTS on
  `*.kaermorhen.fyi`, plain HTTP to those names is refused locally for
  the max-age even if Caddy is down. Fallback during an outage is the
  IP:port URL, which is unaffected — one more reason not to retire them.
- **Apple clients and split DNS**: `kaermorhen.fyi` is a normal public
  domain, so none of the `home.arpa` mDNSResponder pathology from
  [dns.md](../dns.md) applies. This is a second, quieter benefit of paying for
  a domain.

## 7. Cost

**~$5.66/year (~₹500)** — the `.fyi` registration, flat. Cloudflare DNS is free
and Let's Encrypt is free, so that is the whole bill.

This is the first recurring cost in the lab and the first departure from the
zero-cost preference — accepted deliberately: the alternatives were a per-device
CA install on hardware that resists it (Apple TV), or no TLS on a path that
carries logins and Obsidian's vault.

The registrar comparison that produced the choice (prices pulled from Porkbun's
public pricing API, 2026-08-09):

| TLD | Register | Renew | Note |
|---|---|---|---|
| `.fyi` | $5.66 | **$5.66** | chosen — flat, cheapest credible option |
| `.in` | $7.83 | $7.83 | flat, but the ccTLD advertises the country |
| `.cc` | $3.40 | $8.55 | |
| `.com` | $11.08 | $11.08 | |
| `.org` | $7.98 | $11.84 | |
| `.xyz` · `.cloud` · `.site` · `.co` | $1.96–15.76 | $12.98–31.20 | cheap first year, punitive renewal — avoided |

**Judge a TLD by its renewal, not its first year.** Every trap in that last row
is a cheap registration attached to a renewal 5–15× higher, and this domain is
meant to be held indefinitely.

### Why not GoDaddy's ₹99 `.in` offer

Two reasons, the second decisive:

1. `.in` renews at GoDaddy around ₹799–999 + 18% GST (**₹950–1180/yr**), versus
   ₹500 flat here. The ₹99 is first-year only.
2. **GoDaddy's DNS API is unavailable at this scale.** Since April 2024 they
   restrict the Management/DNS API to accounts holding **10+ domains** or a paid
   Discount Domain Club plan — and that API *is* the DNS-01 mechanism. Renewals
   would fail outright. Worse, with Domain Protection enabled the API can return
   success while writing empty TXT records, which fails silently.

Cloudflare Registrar is marginally cheaper still on gTLDs (at-cost, no markup),
but **does not support `.in`** — irrelevant given the final choice, and noted
only so the option isn't re-litigated later.

## 8. Open items

- **Domain: settled 2026-08-09 — `kaermorhen.fyi`, registered at Porkbun.**
  Keeps the lore name (matching this repo) while the TLD, unlike `.in`, reveals
  nothing about where the lab is. Written out in full in tracked files by
  explicit decision — see the note under the header.
- **Jellyfin published server URI — parked 2026-08-23, unresolved.** The last
  open item from §7; full state and the next experiment are recorded there.
  Everything else in this proposal is done.
- **Jellyfin HLS errors — unexplained.** Caddy's log carries **170 × 500** and
  **9 × 502** for `jellyfin.kaermorhen.fyi`, on transcoded HLS segments
  (`/videos/*/hls1/main/*.mp4`) over HTTP/3, with
  `aborting with incomplete response` in the journal. Some of that is normal
  client seeking; 170 is not. Unrelated to the published-URI issue and
  untouched — no diagnosis attempted yet.
- **Vaultwarden**, listed as an LXC candidate in
  [001 §4](001-initial-infrastructure-plan.md), would be the first service
  *built* behind the proxy rather than retrofitted. Worth doing after this.
- **Authentication** (Authelia/Tinyauth in front of the `*arr` stack) is
  deliberately out of scope. The tailnet is the current perimeter; adding SSO
  is a separate proposal once the proxy exists.
- Whether to move Ollama's proxied name behind an allowlist — an unauthenticated
  LLM API on a clean URL is easier to hit by accident than `:11434` was.
