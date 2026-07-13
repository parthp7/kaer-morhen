# paperless — document management (ciri stack)

[Paperless-ngx](https://github.com/paperless-ngx/paperless-ngx) on **ciri**
(VM 150), live at `ciri:/data/stacks/paperless/`, port **8000**.
Deployed 2026-07-14, pinned at **2.20.15** (latest release at deploy time,
includes the GHSA-8c6x-pfjq-9gr7 security fix).

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
- **App image pinned** to `ghcr.io/paperless-ngx/paperless-ngx:2.20.15`
  (upstream example uses `latest`).
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
