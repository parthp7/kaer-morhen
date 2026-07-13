# sure — personal finance (ciri stack)

Sure ([we-promise/sure](https://github.com/we-promise/sure), the community
fork of Maybe Finance) on **ciri** (VM 150), live at `ciri:/data/stacks/sure/`,
port **3000**. Fresh deployment 2026-07-13 — the old-host backup was
deliberately discarded (decision: start clean, little data in it).

Services: `web` (Rails app), `worker` (Sidekiq), `db` (Postgres 16),
`redis`, and an opt-in `backup` (daily `pg_dump`, `--profile backup`).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholder template; real `.env` lives only in the VM,
  chmod 600

## Changes vs the upstream example compose

- **App image uses `:stable`** — ghcr publishes no version tags for sure
  (only `sha-<commit>` + `stable`), so the usual pin-the-version policy
  doesn't apply; accepted deviation (2026-07-13). `stable` was v0.7.2 at
  deploy time. Support images stay pinned: `postgres:16` (kept per the
  old-host analysis in `docs/docker-vm.md`), `redis:7.4-alpine`,
  `postgres-backup-local:16`.
- **Bind mounts instead of named volumes** — `./storage`, `./postgres-data`,
  `./redis-data`, `./backups` under the stack dir, so all state lives on the
  `/data` disk like the other stacks.
- **No insecure defaults** — upstream ships a sample `SECRET_KEY_BASE` and
  `sure_password` as fallbacks; here both use `${VAR:?}` so compose fails
  loudly if `.env` is missing.
- **Kept the upstream `dns: 8.8.8.8/1.1.1.1`** on web/worker — documented
  workaround for Yahoo Finance sync hanging on IPv6-first DNS answers. This
  bypasses Pi-hole for these two containers only.
- **`container_name`s set** (`sure`, `sure-worker`, `sure-db`, `sure-redis`)
  for readable `docker ps`/Kuma targets.
- HTTP only (`RAILS_FORCE_SSL/ASSUME_SSL=false`) — LAN/tailnet access, no
  reverse proxy in front.
- `OPENAI_ACCESS_TOKEN` left unset — AI chat/rules disabled (would incur
  API costs).

## Layout & ownership (in the VM)

```
/data/stacks/sure/             ciri:ciri — stack dir, compose.yaml, .env (600)
├── storage/                   Rails ActiveStorage (uploads, imports)
├── postgres-data/             postgres (uid 999) — the database
├── redis-data/                redis cache/queue (regenerable)
└── backups/                   daily pg_dump output (backup profile)
```

`ls` shows `postgres-data`/`redis-data` owned by **beszel** — that's just the
VM's uid-999 user colliding with the containers' internal uid 999; nothing
runs as the Beszel agent here.

## First-run notes

- First signup at `http://<LAN_PREFIX>.150:3000` becomes the admin account;
  after creating it, disable open registration in Settings → Self-Hosting.
- Upgrades: `stable` is a moving tag, so `docker compose pull && docker
  compose up -d web worker` moves to the newest release. Check the
  [release notes](https://github.com/we-promise/sure/releases) first.

## Follow-ups

- DNS name on pihole-1 (nebula-sync mirrors to pihole-2)
- Uptime-Kuma HTTP monitor on `:3000`
- `backup` profile enabled 2026-07-13; dumps land daily at midnight
  (IST since the 2026-07-14 TZ standardization; the first ran at UTC
  midnight) — verify `.sql.gz` files appear in `backups/daily/`, then fold
  offsite copies into the restic phase of `docs/backups.md`
