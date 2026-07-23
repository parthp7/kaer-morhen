# jellyfin — media server (ciri stack)

[Jellyfin](https://jellyfin.org) on **ciri** (VM 150), live at
`ciri:/data/stacks/jellyfin/`, port **8096**. Pinned at **10.11.11**
(released 2026-06-06).

Hardware transcoding via the GTX 1060 passed through to ciri
([gpu-passthrough.md](../../../docs/gpu-passthrough.md)). Client-side
compatibility — including the sideloaded Samsung TV app, the primary consumer —
is in [jellyfin-clients.md](../../../docs/jellyfin-clients.md).

Deployed and fully configured **2026-07-22**; verified end-to-end: container
healthy on `10.11.11`, media disk (ext4) shared into ciri via `virtiofs1`,
DNS `jellyfin.kaermorhen.internal` → `<LAN_PREFIX>.150` on pihole-1, Kuma HTTP
monitor on `:8096`, `/data` grown to 64 GB, repo mirror in sync. Auto-subtitles
via the OpenSubtitles plugin added 2026-07-23 (see Subtitles). **Playback proven** with a test movie: Direct Play on iPhone
(Swiftfin), MacBook (web), and the Samsung TV; forcing a lower quality drove a
**full hardware NVENC transcode** (CUDA decode → `scale_cuda` → `h264_nvenc`,
exit 0). One gotcha: the TV must connect **by IP**, not the internal hostname —
see Troubleshooting. **Build complete** — Beszel shows the GPU on ciri's view
(power/utilization/memory, verified 2026-07-23); no open items.

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
├── library/                   ← Jellyfin sees only this (read-write, subs)
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

### 6. First run (web UI) — done 2026-07-22

- `http://<LAN_PREFIX>.150:8096` → create the admin account.
- Add libraries: **Movies** → `/media/movies`, **Shows** → `/media/tv`.
- Dashboard → Playback → **Transcoding** — configured and verified in
  `config/encoding.xml`:
  - Hardware acceleration: **NVIDIA NVENC** (`HardwareAccelerationType=nvenc`)
  - Hardware decoding + enhanced NVDEC on, HEVC 10-bit decode on
    (`EnableHardwareEncoding`, `EnableEnhancedNvdecDecoder`,
    `EnableDecodingColorDepth10Hevc` = true)
  - **Tone mapping** on (`EnableTonemapping=true`, bt2390) — makes HDR10 → SDR
    cheap, and the AU7000 needs it for Dolby Vision profile 5 files
  - **AV1 encoding off** (`AllowAv1Encoding=false`) — Pascal has no AV1 encoder
    ([gpu-passthrough.md](../../../docs/gpu-passthrough.md) known ceilings)
- **Trickplay** left off — it is the main way `/config` grows. `/data` reached
  55 % (17/32 GB) right after deploy, so `scsi1` was grown 32 → 64 GB
  (`qm resize` + `resize2fs`, online) on 2026-07-22 for headroom — see below.
- Verify a real transcode: play something on the TV, then on ciri `nvidia-smi`
  shows an `ffmpeg` process and Dashboard → Playback reads "Transcoding
  (hardware)".

### Growing `/data` (scsi1) — online, no downtime (done 2026-07-22, 32 → 64 GB)

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

Verified 2026-07-22: `scsi1 size=64G`, `/data` 63 GB total (28 % used).

`resize2fs` on a mounted ext4 grows online. No `growpart` step — there is no
partition between the disk and the filesystem here.

## Subtitles — auto-fetch via OpenSubtitles (added 2026-07-23)

Jellyfin downloads subtitles automatically; nothing is fetched by hand.

- **Plugin**: Dashboard → Plugins → Catalog → **Open Subtitles** (v24.0.0.0
  installed) → restart. Configured with a free **opensubtitles.com** account
  (the plugin carries its own API key) — the account reports a **20
  downloads/day** cap, ample for a home library.
- **Per library** (Movies, Shows): *Manage* → **Subtitle Downloads** → pick
  download language(s). Fetches on library scan for items missing subs, plus the
  "Download missing subtitles" scheduled task; also on-demand per item or mid-
  playback. Verified 2026-07-23: subtitles download and display in playback.
- **Samsung TV**: downloaded **SRT** Direct Plays as soft subs; **ASS/SSA**
  forces a cheap NVENC burn-in. Embedded subs in `.mkv` rips need no download.

### Why the media bind is read-write (decision, 2026-07-23)

The plugin has `SaveSubtitlesWithMedia=true`, so it writes `.srt` sidecars **next
to each video** — which needs write access to `/media`. Two ways to allow that:

- **A** — keep the bind read-only, set `SaveSubtitlesWithMedia=false` so subs
  land in `/config` (NVMe, PBS-backed).
- **B** — make the `/media` bind read-write; subs sidecar next to the media. **← chosen.**

**Chose B**: subtitles should live and die with the media (a disposable,
re-obtainable, unbacked library), so sidecars on the same disk are the natural
fit and want no PBS coverage. Accepted trade-off: Jellyfin can now write/delete
files on the media disk (delete-from-UI, metadata writes) and writes land as
root via virtiofs — all acceptable for disposable content. The
`create_host_path: false` missing-mount guard is unaffected (it's independent of
read-only). Implemented by dropping `read_only: true` from the `/media` bind.

## Troubleshooting

### Samsung TV: browses fine, playback fails ("media not supported")

Hit 2026-07-22. The Tizen app listed the library and metadata but every play
attempt spun and then errored, on a file (`Inception`, H.264 High/AAC/faststart)
that Direct Plays everywhere else.

- **Diagnosis from the server log**: the TV authenticated and negotiated
  PlaybackInfo (`User policy for "tv"`), but **no `/Videos/.../stream` request
  ever arrived and no ffmpeg spawned** — the TV never fetched a byte. So the
  media was fine; the TV couldn't reach the *stream URL*.
- **Cause**: the app was added as `jellyfin.kaermorhen.internal`. Tizen browses
  via its Chromium web-view (resolves Pi-hole DNS) but plays via native AVPlay,
  a separate network stack that does **not** resolve the internal name.
- **Fix**: set the app's server to `http://<LAN_PREFIX>.150:8096` (IP). Reachable
  remotely too via the Tailscale subnet route. Full write-up in
  [jellyfin-clients.md](../../../docs/jellyfin-clients.md#known-tizen-client-rough-edges).
- **`JELLYFIN_PublishedServerUrl` is now unset** (2026-07-22). It was harmless
  for web/Swiftfin but is exactly what trips a hostname-based native client, so
  it was removed from `compose.yaml` — clients now stream from the address they
  connected on. Connect the TV by IP.

### Confirming a transcode is really on the GPU

Force a low quality in the client, then on ciri `nvidia-smi` shows an `ffmpeg`
process. The server log's ffmpeg command should contain `-hwaccel cuda`,
`scale_cuda`, and `h264_nvenc` (verified 2026-07-22, exit code 0) — that's the
full decode→scale→encode pipeline on the card, not a CPU fallback.

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

- ~~DNS record `jellyfin.kaermorhen.internal` → `<LAN_PREFIX>.150` on
  **pihole-1**~~ done 2026-07-22 (nebula-sync mirrors to pihole-2; pihole-1 is
  the only place to edit). This one record serves LAN *and* tailnet — the subnet
  router (LXC 203) plus split DNS means no Jellyfin-side remote-access config.
- ~~Uptime-Kuma HTTP monitor on `:8096`~~ done 2026-07-22 (added by IP).
- ~~Transcoding settings (NVENC + hardware decode + CUDA tone mapping, AV1
  off)~~ done 2026-07-22.
- ~~End-to-end playback verification~~ done 2026-07-22 — Direct Play on
  iPhone/MacBook/TV + a proven hardware NVENC transcode (see Troubleshooting).
- ~~Grow `/data` for trickplay/library headroom~~ done 2026-07-22 (32 → 64 GB).
- ~~`docs/docker-vm.md` / `docs/storage.md` cross-refs~~ done 2026-07-22.
- ~~Confirm the Beszel GPU panel picks up ciri's agent~~ done 2026-07-23 — GPU
  shows on ciri's view with power/utilization/memory
  ([monitoring.md](../../../docs/monitoring.md)). **Last build item — closed.**

Optional / housekeeping only (no open build work):

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
- **Media bind is read-write** (was `read_only` until 2026-07-23) so the
  OpenSubtitles plugin can save subtitle sidecars next to each video — see
  Subtitles. `create_host_path: false` (the missing-mount guard) is independent
  of rw and stays.
- **`JELLYFIN_PublishedServerUrl` removed** (2026-07-22) — see Troubleshooting.
- **TZ=Asia/Kolkata**, `container_name`, `restart: unless-stopped` — lab
  conventions.
