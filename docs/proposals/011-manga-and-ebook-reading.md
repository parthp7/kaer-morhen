# Proposal 011 — Manga + ebooks: Suwayomi + Komga + Kavita on ciri

- **Status**: **IN PROGRESS — Phases A and B complete, 2026-09-21.**
  Phase A: scsi4 zvol added, ext4 `LABEL=manga`, mounted `/mnt/manga`,
  confirmed excluded from the nightly PBS job; hotplug worked, so **ciri was
  never restarted**. Phase B: gluetun, Suwayomi and Komga all up; **E1–E5 and
  part of E10 pass** (Secure Core exit verified, no IPv6 leak, 83 CBZ on the
  zvol, one Komga series with chapter numbers parsed, both web UIs demanding
  their own login). **All five §10 unknowns are now resolved**, and six new
  gotchas the design did not predict are recorded as items 11–16 — three of
  them (the extension-store sentinel trap, auto-download not backfilling, and
  Cloudflare page-fetch failures) each cost a diagnosis during the build.
  Remaining: Phase C (books), D (proxy/DNS/Kuma), and tests E7, E9, E11–E14.
  **E14, the missing-mount guard, is the one not to skip.**
- **Date**: 2026-09-20
- **Scope**: one new zvol on ciri (**scsi4**, 100 G, `silver`, `backup=0`);
  two new compose stacks — **`manga`** (gluetun + Suwayomi + Komga) and
  **`books`** (Kavita); three Caddy routes; three Pi-hole records; three Kuma
  monitors; three Homepage tiles. **No existing stack is touched.** In
  particular `servarr` is not modified, restarted, or read from, and nothing
  goes near `/mnt/media`, the USB disk, or the NFS mount.
- **Decisions taken up front (2026-09-20)**: Suwayomi for acquisition, by user
  choice (§2); **three servers rather than one**, split manga/books, because
  no single server is best at both and the split is what the user wants
  ergonomically (§2); **a dedicated gluetun rather than sharing servarr's**
  (§5) — the user offered to restructure servarr and the offer was declined
  with reasons; manga on a `backup=0` zvol but **books on `/data` inside the
  nightly PBS job**, because only one of the two is re-downloadable (§4);
  Komic as the iOS client, one paid app covering both servers (§6).

Addresses use `<LAN_PREFIX>` per `CLAUDE.md` and the last-octet convention from
[network.md](../network.md). `kaermorhen.fyi` is written in full, as decided in
[proposal 003](003-reverse-proxy.md).

---

## 0. Execution contract (read first if you are the agent running this)

- **The human runs every command that changes state.** The agent hands over
  exact commands, then verifies with read-only checks (`docker ps`, `curl`,
  `qm config`, `df`). Same contract as proposals 005–010.
- **Order matters across phases**: A (storage) → B (manga stack) → C (books
  stack) → D (proxy, DNS, Kuma) → E (verify) → F (mirror). Inside a phase,
  steps are independent unless a step says otherwise.
- **Phase A is the only phase that can disturb a running service**, and only
  if disk hotplug turns out not to work (§10 item 5). Read that item before
  running A1. Phases B–F add containers and config and touch nothing existing.
- **Rollback**: `docker compose down` in each stack dir removes everything;
  `qm set 150 --delete scsi4` (after unmounting and removing the fstab line)
  removes the disk; revert the three Caddyfile blocks and the three
  `dns.hosts` entries. No other host state changes at all.
- **Do not publish the routes before the containers answer.** Proposal 003 §3
  records what a permanently-502 name costs: it trains you to ignore a red
  check. Phase D comes after B and C for that reason.
- **Do not let Suwayomi touch a source before E1–E3 pass.** The entire point
  of §5 is that no request to a third-party manga host ever leaves on the home
  IP. Verify the tunnel first, browse second.

## 1. The requirement

From the 2026-09-20 session: *"I want to setup a manga/comics stack on ciri"*,
mostly manga with a few western comics, plus EPUB books; *"I would want to
download chapters before travel to read in poor connectivity"*; and
*"separating my books and manga collection helps get in zone"*.

| Requirement | Verdict | How |
|---|---|---|
| Manga library + reader, mostly manga with a few comics | **Kept — hard** | Komga: automatic RTL (manga), vertical webtoon, LTR (comics) detection; 1 folder = 1 series (§2) |
| **Offline download before travel**, poor connectivity | **Kept — hard** | Komic on iOS downloads and syncs progress against both servers (§6). This is a *client* capability — see §2 |
| EPUB books, kept visually separate from manga | **Kept — hard** | Kavita as a second, books-only server: separate URL, separate icon (§2) |
| Acquisition via Suwayomi | **Kept — user decision** | Mihon extension engine, auto-download new chapters as CBZ (§3) |
| VPN egress | **Kept — hard** | Dedicated gluetun; Suwayomi in its netns, kill-switch inherited (§5) |
| Storage on `silver` | **Kept — user decision** | 100 G zvol, scsi4, `backup=0` (§4) |
| Native iOS app | **Kept — softened** | Komic is native and on the App Store, but offline + sync are a paid tier. The only free client never reaches the App Store (§6) |
| More containers if better design | **Kept** | Four containers, two stacks |
| Best-in-class ebook *manager* (Calibre-Web-Automated) | **Deferred** | Fails the offline requirement on iPhone (§9). Revisit as a management layer behind Kavita |
| Books protected against loss | **Added** | Books on `/data`, already in nightly PBS; manga deliberately not (§4) |

**Explicitly out of scope**: any change to `servarr`, `/mnt/media`, the USB
disk, the NFS mount, or Jellyfin; ebook *acquisition* (books are added by
hand).

## 2. Why three servers, not one

Manga does not fit the existing pipeline at all, and the reason is worth
stating because it looks like it should. **There is no working \*arr for
manga.** Readarr is EOL and was removed from `servarr` on 2026-08-24; Mylar3
(last release 2025-08-17) and Kapowarr are ComicVine-and-indexer driven, built
for western comics in volume form. Weekly scanlated chapters do not live on
torrent or usenet indexers. So Prowlarr, qBittorrent, FlareSolverr and **the
hardlink contract play no part here** — nothing is imported, chapters are
written once, in place. This stack shares no machinery with `servarr` beyond
the `jaskier` service account and the habit of putting VPN-facing things in a
netns.

That leaves two jobs — acquisition and reading — and reading splits again.

**Acquisition: Suwayomi.** It is the Mihon/Tachiyomi extension engine running
as a server: hundreds of sources, library tracking, automated update checks,
and auto-download of new chapters. The alternative considered was Tranga
(§9), which is simpler and talks to Komga natively but carries its own small
connector set instead of the whole extension ecosystem. User chose Suwayomi.

**Reading, manga: Komga.** With ebooks handled elsewhere, Komga's only
weakness disappears and every remaining strength is one this library needs:
automatic reading-mode detection (RTL for manga, vertical scroll for webtoons,
LTR for the western comics), intelligent double-page spread handling, strict
*1 folder = 1 series* structure that matches the shape Suwayomi writes, and
the most stable API in the category. Kavita matches the reading modes but you
configure them, and its filename parser — the flexible one — is exactly the
thing that trips over scanlation-group naming.

