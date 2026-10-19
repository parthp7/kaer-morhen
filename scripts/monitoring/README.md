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
- **Since 2026-08-23 this is an NFS probe** ([proposal 005](../../docs/proposals/005-nfs-media-share.md)):
  expected fstype is `nfs4`, not `virtiofs`. Two consequences, both load-bearing:
  - `/mnt/media` is an `x-systemd.automount`, so mountinfo holds a **stacked
    pair** — systemd's `autofs` trigger *underneath* the real `nfs4` mount.
    `findmnt --first-only` returns `autofs`, a guaranteed false alarm; the
    script triggers the automount, then takes `tail -1` (top of the stack).
  - Every command that touches the mount is wrapped in `timeout 30`, **including
    the `[[ -d ]]` sentinel test**. Against a `hard` NFS mount a dead server
    *blocks* rather than erroring, and an unbounded probe would hang until
    systemd SIGKILLed the unit having pushed nothing — turning a precise
    `status=down` into mere heartbeat silence.
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

## media-export-health.sh

The **server-side** half of the media-path monitor, on geralt. `media-mount-health.sh`
on ciri sees the end-to-end truth but cannot say *where* a fault is; this one
proves geralt is serving the real disk, so a host-only fault (disk dropped, nfsd
dead, export vanished) is attributed correctly — and is still caught when ciri
itself is down.

Six checks, first failure wins:

1. `/mnt/media` is a mount point of type `ext4` (not the pve-root placeholder)
2. `library/` can be **enumerated** (readdir reaches the backing store)
3. `library/.mount-health` can be **read as bytes** — the same sentinel file the
   ciri monitor reads, so both halves agree on what "alive" means
4. `nfs-server.service` is active
5. the export table still lists `/mnt/media` — the `mountpoint` export option
   silently **drops** the export when the mount dies, so catch that explicitly
6. nfsd is listening on the storage IP's port 2049

- **Deployed to**: `/usr/local/bin/media-export-health.sh` on **geralt** (0755).
- **Reads** the push URL from `/etc/kuma-push.media-export` (mode 600); the URL
  lives only on geralt and in `secrets.local.yaml`.
- **No IP is hardcoded**: `NFS_BIND_IP` derives itself from `vmbr1`, so the repo
  copy and the deployed copy are byte-identical with nothing to mask.
- Same contract as `media-mount-health.sh`: push up/down with a reason, and exit
  non-zero on failure so `systemctl --failed` shows it host-side too.

### Two deployment traps, both learned the hard way

**Address Kuma by IP, never by name.** geralt resolves via the router and
*cannot* resolve `kaermorhen.internal` or the public domain — only the Pi-holes
hold those records. A name-based push URL fails every time, silently, because
`push()` deliberately swallows curl errors so a dead Kuma cannot corrupt the
check's verdict. This already cost a 10-day silent heartbeat loss in July; see
[docs/uptime-kuma.md](../../docs/uptime-kuma.md).

**Store the BARE base URL**, with no query string. The script appends its own
`status=`/`msg=` via `curl --get --data-urlencode`. A URL pasted from Kuma's UI
ends in `?status=up&msg=OK&ping=`, and curl would append after it — leaving two
`status` parameters, of which Kuma reads the **first**. The monitor would then
report `up` forever regardless of what the check found: a dead-man switch welded
shut, strictly worse than no monitor.

### Timer cadence — why `OnCalendar`, not `OnUnitActiveSec`

Kuma's push window is a hard deadline: a beat that is *ever* late reads as a
missed heartbeat. Two systemd defaults conspire against that:

- `OnUnitActiveSec=N` counts from the **last activation**, so the period is
  always ≥ N and the error accumulates.
- `AccuracySec` defaults to **1 min** — systemd may defer the wakeup that far to
  batch wakeups.

Measured 2026-08-23 with `OnUnitActiveSec=60`: intervals of **61, 72, 75, 90 s**
against a 60 s window — every single beat late. With `OnCalendar=*:*:0/30` plus
`AccuracySec=1s`: **30.0 s, no drift**, beats landing on exact `:00`/`:30`
boundaries. Push at roughly **half** the Kuma heartbeat interval so one dropped
push cannot trip the monitor.

Unit + timer are in this directory; deploy per
[proposal 005](../../docs/proposals/005-nfs-media-share.md) Phase A5.

