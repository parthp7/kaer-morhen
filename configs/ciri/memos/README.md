# memos — note-taking (ciri stack)

Memos on **ciri** (VM 150), live at `ciri:/data/stacks/memos/`, port **5230**.
Restored 2026-07-12 from the old-host backup
(`homelab-backup/backup/memos/`, taken 2026-07-06): SQLite `memos_prod.db`
plus image assets that previously lived on the old NAS mount.

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- no `.env` — the stack has no secrets; all config is inline in the compose

## Changes vs the old-host compose

- **Image pinned** (`0.29.1`, current stable at restore time) — house policy:
  no `:stable`/`:latest`. The backup DB was last written 2026-06-14, so the
  pinned version is ≥ the version that wrote it; Memos migrates the SQLite
  schema forward on first start if needed.
- **Single bind mount.** The old host mounted the NAS at
  `/var/opt/memos/assets`; the new lab has no NAS, so assets live as a plain
  subdirectory of the data dir and one `./data:/var/opt/memos` mount covers
  both. Container-internal paths are unchanged, so asset references in the DB
  keep resolving.
- **Dropped `MEMOS_INSTANCE_URL`** — it was a never-configured placeholder
  (`https://memos.example.com`); set it only if link generation/webhooks need
  a canonical URL later.

## Layout & ownership (in the VM)

```
/data/stacks/memos/            ciri:ciri   — stack dir + compose.yaml
└── data/                      10001:10001 — bind mount = /var/opt/memos
    ├── memos_prod.db            SQLite database
    ├── .thumbnail_cache/        regenerable
    └── assets/                  uploaded files (was the NAS mount)
```

The container writes as **uid 10001**; everything under `data/` must stay
owned by it. The stack dir itself follows the `/data/stacks` convention
(owned by `ciri`).

## Restore procedure (as executed)

```bash
# in the VM
mkdir -p /data/stacks/memos/data        # as ciri — no sudo

# from the Mac
scp -r ~/workspace/homelab-backup/backup/memos lab-ciri:/tmp/restore-memos
scp configs/ciri/memos/compose.yaml lab-ciri:/data/stacks/memos/

# in the VM
sudo tar -xpzf /tmp/restore-memos/memo-data.tar.gz   -C /data/stacks/memos/data --strip-components=1
sudo tar -xpzf /tmp/restore-memos/memo-assets.tar.gz -C /data/stacks/memos/data/assets --strip-components=1
sudo chown -R 10001:10001 /data/stacks/memos/data
cd /data/stacks/memos && docker compose up -d
```

Verify: `http://<LAN_PREFIX>.150:5230` — log in with old credentials, open a
memo with an image attachment (proves the asset-mount consolidation worked).

Verified 2026-07-12: restored to original state, historical data visible.

## Follow-ups

- DNS name on pihole-1 (nebula-sync mirrors to pihole-2)
- Uptime-Kuma HTTP monitor on `:5230`
- App-level backup once the backups.md next phase lands
