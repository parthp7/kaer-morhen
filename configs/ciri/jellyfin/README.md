# jellyfin — media server (ciri stack)

[Jellyfin](https://jellyfin.org) on **ciri** (VM 150), live at
`ciri:/data/stacks/jellyfin/`, port **8096**. Pinned at **10.11.11**
(released 2026-06-06).

Hardware transcoding via the GTX 1060 passed through to ciri
([gpu-passthrough.md](../../../docs/gpu-passthrough.md)). Client-side
compatibility — including the sideloaded Samsung TV app, the primary consumer —
is in [jellyfin-clients.md](../../../docs/jellyfin-clients.md).

Deployed and fully configured **2026-07-22**; verified end-to-end: container
healthy on `10.11.11`, media disk (ext4) shared into ciri over **NFSv4.2**
(was `virtiofs1` until 2026-08-23 — see [proposal 005](../../../docs/proposals/005-nfs-media-share.md)),
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
| media library | **external USB HDD on geralt**, ext4, `/mnt/media`, into the VM over **NFSv4.2** at `/mnt/media` | bulk sequential video; must not sit in a VM disk or inflate PBS |
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

### Mount method: NFSv4.2 (was virtiofs until 2026-08-23)

Two decisions stacked here. Both still hold, but the second one was replaced.

**Against raw `--scsi2` passthrough.** [docker-vm.md](../../../docs/docker-vm.md)
originally planned the media disk as a raw `--scsi2` passthrough with
`backup=0`. That plan predates ciri having either a host share or the GPU:

- Its main advantage was preserving live migration / hibernate / RAM snapshots.
  **Those are already gone** — `virtiofs0` (photos) and `hostpci0` (GPU) each
  independently disqualify ciri. Passthrough would be defending nothing.
- A host share keeps **geralt's own read/write access** to the media while ciri
  runs: bulk-loading over the network, and any future stack wanting the library.
- A USB disk **will** re-enumerate eventually. geralt recovering an ext4 mount
  is a well-understood failure; a block device yanked from under a running
  guest's filesystem is how you corrupt one.
- `backup=0` becomes moot — a host path is never a VM disk, so vzdump never
  sees it. Same property that keeps `/mnt/photos` out of PBS.

**virtiofs → NFS, 2026-08-23** ([proposal 005](../../../docs/proposals/005-nfs-media-share.md)).
virtiofs was the original share transport and it failed structurally, three
times: virtiofsd **pins the inode it was started against**, so when the USB disk
re-enumerated on geralt, ciri kept being served the empty pre-mount placeholder
on the boot disk rather than the real filesystem — silently, with no error
anywhere. That caused the 2026-07-27 wrong-filesystem incident and the 08-10
twelve-day silent outage. NFS has no equivalent failure: the export follows the
mount on the server, and a client that cannot reach it gets a hard error instead
of plausible-looking wrong data.

As built:

- Server `geralt`, client `ciri`, over a **dedicated storage bridge** (same
  last-octet convention as the LAN: geralt `<STORAGE_PREFIX>.21`, ciri
  `<STORAGE_PREFIX>.150`), so bulk media traffic stays off the LAN.
- Export `rw,all_squash,anonuid=13000,anongid=13000` — every write lands as
  `jaskier` (13000) on disk regardless of the client-side uid.
- Mount `vers=4.2,hard,x-systemd.automount,_netdev,nofail`. `hard` means a
  server outage blocks rather than returning short reads; `x-systemd.automount`
  means `/mnt/media` exists as a trigger whether or not geralt is serving, which
  is precisely why the containers need the missing-mount guards below.
- `virtiofs0` (photos) is **untouched and still virtiofs** — explicitly out of
  scope for 005.

Cost: somewhat lower throughput than raw passthrough. Irrelevant at video
bitrates the 1060 can transcode.

### On-disk layout

Laid out for a future *arr stack (Sonarr/Radarr/qBittorrent) even though none
is deployed: `downloads/` and `library/` share one filesystem, so imports can
**hardlink** instead of copying — no double disk usage, no long copy on import.
Costs nothing if the *arr stack never happens.

```
/mnt/media/                    (geralt, ext4, USB)
├── library/                   ← Jellyfin sees only this (read-only)
│   ├── movies/
│   └── tv/
└── downloads/                 ← qBittorrent writes here; *arr hardlink into library/
```

The `servarr` stack ([configs/ciri/servarr](../servarr)) now fills this tree — writers run
as the dedicated non-root account `jaskier` (13000); Jellyfin and Audiobookshelf are read-only.

### The disk, as-built (Seagate BUP Slim, 932 GiB)

Two things surfaced plugging it in (2026-07-21), both worth knowing for a
re-seat or replacement:

- **Its link speed is nondeterministic, and it drops occasionally.**
  *(Rewritten 2026-07-29 — the original note here was wrong.)* It first came up
  `high-speed` on 2026-07-21 after a SuperSpeed attempt dropped within the same
  second, and that was recorded as "enumerates reliably only at USB 2.0, moved to
  a working port." Neither half held up: **every USB port on geralt is 3.0**, the
  drive was never moved between ports (it was replugged into the same one), and
  it has linked at **SuperSpeed (5 Gbps) since 2026-07-22 00:32**. What varies is
  the bridge's negotiation on each replug.
  It then ran 4.5 days and dropped off the bus on **2026-07-26 23:31** mid-read,
  which is what set off the
  [wrong-filesystem incident](../../../docs/storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem).
  A kernel-cmdline UAS quirk was tried on 07-28 to stabilise the bridge and
  **reverted** — it caused intermittent boot hangs (see that incident's
  postscript). **Accepted position**: the bridge is not mitigated at the hardware
  or driver level. The drive is disposable, and the mount guards and hookscript
  make a drop a bounded outcome — media containers stay down — rather than a
  silent corruption. Throughput is now bounded by the 5400 rpm mechanism rather
  than a USB-2.0 ceiling; it has not been re-measured since the link changed.
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

### 2 & 3. ~~geralt — share into ciri via virtiofs~~ / ~~ciri — mount the share~~ — SUPERSEDED 2026-08-23

> ⚠️ **These two steps are a historical record of the 2026-07-22 build, not a
> procedure to follow.** The media share moved from virtiofs to **NFSv4.2** on
> 2026-08-23 ([proposal 005](../../../docs/proposals/005-nfs-media-share.md));
> the `virtiofs1` mapping is gone. To rebuild this share, follow proposal 005's
> runbook, not what is below. Kept because the 2026-07-27 and 08-10 incidents
> referenced further down only make sense against it.

<details>
<summary>Original virtiofs steps (2026-07-22)</summary>

`virtiofs0` was taken by `photos`, so media was **`virtiofs1`**:

```bash
pvesh create /cluster/mapping/dir --id media --map node=geralt,path=/mnt/media

# virtiofs is NOT hot-pluggable — the change stays "pending" until a cold
# restart; a guest-internal reboot is not enough.
qm set 150 --virtiofs1 dirid=media
qm shutdown 150 && qm start 150
qm config 150 | grep virtiofs                      # virtiofs0: photos, virtiofs1: media
```

Then on ciri, mount tag = the mapping id (`media`):

```bash
sudo mkdir -p /mnt/media
echo 'media /mnt/media virtiofs defaults,nofail 0 0' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/media
findmnt /mnt/media                                 # FSTYPE virtiofs
ls /mnt/media                                      # library  downloads
```

</details>

**Current state**, for verification rather than construction:

```bash
findmnt -no SOURCE,FSTYPE /mnt/media
# <STORAGE_PREFIX>.21:/mnt/media  nfs4     (behind an x-systemd.automount trigger)
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
USB disk is down or geralt is not serving the NFS export. Fix the mount, don't
remove the guard. Since 005 the guard matters *more*, not less: `/mnt/media` is
an `x-systemd.automount` trigger that exists as a path whether or not geralt is
serving, so the only thing distinguishing "share is up" from "share is gone" is
whether `/mnt/media/library` resolves.

**This is not hypothetical — it fired for real on 2026-07-27** (`exit 127`,
`failed to fulfil mount request: open /mnt/media/library: no such file or
directory`) and was the *only* thing that stopped a media app running against
geralt's boot disk that day. It also protected Jellyfin's database from being
emptied by a scan of a non-existent library. The servarr stack, which lacked an
equivalent guard at the time, was not so lucky. Full write-up:
[storage.md](../../../docs/storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem).

Note the guard only proves the path **exists**. Proving it is the *right*
filesystem is the job of the `ciri media mount` Push monitor
([uptime-kuma.md](../../../docs/uptime-kuma.md)) — existence alone did not
discriminate once Docker auto-created a `downloads/` directory on the placeholder.

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

### Media bind: read-write → read-only (2026-07-23 → 2026-07-24)

Briefly (2026-07-23) the `/media` bind was **read-write** so the OpenSubtitles plugin
(`SaveSubtitlesWithMedia=true`) could sidecar `.srt` files next to each video. That was the
only root-write path onto the media disk — Jellyfin runs as root, and the disk is now
shared with the `servarr` download stack.

**Reverted to read-only (2026-07-24)** when the `servarr` stack landed: **Bazarr** (running
as the dedicated non-root account `jaskier`, uid 13000) now writes subtitle sidecars, so Jellyfin
no longer needs write access. This restores least privilege — Jellyfin can read the library
but, root process or not, physically cannot modify or delete media. Sidecars still live on
the media disk (written by Bazarr), so the "subs live and die with the disposable library"
property is kept; only the writer changed.

**Operational note:** turn OFF the OpenSubtitles plugin's "save alongside media" (or disable
the plugin) so Jellyfin doesn't attempt writes to the now read-only bind — Bazarr is the
single subtitle writer. The `create_host_path: false` missing-mount guard is independent of
read-only and stays. Implemented by re-adding `read_only: true` to the `/media` bind.

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

### All transcodes fail after a systemd daemon-reload (2026-08-01)

**Symptom.** Direct Play works everywhere, but anything that needs a transcode
fails instantly. On the Samsung TV this surfaces as "media is not supported by
this client" — which is why it gets mistaken for a codec problem. The tell that
it is *not* a codec problem: the failure follows the **transcode**, not the
file. A file that Direct Plays at Auto quality starts failing the moment you
lower the client's bitrate cap below its bitrate.

**Diagnosis.**

```bash
nvidia-smi                       # on ciri: GPU healthy, idle
docker exec jellyfin nvidia-smi  # in the container: "Failed to initialize NVML: Unknown Error"
```

The ffmpeg log (`config/log/FFmpeg.Transcode-*.log`) is unambiguous:

```
[AVHWDeviceContext] cu->cuInit(0) failed -> CUDA_ERROR_NO_DEVICE: no CUDA-capable device is detected
Device creation failed: -542398533.
```

→ `FFmpeg exited with code 187`, retried dozens of times per playback attempt
(each retry writes its own `FFmpeg.Transcode-*.log`, so **a burst of identical
transcode logs seconds apart is itself the signature**).

Note `ls -la /dev/ | grep nvidia` **still lists the device nodes inside the
container** — this is not a missing-device problem, it is a *permissions*
problem. The nodes are visible; every open is denied.

**Cause — mechanism confirmed, trigger NOT.** What is certain: the container's
cgroup **device allowlist** lost its NVIDIA entries while the container kept
running. The nodes stayed bind-mounted (hence visible to `ls`) but every open
was denied. Recreating the container re-ran the injection and fixed it.

What triggered that is **unresolved**. The original write-up blamed a
`systemctl daemon-reload`, on this timeline:

```
2026-07-31 15:08:46  jellyfin started (post-reboot)
2026-07-31 15:45:27  systemd[1]: Reload requested from client PID 64172 ('systemctl')
2026-07-31 17:07:01  ollama started       ← shares the GPU, never broke
```

The reasoning was that ciri runs `Cgroup Driver: systemd` on `Cgroup Version: 2`,
where systemd owns the device rules and rewrites them on reload, dropping
entries the toolkit's prestart hook had poked in out-of-band
([nvidia-container-toolkit#48](https://github.com/NVIDIA/nvidia-container-toolkit/issues/48)).
ollama surviving fit neatly — it started *after* the reload.

**That hypothesis was falsified on 2026-08-02.** With jellyfin recreated and
still on the legacy path, `systemctl daemon-reload` was run three times
(08:54–08:55) and `docker exec jellyfin nvidia-smi` kept working. On this stack
— Docker 29.6.1, containerd 2.2.6, toolkit 1.19.1 — a plain daemon-reload does
**not** reproduce it. A boot-ordering race was considered next and also looks
weak: the driver was fully up well before Docker (`nvidia_uvm` loaded 15:08:41,
persistenced registered the device 15:08:43, containerd 15:08:44, container
15:08:46).

So: **treat a `daemon-reload` near a GPU container as suspicious, but do not
trust it as the explanation.** The diagnosis and the fix above are solid
regardless of trigger; only the attribution is open. If this recurs, capture
`docker inspect` and the container's cgroup device rules *before* recreating —
recreating destroys the evidence, which is why this incident cannot be closed.

The one thing the timeline does still establish is what it **rules out**: ollama
shared the same GPU throughout and never lost access, which excludes the card,
the driver, and VRAM contention (see below).

**Immediate fix** — restarting re-runs the toolkit hook and re-injects the
device rules:

```bash
cd /data/stacks/jellyfin && docker compose up -d --force-recreate jellyfin
docker exec jellyfin nvidia-smi        # must show the GTX 1060
```

Then play something that forces a transcode and confirm Dashboard → Playback
reads "Transcoding (hardware)".

**Permanent fix** — see [Making GPU access survive
daemon-reload](#making-gpu-access-survive-daemon-reload) below. Until that is
applied, the operational rule is: **any `systemctl daemon-reload` on ciri means
restart every GPU container** (`jellyfin`, `ollama`).

**Monitoring gap this exposed.** Beszel watches the GPU from the *host*, where
it looked perfectly healthy for the 21 hours the transcoder was dead. Nothing
watched whether the *container* could still reach it. A Kuma push check running
`docker exec jellyfin nvidia-smi` would catch this same-day.

### Is it the daemon-reload, or VRAM contention with ollama?

The 1060's 6 GB is shared with the `ai` stack, so "Jellyfin can't transcode" now
has two plausible causes and they are **easy to tell apart** — read the ffmpeg
log, not the symptom:

| | daemon-reload / cgroup loss | VRAM contention with ollama |
|---|---|---|
| ffmpeg error | `cuInit(0) failed -> CUDA_ERROR_NO_DEVICE` — fails *before* any allocation | out-of-memory / `OpenEncodeSessionEx failed` — fails *after* CUDA init succeeds |
| `docker exec jellyfin nvidia-smi` | fails (NVML Unknown Error) | **succeeds**, and shows the VRAM already consumed |
| Depends on GPU load? | no — fails with the GPU completely idle | yes — only while a model is resident |
| Fix | recreate the container | `docker exec ollama ollama stop <model>`, or wait out `OLLAMA_KEEP_ALIVE` |

The 2026-08-01 incident was the **left** column: the GPU was reading
`0 MiB / 6144 MiB` with no processes and no model loaded (`ollama ps` empty) at
the moment `nvidia-smi` was failing inside the container. Sharing the GPU did
not cause it.

Contention is nonetheless a **real** future risk, already anticipated in the
`ai` stack's compose comments: `qwen3:8b` is ~5 G of weights and even the MoE
`qwen3:30b-a3b` pins ~4.3 G of VRAM for its offloaded layers, against a 6 G
card that also needs a few hundred MB per NVENC session plus decode surfaces.
`OLLAMA_KEEP_ALIVE=10m` and `OLLAMA_MAX_LOADED_MODELS=1` exist to bound it. If
transcodes start failing *only* right after someone has been chatting, it is
the right-hand column.

### Making GPU access survive daemon-reload

Background, because the mechanism is the whole point:

A container's access to `/dev/nvidia*` is enforced by a **cgroup v2 device
allowlist**. Who *owns* that allowlist depends on Docker's cgroup driver:

- **`systemd` driver** (ciri's current setting): each container gets a systemd
  *scope* unit, and systemd owns the device rules. It considers its own unit
  files the source of truth, so on `systemctl daemon-reload` it **rewrites the
  scope's rules from what it knows**.
- **`cgroupfs` driver**: Docker writes the cgroup files directly and systemd
  never reconciles them.

The legacy nvidia path (`deploy.resources.reservations.devices` /
`NVIDIA_VISIBLE_DEVICES`) works via a **prestart hook** that pokes the device
rules in *after* the container is created — out-of-band, so systemd has no
record of them. Come the next `daemon-reload`, systemd rewrites the allowlist
without them and the GPU silently vanishes from the running container. The
device *nodes* stay bind-mounted and visible, which is why the failure looks so
confusing: `ls /dev` shows the GPU, `cuInit()` says there is no GPU.

There are two ways out. **Option A is what this lab does** (applied 2026-08-02).

Note the honest framing: because the 2026-08-01 trigger was never confirmed,
CDI is **hardening, not a proven fix for a proven cause**. It is worth doing on
its own merits — it removes the entire out-of-band-hook failure class, and the
legacy hook path is the one NVIDIA is moving away from — but if the symptom
recurs under CDI, that is informative rather than impossible, and the incident
notes above should be revisited.

#### Option A — migrate to CDI (adopted 2026-08-02)

The Container Device Interface injects the devices into the **OCI spec before
the container is created**, so the rules are part of the container's persisted
config. Docker and systemd both know about them, and a `daemon-reload`
reconciles *to* them instead of over them. Immune by construction.

Everything needed is already in place on ciri — no daemon.json change, no
package install:

```bash
docker info | grep -A3 "CDI spec directories"   # → Discovered Devices: nvidia.com/gpu=all
systemctl is-enabled nvidia-cdi-refresh.path    # → enabled
```

`nvidia-cdi-refresh.path`/`.service` (shipped with the driver packages)
regenerate the spec automatically whenever the driver changes, so it needs no
manual upkeep.

> **Superseded 2026-08-04 — the spec no longer lives in `/var/run/cdi`.**
> As shipped it is written to `/var/run/cdi/nvidia.yaml`, which is **tmpfs and
> wiped every boot**, and `nvidia-cdi-refresh.service` has no
> `Before=docker.service` — so dockerd and the refresh race on every single
> boot. When dockerd won, both GPU containers died with
> `unresolvable CDI devices` while every other container came up fine. The spec
> was moved to the persistent `/etc/cdi/nvidia.yaml` and Docker ordered after
> the refresh. Full RCA and the fix:
> [gpu-passthrough.md](../../../docs/gpu-passthrough.md). Read that before
> re-deriving any of this — **`/etc/cdi/nvidia.yaml` is the live path**.

The change is compose-side — replace the whole `deploy:` block:

```yaml
    # REMOVE:
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]

    # ADD:
    devices:
      - "nvidia.com/gpu=all"
