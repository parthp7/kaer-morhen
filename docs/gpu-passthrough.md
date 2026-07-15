# GPU Passthrough — GTX 1060 → ciri

As-built runbook for passing geralt's NVIDIA GTX 1060 Mobile through to VM
**150 (`ciri`)**, implemented 2026-07-16. Closes the "iGPU vs GTX 1060"
decision deferred in [Proposal 001 §3](proposals/001-initial-infrastructure-plan.md)
and [docker-vm.md](docker-vm.md). Primary consumer: the upcoming Jellyfin
stack (NVENC transcoding); also unlocks CUDA for Immich ML and future local
AI workloads.

## Decision record: GTX 1060 over iGPU

Evaluated 2026-07-16 against the live hardware:

- **The 1060 is a clean VFIO candidate.** IOMMU is active out of the box on
  this platform (kernel 7.x enables `intel_iommu` by default — no cmdline
  change was needed; verified via populated `/sys/kernel/iommu_groups`). The
  GPU (`01:00.0`, `10de:1c20`) and its HDMI audio function (`01:00.1`,
  `10de:10f1`) sit in **IOMMU group 2** with nothing else but their root
  port — bridges are exempt from VFIO's group rule, so the group is viable
  as-is.
- **Every iGPU-into-VM path is compromised on this hardware.** Full UHD 630
  passthrough steals the host's only console — unacceptable on a node that is
  physical-access-only for power-on/debug ([hardware-inventory.md](hardware-inventory.md)
  WoL notes). GVT-g (mediated iGPU split) is deprecated/unmaintained upstream.
  A Jellyfin LXC on the host with `/dev/dri` would work but breaks the
  "consumer stacks live on ciri" architecture.
- **The 1060 is multi-purpose.** QSV and Pascal NVENC are the same codec
  class for this library (H.264 + HEVC 8/10-bit, no AV1 on either), but the
  1060 adds 6 GB of CUDA: Jellyfin tone mapping, Immich machine learning,
  Ollama-class models (7–8B at Q4), Frigate/TensorRT if cameras ever arrive.
- **Host console survives** — the laptop panel is wired to the iGPU (Optimus),
  which stays with the host.

Known ceilings, accepted: Pascal has no AV1 encode/decode and no HEVC
B-frames (Turing+ features); consumer drivers allow 8 concurrent NVENC
sessions. Ample for home streaming.

## Architecture

| Piece | Value |
|---|---|
| GPU | NVIDIA GTX 1060 Mobile (GP106M, 6 GB) at host `0000:01:00`, both functions (VGA `10de:1c20` + HDMI audio `10de:10f1`) |
| Host binding | `vfio-pci` via `/etc/modprobe.d/vfio.conf` (ids + `disable_vga=1`, softdeps beat `nouveau`/`snd_hda_intel` to the device); `nouveau` blacklisted; vfio modules in `/etc/modules` |
| Kernel cmdline | **unchanged** (`quiet` only) — IOMMU is on by default; `iommu=pt` evaluated and skipped as unneeded |
| VM attach | `hostpci0: 0000:01:00,pcie=1` — no `.0` suffix = all functions travel together (required: they share IOMMU group 2 and the audio function enables the slot-level bus reset) |
| Guest driver | `nvidia-driver-580-server` 580.159.03 (Ubuntu 26.04 archive, `ubuntu-drivers` recommendation) |
| Container runtime | `nvidia-container-toolkit` 1.19.1 from NVIDIA's apt repo (not in Ubuntu's); `nvidia` runtime registered in `/etc/docker/daemon.json` via `nvidia-ctk`, default runtime stays `runc` — containers opt in with `gpus` reservations |
| Memory | no change — `balloon: 0` was already set on the VM; VFIO pins guest RAM, which the 8 G fixed sizing anticipated ([docker-vm.md](docker-vm.md)) |
| Idle cost | ~3 W / 46 °C at P8 with no processes (verified) — negligible thermal load for the laptop chassis |

## Runbook (as executed)

### 1. Host (geralt) — bind the GPU to vfio-pci

```bash
cat >/etc/modprobe.d/vfio.conf <<'EOF'
options vfio-pci ids=10de:1c20,10de:10f1 disable_vga=1
softdep nouveau pre: vfio-pci
softdep snd_hda_intel pre: vfio-pci
EOF
echo -e "vfio\nvfio_iommu_type1\nvfio_pci" >> /etc/modules
echo "blacklist nouveau" > /etc/modprobe.d/blacklist-nouveau.conf

update-initramfs -u -k all
reboot

# after reboot — both functions must say "Kernel driver in use: vfio-pci"
lspci -nnk -s 01:00
```

### 2. Host — attach to the VM

```bash
qm stop 150        # full stop/start, not reboot — hostpci is cold-plug
qm set 150 --hostpci0 0000:01:00,pcie=1
qm start 150
```

`qm start` prints a PCI-reset warning every time — harmless, see gotchas.

### 3. Guest (ciri) — NVIDIA driver

```bash
sudo ubuntu-drivers list                       # → recommended -server branch
sudo apt install -y nvidia-driver-580-server
sudo reboot
nvidia-smi                                     # GTX 1060, 6144 MiB, P8 ~3 W
```

### 4. Guest — container toolkit

