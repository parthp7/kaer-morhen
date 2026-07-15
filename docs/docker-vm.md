# Docker VM — ciri

As-built runbook for VM **150 (`ciri`)** on geralt, implemented 2026-07-11.
The application-hosting VM from [Proposal 001 §3](proposals/001-initial-infrastructure-plan.md):
all consumer-facing compose stacks (sure, memos, paperless-ngx, Jellyfin, …)
live here. Base VM + Docker only — app stacks are follow-up work.

**Naming**: per [network.md](network.md)'s convention — functional names
for LXCs, lore names for VMs and PVE nodes. This VM is `ciri` — the person
the saga is actually about, running on `geralt`, her guardian. VM name =
guest hostname = login user = `ciri`.

## Architecture

| Piece | Value |
|---|---|
| VM | **150** on **geralt**, `.150`, name/hostname/user `ciri` |
| OS | Ubuntu Server **26.04 LTS** (Resolute) cloud image, cloud-init provisioned |
| Machine | **q35 + OVMF**, Secure Boot off (`pre-enrolled-keys=0`) — GPU passthrough later is a `qm set --hostpci0`, not a rebuild; no MOK dance for future NVIDIA DKMS |
| Resources | 6 vCPU (`cpu: host`), **8192 MB fixed** (`balloon: 0`) |
| Disks | **scsi0 64 G = OS**; **scsi1 32 G = `/data`** (Docker + app data) — both sparse zvols on `silver-guests`, `discard=on,iothread=1,ssd=1`, virtio-scsi-single; see "Storage layout" |
| Docker config | `data-root: /data/docker`; `local` log driver capped **100 MB × 5 files per container** (`/etc/docker/daemon.json`); containerd `root = /data/containerd` (`/etc/containerd/config.toml`) — image layers live *there*, not in data-root (containerd image store, see gotchas) |
| Network | virtio on `vmbr0`, static `<LAN_PREFIX>.150/24` via cloud-init, DNS `.101`/`.201` (the Pi-holes), search `kaermorhen.internal` (renamed from `….home.arpa` 2026-07-12 — see [dns.md](dns.md) gotchas) |
| Login | user `ciri`, SSH-key only (keys inherited from geralt's `/root/.ssh/authorized_keys`); no password unless set via `sudo passwd ciri` |
| Docker | Engine 29.6.1 + Compose v5.3.1 from Docker's official apt repo; `ciri` in the `docker` group |
| Monitoring | Beszel agent (binary, `beszel-agent.service`) → hub on `.204`; per-container Docker stats on the same dashboard. **Auto-update timer disabled** (house policy) |
| Backups | picked up automatically by geralt's nightly 04:00 `--all 1` PBS job; `qemu-guest-agent` gives `fs-freeze` consistent snapshots |
| GPU | **deferred** — iGPU (QuickSync) vs GTX 1060 decided when Jellyfin lands; i7-8750H software-transcodes 1080p meanwhile |

**Memory sizing**: geralt budget is 16 G − 2 G ARC cap − ~2 G host/LXCs → 8 G
fixed leaves ~3–4 G headroom. Unlike LXC caps, VM memory is reserved while the
VM runs. `balloon: 0` disables dynamic reclaim (databases + page cache hate
it; the host isn't overcommitted; VFIO pins memory anyway once a GPU is passed
through) — note it also removes the memory-stats device, so PVE's UI shows
QEMU process size, not guest-actual; true usage comes from the Beszel agent
inside the guest. `qm set 150 --delete balloon` would restore the stats device
while keeping memory fixed.

## Storage layout (two-disk split, implemented 2026-07-11)

| Disk | Size | Holds | Why separate |
|---|---|---|---|
| scsi0 → `/` | 64 G | OS only | a full data disk stops containers but leaves SSH, the OS, and monitoring alive |
| scsi1 → `/data` | 32 G | `/data/docker` (Docker data-root: volumes, container state, logs) + `/data/containerd` (image layers & content) + `/data/stacks` (compose files & bind mounts, owned by `ciri`) | independent online growth; per-disk vzdump policy |
| virtiofs0 → `/mnt/photos` | — | geralt's `steel/photos` dataset (Immich originals), dir mapping `photos`, added 2026-07-14 | host dataset stays in the future photos backup path, outside PBS/vzdump; costs the VM live migration + `--vmstate` snapshots (disk-only snapshots and PBS backups verified fine) |

Design decisions behind the split (evaluated 2026-07-11):

- **Runaway logs are fixed by caps, not partitions** — a dedicated log
  partition without caps still fills (and breaks logging for every container);
  with caps it's redundant. `daemon.json` caps each container at
  100 MB × 5 files (`local` driver, rotated files compressed). Caveat: that's
  a **size** guarantee, not a **time** one — a crash-looping app can churn
  through its 500 MB in hours. Verify the window empirically once apps run
  (`docker logs --since 336h <ct> | head -1`) and raise a chatty app's
  `logging:` block in its compose file if needed. Hard time-window retention =
  log shipping (Loki), parked per Proposal 001 §5.
- **Two disks, not five partitions.** Fine-grained purpose-sized partitions
  cause the outages they're meant to prevent (premature ENOSPC in one silo,
  unshrinkable free space in another). One coarse OS/data boundary captures
  the blast-radius and backup-granularity value with one moving part.
