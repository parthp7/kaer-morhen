# Proposal 009 — Document shrinker: Stirling-PDF + Mazanoke on ciri

- **Status**: **BUILT and verified 2026-09-02.** Both containers run on ciri
  with the pinned tags, both names are served over the wildcard certificate,
  both Kuma monitors are green, and every document in the repo is
  byte-identical to what is deployed. "As-built deviations" records the three
  facts verification turned up. Remaining, and needing a real document and a
  phone rather than a shell: the compression-quality tests (C3, C4), the
  home-screen install and offline test (C5, C6), and the fallback script's
  Ghostscript and ImageMagick paths (C9).
- **Date**: 2026-09-02
- **Scope**: one new compose stack `shrink` on **ciri** (Stirling-PDF +
  Mazanoke); two Caddy routes; two Pi-hole records; two Kuma monitors; one
  standalone helper script in `scripts/docs/`. **No existing stack is
  touched**, nothing is restarted, and no host packages are installed except
  the two the helper script declares (optional, §6).
- **Decisions taken up front (2026-09-02)**: two tools rather than one, split
  by file type (§2); Stirling's **Full** image, not `ultra-lite`, because
  compress is Full-only (§2); Stirling's own login stays **on** rather than
  relying on Caddy, for the same reason proposal 008 §4 gave for Homepage
  (§5); Stirling's working directory is a **tmpfs**, so no document ever
  reaches the zvol or the nightly PBS job (§4); telemetry off (§5).

Addresses use `<LAN_PREFIX>` per `CLAUDE.md` and the last-octet convention from
[network.md](../network.md). `kaermorhen.fyi` is written in full, as decided in
[proposal 003](003-reverse-proxy.md).

---

## 0. Execution contract (read first if you are the agent running this)

- **The human runs every command that changes state.** The agent hands over
  exact commands, then verifies with read-only checks (`docker ps`, `curl`,
  `df`). Same contract as proposals 005–008.
- **Order matters only across phases**: A (stack) → B (proxy, DNS, Kuma) →
  C (verify) → D (mirror). Inside a phase, steps are independent.
- **Rollback**: `docker compose down` in the stack dir removes everything on
  ciri; revert the two Caddyfile blocks and the two `dns.hosts` entries. No
  other host state changes at all.
- **Do not publish the routes before the containers answer.** Proposal 003 §3
  records what a permanently-502 name costs: it trains you to ignore a red
  check. Phase B comes after Phase A for that reason.

## 1. The requirement

From the 2026-09-02 session: *"reduce size of PDFs to meet required
constraints for uploading to important websites. I can't use online tools due
to sensitive nature of documents. A UI to do it locally… accessible from
phone."*

| Requirement | Verdict | How |
|---|---|---|
| Shrink a PDF to a **stated** size, not just "smaller" | **Kept — hard** | Stirling's Compress takes an explicit target output size (§6) |
| Shrink an image to a stated size | **Kept — hard** | Mazanoke's target-file-size field (§6) |
| Never leaves the lab | **Kept — hard** | Both self-hosted; Mazanoke never even reaches the server (§4) |
| A UI, usable **from a phone** | **Kept — hard** | Both are responsive web apps behind the existing wildcard cert; Mazanoke installs to the home screen (§3) |
| Open source | **Kept** | Stirling core MIT, Mazanoke GPL-3.0 (§9) |
| Exact byte budgets the UIs cannot hit | **Softened** | a deterministic script as the fallback, not a third service (§6) |
| One tool for everything | **Dropped** | nothing open source does both file types well against a byte budget (§2) |

## 2. Why two tools, not one

The two file types have different failure modes, and no single open-source
project handles both against a hard byte budget.

**PDFs are a server problem.** Getting a scan under a cap means re-encoding
the images inside it: downsampling, then grayscale, then stream
recompression. That is Ghostscript and qpdf work, it needs real CPU, and it is
not something to run on a phone. Stirling-PDF wraps exactly that pipeline and
exposes a target-size field.

**Images are a client problem.** A JPEG can be binary-searched to an exact
byte budget in milliseconds, in WebAssembly, in the browser. Mazanoke does
that, which means the photo of your passport never travels anywhere at all —
strictly better than any server-side compressor for this use case, including
one on your own hardware.

