# scripts/monitoring

Helper scripts for the monitoring/alerting stack (see [docs/monitoring.md](../../docs/monitoring.md)).

## smartd-ntfy.sh

smartd `-M exec` handler that forwards SMART warnings (failing health,
reallocated/pending sectors, error-log growth) to the shared ntfy topic.

- **Deployed to**: `/usr/local/bin/smartd-ntfy.sh` on **both** nodes (0755).
- **Wired via** `/etc/smartd.conf`:
  `DEVICESCAN -a -n standby,q -m <nomailer> -M exec /usr/local/bin/smartd-ntfy.sh`
- **Reads** the topic from `/etc/ntfy.topic` (mode 600, git-ignored world —
  the real topic lives only on the nodes and in `secrets.local.yaml`).
- **Test** the full chain: temporarily append ` -M test` to the DEVICESCAN
  line, `systemctl restart smartmontools`, confirm the phone notification,
  revert.

## media-mount-health.sh

Uptime-Kuma **Push** monitor proving that ciri's `/mnt/media` is the real 916 GB
USB disk and not a placeholder directory that virtiofsd pinned at VM start.
Added 2026-07-29 after the [2026-07-27 wrong-filesystem incident](../../docs/storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem),
which every liveness monitor in the lab missed for ~16 hours.

Checks, first failure wins: `/mnt/media` is a real **virtiofs** mount point →
`library/` exists → the filesystem is **≥ 800 GiB** → `library/` can be
**enumerated** → `library/.mount-health` can be **read**.

**Checks 1–3 answer 2026-07-27** (wrong filesystem: wrong identity, wrong size).
The size check is load-bearing *there* — the placeholder on geralt's pve-root
reports 68 G, and once Docker auto-created `downloads/` on it, existence alone no
longer discriminated.