```

**`NVIDIA_DRIVER_CAPABILITIES` and `NVIDIA_VISIBLE_DEVICES` were removed at the
same time.** They are load-bearing under the legacy path — the toolkit default
omits `video`, which silently disables NVENC/NVDEC — but **CDI ignores them
entirely**. Checked before removing, rather than assumed: the generated spec
carries the encode/decode libraries unconditionally.

```bash
grep -oE "lib(nvidia-encode|nvcuvid)[^ \"]*" /etc/cdi/nvidia.yaml | sort -u
# → libnvidia-encode.so.1, libnvidia-encode.so.580.173.02,
#   libnvcuvid.so.1, libnvcuvid.so.580.173.02
```

If this is ever reverted to the legacy block, **both variables must come back**
or hardware transcoding breaks in a way that still lets `nvidia-smi` succeed.

Apply to both GPU stacks — they share the card and had identical wiring:

```bash
cd /data/stacks/jellyfin && docker compose up -d --force-recreate jellyfin
cd /data/stacks/ai       && docker compose up -d --force-recreate ollama

# devices are now in the OCI spec, not poked in by a hook
docker inspect jellyfin --format '{{json .HostConfig.DeviceRequests}}'
#   → [{"Driver":"cdi","Count":0,"DeviceIDs":["nvidia.com/gpu=all"],...}]
# NOT null. (Corrected 2026-08-24: this line said "→ null" from 2026-08-02 until
# then, contradicting the Follow-ups entry below, which was right. Verified live on
# both jellyfin and ollama. It is `.HostConfig.Devices` that is null under CDI —
# the CDI request lands in DeviceRequests. The error mattered: this is the
# verification block for the CDI migration, so anyone checking against it would see
# a populated value and conclude a working GPU setup had failed.)
docker exec jellyfin nvidia-smi
docker exec ollama   nvidia-smi