**Stirling must be the Full image.** `latest-ultra-lite` is 320 MB against
1.0 GB and would be tempting, but upstream's own version matrix lists
`compress-pdf` as **Full only**. Compress is the entire point of this stack,
so the small image is not an option. Do not "optimise" the tag later.

## 3. Target architecture

```
phone / laptop ──HTTPS──▶ Caddy (LXC 202) ──▶ pdf.kaermorhen.fyi → ciri:8081  Stirling-PDF
   (LAN or tailnet)                        ──▶ img.kaermorhen.fyi → ciri:3474  Mazanoke

ciri (VM 150) — compose stack `shrink`
  stirling-pdf   Java + Ghostscript + qpdf; /tmp on tmpfs; /configs on /data
  mazanoke       static nginx; the browser does the work; no volumes at all
```

| Piece | Where | Detail |
|---|---|---|
| Stirling-PDF | ciri, `docker.io/stirlingtools/stirling-pdf:2.14.3` (2026-08-06) | host port **8081** — 8080 on ciri is qBittorrent's, published from gluetun's netns. Login on, analytics off, `/tmp` on tmpfs |
| Mazanoke | ciri, `ghcr.io/civilblur/mazanoke:v1.1.6` (2026-05-09) | host port **3474** (its default, free on ciri). Static server, basic auth, installable PWA |
| Routes | Caddy LXC 202 | `pdf` and `img` under `kaermorhen.fyi` (Appendix D); Pi-hole `dns.hosts` → `.202` |
| Monitors | Kuma LXC 104 | one HTTP monitor per published port |
| Helper | repo `scripts/docs/shrink-to-size.sh` | run by hand; not wired into any service (§6) |

Both ports were confirmed free on ciri on 2026-09-02, and neither collides
with the 3010 and 1337 that [proposal 008](008-lab-dashboard.md) reserves.

## 4. Where the documents actually go

This is the section that matters, given what the stack is for.

**Mazanoke: nowhere.** It compiles to a static bundle plus WebAssembly. The
container is an nginx serving files; the compression runs in the browser tab.
The image is read from the phone's own storage, resized on the phone, and
saved back to the phone. Nothing crosses the network but the app itself, and
that is cached after the first load.

**Stirling: through ciri's RAM, and not onto its disk.** Version 2 keeps your
working set in the **browser's IndexedDB**, not on the server — the maintainer
states this directly. Each individual operation still uploads the file, runs
Ghostscript on ciri, and streams the result back, so a working copy exists
server-side for the length of the operation. Two things constrain it:

- **`/tmp` is a tmpfs** (Appendix A). Working copies live in RAM, never touch
  the `/data` zvol, and therefore never enter geralt's nightly PBS job or a
  ZFS snapshot. They vanish on container restart. This is cheaper and more
  certain than tuning a cleanup interval, and it does not depend on the
  config keys flagged as unverified in §10.
- **Server-side storage and sharing stay off.** `STORAGE_ENABLED` is an
  opt-in alpha feature that persists files and hands out links. It is off by
  default; the compose file sets it off explicitly so a future default change
  cannot quietly turn it on.

**The residue is on the phone, not the lab.** Because v2 uses IndexedDB, the
documents persist in the phone browser's site storage after the tab closes.
Clearing site data for `pdf.kaermorhen.fyi` is the cleanup. Worth knowing
before handing anyone the phone.

**Only `/configs` is persistent**, holding Stirling's settings and its user
database. It sits on `/data` and is backed up with everything else.

## 5. Access, secrets, telemetry

**Stirling's login stays on.** Caddy is in LXC 202 on yennefer, so Stirling
must publish a port on ciri's LAN address for Caddy to reach it, and that port
bypasses anything Caddy adds. Auth at the proxy would protect the pretty URL
and leave `<LAN_PREFIX>.150:8081` open to the LAN and the tailnet. This is the
same argument proposal 008 §4 made for Homepage, and it lands the same way:
the app holds its own gate, Caddy stays a plain `reverse_proxy`.

The default credentials are `admin` / `stirling`. **Changing them is not
optional** and is the first verification step in Phase A.

**Mazanoke gets basic auth too**, via its `USERNAME` / `PASSWORD` pair. There
is no data behind it to steal, so this is only about not leaving an open
service on the tailnet. It costs one env pair. If test E6 shows the browser
prompt breaking the home-screen install, drop both variables and accept an
open compressor — the privacy property of Mazanoke does not depend on its
auth.