**Reading, books: Kavita.** Not Komga, and not Calibre-Web-Automated. Komga's
EPUB support is built around **Kobo sync**, which does nothing for an iPhone.
CWA is the better *manager* by a distance — auto-ingest, format conversion,
metadata fetching, send-to-Kindle — but its only offline path to iOS is OPDS,
and **OPDS hands over a file rather than streaming pages, so reading position
stays on the phone and never returns to the server**. That fails the one hard
requirement. Kavita is the only one of the three with a native iOS client that
downloads text EPUB *and* syncs progress back.

**The offline requirement is satisfied by the client, not the server.** No
server pushes anything to a phone. What the server choice actually decides is
*which clients can sync progress back* — and that is what rules CWA out and
Kavita in. §6 covers the client.

The split also matches how the user wants to use it: two URLs, two app
entries, no manga in the book app.

## 3. Target architecture

```
                        ciri (VM 150, <LAN_PREFIX>.150)

  stack: manga                                      stack: books
  ┌──────────────────────────────────────┐          ┌────────────────────┐
  │ manga-gluetun   Proton WireGuard     │          │ kavita      :5000  │
  │      └ suwayomi  (shares this netns, │          │   reads ↓          │
  │         no ports of its own)         │          └────────────────────┘
  │         publishes :4567              │                    │
  │                                      │                    │
  │ komga           :25600  (own bridge) │                    │
  └──────────────────────────────────────┘                    │
            │ writes CBZ       │ reads (ro)                   │ reads (ro)
            ▼                  ▼                              ▼
      /mnt/manga/library                              /data/books
      scsi4 · 100 G · silver · backup=0               scsi1 · in nightly PBS

  Caddy (LXC 202) ──► manga.kaermorhen.fyi    → <LAN_PREFIX>.150:25600
                      books.kaermorhen.fyi    → <LAN_PREFIX>.150:5000
                      suwayomi.kaermorhen.fyi → <LAN_PREFIX>.150:4567
```

**Suwayomi and Komga never talk over the network.** Suwayomi writes CBZ files;
Komga reads them. A shared filesystem is the entire interface between them.
That is what makes it possible to put Suwayomi inside a kill-switch netns
while Komga stays on an ordinary bridge, reachable from the LAN and the
reverse proxy even when the tunnel is down.

**Two stacks, not one.** `manga` and `books` are separate compose projects per
the `CLAUDE.md` self-contained rule. A gluetun reconnect, a Suwayomi restart
or a full `docker compose down` on the manga stack cannot take the book server
with it — and the user's separation preference becomes structural rather than
cosmetic.

## 4. Where the files actually go

| Content | Path | Backing | In nightly PBS? |
|---|---|---|---|
| Manga CBZ | `/mnt/manga/library` | scsi4, 100 G zvol on `silver`, ext4 `LABEL=manga` | **no — `backup=0`** |
| EPUB books | `/data/books` | scsi1 (existing) | **yes** |
| Suwayomi state, extensions, DB | `/data/stacks/manga/suwayomi` | scsi1 | yes |
| Komga DB, thumbnails | `/data/stacks/manga/komga` | scsi1 | yes |
| Kavita DB, covers | `/data/stacks/books/kavita` | scsi1 | yes |

**The split backup posture is the point, not an oversight.** Manga is
re-downloadable from source in an afternoon, and 100 G of it would inflate
every nightly snapshot for nothing — the same argument that put `ai-models`
on scsi2 and torrent scratch on scsi3, both `backup=0`. Books are
hand-curated and are *not* re-downloadable; they belong with photos in the
"irreplaceable" category, so they live on `/data`, which the nightly job
already covers. **No new backup machinery is needed for either** — which is
the main reason books are not simply dropped onto the new zvol.

The application state for all three servers is small and sits on `/data`, so
reading progress, library metadata and installed Suwayomi extensions are all
inside the nightly job even though the manga files are not. Losing the zvol
costs re-downloading; it does not cost the library structure or what you have
read.

**`/mnt/media` is avoided entirely.** It is 78% full (204 G free), SMR, carries
no backup by design, and is the mount whose NFS client deadlocked ciri on
2026-09-14 (`nfs4_begin_drain_session`). Putting a second write-active
workload behind it would be a choice to repeat that. The new zvol adds no NFS
surface at all — it is a local ext4 filesystem on NVMe, which also makes
Komga's cover extraction and library scans fast.

**Growth path**: 100 G is a starting size, not a ceiling. If it pinches,
`qm resize 150 scsi4 +50G` then `resize2fs /dev/disk/by-label/manga` — online,
no restart. `silver` has 337 G free today. If manga ever outgrows what is
reasonable on NVMe, `steel` is a 1 TB CMR pool sitting at 0% used and
designated for bulk payloads, at the cost of a second NFS export.

### The missing-mount guard

Both containers bind `/mnt/manga/library` with `create_host_path: false`. This
is the same load-bearing guard the `servarr` stack documents at length, for
the same reason. `/mnt/manga` is mounted `nofail`, so if the disk is missing
the *directory* still exists as an empty mountpoint on the 64 G root disk.
Without the guard Docker's default is to **create** the bind source, and
Suwayomi would cheerfully download a library onto the root filesystem until it
filled. `library/` exists only on the real filesystem, so an unmounted disk
means the containers refuse to start — fail loud, not silently wrong.

## 5. VPN egress

Suwayomi makes outbound requests to third-party manga sources. Those exit
through Proton or they do not happen:

- `suwayomi` runs with `network_mode: "service:manga-gluetun"`, so it has no
  network stack of its own. If the tunnel drops, it loses all connectivity —
  kill-switch, no home-IP leak. Its WebUI is published on **gluetun's** port
  mapping (4567), exactly as qBittorrent's 8080 is published on servarr's
  gluetun.
- **Komga and Kavita are deliberately NOT behind the VPN.** They serve the LAN
  and the reverse proxy and must stay reachable when the tunnel is down. They
  make no outbound requests worth hiding.

### A dedicated gluetun, and why servarr was not restructured

The user offered to extract gluetun + qBittorrent from `servarr` into a shared
stack. That offer was declined on 2026-09-20, for four specific reasons:

1. **Cross-stack netns sharing is brittle.** Stack-to-stack requires
   `network_mode: container:gluetun`, not `service:`. Docker does **not**
   re-establish that binding when gluetun is recreated, so every
   `docker compose pull` on the VPN stack would silently strand dependents in
   every other stack until each was manually restarted.
2. **`depends_on` does not cross compose projects** — no startup ordering
   guarantee, on a boot where ordering is exactly what you want.
3. **Blast radius.** It would put qBittorrent's tunnel inside the failure
   domain of a manga deploy, and the gluetun/qBittorrent/qbit-port-sync trio
   is where the hardlink contract and the hardest-won config in the lab live.
4. **The saving is trivial**: ~150 MB against 19 GB available, and one Proton
   device slot out of ten.

**No port forwarding here.** The servarr gluetun runs `PORT_FORWARD_ONLY: on`
because qBittorrent needs an inbound port. Suwayomi is outbound-only HTTP;
inheriting that flag would restrict the exit pool to PF-capable Proton servers
for no benefit, and there is no `qbit-port-sync` equivalent to feed. It is
deliberately left unset, which also means the manga tunnel can sit in a
different country from the torrent tunnel if a source prefers it.

