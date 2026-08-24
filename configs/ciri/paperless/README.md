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

**Rollback** is the pre-v3 `pg_dump` + `{data,media}` tarball in
`/data/backups/`, not the image tag — the schema migration is one-way.

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