**Telemetry off.** `SYSTEM_ENABLEANALYTICS=false`. An instance that sees
passports and bank statements does not phone home, and the prompt on first run
is one more thing to get wrong.

Keys to add to `secrets.local.yaml`:

| Key | Purpose |
|---|---|
| `STIRLING_USER` / `STIRLING_PASSWORD` | Stirling's admin login |
| `MAZANOKE_USER` / `MAZANOKE_PASSWORD` | Mazanoke basic auth |

## 6. Recipes — constraint to knob

The portals that force this usually state a cap, sometimes with pixel
dimensions attached. What to reach for:

| Constraint | Tool | Setting |
|---|---|---|
| PDF under a stated size | Stirling → Compress | "Expected output size", enter the cap |
| PDF still too big at max compression | Stirling → Compress | tick grayscale, then re-run |
| Scanned PDF that must go very small | Stirling → Compress | grayscale + the aggressive levels; below roughly 100 KB this is an image problem, not a stream-compression one |
| Photo under a stated size | Mazanoke | target file size |
| Photo with both a size cap and pixel dimensions | Mazanoke | max width/height first, then target size |
| HEIC from an iPhone that the portal rejects | Mazanoke | convert to JPG, same pass |
| A cap neither UI quite hits | `scripts/docs/shrink-to-size.sh` | `shrink-to-size.sh scan.pdf 200` |

**The helper script** (Appendix C) exists because the UIs iterate towards a
target while ImageMagick and Ghostscript can be driven at it directly.
`-define jpeg:extent=` makes ImageMagick binary-search its own quality to land
under a byte budget in a single pass; for PDFs the script steps down a DPI
ladder and only spends grayscale if downsampling alone was not enough. It also
strips EXIF, which removes the GPS coordinates a phone photo of a document
carries.

It needs `ghostscript` and `imagemagick` on whatever machine runs it, and it
is deliberately **not** wired into any service. OliveTin, arriving with
proposal 008, has no file-upload argument type, so the only wiring available
would be a watched folder — worse than either UI for a one-off shrink.

## 7. Resource budget

| Item | Cost | Against |
|---|---|---|
| Stirling image | ~1.0 GB on `/data` | 67 GB free on 2026-09-02 |
| Stirling JVM, idle | a few hundred MB RSS | ciri has ~20 GB available |
| Stirling `/tmp` tmpfs | up to 1 GB of RAM, only while working | same |
| Mazanoke image | ~27 MB compressed (amd64) | — |
| Mazanoke runtime | nginx serving static files | negligible |

Compression is CPU-bound and bursty. It shares six vCPUs with the *arr stack
and Ollama; a large scan will spike one core for a few seconds. Nothing here
competes for the GPU.

## 8. Monitoring, backups, maintenance

- **Kuma** (LXC 104): HTTP monitor on `http://<LAN_PREFIX>.150:8081` and
  `http://<LAN_PREFIX>.150:3474`, ntfy notification on, per the pattern in
  [uptime-kuma.md](../uptime-kuma.md). Monitor the ports, not the Caddy names,
  so a proxy problem and an app problem stay distinguishable.
- **Beszel** already reports both containers' CPU and memory through ciri's
  agent, with no configuration.
- **Backups**: `/data/stacks/shrink/` rides geralt's nightly `--all` PBS job.
  The only state worth restoring is Stirling's `/configs`. The tmpfs is
  excluded by construction (§4).
- **Maintenance**: two rows in the version registry in
  [maintenance.md](../maintenance.md), bumped in the quarterly ciri pass.
  Stirling ships often, so expect it to be the moving one.

## 9. Alternatives considered

| Candidate | Why not |
|---|---|
| **ImgCompress** (GPL-3.0) | Server-side, so the image leaves the phone, and target-size compression is not in its documented feature list. Genuinely better at exotic inputs — RAW, PSD, 70-plus formats — so revisit if that ever comes up |
| **Stirling `ultra-lite`** | 320 MB instead of 1.0 GB, but `compress-pdf` is Full-only. Fails on the one feature needed |
| **Paperless-ngx** (already deployed) | Archives and OCRs documents. It has no notion of compressing to a budget. Not a candidate, despite sitting right next door |
| **Script only, no UI** | Exact and free, but unusable from a phone, which was a stated requirement |
| **Gotenberg, pdfcpu, ocrmypdf** | API or CLI only, and none targets a byte budget |
| **Online compressors** | Excluded by the requirement |