**The WireGuard key must be a new one** (§10 item 1). Reusing servarr's
private key means two live sessions on one peer, and both will flap.

### Secure Core (added 2026-09-20, after the user generated the config)

The manga tunnel uses Proton **Secure Core** — a double hop, entering in
Switzerland, Iceland or Sweden before exiting in the chosen country.
`SECURE_CORE_ONLY: on` is what enforces it.

**This stack is the only one in the lab that *can* use it.** Checked against
gluetun's own server list on ciri: 782 Proton servers offer port forwarding
and **zero** of them are secure-core. `servarr` requires port forwarding for
qBittorrent, so Secure Core is permanently unavailable to it. The manga stack
is outbound-only and therefore free to take the double hop — an argument for
the separate tunnel that only appeared after the decision was made.

Three facts about the configuration, all verified against the live server
list rather than the documentation:

- **`SERVER_COUNTRIES` names the EXIT.** gluetun's `country` field is the exit
  country; the entry hop is Proton's choice and appears only inside the server
  name, e.g. `CH-TH#2` = enter Switzerland, exit Thailand. Switzerland itself
  has **zero** secure-core exits, which is the tell: it is an entry country
  only, and asking for it would match nothing.
- **`SECURE_CORE_ONLY` is load-bearing.** Without it, `SERVER_COUNTRIES` also
  matches the ordinary single-hop servers in the same country — Thailand has
  4 of each — and gluetun may silently pick one. The failure is invisible and
  in the wrong direction: you would believe you had a double hop.
- **Pool size varies enormously and is worth choosing on.** WireGuard
  secure-core servers per exit: United States 77, Netherlands 19, Japan 4,
  Hong Kong 3, Singapore 2, **Thailand 2**. A two-server pool means both being
  unavailable leaves no tunnel and, correctly, no Suwayomi. Latency compounds
  it: from India, a Thailand exit still routes via Europe first, and manga
  pages are many small requests — precisely the workload that punishes
  round-trip time.

`MANGA_VPN_COUNTRIES` and `MANGA_SECURE_CORE` are both `.env` values, so the
exit and the whole double-hop decision are one word each to revise.

## 6. Access, secrets, clients

**Every server carries its own login**, and Caddy is a plain proxy in front of
all three — the same conclusion proposal 008 §4 reached for Homepage and 009
§5 for Stirling. A name that resolves over the tailnet must not be an open
door, and basic auth at Caddy cannot cover the bare port on `.150`.

| Service | Gate | Set where |
|---|---|---|
| Suwayomi | `AUTH_MODE: basic_auth` + user/password | `.env` (§Appendix B) |
| Komga | first-run admin account | web UI, Phase B |
| Kavita | first-run admin account | web UI, Phase C |

Both `.env` files are `chmod 600` and git-ignored; `.env.example` carries
placeholders only, per `CLAUDE.md`.

### The iOS client

Offline reading is a client capability. The recommendation is **Komic**
(App Store, iOS 17+): it speaks Komga's and Kavita's native APIs, supports
multiple servers in one app, reads CBZ/CBR/PDF **and text EPUB**, downloads
for offline use and syncs progress back. Offline and sync are the paid tier —
**Lifetime $22.99**, or $0.99/mo, $8.99/yr. One purchase covers both servers,
which is the whole reason the two-server split is affordable.

The two alternatives, for the record:

- **Panels** ($14.99/yr, or $19.99 per major version) is the better *manga*
  reader and downloads whole series at once — but it reads only "comic EPUB"
  (image-based), not text EPUB, and **paywalls the server connection itself**:
  Komga's own documentation states "Panels OPDS support requires either a
  Panels+ subscription or Panels in-app purchase." Worth adding later purely
  for manga; not a substitute.
- **Aidoku** is free, open source, and supports Komga, Kavita *and* Suwayomi
  with offline and sync — but never reaches the App Store. TestFlight requires
  joining their Discord and builds expire every 90 days; AltStore works but
  **AltStore PAL is unsupported**, so a free Apple ID means re-signing every
  7 days from a computer. TrollStore is permanent but caps at iOS 17.0.
  Recurring friction on the device that will be used at an airport.

Both libraries are also readable for free in Safari over the Caddy routes.
**Offline is the only thing that costs money**, and the choice touches nothing
in this build — all three clients speak to the same unchanged servers.

## 7. Resource budget

Measured on ciri 2026-09-20: 23 Gi total, 4.3 Gi used, **19 Gi available**,
39 containers across 13 stacks.

| Container | Expected RSS | Note |
|---|---|---|
| `manga-gluetun` | ~150 MB | same image already running in servarr |
| `suwayomi` | ~1–1.5 GB | JVM; grows with library size and extension count |
| `komga` | ~1–1.5 GB | JVM; cap with `JAVA_TOOL_OPTIONS: -Xmx1g` if it misbehaves |
| `kavita` | ~0.5–1 GB | .NET |
| **Total** | **~3–4 GB** | against 19 GB available |

Disk: 100 G zvol from `silver`'s 337 G free, leaving ~237 G. `/data` gains
only the three app-state directories plus the books, all small.

CPU: Komga and Kavita generate thumbnails on first scan, which is bursty and
brief. ciri has 6 cores and sits near idle.

## 8. Monitoring, backups, maintenance

**Kuma** — three HTTP monitors, ntfy notification on, matching the existing
convention in [uptime-kuma.md](../uptime-kuma.md):

| Monitor | URL | Note |
|---|---|---|
| Komga | `http://<LAN_PREFIX>.150:25600/actuator/health` | plain 200 |
| Kavita | `http://<LAN_PREFIX>.150:5000/api/health` | plain 200 |
| Suwayomi | `http://<LAN_PREFIX>.150:4567/` | **returns 401** behind basic auth — either give Kuma the credentials or add 401 to accepted status codes, or the monitor is red from birth (§10 item 4) |

A red Suwayomi monitor is also the tunnel alarm: when gluetun cannot connect,
the published port stops answering. That is deliberate and is the cheapest
kill-switch check available.

**Backups** — covered by §4. No new job. Phase E test E13 confirms scsi4 is
absent from the nightly job and `/data/books` is present, rather than assuming.

**Maintenance** — four rows for the version registry in
[maintenance.md](../maintenance.md). All four images are pinned; bump
deliberately, read release notes, then `docker compose pull && up -d`.
Per the lab's pinning policy, versioned tags are used wherever the registry
publishes them — Suwayomi's `stable` tag was confirmed digest-identical to
`v2.3.2243` on 2026-09-20, so the version tag is pinned rather than `stable`.

## 9. Alternatives considered

