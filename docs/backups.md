# Backup setup & runbook

Guest-level backup skeleton for cluster **kaermorhen**, built 2026-07-10.
Design rationale: [Proposal 001 §5](proposals/001-initial-infrastructure-plan.md).
Storage it sits on: [storage.md](storage.md). IDs/IPs follow the
[network plan](network.md) (VMID = last octet of `<LAN_PREFIX>.x`).

## Architecture

| Piece | Where | Detail |
|---|---|---|
| Proxmox Backup Server 4.x | LXC **200** on yennefer (`.200`) | Debian 13, unprivileged, nesting=1, 2 cores / 2 GiB |
| Datastore `vault` | `/mnt/backup/pbs` (ext4 HDD) bind-mounted at `/datastore` | ~907 GiB ceiling |
| Nightly backup job — geralt | PVE job, 04:00 | `--all`: every guest, present and future |
| Nightly backup job — yennefer | PVE job, 04:30 | offset so both nodes don't hammer the HDD at once |
| Prune | PBS job, daily | keep-daily 7, keep-weekly 4, keep-monthly 3 |
| Garbage collection | PBS job, daily | actually reclaims pruned chunks (prune alone frees nothing) |
| Verify | PBS job, weekly | re-checksums chunks — bit-rot detection at the layer that owns the data |

Recovery model (honest edition): this protects against guest mistakes and
geralt's disks dying. It does **not** yet protect against yennefer's HDD dying
(the datastore *is* that disk — PBS's own container backup lands circularly in
it) or the house burning down. Both are closed by the planned offsite sync
(Backblaze B2 via rclone) in the next phase. Also outside this skeleton:
host-side data on geralt's `steel` pool (`media`, `photos`) — guests' bind
mounts are skipped by vzdump, so `steel/photos` has its own explicit backup
job since 2026-07-16 (photos are the only irreplaceable dataset; see
storage.md and the "steel/photos job" section below).

## Build runbook

All commands as **root** on the node indicated. As-executed, including the
fixes discovered along the way (called out inline).

### 1. Create the PBS container (yennefer)

```bash
pveam update
pveam available --section system | grep debian-13   # note exact filename
pveam download local debian-13-standard_13.1-1_amd64.tar.zst   # adjust to match

pct create 200 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
  --hostname pbs \
  --unprivileged 1 \
  --features nesting=1 \
  --cores 2 --memory 2048 --swap 512 \
  --rootfs local-lvm:10 \
  --mp0 /mnt/backup/pbs,mp=/datastore \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.200/24,gw=<LAN_PREFIX>.1 \
  --onboot 1 --start 1

# unprivileged uid mapping: PBS runs as user "backup" (uid 34 -> 100034 on host)
chown -R 100034:100034 /mnt/backup/pbs
```

- **`--features nesting=1` is required** (learned the hard way: `pct create`
  warns "Systemd 257 detected. You may need to enable nesting."). Debian 13
  ships systemd 257, which needs nested namespaces for its services; without it
  services fail or boot is flaky. Safe on unprivileged containers. Retrofit an
  existing container with `pct set <id> --features nesting=1` + reboot.
- Bind mount as loud-failure guard: if `/mnt/backup` isn't mounted,
  `/mnt/backup/pbs` doesn't exist and the container refuses to start — backups
  can never silently land on the root SSD.
- Root disk on the SSD (`local-lvm`), chunks on the HDD.

### 2. Install PBS inside the container

```bash
pct exec 200 -- bash -c '
  apt update && apt install -y wget
  wget https://enterprise.proxmox.com/debian/proxmox-release-trixie.gpg \
    -O /usr/share/keyrings/proxmox-release-trixie.gpg
  echo "deb [signed-by=/usr/share/keyrings/proxmox-release-trixie.gpg] http://download.proxmox.com/debian/pbs trixie pbs-no-subscription" \
    > /etc/apt/sources.list.d/pbs.list
  apt update && apt install -y proxmox-backup-server
'
pct exec 200 -- passwd    # root password = PBS web UI login (root@pam)
```

- The GPG key URL on `enterprise.proxmox.com` is just the release *signing key*
  (same key for all repos, no subscription needed); the package source itself
  is `pbs-no-subscription` on `download.proxmox.com`. The key is equally
  available at `https://download.proxmox.com/debian/proxmox-release-trixie.gpg`.
- **Post-install**: the package ships an *enabled* `pbs-enterprise` repo →
  disable it (PBS UI → Administration → Repositories), keep
  `pbs-no-subscription`. Otherwise every `apt update` 401s. The PVE nodes have
  the same quirk (`pve-enterprise` + ceph enterprise repos) — check Node →
  Updates → Repositories there too.
- Web UI: `https://<LAN_PREFIX>.200:8007`.

### 3. Datastore + maintenance jobs (inside the container)

```bash
pct exec 200 -- bash -c '
  proxmox-backup-manager datastore create vault /datastore
  proxmox-backup-manager datastore update vault --gc-schedule daily
  proxmox-backup-manager prune-job create keep-sane --store vault \
    --schedule daily --keep-daily 7 --keep-weekly 4 --keep-monthly 3
  proxmox-backup-manager verify-job create weekly --store vault \
    --schedule weekly --ignore-verified true
'
```

Retention lives here in PBS, not in the PVE storage definition.

