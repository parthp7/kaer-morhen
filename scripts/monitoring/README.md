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

If a faster cadence is ever wanted, 120 s is the sensible floor. Whatever the
timer uses, Kuma's **Heartbeat Interval** must match it or the monitor reddens
on schedule instead of on fault. Keep **Retries** at 1–2 so a single missed run
doesn't page but a genuine outage does.

- **Test** the failure path without touching the mount:
  `sudo MIN_GIB=99999 /usr/local/bin/media-mount-health.sh` → pushes `down`,
  Kuma reddens, ntfy fires; re-run without the override to clear.
