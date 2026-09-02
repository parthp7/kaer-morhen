# shrink — PDF and image size reduction (ciri stack)

Two tools on **ciri** (VM 150), live at `ciri:/data/stacks/shrink/`:

| Service | Image | Port | Name |
|---|---|---|---|
| Stirling-PDF | `docker.io/stirlingtools/stirling-pdf:2.14.3` | **8081** | `pdf.kaermorhen.fyi` |
| Mazanoke | `ghcr.io/civilblur/mazanoke:v1.1.6` | **3474** | `img.kaermorhen.fyi` |

Built to shrink documents to the byte caps that upload forms impose, without
handing them to an online compressor. Design, rationale and the alternatives
that were rejected: [proposal 009](../../../docs/proposals/009-document-shrinker.md).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholders; the real `.env` is `chmod 600` and VM-only

## Why two tools

PDFs and images fail differently. Getting a scan under a cap means re-encoding
the images inside it, which is Ghostscript and qpdf work and needs real CPU;
Stirling wraps that pipeline and exposes a target-size field. A JPEG, by
contrast, can be binary-searched to an exact byte budget in the browser, which
is what Mazanoke does — so the photo of your passport never travels at all.

**Stirling must be the Full image.** `latest-ultra-lite` is 320 MB against
1.0 GB and looks like an easy win, but upstream's version matrix lists
`compress-pdf` as Full-only. Compress is the entire point of this stack.

## Where the documents go

- **Mazanoke: nowhere.** It is an nginx serving a static bundle; the
  compression runs in the browser tab. No volumes, by design.
- **Stirling: through RAM, not onto the disk.** Version 2 keeps the working
  set in the browser's IndexedDB, but each individual operation still uploads
  the file and runs Ghostscript on ciri. `/tmp` is therefore a **tmpfs**:
  `system.tempFileManagement.baseTmpDir` defaults to `<java.io.tmpdir>/stirling-pdf`,
  so putting `/tmp` in RAM keeps every working copy off the zvol, out of ZFS
  snapshots and out of the nightly PBS job. `SYSTEM_TEMPFILEMANAGEMENT_MAXAGEHOURS=1`
  bounds how much can pile up in that 1 G before the half-hourly cleanup runs.
- **`STORAGE_ENABLED` and `STORAGE_SHARING_ENABLED` are off.** Both are off
  upstream too; they are set explicitly so a change of default cannot turn
  server-side file storage on quietly.
- **The residue is on the phone.** Because v2 uses IndexedDB, documents
  persist in the browser's site storage after the tab closes. Clearing site
  data for `pdf.kaermorhen.fyi` is the cleanup.

Only `./stirling/configs/` is persistent, holding settings and the user
database. It rides the nightly PBS job with the rest of `/data`.

## Auth

**Stirling's own login is on, deliberately.** Caddy is in LXC 202 on
yennefer, so Stirling must publish a port on ciri's LAN address for Caddy to
reach it, and that port bypasses anything Caddy adds. Auth at the proxy would
protect the pretty URL and leave `<LAN_PREFIX>.150:8081` open to the LAN and
the tailnet. Same reasoning as proposal 008 §4.

`SECURITY_INITIALLOGIN_*` seeds the admin account on first start so the
documented `admin` / `stirling` default is never live. Once the account
exists, `/configs` is the source of truth and both variables can be dropped.

**Mazanoke's basic auth** needs `USERNAME` *and* `PASSWORD`; with either
missing it is not applied at all. There is no data behind that gate, only an
open compressor, so if the browser prompt ever breaks the home-screen install
it is fine to drop both.

## Phone use

Both are responsive web apps behind the wildcard cert from
[proposal 003](../../../docs/proposals/003-reverse-proxy.md), so an iPhone
gets a valid padlock with no custom root to install.

Mazanoke is an installable PWA and works offline once installed. That
**requires HTTPS**: a service worker only runs in a secure context, so reach
it at `https://img.kaermorhen.fyi`, never at `<LAN_PREFIX>.150:3474` over
plain HTTP.

## Gotchas

- **Host port 8081, container port 8080.** Stirling listens on 8080 inside
  the container and that does not change; qBittorrent already holds 8080 on
  ciri through gluetun's netns.
- **Compress-to-target was broken through v1.3.x** — it ignored the requested
  size and returned the smallest possible file, spending quality nobody asked
  for (upstream issue 4442, closed via PR 4703). Worth re-testing after any
  version bump: compress something already under the cap and check it is not
  shrunk to the minimum.
- **Stirling is a Spring app** and is slow to start. Wait for the port line in
  the logs before deciding it is broken.
- **Open-core since v1.0.** Compress, merge, split, OCR and convert are in the
  MIT-licensed part; the proprietary directories and the five-user limit cover
  SSO, text editing and admin controls, none of which this stack uses.

## The exact-cap fallback

When a portal's cap is tighter than either UI will reach, the deterministic
route is [`scripts/docs/shrink-to-size.sh`](../../../scripts/docs/README.md).
