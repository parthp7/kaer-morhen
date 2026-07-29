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
| 1 TB USB HDD (Seagate BUP Slim) | ext4, label `media`, `/mnt/media` | shared to ciri via **virtiofs** (`dirid=media`) | Jellyfin library — disposable, **no backup** (see below) |

`steel` datasets:

| Dataset | recordsize | Purpose |
|---|---|---|
| ~~`steel/media`~~ | — | **Destroyed 2026-07-23** — the Jellyfin library moved to the external USB HDD (below); dataset removed once the disk was proven. |
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

zfs create -o recordsize=1M steel/media    # destroyed 2026-07-23 — moved to USB HDD
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

- ~~USB HDD on geralt takes over `steel/media`~~ done 2026-07-22 — a **1 TB
  Seagate BUP Slim** (not the 2 TB originally sketched), ext4, `LABEL=media`,
  `/mnt/media` with `nofail`, shared into ciri via virtiofs for Jellyfin
  ([configs/ciri/jellyfin/README.md](../configs/ciri/jellyfin/README.md)).
  Holds replaceable data only — no backup. `steel/media` was destroyed
  2026-07-23 once the USB disk was proven, freeing `steel` to grow as the
  photo/document disk. It shipped NTFS-preformatted — reformatted after
  confirming contents were disposable.
  **Correction 2026-07-29**: the earlier note here (and in the Jellyfin README)
  claimed the drive "enumerates reliably only at USB 2.0" and had been moved to a
  working port. Both are wrong. Every USB port on geralt is 3.0, the drive was
  never moved between ports, and it has linked at **SuperSpeed (5 Gbps) since
  2026-07-22 00:32**. What actually varies is the bridge's link negotiation on
  each replug — `high-speed` on 2026-07-21, SuperSpeed since — which is
  nondeterministic, not port-dependent. Treat the drop risk as a property of the
  bridge, mitigated by architecture rather than by port choice (see the incident
  below).
- **PBS on yennefer** with datastore at `/mnt/backup/pbs`; both nodes back up
  guests to it, then sync offsite (Backblaze B2 via rclone).
- ~~Explicit `steel/photos` backup job → yennefer~~ done 2026-07-16
  (restic, daily — see [scripts/backup/README.md](../scripts/backup/README.md));
  the B2 offsite leg is still pending.
- Capacity watchlines: keep ZFS pools under ~80 %; yennefer's 1 TB backup disk is
  the ceiling — it fills before steel does once the photo library approaches
  ~600–700 GB.

## Incident 2026-07-27 / 28 — virtiofs served the wrong filesystem

The most instructive failure the lab has had: **nothing went down, and that was
the problem.** Recorded in full because every mitigation now in place exists
because of a specific line in this timeline.

### What happened

| When | Event |
|---|---|
| 07-26 23:31:32 | `usb 2-3: USB disconnect` mid-read. `I/O error, dev sdb`, `JBD2: I/O error when updating journal superblock`. The bridge re-enumerated 1 s later — but nothing remounted, so `/mnt/media` was a **stale** mount for ~16 h |
| 07-27 15:16:55 | Jellyfin: `Input/output error: '/media/tv/Rick.and.Morty.S09E05…'` — the first user-visible symptom |
| 07-27 15:21 | geralt rebooted to clear it |
| 07-27 **15:22:17** | `virtiofsd --shared-dir=/mnt/media` starts — the USB disk is **not yet mounted** |
| 07-27 **15:22:19** | `mnt-media.mount` completes — **2 seconds too late** |

virtiofsd resolves `--shared-dir` **once** and pins that inode for the life of
the process. It had pinned the empty placeholder directory on `pve-root`, so ciri
spent the next 16 hours serving a **68 GB** filesystem where the **916 GB** disk
should have been. A guest-side remount cannot fix this — only a cold VM restart.

`nofail` is what allowed it: `nofail` deliberately drops the mount's ordering
barrier into `local-fs.target`, so `pve-guests` never waited. The USB disk simply
happened to be 2 seconds slower than the VM that morning.

### Why nothing alerted

All 18 Uptime-Kuma monitors and every Beszel panel stayed **green throughout**.
The containers were up and answering; they were just pointed at the wrong disk.

- **Jellyfin refused to start** — `create_host_path: false` on its `/media` bind
  fired exactly as designed (`exit 127`, `open /mnt/media/library: no such file
  or directory`), which also protected its database from mass item eviction.
- **qBittorrent and the \*arr had no such guard.** Docker's default
  `create_host_path: true` silently created `downloads/` on geralt's **boot
  disk**; qBittorrent attached to it and marked all 20 torrents
  `missingFiles`/`error`, and Radarr reported `Missing root folder:
  /data/library/movies`.

The one saving grace: qBittorrent errored out rather than downloading, so
`pve-root` was never filled.

### Fixes, and which failure each one answers

| Fix | Answers |
|---|---|
| `x-systemd.before=pve-guests.service,x-systemd.device-timeout=30` on the media mount in geralt's `/etc/fstab` | the 2-second race. Ordering **only**, no `Requires` — an absent disk delays guest start ≤30 s, then everything comes up anyway |
| [`vm150-require-virtiofs.sh`](../scripts/proxmox/vm150-require-virtiofs.sh) hookscript on VM 150 | the disk dropping while running, then a VM restart — which ordering cannot cover |
| `create_host_path: false` guards on qBittorrent + a read-only `/media-guard` sentinel on Sonarr/Radarr/Bazarr | the silent-write-to-boot-disk failure. Jellyfin already had this; the others did not |
| [`media-mount-health.sh`](../scripts/monitoring/media-mount-health.sh) Push monitor | the 16 hours of green dashboards ([uptime-kuma.md](uptime-kuma.md)) |

**The tiers are deliberately asymmetric.** `/steel/photos` (internal SATA,
irreplaceable Immich originals) is **required** — the hookscript blocks ciri from
starting without it. `/mnt/media` (external USB, explicitly disposable) is
**advisory** — ciri starts, and the media containers alone stay down via their
own bind guards. Holding Immich, Paperless, memos and sure hostage to a USB disk
would be the wrong trade.

`/steel/photos` needs no fstab ordering of its own: `zfs-mount.service` is
`Before=local-fs.target`, and `local-fs → sysinit → basic → pve-guests` orders it
transitively. Media needed the explicit line *precisely because* `nofail` removed
it from that chain.

### Postscript: the UAS quirk that wasn't (07-28)

An attempt to harden the bridge itself —
`usb-storage.quirks=0bc2:ab24:u usbcore.autosuspend=-1` on the kernel cmdline —
caused **intermittent boot hangs**, roughly 3 in 6 attempts, and was reverted.

Worth recording because the evidence is counter-intuitive: the three boots that
*did* come up carried the parameters and were **completely healthy** — `[sdb]
Attached SCSI disk`, `mnt-media.mount` mounted, SSH in 7 s, VM 150 started in
23 s. The hangs left **no journal at all**; they are visible only as gaps between
boot IDs (15m41s, 6m06s, 2m06s), meaning the hang was **before
`systemd-journald` started** — GRUB, early kernel, or initramfs. With `quiet` set
there was nothing on the console either.

The mechanism was never proven and by definition cannot be from the available
evidence. **`quiet` has been left off** `GRUB_CMDLINE_LINUX_DEFAULT` since: the
reason this cost a trip to the physical laptop is that the failure was invisible.

**Accepted position:** the bridge stays unmitigated. The drive is disposable and
the architecture above turns a drop into "media containers stay down" instead of
"silent writes to the boot disk". It will drop again; that is now a known,
bounded outcome rather than a corruption.
