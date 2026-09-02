# paperless — document management (ciri stack)

[Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) on **ciri**
(VM 150), live at `ciri:/data/stacks/paperless/`, port **8000**.
Deployed 2026-07-14 at **2.20.15**; upgraded to **3.0.5** on 2026-08-24
(see "v3 upgrade" below — it is a one-way migration with a mandatory config
change).

Services: `webserver` (app + OCR workers), `db` (Postgres 16), `broker`
(Redis), and an opt-in `backup` (daily `pg_dump`, `--profile backup`).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholder template; real `.env` lives only in the VM,
  chmod 600
- `scripts/pre-consume-decrypt.sh` — pre-consume hook that decrypts
  password-protected PDFs on ingest (see "Encrypted PDFs" below)
- `scripts/post-consume-strip-pw.sh` — post-consume hook that removes the
  `__pw=` suffix from the title afterwards
- `scripts/pdf-passwords.example.txt` — placeholder template; the real
  `pdf-passwords.txt` lives only in the VM, chmod 600, git-ignored

## Changes vs the upstream example compose

Based on upstream `docker-compose.postgres.yml`:

- **No tika/gotenberg** — deliberate (2026-07-14): images/PDF ingestion
  only, saves ~1G RAM for future apps. Office/eml files won't be consumable;
  if that's ever needed, add the two services back from upstream's
  `docker-compose.postgres-tika.yml` plus the `PAPERLESS_TIKA_*` env vars.
- **App image pinned** to `ghcr.io/paperless-ngx/paperless-ngx:3.0.5`
  (upstream example uses `latest`).
- **`PAPERLESS_DBENGINE: postgresql` is set explicitly** — mandatory from v3.
- **`PAPERLESS_CONSUMER_DELETE_DUPLICATES: true`** — v3 consumes duplicates by
  default and flags them in the UI; this keeps the v2 behaviour of discarding a
  re-scanned file. Flip it to adopt the new default.
- **Postgres 16 + Redis 7.4-alpine instead of upstream's postgres:18 /
  redis:8** — both supported by paperless, both already pulled on ciri for
  the sure stack, and postgres:16 keeps the familiar
  `/var/lib/postgresql/data` mount point (18 moved it). Accepted deviation
  2026-07-14.
- **Bind mounts instead of named volumes** — `./data`, `./media`,
  `./export`, `./consume`, `./postgres-data`, `./redis-data`, `./backups`
  under the stack dir, so all state lives on the `/data` disk like the
  other stacks.
- **No insecure defaults** — `POSTGRES_PASSWORD` and `PAPERLESS_SECRET_KEY`
  use `${VAR:?}` so compose fails loudly if `.env` is missing (upstream
  hardcodes user/pass `paperless` and ships no secret key).
- **`container_name`s set** (`paperless`, `paperless-db`,
  `paperless-redis`, `paperless-backup`) for readable `docker ps`/Kuma
  targets.
- Same daily `pg_dump` backup sidecar pattern as sure
  (`--profile backup`).
- **`./scripts` mounted read-only + `PAPERLESS_PRE_CONSUME_SCRIPT`** — not in
  upstream. Decrypts password-protected PDFs on ingest; see "Encrypted PDFs"
  below. The image ships no `/usr/src/paperless/scripts`, so the mount
  shadows nothing.
- **`PAPERLESS_POST_CONSUME_SCRIPT`** — also not in upstream; cleans the
  `__pw=` suffix out of the title. Deliberately cannot fail a consume.
- HTTP only, no `PAPERLESS_URL` set — LAN/tailnet access by IP works with
  paperless defaults (`ALLOWED_HOSTS=*`); set `PAPERLESS_URL` only if a
  reverse proxy / DNS name goes in front.

## Layout & ownership (in the VM)

```
/data/stacks/paperless/        ciri:ciri — stack dir, compose.yaml, .env (600)
├── data/                      index, classifier model, logs (uid 1000)
├── media/                     ★ originals + archive PDFs — the documents
├── export/                    document_exporter output target
├── consume/                   drop files here → auto-ingested, then deleted
├── scripts/                   pre-consume hook + pdf-passwords.txt (600, git-ignored)
├── postgres-data/             postgres (uid 999) — metadata/tags DB
├── redis-data/                task queue (regenerable)
└── backups/                   daily pg_dump output (backup profile)
```

