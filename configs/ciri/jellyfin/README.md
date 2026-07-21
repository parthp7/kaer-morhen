# jellyfin — media server (ciri stack)

[Jellyfin](https://jellyfin.org) on **ciri** (VM 150), live at
`ciri:/data/stacks/jellyfin/`, port **8096**. Pinned at **10.11.11**
(released 2026-06-06).

Hardware transcoding via the GTX 1060 passed through to ciri
([gpu-passthrough.md](../../../docs/gpu-passthrough.md)). Client-side
compatibility — including the sideloaded Samsung TV app, the primary consumer —
is in [jellyfin-clients.md](../../../docs/jellyfin-clients.md).

Deployed **2026-07-22**; verified same day: container healthy on `10.11.11`,
media disk (ext4) shared into ciri via `virtiofs1`, GTX 1060 + NVENC reaching
the container, media bind read-only, repo mirror in sync. Remaining items are
web-UI/DNS follow-ups (transcoding settings, Pi-hole record, Kuma monitor).

## Files

- `compose.yaml` — mirror of the live file (scp'd from the VM after every
  change, per `CLAUDE.md`)
- `.env.example` — placeholder template; real `.env` lives only in the VM

## Storage design

| Data | Lives on | Why |
|---|---|---|
| media library | **external USB HDD on geralt**, ext4, `/mnt/media`, into the VM via **virtiofs** at `/mnt/media` | bulk sequential video; must not sit in a VM disk or inflate PBS |
| `config/` (DB, artwork, trickplay) | ciri `/data` (NVMe zvol) | small-file random I/O — painful from a 5400rpm USB disk |
| `cache/` (transcode scratch) | ciri `/data` (NVMe zvol) | write-heavy scratch, regenerable |

### Filesystem choice: ext4

Prescribed by [storage.md](../../../docs/storage.md)'s Future work section for
exactly this disk, and it holds up:

- The media is **explicitly disposable** — entertainment content, re-obtainable.
  ZFS's headline benefit here would be checksummed bit-rot *detection*, which
  earns little on data nobody would restore.
- **ZFS on USB is a known bad pairing**: a USB bridge reset or re-enumeration
  can suspend the pool, which on a headless node means manual `zpool clear`/
  re-import. ext4 remounts.
- geralt's ARC is capped at 2 GiB on a 16 GB node already hosting an 8 GB VM
  ([storage.md](../../../docs/storage.md) §5) — a second pool competes for it.
- ext4 is trivially recoverable from any live USB, which matters more than
  features on a disk with no backup.

Rejected: **XFS** (fine for large files, but can't shrink and buys nothing
here), **exFAT/NTFS** (no POSIX permissions, weaker journaling — reformat even
if the drive ships preformatted), **ZFS** (above).

### Mount method: virtiofs, superseding the `--scsi2` plan

[docker-vm.md](../../../docs/docker-vm.md) originally planned the media disk as
a raw `--scsi2` passthrough with `backup=0`. That plan predates ciri having
either virtiofs or the GPU, and is now stale:

- Its main advantage was preserving live migration / hibernate / RAM snapshots.
  **Those are already gone** — `virtiofs0` (photos) and `hostpci0` (GPU) each
  independently disqualify ciri. Passthrough would be defending nothing.
- virtiofs keeps **geralt's own read/write access** to the media while ciri
  runs: bulk-loading over the network, and any future stack wanting the library.
- A USB disk **will** re-enumerate eventually. geralt recovering an ext4 mount
  is a well-understood failure; a block device yanked from under a running
  guest's filesystem is how you corrupt one.
- `backup=0` becomes moot — a host path is never a VM disk, so vzdump never
  sees it. Same property that keeps `/mnt/photos` out of PBS.

Cost: somewhat lower throughput than raw passthrough. Irrelevant at video
bitrates the 1060 can transcode.

### On-disk layout

Laid out for a future *arr stack (Sonarr/Radarr/qBittorrent) even though none
is deployed: `downloads/` and `library/` share one filesystem, so imports can
**hardlink** instead of copying — no double disk usage, no long copy on import.
Costs nothing if the *arr stack never happens.

```
/mnt/media/                    (geralt, ext4, USB)
├── library/                   ← Jellyfin sees only this, read-only
│   ├── movies/
│   └── tv/
└── downloads/                 ← future *arr writes here, hardlinks into library/
```

### The disk, as-built (Seagate BUP Slim, 932 GiB)

Two things surfaced plugging it in (2026-07-21), both worth knowing for a
re-seat or replacement:

- **It enumerates reliably only at USB 2.0.** On USB 3.0 (`SuperSpeed`) it
  connected and dropped within the same second (`USB disconnect` immediately
  after enumeration — a bus-power/link brown-out on spin-up). Moved to a port
  it comes up as `high-speed` and stays stable. **Accepted trade-off**: ~40 MB/s
  ceiling instead of USB 3.0 — enough for a couple of concurrent video streams,
  and stable beats fast-but-dropping. If a future port/cable holds USB 3.0, take
  it, but not at the cost of the drops.
- **It shipped NTFS-preformatted with existing data.** Reformatted to ext4 only
  after confirming (2026-07-22) the contents were disposable. The "blank" premise
  was wrong on first inspection — always eyeball an unfamiliar disk before the
  `mkfs`.

## Runbook (as executed 2026-07-22)

### 1. geralt — format and mount the USB disk

Plug the disk in, then identify it by stable id — **never `/dev/sdX`**, which
reorders across boots and is especially volatile for USB:

```bash
lsblk -o NAME,SIZE,TYPE,TRAN,FSTYPE,LABEL,MODEL
ls -l /dev/disk/by-id/ | grep -i usb
```

Confirm the id matches the intended disk before continuing — the next command
is destructive.

```bash
DISK=/dev/disk/by-id/usb-<MEDIA_DISK_ID>          # placeholder → secrets.local.yaml

# One whole-disk GPT partition, type 8300
sgdisk -Z "$DISK"                                  # DESTRUCTIVE: wipes the disk
sgdisk -n1:0:0 -t1:8300 -c1:media "$DISK"

# -m 0: zero root-reserved space. The default 5% would strand ~100 GB on a 2 TB
# disk; no system process ever runs from here.
mkfs.ext4 -L media -m 0 "${DISK}-part1"
```

Mount it, by label, with `nofail` so a dead or absent USB disk can never hang a
headless node's boot:

```bash
mkdir -p /mnt/media
echo 'LABEL=media /mnt/media ext4 defaults,noatime,nofail 0 2' >> /etc/fstab
systemctl daemon-reload && mount /mnt/media
findmnt /mnt/media                                 # ext4, rw, noatime

mkdir -p /mnt/media/library/movies /mnt/media/library/tv /mnt/media/downloads
```

### 2. geralt — share into ciri via virtiofs

`virtiofs0` is taken by `photos`, so media is **`virtiofs1`**:

```bash
pvesh create /cluster/mapping/dir --id media --map node=geralt,path=/mnt/media

# virtiofs is NOT hot-pluggable — the change stays "pending" until a cold
# restart; a guest-internal reboot is not enough.
qm set 150 --virtiofs1 dirid=media
qm shutdown 150 && qm start 150
qm config 150 | grep virtiofs                      # virtiofs0: photos, virtiofs1: media
```

### 3. ciri — mount the share

Mount tag is the mapping id (`media`):

```bash
sudo mkdir -p /mnt/media
echo 'media /mnt/media virtiofs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/media
findmnt /mnt/media                                 # FSTYPE virtiofs
ls /mnt/media                                      # library  downloads
```

### 4. ciri — deploy

```bash
mkdir -p /data/stacks/jellyfin && cd /data/stacks/jellyfin
# copy in compose.yaml; create .env from .env.example
chmod 600 .env
docker compose up -d
docker compose ps
docker compose logs -f jellyfin                    # watch first-run init
```

If the container refuses to start with a bind-source error, that is the
missing-mount guard working — `/mnt/media/library` doesn't exist, meaning the
USB disk or the virtiofs share is down. Fix the mount, don't remove the guard.

### 5. Verify the GPU reached the container

```bash
docker exec jellyfin nvidia-smi                    # GTX 1060 visible
# NVENC/NVDEC present — this is what NVIDIA_DRIVER_CAPABILITIES=...,video buys
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -encoders \
  | grep nvenc
```

### 6. First run (web UI)

- `http://<LAN_PREFIX>.150:8096` → create the admin account.
- Add libraries: **Movies** → `/media/movies`, **Shows** → `/media/tv`.
- Dashboard → Playback → **Transcoding**:
  - Hardware acceleration: **NVIDIA NVENC**
  - Enable HEVC, and **enable hardware decoding** for H.264/HEVC
  - Enable **tone mapping** (CUDA) — this is what makes HDR10 → SDR cheap, and
    the AU7000 needs it for Dolby Vision profile 5 files
  - **Do not** enable AV1 encoding — Pascal has no AV1 encoder
    ([gpu-passthrough.md](../../../docs/gpu-passthrough.md) known ceilings)
- Leave **trickplay** off initially — it is the main way `/config` grows.
  `/data` reached 55 % (17/32 GB) right after deploy, so `scsi1` is being grown
  32 → 64 GB (`qm resize` + `resize2fs`, online) for headroom — see below.
- Play something on the TV, then confirm on ciri: `nvidia-smi` shows an
  `ffmpeg` process during a forced transcode, and Dashboard → Playback shows
  "Transcoding (hardware)" rather than software.

### Growing `/data` (scsi1) — online, no downtime

`/data` is the whole disk `/dev/sdb` in ciri (ext4, no partition table), backed
by `scsi1 = silver-guests:vm-150-disk-2`. virtio-scsi grows online, so no
reboot. Thin-provisioned on `silver` (500 GB NVMe, ample free), so this only
reserves what gets written.

```bash
# geralt — grow the virtual disk to 64 GB
qm resize 150 scsi1 64G

# ciri — grow the ext4 filesystem onto the new space (whole-disk, no partition)
sudo resize2fs /dev/sdb
df -h /data                                        # now ~63 GB total
```

`resize2fs` on a mounted ext4 grows online. No `growpart` step — there is no
partition between the disk and the filesystem here.

## Backup story: none, deliberately

This is the **only storage in the lab with no recovery path**, by decision
(2026-07-20): the library is disposable entertainment content, re-obtainable.

- PBS/vzdump backs up ciri's VM disks, so `config/` (the Jellyfin DB, watch
  state, users) **is** covered — losing the media does not lose the setup.