# regression test
sudo systemctl daemon-reload
docker exec jellyfin nvidia-smi                 # must still work
```

Then prove NVENC specifically — `nvidia-smi` succeeding does **not** prove the
encoder is reachable, which is exactly the trap the removed
`NVIDIA_DRIVER_CAPABILITIES` used to guard:

```bash
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -encoders \
  | grep nvenc
```

Finally force a real transcode from a client and confirm Dashboard → Playback
reads "Transcoding (hardware)".

**As-built result (2026-08-02)** — South Park S01E08 (AV1 10-bit / Opus / PGS,
the worst case in the library) played from the Samsung TV:

```
-i "/media/tv/South Park/South.Park.S01E08...AV1.Opus.AV1D.mkv"
libdav1d          ← AV1 decode in SOFTWARE (Pascal has no AV1 NVDEC)
h264_nvenc        ← encode on the GPU
frame=18718 fps=243 ... speed=10.1x     (clean exit — final Lsize line, no cuInit error)
```

**10.1x realtime** with PGS burn-in; **14.4x** (`fps=349`) on the same episode
with subtitles off. The split pipeline — software AV1 decode, hardware H.264
encode — is comfortable on ciri's 6 vCPUs, so the earlier worry that AV1 would
be a CPU problem is settled: it is not, at least at 1080p animation bitrates.

Note this is the *steady state* for South Park S1, not a one-off: the TV cannot
Direct Play that AV1 stream even with subtitles off
([tested 2026-08-02](../../../docs/jellyfin-clients.md#av1-the-row-said-yes-the-tv-says-no-tested-2026-08-02)),
so those episodes always transcode.

#### Option B — switch Docker to the cgroupfs driver

The widely-cited workaround. It doesn't fix the out-of-band hook; it removes
systemd from the loop so nothing reconciles the rules away. Prefer Option A —
keep this as the fallback if CDI ever misbehaves.

```bash
# 1. Back up first — this file also carries data-root and log settings.
sudo cp /etc/docker/daemon.json /etc/docker/daemon.json.bak

