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

`silver-guests` zvols for **ciri (VM 150)** — the one place a guest disk is
deliberately excluded from backup:

| Disk | Size | Mounted in ciri | In nightly PBS? |
|---|---|---|---|
| scsi0 | 64 G | `/` | yes |
| scsi1 | 64 G | `/data` — Docker data-root + every stack's app data | yes |
| scsi2 | 64 G | `/mnt/ai-models` — Ollama model weights | **no — `backup=0`** |
| scsi3 | 150 G | `/mnt/torrents` — in-flight torrent scratch (`incomplete/`) | **no — `backup=0`** |

scsi2 was added 2026-07-31 for the AI stack ([proposal 002](proposals/002-local-ai-stack.md)).
The `backup=0` flag is the point of it: ~29 GB of GGUF weights are
re-downloadable in minutes, so backing them up nightly would inflate every
snapshot for nothing. Anything that must survive a restore therefore must NOT
live under `/mnt/ai-models` — it is a cache, not storage.

scsi3 was added 2026-08-23 ([proposal 005](proposals/005-nfs-media-share.md)) and
applies the same precedent for the same reason: torrent scratch is disposable by
construction, and backing it up nightly would inflate every snapshot with data
that is deleted the moment a download completes. Its real job is to keep random
write I/O off the SMR USB disk — qBittorrent downloads to NVMe, then performs its
own move-on-completion to the media share as a single **sequential** write, which
is the SMR-friendliest workload there is.

**Grown 100 G → 150 G on 2026-09-02**, online and with no restart — exactly the
procedure [proposal 005](proposals/005-nfs-media-share.md) §"Sizing the scratch
disk" anticipated:

```bash
⚙️ ssh lab-geralt 'qm resize 150 scsi3 +50G'
⚙️ ssh lab-ciri   'sudo resize2fs /dev/disk/by-label/torrents'
```