- `/mnt/media` is a host path: vzdump never sees it, and it is deliberately
  **not** added to the restic job in
  [scripts/backup/README.md](../../../scripts/backup/README.md), which exists
  for `steel/photos` — the irreplaceable dataset.
- If the USB disk dies, the library is gone and that is an accepted outcome.
  Do not later assume otherwise because every other dataset is protected.

## Follow-ups

- DNS record `jellyfin.kaermorhen.internal` → `<LAN_PREFIX>.150` on **pihole-1**
  (nebula-sync mirrors to pihole-2; pihole-1 is the only place to edit).
  This one record serves LAN *and* tailnet — the subnet router (LXC 203) plus
  split DNS means no Jellyfin-side remote-access config at all.
- Uptime-Kuma HTTP monitor on `:8096`.
- `docs/docker-vm.md` — stacks table row, and correct the stale `--scsi2`
  media-disk plan to point here.
- `docs/storage.md` — move the USB HDD out of Future work into as-built.
- `steel/media` (ZFS, empty) is now redundant — the USB disk took its role.
  Leave or `zfs destroy` once the disk is proven.
- Consider Beszel `EXTRA_FILESYSTEMS` for `/mnt/media` to watch capacity.
- Optional later: *arr stack writing into `downloads/`, hardlinking into
  `library/`.

## Changes vs a stock Jellyfin compose

- **Image pinned** to `10.11.11` per repo pinning policy.
- **Bridge network + published port**, not `network_mode: host`. Host mode is
  the common upstream recommendation, but it exists for DLNA and client
  auto-discovery (UDP 7359) — neither is used here, since every client is
  pointed at an explicit URL. Bridge keeps the lab's one-network-per-stack
  convention.
- **`NVIDIA_DRIVER_CAPABILITIES: compute,video,utility`** — the toolkit
  default omits `video`, which silently disables NVENC/NVDEC.
- **Media bind is `read_only` with `create_host_path: false`** — see the guard
  note in `compose.yaml`.
- **TZ=Asia/Kolkata**, `container_name`, `restart: unless-stopped` — lab
  conventions.