| Option | Why not |
|---|---|
| **Kavita for everything** (one server, both libraries) | Works, and was the design until the user asked for separation. Kavita's manga reader needs mode configuration where Komga auto-detects, and its flexible parser mis-reads scanlation naming |
| **Komga for everything** | Its EPUB support is shaped around Kobo sync; no text-EPUB path to an iPhone |
| **Calibre-Web-Automated for books** | Better manager by a distance (auto-ingest, conversion, metadata, send-to-Kindle, KOReader sync) but no native iOS client — OPDS only, which never syncs progress back. Fails the offline requirement. **Deferrable**: it can be added later *behind* Kavita as an ingest layer over the same directory, with reading unchanged (§Follow-ups) |
| **Tranga** for acquisition | Active (389★, pushed 2026-09-18) and talks to Komga natively, but its own small connector set vs Suwayomi's full Mihon extension ecosystem. User chose Suwayomi |
| **Mylar3 / Kapowarr** | Western-comics shaped: ComicVine metadata, indexer-driven, volume-based. Wrong tool for weekly scanlated chapters |
| **CLI downloaders** (`mangal`, `mangadlmao`) + systemd timer | No library state, no per-series update tracking, no UI. Also note [kuma-push-timer-drift](../uptime-kuma.md): timer-based jobs need `OnCalendar` + `AccuracySec=1s` to avoid flapping push monitors |
| **Sharing servarr's gluetun** | §5 |
| **Manga on `/mnt/media`** | §4 |
| **Jellyfin** as the comic reader | It is a video server; its book support is vestigial |

## 10. Gotchas and pre-flight facts for the executing agent

1. **A new Proton WireGuard key is required.** Do **not** reuse
   `PROTON_WG_PRIVATE_KEY` from servarr's `.env` — one key with two live
   sessions makes both flap. Generate a second WireGuard configuration in the
   Proton dashboard. Confirm a device slot is free (the plan allows ten).
1b. **Secure Core: `SERVER_COUNTRIES` is the exit, and `SECURE_CORE_ONLY`
   must be on** or single-hop servers in the same country also match and may
   be chosen silently. Entry countries (CH/IS/SE) are not filterable. Check
   the pool size for the exit you pick — Thailand has 2 WireGuard secure-core
   servers, Netherlands 19. See §5.
2. **`DOWNLOAD_AS_CBZ` defaults to `false` in the Docker image**, even though
   the upstream `server.conf` default is `true`. The two genuinely differ. If
   it is not set explicitly, Suwayomi writes loose folders of images and Komga
   will not index them as books — the stack looks deployed and produces
   nothing readable. Likewise the variable is **`AUTO_DOWNLOAD_CHAPTERS`**,
   not `AUTO_DOWNLOAD_NEW_CHAPTERS`.
3. **Suwayomi's download layout is nested**:
   `downloads/mangas/<source>/<title>/<chapter>.cbz`. Komga treats the deepest
   folder containing books as the series, which *should* make `<title>` the
   series and `<source>` an intermediate folder. **This is unverified.** It
   decides whether the library reads right or inside-out, so test E5 checks it
   on real files before anything is built on top. If it comes out wrong, the
   fix is Komga's library root, not the download layout.
4. **Suwayomi's WebUI returns 401 behind basic auth**, so a default Kuma HTTP
   monitor will be red immediately. Supply credentials or widen accepted
   status codes (§8).
5. **Disk hotplug is expected to work.** `qm config 150` shows no `hotplug`
   line, so Proxmox's default (`disk,network,usb`) applies, and `scsihw` is
   `virtio-scsi-single`. Adding scsi4 to the running VM should surface
   `/dev/sde` without a restart. **If it does not, stop**: restarting ciri
   takes down all 13 stacks, and per
   [nfs-client-session-drain-hang](../docker-vm.md) a VM stop/start is the
   lab's recovery tool, not a routine step. Schedule it rather than improvising.
6. **Neither Suwayomi nor Komga supports PUID/PGID.** Both take an explicit
   `user: "13000:13000"` directive — Komga's own documentation recommends
   exactly this. Kavita is the LinuxServer image and *does* use PUID/PGID;
   the official `jvmilazz0/kavita` image does not and runs as root, which is
   why the LSIO image is pinned instead.
7. **Nested bind ordering** — the manga stack mounts `./suwayomi` at the
   Tachidesk data directory and then `/mnt/manga/library` **over** its
   `downloads` subdirectory. Docker orders binds by target depth, parent
   first, so this resolves correctly. It is the same technique servarr uses to
   nest the NVMe scratch inside the NFS downloads tree.
8. **Komga's config directory must be on a local filesystem**, not a network
   share — its documentation is explicit. `/data/stacks/manga/komga` is local
   ext4 on scsi1, which satisfies this. Do not "tidy" it onto the media share.
9. **Ports 4567, 25600 and 5000 were confirmed free on ciri** on 2026-09-20.
   Note 8080 is qBittorrent's (published from servarr's gluetun) and 8081 is
   Stirling's — neither is touched.
10. **`/data/books` must exist and be owned 13000:13000 before Phase C**, or
    Kavita's library scan finds nothing and the failure looks like a Kavita
    bug rather than a missing directory.

### Found during the build (2026-09-20/21) — not predicted by this design

11. **Suwayomi ships with NO extension repository, and the URL every guide
    gives is the wrong one.** v2.3 uses Mihon's Extension Store
    (`server.extensionStores`), not the older `extensionRepos`. Pasting
    `https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json`
    "works" — no error — and yields exactly **two** entries, `Outdated App`
    and `Update to Mihon 0.20.1+`. Those are sentinels Keiyoushi serves to
    clients on the old extension API. The real catalogue is the protobuf
    index, `https://github.com/keiyoushi/extensions/raw/repo/index.pb`
    (765 bytes vs 108 KB gzipped — an easy tell). Set declaratively via
    `EXTENSION_STORES`, which **does** override `server.conf` on every start
    (the Open WebUI ConfigVar trap does *not* apply). Verified: 1,396
    extensions.
12. **`AUTO_DOWNLOAD_CHAPTERS` does not backfill.** It fires when a *library
    update* discovers a chapter that did not exist before. Adding a series
    with 973 existing chapters downloads none of them — you get chapter 974
    onward and nothing behind it. The back catalogue is a manual selection in
    the UI. This surprised the build and is worth knowing before concluding
    the setting is broken.
13. **Cloudflare-fronted sources fail at page-fetch while the tunnel is
    perfectly healthy.** MangaFox returned `HTTP 200` with
    `Server: cloudflare` and a `cf-2fa-verify` marker, but the chapter page
    list came back empty →
    `Downloader$EmptyChapterException: Chapter does not have any pages to
    download`. MangaDex's API through the same tunnel returned clean JSON,
    which is the control that proves the VPN is not at fault. Same failure
    class as the Open WebUI search wall. Suwayomi's bundled headless Chromium
    is meant to clear these and does not always. **Diagnosis rule: test a
    known-good API source (MangaDex) before suspecting the tunnel.** A Proton
    exit IP plausibly worsens Cloudflare scoring, but that was not proven.
14. **Suwayomi logs a steady stream of alarming, harmless Chromium errors** —
    `dbus/bus.cc`, `VK_ERROR_INCOMPATIBLE_DRIVER`, `google_apis/gcm …
    PHONE_REGISTRATION_ERROR`. That is the bundled headless browser
    complaining about a system bus, GPU driver and Google push registration
    that do not exist in a container. None of it affects manga fetching. Do
    not chase it.
