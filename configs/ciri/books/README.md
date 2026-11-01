# books — EPUB library and reader (ciri stack)

One service on **ciri** (VM 150), live at `ciri:/data/stacks/books/`:

| Service | Image | Port | Name |
|---|---|---|---|
| Kavita | `lscr.io/linuxserver/kavita:version-v0.9.1.4` | **5000** | `books.kaermorhen.fyi` |

Manga lives in the separate [`manga`](../manga/README.md) stack. Design and
rationale: [proposal 011](../../../docs/proposals/011-manga-and-ebook-reading.md).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — no secrets; Kavita's admin account is made in the web UI

## Why a separate stack, not a second service in `manga`

Two reasons, both structural rather than cosmetic. Books and manga are read in
different modes and the user wants them apart — separate URL, separate app
entry, no manga in the book app. And a gluetun reconnect, a Suwayomi restart
or a full `docker compose down` on the manga stack must not be able to take
the book server with it.

## Why Kavita and not Komga or Calibre-Web-Automated

**Komga's EPUB support is built around Kobo sync**, which does nothing for an
iPhone. **Calibre-Web-Automated is the better *manager* by a distance** —
auto-ingest, format conversion, metadata fetching, send-to-Kindle, KOReader
sync — but its only offline path to iOS is OPDS, and **OPDS hands over a file
rather than streaming pages, so reading position stays on the phone and never
returns to the server.** That fails the one hard requirement here: downloading
before travel and resuming afterwards.

Kavita is the only one of the three with a native iOS client that downloads
text EPUB *and* syncs progress back. CWA remains a sensible future addition
*behind* Kavita as an ingest layer over the same directory, with reading
unchanged.

## Where the files go

| Content | Path | In nightly PBS? |
|---|---|---|
| EPUB books | `/data/books` — scsi1 | **yes** |
| Kavita DB, covers | `./kavita` on `/data` | yes |

This is the opposite posture to the manga stack, on purpose. Manga is
re-downloadable and sits on a `backup=0` zvol; **books are hand-curated and
are not**, so they live on `/data`, which the nightly job already covers. No
new backup machinery was needed for either — which is the main reason books
are not simply dropped onto the manga zvol.

## Library mount is read-only

Kavita is a reader. Books are added by hand (`scp`/`rsync` into
`/data/books`), which keeps the lab's "reader apps mount the library
read-only" rule intact rather than carving an exception for it.

`create_host_path: false` on that bind is belt-and-braces here — `/data` is
the Docker data-root, so if it were missing the daemon would not be running at
all — but the habit is kept consistent across stacks.

## Gotchas

- **The LinuxServer image is deliberate.** The official `jvmilazz0/kavita`
  ships no PUID/PGID and runs as root; this one takes the same `jaskier`
  (13000) identity as every other writer in the lab.
- **`/data/books` must exist and be owned 13000:13000 before the first `up`**,
  or the library scan finds nothing and the failure looks like a Kavita bug
  rather than a missing directory.
- **Kavita's stable Docker tags are three-part** (`0.9.1`) while its GitHub
  releases are four-part (`v0.9.1.4`). The LSIO tag `version-v0.9.1.4` is the
  unambiguous one and is what is pinned.

## Deploy

```sh
# from the repo checkout
rsync -av configs/ciri/books/ lab-ciri:/data/stacks/books/
ssh lab-ciri 'cd /data/stacks/books && cp .env.example .env && chmod 600 .env'
ssh lab-ciri 'cd /data/stacks/books && docker compose up -d'
```

Prerequisites, both owned by `jaskier`:

```sh
mkdir -p /data/stacks/books/kavita
sudo chown -R 13000:13000 /data/stacks/books/kavita
sudo install -d -o 13000 -g 13000 /data/books
```

First visit to `:5000` creates the admin account. Then add a library of type
**Book** pointing at `/books`.

## Clients

Read in a browser at `books.kaermorhen.fyi`, or on iOS with **Komic**
(App Store) — the same app and the same single purchase that serves the
`manga` stack's Komga, since it supports multiple servers. Offline downloads
and progress sync are the paid tier (Lifetime $22.99). Panels cannot read text
EPUB, only image-based "comic EPUB". Full comparison in proposal 011 §6.
