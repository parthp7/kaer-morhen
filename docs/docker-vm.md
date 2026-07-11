# Docker VM — ciri

As-built runbook for VM **150 (`ciri`)** on geralt, implemented 2026-07-11.
The application-hosting VM from [Proposal 001 §3](proposals/001-initial-infrastructure-plan.md):
all consumer-facing compose stacks (sure, memos, paperless-ngx, Jellyfin, …)
live here. Base VM + Docker only — app stacks are follow-up work.

**Naming**: single-purpose LXCs get functional names (`pihole-1`, `uptime-kuma`);
the few big multi-service guests get character names like the nodes. This VM is
`ciri` — the person the saga is actually about, running on `geralt`, her
guardian. VM name = guest hostname = login user = `ciri`.

## Architecture

| Piece | Value |
|---|---|
| VM | **150** on **geralt**, `.150`, name/hostname/user `ciri` |
| OS | Ubuntu Server **26.04 LTS** (Resolute) cloud image, cloud-init provisioned |
| Machine | **q35 + OVMF**, Secure Boot off (`pre-enrolled-keys=0`) — GPU passthrough later is a `qm set --hostpci0`, not a rebuild; no MOK dance for future NVIDIA DKMS |
| Resources | 6 vCPU (`cpu: host`), **8192 MB fixed** (`balloon: 0`), 64 G sparse zvol on `silver-guests` (`discard=on,iothread=1,ssd=1`, virtio-scsi-single) |
| Network | virtio on `vmbr0`, static `<LAN_PREFIX>.150/24` via cloud-init, DNS `.101`/`.201` (the Pi-holes), search `kaermorhen.home.arpa` |
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

**Disk sizing**: 64 G is a cap on a sparse zvol, not an allocation. Growing is
online and trivial (`qm disk resize 150 scsi0 +32G`, then `growpart` in-guest);
shrinking is effectively impossible — grow on evidence. Bulk data classes
never go here: media later arrives as a second disk (`--scsi1`) backed by
steel/USB with **`backup=0`**, so replaceable terabytes never inflate the
nightly PBS job protecting the irreplaceable app data.

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
  --searchdomain kaermorhen.home.arpa
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
- **Uptime-Kuma** (`http://<LAN_PREFIX>.103:3001`): Ping monitor for `.150` —
  Kuma shares the node, but a VM crash isn't a node crash.

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
groups ciri                             # includes docker
systemctl is-active beszel-agent qemu-guest-agent
systemctl is-enabled beszel-agent-update.timer   # disabled
df -h /; free -m
resolvectl status | grep -A3 'DNS Servers'
```

Verified 2026-07-11: VM running with the config above, guest agent answering,
`.150` static with Pi-hole DNS + search domain, cloud-init done, Docker
29.6.1 / Compose v5.3.1 with `ciri` in the docker group, root fs grown to
61 G (2.6 G used), Beszel agent active with update timer disabled,
~585 MB RAM in use of 7.9 G.

## Next steps (not yet built)

- **First compose stack: nebula-sync** + Pi-hole local DNS records — clears
  the two deferred items in [dns.md](dns.md) and ends the
  edit-both-UIs-by-hand tax. Do this before any apps.
- **App stacks**: sure, memos, paperless-ngx; Jellyfin last.
- **Jellyfin prerequisites**: GPU decision (iGPU QuickSync vs GTX 1060
  passthrough — also unblocks the Beszel GPU panel, see
  [monitoring.md](monitoring.md)), and the media disk as `--scsi1` from
  steel/USB with `backup=0`.
- **App-level backups**: restic/borgmatic dumps to offsite once apps hold
  real data ([backups.md](backups.md) next phase).
- Optional: `qm set 150 --delete balloon` to restore PVE guest-memory
  reporting (memory stays fixed at 8 G).