15. **Suwayomi partitions downloads by source**, so the same series taken from
    two sources becomes **two** series in Komga with split read progress.
    Settle on a source per series before downloading in bulk, and delete the
    old source's folder after migrating.
16. **Komga parses chapter numbers correctly from Suwayomi's filenames.**
    `Official_Chapter 89.cbz` → `number=89`. This was the specific risk behind
    choosing Komga's stricter parser over Kavita's flexible one, and it held.

---

## Phase A — storage

### A1. Add the zvol (on geralt)

**[USER]**:

```bash
qm set 150 --scsi4 silver-guests:100,backup=0,discard=on,iothread=1,ssd=1
```

**[VERIFY]**:

```bash
ssh lab-geralt "qm config 150 | grep scsi4"
```

Expected: `scsi4: silver-guests:vm-150-disk-<N>,backup=0,discard=on,iothread=1,size=100G,ssd=1`.

### A2. Format and mount (in ciri)

Confirm the new device appeared **before** formatting — §10 item 5:

```bash
lsblk -o NAME,SIZE,LABEL,MOUNTPOINT
```

Expect a new 100 G unformatted `/dev/sde`. If it is absent, stop and read §10
item 5. If present:

**[USER]** on ciri:

```bash
sudo mkfs.ext4 -L manga /dev/sde
echo 'LABEL=manga /mnt/manga ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/manga
sudo systemctl daemon-reload
sudo mount /mnt/manga
sudo install -d -o 13000 -g 13000 /mnt/manga/library
sudo install -d -o 13000 -g 13000 /data/books
```

**[VERIFY]**:

```bash
findmnt /mnt/manga && ls -ld /mnt/manga/library /data/books && df -h /mnt/manga
```

Expected: ext4, ~98 G available, both directories owned `13000:13000`.

## Phase B — the manga stack

### B1. Directories and files

The stack is deployed **from the repo checkout**, following the `ai` stack's
precedent — `compose.yaml` and `.env.example` are committed at
`configs/ciri/manga/` (identical to Appendices A and B) and pushed out with
`rsync`, rather than pasted onto the VM by hand. The mirror rule in
`CLAUDE.md` still holds afterwards: Phase F `scp`s the live file *back* and
confirms it is byte-identical, so the repo remains the mirror of what runs.

**[USER]** on ciri — the app directories must exist and be owned by `jaskier`
before the first `up`, or the two JVMs cannot write their own databases:

```bash
mkdir -p /data/stacks/manga/{suwayomi,komga}
sudo chown -R 13000:13000 /data/stacks/manga/suwayomi /data/stacks/manga/komga
```

**[USER]** from the repo checkout:

```bash
rsync -av configs/ciri/manga/ lab-ciri:/data/stacks/manga/
ssh lab-ciri 'cd /data/stacks/manga && cp .env.example .env && chmod 600 .env'
```

Then fill the four values in `/data/stacks/manga/.env` — nothing else needs
substituting, as `compose.yaml` carries no host-specific values:

| Key | Source |
|---|---|
| `MANGA_WG_PRIVATE_KEY` | `PrivateKey =` in the **new** Proton WireGuard config |
| `MANGA_WG_ADDRESSES` | `Address =` in the same file (typically `10.2.0.2/32`) |
| `MANGA_VPN_COUNTRIES` | any Proton country; need not match servarr's (§5) |
| `SUWAYOMI_USER` / `SUWAYOMI_PASSWORD` | chosen here; this is Suwayomi's own gate (§6) |

**[VERIFY]** — the `${VAR:?}` test, which fails loudly on a blank rather than
at runtime:

```bash
ssh lab-ciri 'cd /data/stacks/manga && docker compose config >/dev/null && echo renders OK'
```

### B2. Tunnel first, alone

```bash
cd /data/stacks/manga
docker compose config                 # renders? every ${VAR:?} satisfied?
docker compose up -d manga-gluetun
docker compose logs -f manga-gluetun  # wait for the healthy/connected line
```

**Do not start Suwayomi until this is verified** — §0.

**[VERIFY]** — this is contract test E1, run early because everything after it
depends on it:

```bash
docker exec manga-gluetun wget -qO- https://ifconfig.me ; echo
curl -s https://ifconfig.me ; echo          # from ciri itself, for contrast
```

The two must differ, and the first must be the Proton exit.

### B3. The rest of the stack

```bash
docker compose up -d
docker compose ps
docker compose logs --tail 50 suwayomi komga
```

Both are JVM applications and are slow on first start. Wait for the port
announcement before testing.

**[VERIFY]**: `curl -sI http://<LAN_PREFIX>.150:4567/ | head -1` (expect
**401** — basic auth is on) and
`curl -s http://<LAN_PREFIX>.150:25600/actuator/health`.

### B4. First-run configuration

1. Open `http://<LAN_PREFIX>.150:4567`, log in with the `.env` credentials.
2. Add the Mihon extension repository, install the sources you want, add a
   few series to the library.
3. Confirm **Settings → Downloads** shows CBZ and auto-download on. If not,
   §10 item 2 — the environment did not take.
4. Open `http://<LAN_PREFIX>.150:25600`, create the admin account, add a
   library pointing at `/data` (see §10 item 3 before choosing the exact root).

## Phase C — the books stack

Same deploy-from-repo route as Phase B; committed at `configs/ciri/books/`.
`/data/books` itself was created in Phase A4.

```bash
# [USER] on ciri
mkdir -p /data/stacks/books/kavita
sudo chown -R 13000:13000 /data/stacks/books/kavita

# [USER] from the repo checkout
rsync -av configs/ciri/books/ lab-ciri:/data/stacks/books/
ssh lab-ciri 'cd /data/stacks/books && cp .env.example .env && chmod 600 .env'
```

**Nothing needs substituting here** — the `.env` carries only `PUID`/`PGID`,
already correct at 13000, and Kavita's admin account is created in the web UI.

```bash
ssh lab-ciri 'cd /data/stacks/books && docker compose up -d'
ssh lab-ciri 'cd /data/stacks/books && docker compose logs --tail 50 kavita'
```

**[VERIFY]**: `curl -s http://<LAN_PREFIX>.150:5000/api/health`.

Then open `http://<LAN_PREFIX>.150:5000`, create the admin account, and add a
library of type **Book** pointing at `/books`.

## Phase D — proxy, DNS, Kuma, Homepage

### D1. Caddyfile (LXC 202) — Appendix E, then:

