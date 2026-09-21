# manga — acquisition + library/reader (ciri stack)

Three services on **ciri** (VM 150), live at `ciri:/data/stacks/manga/`:

| Service | Image | Port | Name |
|---|---|---|---|
| gluetun | `qmcgaw/gluetun:v3.41.3` | publishes **4567** | — |
| Suwayomi | `ghcr.io/suwayomi/suwayomi-server:v2.3.2243` | (via gluetun) | `suwayomi.kaermorhen.fyi` |
| Komga | `gotson/komga:1.27.0` | **25600** | `manga.kaermorhen.fyi` |

Mostly manga, a few western comics. Books live in the separate
[`books`](../books/README.md) stack. Design, rationale and the alternatives
that were rejected:
[proposal 011](../../../docs/proposals/011-manga-and-ebook-reading.md).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholders; the real `.env` is `chmod 600` and VM-only

## The interface between Suwayomi and Komga is a directory, not a network

Suwayomi writes CBZ files into `/mnt/manga/library`; Komga reads them. They
never speak over the network. That is what makes it possible to put Suwayomi
inside gluetun's network namespace while Komga stays on an ordinary bridge,
reachable from the LAN and the reverse proxy **even while the tunnel is down**.

## Why this shares nothing with servarr

There is no working \*arr for manga. Readarr is EOL and was removed from
`servarr` on 2026-08-24; Mylar3 and Kapowarr are ComicVine-and-indexer shaped,
built for western comics in volume form. Weekly scanlated chapters are not on
torrent or usenet indexers at all. So Prowlarr, qBittorrent, FlareSolverr and
**the hardlink contract play no part here** — nothing is imported, chapters
are written once, in place. The only things borrowed from `servarr` are the
`jaskier` service account and the habit of putting VPN-facing things in a
netns.

## VPN

`suwayomi` runs with `network_mode: "service:manga-gluetun"`, so it has no
network stack of its own: every request to a third-party manga source exits
through Proton, and if the tunnel drops it loses all connectivity
(kill-switch). Its WebUI is published on **gluetun's** port mapping, exactly
as qBittorrent's 8080 is in `servarr`.

**Komga is deliberately not behind the VPN.** It serves the LAN and the
reverse proxy and makes no outbound requests worth hiding.

**A dedicated gluetun, not servarr's.** Sharing one across stacks would need
`network_mode: container:gluetun`, which Docker does not re-establish when
gluetun is recreated — every `docker compose pull` on the VPN stack would
silently strand dependents elsewhere — and `depends_on` does not cross compose
projects. It would also put qBittorrent's tunnel inside the blast radius of a
manga deploy. The second tunnel costs ~150 MB and one Proton device slot.

**No port forwarding here**, unlike servarr. Suwayomi is outbound-only HTTP;
`PORT_FORWARD_ONLY` would restrict the exit pool to PF-capable Proton servers
for no benefit, and there is no `qbit-port-sync` equivalent to feed.

**The WireGuard key must be a second, distinct Proton config.** Reusing
servarr's private key means two live sessions on one peer and both flap.

## Where the files go

| Content | Path | In nightly PBS? |
|---|---|---|
| Manga CBZ | `/mnt/manga/library` — scsi4, 100 G zvol on `silver`, ext4 `LABEL=manga` | **no — `backup=0`** |
| Suwayomi state, extensions, DB | `./suwayomi` on `/data` | yes |
| Komga DB, thumbnails | `./komga` on `/data` | yes |

The split is deliberate. Manga is re-downloadable and 100 G of it would
inflate every nightly snapshot for nothing — the same argument that put
`ai-models` on scsi2 and torrent scratch on scsi3. But the *application state*
sits on `/data`, so losing the zvol costs a re-download and not the library
structure, the installed extensions, or what you have read.

`/mnt/media` is avoided entirely: 78% full, SMR, unbacked, and the mount whose
NFS client deadlocked ciri on 2026-09-14.

## The missing-mount guard

Both containers bind `/mnt/manga/library` with `create_host_path: false`, the
same load-bearing guard `servarr` documents at length. `/mnt/manga` is mounted
`nofail`, so if the disk is missing the *mountpoint* still exists as an empty
directory on the 64 G root disk. Without the guard, Docker's default is to
**create** the bind source and Suwayomi would download a library onto the root
filesystem until it filled. `library/` exists only on the real filesystem, so
an absent disk means the containers refuse to start — fail loud.

Never create `/mnt/manga/library` while the disk is unmounted; that puts a
stray directory on the root disk underneath the mountpoint and silently
defeats the guard.

## Auth

**Suwayomi's own basic auth is on, deliberately.** Caddy is in LXC 202 on
yennefer, so Suwayomi must publish a port on ciri's LAN address for Caddy to
reach it, and that port bypasses anything Caddy adds. Auth at the proxy would
protect the pretty URL and leave `<LAN_PREFIX>.150:4567` open to the LAN and
the tailnet. Same reasoning as proposal 008 §4 and the `shrink` stack.

Komga carries its own admin account, created on first visit to `:25600`.

## Gotchas

- **`DOWNLOAD_AS_CBZ` defaults to `false` in the Docker image**, even though
  upstream's `server.conf` default is `true` — they genuinely differ. Unset,
  Suwayomi writes loose folders of images and Komga will not index them as
  books: the stack looks deployed and produces nothing readable.
