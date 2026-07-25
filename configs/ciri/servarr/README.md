# servarr — download & import stack

Automated acquisition pipeline on **ciri (VM 150)** that feeds **Jellyfin** (movies, TV).
Torrents only, routed through a **Proton VPN** kill-switch (gluetun). Live path:
`ciri:/data/stacks/servarr/`. (Audiobooks deferred — see note under Services.)

## Status — as-built (2026-07-25)

Deployed and serving TV + Movies. Verified:

- **Kill-switch ✓** — qBittorrent runs in gluetun's netns (`NetworkMode: container:<gluetun>`);
  its observed public IP is the Proton VPN IP (Amsterdam), **not** the home IP; gluetun's
  firewall is default-deny (`-P OUTPUT DROP`) with egress only via `tun0` + the WireGuard
  endpoint, so a tunnel drop can't leak torrent traffic. Full stop-the-tunnel test is a
  write action — see "Verify the kill-switch" in the runbook.
- **Hardlinks ✓** — imports hardlink (verified: a Rick and Morty S09 episode shares one
  inode across `/data/downloads/complete/…` and `/data/library/tv/…`, link count 2, `664`,
  owned by `jaskier`). `/data` is a single virtiofs filesystem.
- **Indexers** — 1337x (via FlareSolverr proxy) + The Pirate Bay. **Root folders** set:
  Sonarr `/data/library/tv`, Radarr `/data/library/movies`. Prowlarr app-sync live.
- **FlareSolverr ✓** up on `:8191`.

**Proton port forwarding — `qbit-port-sync` sidecar, verified working 2026-07-26** (replaces
the non-durable one-shot up-command). Requires qBittorrent's **"Bypass authentication for
clients on localhost" = ON** (step 6). Sidecar corrected 2026-07-26 for the gluetun-v3.5
endpoint move (`/v1/portforward`) and to never push port `0`; confirmed end-to-end (gluetun
forwarded port == qBit live `listen_port` via API, `connection_status: connected`). Note:
**Proton PF is intermittent server-side** — the forwarded port periodically drops to 0
(NAT-PMP refused) until gluetun reconnects to a working server; the sidecar holds qBit's last
good port meanwhile (see Caveats for the manual reconnect).

## Services

| Service | Image tag | URL (from LAN) | Role |
|---|---|---|---|
| gluetun | `qmcgaw/gluetun:v3.41.1` | — | Proton WireGuard egress + kill-switch + port-forward |
| qbittorrent | `lscr.io/linuxserver/qbittorrent:version-5.2.3_v2.0.13` | `http://<CIRI_IP>:8080` | Torrent client (inside gluetun's netns) |
| qbit-port-sync | `alpine:3.21` | — | Applies gluetun's rotating Proton forwarded port to qBittorrent (in gluetun's netns) |
| prowlarr | `lscr.io/linuxserver/prowlarr:version-2.5.2.5491` | `http://<CIRI_IP>:9696` | Indexer manager (feeds all *arr) |
| sonarr | `lscr.io/linuxserver/sonarr:version-4.0.19.2979` | `http://<CIRI_IP>:8989` | TV |
| radarr | `lscr.io/linuxserver/radarr:version-6.3.0.10514` | `http://<CIRI_IP>:7878` | Movies |
| bazarr | `lscr.io/linuxserver/bazarr:version-v1.6.0` | `http://<CIRI_IP>:6767` | Subtitles for Sonarr/Radarr |
| jellyseerr | `fallenbagel/jellyseerr:2.7.3` | `http://<CIRI_IP>:5055` | Request UI |
| flaresolverr | `ghcr.io/flaresolverr/flaresolverr:v3.5.0` | `http://<CIRI_IP>:8191` | Cloudflare solver for Prowlarr indexers |

**Audiobooks deferred:** Readarr was removed — it is EOL (frozen at 0.4.18) and its old
WebUI login can't authenticate to qBittorrent 5.x. Audiobooks (Readarr replacement +
Audiobookshelf) will be revisited separately; this stack is TV + Movies only for now.

`<CIRI_IP>` = `<LAN_PREFIX>.150`. Tags verified current 2026-07-24; bump deliberately.

## The hardlink contract (why it's built this way)