The trigger was three concurrent 4K UHD REMUXes overrunning the original 100 G —
see [Incident 2026-09-02](#incident-2026-09-02--torrent-scratch-exhausted-by-three-4k-remuxes).
The 100 G figure was sized for "two season packs + two movies ≈ 80–120 G", an
assumption 4K REMUX invalidates on its own.

(`/mnt/photos` is a virtiofs share and `/mnt/media` an NFS mount; both are
excluded for a different reason — PBS only sees the guest's own disks.)

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
  **Correction 2026-08-03**: the drop risk is not a property of the bridge alone.
  The bare drive is **SMR**, and its write stalls are what expire the UAS command
  timeout that makes the bridge drop. The bridge is the messenger; sustained
  writes are the trigger. See the
  [2026-08-03 incident](#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr).
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

> **Superseded 2026-08-03.** "Unmitigated" was accepted on the belief that the
> fault was an unknowable property of the bridge. It is not — the root cause is
> now identified as **SMR write stalls** in the bare drive, and the "bounded
> outcome" assumption failed in practice: the next drop went **undetected for
> 14 h 43 m**. See the incident below.

## Incident 2026-08-03 — USB bus drop under sustained write (SMR)

The second media outage, and the one that identified the actual root cause. Unlike
2026-07-27 this was **not** a boot-order race: geralt never rebooted (up 3 d 4 h,
boot of 07-31 14:39). The disk dropped off the bus **while running**.

### What happened

| When | Event |
|---|---|
| 08-03 **00:56:48** | `usb 2-3: USB disconnect` **mid-write** — `phys_seg 57 op WRITE`, then `EXT4-fs (sdb1): failed to convert unwritten extents … potential data loss`, `Aborting journal`, `EXT4-fs (sdb1): shut down requested (2)` |
| 00:56:49 | systemd: `Unmounted mnt-media.mount` — **and nothing ever remounts it** |
| 00:56:49 → 00:57:15 | bridge re-enumerates **5 times** in 27 s, settles as **`sdc`** (was `sdb`), left unmounted |
| **09:11:15** | Jellyfin scheduled library scan fails — `IOException: Input/output error : '/media/movies'`. **First real signal, 6.5 h before anyone noticed** |
| 14:53:23 | User playback attempt fails with the same `Input/output error` |
| 15:39:59 | Manual `mount` on geralt — `EXT4-fs (sdc1): recovery complete` (journal replayed) |
| 15:40:45 | First ciri restart **fails**, `QEMU exited with code 1` |
| 15:44:04 / 16:19:58 | Second and third restarts succeed; service restored |

`/mnt/media` was down for **14 h 43 m**.

### Root cause: the drive is SMR

The bare drive inside the Backup Plus Slim is **DM-SMR** (shingled) — see the
[hardware inventory](hardware-inventory.md#node-geralt) for the identification and
why it is certain despite the exact model not being read directly. The failure
chain:

**sustained write → small CMR persistent cache fills → continuous read-modify-write
on shingled tracks → throughput collapses below ~10 MB/s → individual SCSI commands
stall for seconds → UAS command timeout fires (`uas_zap_pending … inflight: CMD`)
→ bridge drops off the bus (`cmd cmplt err -108`)**

Two drops match the prediction cleanly: **2026-07-26 23:31** and **2026-08-03
00:56**, each mid-write with large scatter-gather (`phys_seg 57`).

Two further drops followed the same day — **22:27:44** and **22:35:38** — but
these were **operator-induced, not spontaneous**: the disk was physically picked
up and flipped to read its label for the hardware cataloguing above. Three pieces
of evidence separate them from the real failures:

1. **No bulk write was in flight.** At 00:56:48 the failing command was
   `op WRITE … phys_seg 57` with `failed to convert unwritten extents … potential
   data loss` — a large multi-segment data write. At 22:27:44 the only writes are
   `sector 0 … phys_seg 0` (a flush/barrier) and the journal superblock — i.e.
   ext4's own shutdown housekeeping *caused by* the disconnect, not a workload
   preceding it.
2. **Connector bounce, not a timeout.** Device numbers went **8 → 9 → 10 inside
   one second**, with device 9 living under a second. A firmware/UAS timeout
   produces one clean disconnect and one re-enumeration; rapid multi-bounce is the
   signature of a physical make/break at the connector.
3. **Timing** matches the label-reading exactly, and the 22:35 repeat is
   consistent with continued handling while the filesystem was still recovering.

**A tempting corroboration that does NOT hold:** a burst of PCIe AER correctable
errors appears at 22:25, which looks like chassis disturbance. It is not evidence —
those errors are **chronic**, ~2,900/hour every hour (376,556 since 08-01) on the
`alx` NIC. Checked and discarded; noted here so it isn't re-run as a theory.

So the corrected spontaneous-drop history is:

| When | In-flight command | Cause |
|---|---|---|
| 2026-07-26 23:31 | write | spontaneous — 16 h stale mount |
| 2026-08-03 00:56 | `WRITE`, `phys_seg 57` | spontaneous — 14 h 43 m outage |
| ~~2026-08-03 22:27~~ | flush/journal only | **operator — disk handled** |
| ~~2026-08-03 22:35~~ | `Read(10)` LBA 2050 | **operator — during recovery** |

**2 spontaneous drops in 13 days, both mid-write.** A first pass over these logs
read the four events as "3 incidents in 22 hours — the device is degrading."
**That reading is wrong** and is recorded here so it is not reached again: it
counted the two operator-induced drops as hardware failures. There is no evidence
of an accelerating failure rate, and the `Read(10)` at 22:35 is *not* evidence that
reads trigger drops. The SMR-write mechanism remains the only explanation needed
for both genuine failures.

**Lesson for future RCA here: this disk is hand-portable and unsecured.** Any drop
must be checked against physical handling before it is counted as a hardware
trend.

**This reframes the disk's role.** An SMR drive is a poor target for \*arr imports
(sustained writes) but perfectly adequate for streaming (sequential reads). Reads
do not touch the CMR cache and do not trigger the stall.

### Why the 2026-07-27 mitigations did not apply

Neither failed — neither was in scope:

| Mitigation | Why it did not fire |
|---|---|
| fstab `x-systemd.before=pve-guests.service` | boot ordering only; **no boot occurred** |
| [`vm150-require-virtiofs.sh`](../scripts/proxmox/vm150-require-virtiofs.sh) | runs at VM `pre-start` only; the VM was **already running**. When it did run at 15:40:45 it correctly passed both shares |

The hookscript header claims it covers "the disk dropping off the bus while
running, then a VM restart". True — but only *if* a restart happens, and that
restart is human-initiated. Nothing detects a drop while the VM runs.

### Why the remount alone did not fix it

Expected, and worth restating: `virtiofsd` resolves `--shared-dir` **once** and
pins that inode. The manual `mount` created a *new* inode on `sdc1`; virtiofsd was
still holding the dead `sdb1` one. No guest-side action can reattach it — only a
cold VM restart. **Host remount + VM restart is the correct and only sequence.**

### Why nothing alerted — again

`media-mount-health.sh`, written after 07-27 specifically to end green-dashboard
outages, pushed **166 consecutive `ok` heartbeats and 0 failures** across the whole
14 h 43 m. All three checks passed against a **shut-down filesystem**:

| Check | Result | Why it passed |
|---|---|---|
| `findmnt --mountpoint` is `virtiofs` | pass | the guest mount never went away |
| `/mnt/media/library` exists | pass | virtiofsd's pinned fd + cached dentries |
| size ≥ 800 GiB | pass | `statfs` on the pinned inode still returned **915 GiB** |

Meanwhile every actual `read()` returned `EIO`, as Jellyfin and Radarr both logged.

**The claim "check 3 is the load-bearing one" is falsified for this failure mode.**
It holds for 07-27 (wrong filesystem → wrong size) but not here: right identity,
right size, right fstype, dead filesystem. **Size cannot see this — only a read
can.** The monitor gained a read check as a direct result (check 4/5).

**Confirmed live, 2026-08-04.** While writing this section the same failure was
found *in progress*, which is as clean a validation as the design could get:

```
$ findmnt /mnt/media          → virtiofs                    (check 1 passes)
$ df -h /mnt/media            → 916G, 259G used             (check 3 passes)
$ ls -ld /mnt/media/library   → drwxrwsr-x jaskier jaskier  (check 2 passes)
$ ls -1  /mnt/media/library   → Input/output error (os error 5)   ← check 4 FAILS
```

The monitor had pushed **57 more consecutive `ok` heartbeats, 0 failures**. On
geralt the host mount was *healthy* (`/dev/sdb1`, remounted 22:35:53) — the fault
was purely virtiofsd still holding the **`sdc1`** inode from the 16:19 VM start,
visible as `EXT4-fs warning (device sdc1) … comm vring_worker: error -5`, with
`/dev/sdc` no longer existing at all. `vring_worker` is a virtiofsd thread: proof
the pin, not the disk, was the live fault.

The *trigger* was the operator handling the disk (above), but everything
downstream was genuine — an unintended and rather valuable fault-injection test.
It confirms the failure mode reproduces from **any** bus drop, whatever its cause,
and that checks 1–3 cannot see it while check 4 catches it immediately.

**Gotcha found in the same recovery: `qm reboot 150` does not work here.** It has
failed on both attempts, in the same way each time — the reboot task returns `OK`,
then the restart dies with `start failed: QEMU exited with code 1`, and a second
manual `qm start` succeeds:

| Attempt | Reboot fails | Manual start succeeds |
|---|---|---|
| 2026-08-03 | 15:40:45 | 15:44:04 |
| 2026-08-04 | 00:06:18 | 00:08:25 |

The hookscript passes both shares immediately before the failure, so it is not the
guard — most likely a virtiofsd socket teardown/re-bind race on this VM. **Use
`qm stop 150 && qm start 150`, not `qm reboot 150`**, or expect to run the start
twice and to be briefly misled into thinking the mount is still broken.

### No collateral this time

`pve-root` stayed at 15 % (9.4 G), qBittorrent logged **zero** errors and no
`missingFiles`, and Radarr failed loudly (`Unable to get free space … I/O error`)
without writing anything. The asymmetry against 07-27 is instructive: then the
guest was pointed at a **live empty placeholder** (writable → silent corruption);
here it was pointed at a **dead filesystem** (hard `EIO` → everything refused). The
`create_host_path:false` guards were never even exercised.

### Fixes, and which failure each one answers

| Fix | Answers |
|---|---|
| Read check (4/5) in [`media-mount-health.sh`](../scripts/monitoring/media-mount-health.sh) | the 14 h 43 m of green heartbeats — the only check that can see a dead-but-mounted filesystem |
| `usb-storage.quirks=0bc2:ab24:u` via **`modprobe.d`, not GRUB** | the UAS command timeout. Also clears the vendor-wide `US_FL_NO_ATA_1X`, which may restore SMART. Delivered outside the kernel cmdline because that is the path blamed for the 07-28 boot hangs |
| `queue_depth=1` (runtime probe) | reduces UAS command concurrency with zero boot risk and instant revert — a test, not a fix |
| Keep sustained writes off the disk (downloads/imports land on `steel`) | the **root cause**. Targets SMR cache exhaustion directly |
| Auto-remount on re-enumeration | the host mount sitting dead from 00:57 to 15:39 — **filed here, never implemented, and the direct cause of the 12-day [2026-08-10 / 22](#incident-2026-08-10--22--usb-link-fault-12-day-silent-outage) outage. Finally deployed 2026-08-23 as part of [proposal 005](proposals/005-nfs-media-share.md)** |

**Still open:** virtiofs pins the inode, so even an auto-remount cannot heal the
guest without a VM restart. Replacing the media share with **NFS** would remove
that constraint entirely (an NFS client recovers on its own; export with the
`mountpoint` option so it refuses to serve the empty placeholder).

***Built 2026-08-23.*** [Proposal 005](proposals/005-nfs-media-share.md) replaced
virtiofs with NFS over a dedicated storage network, and
[proposal 004](proposals/004-media-mount-self-healing.md) — which would have
automated the VM restart instead of removing the need for it — was superseded
before deployment. Repair is now host-side only and takes ~13 s with the guest
untouched. One correction to the parenthetical above, learned by fault injection:
the `mountpoint` option refuses to export a path that is **not a mount point**,
but it does *not* protect against a path that is mounted and **dead** — it went
on exporting a filesystem in `shutdown` state throughout the test. It answers
07-27, not 08-03.

**Accepted position (revised 2026-08-03):** the drive is SMR and will stall under
sustained write; the bridge will drop when it does. The lab's job is to (a) stop
writing to it heavily, (b) detect the drop in minutes rather than hours, and
(c) make recovery not require a human. A replacement should be **CMR** — swapping
only the enclosure would leave the root cause in place.

## Incident 2026-08-10 / 22 — USB link fault, 12-day silent outage

The third media outage, and the first that is **not** the SMR mechanism. A
one-second bus drop became a **12-day** outage because nothing re-arms the mount.
Detection worked perfectly and still nobody acted, which makes this as much an
alerting incident as a storage one.

geralt never rebooted (up 17 d at diagnosis). The disk was healthy, present and
unmounted the entire time.

### What happened

| When (IST) | Event |
|---|---|
| 08-10 **00:15:37** | `usb 2-3: USB disconnect` — spontaneous, while virtiofsd (`comm vring_worker`) was serving **reads**. `device offline error, dev sdb, sector 0 op WRITE` (a flush), `EXT4-fs (sdb1): shut down requested (2)`, `Aborting journal on device sdb1-8` |
| 00:15:37 | systemd: `Unmounted mnt-media.mount` — **and nothing ever remounts it** |
| 00:15:37 | Disk re-enumerates **0 s later** at SuperSpeed as device 3, attaches as **`sdc`** (was `sdb`). Healthy. Left unmounted |
| 00:15:47 | `media-mount-health.service` FAILs: `cannot enumerate /mnt/media/library`. **10 seconds after the drop** — the monitor did its job |
| 00:16:33 | Kuma marks monitor 23 down → ntfy fires. **Once.** User received it, did not check the server |
| 08-15 **16:34:44 → 16:35:04** | Second event, worse: **4+ disconnect/re-enumerate cycles in 20 s**, `device descriptor read/64, error -71`, bouncing between `2-3` and `1-3`, ending in a permanent fallback to **USB 2.0** (`speed=480`) |
| 08-22 01:27 | Diagnosis. `/mnt/media` still unmounted, disk still healthy, still at 480 Mb/s |

`/mnt/media` was down for **12 days 1 h**. Jellyfin was retrying one transcode
(`South.Park.S02E04`) every ~5 s from a client left on the play screen — those
retries are what kept `EXT4-fs warning … comm vring_worker` scrolling in geralt's
log for twelve days.

### Root cause: the USB link, not SMR

This is the important finding, because it **contradicts the standing position**
from [2026-08-03](#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr).
The SMR remediation is in place and **working**:

| Evidence | Reading | What it rules out |
|---|---|---|
| `188 Command_Timeout` | **65558** vs the 08-04 baseline **65557** — **+1 in 18 days** | Under the SMR/UAS mechanism this counter climbed hard. It has essentially stopped. The quirk beat it |
| `usb-storage 2-3:1.0: Quirks match for vid 0bc2 pid ab24: 800000`, `UAS is ignored for this device` | quirk loaded and active | UAS is disabled, so a **UAS command timeout cannot be what dropped the bus**. This was a raw USB disconnect |
| In-flight I/O at the drop | `comm vring_worker` — **read-dominant** (Jellyfin), no \*arr import running | SMR cache exhaustion, which needs sustained *writes* |
| 08-15 signature | `error -71` on descriptor reads, repeated re-enumeration, permanent drop to USB 2.0 | Shingled-write stalls do not renegotiate link speed. This is **physical layer** |
| `199 UDMA_CRC_Error_Count` | **0** | the SATA link *inside* the enclosure. Note this does **not** exonerate the USB cable — it is not on that link |
| `191 G-Sense_Error_Rate` | **10** | the drive has taken knocks; consistent with the 08-15 cascade being physical handling |

Drive health is pristine — `5 Reallocated_Sector_Ct` 0, `197 Current_Pending_Sector`
0, `198 Offline_Uncorrectable` 0, SMART `PASSED`, 2119 power-on hours. **The
platters are fine. Suspect the cable and the port, not the disk.**

Per the standing lesson from 08-03 — *this disk is hand-portable and unsecured,
check physical handling before counting a drop as a hardware trend* — the 08-15
cascade most likely **was** physical handling of the drive or its cable.

### Why a one-second glitch became twelve days

`mnt-media.mount` is a one-shot fstab unit. On device loss it deactivates; when
the device returns 0 s later under a **new kernel name**, nothing Wants it, so it
stays dead indefinitely. The 07-27 fix
(`x-systemd.before=pve-guests.service`) is **boot ordering only** and does nothing
for a mid-flight drop — the same reason it did not apply on 08-03.

"Auto-remount on re-enumeration" was listed as a fix in the 08-03 table and
**never implemented**. This incident is the bill for that.

### Why detection worked and it still ran twelve days

Unlike 07-27 and 08-03, the monitor was **not** blind. Check 4 caught it in ten
seconds and failed ~3,400 consecutive times over twelve days. The gap moved
downstream, to notification:

**Every Kuma monitor has `resend_interval = 0`** — notify once on the down
transition, then never again. A total media outage got **one ntfy at 00:16 AM**
and silence for twelve days. The user received that notification and did not act
on it, which is the expected outcome for a single midnight buzz with no follow-up.

This is now the cheapest high-value fix in the lab: one field, per monitor.

### Collateral

None. Same asymmetry as 08-03: the guest was pointed at a **dead** filesystem
(hard `EIO`) rather than a live empty placeholder, so everything refused loudly
instead of writing to the wrong disk. Sonarr logged `Unable to get free space and
unmapped folders for root folder /data/library/tv/` and wrote nothing;
`pve-root` was untouched. The `create_host_path:false` guards were never
exercised.

The filesystem superblock reads `Filesystem state: clean` with
`Last write time: Tue Aug 4 23:06:11` — i.e. **stale**, because the device was
already gone when ext4 tried to mark it dirty. `clean` here is not evidence of a
clean shutdown; the journal was aborted. fsck before remounting.

### Recovery

```bash
# on geralt
fsck.ext4 -fp /dev/disk/by-label/media   # journal was aborted; -p auto-fixes safe issues
mount /mnt/media
findmnt /mnt/media && ls /mnt/media/library   # must list, not EIO

# only then — virtiofsd must re-resolve the pinned inode
qm stop 150 && qm start 150               # NOT qm reboot
```

### Fixes, and which failure each one answers

| Fix | Answers |
|---|---|
| **DONE 2026-08-23** — self-healing mount + NFS, [proposal 005](proposals/005-nfs-media-share.md) | the mount sitting dead from 08-10 to 08-22, **and** the VM restart that virtiofs pinning made unavoidable. Closes the "auto-remount on re-enumeration" item left open on 08-03. Verified by fault injection: 13 s to heal, ciri's uptime unbroken, zero container restarts |
| **PARTIAL** — `resend_interval` on the Kuma monitors (30–60 min) | the twelve days. Still the highest-value change here. Set on `media-export` and `media-mount`; **~29 monitors remain on the `0` default** |
| Reseat/replace the USB cable, confirm the link returns to 5000 Mb/s | the **root cause**. *(2026-08-23: the link is back at `speed=5000` / USB 3.0 on its own, having been at 480 since 08-15. Less urgent than it was; the drop history stands.)* |
| ~~Keep sustained writes off the disk (downloads/imports on `steel`)~~ → **DONE differently 2026-08-23** | steel was vetoed (reserved for photo growth). Proposal 005 put in-flight torrent writes on a `backup=0` NVMe zvol instead, leaving only one sequential write per completed file. Note it would **not** have prevented this incident either way — the drop happened under read traffic |

**Revised position (2026-08-22):** the 08-03 conclusion — "the drive is SMR and
will stall under sustained write" — remains true but is **no longer the active
failure mode**. The UAS quirk closed it. What drops the bus now is the physical
USB link, and the lab's job is unchanged: detect in minutes, recover without a
human, and make the alert survive being ignored once. A replacement should still
be **CMR**, but the cable is the cheaper suspect and should be eliminated first.

### Postscript 2026-08-23 — the structural fix, and what testing it found

[Proposal 005](proposals/005-nfs-media-share.md) is deployed. `/mnt/media` is no
longer a virtiofs share: geralt exports it over NFSv4.2 on a dedicated,
port-less storage bridge, and ciri mounts it `hard` with `x-systemd.automount`.
An NFS client holds a *network handle* rather than a pinned inode, so the whole
class of failure that made this incident twelve days long — "the host can remount
all it likes, the guest is still being served the dead filesystem" — no longer
exists. `udev` → `media-autoheal.sh` remounts and re-exports host-side; the guest
blocks and resumes on its own.

**Measured, not asserted.** Unbinding the USB device with everything running:
repair completed in **13 s**, ciri's uptime unbroken, **zero container restarts**.
The same fault on 2026-08-10 cost 12 days and would have cost a full VM restart
even had someone noticed.

Two findings from that test are worth carrying forward, because both contradict
things written above:

- **`readdir` does not prove a filesystem is alive.** The first heal attempt
  *failed silently*: `media-autoheal.sh` probed with `ls`, concluded "nothing to
  heal", and left nfsd exporting a corpse. `library/` has three entries and had
  just been read, so the readdir was served entirely from the **dentry cache**.
  On that same dead mount, `dd … iflag=direct` returned `EIO` — and both Kuma
  monitors had flagged the fault correctly, because both use `O_DIRECT`. *The
  healer was the only component using a weaker probe than the thing watching it.*
  This generalises past media: the [08-03 lesson](#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr)
  was that `stat`/`df` pass against a shut-down ext4; the 08-23 lesson is that
  **`readdir` does too, whenever the directory is small and warm.** Only a
  cache-bypassing byte read reaches the disk.
- **The `mountpoint` export option does not cover mounted-but-dead.** It refuses
  to export a path that is not a mount point, which answers 07-27's empty
  placeholder. It went on happily exporting a filesystem in `shutdown` state
  throughout this test. Do not over-trust it.

**Still open:** `resend_interval` on ~29 remaining monitors — which, note, is the
one fix on the list above that would have shortened *this* incident, and it is
still the cheapest.

### Postscript 2026-09-02 — the link fault is still live, and self-healing hid it

Measured on geralt at **uptime 8 d 21 h**: **54 `USB disconnect` events and 54
`Aborting journal on device` events.** The disk drops off `usb 1-3` every few
hours — 09-01 at 07:15, 09:18, 09:58, 10:05, 13:03, 17:30, 20:20, 22:12, 22:27;
09-02 at 02:08, 04:16, 05:14, 05:43, 11:25, 14:01 — and re-enumerates under a new
kernel name each time (it has walked `sdm → sdn → sdp → sdq → sdv …`; always
address it as `/dev/disk/by-id/usb-Seagate_BUP_Slim_BK_<SERIAL>-0:0`, never
`/dev/sdX`).

**The SMR question is now closed, definitively.** `188 Command_Timeout` reads
**65558** — the *same value* recorded at the 08-22 diagnosis. That is **+0 in
eleven days** and **+1 in the twenty-nine days** since the 08-04 baseline of
65557, across +687 power-on hours. The UAS quirk beat the stall mechanism and
kept beating it. The platters remain pristine:

| Attribute | 08-22 | 09-02 |
|---|---|---|
| 188 Command_Timeout | 65558 | **65558** |
| 5 Reallocated_Sector_Ct | 0 | 0 |
| 197 Current_Pending_Sector | 0 | 0 |
| 198 Offline_Uncorrectable | 0 | 0 |
| 187 Reported_Uncorrect | 0 | 0 |
| 199 UDMA_CRC_Error_Count | 0 | 0 |
| 9 Power_On_Hours | 2119 | 2396 |
| 12 Power_Cycle_Count | — | 311 |
| 4 Start_Stop_Count | — | 667 |
| 191 G-Sense_Error_Rate | 10 | 10 |
| 194 Temperature_Celsius | — | **47 (max 51)** |

**This reverses the 08-23 note that the cable is "less urgent than it was".**
`/sys/bus/usb/devices/1-3/speed` reads **480** again, having been back at 5000 on
08-23. With the SMR mechanism ruled out and every media counter at zero, the
physical link is not merely the leading suspect — it is the only one left. The
cable, the port and the enclosure's power delivery are the cheap tests, and
47 °C (max 51) in a plastic 2.5" enclosure is worth ruling out alongside them.

### The uncomfortable part: the fix worked, and that is why nobody noticed

[Proposal 005](proposals/005-nfs-media-share.md)'s self-healing mount performed
exactly as designed, 54 times. The 14:01 drop is representative:

```
14:01:04  usb 1-3: USB disconnect, device number 53
14:01:04  EXT4-fs (sdm1): shut down requested (2) / Aborting journal on device sdm1-8
14:01:04  usb 1-3: new high-speed USB device number 54 … attaches as sdn
14:01:15  media-autoheal: /mnt/media is mounted but not readable — detaching the dead mount
14:01:28  media-autoheal: /mnt/media remounted and readable
14:01:29  media-autoheal: export refreshed — media path healed end to end
```

**~14 s, end to end**, matching the 13 s measured under fault injection on 08-23.
ciri blocks on the `hard` NFS mount and resumes; no container restarts, no VM
restart, no human.

That is the correct outcome, and it carries a cost this incident log should
record plainly: **a hardware fault that fires every few hours produced no outage,
and therefore produced no pressure to fix the hardware.** The 08-10 incident ran
twelve days and was impossible to ignore once seen. Its successor ran fifty-four
times in nine days and was invisible. Detection is not the gap this time —
`media-autoheal` and the Kuma monitors all fired correctly; each event simply
heals faster than it can accumulate into anything a human would look at.

The one place the deterioration stayed visible was a service nobody was reading
the logs of. qBittorrent, seeding from `/data/downloads/complete`, floods:

```
File error alert. Torrent: "…". File: "/data/downloads/complete/….mkv".
  Reason: "… file_read (…) error: I/O error"
```

every one to two seconds while the mount is dead. Two second-order effects:

- **It shreds qBittorrent's own log history.** qBittorrent rotates
  `qbittorrent.log` at 64 KB and keeps *every* `.bak` — the directory held
  **1,301 files / 92 MB** at diagnosis. The `No space left on device` entries
  from the 13:40 event the same day had already been rotated out of reach within
  the hour.
- **That directory lives on ciri's `scsi1` (`/data`), which _is_ in the nightly
  PBS job** — unlike the two `backup=0` scratch disks. It is small in absolute
  terms today and growing on a fault-driven schedule.

**Standing lesson:** an auto-healer that hides a fault completely must be paired
with something that *counts* the fault. A drop that self-repairs in 14 s is still
a drop, and 54 of them is a hardware trend. `dmesg -T | grep -c "USB disconnect"`
against uptime is the whole check.

### Fixes, and which failure each one answers (2026-09-02)

| Fix | Answers |
|---|---|
| **Replace the USB cable; if the drops persist, the enclosure** — then confirm `/sys/bus/usb/devices/1-3/speed` returns to `5000` and stays there | the **root cause**, now the only remaining suspect. Promoted back to urgent — this reverses the 08-23 downgrade |
| Check thermals — 47 °C running, 51 °C peak | a plausible contributing mechanism for bus-power drops, and free to eliminate |
| **Count the drops.** A monitor on `USB disconnect` events per unit uptime, alerting on rate rather than on outage | the fact that 54 faults produced no signal a human acted on, because each one healed in 14 s |
| Cap qBittorrent's log retention | 1,301 files / 92 MB of rotated logs on a PBS-backed disk, and the loss of forensic history exactly when it is needed |
| ~~Auto-remount on re-enumeration~~ — **DONE 2026-08-23**, verified 54× in production | the 12-day outage. This one is finished; the evidence above is it working, not failing |

## Incident 2026-09-02 — torrent scratch exhausted by three 4K REMUXes

The first failure of the `scsi3` scratch disk added by
[proposal 005](proposals/005-nfs-media-share.md), and the first media-stack
incident with **no hardware fault and no collateral** — a pure capacity-planning
miss. Detection worked, the blast radius was exactly what the design predicted,
and the whole thing was contained to the disposable disk.

### What happened

Radarr grabbed three 4K UHD BluRay REMUXes within one minute:

| Torrent | Full size |
|---|---|
| `Crime.101.2026 … REMUX` | 79.9 G |
| `28.Years.Later.The.Bone.Temple.2026 … REMUX` | 69.1 G |
| `Minions.And.Monsters.2026 … REMUX` | 62.1 G |
| **combined** | **211.1 G** onto a 100 G disk |

| When (IST) | Event |
|---|---|
| 12:44–12:45 | all three added; `max_active_downloads` was **3**, so all three ran at once |
| 13:40:36 | `/mnt/torrents` hits 0 bytes free. All three error in the *same second*: `file_write (…) error: No space left on device` |
| 13:40 → | Beszel alerts on `/mnt/torrents` |
| ~13:55 | user pauses two, resizes 100 G → 150 G, sets `max_active_downloads` 3 → 2 and preallocation **on** |
| 13:57:08 | `EXT4-fs (sdd): resized filesystem from 26214400 to 39321600 blocks` — online, no restart |

Only **one** of the three could ever have completed. Usable space was ~93 G
(5 % ext4 root reserve; qBittorrent runs as `jaskier`/13000). The largest alone,
79.9 G, fits. The two *smallest* together — 62.1 + 69.1 = 131.2 G — do not.

### Why it filled silently instead of refusing at add time

`preallocate_all` was **off**, so libtorrent wrote sparse files. Apparent size on
disk was 213 G against 93 G actually allocated: qBittorrent accepted all three
without complaint, wrote for **56 minutes**, and discovered the wall only when
the last block of the filesystem was gone. With preallocation on, the third add
fails immediately and loudly instead of taking the other two down with it an hour
later.

Verified after the change: a newly-added torrent got a full-size file with **0
blocks allocated** and errored at 0 % within seconds. Note the scope —
**preallocation only binds torrents added after the change.** libtorrent stores
the storage mode in resume data, so the three already in flight stayed sparse
(one showed 50 G allocated against 70 G apparent while running).

### Why the pipeline stopped rather than degraded

Three compounding behaviours, all worth knowing before the next time:

- **qBittorrent never retries an errored torrent.** It stays errored after space
  is freed; it needs a manual resume. A client or VM restart does not help — it
  rechecks, resumes, and re-errors in seconds if space is still short.
- **Errored torrents still hold download-queue slots.** With
  `max_active_downloads = 3` and all three slots held by torrents that could
  never finish, the next Radarr grab sat in `queuedDL` behind them. Every
  subsequent \*arr grab would have queued behind them too — head-of-line
  blocking, indefinitely.
- **Radarr will not clean up after itself.** It maps qBittorrent's `error` state
  to **Warning, not Failed** (`errorMessage: "qBittorrent is reporting an
  error"`), so despite `removeFailedDownloads: true` it does **not** blacklist
  the release, re-search, or remove anything. The upside is no re-grab storm
  chewing bandwidth; the downside is no self-recovery and no timeout. It waits
  forever.

### Why detection worked this time

**Beszel alerted on `/mnt/torrents`**, which is the first media-adjacent incident
in this log where the alerting story is simply "it worked". Proposal 005 §
Monitoring had deliberately deferred a dedicated check — *"Beszel's agent already
graphs guest disks; add a dedicated check only if it ever actually bites."* It
bit, and the deferred-by-design coverage held. **No Uptime Kuma monitor is needed
for scratch free space.**

### Collateral

**None**, and by construction. The `backup=0` scratch zvol is the only thing that
filled:

| Filesystem | State during the incident |
|---|---|
| `/mnt/torrents` (scsi3, scratch) | **100 % full** — the entire blast radius |
| `/data` (scsi1, Docker + app data) | 49 % — untouched |
| `/mnt/media` (NFS from geralt) | 52 %, 443 G free — untouched |
| `pve-root` | untouched |

The hardlink contract held, no nightly PBS snapshot was inflated, no import ran
against the wrong filesystem, and nothing repeated the 07-27 pattern. Wasted
bandwidth across the three torrents totalled 0.22 G. This is the separate-disposable-disk
design doing precisely its job — the failure was loud, local and cheap.

### Fixes, and which failure each one answers

| Fix | Answers |
|---|---|
| **DONE** — `scsi3` 100 G → 150 G, online | the immediate exhaustion. 4K REMUX at 60–90 G per title invalidates the original "two season packs + two movies ≈ 80–120 G" sizing |
| **DONE** — `max_active_downloads` 3 → 2 | three oversized torrents occupying every slot at once |
| **DONE** — `preallocate_all` **on** | the 56-minute silent fill. Now fails at 0 % in seconds, at add time, on the torrent that does not fit — and only that one |
| **DECLINED** — a Radarr/Sonarr quality or size cap | would have prevented the grab outright. The user declined it deliberately; do not re-propose. Consequently `max_active_downloads = 2` plus fail-fast preallocation are the *entire* guardrail, and 148 G still cannot hold a worst-case pair of 4K REMUXes — expect to hand-sequence large batches |
| Resume errored torrents by hand after space frees | qBittorrent's refusal to retry. There is no automatic recovery path; a stuck `error` torrent is a manual step, always |

## Incident 2026-09-02 (second) — one torrent move starved Jellyfin off the disk

Same day and the **same three REMUXes** as the scratch-exhaustion incident above:
one of them finished, qBittorrent began its move-on-completion onto the media
disk, and that single sequential write took Jellyfin playback down for the
duration. No hardware failed, nothing filled up, and no mitigation misfired —
this is the media pipeline's two halves contending for one USB 2.0-linked SMR
spindle, and the write winning totally.

Two things had to be true at once. **`queue_depth=1`** (a consequence of the
08-03 `IGNORE_UAS` mitigation) means a reader can never interleave behind a
writer — that makes contention *unfair*. **A connector negotiating USB 2.0
instead of SuperSpeed** left only ~10 MB/s to share — that is what made it
*catastrophic*.

Replacing the connector at 22:01 the same evening resolved it and settled which
factor dominated: same `queue_depth=1`, same quirk, 9.8 → **105 MB/s**, problem
gone. The analysis below is preserved as measured during the outage; the
resolution and revised recommendations follow it.

### What happened

| When (IST) | Event |
|---|---|
| 14:01:04 | USB disconnect #54 this boot; dev 53 → 54, `sdm` → `sdn`, journal aborted and remounted 15 s later. Routine by now — see the 08-10/22 postscripts |
| ~15:0x | qBittorrent completes `28.Years.Later.The.Bone.Temple.2026 … REMUX` (69.1 GiB) and starts moving it from the `scsi3` NVMe scratch to `/mnt/media/downloads/complete` over NFS |
| 15:14–15:21 | every Jellyfin playback attempt fails. ffmpeg starts, emits `size=0KiB time=N/A bitrate=N/A speed=N/A`, the transcode kill timer fires, the client's segment GET dies with `A task was canceled` |
| 15:2x | diagnosis; no intervention. The move was left to finish |

Jellyfin itself was never unhealthy: container `Up (healthy)`, `/health` 200, GPU
present and idle at 0 %, `/mnt/media` mounted and listable, every filesystem with
room to spare.

### It was not the GPU, and not the mount

Two eliminations worth recording, because both are the obvious first guess:

- **Not the GPU.** The failing jobs included plain remuxes (`-codec:v:0 copy`,
  no `hevc_nvenc`, no CUDA filter) and they produced `0KiB` identically. A GPU or
  CDI fault cannot explain a stream-copy producing nothing.
- **Not a broken mount.** `ls` and a *cached* `dd` both returned instantly at
  ~3 GB/s. A mount that is present, listable and fast on cached data looks
  perfectly healthy to every check we have — including
  `media-mount-health.sh`, whose byte-read probe reads the same early bytes that
  are already in page cache.

The reproduction that actually showed it, run inside the container against the
file Jellyfin was failing on:

```bash
# ffmpeg remux to /dev/null — reads 440 frames instantly from page cache at
# 36.5x, then falls off a cliff the moment it needs uncached data
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -i "<file>" \
  -c copy -t 20 -f null -
# frame=440 … speed=36.5x   ← page cache
# frame=482 … speed=0.621x  ← the disk
```

### Root cause: a half-speed link and `queue_depth=1`, plus one sustained writer

Measured on geralt while the move ran:

| Probe | Result |
|---|---|
| 64 MiB uncached read over NFS from ciri (`iflag=direct`, 1 GiB offset) | **did not complete in 180 s** (< 0.36 MB/s) |
| Same read directly on geralt against `/dev/sdn` | **9.8 MB/s** |
| `nfsd` threads in `D` state | **16 of 16** — all of them |
| `lsof` on ciri | hung; stat of the mount blocks |
| Move write rate | ~16 MiB/s sustained |

All sixteen `nfsd` threads were blocked in uninterruptible I/O wait serving the
write. There was no thread left to serve a read with, so Jellyfin's reads did not
merely go slow — they went nowhere.

Underneath that, the device geometry makes contention unwinnable:

```
/sys/block/sdn/device/queue_depth   1      ← usb-storage: ONE command in flight
/sys/block/sdn/queue/nr_requests    2      ← clamped by the above
/sys/block/sdn/queue/max_sectors_kb 120    ← usb-storage bulk transport default
/sys/block/sdn/queue/scheduler      [mq-deadline]
/sys/block/sdn/bdi/max_ratio        100    ← may claim the whole dirty budget
/sys/block/sdn/bdi/strict_limit     0
```

`mq-deadline`'s `read_expire=500ms` is the right idea and cannot help here: with
a two-slot queue and one command in flight, there is nothing to reorder. Every
read waits for the in-flight write to finish on the wire.

And the wire is half-speed. The drive is on the USB 2.0 bus while the SuperSpeed
bus sits **empty**:

```
/:  Bus 001 … root_hub, xhci_hcd/16p, 480M
    |__ Port 003: Dev 054, Mass Storage, usb-storage, 480M   ← the media disk
/:  Bus 002 … root_hub, xhci_hcd/8p, 10000M                  ← nothing attached
```

This is the link fault from the 08-10/22 incident, still live: **54 disconnects
and 54 journal aborts in the 9 days since boot.** Until now it was recorded as a
reliability problem. It is also a throughput problem, and this incident is what
made that visible.

### The mitigation that caused it

`/etc/modprobe.d/usb-storage-media.conf` carries `quirks=0bc2:ab24:u`
(`US_FL_IGNORE_UAS`), added after 08-03 to stop the bus drops under sustained
write. It works, and it is the direct cause of `queue_depth=1`: UAS is what
provides command queuing on USB mass storage, and `usb-storage` has none. The
120 KB `max_sectors_kb` comes from the same fallback.

So the media disk's write path was hardened by removing exactly the capability
that would have let a reader coexist with a writer. That was the correct trade in
August — bus drops cost 14-hour outages.

**But the quirk turned out not to be the binding constraint.** The connector swap
below left `queue_depth=1` untouched and still took throughput from 9.8 to
105 MB/s, which is enough for the whole workload with room to spare. The quirk
makes read/write contention *unfair*; it did not make it *fatal*. Re-testing it
is therefore now a low-priority experiment rather than a fix — and one that risks
re-opening the 08-03 stall for a benefit the cable already delivered.

### Why nothing alerted

Nothing was down. Beszel saw free space everywhere, Kuma's HTTP check on Jellyfin
got its 200, and `media-mount-health.sh` reads bytes that are already cached. The
gap is that **we have no probe for media-disk read latency under load** — the one
condition that actually breaks playback. A `dd … iflag=direct` from an uncached
offset with a `timeout` is the check that would have caught this, and it is
cheap. Note the probe must read from an **uncached offset**: `ls`, `df` and a
cached `dd` all returned instantly at ~3 GB/s throughout.

### Resolution — connector replaced 2026-09-02 22:01:31 IST

**The cable was the whole story.** The connector was swapped for the one from a
newer drive at **22:01:31 IST** (`usb 1-3` disconnect 22:00:55 → re-enumerated as
`usb 2-3` 36 s later). The drive moved to the SuperSpeed bus and every number
improved by an order of magnitude:

| | Before (USB 2.0) | After (SuperSpeed) |
|---|---|---|
| Bus / link | `usb 1-3`, **480M** | `usb 2-3`, **5000M** |
| `max_sectors_kb` | **120** | **1024** |
| Sequential read, geralt, `iflag=direct` | **9.8 MB/s** | **105 MB/s** |
| Sequential read over NFS from ciri | **< 0.36 MB/s** (did not finish in 180 s) | **127 MB/s** direct, **136 MB/s** buffered |
| Small-block read over NFS (32K / 64K) | not measurable | **128 / 104 MB/s** |

`max_sectors_kb` rising 120 → 1024 is the quiet half of the win: it is the
`usb-storage` transfer ceiling, and at USB 2.0 it capped every command at 120 KB.
Commands are now 8.5× larger over a 10× faster link.

**This reframes the whole incident.** The disk was never slow — 105 MB/s is a
healthy figure for a 2.5" SMR portable. It was being strangled by the connector,
and the "SMR is too slow for concurrent read+write" reading of 08-03 was, in
part, measuring a bad cable.

Capacity against the real workload, using the post-swap numbers:

| Load | Demand |
|---|---|
| 5 concurrent 4K streams @ 80–100 Mbps | ~50–60 MB/s |
| one qBittorrent move-on-completion | whatever is left, ~45 MB/s |
| \*arr metadata scans | negligible — cache hits, microseconds |

The disk now serves the entire worst case with headroom. **Rate limiting is
therefore no longer warranted** and has been dropped (see below).

**Still unproven: the drop rate.** 58 disconnects and 58 journal aborts this
boot, the last at 22:00:55 — which was the swap itself. Still 58 at 23:45 with the
link holding at 5000M: ~1 h 45 m clean against a fault that averaged one every
~3–4 hours. Encouraging, not yet evidence. The
old connector kept dropping right up to the end (16:19, 18:25, 18:52). **Do not
call the drop fault fixed until the disk has held a SuperSpeed link across
several days**, ideally through a full move-on-completion. If drops return on
this connector, the next step is the brand-new cable; if they stop, the cable was
the cause of the 08-10/22 link fault as well.

### Fixes, and which failure each one answers

| Fix | Answers |
|---|---|
| **DONE 22:01:31** — connector replaced with the newer drive's | the root cause. 9.8 → 105 MB/s, 480M → 5000M, `max_sectors_kb` 120 → 1024. Removes the starvation condition outright |
| **WATCHING** — drop rate on the new connector | the 58 drops. Needs days, not minutes. A brand-new cable is the next step if they recur |
| **DONE 23:38:56** — `nfsd` threads 16 → **32** | the 16-of-16 blocked pool. Cheap insurance, not a fix — see the sizing below for why 32 and not 64. Applied and verified — see "Applied" below |
| **PENDING** — an uncached read-latency probe in `media-mount-health.sh` | the detection gap. Every existing check passed during a total playback outage |
| **DEFERRED** — re-test whether `quirks=…:u` is still needed | `queue_depth=1`. Now much less urgent: with the link fixed there is bandwidth to spare, and re-enabling UAS risks re-opening the 08-03 stall. Only worth trying if contention recurs *after* the connector is proven |
| **DROPPED** — rate-limiting the move-on-completion | superseded by the connector fix. qBittorrent cannot do it natively anyway; the dead ends are recorded below so they are not re-attempted |
| **OPTIONAL** — `bdi/max_ratio` on the media disk | writeback burstiness. Much less pressing at 105 MB/s |
| Sequence large REMUX moves by hand outside viewing hours | the residual, if drops return and throughput collapses again |

#### Setting the `nfsd` thread count — the options

geralt runs **nfs-utils 2.8.3**, where `nfs-server.service` starts via
`/usr/sbin/nfsdctl autostart || /usr/sbin/rpc.nfsd`. That changes which knobs are
real:

| Mechanism | Persistent | Notes |
|---|---|---|
| `[nfsd] threads=N` in **`/etc/nfs.conf.d/kaermorhen.conf`** | yes | **Use this.** The project already owns this drop-in (proposal 005 § B1) and it already has an `[nfsd]` section — one line to add |
| `[nfsd] threads=N` in `/etc/nfs.conf` | yes | Same effect; the shipped line is commented at line 65. Editing the distro file instead of the drop-in breaks the project convention |
| `nfsdctl threads N` | **no** | Runtime, takes effect immediately, no restart and no client disruption. Ideal for testing a value before committing it |
| `echo N > /proc/fs/nfsd/threads` | **no** | Raw kernel interface, same immediate effect. Lowest-level fallback |
| ~~`RPCNFSDCOUNT` in `/etc/default/nfs-kernel-server`~~ | — | **Gone.** nfs-utils 2.8.3 dropped it; that file now holds only `RPCNFSDPRIORITY` and `NEED_SVCGSSD`. Recorded so it is not tried |

Recommended change — one line appended to the existing drop-in's `[nfsd]`
section:

```ini
# /etc/nfs.conf.d/kaermorhen.conf
[nfsd]
host=<STORAGE_PREFIX>.21
vers3=n
vers4=y
vers4.0=n
vers4.1=n
vers4.2=y
threads=32
```

```bash
systemctl restart nfs-server     # or, without restarting: nfsdctl threads 32
nfsdctl threads                  # expect pool-threads: 32
cat /proc/fs/nfsd/threads        # expect 32
```

Test it live with `nfsdctl threads 32` first — it applies instantly and reverts
on the next restart, so nothing is committed until the drop-in is edited.

**Applied 2026-09-02 23:38:56 IST.** Verified at every layer:

| Check | Result |
|---|---|
| `nfsdctl threads` | `pool-threads: 32` |
| `/proc/fs/nfsd/threads`, `/proc/fs/nfsd/pool_threads` | `32`, `32` |
| Actual kernel threads | `32` |
| `threads=` lines in the drop-in | exactly 1 — the guarded append did not duplicate |
| Export options | unchanged: `fsid=101`, `all_squash`, `anonuid=13000` |
| ciri's mount | `nfs4` intact, 1 client, all 32 threads idle |
| Read from ciri after the restart | **99 MB/s** direct, **203 MB/s** at 64K buffered |
| Jellyfin | `Up (healthy)`, `/health` 200 |

**Persistence is proven, not assumed:** the drop-in was written at **23:38:46**
and `nfs-server` restarted at **23:38:56**, ten seconds later — so the running 32
was read from the config file, not left behind by the live `nfsdctl` call.

**One benign warning to ignore.** Every start logs `nfsdctl: lockd configuration
failure`. It is **not** from this change: it appears on all six `nfs-server`
starts since the share was built on 2026-08-23 — i.e. every start in the journal.
`lockd` is the NFSv3 lock manager and this export is v4.2-only (`vers3=n`);
NFSv4 has integrated locking and never uses it. Cosmetic, recorded so it is not
chased later.

#### Why 32 is the right number for this workload

The measured facts that decide it:

- **There is exactly one NFS client.** `/proc/fs/nfsd/clients` = 1 — ciri. Every
  consumer (Jellyfin, the \*arrs, qBittorrent) is a container *inside* ciri
  sharing that one mount, so "4–5 streaming clients" is 4–5 processes behind a
  single NFS client, not 5 clients.
- **The client is not the constraint.** `mountstats` shows the transport has run
  up to **`max_slots` 1026** concurrent RPCs with **backlog utilisation 0** — it
  has never had to queue for a slot. Whatever the server offers, the client can
  fill.
- **Threads are needed for *blocking* work, not total RPCs.** Metadata ops
  (`getattr`, `lookup`, `readdir` — the \*arr scan pattern) are page/dentry-cache
  hits that return in microseconds. A burst of a thousand of those drains through
  a small pool almost instantly. Only disk-bound RPCs hold a thread.

Sizing against the real load:

| Source | Concurrent disk-bound RPCs |
|---|---|
| 5 streams × ~4 RPCs in flight (1 MB `rsize`, readahead pipelining) | ~20 |
| one qBittorrent move-on-completion | ~8 |
| \*arr metadata | ~0 sustained (cache hits) |
| **total** | **~28** |

**32 covers that with headroom**, which is the entire point: the failure was not
"too little bandwidth", it was **every thread in the pool consumed at once**, so
cache-hit operations that needed no disk at all could not be served. 16 sits
below the sustained demand; 32 sits above it.

**Going past 32 buys nothing here.** The device is `queue_depth=1` with
`nr_requests=2` — extra threads cannot create device parallelism, they just block
in block-layer request allocation. 64 is harmless but is headroom over headroom;
32 is the honest number. Revisit only if a second NFS client is ever added.

**Caveat on validating this empirically:** the classic tuning method is gone. The
`th` line in `/proc/net/rpc/nfsd` reads `th 16 0 0.000 …` — modern kernels
hardcode the histogram buckets to zero, so the "how often were all threads busy"
signal no longer exists. `/proc/fs/nfsd/pool_stats` still counts
`sockets-enqueued` (41.4M) against `packets-arrived` (22.8M), but on this kernel
the enqueue path runs unconditionally rather than only on starvation, so the
ratio is **not** a clean starvation metric either. The 32 above is reasoned from
the workload, not measured from the counters — do not treat a change in those
counters as proof it worked.

#### Does limiting read vs write at the NFS layer make sense?

Evaluated, and the answer is **no** — with one option worth keeping in mind.
There is **no native bandwidth throttle in NFS**, so every option is an indirect
lever:

| Lever | Verdict |
|---|---|
| **Asymmetric `rsize`/`wsize`** (keep `rsize=1M`, cut `wsize` to 256K) | **No.** It does shorten how long a thread holds the device per write, but it shrinks writes on an **SMR** drive — the opposite of what SMR wants. Small writes trigger read-modify-write in the CMR cache band, which is the 08-03 stall mechanism. Do not do this |
| **`sync` → `async` export** | **No, firmly.** It would free threads instantly, but `async` means the server acknowledges writes it has not committed. With 58 bus drops this boot, that is precisely the condition under which the client believes data is safe and it is not. `sync` is load-bearing on this disk. Revisit only after months of a clean drop record |
| **Lower the client's readahead to throttle reads** | **No, and it was worth checking.** The NFS client's `read_ahead_kb` is **128 KB against a 1 MB `rsize`**, which looks like a bottleneck on paper. Measured, it is not: 128 MB/s at 32K reads and 104 MB/s at 64K. Nothing to fix, and nothing to gain by lowering it |
| **`nconnect=4`** | **The one worth remembering.** All traffic currently shares **one TCP connection** (no `nconnect` in the mount options), so a 1 MB write RPC head-of-line-blocks reads at the transport. `nconnect` does not *limit* either side — it stops them sharing one pipe, which is strictly better than throttling. Costs a remount (all users must release the mount), so bundle it with the next maintenance window. Low priority at 105 MB/s |
| **`tc` egress shaping on ciri** | Still the **only** true rate limit, and no longer needed. Kept in the note below purely as a recorded option |

The dead ends, recorded so they are not re-attempted: **`docker run
--device-write-bps` / cgroup v2 `io.max`** cannot work — the target is an NFS
mount inside ciri, not a block device, and on geralt the writeback is done by
kernel flush threads that belong to no cgroup. **`ionice`** fails for the same
reason. **qBittorrent itself has no move-on-completion throttle** — its rate
limits are peer-traffic only.

Had a true rate limit still been wanted, the shape was: shape ciri's *egress*
toward geralt (NFS writes are ciri→geralt; reads are ciri *ingress*, so egress
shaping throttles the move and leaves playback untouched), helped by ciri
reaching the storage network on a dedicated `eth1`. Recorded, not implemented.

#### Optional — limiting the dirty-page budget of the slow disk

Much less pressing post-swap, but still sound if writeback burstiness ever bites.
With `vm.dirty_ratio=20` on 32 GB, up to ~6.4 GB of dirty pages can queue for the
USB disk:

```bash
echo 5 > /sys/block/<dev>/bdi/max_ratio
echo 1 > /sys/block/<dev>/bdi/strict_limit
```

Persist via a `udev` rule keyed on the drive's serial, never on `/dev/sdX` — the
letter changes on every reconnect (`sdm` → `sdn` → `sdp` → `sdq` → `sdt` → `sdv`
in one day):

```
# /etc/udev/rules.d/60-media-bdi.rules
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="<MEDIA_USB_SERIAL>", \
  ATTR{bdi/max_ratio}="5", ATTR{bdi/strict_limit}="1"
```
