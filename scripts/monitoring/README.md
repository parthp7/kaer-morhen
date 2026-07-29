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
`library/` exists → the filesystem is **≥ 800 GiB**. The size check is the
load-bearing one — the placeholder on geralt's pve-root reports 68 G, and once
Docker auto-created `downloads/` on it, existence alone no longer discriminated.

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

**Hard** (red at once): egress == ciri's public IP; egress not owned by Proton;
no egress at all; gluetun control server unreachable; qBittorrent API
unreachable. **Soft** (green, reason in the heartbeat log): forwarded port `0`,
or forwarded port ≠ qBit's `listen_port` — both self-heal, and both escalate to
red after `MAX_STRIKES` (default 6, ≈30 min) consecutive runs.

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

- **Test the leak path** without breaking anything, by asserting the wrong
  provider: `sudo EXPECTED_ORG=nonesuch /usr/local/bin/servarr-vpn-health.sh`
  → hard fail, Kuma reddens, ntfy fires. Re-run clean to clear.
- **Test the soft path**: `sudo MAX_STRIKES=1 /usr/local/bin/servarr-vpn-health.sh`
  while the forwarded port is 0 → escalates immediately instead of after 6.
  Reset afterwards with
  `sudo rm -f /var/lib/servarr-vpn-health/degraded.strikes`.

- **Test** the failure path without touching the mount:
  `sudo MIN_GIB=99999 /usr/local/bin/media-mount-health.sh` → pushes `down`,
  Kuma reddens, ntfy fires; re-run without the override to clear.