- **The host was never at risk** — zvols are hard-capped, so a full VM
  filesystem is contained by virtualization anyway. The split protects ciri's
  OS from ciri's apps, nothing more.
- **Root stays 64 G even though the OS needs ~8 G** (evaluated 2026-07-12):
  the zvol is sparse, so the pool is charged for written blocks (~2.6 G), not
  the cap — `discard` + weekly fstrim return deletions, and PBS backs up used
  blocks only. Shrinking would be rescue-media surgery (PVE can't shrink
  disks; ext4 root shrink is offline-only) for a purely cosmetic gain, and a
  reinstall buys the same nothing at higher cost.
- **Sizing**: caps on sparse zvols, not allocations. Growing is online and
  trivial (`qm disk resize` + `resize2fs`); shrinking is effectively
  impossible — grow on evidence. Bulk media never goes here: it later arrives
  as **`--scsi2`** backed by steel/USB with **`backup=0`**, so replaceable
  terabytes never inflate the nightly PBS job protecting the irreplaceable
  app data on scsi0+scsi1 (both backed up by default).

## Runbook (as executed)

### 1. Create the VM (geralt)

```bash
cd /tmp && wget https://cloud-images.ubuntu.com/releases/resolute/release/ubuntu-26.04-server-cloudimg-amd64.img

qm create 150 --name ciri --ostype l26 \
  --machine q35 --bios ovmf --efidisk0 silver-guests:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --cores 6 --memory 8192 --balloon 0 \
  --scsihw virtio-scsi-single \
  --net0 virtio,bridge=vmbr0 \
  --serial0 socket --vga serial0 \
  --agent enabled=1,fstrim_cloned_disks=1 \
  --onboot 1

qm importdisk 150 ubuntu-26.04-server-cloudimg-amd64.img silver-guests
qm set 150 --scsi0 silver-guests:vm-150-disk-1,discard=on,iothread=1,ssd=1
qm disk resize 150 scsi0 64G
```

- The EFI vars disk takes `vm-150-disk-0`, so the imported image lands as
  `vm-150-disk-1` — check `qm config 150` before the `--scsi0` attach.
- `--serial0 socket --vga serial0`: cloud images put their console on serial;
  without this the console is a blank VGA screen.
- Resize is absolute (`64G`), not relative; cloud-init's `growpart` expands
  the filesystem into it on boot.

### 2. Cloud-init — complete this BEFORE the first `qm start` (see gotchas)

```bash
qm set 150 --ide2 silver-guests:cloudinit --boot order=scsi0
qm set 150 --ciuser ciri --sshkeys /root/.ssh/authorized_keys \
  --ipconfig0 ip=<LAN_PREFIX>.150/24,gw=<LAN_PREFIX>.1 \
  --nameserver "<LAN_PREFIX>.101 <LAN_PREFIX>.201" \
  --searchdomain kaermorhen.internal
qm start 150
```

First boot runs a cloud-init package upgrade — allow a couple of minutes,
then `ssh ciri@<LAN_PREFIX>.150` (key-only; reusing geralt root's
`authorized_keys` keeps one trust boundary: whatever key reaches geralt
reaches ciri).

### 3. Inside the VM — guest agent + Docker

```bash
sudo apt update && sudo apt install -y qemu-guest-agent
sudo systemctl enable --now qemu-guest-agent
```

Docker from the official repo (per
[docs.docker.com](https://docs.docker.com/engine/install/ubuntu/) — supports
26.04 "resolute"):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update && sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker ciri    # re-login to take effect
docker run --rm hello-world
```

### 4. Monitoring wiring

- **Beszel**: hub UI (`http://<LAN_PREFIX>.204:8090`) → Add System `ciri`,
  host `<LAN_PREFIX>.150` → run the generated agent install command in the VM.
  **Decline the script's auto-update prompt** (house policy: the stack updates
  when we choose). Per-container Docker stats appear on the dashboard.
- **Uptime-Kuma** (`http://<LAN_PREFIX>.104:3001`): Ping monitor for `.150` —
  Kuma shares the node, but a VM crash isn't a node crash.

### 5. Data disk + Docker relocation + log caps (2026-07-11)