## media-link-health.sh

The **third** media monitor on geralt, and the only one that is not a liveness
check. `media-mount-health.sh` and `media-export-health.sh` both answer "can I
read a byte right now?" — two faults on this disk were invisible to that question
for opposite reasons, and this script answers both.

**The drops were hidden by the fix for them.** Proposal 005's `media-autoheal.sh`
remounts and re-exports about 14 s after a USB re-enumeration. Between 2026-08-24
and 2026-09-02 it did that **54 times** and nobody noticed: every outage was
shorter than the monitors' probe interval, so both stayed green throughout. The
08-10 fault ran 12 days and was impossible to ignore; this one fired every few
hours and produced no signal a human acted on. *An auto-healer that hides a fault
must be paired with something that counts it.*

**The link quietly fell back to USB 2.0 and stayed there.** On 2026-08-15 the
bridge re-enumerated at 480 Mb/s instead of 5000, and `max_sectors_kb` fell
1024 → 120 with it. Nothing was down, so nothing alerted — for **eighteen days**,
until it starved Jellyfin off the disk on 2026-09-02 while `ls`, `df` and a cached
`dd` all still returned at ~3 GB/s. Speed is not liveness, and no liveness check
can see this.

Four checks, first failure wins:

1. the disk is present — resolvable via `/dev/disk/by-label/media`
2. its USB link is **SuperSpeed** (`speed` ≥ `MIN_SPEED`, default 5000) — 08-15
3. `max_sectors_kb` ≥ `MIN_SECTORS_KB` (default 1024) — the quiet half of 08-15
4. `USB disconnect` events on the disk's port ≤ `DROP_MAX` (default **0**) in a
   rolling `WINDOW_H` (default **24**) hours

- **Deployed to**: `/usr/local/bin/media-link-health.sh` on **geralt** (0755),
  push URL in `/etc/kuma-push.media-link` (mode 600).
- **Timer every 5 min**, Kuma heartbeat **600 s** — the same "push at half the
  heartbeat" rule and the same `OnCalendar` + `AccuracySec=1s` drift fix as
  `media-export-health`. Set `resend_interval` to 60 min: a monitor that reports
  a *rate* is worthless if it notifies once and goes quiet, which is the 08-10
  lesson.
- Both Kuma deployment traps above (**address by IP**, **store the bare base
  URL**) apply verbatim.

### Why it does not check the mount

Because `media-export-health.sh` already does, and one fault firing two red
monitors teaches you to ignore one of them. This script is scoped to what the
others structurally cannot see: **degraded-but-up**, and **broken-then-repaired**.

### Why `DROP_MAX=0`, and when to raise it

Any drop inside 24 h turns the monitor red. That is deliberate — the whole
finding of 2026-09-02 is that a self-healed 14 s drop is still a hardware fault,
and 54 of them is a trend. Two consequences to know before it surprises you:

- **A deliberate reseat counts.** Unplugging the drive shows up as a drop and the
  monitor stays red for the rest of the window. Per the 08-03 standing lesson —
  *this disk is hand-portable; check physical handling before counting a drop as
  a hardware trend* — that is the right default, not a bug.
- **Raise `DROP_MAX` only to ride out a known-bad phase**, and lower it back
  afterwards. A threshold set high enough never to fire is the same as no
  monitor.

### How the port is matched, and why not `/dev/sdX`

The disk has walked `sdb → sdm → sdn → sdp → sdq → sdv → sdb` across
re-enumerations, so the kernel name is meaningless between drops. The script
resolves the label to its block device, walks up `/sys` to the USB device node
that owns it, and derives the port from there (`2-3`). The **bus** number changes
when the link renegotiates — it was `1-3` at 480 Mb/s and `2-3` at 5000 — so the
match is `usb [0-9]+-3: USB disconnect`: pin the port, let the bus float.

Counting uses `journalctl --since … _TRANSPORT=kernel`, not `journalctl -k` and
not `dmesg`:

- **`-k` implies `-b`**, which would silently scope a rolling 24 h window to the
  current boot.
- **`dmesg` wraps.** Measured 2026-09-04 on an 11-day uptime: `dmesg` reported 58
  disconnects where the journal held 59. The check originally written into
  storage.md — `dmesg -T | grep -c "USB disconnect"` against uptime — undercounts
  exactly when the history matters most. Persistent journald (`/var/log/journal`)
  is therefore a requirement, not a nicety.