As with sure, `postgres-data`/`redis-data` will show as owned by **beszel**
(VM uid-999 collision with the containers' internal uid 999) — cosmetic.

## First-run notes

- Create the admin account (interactive):
  `docker compose run --rm webserver createsuperuser`
- Web UI at `http://<LAN_PREFIX>.150:8000`.
- Ingest test: drop a PDF into `consume/` — it should appear OCR'd in the
  UI within ~a minute; upload via UI works too.
- Upgrades are deliberate: bump the pinned tag in `compose.yaml`, check the
  [release notes](https://github.com/paperless-ngx/paperless-ngx/releases),
  then `docker compose pull && docker compose up -d`.

## Encrypted PDFs (pre-consume decrypt)

Added 2026-09-02. `scripts/pre-consume-decrypt.sh` runs as
`PAPERLESS_PRE_CONSUME_SCRIPT` and strips the open-password from encrypted PDFs
before the parser sees them, so **password-protected files can be uploaded
as-is from any device** — web UI, mobile app, or `consume/` — with no
client-side prep.

**Why it is needed, and why the old behaviour was dangerous.** Paperless has no
concept of a PDF password. OCRmyPDF raises `EncryptedPdfError`, and
`paperless/parsers/tesseract.py:611` *catches* it rather than failing:

> "This file is encrypted and/or signed, OCR is impossible. Using any text
> present in the original file."

The document was therefore created anyway — **empty content, no OCR text, no
archive PDF, and a stored original that still prompts for a password**. It
looked like a clean import and was silently unsearchable. That is the failure
this hook removes.

**Why a pre-consume hook rather than decrypting on the client.** The hook fires
inside `Consumer.run()` (`documents/consumer.py:288`), and web-UI/API uploads
build the same `ConsumableDocument` and dispatch the same `consume_file` task
as the watched folder (`documents/views.py:2021`). One hook therefore covers
every upload path. It rewrites `DOCUMENT_WORKING_PATH` — the scratch copy that
is parsed *and* then stored as the original (`consumer.py:683`, with
`unmodified_original` left `None` on this path) — so the original, the archive
PDF and the thumbnail all come out password-free. `qpdf --decrypt` rewrites
losslessly; it does not re-render, so the text layer survives and OCR is not
reduced to reading an image.

**Passwords, tried in this order:**

1. the **empty** password — files with only an *owner* password (printing/copy
   restrictions, no prompt on open) need no secret and no config;
2. every line of **`scripts/pdf-passwords.txt`** — mode 600, owned by `ciri`
   (uid 1000, which is the container's `paperless` uid), git-ignored, mounted
   read-only. This is the zero-friction path for recurring senders;
3. a **`__pw=` filename suffix**, e.g. `oneoff__pw=hunter2.pdf` — the escape
   hatch for a one-off whose password is not worth storing.

The `__pw=` suffix would otherwise survive into the document title and
`original_filename`, because paperless derives both from the *upload* filename
(`consumer.py:839`) and the pre-consume hook can only rewrite the file's bytes
at a fixed path, never rename it. `scripts/post-consume-strip-pw.sh` therefore
runs as `PAPERLESS_POST_CONSUME_SCRIPT` and rewrites both fields after the fact
— `statement__pw=hunter2` becomes `statement`.

Three things about that hook are load-bearing:

- **It never exits non-zero.** A failing post-consume script makes paperless
  mark the whole consume red even though the document imported fine
  (`POST_CONSUME_SCRIPT_ERROR`), which for a cosmetic cleanup would be actively
  misleading. Everything exits 0; problems go to stderr and land as WARNING.
- **It re-indexes explicitly.** The search index is written by `add_to_index`,
  wired to `document_consumption_finished` (`documents/apps.py:29`), which
  fires *before* post-consume hooks — so without a refresh the index would keep
  the old title: searching the clean name would miss and searching the password
  would hit. It queues `documents.tasks.bulk_update_documents`, the same task
  the REST API uses after an edit.
- **It gates on the marker in shell before bootstrapping Django**, so an
  ordinary upload pays nothing for a hook that is irrelevant to it. The
  bootstrap costs ~8s when it does run, which is why the gate matters.

> ⚠️ The password still passes through the task list and the container logs for
> such an upload, and it is in your shell history if you renamed the file there.
> Prefer the password file for anything recurring; the suffix is for one-offs.

> ⚠️ `PAPERLESS_FILENAME_FORMAT` is unset here, so stored files are named
> `NNNNNNN.pdf` and no password ever reaches a path on disk. If that format is
> ever set to something title-derived, re-check this: the file would be written
> under the `__pw=` name and then moved when the post-consume hook renames it.

**On failure the consume fails loudly.** If no candidate opens the file the
script exits non-zero, which paperless turns into `pre_consume_script_error`
(`documents/utils.py:176` — `check_exit_code` defaults to `True`). The document
is *not* created and the failure is red in the Tasks view. This is deliberate:
the whole point is to never again produce a silently empty document.

Passwords are passed to qpdf on stdin (`--password-file=-`), never in argv, and
are never logged. `qpdf` 12.2.0 is already in the image — no custom Dockerfile.

**Verifying it after a change:**

```bash
docker exec paperless printenv PAPERLESS_PRE_CONSUME_SCRIPT PAPERLESS_POST_CONSUME_SCRIPT
docker exec paperless ls -l /usr/src/paperless/scripts/
docker logs paperless --since 10m 2>&1 | grep -E 'pre-consume-decrypt|post-consume-strip-pw'
# the real assertion — the stored original must not be encrypted (exit 2):
docker exec paperless qpdf --is-encrypted /usr/src/paperless/media/documents/originals/<N>.pdf; echo $?
```

Build a throwaway encrypted test PDF with the tools already in the image:

```bash
docker exec -u paperless paperless bash -c '
cat > /tmp/dt.ps <<EOF
%!PS
/Helvetica findfont 24 scalefont setfont
72 700 moveto (PAPERLESS DECRYPT TEST) show
showpage
EOF
gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -sOutputFile=/tmp/a.pdf /tmp/dt.ps
qpdf --encrypt --user-password=testpw123 --owner-password=own456 --bits=256 -- \
     /tmp/a.pdf "/usr/src/paperless/consume/decrypt-test__pw=testpw123.pdf"'
```

**Verified 2026-09-02** on 3.0.5, first deployment:

| Case | Result |
|---|---|
| `decrypt-test__pw=testpw123.pdf` | matched via filename suffix, decrypted, consumed; content `PAPERLESS DECRYPT TEST ALPHA`, 1 page |
| stored original + archive | `qpdf --is-encrypted` → exit 2 (not encrypted), `--requires-password` → exit 2 |
| `decrypt-negative.pdf` (password in no list) | hook exit 1 → `pre_consume_script_error`, **no document created**, file left in `consume/` |
| mount | `rw=false` — the container cannot alter the hook or the password list |
| `title-test__pw=testpw123.pdf` (post-consume, doc 15) | title and `original_filename` → `title-test`; original + archive not encrypted |
| search index after the rename | `title-test` → `[15]`, `CHARLIE` → `[15]`, `testpw123` → `[14]` only (doc 14 predates the hook) |

> A *successful* match through `pdf-passwords.txt` has not been exercised yet —
> the first test matched via the filename suffix, and the list entry was loaded
> and tried (the log says "loaded N password(s)") but did not match that file.
> The decrypt path itself is shared, so this is a gap in coverage, not a known
> defect.

## v3 upgrade (2026-08-24)

Upgraded 2.20.15 → 3.0.5. Upstream supports the v3 jump **only from 2.20.15**,
which is where this stack already was.

**The footgun.** v3 stopped inferring PostgreSQL from `PAPERLESS_DBHOST`;
`PAPERLESS_DBENGINE` is now required and defaults to `sqlite`. Without it
paperless boots on an empty SQLite file and presents a working, *completely
empty* instance — indistinguishable from total data loss at a glance, while
the Postgres data sits untouched. Verify the engine, not just that the UI
loads:

```bash
docker exec paperless python3 -c "
import os,django; os.environ.setdefault('DJANGO_SETTINGS_MODULE','paperless.settings')
django.setup()
from django.conf import settings; print(settings.DATABASES['default']['ENGINE'])"
# -> django.db.backends.postgresql
```

**Breaking changes that did NOT apply here** (checked against this compose and
`.env` before upgrading): document/thumbnail encryption, `CONSUMER_BARCODE_SCANNER`,
`OCR_MODE`/`OCR_SKIP_ARCHIVE_FILE`, pre/post-consume scripts, and the removed
SSL/timeout variables — none were in use. `PAPERLESS_SECRET_KEY` was already
explicit, so sessions survived. The NumPy `x86-64-v2` floor (which SIGILLs the
classifier on pre-2008 CPUs) is a non-issue: ciri's i7-8750H has SSE4.2.

**What the upgrade did on its own:** applied migrations (including a SHA-256
checksum recompute over all documents), **dropped all task history**, and
rebuilt the search index from scratch — Tantivy replaced Whoosh and the formats
are incompatible. Startup is correspondingly slow; let it finish.

**Search syntax changed.** `note:` → `notes.note:`, `custom_field:` →
`custom_fields.value:`. Saved views with an explicit prefix are migrated
automatically; *unqualified* queries that used to match note/custom-field text
are not, and silently return fewer results.

**Post-upgrade verification (all passed 2026-08-24):** engine is postgresql;
8 active documents + 2 in trash = 10 rows, matching pre-upgrade; index rebuilt
(`needs_rebuild()` → `False`) and full-text queries return hits.

> ⚠️ Note when verifying by shell: `documents.index` no longer exists in v3 —
> the package is `documents.search` (`get_backend`, `needs_rebuild(index_dir)`,
> `SearchMode.QUERY|TEXT|TITLE`). And `search_ids(query, user)` filters by
> viewer permission, so passing the wrong superuser returns **0 hits on a
> perfectly healthy index**. The document-owning account here is `parth`
> (id 4), not the unused `paperless` superuser (id 3).

**Rollback** is *not* the image tag — the schema migration is one-way. What
actually exists (verified 2026-08-24, after the fact):

| Artifact | Covers | Note |
|---|---|---|
| `pbs-vault` snapshot `2026-08-24T15:36:06Z` | **everything**, incl. `postgres-data` | 21:06 IST, ~1 h 20 m before the 22:29 migration. `scsi1` is in the backup set, so this is the complete rollback |
| `/data/backups/paperless-pre-v3-2026-08-24.tar.gz` | `data/` + `media/` only | 14 M; the Whoosh index and document files — **no database** |
| `backups/pre-image-refresh-2026-08-24.sql` | database | 662 K logical dump from **03:06** the same day, i.e. ~19 h stale relative to the upgrade |

> ⚠️ **The intended pre-v3 `pg_dump` was never taken.** The plan called for a
> dump immediately before the migration; only the file tarball was made, and
> `tar -C /data/stacks/paperless data media` does not include `postgres-data/`.
> The PBS snapshot covers the gap here by luck of timing, not by design. For
> the next major: take the dump **and confirm the file exists** before pulling
> the new image — `ls -lh` the artifact, do not assume the command ran.

## Backup story (important)

The `backup` profile only dumps **postgres** (metadata: tags, correspondents,
custom fields). The actual documents are files in `./media` — a pg_dump alone
cannot restore paperless. Until the restic phase of `docs/backups.md` covers
`/data/stacks/paperless/{media,data}`, treat backups as incomplete. The
built-in `document_exporter` (writes a portable full export to `./export`)
is the cleanest single-artifact backup — candidate for a cron later.

## Follow-ups

- DNS name on pihole-1 (nebula-sync mirrors to pihole-2)
- ~~Uptime-Kuma HTTP monitor on `:8000`~~ done 2026-07-14
- Enable `backup` profile after first-run verification
- Fold `media/` + `data/` (or a scheduled `document_exporter` run) into the
  restic phase of `docs/backups.md`
