# GPU Passthrough — GTX 1060 → ciri

As-built runbook for passing geralt's NVIDIA GTX 1060 Mobile through to VM
**150 (`ciri`)**, implemented 2026-07-16. Closes the "iGPU vs GTX 1060"
decision deferred in [Proposal 001 §3](proposals/001-initial-infrastructure-plan.md)
and [docker-vm.md](docker-vm.md). Primary consumer: the upcoming Jellyfin
stack (NVENC transcoding — client-side compatibility research in
[jellyfin-clients.md](jellyfin-clients.md)); also unlocks CUDA for Immich ML
and future local AI workloads.

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
| Host binding | `vfio-pci` via `/etc/modprobe.d/vfio.conf` (ids + `disable_vga=1` + **`disable_idle_d3=1`**, softdeps beat `nouveau`/`snd_hda_intel` to the device); `nouveau` blacklisted; vfio modules in `/etc/modules`. `disable_idle_d3=1` is **not optional** — see the D3cold host-hang gotcha |
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
options vfio-pci ids=10de:1c20,10de:10f1 disable_vga=1 disable_idle_d3=1
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
| Jellyfin (**live** 2026-07-22) | NVENC/NVDEC transcode, CUDA HDR→SDR tone mapping | reservation above + NVENC in Playback settings — **verified**: CUDA decode → `scale_cuda` → `h264_nvenc` ([stack](../configs/ciri/jellyfin/README.md)) |
| Immich | ML (smart search, faces) on CUDA; NVENC for video previews | swap ML image to the `-cuda` tag + reservation; NVENC in video-transcoding settings — optional, CPU is coping meanwhile |
| Future | Ollama (7–8B Q4 fits in 6 GB), Frigate + TensorRT, Whisper | per-stack |

paperless / memos / sure / nebula-sync have no GPU use.

## Gotchas hit (and the explanations)

- **Host hard-hang ~2 min after boot whenever the GPU is left unclaimed —
  `disable_idle_d3=1` is mandatory (diagnosed and fixed 2026-07-31).**
  Without it, `vfio-pci` lets the idle 1060 runtime-suspend into **D3cold**.
  Resuming it makes the kernel evaluate MSI's Optimus power-on AML
  (`\_SB.PCI0.PGON` via the `\_SB.PCI0.PEG0.PG00` power resource), whose
  polling loop intermittently never satisfies its exit condition and dies at
  `AE_AML_LOOP_TIMEOUT` after ~30 s. The GPU is then in an undefined power
  state; vfio-pci retries the resume ladder (1023 → 2047 → 4095 → 8191 →
  16383 → 32767 ms) and **the host wedges hard** — no panic, no oops, nothing
  in `pstore`, and the journal simply stops mid-line because journald never
  flushes. Diagnostic signature in `journalctl -b <n>`:

  ```
  ACPI Error: Aborting method \_SB.PCI0.PGON due to previous error (AE_AML_LOOP_TIMEOUT)
  ACPI Error: Aborting method \_SB.PCI0.PEG0.PG00._ON due to previous error (AE_AML_LOOP_TIMEOUT)
  vfio-pci 0000:01:00.0: not ready 1023ms after resume; waiting
  ```

  It is a **race, so it presents as intermittent**: if a VM claims the GPU
  before it idles (~10 s on this node, `onboot: 1` on VM 150) the box is fine,
  which is why some boots survive and others die at 68–124 s. Confirmed across
  12 retained boots — the signature appeared in 6/6 crashes and 0/6 healthy
  boots. `disable_idle_d3=1` makes vfio-pci hold a runtime-PM reference so the
  card never leaves D0 and the broken AML path is never entered. Cost: a few
  idle watts. Note `power/control` still reads `auto` afterwards — that knob is
  not what changes; `power_state: D0` and a `runtime_suspended_time` stuck at
  `0 ms` are the proof.

  **Two traps:** (1) the parameter only takes effect through the initramfs, so
  hand-editing `vfio.conf` without `update-initramfs -u -k all` leaves the live
  param silently at `N` while the file claims otherwise — always verify
  `/sys/module/vfio_pci/parameters/disable_idle_d3`. (2) Setting
  `onboot: 0` on VM 150 *arms* this bug, because nothing then claims the GPU
  at boot and it idles straight into D3cold. Keep VM 150 on `onboot: 1`.

  This was originally misattributed to a RAM fault — see
  [hardware-inventory.md](hardware-inventory.md) memory notes.

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
- **Jellyfin and Ollama silently fail to start after a guest reboot — the CDI
  spec race (diagnosed and fixed 2026-08-04).** Every non-GPU container comes up;
  only the two requesting `nvidia.com/gpu=all` die, with
  `ExitCode=128`, `CDI device injection failed: unresolvable CDI devices
  nvidia.com/gpu=all`. Boot timeline that exposed it:

  ```
  23:06:48      docker.service starts
  23:06:49.011  dockerd: "CDI directory does not exist, skipping" dir=/var/run/cdi
  23:06:49.011  dockerd: "CDI directory does not exist, skipping" dir=/etc/cdi
  23:06:50.13   dockerd: "Refreshing the CDI registry generated errors:
                          failed to monitor for changes: no such file or directory"
  23:06:50.32   dockerd: failed to start container — unresolvable CDI devices
  23:06:50      nvidia-cdi-refresh: "Generated CDI spec with version 0.7.0"  ← ~0.3 s too late
  ```

  **Two causes compound.** (1) `nvidia-cdi-refresh.service` as shipped declares
  only `ConditionPathExists` and `WantedBy=multi-user.target` — there is **no
  `Before=docker.service` anywhere**, so systemd runs it and Docker in parallel
  and whichever wins, wins. (2) The unit hardcodes
  `NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/var/run/cdi/nvidia.yaml`, which is **tmpfs
  and wiped every boot**, so the race is re-run on *every* boot rather than being
  one-time setup. Like the D3cold bug above, **it is a race and therefore
  intermittent** — it had been winning silently since the CDI wiring in `056ea1a`.

  **The aggravator that prevents self-healing:** dockerd tries to set an inotify
  watch on `/var/run/cdi` *before the directory exists*, and the watch fails
  (`failed to monitor for changes`). So when the spec appears 0.3 s later, dockerd
  never notices it. Without that, Docker would have recovered on its own.

  **Fix — both applied 2026-08-04, they are complementary:**

  ```bash
  # A. Persistent spec: exists on disk before Docker ever starts, killing the race.
  #    The shipped unit already reads this override file, so no unit editing.
  mkdir -p /etc/cdi
  echo 'NVIDIA_CTK_CDI_OUTPUT_FILE_PATH=/etc/cdi/nvidia.yaml' \
    > /etc/nvidia-container-toolkit/nvidia-cdi-refresh.env
  systemctl start nvidia-cdi-refresh.service

  # B. The missing ordering — still needed, because a driver upgrade regenerates
  #    the spec via nvidia-cdi-refresh.path and could race again.
  mkdir -p /etc/systemd/system/docker.service.d
  printf '[Unit]\nAfter=nvidia-cdi-refresh.service\nWants=nvidia-cdi-refresh.service\n' \
    > /etc/systemd/system/docker.service.d/wait-for-cdi.conf
  systemctl daemon-reload
  ```

  `Wants`, deliberately **not** `Requires` — a boot with the GPU absent must still
  bring Docker up rather than take the whole stack down with it. Same asymmetry as
  the required/advisory tiers in
  [`vm150-require-virtiofs.sh`](../scripts/proxmox/vm150-require-virtiofs.sh).

  Verify (read-only): `ls /etc/cdi/nvidia.yaml` and
  `systemctl show docker.service -p After | tr ' ' '\n' | grep nvidia` — the
  latter must list `nvidia-cdi-refresh.service`.

  **Operational trap: `qm start 150` does not guarantee a working Jellyfin.**
  The VM comes up, the hookscript passes, `/mnt/media` is fine — and the GPU
  containers are still dead. After any restart of this stack, check
  `docker ps -a | grep -E 'jellyfin|ollama'`, not just the VM state. Recovery
  without a reboot is `docker start jellyfin ollama`; if that repeats the CDI
  error, dockerd's registry is stale from the failed watch and needs
  `systemctl restart docker` first.

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
  [monitoring.md](monitoring.md); the Beszel GPU panel is live via ciri's agent
  (verified 2026-07-23 — power draw, utilization, memory).