The `ok` message carries the count even when green (`0 drop(s) in 23.4/24 h`), so
Kuma's history shows the trend rather than only the exceedances. The second
number is how much of the window the journal can actually speak for — after a
reboot it is smaller than `WINDOW_H`, and "0 drops" means less.

### Verified before deploying (2026-09-04)

Every branch exercised against the live host by piping the script over `ssh`, so
nothing was installed until all five verdicts were seen:

```bash
# pass
ssh lab-geralt 'bash -s' < media-link-health.sh
# → ok: 5000M on 2-3, max_sectors_kb 1024, 0 drop(s) in 23.4/24 h        exit 0
# drop threshold — 48 h reaches back past the connector swap and its one drop
ssh lab-geralt 'WINDOW_H=48 bash -s' < media-link-health.sh
# → FAIL — 2 USB drop(s) on port 2-3 in the last 48 h (max 0)            exit 1
ssh lab-geralt 'WINDOW_H=48 DROP_MAX=5 bash -s' < media-link-health.sh   # exit 0
# link degraded / transfers capped / disk gone
ssh lab-geralt 'MIN_SPEED=10000 bash -s'      < media-link-health.sh     # exit 1
ssh lab-geralt 'MIN_SECTORS_KB=2048 bash -s'  < media-link-health.sh     # exit 1
ssh lab-geralt 'MEDIA_LABEL=nosuchlabel bash -s' < media-link-health.sh  # exit 1
```

`push()` swallows a missing URL file with a warning, so a dry run like this
cannot corrupt a live monitor's state.