# 2. Add the exec-opts key (merge into the existing JSON, don't overwrite it):
sudo nano /etc/docker/daemon.json
```

```json
{
    "data-root": "/data/docker",
    "log-driver": "local",
    "log-opts": { "max-file": "5", "max-size": "100m" },
    "exec-opts": ["native.cgroupdriver=cgroupfs"],
    "runtimes": {
        "nvidia": { "args": [], "path": "nvidia-container-runtime" }
    }
}
```

```bash
# 3. Validate the JSON before restarting — a syntax error here means dockerd
#    will not come back up, taking all ~26 containers with it.
python3 -m json.tool /etc/docker/daemon.json

# 4. Restart the daemon. THIS RESTARTS EVERY CONTAINER ON ciri — schedule it.
sudo systemctl restart docker

# 5. Verify
docker info | grep -i "cgroup driver"           # → cgroupfs
docker exec jellyfin nvidia-smi
sudo systemctl daemon-reload && docker exec jellyfin nvidia-smi   # still works
```

Trade-off: two writers (systemd and Docker) now touch the cgroup tree. That is
a genuine downside and is why systemd is the upstream default — but on a
single-node Docker host with no Kubernetes it is a well-trodden configuration.
Roll back by restoring `daemon.json.bak` and restarting Docker.

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

Reopened 2026-08-01 by the GPU-loss incident (see Troubleshooting):

- ~~**Migrate `jellyfin` and `ollama` to CDI device syntax**~~ **done and
  verified 2026-08-02** ([Option A](#option-a--migrate-to-cdi-adopted-2026-08-02)).
  Both containers now report
  `DeviceRequests: [{"Driver":"cdi","DeviceIDs":["nvidia.com/gpu=all"]}]`,
  `nvidia-smi` works in both, `h264_nvenc`/`hevc_nvenc`/`av1_nvenc` are present,
  and a real South Park S1 transcode ran to completion — see below.
- [ ] **Root cause of the 2026-08-01 GPU loss remains UNKNOWN** — the
  daemon-reload theory was falsified 2026-08-02 (see Troubleshooting). If it
  recurs, capture `docker inspect` and the cgroup device rules *before*
  recreating the container.
- ~~**Kuma check for GPU-in-container**~~ **deployed and verified 2026-08-05** —
  [`gpu-health.sh`](../../../scripts/monitoring/README.md#gpu-healthsh), a Push
  monitor that runs a real NVENC encode inside the container rather than just
  `nvidia-smi` (the two can disagree). Timer active, strikes at 0, monitor green.
  The 21-hour blind spot is closed.
- ~~**Settle the AU7000 AV1 question**~~ **tested 2026-08-02: the TV does NOT
  Direct Play AV1 Main 10-bit.** With subtitles off (no `overlay` filter in the
  command) it still re-encoded video via `h264_nvenc`, so the matrix row that
  claimed AV1 support was wrong — corrected in
  [jellyfin-clients.md](../../../docs/jellyfin-clients.md#av1-the-row-said-yes-the-tv-says-no-tested-2026-08-02).
  Practical impact: every South Park S1 episode is a permanent transcode, which
  is fine — 14.4x realtime.

Optional / housekeeping only (no open build work):

- ~~`steel/media` (ZFS) redundant — leave or destroy~~ destroyed 2026-07-23
  (the USB disk took its role).
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
- **GPU via CDI** (`devices: ["nvidia.com/gpu=all"]`), not the usual
  `deploy.resources.reservations.devices` block — see
  [Option A](#option-a--migrate-to-cdi-adopted-2026-08-02). This also drops
  `NVIDIA_DRIVER_CAPABILITIES: compute,video,utility`, which *was* required
  under the legacy path (the toolkit default omits `video`, silently disabling
  NVENC/NVDEC) but is inert under CDI.
- **Media bind is read-only** — Jellyfin runs as root, so read-only is what keeps
  it from being able to write/delete on the shared media disk. (It was briefly rw
  2026-07-23 for OpenSubtitles sidecars; Bazarr now writes subs — see Subtitles.)
  `create_host_path: false` (the missing-mount guard) is independent and stays.
- **`JELLYFIN_PublishedServerUrl` removed** (2026-07-22) — see Troubleshooting.
- **TZ=Asia/Kolkata**, `container_name`, `restart: unless-stopped` — lab
  conventions.
