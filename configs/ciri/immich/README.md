# immich — photo/video library (ciri stack)

[Immich](https://immich.app) on **ciri** (VM 150), live at
`ciri:/data/stacks/immich/`, port **2283**. Pinned at **v3.0.2** (latest
release at draft time; v3.0.0 shipped 2026-07-01).

Services: `immich-server` (app/API, port 2283), `immich-machine-learning`
(smart search + face recognition, CPU-only for now), `redis` (valkey),
`database` (Immich's own postgres build with VectorChord).

Deployed 2026-07-14; verified end-to-end 2026-07-15: 4/4 containers
healthy, API answering on `http://immich.kaermorhen.internal:2283`,
originals + `.immich` markers on steel via virtiofs, thumbs (50M) on NVMe,
ML models cached (786M), stack RAM ~1.7G idle, repo mirror in sync.

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholder template; real `.env` lives only in the VM,
  chmod 600

## Storage design

The library splits across two disks (officially supported — subfolder bind
overrides on `/data`):

| Data | Lives on | Why |
|---|---|---|
| originals (`library/`, `upload/`), `encoded-video/`, `profile/`, DB dumps (`backups/`) | **geralt `steel/photos`** (ZFS, recordsize=1M), into the VM via **virtiofs** at `/mnt/photos` | irreplaceable → must sit on the host in the future `steel/photos → yennefer + B2` backup path (storage.md); never inside a VM disk, never inflating nightly PBS |
| `thumbs/` | ciri `/data` (`./thumbs`, NVMe zvol) | timeline scrubbing = small-file random reads, painful from the 5400rpm HDD; fully regenerable, needs no backup |
| postgres data | ciri `/data` (`./postgres-data`) | DB must be local + fast, never on a share |
| ML model cache | ciri `/data` (`./model-cache`) | ~1G, re-downloadable |

virtiofs trade-off (accepted 2026-07-14, verified same day): a VM with a
virtiofs device **cannot live-migrate, hibernate, or snapshot with RAM
state** (`--vmstate`). Plain disk-only `qm snapshot`s work — they cover
the zvols and skip the share (host data; a VM rollback never rewinds the
photos). PBS/vzdump backups are unaffected (QEMU live backup doesn't use
storage snapshots) — proven in runbook step 2. Fallback if the lost
features ever matter: NFS export from geralt instead.

## Changes vs the upstream release compose

Based on the [v3.0.2 release
compose](https://github.com/immich-app/immich/releases/download/v3.0.2/docker-compose.yml):

- **Images pinned to `v3.0.2`** (upstream floats `release`); digest pins
  stripped from the valkey/postgres images per repo pinning policy.
- **`./thumbs:/data/thumbs` override** added (storage split above).
- **Bind mounts instead of named volume** for the ML model cache.
- **`DB_DATA_LOCATION` env replaced** by a direct `./postgres-data` bind.
- **`restart: unless-stopped`** (upstream: `always`), **TZ=Asia/Kolkata**
  everywhere, **container_names** (`immich`, `immich-ml`, `immich-redis`,
  `immich-db`), dedicated bridge network — lab conventions.
- **`${UPLOAD_LOCATION:?}`/`${DB_PASSWORD:?}`** fail loudly if `.env` is
  missing (upstream defaults the DB password to `postgres`).
- Service names `database`/`redis` kept — immich-server's default
  `DB_HOSTNAME`/`REDIS_HOSTNAME` resolve to them.
- `DB_STORAGE_TYPE: 'HDD'` deliberately **not** set — postgres is on NVMe.

## Runbook (as executed 2026-07-14)

### 1. geralt — expose steel/photos to VM 150 via virtiofs

```bash
# Directory mapping (Datacenter → Resource Mappings → Directory in the GUI)
pvesh create /cluster/mapping/dir --id photos --map node=geralt,path=/steel/photos

# Attach to ciri — virtiofs is NOT hot-pluggable: the change stays "pending"
# until a cold restart (guest-internal reboot is not enough)
qm set 150 --virtiofs0 dirid=photos
qm shutdown 150 && qm start 150
qm config 150 | grep virtiofs      # virtiofs0: dirid=photos
```

### 2. geralt — prove the nightly backup still passes (before anything else)

```bash
vzdump 150 --storage pbs-vault --mode snapshot   # expect: INFO: Backup job finished successfully
```

If the vzdump fails, stop: detach (`qm set 150 --delete virtiofs0`, cold
restart) and fall back to the NFS design.

Executed 2026-07-14: backup passed (incremental, 59s). Also verified that
disk-only `qm snapshot` still works with virtiofs attached (snapshots the
zvols, skips the share) — only `--vmstate` snapshots, live migration, and
hibernate are blocked. Test snapshot removed with
`qm delsnapshot 150 should-fail`.

### 3. ciri — mount the share

The fstab mount tag is the mapping id (`photos`).

```bash
sudo mkdir /mnt/photos
echo 'photos /mnt/photos virtiofs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/photos
findmnt /mnt/photos                # FSTYPE virtiofs
sudo touch /mnt/photos/.rw-test && sudo rm /mnt/photos/.rw-test
```

Then on geralt: `ls -la /steel/photos` — confirms writes land in the
dataset. Missing-mount safety: after first run Immich plants `.immich`
marker files in every media subfolder and **refuses to start** if they
vanish, so a failed mount (`nofail`) means a crash-looping container, not
photos silently written to the VM disk.

### 4. ciri — deploy the stack

```bash
mkdir -p /data/stacks/immich && cd /data/stacks/immich
# copy in compose.yaml; create .env from .env.example with a real DB_PASSWORD
chmod 600 .env
docker compose up -d
docker compose ps            # all healthy (server healthcheck needs ~a minute)
```

### 5. First run

- `http://<LAN_PREFIX>.150:2283` → create the admin account.
- Administration → System Settings → **Backup Settings**: enable daily
  database dumps (fires into `backups/` on steel/photos — see backup story).
- Upload a test photo + video; confirm they land under
  `/steel/photos/upload/…` (geralt) and the thumbnail under
  `./thumbs` (ciri); play the video.
- Kick "Smart Search" + "Face Detection" jobs on the test assets —
  first run downloads ~1G of models into `./model-cache`; watch RAM
  (`docker stats`, expect ~3–4G stack total during jobs).
- Upgrades are deliberate: bump the pinned tags in `compose.yaml`, read the
  [release notes](https://github.com/immich-app/immich/releases) (Immich
  flags breaking changes prominently), then
  `docker compose pull && docker compose up -d`.

## Layout & ownership

```
/data/stacks/immich/           ciri:ciri — compose.yaml, .env (600)
├── thumbs/                    previews/thumbnails (regenerable, NVMe)
├── postgres-data/             postgres (uid 999) — ALL library metadata
└── model-cache/               CLIP + face models (re-downloadable)

/mnt/photos → geralt:/steel/photos   (virtiofs, container writes as root)
├── library/                   ★ originals (storage-template layout)
├── upload/                    ★ originals as uploaded
├── backups/                   ★ daily DB dumps (enable in admin UI)
├── encoded-video/             transcoded copies (regenerable)
└── profile/                   avatars
```

★ = irreplaceable + DB dumps — the payload of the future offsite job.

## Backup story (important)

Nightly PBS covers postgres-data and thumbs (VM disks) but **vzdump never
sees /mnt/photos**. The originals are covered since 2026-07-16 by the
dedicated restic job (geralt → yennefer, daily 05:00 IST — as-built in
[scripts/backup/README.md](../../../scripts/backup/README.md)); the in-app
DB dumps into `backups/` ride along with it, pairing metadata with
originals so a restore doesn't need PBS and steel to agree on a point in
time. Still pending: the B2 offsite leg (backups.md next phase) — until
then both copies of the library live in one apartment.

## Library import (after backups exist)

- Phones: mobile app → server URL → background backup (LAN now; Tailscale
  URL for remote later).
- Google Takeout: [immich-go](https://github.com/simulot/immich-go)
  (keeps albums + metadata).
- Folder tree on disk: `immich` CLI bulk upload, or an External Library
  (read-only in place) — decide per source.
- Verify counts/checksums before deleting any source copy.

## Follow-ups

- ~~DNS name on pihole-1 (nebula-sync mirrors to pihole-2)~~ done
  2026-07-14 (`immich.kaermorhen.internal`)
- ~~Uptime-Kuma HTTP monitor on `:2283`~~ done 2026-07-14
- ~~docs/docker-vm.md stacks table row + this README → as-built~~ done
  2026-07-15
- ~~`steel/photos` backup job (blocking for import)~~ done 2026-07-16 —
  **library import unblocked**; re-run the restore drill after import
- Confirm daily DB dumps enabled (admin UI → Backup Settings) —
  `backups/` was still empty at verification
- Optional: add `/mnt/photos` to Beszel's `EXTRA_FILESYSTEMS` to watch
  steel usage from the ciri dashboard
- Later, with Jellyfin's GPU decision: QuickSync for ML/transcodes
  (`hwaccel.*.yml` extends + image tag change)