## 10. Gotchas and pre-flight facts for the executing agent

Verified on 2026-09-02 unless marked otherwise.

1. **`compress-pdf` is absent from `ultra-lite`.** Confirmed against
   upstream's version matrix. Repeated here because the size difference makes
   the wrong tag look like an easy win.
2. **Compress-to-target was broken through v1.3.x** — it ignored the requested
   size and returned the smallest possible file, spending quality nobody asked
   for (issue 4442, closed via PR 4703). Tests E3 and E4 exist specifically to
   prove 2.14.3 behaves. Do not skip them.
3. **`SECURITY_INITIALLOGIN_*` — RESOLVED 2026-09-02.** Upstream's
   `settings.yml.template` carries `security.initialLogin.username` and
   `.password`, both defaulting to empty, so the environment forms are real
   and the compose file seeds the admin account with them. The documented
   `admin` / `stirling` default therefore never goes live. Test C2 still
   proves the gate itself.
4. **The temp-directory keys — RESOLVED 2026-09-02, and the earlier source was
   wrong.** There is no `stirling.tempDir`. The real setting is
   `system.tempFileManagement.baseTmpDir`, which defaults to
   `<java.io.tmpdir>/stirling-pdf` — that is *under* `/tmp`, so the tmpfs
   covers it with no configuration at all. The neighbouring defaults are
   `maxAgeHours: 24` and `cleanupIntervalMinutes: 30`; a day of scans
   accumulating in a 1 G tmpfs is worth avoiding, so the compose file sets
   `SYSTEM_TEMPFILEMANAGEMENT_MAXAGEHOURS=1`.
5. **The login docs mention `DISABLE_ADDITIONAL_FEATURES` and a separate
   with-login jar.** That is v1-era packaging. The v2 Docker image ships with
   login on by default, which is why this design does not set that variable.
6. **Host port 8081, container port 8080.** Stirling listens on 8080 inside
   the container and that does not change. Only the host side moves, because
   qBittorrent already holds 8080 on ciri through gluetun's netns.
7. **Mazanoke basic auth against PWA install is untested** — that is E6, and
   §5 states the fallback.
8. **Stirling v2 leaves your working set in the browser's IndexedDB.** On a
   phone that means it survives closing the tab. Clearing site data is the
   cleanup (§4).
9. **A service worker requires a secure context**, so Mazanoke must be reached
   at `https://img.kaermorhen.fyi` for install-to-home-screen and offline mode
   to work at all. Reaching it at `<LAN_PREFIX>.150:3474` over plain HTTP
   silently disables the half of Mazanoke that makes it good on a phone.
10. **The helper script's compression paths are UNTESTED.** Its argument
    validation, type whitelist, dependency checks and under-budget shortcut
    were exercised on 2026-09-02, it is `shellcheck`-clean, and it runs on
    **bash 3.2**, which is what macOS ships — but neither `gs` nor `magick`
    exists on the machine it was written on, so the ghostscript ladder and the
    `jpeg:extent` call have never run. That is what test C9 is for.
11. **Stirling is open-core since v1.0.** Compress, merge, split, OCR and
    convert are in the MIT-licensed part. The proprietary directories and the
    five-user limit cover SSO, text editing and admin controls, none of which
    this stack uses. A single-user lab is unaffected.

---

## Phase A — the stack on ciri

### A1. Directories and files

```bash
mkdir -p /data/stacks/shrink/stirling/configs /data/stacks/shrink/stirling/logs
cd /data/stacks/shrink
# compose.yaml from Appendix A, .env from Appendix B
chmod 600 .env
```

### A2. Bring it up

```bash
cd /data/stacks/shrink
docker compose config          # renders? every ${VAR:?} satisfied?
docker compose up -d
docker compose ps
docker compose logs --tail 50 stirling
```

Stirling is a Spring application and takes a while on first start. Wait for
the log line announcing the port before testing.

*(verify)* `curl -sI http://<LAN_PREFIX>.150:8081/ | head -1` and
`curl -sI http://<LAN_PREFIX>.150:3474/ | head -1`.

