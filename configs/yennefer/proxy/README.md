# proxy — Caddy reverse proxy (LXC 202 on yennefer)

**Status: partially built 2026-08-12.** LXC 202 is running Caddy with a
production wildcard cert for `*.kaermorhen.fyi`, smoke-tested end-to-end on
`memos.kaermorhen.fyi`. The `Caddyfile` here is the full target config — the
live file currently serves memos only. Design, rationale and full runbook:
[docs/proposals/003-reverse-proxy.md](../../../docs/proposals/003-reverse-proxy.md).

Gives every web service a name instead of a port —
`https://jellyfin.kaermorhen.fyi` instead of `<LAN_PREFIX>.150:8096` —
identically on the LAN and over Tailscale.

## Files

| File | Live location | Notes |
|---|---|---|
| `Caddyfile` | `202:/etc/caddy/Caddyfile` | scp back here verbatim after any change |
| `.env.example` | `202:/etc/caddy/cloudflare.env` | real file chmod 600, holds the Cloudflare API token |

Unlike the ciri stacks this is not a compose stack — Caddy runs as a systemd
service from the official apt repo. The mirror rule from `CLAUDE.md` applies
the same way.

## How it works

1. Pi-hole answers `<app>.kaermorhen.fyi` with `<LAN_PREFIX>.202`
   (explicit A records in pihole-1's `dns.hosts`, synced to pihole-2 by
   nebula-sync).
2. Caddy terminates TLS on `.202` using a single wildcard
   `*.kaermorhen.fyi` certificate from Let's Encrypt, and dispatches on
   the `Host` header to the right backend `IP:port`.
3. The certificate is obtained and renewed over **DNS-01** — a TXT record
   written through the Cloudflare API. No inbound port forward exists, and
   nothing here is reachable from the internet.
4. Remotely, the same names resolve through `tailscale-1`'s subnet route once
   `kaermorhen.fyi` is added to the tailnet's split-DNS list.

The old `<IP>:<port>` URLs keep working and are the fallback whenever the proxy
or yennefer is down — don't retire them.

## Common operations

```bash
pct enter 202

caddy adapt --config /etc/caddy/Caddyfile       # syntax check, no token needed
systemctl reload caddy                          # zero-downtime

# Full validation needs the token in THIS shell — systemd's EnvironmentFile
# applies to the service only, so a bare `caddy validate` reports
# "API token '' appears invalid" even when the file is perfect.
set -a; . /etc/caddy/cloudflare.env; set +a
caddy validate --config /etc/caddy/Caddyfile
journalctl -u caddy -f                          # cert issuance / renewal
caddy list-modules | grep cloudflare            # plugin still present?
```

## Adding a service

1. Add a `@name host …` + `handle` pair to the `Caddyfile`, validate, reload.
2. Add an A record → `<LAN_PREFIX>.202` on **pihole-1 only**, passing the
   *whole* `dns.hosts` array (`pihole-FTL --config` replaces, never appends).
3. Force the sync: `docker compose -f /data/stacks/nebula-sync/compose.yaml
   run --rm sync-now` on ciri.
4. scp the Caddyfile back into this repo.

No new certificate is needed — the wildcard already covers it.

## Gotchas

- **`apt upgrade` drops the DNS plugin.** The apt package ships the stock Caddy
  binary; `caddy add-package github.com/caddy-dns/cloudflare` replaced it with
  a custom build. Re-run that command after every Caddy upgrade and confirm
  with `caddy list-modules`. If you don't, renewals fail roughly 30 days later
  with "no solvers available" — far enough from the upgrade to be baffling.
- **The wildcard covers one label only.** `*.kaermorhen.fyi` matches
  `sonarr.kaermorhen.fyi` but **not** `a.b.kaermorhen.fyi`. Keep service
  names flat — one label, no dots inside them.
- **Host-header-sensitive backends** (qBittorrent, Ollama) need
  `header_up Host {upstream_hostport}`; without it qBit returns a blank page
  and Ollama 403s. Already set in the `Caddyfile`.
- **Upload-heavy backends** (Immich, Paperless, CouchDB) need
  `request_body { max_size 0 }` or large uploads fail at Caddy's default limit.
- **Some apps need their own config updated** to trust the new hostname —
  `PAPERLESS_URL` for Paperless, allowed-hosts for Sure, Known Proxies for
  Jellyfin. Full list in the proposal, §7.
