# Storage layout & build runbook

As-built storage configuration for cluster **kaermorhen**, executed 2026-07-09.
Design rationale and alternatives considered: [Proposal 001](proposals/001-initial-infrastructure-plan.md).

Disk serials in `/dev/disk/by-id/` paths are placeholders (`<NAME>`) per `CLAUDE.md`,
resolved in the git-ignored `secrets.local.yaml`.

## As-built layout

### geralt

| Device | Backing | Configured as | Purpose |
|---|---|---|---|
| 256 GB NVMe (boot) | LVM `pve` VG | `local` (dir) + `local-lvm` (thin) | Proxmox root/swap; overflow/scratch guest space |
| 500 GB NVMe (Kingston) | ZFS pool **`silver`** | `silver-guests` (zfspool) | All VM/LXC disks (docker VM etc.) |
| 1 TB HDD (Seagate) | ZFS pool **`steel`** | datasets below | Bulk payloads + dumps |

`steel` datasets:

| Dataset | recordsize | Purpose |
|---|---|---|
| `steel/media` | 1M | Jellyfin library (replaceable — migrates to future 2 TB USB disk) |
| `steel/photos` | 1M | Immich originals (irreplaceable — must be in backup path) |
| `steel/dump` | 128K (default) | `steel-dump` dir storage: vzdump, ISOs, templates |

Pool naming: Geralt carries two swords — **silver** (fast/precious: guests) and
**steel** (workhorse: bulk).

ZFS ARC capped at **2 GiB** (`/etc/modprobe.d/zfs.conf`).

### yennefer

| Device | Backing | Configured as | Purpose |
|---|---|---|---|
| 256 GB SATA SSD (boot) | LVM `pve` VG | `local` (dir) + `local-lvm` (thin) | Proxmox root/swap; **all yennefer guest disks** |
| 1 TB HDD (WD) | ext4, label `backup`, `/mnt/backup` | `backup-dump` (dir) | vzdump target now; `/mnt/backup/pbs` reserved for PBS datastore |

**No ZFS on yennefer** — deliberate. The disk only holds backups: PBS checksums and
zstd-compresses its own chunks, so ZFS's checksums/compression add ~nothing, while
ARC would eat RAM the 8 GB node can't spare. ext4 is zero-overhead and trivially
recoverable from any live USB.

## Design decisions

- **Single-disk ZFS, no cross-node replication** (2 nodes only). ZFS is for
  checksumming (bit-rot *detection* on aging consumer disks), snapshots, and lz4 —
  not redundancy. A single-disk pool detects corruption but cannot self-heal data.
- **`media` and `photos` are separate datasets** so the future 2 TB USB drive can
  take over movies by moving one dataset's contents, and the photo backup job
  targets `steel/photos` cleanly. USB disk gets replaceable data only.
- **Photos are the only irreplaceable dataset.** They live on the host (not inside a
  VM disk), so PBS guest backups will NOT include them — they need an explicit
  backup job to yennefer + offsite. Must-have line item in the backup design.
- **Boot `pve` VGs untouched** on both nodes; `local-lvm` on yennefer is her only
  fast storage and hosts all her guests (HAOS VM, Pi-hole, PBS, proxy LXCs).
- Known hardware flag: geralt's HDD has 37 lifetime UDMA CRC errors (cable-class
  signal, zero reallocated/pending sectors). Monitoring should alert if it grows.

## Build runbook

All commands run as **root** on the respective node. Steps 1–2 are destructive;
everything else is additive. Executed 2026-07-09.

### 1. geralt — wipe leftover storage (DESTRUCTIVE)

The previous install left an LVM thin pool (`ssd-vg`, containing an old VM disk) on
the 500 GB NVMe and a stale ZFS pool on the HDD. Neither was referenced by the new
install's `/etc/pve/storage.cfg`, so removal does not affect the node.

```bash
# Remove leftover LVM stack on the 500 GB NVMe (nvme0n1 — NOT the boot nvme1n1)
vgchange -an ssd-vg          # deactivate the VG
vgremove -ff -y ssd-vg       # delete VG + all LVs in it
pvremove -y /dev/nvme0n1     # drop the PV header
wipefs -a /dev/nvme0n1       # clear remaining signatures

# Wipe the stale ZFS pool on the 1 TB HDD
zpool labelclear -f /dev/sda1   # ZFS keeps 2 labels at start AND 2 at END of the
                                # partition — a plain partition-table wipe leaves
                                # the end labels behind; labelclear removes all 4
wipefs -a /dev/sda              # clear GPT (primary + backup) and protective MBR
```

### 2. yennefer — wipe leftover storage (DESTRUCTIVE)

```bash
zpool labelclear -f /dev/sda1
wipefs -a /dev/sda
```

### 3. geralt — create `silver` (guest pool, 500 GB NVMe)

```bash
zpool create -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa -O acltype=posixacl \
  -O mountpoint=/silver \
  silver /dev/disk/by-id/nvme-KINGSTON_SNVSE500G_<GERALT_SSD500_SERIAL>

zfs create silver/guests
pvesm add zfspool silver-guests --pool silver/guests --content images,rootdir --sparse 1
```

Why these flags:

- `/dev/disk/by-id/…` — stable device identity; `/dev/nvme0n1` style names can
  reorder across boots.