```bash
caddy adapt --config /etc/caddy/Caddyfile && set -a && . /etc/caddy/cloudflare.env && set +a \
  && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### D2. Pi-hole records (pihole-1 only; replace-not-append — read first)

```bash
pct exec 101 -- pihole-FTL --config dns.hosts       # current array
pct exec 101 -- pihole-FTL --config dns.hosts '[ …all existing…, "<LAN_PREFIX>.202 manga.kaermorhen.fyi", "<LAN_PREFIX>.202 books.kaermorhen.fyi", "<LAN_PREFIX>.202 suwayomi.kaermorhen.fyi" ]'
# on ciri: force the sync to pihole-2
docker compose -f /data/stacks/nebula-sync/compose.yaml run --rm sync-now
```

### D3. Kuma — three HTTP monitors per §8. Mind the Suwayomi 401.

### D4. Homepage — three tiles in the Apps group of
`configs/ciri/homepage/homepage/services.yaml`, `server: ciri` +
`container: <name>` for the status dot. Komga and Kavita both have upstream
Homepage widgets; Suwayomi does not, so it gets a `siteMonitor` link tile.

## Phase E — verification (the contract tests)

| # | Test | Pass |
|---|---|---|
| E1 | `docker exec manga-gluetun wget -qO- ifconfig.me` vs `curl ifconfig.me` on ciri | different IPs; the container's is the Proton exit |
| E2 | `docker stop manga-gluetun`, then `docker exec suwayomi wget -qO- ifconfig.me` | fails outright — no connectivity at all, not merely slow |
| E3 | **Revised 2026-09-20** — the Suwayomi image has no `wget`, so compare network-namespace inodes instead: `sudo readlink /proc/$(docker inspect -f '{{.State.Pid}}' suwayomi)/ns/net` vs the same for `manga-gluetun` | **identical inode**. Stronger than an IP match: Suwayomi has no interfaces, routes or DNS of its own, so the kill-switch is structural, not configured |
| E4 | Add one series in Suwayomi, let it download | `.cbz` files under `/mnt/manga/library`, owned `13000:13000` |
| E5 | Komga scan | series appears under its own title; **the `mangas/<source>/` level has not become the series** (§10 item 3) |
| E6 | Open a chapter in Komga's web reader | RTL auto-detected for manga; a webtoon scrolls vertically; a western comic is LTR |
| E7 | Komic → Komga, download a series, airplane mode | reads offline; progress syncs back on reconnect |
| E8 | Drop an EPUB in `/data/books`, scan in Kavita | appears in the Book library; Komic reads it offline with chapter progress |
| E9 | All three names on LAN **and** over the tailnet | valid wildcard certificate, no warning on iPhone |
| E10 | Hit `:25600`, `:5000`, `:4567` directly, bypassing Caddy | each still demands its own login |
| E11 | `docker stop komga` for 2 minutes | Kuma phone alert, then resolved on start |
| E12 | `docker compose down && up -d` on the books stack | manga stack entirely unaffected — the separation is real |
| E13 | `qm config 150`; PBS job contents | scsi4 shows `backup=0` and is absent from the nightly job; `/data/books` **is** covered |
| E14 | `sudo umount /mnt/manga`, then `docker compose up -d` on manga | both containers refuse to start; **nothing** is created under `/mnt/manga` on the root disk (§4) |

E14 is the guard test and matters more than it looks — it is the one that
proves a missing disk fails loud instead of quietly filling the root
filesystem.

## Phase F — as-built mirroring (only after E passes)

- Both stacks were deployed *from* the repo (Phases B1, C), so the mirror
  already exists. Phase F **confirms it rather than creates it**: `scp` each
  live `compose.yaml` back and diff it against the committed copy. Any
  difference is a hand-edit made on the VM during the build and must be
  committed, not discarded — the repo is the mirror of what runs, not of what
  was intended.

  ```bash
  ssh lab-ciri 'cat /data/stacks/manga/compose.yaml' | diff - configs/ciri/manga/compose.yaml && echo "manga: identical"
  ssh lab-ciri 'cat /data/stacks/books/compose.yaml' | diff - configs/ciri/books/compose.yaml && echo "books: identical"
  ```
- `configs/yennefer/proxy/Caddyfile` — the three new matcher blocks.
- [storage.md](../storage.md): scsi4 row in the ciri zvol table; note
  `/data/books` in the backup discussion.
- [docker-vm.md](../docker-vm.md): `manga` and `books` rows in the Stacks
  table; memory budget refreshed.
- [dns.md](../dns.md): three records added, `dns.hosts` count +3.
- [uptime-kuma.md](../uptime-kuma.md): the three monitors, including the
  Suwayomi 401 note.
- [maintenance.md](../maintenance.md): four version-registry rows.
- This file: Status → **Built**, plus an "As-built deviations" section.

## Follow-ups (not in scope)

- **Calibre-Web-Automated as an ingest layer** behind Kavita if EPUB metadata
  quality disappoints: it converts, tags and de-duplicates into the same
  directory Kavita serves, and reading stays in Komic. The integration detail
  to check first is how gracefully Kavita scans Calibre's `metadata.db` +
  `Author/Title/` layout — verify on the box, not from forum posts.
- **Panels** as a second, manga-only iOS app if Komic's reader disappoints
  (§6).
- **Suwayomi tracker sync** (AniList/MyAnimeList) — supported upstream,
  unconfigured here.
- **Komga's OPDS v2 feed** if a non-iOS reader ever joins the household.
- A **Beszel** per-container history row for the four new containers, if the
  existing agent does not pick them up automatically.

---

# Appendix A — `compose.yaml`

Committed at `configs/ciri/manga/compose.yaml` and deployed from there (Phase
B1). Reproduced here so the proposal is readable standalone; the committed
file is the source of truth.

```yaml
# Stack: manga — acquisition (Suwayomi) + library/reader (Komga).
# Design + runbook: docs/proposals/011-manga-and-ebook-reading.md
# Mirror of ciri:/data/stacks/manga/compose.yaml (CLAUDE.md mirror rule).
#
# THE INTERFACE BETWEEN THESE TWO SERVICES IS A DIRECTORY, NOT A NETWORK.
# Suwayomi writes CBZ files into /mnt/manga/library; Komga reads them. They
# never speak over the network, which is what allows Suwayomi to live inside
# gluetun's netns while Komga stays reachable on an ordinary bridge.
#
# Suwayomi runs INSIDE gluetun's network namespace: every request to a
# third-party manga source exits through Proton, and if the tunnel drops it
# loses all connectivity (kill-switch) — no home-IP leak. Komga does NOT and
# must not: it serves the LAN and the reverse proxy, including while the
# tunnel is down.
#
# NO PORT FORWARDING, unlike the servarr gluetun. Suwayomi only makes outbound
# HTTP requests; PORT_FORWARD_ONLY would narrow the Proton server pool for
# nothing and there is no qbit-port-sync equivalent to feed. The WireGuard key
# here MUST be a second, distinct Proton config — reusing servarr's key means
# two live sessions on one peer and both flap.
#
# Lab conventions: pinned image tags (verified current 2026-09-20 — bump
# deliberately, read release notes, then `docker compose pull && up -d`),
# container_name on every service, restart: unless-stopped, TZ=Asia/Kolkata,
# dedicated bridge network, secrets only from .env (${VAR:?} fails loudly).
#
# Least-privilege: both writers run as the dedicated non-root service account
# `jaskier` (13000:13000), the same one the *arr use. NEITHER image supports
# PUID/PGID, so both take an explicit `user:` directive — Komga's own docs
# recommend exactly this.

# Missing-mount guard, the same pattern servarr documents at length.
# /mnt/manga is mounted `nofail`, so if the disk is absent the mountpoint
# still exists as an empty directory on the 64 G root disk. Without
# create_host_path:false, Docker's default is to CREATE the bind source and
# Suwayomi would download a library onto the root filesystem until it filled.
# `library/` exists only on the real filesystem => absent disk means the
# containers refuse to start. Fail loud. Verified by test E14.
x-manga-library: &manga_library
  type: bind
  source: /mnt/manga/library
  bind:
    create_host_path: false