### A3. Credentials

1. Open `http://<LAN_PREFIX>.150:8081` and log in. If the `.env` credentials
   are not accepted, use `admin` / `stirling` (§10 item 3).
2. Change the admin password to `STIRLING_PASSWORD` in Settings.
3. Confirm a logged-out browser cannot reach any tool.

## Phase B — proxy, DNS, Kuma

### B1. Caddyfile (LXC 202) — Appendix D, then:

```bash
caddy adapt --config /etc/caddy/Caddyfile && set -a && . /etc/caddy/cloudflare.env && set +a \
  && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### B2. Pi-hole records (pihole-1 only; replace-not-append — read first)

```bash
pct exec 101 -- pihole-FTL --config dns.hosts       # current array
pct exec 101 -- pihole-FTL --config dns.hosts '[ …all existing…, "<LAN_PREFIX>.202 pdf.kaermorhen.fyi", "<LAN_PREFIX>.202 img.kaermorhen.fyi" ]'
# on ciri: force the sync to pihole-2
docker compose -f /data/stacks/nebula-sync/compose.yaml run --rm sync-now
```

### B3. Kuma monitors — two HTTP monitors per §8, ntfy notification on.

## Phase C — verification (the contract tests)

| # | Test | Pass |
|---|---|---|
| C1 | `https://pdf.kaermorhen.fyi` on LAN and over the tailnet | login page, valid certificate, no warning on iPhone |
| C2 | `http://<LAN_PREFIX>.150:8081/` bypassing Caddy | still asks for the password |
| C3 | Compress a real multi-megabyte scan to a stated target | output under the cap **and** still legible |
| C4 | Compress a file already under the target | output is not shrunk to the minimum (the 4442 regression) |
| C5 | `https://img.kaermorhen.fyi` on the phone → install to home screen → airplane mode | app opens offline and still compresses |
| C6 | Same, with Mazanoke basic auth enabled | install and offline mode survive the prompt; if not, drop the two variables (§5) |
| C7 | `docker exec stirling-pdf ls -la /tmp` after a compress, then `docker compose restart stirling` | files present during work, gone after; `du -sh /data/stacks/shrink` barely moves |
| C8 | Kuma: `docker stop stirling-pdf` for 2 minutes | phone alert, then resolved on start |
| C9 | `shrink-to-size.sh scan.pdf 200` twice on the same input | both runs land under budget, identical result, input untouched |

## Phase D — as-built mirroring (only after C passes)

- `scp` the live `compose.yaml` into `configs/ciri/shrink/` **verbatim**, add
  `.env.example` with placeholders and a README (the `CLAUDE.md` mirror rule).
- `configs/yennefer/proxy/Caddyfile` — the two new matcher blocks.
- `scripts/docs/shrink-to-size.sh` + a README, `shellcheck`-clean.
- [dns.md](../dns.md): two records added, `dns.hosts` count +2.
- [docker-vm.md](../docker-vm.md): a `shrink` row in the Stacks table.
- [maintenance.md](../maintenance.md): the two version-registry rows from §8.
- [uptime-kuma.md](../uptime-kuma.md): the two monitors.
- This file: Status → **Built**, plus "As-built deviations".

## As-built deviations (2026-09-02)

Deployed and verified the same day it was designed. The design needed no
changes; three facts came out of verification that the plan had not stated.

1. **Only one of the two broke a default Kuma monitor, for a reason worth
   keeping.** The plan assumed a login meant a monitor problem; that is true
   for one service and not the other. Stirling's Spring Security
   content-negotiates its rejection — an API-style `Accept: */*` gets a bare
   401, a browser-style `Accept: text/html` gets a 302 to `/login` which
   renders 200 — so Kuma passes on a plain HTTP monitor and is genuinely
   proving the app renders. Mazanoke's nginx answers 401 to every HTML path
   regardless of `Accept`, so its monitor needed Kuma's HTTP Basic Auth. The
   lesson generalises: **`curl -I` is not what Kuma sends**, so a bare 401 by
   hand does not predict a red monitor.
2. **Mazanoke's basic auth does not cover every path.** `/manifest.json` and
   `/favicon.ico` return 200 unauthenticated, while `/index.html`,
   `/sw.js` and `/manifest.webmanifest` return 401. That is presumably
   deliberate, to keep the install prompt working. It is a usable
   unauthenticated health target but a fragile one, since nothing documents
   it and a version bump could change the list.