### 4. Access user for the PVE nodes (inside the container)

```bash
pct exec 200 -- bash -c '
  proxmox-backup-manager user create pve@pbs --password "<PBS_PVE_PASSWORD>"
  proxmox-backup-manager acl update /datastore/vault DatastoreAdmin --auth-id pve@pbs
  proxmox-backup-manager cert info | grep Fingerprint
'
```

Dedicated user keeps root@pam out of the nodes' storage configs;
DatastoreAdmin = backup + restore + browse. Record the fingerprint and password
in `secrets.local.yaml` (`PBS_FINGERPRINT`, `PBS_PVE_PASSWORD`).

### 5. Register the PBS storage on BOTH nodes

```bash
pvesm add pbs pbs-vault --server <LAN_PREFIX>.200 --datastore vault \
  --username pve@pbs --password '<PBS_PVE_PASSWORD>' \
  --fingerprint '<PBS_FINGERPRINT>' \
  --content backup

pvesm status    # pbs-vault active, ~907 GiB
```

### 6. Nightly backup jobs (one per node)

```bash
# geralt
pvesh create /cluster/backup --schedule "04:00" --storage pbs-vault \
  --all 1 --mode snapshot --enabled 1 --notes-template '{{guestname}}'

# yennefer — offset 30 min
pvesh create /cluster/backup --schedule "04:30" --storage pbs-vault \
  --all 1 --mode snapshot --enabled 1 --notes-template '{{guestname}}'
```

- Originally created at 02:00/02:30; retimed to 04:00/04:30 on 2026-07-10 for a
  better copy window. To retune later: node UI → Datacenter → Backup → Edit, or
  `pvesh set /cluster/backup/<job-id> --schedule "HH:MM"` (ids in
  `/etc/pve/jobs.cfg`). Keep the two nodes staggered (shared target HDD) and
  ahead of PBS's prune/GC window.

- `--all 1` is the point of the skeleton: every guest created from now on is
  born covered — no per-guest opt-in to forget.
- `{{guestname}}` is typed **literally** (single quotes matter) — vzdump
  expands it per backup, so the PBS UI shows `ct/200 — pbs` instead of bare
  IDs. Other variables: `{{vmid}}`, `{{node}}`, `{{cluster}}`.

### 7. Restore test (as actually performed)

Method: create a throwaway LXC, give it *distinguishable state*, let the real
scheduled job back it up, destroy it, restore, and check the state survived.
Using the scheduled job (rather than a manual `vzdump`) also validated the
schedule itself.

```bash
# geralt — test guest in the scratch band (199), same fixes as PBS container
pct create 199 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
  --hostname restore-test --unprivileged 1 --features nesting=1 \
  --rootfs silver-guests:4 --memory 512 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.199/24,gw=<LAN_PREFIX>.1 \
  --start 1

# marker state: update + a package that isn't in the base template
pct exec 199 -- bash -c 'apt update && apt upgrade -y && apt install -y tree'

# ... wait for the nightly job to run (or trigger the job manually in the UI) ...

pct destroy 199                          # simulate loss
pvesm list pbs-vault                     # find the backup volid
pct restore 199 pbs-vault:backup/ct/199/<timestamp> --storage silver-guests
pct start 199
pct exec 199 -- which tree               # marker present => state restored
pct stop 199 && pct destroy 199          # clean up
```

Verified 2026-07-10: scheduled job fired at 02:00, restore came back with the
upgraded packages and `tree` installed — full loop proven (geralt → network →
PBS → HDD → back) before anything precious exists.

One storage fix surfaced during this test: LXC creation on `silver` failed
until the pool got a real mountpoint (`zfs set mountpoint=/silver silver`) —
LXC disks are filesystem datasets that must mount, unlike VM zvols. Details in
[storage.md](storage.md).

## Gotchas recap

- Debian 13 LXCs need `--features nesting=1` (systemd 257).
- PBS install enables the enterprise apt repo — disable it; same on PVE nodes.
- Prune without GC reclaims nothing; both are scheduled.
- vzdump skips bind mounts: the datastore never backs itself up (good), but
  host-side payloads (`steel/photos`!) are equally invisible to it (must be
  handled separately).
- `silver` pool needs a mountpoint for LXC subvols (fixed 2026-07-10).

## steel/photos job (built 2026-07-16)

The explicit job for the irreplaceable dataset: **restic on geralt** →
SFTP repo at `yennefer:/mnt/backup/photos`, daily 05:00 IST (after
Immich's 02:00 in-app DB dump and the PBS window), retention 7d/4w/6m,
monthly `check --read-data-subset=10%` (bit-rot detection on the ext4
target), ntfy on failure + Uptime-Kuma push dead-man on success.
As-built + runbook: [scripts/backup/README.md](../scripts/backup/README.md).
Yennefer's disk now carries PBS **and** this repo — the ~600–700 G photo
watchline from storage.md applies.

## Next phase (not yet built)

- **Offsite**: rclone sync of the PBS datastore → Backblaze B2, nightly timer —
  closes the "yennefer HDD dies" and disaster gaps.
- **Photos offsite**: second restic repo on B2 (`restic copy`; init with
  `--copy-chunker-params`), object lock = ransomware/compromised-node story.
- **App-level dumps** (postgres etc.) inside the docker VM via restic/borgmatic,
  once apps exist.