services:
  # ---- VPN egress + kill-switch -------------------------------------------
  manga-gluetun:
    image: qmcgaw/gluetun:v3.41.3
    container_name: manga-gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      # Suwayomi's WebUI is published HERE (it shares this netns), not on the
      # suwayomi service — same arrangement as qBittorrent's 8080 in servarr.
      - "4567:4567"
    environment:
      TZ: Asia/Kolkata
      VPN_SERVICE_PROVIDER: protonvpn
      VPN_TYPE: wireguard
      WIREGUARD_PRIVATE_KEY: ${MANGA_WG_PRIVATE_KEY:?set in .env}
      WIREGUARD_ADDRESSES: ${MANGA_WG_ADDRESSES:-10.2.0.2/32}
      # SECURE CORE (double hop). SERVER_COUNTRIES names the EXIT country:
      # gluetun's `country` field is the exit, and the entry (CH/IS/SE) is
      # Proton's choice, encoded only in the server name (e.g. "CH-TH#2") and
      # NOT filterable. Switzerland has zero secure-core exits, which is the
      # tell — it is an entry country only.
      #
      # SECURE_CORE_ONLY is load-bearing, not decorative. Without it,
      # SERVER_COUNTRIES also matches the ordinary single-hop servers in the
      # same country (Thailand has 4 of each) and gluetun may silently pick
      # one — you would believe you had double hop and not have it.
      #
      # Mind the pool size when choosing an exit: Thailand has only 2
      # WireGuard secure-core servers, so both being down means no tunnel and
      # (correctly) no Suwayomi. Netherlands has 19, United States 77.
      SERVER_COUNTRIES: ${MANGA_VPN_COUNTRIES:-Netherlands}
      SECURE_CORE_ONLY: ${MANGA_SECURE_CORE:-on}
      # VPN_PORT_FORWARDING deliberately UNSET — see the header.
      # NB: Proton does not offer port forwarding on secure-core servers
      # anyway, so this stack's outbound-only design and Secure Core are a
      # natural fit — where servarr's PORT_FORWARD_ONLY would directly
      # conflict with it.
    networks:
      - manga_net

  # ---- Acquisition (no own network — lives in gluetun's netns) ------------
  suwayomi:
    image: ghcr.io/suwayomi/suwayomi-server:v2.3.2243
    container_name: suwayomi
    restart: unless-stopped
    # All traffic goes through gluetun; dies with the tunnel (kill-switch).
    network_mode: "service:manga-gluetun"
    depends_on:
      - manga-gluetun
    user: "13000:13000"
    environment:
      TZ: Asia/Kolkata
      # LOAD-BEARING. The image's default is "false" even though upstream's
      # server.conf default is "true" — they genuinely differ. Unset, Suwayomi
      # writes loose folders of images and Komga will not index them as books:
      # the stack looks deployed and produces nothing readable.
      DOWNLOAD_AS_CBZ: "true"
      # Note the name — AUTO_DOWNLOAD_CHAPTERS, not AUTO_DOWNLOAD_NEW_CHAPTERS.
      AUTO_DOWNLOAD_CHAPTERS: "true"
      AUTO_DOWNLOAD_NEW_CHAPTERS_LIMIT: "0"
      # Extension catalogue. Suwayomi ships with NONE by default, deliberately
      # — upstream carries no source list, so this is the one thing that must
      # be supplied before the server can browse anything at all. Declared
      # here rather than clicked into the UI so it is git-tracked and survives
      # a container recreate; it maps to server.extensionStores in server.conf.
      #
      # THE URL MUST BE THE PROTOBUF INDEX. Suwayomi 2.3 moved to Mihon's
      # Extension Store system (server.extensionStores) from the older
      # extensionRepos, and the .../repo/index.min.json URL that almost every
      # guide still gives is a TRAP: it serves two sentinel entries to clients
      # on the old extension API — "Outdated App" and "Update to Mihon
      # 0.20.1+" — so the UI looks like it worked and lists two fake
      # extensions while you have no sources. Verified 2026-09-20:
      # index.min.json = 765 bytes / 2 sentinels, index.pb = 108 KB gzipped
      # protobuf / the real catalogue. This URL is the one Keiyoushi's own
      # README gives, and matches the index_v2 field in its repo.json.
      EXTENSION_STORES: '["https://github.com/keiyoushi/extensions/raw/repo/index.pb"]'
      # Its own gate. A tailnet-resolvable name must not be an open door, and
      # basic auth at Caddy could never cover the bare port on .150 — the same
      # reasoning as Homepage (008 §4) and Stirling (009 §5).
      AUTH_MODE: basic_auth
      AUTH_USERNAME: ${SUWAYOMI_USER:?set in .env}
      AUTH_PASSWORD: ${SUWAYOMI_PASSWORD:?set in .env}
      BIND_PORT: "4567"
      WEB_UI_ENABLED: "true"
      WEB_UI_FLAVOR: WebUI
      WEB_UI_CHANNEL: stable
    volumes:
      # State, extensions and DB on /data (scsi1) — inside the nightly PBS
      # job, unlike the downloads below. Losing the zvol costs re-downloading;
      # it does not cost the library structure or the installed extensions.
      - ./suwayomi:/home/suwayomi/.local/share/Tachidesk
      # NESTED ON PURPOSE over the `downloads` subdirectory of the bind above.
      # Docker orders binds by target depth, parent first, so the state
      # directory lands first and the zvol on top of it — the same technique
      # servarr uses to nest NVMe scratch inside the NFS downloads tree.
      - <<: *manga_library
        target: /home/suwayomi/.local/share/Tachidesk/downloads
    # NB: no `ports:` and no `networks:` here — both come from manga-gluetun.

  # ---- Library + reader (NOT behind the VPN, deliberately) ----------------
  komga:
    image: gotson/komga:1.27.0
    container_name: komga
    restart: unless-stopped
    user: "13000:13000"
    environment:
      TZ: Asia/Kolkata
      # If the JVM misbehaves on a large library, cap it here:
      # JAVA_TOOL_OPTIONS: "-Xmx1g"
    volumes:
      # Komga's docs are explicit that /config must be a LOCAL filesystem, not
      # a network share. This is ext4 on scsi1. Do not "tidy" it onto a share.
      - ./komga:/config
      # READ-ONLY: Komga is a reader here and never writes to the library.
      # Same rule as Jellyfin's media bind in the jellyfin stack.
      - <<: *manga_library
        target: /data
        read_only: true
    ports:
      - "25600:25600"
    networks:
      - manga_net

networks:
  manga_net:
    driver: bridge
```

# Appendix B — `.env` (→ `ciri:/data/stacks/manga/.env`, chmod 600)

The committed `.env.example` carries these keys with `<PLACEHOLDER>` values
only. Real values live in the git-ignored `secrets.local.yaml`.

```bash
# Proton WireGuard — a SECOND config, distinct from servarr's.
# Reusing PROTON_WG_PRIVATE_KEY means two live sessions on one peer and both
# will flap. Generate a new WireGuard configuration in the Proton dashboard.
MANGA_WG_PRIVATE_KEY=<MANGA_WG_PRIVATE_KEY>
MANGA_WG_ADDRESSES=<MANGA_WG_ADDRESSES>
MANGA_VPN_COUNTRIES=Netherlands