3. **The tmpfs assumption is confirmed empirically.** `/tmp/stirling-pdf`
   exists inside the tmpfs mount, so §4's claim that working copies never
   reach the zvol is now observed rather than inferred. Persistent state for
   the whole stack is 216 KB, all of it Stirling's settings and H2 database.

Verified on 2026-09-02: both containers up with the pinned tags, Stirling
reporting healthy and `2.14.3`; the tmpfs mounted at 1 G; the bare port at
8081 returning 401, which is test C2; both names resolving to `.202` and
served over the wildcard Let's Encrypt certificate valid to 2026-11-10.

## Follow-ups (not in scope)

- **Homepage tiles** once [proposal 008](008-lab-dashboard.md) lands: link
  tiles in the Apps group, with status dots and stats via the socket proxy by
  container name. No widget exists upstream for either app.
- **OCR** is already inside the Full image. If a portal ever demands a
  searchable PDF rather than a small one, the tool is there at no extra cost.
- **ImgCompress** if RAW, PSD or HEIC batches ever matter more than keeping
  the file on the phone (§9).

---

# Appendix A — `compose.yaml` (→ `ciri:/data/stacks/shrink/`)

```yaml
# Stack: shrink — local PDF and image size reduction for upload forms.
# Design + runbook: docs/proposals/009-document-shrinker.md
# Mirror of ciri:/data/stacks/shrink/compose.yaml (CLAUDE.md mirror rule).
#
# The point of this stack is that sensitive documents never leave the lab.
# Two consequences are load-bearing, not cosmetic:
#   - stirling's /tmp is a tmpfs, so working copies live in RAM and never
#     reach the zvol, a ZFS snapshot, or the nightly PBS job;
#   - mazanoke has no volumes at all, because it compresses in the browser.

services:
  stirling:
    image: docker.io/stirlingtools/stirling-pdf:2.14.3
    container_name: stirling-pdf
    restart: unless-stopped
    ports:
      # 8080 on ciri is qBittorrent's, published from gluetun's netns.
      # The container port stays 8080; only the host side moves.
      - "8081:8080"
    volumes:
      - ./stirling/configs:/configs
      - ./stirling/logs:/logs
    tmpfs:
      # settings.yml.template: system.tempFileManagement.baseTmpDir defaults to
      # <java.io.tmpdir>/stirling-pdf, i.e. under /tmp. Putting /tmp in RAM is
      # therefore enough to keep every working copy off the disk.
      - /tmp:rw,noexec,nosuid,nodev,size=1g
    environment:
      TZ: Asia/Kolkata
      SYSTEM_DEFAULTLOCALE: en-GB
      # Upstream default is null, which prompts the admin on first launch.
      # This instance sees passports and bank statements: answer it here.
      SYSTEM_ENABLEANALYTICS: "false"
      # Login stays ON: the published LAN port bypasses Caddy entirely, so
      # auth has to live in the app (proposal 008 §4 made the same call).
      SECURITY_ENABLELOGIN: "true"
      # Seeds the admin account on first start instead of leaving the
      # documented admin/stirling default in place. Safe to delete once the
      # account exists — /configs is the source of truth from then on.
      SECURITY_INITIALLOGIN_USERNAME: ${STIRLING_USER:?set in .env}
      SECURITY_INITIALLOGIN_PASSWORD: ${STIRLING_PASSWORD:?set in .env}
      # Default is 24 h, which lets a 1 G tmpfs accumulate a day of scans in
      # RAM. Cleanup runs every 30 min by default, so 1 h bounds it tightly.
      SYSTEM_TEMPFILEMANAGEMENT_MAXAGEHOURS: "1"
      # Server-side storage and link sharing are off upstream too. Set them
      # explicitly so a future change of default cannot turn them on quietly.
      STORAGE_ENABLED: "false"
      STORAGE_SHARING_ENABLED: "false"

  mazanoke:
    image: ghcr.io/civilblur/mazanoke:v1.1.6
    container_name: mazanoke
    restart: unless-stopped
    ports:
      - "3474:80"
    environment:
      TZ: Asia/Kolkata
      # Both must be set or basic auth is not applied at all. If the browser
      # prompt breaks the home-screen install (test C6), delete both — there
      # is no data behind this gate, only an open compressor.
      USERNAME: ${MAZANOKE_USER:?set in .env}
      PASSWORD: ${MAZANOKE_PASSWORD:?set in .env}
```