- `ashift=12` — 4K sector alignment; correct for these drives, safe universally,
  and immutable after creation (the one setting you can't fix later).
- `compression=lz4` — effectively free CPU-wise, typically saves 20–40 % on OS/app
  disks.
- `atime=off` — skip write-on-every-read metadata updates.
- `xattr=sa` + `acltype=posixacl` — store extended attributes/ACLs in inodes
  instead of hidden files; standard for Linux guests and container rootfs.
- `mountpoint=/silver` — VM disks are zvols (block devices, never mounted), but
  LXC disks are filesystem datasets that Proxmox mounts under
  `/silver/guests/subvol-<vmid>-disk-N` — the pool needs a real mountpoint for
  that. (Originally created with `mountpoint=none`, which broke LXC creation;
  fixed 2026-07-10 via `zfs set mountpoint=/silver silver`.)
- `--sparse 1` — thin provisioning: guest disks consume only written blocks.

### 4. geralt — create `steel` (bulk pool, 1 TB HDD)

```bash
zpool create -o ashift=12 \
  -O compression=lz4 -O atime=off -O xattr=sa \
  -O mountpoint=/steel \
  steel /dev/disk/by-id/ata-ST1000LM049-2GH172_<GERALT_HDD_SERIAL>

zfs create -o recordsize=1M steel/media
zfs create -o recordsize=1M steel/photos
zfs create steel/dump

pvesm add dir steel-dump --path /steel/dump \
  --content backup,iso,vztmpl \
  --prune-backups keep-daily=7,keep-weekly=4 \
  --is_mountpoint yes
```

- `recordsize=1M` on media/photos — large sequential files (video, multi-MB
  photos); fewer records, less metadata overhead. `dump` keeps the 128K default.
- `--is_mountpoint yes` — Proxmox refuses to write into `/steel/dump` if the pool
  ever fails to import, instead of silently filling the root SSD.
- `--prune-backups` — vzdump retention handled by the storage itself.

### 5. geralt — cap ZFS ARC at 2 GiB

Manually created pools default the ARC to 50 % of RAM; on a 16 GB node hosting an
8–10 GB docker VM that's unaffordable.

```bash
echo "options zfs zfs_arc_max=2147483648" > /etc/modprobe.d/zfs.conf
update-initramfs -u -k all                                  # persist across boots
echo 2147483648 > /sys/module/zfs/parameters/zfs_arc_max    # apply now, no reboot
```

### 6. yennefer — partition, format, mount the backup disk

```bash
# One whole-disk GPT partition, type 8300 (Linux filesystem), named "backup"
sgdisk -n1:0:0 -t1:8300 -c1:backup /dev/disk/by-id/ata-WDC_WD10JPVX-60JC3T1_<YENNEFER_HDD_SERIAL>

# ext4 with volume label; -m 1 cuts root-reserved space from 5% to 1% (~37 GB
# reclaimed — no system processes ever run from this disk)
mkfs.ext4 -L backup -m 1 /dev/disk/by-id/ata-WDC_WD10JPVX-60JC3T1_<YENNEFER_HDD_SERIAL>-part1

mkdir -p /mnt/backup
echo "LABEL=backup /mnt/backup ext4 defaults,noatime,nofail 0 2" >> /etc/fstab
systemctl daemon-reload
mount /mnt/backup

mkdir /mnt/backup/dump /mnt/backup/pbs
```

- Mount by `LABEL=` — survives device renames.
- `nofail` — a dead/absent disk must not hang a headless node's boot.
- `pbs/` is the reserved future PBS datastore directory.

### 7. yennefer — register the dump storage

```bash
pvesm add dir backup-dump --path /mnt/backup/dump \
  --content backup,iso,vztmpl \
  --prune-backups keep-daily=7,keep-weekly=4 \
  --is_mountpoint /mnt/backup
```

- `--is_mountpoint /mnt/backup` — path form of the same guard as on geralt: the
  storage only activates if `/mnt/backup` is actually a mountpoint.

No ARC cap needed on yennefer: with no ZFS pools, the ARC never grows.

### 8. Verification (read-only)

```bash
# geralt
zpool status -x                                  # expect: "all pools are healthy"
zfs list -r -o name,used,avail,recordsize,compression
cat /sys/module/zfs/parameters/zfs_arc_max       # 2147483648
pvesm status                                     # silver-guests + steel-dump active

# yennefer
lsblk -f /dev/sda                                # ext4, LABEL=backup, mounted
findmnt /mnt/backup                              # rw,noatime
pvesm status                                     # backup-dump active
```

Verified 2026-07-09: both pools ONLINE/healthy, ARC cap live and persisted, all
storages active with correct flags in `/etc/pve/storage.cfg`, boot `pve` VGs
untouched.

## Future work

- **2 TB USB HDD on geralt** (permanent): ext4, mounted by-id with `nofail`, takes
  over `steel/media` contents (replaceable data only — never photos, never the
  backup copy of anything on steel). Frees steel to grow as the photo/document disk.
- **PBS on yennefer** with datastore at `/mnt/backup/pbs`; both nodes back up
  guests to it, then sync offsite (Backblaze B2 via rclone).
- ~~Explicit `steel/photos` backup job → yennefer~~ done 2026-07-16
  (restic, daily — see [scripts/backup/README.md](../scripts/backup/README.md));
  the B2 offsite leg is still pending.
- Capacity watchlines: keep ZFS pools under ~80 %; yennefer's 1 TB backup disk is
  the ceiling — it fills before steel does once the photo library approaches
  ~600–700 GB.