**Checks 4–5 answer [2026-08-03](../../docs/storage.md#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr)**
(dead filesystem: *right* identity, *right* size). When the USB disk drops off the
bus, virtiofsd keeps serving its pinned inode on a shut-down ext4: `findmnt` still
says `virtiofs`, `df` still reports 915 GiB, and `stat` still succeeds — while
every real read returns `EIO`. The monitor pushed **166 consecutive `ok`
heartbeats over 14 h 43 m** in that state, then **57 more** during a recurrence on
08-03/04. Only an actual read distinguishes a live filesystem from a dead one:

- **Check 4** enumerates `library/` (`readdir` must reach virtiofsd for anything
  not in the guest dentry cache — this is exactly what failed for Jellyfin,
  `Input/output error: '/media/movies'`).
- **Check 5** reads bytes from `library/.mount-health` with **`O_DIRECT`**, so the
  guest page cache cannot serve a stale copy. If the kernel rejects the flag
  (`EINVAL` — virtiofs without O_DIRECT support) it falls back to a buffered read
  rather than raising a false alarm; that fallback is weaker, which is why check 4
  is kept as an independent signal.

**Do not "optimise" checks 4–5 back into `stat()` calls** — that reintroduces the
exact blind spot they exist to close.

The sentinel file must exist on the real disk (create once, at deploy):

```bash
dd if=/dev/urandom of=/mnt/media/library/.mount-health bs=4096 count=1
```

- **Deployed to**: `/usr/local/bin/media-mount-health.sh` on **ciri** (0755).
- **Reads** the push URL from `/etc/kuma-push.media-mount` (mode 600). The URL
  carries Kuma's push token — it lives only on ciri and in `secrets.local.yaml`.
- **Exits non-zero** on failure as well as pushing `status=down`, so a bad state
  is visible in `systemctl --failed` even if Kuma itself is unreachable.
- **Two independent failure signals**: an explicit `status=down` push (fast, with
  a reason) *and* heartbeat silence if the script or timer dies (the backstop).

Unit + timer on ciri:

```ini
# /etc/systemd/system/media-mount-health.service
[Unit]
Description=Uptime-Kuma push: ciri sees the real media filesystem
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/media-mount-health.sh
```

```ini
# /etc/systemd/system/media-mount-health.timer
[Unit]
Description=Run media-mount-health every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now media-mount-health.timer
systemctl list-timers media-mount-health.timer
journalctl -u media-mount-health.service -n 5
```

### Required drop-in: `TimeoutStartSec` (do not skip)

`Type=oneshot` defaults to `TimeoutStartUSec=infinity`. That default is actively
harmful here: if the USB disk drops off the bus mid-check, `df`/`stat` block in
uninterruptible **D state**, the script never returns, the service stays
`activating` forever — and **the timer never fires again**. Kuma still reddens
via heartbeat silence, but the unit is wedged until someone clears it by hand,
and `systemctl --failed` stays empty because the unit never fails; it hangs.

```bash
sudo systemctl edit media-mount-health.service
```

```ini
[Service]
TimeoutStartSec=60
```

```bash
sudo systemctl daemon-reload
systemctl show media-mount-health.service -p TimeoutStartUSec   # expect 1min
```

Applied 2026-07-29 as
`/etc/systemd/system/media-mount-health.service.d/override.conf`. Using
`systemctl edit` rather than editing the unit means it survives a reinstall of
the unit file from this repo. With it, a hung disk yields three signals instead
of one silent hang: a `failed` unit, a red Kuma monitor, and a timer that keeps
running.

### Why 300 s and not 60 s like the other monitors

The 60 s monitors are HTTP liveness checks against always-on services — cheap,
and what they detect can start or stop at any second. This check is a different
class, and the interval is a deliberate choice, not an oversight:

- **The fault is set at VM start and then frozen.** virtiofsd resolves
  `--shared-dir` once and pins that inode for its lifetime, so a VM that booted
  onto the wrong filesystem stays wrong until the next cold `qm start`. There is
  no path from wrong back to right without a VM restart, so polling faster only
  shortens *notification* of a condition that a restart has to clear anyway.
  The 07-27 outage ran 16 hours because nothing checked at all — not because a
  check was slow.
- **It touches a spinning USB disk with a known-flaky bridge.** `df` is a cheap
  `statfs`, but the `library/` check stats the mount. 60 s polling is 5× the
  traffic to the least-trusted device in the lab and works against spin-down.

If a faster cadence is ever wanted, 120 s is the sensible floor.

### Kuma's heartbeat interval must EXCEED the timer period (corrected 2026-07-29)

This originally said the heartbeat interval should *match* the timer. That is
wrong, and it made both Push monitors flap red on every beat while the checks
themselves were passing. A `systemd` timer's real period is **longer** than
`OnUnitActiveSec`:

- `AccuracySec` lets systemd defer the trigger to batch it with other timers —
  up to 30 s with the value below.
- `OnUnitActiveSec` counts from the last **activation**, so each run's own
  duration is added on top.

Measured on ciri, consecutive `media-mount-health` runs: 301 s, 330 s, 322 s,
308 s, 330 s — every one over a 300 s heartbeat window, so Kuma reddened every
time. Set the heartbeat **above the worst-case period, not equal to the timer**:

| Timer `OnUnitActiveSec` | Kuma Heartbeat Interval | Retries |
|---|---|---|
| 5 min | **360 s** | **1** |

Retries `1` means two consecutive genuine misses (~12 min) before it pages,
which is still well inside the 16-hour blind spot this was built to close. If
`AccuracySec=1s` is set instead of `30s` the period tightens to ~301 s, but keep
the headroom anyway — it costs nothing and the timer is not the only source of
delay (a slow push counts too).

## servarr-vpn-health.sh

Uptime-Kuma **Push** monitor proving qBittorrent's traffic still leaves through
the VPN, and that it can still accept peers. Added 2026-07-29; rationale and the
full severity table are in
[docs/uptime-kuma.md](../../docs/uptime-kuma.md#the-servarr-vpn-push-monitor-added-2026-07-29--and-what-it-actually-proves).

The core of it: make a **real outbound request from inside gluetun's netns** and
compare the answer to ciri's own public IP. Probing from ciri would measure ciri
and prove nothing — qBittorrent lives in gluetun's namespace, so that is the only
place the question can be asked honestly.

**Hard** (red at once): egress == ciri's public IP; the `tun0` interface missing
from the netns; no egress at all; gluetun control server unreachable; qBittorrent
API unreachable. **Soft** (green, reason in the heartbeat log): forwarded port
`0`; forwarded port ≠ qBit's `listen_port`; or the egress comparison being
unverifiable — all escalate to red after `MAX_STRIKES` (default 6, ≈30 min)
consecutive runs.

**The exit IP's owner is deliberately NOT a check.** The first version hard-failed
unless the exit's `organization` contained `proton`, and it raised a false leak
alert across four consecutive runs (2026-07-29 23:45 → 2026-07-30 00:01) when
gluetun rotated onto a Proton server whose block is registered to its upstream
datacenter — `AS208172 Proton AG` → `AS199218 Proton AG` →
`AS43350 NForce Entertainment B.V.`, all the same VPN.
Proton rents capacity and does not own all the space it exits from, so neither
the ASN nor the org string is a stable identity, and pinning either just moves
the whack-a-mole. The only leak invariant that cannot go stale is
**egress != ciri's own public IP**; the org is reported for human context and
never decides the verdict.

- **Deployed to**: `/usr/local/bin/servarr-vpn-health.sh` on **ciri** (0755).
- **Reads** the push URL from `/etc/kuma-push.servarr-vpn` (mode 600). Separate
  file and separate Kuma monitor from the media one — never share a push token.
- **Strike counter**: `/var/lib/servarr-vpn-health/degraded.strikes`, deliberately
  not in `/tmp` so a reboot can't reset a genuinely stuck port to zero strikes.
- **Needs `docker exec`** — runs as root from the timer, same as the other script.
- **Fails closed**: if a lookup breaks, the run is a hard failure rather than a
  green heartbeat. "Cannot determine" is never "fine".

Unit + timer on ciri (same shape as media-mount, including the drop-in — the
`Type=oneshot` timeout argument applies identically here, and more so: this
script makes network calls that can hang):

```ini
# /etc/systemd/system/servarr-vpn-health.service
[Unit]
Description=Uptime-Kuma push: qBittorrent egress still goes through the VPN
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
TimeoutStartSec=150
ExecStart=/usr/local/bin/servarr-vpn-health.sh
```

`TimeoutStartSec` is set directly in the unit here rather than as a drop-in,
because unlike media-mount this script was written with it from the start. It
must exceed the internal network timeouts: checks are 10 + 15 + 10 + 10 + 10 =
55 s worst case, and the retrying push adds up to 36 s more — 91 s total, so the
original `90` was under the line by a second. **150** leaves real margin.

```ini
# /etc/systemd/system/servarr-vpn-health.timer
[Unit]
Description=Run servarr-vpn-health every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

`OnBootSec=3min` (vs media-mount's 2 min) gives gluetun time to bring the tunnel
up after a reboot, so the first run isn't a spurious "no egress" alert.

Deploy:

```bash
sudo install -m 0755 servarr-vpn-health.sh /usr/local/bin/
printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.servarr-vpn >/dev/null
sudo chmod 600 /etc/kuma-push.servarr-vpn
sudo systemctl daemon-reload && sudo systemctl enable --now servarr-vpn-health.timer
journalctl -u servarr-vpn-health.service -n 10 --no-pager
```

Kuma monitor: **Push**, name `servarr vpn health`, Heartbeat Interval **360 s**,
Retries **1** — see the heartbeat-interval note above; 300 s here would flap red
on every beat. Strip the `?status=up&msg=OK&ping=` query string from the URL
Kuma displays — the script appends its own parameters.

- **Test the leak path** without touching the tunnel, by telling the script that
  ciri's public IP *is* the current egress IP — which is exactly what a leak looks
  like:
  ```bash
  VPN_IP=$(docker exec gluetun wget -qO- https://api.ipify.org)
  sudo HOST_IP_OVERRIDE="$VPN_IP" /usr/local/bin/servarr-vpn-health.sh
  ```
  → hard fail, Kuma reddens, ntfy fires. Re-run without the override to clear.
  `HOST_IP_OVERRIDE` never writes the host-IP cache, so this leaves no residue.
- **Test the soft path**: `sudo MAX_STRIKES=1 /usr/local/bin/servarr-vpn-health.sh`
  while the forwarded port is 0 → escalates immediately instead of after 6.
  Reset afterwards with
  `sudo rm -f /var/lib/servarr-vpn-health/degraded.strikes`.

- **Test** the failure path without touching the mount:
  `sudo MIN_GIB=99999 /usr/local/bin/media-mount-health.sh` → pushes `down`,
  Kuma reddens, ntfy fires; re-run without the override to clear.

## gpu-health.sh

Uptime-Kuma **Push** monitor proving Jellyfin can still **encode on the GPU**.
Added 2026-08-02 after the [2026-08-01 GPU-loss outage](../../configs/ciri/jellyfin/README.md#all-transcodes-fail-after-a-systemd-daemon-reload-2026-08-01),
which ran ~21 hours with every monitor green.

That outage is the third instance of the same lesson as
[`media-mount-health.sh`](#media-mount-healthsh) and
[`servarr-vpn-health.sh`](#servarr-vpn-healthsh): **liveness cannot see a
capability that has silently gone missing.** Jellyfin answered on `:8096`
throughout, its Kuma HTTP monitor stayed green, and Beszel's GPU panel was
healthy — because Beszel watches the card from the **host**, where nothing was
wrong. Direct Play kept working, so most playback looked normal; only
transcodes failed, and only on the TV, as "media is not supported by this
client".

### Why the check is an encode, not `nvidia-smi`

`nvidia-smi` succeeding proves NVML is reachable. It does **not** prove the
encoder is usable — under the legacy runtime path, a container missing `video`
in `NVIDIA_DRIVER_CAPABILITIES` runs `nvidia-smi` happily while NVENC is
invisible. So the load-bearing check runs a real one-second `h264_nvenc` encode
with **Jellyfin's own ffmpeg, inside the container**, output to the null muxer:

```bash
docker exec jellyfin /usr/lib/jellyfin-ffmpeg/ffmpeg -hide_banner -loglevel error \
  -f lavfi -i testsrc=duration=1:size=256x256:rate=5 -c:v h264_nvenc -f null -
```

That exercises CUDA init, NVENC session allocation and an actual encode — every
step a transcode needs, and the exact step that failed on 08-01. Nothing is
written to disk.

- **Deployed to**: `/usr/local/bin/gpu-health.sh` on **ciri** (0755).
- **Reads** the push URL from `/etc/kuma-push.gpu-health` (mode 600).
- **Exits non-zero** on hard failure as well as pushing `status=down`.
- **Two independent failure signals**: an explicit `status=down` push, *and*
  heartbeat silence if the script or timer dies.

### Severities

| | Condition | Why |
|---|---|---|
| **Hard** | jellyfin container not running | nothing to check |
| **Hard** | `nvidia-smi` fails inside jellyfin | the 2026-08-01 fault exactly — host card can be perfectly healthy |
| **Hard** | `h264_nvenc` missing from ffmpeg | NVML works but the encoder is not exposed |
| **Hard** | test encode fails with the GPU **idle** | a real fault; there is nothing to blame it on |
| **Hard** | ollama running but its `nvidia-smi` fails | the other GPU consumer lost access, same fault class |
| **Soft** | test encode fails with **≥ 3000 MiB VRAM in use** | a resident Ollama model on the shared 6 GB card; `OLLAMA_KEEP_ALIVE=10m` frees it |
| **Hard** | test encode fails and VRAM is **unreadable** | fail closed — an unreadable `nvidia-smi` is not evidence of innocence |

Soft conditions escalate after **6 consecutive runs** (~30 min at the 5 min
timer), counted in `/var/lib/gpu-health/degraded.strikes` — outside `/tmp` so a
reboot cannot reset a genuinely wedged GPU to zero strikes. This encodes the
same distinction as the jellyfin README's
[contention-vs-device-loss table](../../configs/ciri/jellyfin/README.md#is-it-the-daemon-reload-or-vram-contention-with-ollama):
contention fails *after* CUDA initialises and only while a model is loaded;
lost device access fails before any allocation, with the card idle.

The 3000 MiB threshold only **attributes** a failure, it never causes one. It
sits above an idle card plus a live transcode session (~115 MiB, measured
2026-08-02) and below the smallest resident model (~4.3 G).

### Unit + timer on ciri

```ini
# /etc/systemd/system/gpu-health.service
[Unit]
Description=Uptime-Kuma push: Jellyfin can encode on the GPU
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/gpu-health.sh
```

```ini
# /etc/systemd/system/gpu-health.timer
[Unit]
Description=Run gpu-health every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
AccuracySec=30s

[Install]
WantedBy=timers.target
```

`OnBootSec=3min` (not 2, like media-mount) staggers it off the other timer so
two `docker exec`-heavy checks don't fire together on a 6-vCPU VM.

**The `TimeoutStartSec` drop-in applies here too** — same reasoning as
[media-mount](#required-drop-in-timeoutstartsec-do-not-skip): `Type=oneshot`
defaults to an infinite start timeout, and a wedged container would leave the
unit `activating` forever, so the timer would never fire again. The script also
wraps every `docker exec` in `timeout 30`, which turns a hang into a labelled
failure rather than a silent kill — but keep both.

```bash
sudo systemctl edit gpu-health.service
```

```ini
[Service]
TimeoutStartSec=90
```

90 s, not 60: the worst case is four `docker exec` calls each capped at 30 s.

```bash
sudo systemctl daemon-reload && sudo systemctl enable --now gpu-health.timer
systemctl list-timers gpu-health.timer
journalctl -u gpu-health.service -n 5
```

Kuma monitor: **Push**, heartbeat **360 s**, retries **1** — the interval must
exceed the timer's worst-case period, see
[the correction above](#kumas-heartbeat-interval-must-exceed-the-timer-period-corrected-2026-07-29).

### Exercising both paths before trusting it

A monitor that has never been red has not been tested. Both paths can be forced
without touching the GPU:

```bash
# Hard path — point it at a container that has no GPU:
sudo env JELLYFIN_CONTAINER=searxng /usr/local/bin/gpu-health.sh; echo "exit=$?"
# → nvidia-smi FAILED inside 'searxng' …   exit 1, Kuma goes red

# Hard path — encode fails with the card idle (the "really broken" verdict):
sudo env FORCE_ENCODE_FAIL=1 /usr/local/bin/gpu-health.sh; echo "exit=$?"
# → NVENC test encode FAILED with the GPU essentially idle (0MiB used) …   exit 1

# Soft path — same failure, but attributed to VRAM contention:
sudo env FORCE_ENCODE_FAIL=1 VRAM_CONTENTION_MIB=0 /usr/local/bin/gpu-health.sh
# → degraded: … (strike 1/6), stays green, exit 0
# Repeat 6× to watch it escalate to down, then clear the counter:
sudo rm -f /var/lib/gpu-health/degraded.strikes
```

**Use `FORCE_ENCODE_FAIL`, not `FFMPEG_BIN=/bin/false`, to fake a failed
encode.** The obvious trick does not work: `FFMPEG_BIN` is also used by the
earlier `-encoders` check, so pointing it at `/bin/false` trips *that* check and
lands on the hard "h264_nvenc missing" path, never reaching the encode step the
soft path depends on. The explicit test hook exists to make the soft path
reachable at all — same role as `HOST_IP_OVERRIDE` in
[`servarr-vpn-health.sh`](#servarr-vpn-healthsh).

`sudo env VAR=…` rather than `sudo VAR=…`: the latter depends on sudoers not
resetting the environment, and fails silently-wrong if it does — the script
would run with defaults and report a misleading green.

Then confirm the monitor goes **green** on a normal run — per the
[photos-backup lesson](../../docs/uptime-kuma.md#the-photos-backup-push-monitor--silent-for-14-days-fixed-2026-07-30),
a push monitor that has never been green has only been created, not tested.