# Appendix B — `.env.example` (→ `configs/ciri/shrink/`)

```dotenv
# Copy to .env on ciri, fill in, chmod 600. Never commit the real file.
# Real values belong in secrets.local.yaml.

# Stirling-PDF admin account, seeded on first start.
STIRLING_USER=<STIRLING_USER>
STIRLING_PASSWORD=<STIRLING_PASSWORD>

# Mazanoke basic auth. Both must be set or auth is not applied at all.
MAZANOKE_USER=<MAZANOKE_USER>
MAZANOKE_PASSWORD=<MAZANOKE_PASSWORD>
```

# Appendix C — `shrink-to-size.sh` (→ `scripts/docs/`, 0755)

```bash
#!/usr/bin/env bash
# shrink-to-size.sh — shrink a PDF or image to fit a byte budget.
#
# Purpose: the deterministic fallback for upload forms with a hard cap that
#          Stirling-PDF or Mazanoke cannot quite hit. Both UIs iterate towards
#          a target; ghostscript and imagemagick can be driven straight at it.
# Usage:   shrink-to-size.sh <input> <target-kb> [output]
#            shrink-to-size.sh scan.pdf 200
#            shrink-to-size.sh photo.heic 50 signature.jpg
# Needs:   ghostscript (PDFs) and imagemagick 7 (images) on PATH.
#          ciri: sudo apt install ghostscript imagemagick
#          mac:  brew install ghostscript imagemagick
# Output:  <name>-<target>kb.<ext> beside the input unless a third argument
#          names one. Never overwrites the input; re-running rebuilds the
#          output from the input, never from a previous output.
# Note:    -strip drops EXIF, which is where a phone photo of a document keeps
#          its GPS coordinates.

set -euo pipefail

die() { printf 'shrink-to-size: %s\n' "$*" >&2; exit 1; }
size_of() { wc -c < "$1" | tr -d '[:space:]'; }

(( $# >= 2 && $# <= 3 )) || die "usage: $(basename "$0") <input> <target-kb> [output]"

in=$1
target_kb=$2
[[ -f $in ]] || die "no such file: $in"
[[ $target_kb =~ ^[1-9][0-9]*$ ]] || die "target-kb must be a positive integer, got: $target_kb"

target_bytes=$(( target_kb * 1024 ))
orig=$(size_of "$in")
base=${in%.*}
ext=$(printf '%s' "${in##*.}" | tr '[:upper:]' '[:lower:]')

# Validate the type BEFORE the size shortcut below, so an unsupported file
# that happens to be small cannot exit 0 looking like a success.
case $ext in
  pdf|jpg|jpeg|png|webp|heic|heif|tif|tiff|bmp) ;;
  *) die "unsupported extension: .$ext (pdf, jpg, jpeg, png, webp, heic, heif, tif, tiff, bmp)" ;;
esac

if (( orig <= target_bytes )); then
  printf 'already %d KB, inside the %d KB budget — nothing to do\n' \
    "$(( orig / 1024 ))" "$target_kb"
  exit 0
fi

case $ext in
  pdf)
    command -v gs >/dev/null 2>&1 || die "ghostscript (gs) not on PATH"
    out=${3:-${base}-${target_kb}kb.pdf}
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    got=$orig
    # Colour before grayscale: dropping colour is a visible change, so only
    # spend it once downsampling alone has failed at every step.
    for mode in color gray; do
      for dpi in 200 150 120 100 72 50; do
        args=(
          -sDEVICE=pdfwrite -dCompatibilityLevel=1.7
          -dNOPAUSE -dBATCH -dQUIET
          -dDetectDuplicateImages=true -dCompressFonts=true -dSubsetFonts=true
          -dDownsampleColorImages=true -dColorImageDownsampleType=/Bicubic
          -dColorImageResolution="$dpi"
          -dDownsampleGrayImages=true -dGrayImageDownsampleType=/Bicubic
          -dGrayImageResolution="$dpi"
          -dDownsampleMonoImages=true -dMonoImageDownsampleType=/Subsample
          -dMonoImageResolution=$(( dpi * 2 ))
        )
        if [[ $mode == gray ]]; then
          args+=(-sColorConversionStrategy=Gray -dProcessColorModel=/DeviceGray)
        fi
        gs "${args[@]}" -sOutputFile="$tmp/try.pdf" "$in"
        got=$(size_of "$tmp/try.pdf")
        if (( got <= target_bytes )); then
          cp "$tmp/try.pdf" "$out"
          printf '%s: %d KB -> %d KB (%s, %d dpi)\n' \
            "$out" "$(( orig / 1024 ))" "$(( got / 1024 ))" "$mode" "$dpi"
          exit 0
        fi
      done
    done
    die "cannot reach ${target_kb} KB; the smallest attempt was $(( got / 1024 )) KB at 50 dpi grayscale. Split the document or drop pages."
    ;;
  *)
    # Images. The extension was whitelisted above, so this is not a catch-all.
    command -v magick >/dev/null 2>&1 || die "imagemagick 7 (magick) not on PATH"
    # jpeg:extent only applies to JPEG output, which is why the default
    # output extension is .jpg whatever went in.
    out=${3:-${base}-${target_kb}kb.jpg}
    magick "$in" -auto-orient -strip -define jpeg:extent="${target_kb}kb" "$out"
    got=$(size_of "$out")
    (( got <= target_bytes )) || die "landed at $(( got / 1024 )) KB, over budget. Add a resize: magick '$in' -resize 50% -strip -define jpeg:extent=${target_kb}kb '$out'"
    printf '%s: %d KB -> %d KB\n' "$out" "$(( orig / 1024 ))" "$(( got / 1024 ))"
    ;;
esac
```