Every *arr **and** qBittorrent bind the same host dir `/mnt/media` at `/data`. Downloads
land in `/data/downloads`, imports go to `/data/library/{movies,tv,audiobooks}`. Both are
on **one ext4 filesystem** (geralt's USB HDD via virtiofs), so `*arr` imports are instant
**hardlinks** — the file exists in both `downloads/` (still seeding) and `library/`
(Jellyfin/ABS see it) sharing one inode, using zero extra bytes. This matters: the disk is
USB-2.0-limited (~40 MB/s) and copying every import would be painfully slow and double the
space. **Never** split downloads and library into separate mounts — that silently reverts
to copy mode.

```
Prowlarr ─(indexers, via FlareSolverr for CF sites)→ Sonarr / Radarr / Jellyseerr(requests)
                              │ grab → qBittorrent API (http://gluetun:8080)
                              ▼
        qBittorrent ─netns→ gluetun ─WireGuard+PF→ Proton VPN → internet
                              │ completes → /data/downloads/complete/…
                              ▼  *arr hardlink-import → /data/library/{movies,tv}
                    Jellyfin (/media)   Bazarr (subs)
```

---

## Permissions model (least privilege)

No app has root write access to the media location. Writers run as one dedicated
non-root service account; readers are read-only.

| App | Runs as | `/mnt/media` access | Scope |
|---|---|---|---|
| qBittorrent | `jaskier` (13000) | **rw** | `downloads/` **only** (no library) |
| Sonarr / Radarr | `jaskier` (13000) | **rw** | full tree (import: read `downloads/`, hardlink into `library/`) |
| Bazarr | `jaskier` (13000) | **rw** | writes subtitle sidecars into `library/` |
| Prowlarr / Jellyseerr / FlareSolverr / qbit-port-sync | n/a | **none** | never touch media (indexers / requests / CF-solver / port-sync only) |
| Audiobookshelf | root process | **ro** | `library/audiobooks` read-only — cannot modify media |
| Jellyfin | root process | **ro** (recommended, step 1a) / rw (current) | `library` — read-only removes its only root-write on media |

- **`jaskier` (uid/gid 13000) is a dedicated account** (system, no login, no home),
  separate from the human `ciri` user (1000) and from root — a compromised download client
  can only reach what `jaskier` owns (the media tree), nothing of yours.
- **qBittorrent can't see the library at all** — even fully compromised it can only write
  under `downloads/`.
- **Readers are read-only** — Jellyfin/Audiobookshelf physically cannot delete or alter
  library files even though their process is root.
- Files land `664`, dirs `2775` (setgid) via `UMASK=002` + the setgid bit, so every writer
  in group `jaskier` (13000) can manage each other's imports and root readers can still read.

---

## First-time deploy runbook

> Convention: **you run all write/`docker` commands** (on ciri via `ssh lab-ciri`);
> Claude only runs read-only checks. `qm` commands run on **geralt** (`ssh lab-geralt`).
> Steps marked ⚙️ change system state — run them yourself.

### 0. (Recommended first) Give ciri more RAM — 8 GB → 10 GB
ciri at 8 GB has only ~4 GB free and this stack adds ~1.7–2 GB active (Immich ML can also
spike 1–2 GB). geralt (16 GB) has room: ~2 GB free + 8 GB swap, ARC pinned at 2 GB.
Bumping ciri to 10 GB leaves geralt ~2 GB host headroom (the safe floor; 11 GB is the hard
ceiling). Memory hot-plug isn't enabled, so this needs a reboot of ciri:

```bash
# ⚙️ on ciri: stop stacks cleanly first (optional but tidy)
ssh lab-ciri 'cd /data/stacks/jellyfin && docker compose stop'   # etc. for each, or just shut down
# ⚙️ on geralt:
ssh lab-geralt 'qm shutdown 150 && sleep 20 && qm set 150 --memory 10240 && qm start 150'
```
Verify: `ssh lab-geralt 'qm config 150 | grep memory'` → `memory: 10240`, then
`ssh lab-ciri 'free -h'`. If you'd rather defer, deploy **core-first** (gluetun,
qbittorrent, prowlarr, sonarr, radarr) and add bazarr/jellyseerr/flaresolverr later.