- **The variable is `AUTO_DOWNLOAD_CHAPTERS`**, not
  `AUTO_DOWNLOAD_NEW_CHAPTERS`.
- **Neither image supports PUID/PGID.** Both take an explicit
  `user: "13000:13000"` — Komga's own documentation recommends exactly this.
- **Nested bind ordering**: `./suwayomi` mounts the Tachidesk data directory
  and `/mnt/manga/library` mounts **over** its `downloads` subdirectory.
  Docker orders binds by target depth, parent first, so this resolves
  correctly — the same technique `servarr` uses to nest NVMe scratch inside
  the NFS downloads tree.
- **Komga's `/config` must be on a local filesystem**, not a network share —
  its documentation is explicit. `./komga` is ext4 on scsi1. Do not "tidy" it
  onto the media share.
- **Suwayomi's WebUI returns 401** behind basic auth, so a default Kuma HTTP
  monitor is red from birth. Give Kuma the credentials or widen the accepted
  status codes. A genuinely red Suwayomi monitor is also the tunnel alarm:
  when gluetun cannot connect, the published port stops answering.

## Learned during the build (2026-09-20/21)

- **The extension-store URL in every guide is the wrong one.** Suwayomi ships
  with no sources at all. Pasting
  `…/keiyoushi/extensions/repo/index.min.json` produces no error and exactly
  two entries — `Outdated App` and `Update to Mihon 0.20.1+` — which are
  sentinels served to clients on the old extension API. The real catalogue is
  the protobuf index already set in `EXTENSION_STORES` above (765 bytes vs
  108 KB gzipped is the tell). Confirmed working: **1,396 extensions**.
- **`AUTO_DOWNLOAD_CHAPTERS` does not backfill.** It only fires when a library
  *update* finds a chapter that did not exist before. Add a series with 900
  chapters and you get none of them — the back catalogue is a manual
  selection in the UI. The setting is not broken.
- **A healthy tunnel and a failing source look identical from the UI.**
  Cloudflare-fronted sources return `HTTP 200` for the site but an empty page
  list for a chapter, giving
  `EmptyChapterException: Chapter does not have any pages to download`.
  **Diagnosis rule: test MangaDex's API through the tunnel first**
  (`docker exec manga-gluetun wget -qO- "https://api.mangadex.org/manga?limit=1"`).
  Clean JSON there means the VPN is fine and the source is the problem —
  switch sources rather than debugging the stack. MangaFox failed this way;
  MangaDex and Weeb Central work.
- **The scary Chromium errors in the log are noise.** `dbus/bus.cc`,
  `VK_ERROR_INCOMPATIBLE_DRIVER`, `google_apis/gcm … PHONE_REGISTRATION_ERROR`
  come from the bundled headless browser (used for Cloudflare bypass)
  complaining about a system bus, GPU and Google push service that do not
  exist in a container. Harmless. Do not chase them.
- **Downloads are partitioned by source**, so the same series taken from two
  sources becomes two series in Komga with split read progress. Pick a source
  per series before bulk-downloading, and delete the old source's folder after
  a migration.
- **Komga parses Suwayomi's chapter numbers correctly** —
  `Official_Chapter 89.cbz` → `number=89` — so reading order is right. This
  was the main risk in choosing Komga's strict parser, and it held.
- **Komga's library root is `/data/mangas`, not `/data`.** Suwayomi writes
  `thumbnails/` beside `mangas/` inside the downloads directory; pointing at
  `mangas/` keeps cover art out of every scan. Verified: one series, one
  library, zero phantom entries.

## Deploy

```sh
# from the repo checkout
rsync -av configs/ciri/manga/ lab-ciri:/data/stacks/manga/
ssh lab-ciri 'cd /data/stacks/manga && cp .env.example .env && chmod 600 .env'
# fill .env: the Proton WireGuard key/address, and a Suwayomi user/password
ssh lab-ciri 'cd /data/stacks/manga && docker compose config >/dev/null'

# tunnel FIRST, alone — verify the exit IP before Suwayomi touches a source
ssh lab-ciri 'cd /data/stacks/manga && docker compose up -d manga-gluetun'
ssh lab-ciri 'docker exec manga-gluetun wget -qO- https://ifconfig.me'   # Proton IP
curl -s https://ifconfig.me                                             # must differ

ssh lab-ciri 'cd /data/stacks/manga && docker compose up -d'
```

The app directories must exist and be owned by `jaskier` before the first
`up`, or the JVMs cannot write their own databases:

```sh
mkdir -p /data/stacks/manga/{suwayomi,komga}
sudo chown -R 13000:13000 /data/stacks/manga/suwayomi /data/stacks/manga/komga
```

## Clients

Read in a browser at `manga.kaermorhen.fyi`, or on iOS with **Komic**
(App Store; offline downloads and progress sync are the paid tier, Lifetime
$22.99 — one purchase also covers the `books` stack's Kavita). **Panels** is
the better manga reader but paywalls the server connection itself and cannot
read text EPUB; **Aidoku** is free and supports Komga, Kavita *and* Suwayomi
but never reaches the App Store. Full comparison in proposal 011 §6.
