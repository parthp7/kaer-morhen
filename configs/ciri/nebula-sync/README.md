# nebula-sync — Pi-hole pair sync (ciri stack)

First compose stack on **ciri** (VM 150), live at
`ciri:/data/stacks/nebula-sync/`, deployed 2026-07-12. Keeps pihole-2 (`.201`)
a full mirror of pihole-1 (`.101`) — adlists, local DNS records, config — via
Pi-hole v6 Teleporter. Ends the edit-both-UIs-by-hand tax from
[dns.md](../../../docs/dns.md): **make all changes on pihole-1 only**;
anything changed on pihole-2 is overwritten on the next sync.

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — template; the real `.env` lives only in the VM (chmod 600)

## Design decisions

- **Image pinned** (`v0.11.2`) — house policy: no `:latest`, upgrades are
  deliberate.
- **`FULL_SYNC=true` + `RUN_GRAVITY=true`** — the two Pi-holes are
  deliberately identical, so a full Teleporter mirror is correct; gravity
  rebuilds on the replica after each sync.
- **Hourly `CRON`** on the daemon service. Every-minute was tried (2026-07-12)
  and reverted: each run is a full Teleporter import + gravity rebuild +
  session invalidation against 512 MB LXCs, and the session churn can log you
  out of pihole-2's web UI.
- **`sync-now` one-shot service** (profile `manual`, no `CRON` defined →
  syncs once and exits) for immediate on-demand sync. A separate service is
  required because Docker cannot *unset* an inherited env var per-run:
  `docker compose run -e CRON="" …` passes an empty string, which nebula-sync
  rejects as an invalid cron expression.

## Usage (in the VM, `/data/stacks/nebula-sync/`)

```bash
docker compose up -d               # daemon, hourly sync (sync-now not started)
docker compose run --rm sync-now   # immediate one-shot sync
docker logs nebula-sync            # sync history
docker compose down                # stop
```

## Verify (read-only)

```bash
# a change made on pihole-1 appears on pihole-2 after the next sync:
dig @<LAN_PREFIX>.201 ciri.kaermorhen.internal +short   # matches @.101
dig @<LAN_PREFIX>.201 doubleclick.net +short            # 0.0.0.0 — blocking intact
docker logs nebula-sync | tail -2                       # "Sync completed"
```