### 1. ⚙️ Create the `jaskier` service account, subdirectories, and ownership (on ciri)
The writers run as a **dedicated non-root, non-login account `jaskier` (uid/gid 13000)** —
the bard of the lab, fitting for a media/entertainment stack; not root, not your `ciri`
user. `/mnt/media/*` is currently `root:root`, so create the account and hand it the tree:
```bash
# dedicated service account: no home, no login shell (uid 13000 is above the
# system range, so no -r — that flag only warns and changes nothing here)
ssh lab-ciri 'sudo groupadd -g 13000 jaskier 2>/dev/null; sudo useradd -u 13000 -g 13000 -M -s /usr/sbin/nologin jaskier 2>/dev/null; id jaskier'
# directories
ssh lab-ciri 'sudo mkdir -p /mnt/media/downloads/{incomplete,complete} /mnt/media/library/audiobooks'
# own the tree to the service account
ssh lab-ciri 'sudo chown -R 13000:13000 /mnt/media/downloads /mnt/media/library'
# dirs: rwx owner+group, r-x others (so a root-run reader like Jellyfin can read);
# setgid so imports keep gid 13000. Files become 664 via the containers' UMASK=002.
ssh lab-ciri 'sudo find /mnt/media/downloads /mnt/media/library -type d -exec chmod 2775 {} +'
```
Now the writers (uid 13000) own downloads + library and can create/hardlink/delete;
readers get through as follows: **Audiobookshelf** mounts read-only; **Jellyfin** either
mounts read-only (recommended — see step 1a) or, if left as-is, reads fine as root over the
`o+rx` dirs. No app needs root *write* on the media location.

### 1a. ⚙️ (Recommended) Make Jellyfin read-only on the media location
Jellyfin currently binds `/mnt/media/library` **read-write** and runs as **root** — the one
app with root write access to media, added 2026-07-23 so its OpenSubtitles plugin could
save `.srt` sidecars. **Bazarr (uid 13000) now owns subtitles**, so Jellyfin no longer needs
to write. To close it: in `configs/ciri/jellyfin/compose.yaml` re-add `read_only: true` to
the `/media` bind, redeploy Jellyfin, and in the Jellyfin UI turn OFF the OpenSubtitles
plugin's "save alongside media" (or disable the plugin) so Bazarr is the single subtitle
writer. See the Jellyfin README's "Why the media bind is read-write" section for the
original trade-off. *(Confirm before doing this — it changes that documented decision.)*

### 2. ⚙️ Stage the stack files (on ciri)
```bash
# copy compose.yaml + .env.example from this repo into the live stack dir
ssh lab-ciri 'mkdir -p /data/stacks/servarr'
scp configs/ciri/servarr/compose.yaml     lab-ciri:/data/stacks/servarr/
scp configs/ciri/servarr/.env.example     lab-ciri:/data/stacks/servarr/
ssh lab-ciri 'cd /data/stacks/servarr && cp -n .env.example .env && chmod 600 .env'
```

### 3. ⚙️ Fill in `.env` (on ciri) — Proton WireGuard key
In the **Proton VPN portal → Downloads → WireGuard**: create a NEW config with
**NAT-PMP (Port Forwarding) ON** and a **P2P** server, then put its `PrivateKey` into
`PROTON_WG_PRIVATE_KEY` and its `Address` into `WIREGUARD_ADDRESSES` (Proton standard is
`10.2.0.2/32`). Edit with `ssh lab-ciri` + your editor, or edit locally and re-scp.

### 4. ⚙️ Bring it up (on ciri)
```bash
ssh lab-ciri 'cd /data/stacks/servarr && docker compose config >/dev/null && docker compose up -d'
ssh lab-ciri 'cd /data/stacks/servarr && docker compose logs -f gluetun'   # watch tunnel + "port forwarded"
```