# Suwayomi WebUI basic auth (its own gate; Caddy is a plain proxy).
SUWAYOMI_USER=<SUWAYOMI_USER>
SUWAYOMI_PASSWORD=<SUWAYOMI_PASSWORD>
```

# Appendix C — `compose.yaml`

Committed at `configs/ciri/books/compose.yaml` and deployed from there (Phase C).

```yaml
# Stack: books — EPUB library and reader (Kavita).
# Design + runbook: docs/proposals/011-manga-and-ebook-reading.md
# Mirror of ciri:/data/stacks/books/compose.yaml (CLAUDE.md mirror rule).
#
# Deliberately a SEPARATE stack from `manga`, not a second service inside it.
# Two reasons, both structural: the user reads books and manga in different
# modes and wants them apart; and a gluetun reconnect or a `docker compose
# down` on the manga stack must not be able to take the book server with it.
#
# Kavita rather than Komga for books because Komga's EPUB support is built
# around Kobo sync, which does nothing for an iPhone. Kavita is the only one
# of the three servers with a native iOS client (Komic) that downloads text
# EPUB *and* syncs reading progress back — the hard requirement here is
# reading offline while travelling.
#
# THE LINUXSERVER IMAGE IS DELIBERATE. The official jvmilazz0/kavita image
# ships no PUID/PGID and runs as root; this one takes the same `jaskier`
# (13000) identity as every other writer in the lab.
#
# Unlike the manga library, /data/books IS inside the nightly PBS job: books
# are hand-curated and not re-downloadable, where manga is. See proposal §4.

services:
  kavita:
    image: lscr.io/linuxserver/kavita:version-v0.9.1.4
    container_name: kavita
    restart: unless-stopped
    environment:
      PUID: ${PUID:-13000}
      PGID: ${PGID:-13000}
      TZ: Asia/Kolkata
    volumes:
      - ./kavita:/config
      # READ-ONLY: Kavita is a reader. Books are added by hand (scp/rsync
      # into /data/books), which keeps the lab's "reader apps mount the
      # library read-only" rule intact rather than carving an exception.
      # create_host_path:false is belt-and-braces here — /data is the Docker
      # data-root, so if it were missing the daemon would not be running at
      # all — but the habit is worth keeping consistent across stacks.
      - type: bind
        source: /data/books
        target: /books
        read_only: true
        bind:
          create_host_path: false
    ports:
      - "5000:5000"
    networks:
      - books_net

networks:
  books_net:
    driver: bridge
```

# Appendix D — `.env` (→ `ciri:/data/stacks/books/.env`, chmod 600)

No secrets: Kavita's admin account is created in the web UI on first run.
The file exists only to keep the service account explicit and overridable.

```bash
PUID=13000
PGID=13000
```

# Appendix E — Caddyfile blocks (→ LXC 202, `/etc/caddy/Caddyfile`)

Added inside the existing site block, after the proposal 010 `@n8n` section.

```caddyfile
	# ---- Reading (proposal 011) ---------------------------------------------
	# All three carry their own login (Komga and Kavita admin accounts,
	# Suwayomi basic auth); Caddy is a plain proxy here like everywhere else.

	@manga host manga.kaermorhen.fyi
	handle @manga {
		reverse_proxy <LAN_PREFIX>.150:25600
	}

	@books host books.kaermorhen.fyi
	handle @books {
		reverse_proxy <LAN_PREFIX>.150:5000
	}

	@suwayomi host suwayomi.kaermorhen.fyi
	handle @suwayomi {
		# Published from manga-gluetun's netns, not from the suwayomi
		# container — so this port stops answering when the tunnel is down.
		# That is the intended behaviour and doubles as the kill-switch alarm
		# (see the Kuma monitor in §8).
		reverse_proxy <LAN_PREFIX>.150:4567
	}
```

## Sources

Checked 2026-09-20.

- Suwayomi: [Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server),
  [Docker image and environment variables](https://github.com/Suwayomi/docker-tachidesk)
  (`DOWNLOAD_AS_CBZ` default `false`, `AUTO_DOWNLOAD_CHAPTERS`, `AUTH_MODE`),
  [configuring Suwayomi-Server](https://github.com/Suwayomi/Suwayomi-Server/wiki/Configuring-Suwayomi%E2%80%90Server)
  (`downloadAsCbz` config default `true` — differs from the image).
  `stable` confirmed digest-identical to `v2.3.2243` against ghcr.io.
- Komga: [komga.org](https://komga.org/),
  [Docker installation](https://komga.org/docs/installation/docker/)
  (`user: "1000:1000"` recommended over root; config must be a local
  filesystem), [Read with Panels on iOS](https://komga.org/docs/guides/panels/)
  ("Panels OPDS support requires either a Panels+ subscription or Panels
  in-app purchase"). Latest release 1.27.0, 2026-09-17.
- Kavita: [kavitareader.com](https://www.kavitareader.com/),
  [Docker install](https://wiki.kavitareader.com/installation/docker/),
  [third-party apps](https://wiki.kavitareader.com/guides/3rdparty/kavita-dedicated/)
  (KOReader progress sync across PDF/EPUB/archives; Turnleaf is Android-only).
  Latest release v0.9.1.4, 2026-09-02; LSIO tag `version-v0.9.1.4`, 2026-09-11.
- iOS clients: [Komic](https://pruizlezcano.github.io/komic/) and its
  [App Store listing](https://apps.apple.com/app/id6744676973) (Komga + Kavita,
  CBZ/CBR/PDF/EPUB, offline and sync behind Komic+; Lifetime $22.99),
  [Panels](https://apps.apple.com/us/app/panels-comic-reader/id1236567663)
  (Panels+ $1.49/mo, $14.99/yr, $19.99 per major version; "comic EPUB" is
  image-based only), [Aidoku](https://aidoku.app/) and its
  [install guide](https://github.com/Aidoku/Aidoku/blob/main/README.md)
  (TestFlight via Discord, AltStore PAL unsupported).
- Alternatives: [Tranga](https://github.com/C9Glax/tranga) (389★, pushed
  2026-09-18), [Calibre-Web-Automated](https://github.com/crocodilestick/Calibre-Web-Automated)
  (v4.0.6, 2026-02-04; 6.3k★, pushed 2026-08-07),
  [Kapowarr](https://github.com/Casvt/Kapowarr) (V1.3.2),
  [Mylar3](https://github.com/mylar3/mylar3) (v0.8.3, 2025-08-17),
  [OPDS on iOS](https://justread.app/en/posts/how-to-set-up-opds-on-iphone-ipad)
  (OPDS hands over files; reading position does not sync back).
- Lab state read live on 2026-09-20: ciri 23 Gi total / 19 Gi available,
  39 containers; `silver` 337 G free, `steel` 899 G free (0% used);
  `/mnt/media` 78% full; ports 4567/25600/5000 unused; `qm config 150` has no
  `hotplug` line and `scsihw: virtio-scsi-single`.