# Appendix D — Caddyfile blocks (→ LXC 202 `/etc/caddy/Caddyfile`)

Add to the existing wildcard site block, after `@sure`, under the
"Photos, docs, notes" heading.

```caddyfile
	@pdf host pdf.kaermorhen.fyi
	handle @pdf {
		# Stirling-PDF. Uploads are whole scans, so lift the body cap the
		# same way immich and paperless above do.
		request_body {
			max_size 0
		}
		reverse_proxy <LAN_PREFIX>.150:8081
	}

	@img host img.kaermorhen.fyi
	handle @img {
		# Mazanoke compresses in the browser, so no image ever crosses this
		# hop — there is nothing to lift a body cap for. HTTPS here is what
		# makes install-to-home-screen and offline mode work at all: a
		# service worker requires a secure context.
		reverse_proxy <LAN_PREFIX>.150:3474
	}
```

## Sources

Checked 2026-09-02.

- Stirling-PDF: [repository](https://github.com/Stirling-Tools/Stirling-PDF),
  [licence](https://github.com/Stirling-Tools/Stirling-PDF/blob/main/LICENSE)
  (MIT, with named proprietary directories excluded),
  [Docker install](https://docs.stirlingpdf.com/Installation/Docker%20Install),
  [version matrix](https://docs.stirlingpdf.com/Installation/Versions/)
  (`compress-pdf` is Full-only),
  [system and security settings](https://docs.stirlingpdf.com/Configuration/Security/System%20and%20Security/),
  [file sharing and storage](https://docs.stirlingpdf.com/Configuration/Storage/File-Sharing-Storage/),
  [issue 4442](https://github.com/Stirling-Tools/Stirling-PDF/issues/4442)
  (target size ignored through v1.3.x, closed via PR 4703),
  [discussion 5021](https://github.com/Stirling-Tools/Stirling-PDF/discussions/5021)
  (maintainer: v2 file storage is the browser's, not the server's).
- Mazanoke: [repository](https://github.com/civilblur/mazanoke) (GPL-3.0,
  target file size, installable PWA),
  [configuration](https://github.com/civilblur/mazanoke/blob/main/docs/configuration.md)
  (`USERNAME` / `PASSWORD`).
- Rejected: [ImgCompress](https://github.com/karimz1/imgcompress) (GPL-3.0,
  server-side).
- Versions and image sizes read from Docker Hub and ghcr.io tag listings:
  Stirling-PDF **2.14.3** (2026-08-06, Full ~1.0 GB, ultra-lite ~320 MB),
  Mazanoke **v1.1.6** (2026-05-09).