### 5. Validate the kill-switch (mandatory before adding any torrent)
Read-only checks (qBittorrent is alpine → use `wget`, not `curl`; qBit shares gluetun's
netns so its public IP == the VPN's):
```bash
# home/host public IP (baseline, NOT via VPN):
ssh lab-ciri 'curl -s http://checkip.amazonaws.com'
# VPN public IP + forwarded port (gluetun control server):
ssh lab-ciri 'docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/publicip/ip; echo; docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/openvpn/portforwarded; echo'
# qBittorrent's OWN observed public IP — MUST equal the VPN IP, never the home IP:
ssh lab-ciri 'docker exec qbittorrent wget -qO- http://checkip.amazonaws.com; echo'
# gluetun firewall — expect default DROP + egress only via tun0/WG endpoint (the kill-switch):
ssh lab-ciri 'docker exec gluetun iptables -S'
```
Full leak test (⚙️ write action — stops a container): with the tunnel down, qBittorrent
must lose all connectivity, proving no fall-back to the home line:
```bash
⚙️ ssh lab-ciri 'docker stop gluetun'
   ssh lab-ciri 'docker exec qbittorrent wget -qO- --timeout=8 http://checkip.amazonaws.com; echo "exit=$?"'   # must TIME OUT / fail
⚙️ ssh lab-ciri 'docker start gluetun'   # then: docker restart qbittorrent (re-attaches to the netns)
```

### 6. qBittorrent first-run
- Get the temporary admin password: `ssh lab-ciri 'docker logs qbittorrent | grep -i password'`.
- Open `http://<CIRI_IP>:8080`, log in, **set a real password**.
- Tools → Options → **Web UI → tick "Bypass authentication for clients on localhost"**
  (**required** — lets the `qbit-port-sync` sidecar set the forwarded listen port without creds).
- Downloads: default save path `/data/downloads/complete`, incomplete `/data/downloads/incomplete`,
  keep incomplete in that separate folder.

### 7. Prowlarr → *arr wiring (TV + Movies)
- **Apps**: Prowlarr (`:9696`) → Settings → Apps → add **Sonarr** (`http://sonarr:8989`) and
  **Radarr** (`http://radarr:7878`), pasting each app's API key (its Settings → General →
  Security). Prowlarr then pushes indexers to both.
- **FlareSolverr proxy** (for Cloudflare-protected indexers): Prowlarr → Settings → Indexers
  → **Proxies** → `+` → **FlareSolverr**, Host `http://flaresolverr:8191`, Tags e.g.
  `flaresolverr`. Then on each indexer that needs it (e.g. 1337x), add the same tag so
  Prowlarr routes it through the solver. Cloudflare-free indexers (TPB, YTS, EZTV) need no tag.
- **Indexers**: Prowlarr → Indexers → Add Indexer → pick sites (start with public torrent
  ones: The Pirate Bay, YTS for movies, EZTV for TV; add 1337x once the proxy is set). Test → Save.
- **Download client**: in Sonarr/Radarr → Settings → Download Clients → add **qBittorrent**,
  host `gluetun`, port `8080` (qBit lives in gluetun's netns — address it by the gluetun
  container name), your qBit login. Test → Save.
- **Root folders**: Sonarr `/data/library/tv`, Radarr `/data/library/movies`
  (Settings → Media Management → Root Folders). Confirm the app reports hardlinking is possible.

### 8. Jellyseerr (`:5055`) & Bazarr (`:6767`)
- Jellyseerr: sign in with Jellyfin — point it at Jellyfin `http://<CIRI_IP>:8096` (cross-network,
  use the IP not the container name), then connect Radarr `http://radarr:7878` and
  Sonarr `http://sonarr:8989`.
- Bazarr: Settings → connect Sonarr `http://sonarr:8989` and Radarr `http://radarr:7878`;
  add subtitle providers (OpenSubtitles etc.) and languages. Complements Jellyfin's own
  OpenSubtitles plugin — pick one as primary to avoid duplicate sidecars.

### 9. Verify a real hardlink import
Grab one small item in Sonarr/Radarr. After it imports:
```bash
ssh lab-ciri 'docker exec sonarr sh -c "find /data/downloads/complete -type f | head -1 | xargs ls -li; echo ---; find /data/library/tv -type f | head -1 | xargs ls -li"'
```
The download and the library copy should show the **same inode** and **link count ≥ 2** →
hardlink confirmed (not a copy). Then Jellyfin → the library → **Scan Library Files**.

---

## Integrate with the rest of the lab
- **DNS** (edit **pihole-1 / LXC 101 only**; nebula-sync mirrors to pihole-2 hourly): add
  A-records → `<LAN_PREFIX>.150` for the UIs you want named, e.g.
  `prowlarr / sonarr / radarr / qbittorrent / jellyseerr.kaermorhen.internal`.