- **PBS backups of ciri: unaffected.** Live migration was already off the
  table (virtiofs mount); hostpci doesn't change the backup story.
- **Guest RAM is now VFIO-pinned** — already priced into the 8 G fixed /
  `balloon: 0` sizing.

## Verification (read-only)

```bash
# geralt
lspci -nnk -s 01:00                    # both functions: vfio-pci
cat /sys/bus/pci/devices/0000:01:00.0/reset_method   # bus
qm config 150 | grep -E 'hostpci|onboot'  # hostpci0: 0000:01:00,pcie=1 / onboot: 1

# D3cold hang guard (see gotchas) — all four must hold
cat /sys/module/vfio_pci/parameters/disable_idle_d3          # Y  (live, not just the file)
cat /sys/bus/pci/devices/0000:01:00.0/power_state            # D0
cat /sys/bus/pci/devices/0000:01:00.0/power/runtime_suspended_time  # 0   (ms, never suspended)
journalctl -b 0 | grep -cE 'PGON|PG00\._ON|not ready'        # 0

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

Re-verified 2026-07-31 after the `disable_idle_d3=1` fix: clean boot with no
`PGON`/`not ready`/oops/MCE, host survived 475 s (vs 68–124 s for every prior
crash), then the decisive isolation test — ciri stopped and the GPU left
**unclaimed for 13 m 22 s**, staying `D0` with `runtime_suspended_time` at
`0 ms` throughout (12/12 polled samples), and reattaching in 5 s on
`qm start 150`. Pre-fix that idle window was reliably fatal.

## Next steps

- ~~**Jellyfin stack** on ciri~~ done 2026-07-22
  ([configs/ciri/jellyfin/README.md](../configs/ciri/jellyfin/README.md)) —
  NVENC transcode verified. Media landed on an external USB HDD via virtiofs,
  not the `--scsi2` originally sketched here.
- ~~**Beszel GPU panel**~~ done 2026-07-23 — ciri's agent picks up `nvidia-smi`; the
  panel appears on the hub ([monitoring.md](monitoring.md)).
- **Immich CUDA** (optional) — switch the ML container to the `-cuda` image
  when convenient; not urgent while CPU keeps up.