Done while Docker was still empty (hello-world only) — so a fresh `data-root`,
no migration.

```bash
# geralt — new 32 G sparse zvol, hot-plugged (no VM reboot needed)
qm set 150 --scsi1 silver-guests:32,discard=on,iothread=1,ssd=1
```

```bash
# ciri — verify the new disk is sdb (32G, bare) BEFORE mkfs
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS,MODEL
sudo mkfs.ext4 -L data /dev/sdb   # deliberately no partition table: future
                                  # grow = qm disk resize + resize2fs, no growpart

sudo mkdir /data
echo 'LABEL=data /data ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount -a
# LABEL survives device renames; nofail = a dead data disk degrades boot
# instead of dropping to emergency mode and killing SSH

sudo mkdir -p /data/docker /data/stacks
sudo chown ciri: /data/stacks
```

```bash
# ciri — relocate Docker + cap logs (stop BOTH units, see gotchas)
sudo systemctl stop docker.service docker.socket
sudo tee /etc/docker/daemon.json <<'EOF'
{
  "data-root": "/data/docker",
  "log-driver": "local",
  "log-opts": { "max-size": "100m", "max-file": "5" }
}
EOF
sudo systemctl start docker.socket docker.service
docker info --format 'root: {{.DockerRootDir}} | logging: {{.LoggingDriver}}'
docker run --rm hello-world
sudo rm -rf /var/lib/docker      # only after the verify above

# Beszel: agents watch / only — add the new fs, then confirm on the hub
sudo systemctl edit beszel-agent   # [Service] Environment="EXTRA_FILESYSTEMS=/data"
sudo systemctl restart beszel-agent

sudo reboot   # prove fstab + docker come back — never skip this
```

```bash
# ciri — move containerd's root too (2026-07-12): on modern Docker the image
# store is containerd's, so data-root alone leaves image layers on the root disk
sudo systemctl stop docker.service docker.socket containerd
# /etc/containerd/config.toml — add top-level line:
#   root = "/data/containerd"
sudo systemctl start containerd docker.socket docker.service
docker run --rm hello-world      # repulls; layers land in /data/containerd
sudo rm -rf /var/lib/containerd  # abandoned pre-move remnant
```

## Gotchas hit (and the fixes)

- **VM booted on a DHCP address (`.34`), not `.150`; SSH to `.150` timed out.**
  The first `qm start` happened before the cloud-init settings were complete,
  so the image defaulted to DHCP. Cloud-init config must be finished **before
  first boot**; to recover, finish the config and do a full
  **`qm stop 150 && qm start 150`** — PVE only regenerates the cloud-init ISO
  on a fresh start, so a guest-internal reboot won't pick it up. (The stale
  DHCP lease on the router is harmless and expires on its own.)
- **"What's the password?" — there is none.** Cloud images are SSH-key-only;
  console/password logins fail by design. For emergency console access, set
  one after logging in: `sudo passwd ciri` (sudo is passwordless for the
  cloud-init user).
- **Beszel agent install script enabled daily auto-updates** (answered its
  prompt wrong): it plants `beszel-agent-update.timer`. Fix:
  `sudo systemctl disable --now beszel-agent-update.timer`.
- **`qm terminal 150` needs a real TTY** — from a piped/scripted SSH session
  it dies with `tcgetattr … Inappropriate ioctl`. Peek at the serial console
  non-interactively via the socket instead:
  `printf '\r\n' | timeout 4 socat - UNIX-CONNECT:/var/run/qemu-server/150.serial0`.
- **Finding a guest that isn't where it should be**: ping-sweep the DHCP range
  and match the VM's MAC (`qm config 150 | grep net0`) in `ip neigh` — the
  router's lease table isn't scriptable (Boa/GPON captcha), but ARP is.
- **"Docker is down" after editing `daemon.json`** — stopping
  `docker.service` alone isn't enough (`docker.socket` resurrects it on the
  next API call, possibly mid-edit), so the runbook stops both — but then
  **both must be started again**; an edit session that ends with the daemon
  cleanly stopped looks exactly like a crash later.
- **`EXTRA_FILESYSTEMS` wants a mount path, not a device name** —
  `EXTRA_FILESYSTEMS=sdb` shows nothing on the hub; `EXTRA_FILESYSTEMS=/data`
  works.
- **`data-root` does not govern image storage on modern Docker.** Fresh
  Docker 28+ installs default to the **containerd image store**
  (`docker info` shows driver `overlayfs`; classic is `overlay2`), which
  keeps image layers under containerd's root — `/var/lib/containerd`, on the
  root disk — silently defeating a relocated data-root as images accumulate.
  Fix: `root = "/data/containerd"` in `/etc/containerd/config.toml`, restart
  containerd + docker (the moved store starts empty; repull). Verify with
  `du -sh /data/containerd` after a pull.