- **Uptime-Kuma** (LXC 104): 7 monitors added 2026-07-26 (full table in
  [uptime-kuma.md](../../../docs/uptime-kuma.md)) — HTTP-Keyword on the `/ping` endpoints for
  prowlarr/sonarr/radarr, keyword checks for bazarr/jellyseerr/flaresolverr, and a plain HTTP
  check on qbittorrent `:8080` that **doubles as gluetun liveness**. `gluetun` and
  `qbit-port-sync` have no LAN HTTP endpoint — covered by Beszel. These are **liveness only**:
  they can't see a VPN leak or port-forwarding stuck at 0 — a functional "servarr VPN health"
  push monitor is a tracked next item ([uptime-kuma.md](../../../docs/uptime-kuma.md) Next steps).
- **Beszel**: agents inside ciri, so all 9 servarr containers appear automatically with
  per-container CPU/mem/net.
- **Backups:** these `./config` dirs live on ciri's `/data` disk → already covered by the
  nightly PBS `--all` job. The media on `/mnt/media` stays unbacked/disposable by design.

## Caveats
- **USB 2.0 ~40 MB/s, shared** with Jellyfin reads. In qBittorrent cap the global rate and
  max active torrents so a big download can't starve a live transcode. Disk is
  **disposable** — a drop means re-download.
- **Proton dynamic port (handled by `qbit-port-sync`)**: Proton assigns a forwarded port and
  **rotates** it. The `qbit-port-sync` sidecar (in gluetun's netns) polls gluetun's control
  API every 30s and, on change, sets qBittorrent's listen port via
  `POST 127.0.0.1:8080/api/v2/app/setPreferences`. Two gluetun-v3.5 gotchas baked into the
  sidecar: (1) the endpoint is **`GET /v1/portforward`** — the old `/v1/openvpn/portforwarded`
  now 301-redirects there and busybox `wget` won't follow it; (2) it **never pushes `0`** —
  see the Proton PF note below. The POST is accepted unauthenticated **only** because it comes
  from localhost, so qBittorrent **must** have "Bypass authentication for clients on localhost"
  ON (step 6), else the sidecar logs a retry. Verify it took:
  ```bash
  ssh lab-ciri 'docker exec gluetun wget -qO- http://127.0.0.1:8000/v1/portforward; echo'   # {"port":NNNNN}
  # qBit's LIVE listen port — read the API, NOT qBittorrent.conf (Session\Port is only
  # flushed to the conf on shutdown, so the file reads empty/stale while running):
  ssh lab-ciri 'docker exec qbittorrent wget -qO- http://127.0.0.1:8080/api/v2/app/preferences | grep -o "\"listen_port\":[0-9]*"'   # should MATCH
  ssh lab-ciri 'docker logs --tail 5 qbit-port-sync'
  ```
- **Proton PF is intermittent (server-side)**: gluetun sometimes logs
  `ERROR [port forwarding] adding port mapping: … 10.2.0.1:5351: connection refused/timeout`
  and the forwarded port goes to **0** — the connected Proton server stopped honouring
  NAT-PMP. The sidecar rides this out (keeps qBit's last good port instead of zeroing it), and
  a fresh port is applied automatically once gluetun forwards one again. If it stays stuck at 0
  for long, reconnect onto a working PF server:
  ```bash
  ⚙️ ssh lab-ciri 'docker restart gluetun && sleep 8 && docker restart qbittorrent'
  ```
  (Restart qBittorrent after gluetun — it must re-attach to the fresh netns; the sidecar
  recovers on its own.)
- **qBittorrent addressed as `gluetun`**: because it shares gluetun's network namespace it
  has no hostname of its own — always point the *arr at `gluetun:8080`, never `qbittorrent:8080`.
- **FlareSolverr** is only needed for Cloudflare-protected indexers; it's stateless (no
  media, no `/config`). If an indexer test fails with a Cloudflare/challenge error, tag it to
  route through the FlareSolverr proxy.
- **Audiobooks are deferred**: Readarr was removed (EOL, can't auth to qBittorrent 5.x). When
  revisited, audiobooks will use a maintained grabber + the separate `audiobookshelf` stack.