Background: [docs/storage.md](../../docs/storage.md), incidents 2026-08-10/22 and
2026-09-02, and the 2026-09-04 postscript that this monitor came out of.

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
API unreachable; port forwarding EXITED. **Soft** (green, reason in the heartbeat
log): qBit's external address ≠ the tunnel's (a *stranded* client); forwarded port
`0`; forwarded port ≠ qBit's `listen_port`; or the egress comparison being
unverifiable — all escalate to red after `MAX_STRIKES` (default 10 at the 3-min
timer, ≈30 min) consecutive runs. Three of these are **auto-fixed** — see
[Auto-fix](#auto-fix-servarr-vpn-remediatesh-added-2026-10-20) below.

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
- **Fails closed**: if a lookup breaks, the run is never a clean green. A broken
  netns probe is a hard failure; an unverifiable host-IP comparison is *soft*
  (degraded, escalating through the strike counter) so an ipify outage cannot
  fake a leak. "Cannot determine" is never "fine".

Unit + timer on ciri: [`servarr-vpn-health.service`](servarr-vpn-health.service)
and [`servarr-vpn-health.timer`](servarr-vpn-health.timer) in this directory,
installed verbatim to `/etc/systemd/system/`. The `Type=oneshot` timeout argument
from media-mount applies identically here, and more so, because this script
makes network calls that can hang.

`TimeoutStartSec` is set directly in the unit here rather than as a drop-in,
because unlike media-mount this script was written with it from the start. It
must exceed the internal network timeouts: checks are 10 + 15 + 10 + 10 + 10 =
55 s worst case, and the retrying push adds up to 36 s more — 91 s total, so the
original `90` was under the line by a second. **150** leaves real margin.

**The timer is `OnCalendar=*:0/3` + `AccuracySec=1s`** (since 2026-10-20; it was
`OnUnitActiveSec=5min` + `AccuracySec=30s`). Same lesson as
[media-export-health](#timer-cadence--why-oncalendar-not-onunitactivesec), learned
a second time. From 2026-09-01 to 10-19, **401 of 13,835 push gaps exceeded the
360 s Kuma window** (max 394 s). Every Kuma alert on this monitor in October read
`No heartbeat in the time window`, and most recovered on the very next push with
`ok`. They were late beats, not faults. They also hid the real faults: when a
stranded client began, Kuma was often already red from a late beat, so the
reason never reached ntfy. Pushing every 180 s against a 360 s window means even
the worst case (180 s + a ~100 s run, the push lands at the end) is 280 s.
`MAX_STRIKES` went from 6 to 10 so escalation still takes ~30 min.

`OnBootSec=3min` (vs media-mount's 2 min) gives gluetun time to bring the tunnel
up after a reboot, so the first run isn't a spurious "no egress" alert.

Deploy:

```bash
sudo install -m 0755 servarr-vpn-health.sh servarr-vpn-remediate.sh /usr/local/bin/
sudo install -m 0644 servarr-vpn-health.service servarr-vpn-health.timer \
  'servarr-vpn-remediate@.service' /etc/systemd/system/
printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.servarr-vpn >/dev/null
sudo chmod 600 /etc/kuma-push.servarr-vpn
printf '%s\n' '<NTFY_TOPIC>' | sudo tee /etc/ntfy.topic >/dev/null
sudo chmod 600 /etc/ntfy.topic
sudo systemctl daemon-reload && sudo systemctl enable --now servarr-vpn-health.timer
sudo systemctl restart servarr-vpn-health.timer   # pick up a changed schedule
journalctl -u servarr-vpn-health.service -n 10 --no-pager
```

Kuma monitor: **Push**, name `servarr vpn health`, Heartbeat Interval **360 s**,
Retries **1** — twice the 180 s push period; see the heartbeat-interval note
above. Strip the `?status=up&msg=OK&ping=` query string from the URL
Kuma displays — the script appends its own parameters.

### Auto-fix: `servarr-vpn-remediate.sh` (added 2026-10-20)

The health check always knew the cure for its recurring verdicts and printed it
in the alert. Nothing applied it. A **stranded** client (qBit's external
address ≠ the tunnel's) followed gluetun's own tunnel restarts every few days and
**never cleared on its own**: ~15 h on 2026-10-11 and ~49 h on 2026-10-17, each
time until someone restarted it by hand. qBit's log confirmed the 10-17 one was
real, with no `Detected external IP` for the whole 49 h.

Now, *after* its push, the health script starts
`servarr-vpn-remediate@<action>.service` with `--no-block`. The ladder runs in
its own unit, so it can never delay a heartbeat.

| Verdict | Triggers after | Action | What it restarts, in order |
|---|---|---|---|
| `stranded` | 3 consecutive runs (~9 min) | `client` | qbittorrent → wait for API → qbit-port-sync → wait for port match |
| port ≠ `listen_port` | 3 consecutive runs | `sync` | qbit-port-sync → wait for port match |
| PF **EXITED** | first run | `full` | gluetun → wait healthy + egress + port ≠ 0 → then `client` |
| leak, no egress, `tun0` missing, API/ctl unreachable, PF 0 retrying, unverifiable | never | — | page only |

- **Each wait polls real state** against a wall-clock deadline (90 s, 180 s for
  gluetun), not a fixed sleep. Then it **verifies** with
  `servarr-vpn-health.sh --dry-run`, which must say `ok:`. Exit 0 alone is not
  enough, because a degraded run below `MAX_STRIKES` also exits 0. If `sync` or
  `client` fails, it escalates once to `full`.
- **Per-reason counter** (`reason` + `reason.count` in the state dir) next to the
  shared strike counter. A hard fail between two stranded runs neither resets nor
  bumps it, because gluetun's reconnects (`no egress`) interleaved with the
  stranded runs on both 10-11 and 10-17. Retries every 20 runs (~1 h) while the
  verdict persists.
- **Guard rails**: qBittorrent's bind sources (`/mnt/media/downloads`,
  `/mnt/torrents/incomplete`) must be reachable first, under `timeout 30`,
  because its `create_host_path:false` guards would otherwise turn a degraded
  client into one that won't start. At most **3 runs per 6 h**
  (`remediate.log`); past that, one ntfy saying it gave up, and paging takes
  over. `flock -n`, so one ladder runs at a time. Leaves `manga-gluetun` alone.
- **One ntfy per run** with the steps and the outcome, via `/etc/ntfy.topic` on
  ciri (new; same 0600 convention as the nodes). A successful fix usually lands
  before the monitor escalates, so Kuma may never go red. The ntfy is the only
  sign it happened.
- `REMEDIATE=0` in the health script's environment disables the trigger.

Tests:

- **Dry-run the ladder** (prints every step, restarts nothing):
  `sudo servarr-vpn-remediate.sh --dry-run client`
- **End-to-end on the stranded path**. This really restarts qbittorrent and
  qbit-port-sync, a ~1 min torrent pause. Fake a stranded client three times
  within one timer period:
  ```bash
  for i in 1 2 3; do sudo QBIT_IP_OVERRIDE=192.0.2.1 /usr/local/bin/servarr-vpn-health.sh; done
  journalctl -u 'servarr-vpn-remediate@*' -n 20 --no-pager
  ```
  → the third run starts `remediate@client`. Expect restart → waits → `verified: ok:`,
  an ntfy "servarr auto-fixed (client)", and `reason.count` / `degraded.strikes` back to 0.
  A timer run landing between the three resets the count, so just run it again.

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
  while the forwarded port is 0 → escalates immediately instead of after 10.
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

### `set -o pipefail` + `grep -q` = false failure (fixed 2026-08-05)

The first deploy failed its smoke test with `h264_nvenc missing from ffmpeg …`
for an encoder that was demonstrably present. The check was:

```bash
if ! … docker exec jellyfin "$FFMPEG_BIN" -hide_banner -encoders 2>/dev/null | grep -q h264_nvenc
```

Measured on ciri:

| | exit |
|---|---|
| `set -o pipefail` + `grep -q` | **141** (128+13, SIGPIPE) |
| same pipeline without `pipefail` | 0 |
| `h264_nvenc` in the output? | yes — 1 match in 227 lines |

`grep -q` exits at the **first match** and closes the read end of the pipe.
ffmpeg is still enumerating (12.8 KB of output, emitted incrementally), its next
write hits a pipe with no reader, and it dies of SIGPIPE. `pipefail` then reports
the *pipeline* as failed even though grep succeeded. All lab scripts run
`set -euo pipefail`, so this is a trap for any of them.

Fixed by capturing the output and matching in-shell, which also separates
"ffmpeg would not run" from "the encoder is absent" — genuinely different faults:

```bash
if ! encoders=$(… docker exec … -encoders 2>/dev/null); then …; fi
if [[ "$encoders" != *h264_nvenc* ]]; then …; fi
```

**The sibling instance is safe, and it is worth knowing why.**
[`servarr-vpn-health.sh`](#servarr-vpn-healthsh) has the same shape at its
`tun0` check (`in_netns ip -o addr show tun0 | grep -q inet`) on a *hard* path.
It was measured, not assumed: the output is **93 bytes**, so `ip` writes
everything into the 64 KB pipe buffer and exits before `grep` ever closes it —
0 failures in 25 consecutive runs. Left as-is rather than churn a monitor that
is proven in production. The rule that separates the two cases: **piping to an
early-exiting reader is only safe when the writer's entire output fits the pipe
buffer and it exits promptly.** If the producer streams, capture instead.

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

### As-built (deployed 2026-08-05)

| Check | Value |
|---|---|
| `/usr/local/bin/gpu-health.sh` | 0755 root, md5 matches the repo copy byte-for-byte |
| `/etc/kuma-push.gpu-health` | `-rw------- root root` |
| `gpu-health.timer` | enabled, active; `OnBootSec=3min`, `OnUnitActiveSec=5min`, `AccuracyUSec=30s` |
| `TimeoutStartUSec` | `1min 30s` (the drop-in took) |
| `/var/lib/gpu-health/degraded.strikes` | `0` |
| Runs | all `ok: 'jellyfin' encoded on the GPU (h264_nvenc), 0MiB VRAM in use` |
| Push errors | none — no `push to Uptime-Kuma failed` in the journal |

**Measured timer period: 323 s**, against the 360 s heartbeat — consistent with
media-mount's historical 301–330 s, and the run itself takes ~1 s. That leaves
roughly 30 s of headroom, the same margin the other two Push monitors have run
with since 2026-07-29. Note this is a **single** timer-to-timer sample taken
minutes after deploy; if Kuma ever flaps red with the checks passing, re-measure
before assuming a real fault:

```bash
journalctl -u gpu-health.service -o short-unix | grep -a "Starting gpu-health" \
  | awk '{print int($1)}' | awk 'NR>1{print $1-p" s"} {p=$1}'
```

(A manual `systemctl start` resets `OnUnitActiveSec`, so it shows up as a short
bogus interval — ignore those when reading the output.)