`nvidia-ctk` is **not in Ubuntu's repos** — it ships from NVIDIA's apt repo
(same pattern as the Docker install in [docker-vm.md](docker-vm.md)):

```bash
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | \
  sudo gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | \
  sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#' | \
  sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list

sudo apt update && sudo apt install -y nvidia-container-toolkit

sudo nvidia-ctk runtime configure --runtime=docker
cat /etc/docker/daemon.json    # VERIFY data-root + log-opts survived the merge
sudo systemctl restart docker
systemctl is-active docker docker.socket   # both active

docker run --rm --gpus all ubuntu nvidia-smi   # smoke test — same table as host
```

## Using the GPU from compose

Default runtime is still `runc`; a service opts in with:

```yaml
services:
  jellyfin:
    # …
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: all
              capabilities: [gpu]
```

Consumers:

| App | Use | Wiring |
|---|---|---|
| Jellyfin (next stack) | NVENC/NVDEC transcode, CUDA HDR→SDR tone mapping | reservation above + enable NVENC in Playback settings |
| Immich | ML (smart search, faces) on CUDA; NVENC for video previews | swap ML image to the `-cuda` tag + reservation; NVENC in video-transcoding settings — optional, CPU is coping meanwhile |
| Future | Ollama (7–8B Q4 fits in 6 GB), Frigate + TensorRT, Whisper | per-stack |

paperless / memos / sure / nebula-sync have no GPU use.

## Gotchas hit (and the explanations)

- **`qm start 150` warns: `error writing '1' to
  '/sys/bus/pci/devices/0000:01:00.0/reset': Inappropriate ioctl for device`.**
  Harmless and permanent — GP106M has no Function-Level Reset; its only
  `reset_method` is `bus`, and a bus reset can't be triggered through one
  function's sysfs file while the sibling audio function shares the bus, so
  the kernel rejects PVE's per-function attempt. QEMU/VFIO then performs the
  proper slot-level secondary-bus reset itself — which works *because* both
  functions are assigned together. Nothing to fix; no PVE knob silences it.
- **No-FLR corollary:** the GPU can't be reset in isolation. If it ever comes
  up wedged in the guest after many VM stop/start cycles (rare with clean
  driver teardown), the recovery is a **geralt reboot**.
- **`nvidia-ctk: command not found` after installing the driver** — the
  toolkit is a separate package from a separate (NVIDIA) repo; the driver
  package doesn't ship it.
- **`nvidia-ctk runtime configure` edits `/etc/docker/daemon.json`** — the
  same file carrying `data-root` and the log caps. It merges correctly
  (verified: all prior keys intact, `runtimes.nvidia` added), but eyeball it
  before restarting Docker, and remember the docker.socket resurrection
  gotcha from [docker-vm.md](docker-vm.md).
- **Optimus vBIOS caveat — did NOT fire here.** Mobile GPUs sometimes need
  `romfile=` because the vBIOS lives in the system BIOS, not on the card.
  This card initialized fine headless (no display output → no vBIOS-dependent
  VGA init). If a future driver/init failure looks vBIOS-shaped: dump the
  vBIOS, place it in `/usr/share/kvm/`, re-attach with
  `--hostpci0 0000:01:00,pcie=1,romfile=<file>`.

## Consequences elsewhere

- **The host can no longer see the 1060** (it's vfio-bound) — GPU monitoring
  must come from *inside ciri*, where the driver now lives. This is the
  "nvidia drivers wherever the GPU lives" fork anticipated in
  [monitoring.md](monitoring.md); the Beszel GPU panel is now unblocked via
  ciri's agent.
- **PBS backups of ciri: unaffected.** Live migration was already off the
  table (virtiofs mount); hostpci doesn't change the backup story.
- **Guest RAM is now VFIO-pinned** — already priced into the 8 G fixed /
  `balloon: 0` sizing.

## Verification (read-only)

```bash
# geralt
lspci -nnk -s 01:00                    # both functions: vfio-pci
cat /sys/bus/pci/devices/0000:01:00.0/reset_method   # bus
qm config 150 | grep hostpci           # hostpci0: 0000:01:00,pcie=1

# ciri (ssh lab-ciri)
nvidia-smi                             # GTX 1060, P8, ~3 W idle
dpkg -l nvidia-container-toolkit | grep ^ii          # 1.19.1-1
docker info --format '{{json .Runtimes}}' | grep -o nvidia   # runtime present
docker info --format '{{.DefaultRuntime}}'           # runc (opt-in per service)
cat /etc/docker/daemon.json            # data-root + log-opts + runtimes.nvidia
docker run --rm --gpus all ubuntu nvidia-smi          # end-to-end smoke test
```

Verified 2026-07-16: host binding, VM attach, driver 580.159.03, toolkit
1.19.1, daemon.json merge, both docker units active, container smoke test
passing.

## Next steps

- **Jellyfin stack** on ciri (`configs/ciri/jellyfin/`) — the GPU prerequisite
  is done; remaining prerequisite is the media disk as `--scsi2` from
  steel/USB with `backup=0` ([docker-vm.md](docker-vm.md)).
- **Beszel GPU panel** — confirm ciri's agent picks up `nvidia-smi` and the
  panel appears on the hub ([monitoring.md](monitoring.md)).
- **Immich CUDA** (optional) — switch the ML container to the `-cuda` image
  when convenient; not urgent while CPU keeps up.