- **`local` log driver files are binary + compressed** — read logs with
  `docker logs --since/--until <ct>` (handles rotated files), not by grepping
  `/data/docker`. If raw grep-able files ever matter more than compactness,
  switch to `json-file` with the same `max-size`/`max-file` opts.

## Verification (read-only)

```bash
# geralt
qm status 150
qm agent 150 ping && echo agent-ok
qm config 150

# in the VM (ssh lab-ciri)
hostname; ip -4 -br addr show eth0     # ciri, .150/24
cloud-init status                       # done
docker version --format '{{.Server.Version}}'; docker compose version
docker info --format '{{.Driver}} | {{.DockerRootDir}} | {{.LoggingDriver}}'
                                        # overlayfs | /data/docker | local
grep '^root' /etc/containerd/config.toml   # root = "/data/containerd"
sudo du -sh /data/containerd /data/docker
groups ciri                             # includes docker
systemctl is-active docker docker.socket beszel-agent qemu-guest-agent
systemctl is-enabled beszel-agent-update.timer   # disabled
lsblk; grep data /etc/fstab; df -h / /data
systemctl cat beszel-agent | grep EXTRA_FILESYSTEMS   # /data
free -m
resolvectl status | grep -A3 'DNS Servers'
```

Verified 2026-07-11: VM running with the config above, guest agent answering,
`.150` static with Pi-hole DNS + search domain, cloud-init done, Docker
29.6.1 / Compose v5.3.1 with `ciri` in the docker group, root fs grown to
61 G (2.6 G used), Beszel agent active with update timer disabled. Two-disk
split verified same day **including reboot survival**: `/data` mounted by
label, `data-root` at `/data/docker` with `local` logging (100m×5),
old `/var/lib/docker` removed, hello-world runs, hub showing `/data`.
Containerd root move verified 2026-07-12: config set, services active,
hello-world layers landing in `/data/containerd`.

## Stacks

Convention (also in `CLAUDE.md`): each stack lives at `/data/stacks/<stack>/`
in the VM — `compose.yaml` + git-ignored `.env` — and is mirrored in this
repo at `configs/ciri/<stack>/` (compose scp'd verbatim after every change,
plus `.env.example` + README).

| Stack | Since | Purpose |
|---|---|---|
| nebula-sync | 2026-07-12 | hourly Pi-hole sync 101 → 201 + on-demand `sync-now`; cleared both deferred items in [dns.md](dns.md) ([as-built](../configs/ciri/nebula-sync/README.md)) |
| memos | 2026-07-12 | note-taking, port 5230; restored from old-host backup (SQLite DB + assets), historical data verified ([as-built](../configs/ciri/memos/README.md)) |
| sure | 2026-07-13 | personal finance (we-promise/sure v0.7.2 via `:stable`), port 3000; fresh install, old-host backup deliberately discarded; daily pg_dump via `backup` profile enabled ([as-built](../configs/ciri/sure/README.md)) |
| paperless | 2026-07-14 | document management (2.20.15), port 8000; images/PDF ingestion only — no tika/gotenberg ([as-built](../configs/ciri/paperless/README.md)) |
| immich | 2026-07-14 | photo/video library (v3.0.2), port 2283; originals on geralt's `steel/photos` via virtiofs at `/mnt/photos`, thumbs/postgres on `/data` ([as-built](../configs/ciri/immich/README.md)) |

## Next steps (not yet built)

- **App stacks**: Jellyfin is the last one. Memos done 2026-07-12, sure
  2026-07-13 (fresh install — old-host backup discarded), paperless
  2026-07-14, immich 2026-07-14.
- **Immich follow-ups**: backup job done 2026-07-16 (restic → yennefer,
  [scripts/backup/README.md](../scripts/backup/README.md)) — library
  import now unblocked; B2 offsite later — see
  [configs/ciri/immich/README.md](../configs/ciri/immich/README.md).
- **Memos follow-ups**: DNS name on pihole-1, Uptime-Kuma HTTP monitor on
  `:5230`.
- **Sure follow-ups**: DNS name on pihole-1, Uptime-Kuma HTTP monitor on
  `:3000`.
- **Jellyfin prerequisites**: GPU decision (iGPU QuickSync vs GTX 1060
  passthrough — also unblocks the Beszel GPU panel, see
  [monitoring.md](monitoring.md)), and the media disk as `--scsi2` from
  steel/USB with `backup=0`.
- **App-level backups**: restic/borgmatic dumps to offsite once apps hold
  real data ([backups.md](backups.md) next phase).
- Optional: `qm set 150 --delete balloon` to restore PVE guest-memory
  reporting (memory stays fixed at 8 G).
