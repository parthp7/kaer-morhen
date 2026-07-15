# backup scripts

## restic-photos — steel/photos → yennefer

The explicit backup job for the only irreplaceable dataset
([storage.md](../../docs/storage.md)): Immich originals + in-app DB dumps on
geralt's `steel/photos`, which PBS/vzdump never sees (host-side data, and the
VM only touches it through virtiofs). Runs as root **on geralt** (restic must
run where the data is), pushing over SFTP to a repo on yennefer's backup disk.

Deployed 2026-07-16; verified same day: first snapshot `26c7fe28`
(214 MiB, tag `immich`) in the repo on yennefer, both timers enabled
(next: daily 05:00 IST, check on the 1st), first service run clean
(9.3s CPU / 365M peak), Kuma dead-man URL wired, pass + env files 600,
restore drill passed (full restore, `diff -r` clean).

### Why restic (and this shape)

- **Versioned + deduped + encrypted**, with retention — an `rsync` mirror
  would happily replicate a deletion or ransomware pass on the next run.
- **`zfs send` is out**: yennefer has no ZFS *by design* (see storage.md).
- **Repo-level checksums + monthly `check --read-data-subset=10%`** stand in
  for filesystem checksumming on yennefer's plain ext4 — same argument PBS
  makes for its own datastore.
- **B2-ready**: the offsite phase becomes a second repo
  (`restic init --from-repo … --copy-chunker-params`, then `restic copy`)
  with dedup preserved — no new tooling.
- **Running on the PVE host, not an LXC, is deliberate** (evaluated
  2026-07-15): restic is a client binary on a timer, and an LXC on geralt
  is still owned by geralt root — the meaningful boundary is between the
  nodes, not around the process. The upgrades that buy real protection
  against a compromised geralt are yennefer-side/offsite immutability:
  B2 with object lock (planned phase), or an append-only `rest-server`
  LXC on yennefer (deliberately not built now; prune would have to move
  yennefer-side).

### Pieces

| File | Deploys to (geralt) | Purpose |
|---|---|---|
| `restic-photos.sh` | `/usr/local/bin/` (0755) | `backup` = backup + forget/prune; `check` = data verification; ntfy on failure (reuses `/etc/ntfy.topic`), optional Kuma dead-man ping on success |
| `restic-photos.{service,timer}` | `/etc/systemd/system/` | daily **05:00 IST** — after Immich's 02:00 DB dump and the 04:00/04:30 PBS window |
| `restic-photos-check.{service,timer}` | `/etc/systemd/system/` | monthly, 1st at 06:00 IST |
| `restic-photos.env.example` | → `/etc/restic-photos.env` (0600) | repo URL, password file path, optional `KUMA_PUSH_URL` |

Retention: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`.

### Non-negotiables

- **The repo password** (`/etc/restic-photos.pass`) must also live in the
  password manager. The repo is encrypted; no password = no photos.
- **Restore drill before trusting it** (and after the real library import):
  `restic restore latest --target /tmp/restore-drill …`, compare checksums,
  delete. A backup that has never been restored is a hypothesis.
- Capacity watchline (storage.md): yennefer's ~900G disk also carries PBS —
  it fills before steel does once the library nears ~600–700G.

### Manual operations

```bash
# root@geralt — load the env first:
set -a; . /etc/restic-photos.env; set +a

restic snapshots                      # list backups
restic stats                          # logical size / dedup view
restic restore latest --target /tmp/restore-drill --include '<some path>'
restic mount /mnt/restic              # browse (needs fuse); Ctrl-C to unmount
```
