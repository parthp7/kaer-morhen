# Proposal 004 — Self-healing media mount

- **Status**: **SUPERSEDED by [proposal 005](005-nfs-media-share.md), never
  implemented.** Nothing in this document was ever deployed, and it should not
  be. Kept for the incident analysis and the design reasoning, not as a plan.
- **Why it was dropped (2026-08-22 → deployed 2026-08-23)**: this proposal
  automates the outage instead of removing it. Its central move — cold-restart
  ciri so virtiofsd re-resolves `--shared-dir` — cycles all ~20 containers,
  Immich and Paperless included, to heal a share only the media stack uses.
  005 moved `/mnt/media` to **NFS**, where the client holds a network handle
  rather than a pinned inode, so the repair is host-side only and **no VM
  restart is needed at all**. Measured on a live fault injection 2026-08-23:
  13 s to heal, ciri's uptime unbroken, zero container restarts.
- **What survived into 005**: the udev rule and the oneshot service unit,
  essentially unchanged. What died with virtiofs: the `qm stop`/`qm start`
  calls, `vm_running`, and the entire restart-budget/rate-limiting apparatus —
  all of which existed only because restarting a VM is expensive and dangerous.
  A remount plus `exportfs -ra` is neither. §5 (Kuma `resend_interval`) was
  carried forward unchanged and is still outstanding for ~29 monitors.
- **⚠️ The script in §3 contains a silent-failure bug — do not resurrect it.**
  `is_readable()` probes with a readdir, on the stated assumption that "readdir
  is the only probe that reaches the backing store." That is **false**: a small,
  recently-accessed directory is served entirely from the dentry cache and
  succeeds against a shut-down ext4. Observed for real on 2026-08-23, when the
  identical function in 005's script reported *"nothing to heal"* against a dead
  filesystem while both Kuma monitors correctly flagged it via `O_DIRECT`. Had
  004 been deployed, **its VM restart would never have fired** — the exact
  outage class it was written to fix. The fix is in
  [`scripts/proxmox/media-autoheal.sh`](../../scripts/proxmox/media-autoheal.sh):
  readdir **and** an `O_DIRECT` byte read, both under `timeout`.
- The [2026-08-10 / 22 incident](../storage.md#incident-2026-08-10--22--usb-link-fault-12-day-silent-outage)
  was recovered by hand; this proposal was about making the *next* one recover
  itself. [005](005-nfs-media-share.md) does that, better.
- **Date**: 2026-08-22
- **Scope**: `geralt` only — one script, one systemd unit, one udev rule, plus a
  Uptime-Kuma settings change on LXC 104 (§5). No changes to `ciri`, no changes
  to any compose stack, no new guests, no hardware.
- **Closes**: the "auto-remount on re-enumeration" item filed in the
  [2026-08-03 RCA](../storage.md#fixes-and-which-failure-each-one-answers) and
  never implemented — whose absence *is* the reason 2026-08-10 ran for 12 days.

Addresses use the `<LAN_PREFIX>` placeholder per `CLAUDE.md`. The ntfy topic is a
credential and stays in `/etc/ntfy.topic` (mode 600) and `secrets.local.yaml`.

## 1. The problem

The media disk is external USB and drops off the bus periodically. Three
incidents so far ([07-27](../storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem),
[08-03](../storage.md#incident-2026-08-03--usb-bus-drop-under-sustained-write-smr),
[08-10](../storage.md#incident-2026-08-10--22--usb-link-fault-12-day-silent-outage)).
The drop itself is survivable and always has been. What is not survivable is
what happens next:

**A one-shot mount unit never re-arms.** `mnt-media.mount` is generated from
`/etc/fstab`. On device loss systemd deactivates it. The disk re-enumerates
seconds later under a **new kernel name** (`sdb` → `sdc`), and nothing Wants the
mount any more because `local-fs.target` settled long ago. The disk then sits
present, healthy and unmounted for as long as nobody looks — **12 days**, on
2026-08-10.

**virtiofsd pins the inode.** Even a perfect host remount does not heal the
guest. `virtiofsd` resolves `--shared-dir` **once**, at VM start, and holds that
inode for the life of the process. A running `ciri` keeps being served the dead
pre-drop filesystem no matter what geralt does. Only a cold VM restart
re-resolves it. This has been true and documented since 07-27; the hookscript
header says so in as many words.

So the full repair is **two steps that must happen in order**, and today both are
manual:

```
host: fsck + mount /mnt/media          # nothing triggers this
then: qm stop 150 && qm start 150      # nothing triggers this either
```

### What the existing mitigations do and do not cover

| Existing | Covers | Does not cover |
|---|---|---|
| fstab `x-systemd.before=pve-guests.service` | boot **ordering** | anything that happens while the machine is up. Did not apply on 08-03 or 08-10 |
| [`vm150-require-virtiofs.sh`](../../scripts/proxmox/vm150-require-virtiofs.sh) | VM `pre-start` — refuses to start ciri onto a bad share | the VM is **already running** when the disk drops. Only helps *if* a human restarts it |
| [`media-mount-health.sh`](../../scripts/monitoring/media-mount-health.sh) | **detection** — caught 08-10 in 10 seconds | it detects, it does not repair. And see §5 |

Detection is solved. Repair is not.

## 2. Proposed design

A udev rule that fires when the media filesystem **re-appears**, starting a
oneshot systemd service that performs both halves of the repair.

```
USB re-enumeration
  → udev ACTION=="add", ID_FS_LABEL=="media"
    → SYSTEMD_WANTS=media-autoheal.service
      → media-autoheal.sh
          1. mounted AND readable?            → exit, nothing to heal
          2. mounted but dead (readdir EIO)?  → umount -l
          3. systemctl start mnt-media.mount  → fsck runs as its dependency
          4. mounted a fs AND VM 150 running? → qm stop 150 && qm start 150
          5. ntfy on every repair / refusal / failure
```

### Design decisions, and why

| Decision | Why |
|---|---|
| Match on ext4 **LABEL**, not a kernel name | the name changing (`sdb`→`sdc`) is the entire failure mode. Label is also what `/etc/fstab` keys on, so the two cannot drift apart |
| `ENV{SYSTEMD_WANTS}`, not `RUN+=` | the repair includes a VM stop+start that runs for minutes — far past udev's event timeout. udev only asks systemd to start the unit and returns immediately |
| `systemctl start mnt-media.mount`, not `mount` | systemd owns the mount, so there is no double-mount race against `local-fs.target` at boot, and `systemd-fsck` runs automatically as the passno-2 dependency. **Boot and repair share one code path** |
| `readdir` as the liveness probe, never `stat`/`df` | those pass against a shut-down ext4 — `df` still reported 916 G throughout 08-10. The lesson of 08-03, and the reason `media-mount-health.sh` checks 4/5 exist |
| Cold `qm stop` + `qm start`, never `qm reboot` | `qm reboot` hits a virtiofsd socket re-bind race on this VM; the first start fails roughly half the time (observed 08-03 15:40 and 08-04 00:06). Documented in storage.md |

### Guard rails

A script that restarts a VM by itself needs to be hard to misfire. All of these
are deliberate:

| Guard | Failure it prevents |
|---|---|
| `flock` on `/run/media-autoheal.lock` | udev fires repeatedly during a re-enumeration; losers exit quietly rather than queue behind a restart that already fixed things |
| Max **3 VM restarts per hour**, then alert and stop | a flapping bus — **2026-08-15 was 4 re-enumerations in 20 seconds** — must not become a VM-restart loop |
| Never **starts** a stopped VM 150 | a stopped VM is somebody's decision, not a fault to correct |
| Only restarts the VM if a mount was **actually performed** | a spurious udev event on an already-healthy system does nothing |
| `StartLimitBurst=5` on the unit | belt and braces above the flock, at the systemd layer |
| ntfy on repair, refusal *and* failure | a self-healing system that heals silently is one that hides a degrading cable |

### What this deliberately does not do

- **It does not stop the drops.** It shortens the outage from days to about a
  minute. The trigger is a physical USB link fault (§4 of the incident) and the
  fix for that is a cable, not a script.
- **It does not remove the virtiofs pinning constraint** — it just automates
  living with it. **NFS instead of virtiofs** would remove the constraint itself:
  an NFS client recovers on its own with no VM restart at all. Still the better
  long-term answer, still filed as future work, still not scoped here.

## 3. Implementation

Three files. Proposed home: `scripts/proxmox/`. Not yet written there — the repo
holds as-built material, and this is not built.

### `media-autoheal.sh` → `/usr/local/sbin/` (0755)

```bash
#!/usr/bin/env bash
# media-autoheal.sh — re-mount the media USB disk after a bus re-enumeration,
#                     and re-attach ciri (VM 150) to the new inode.
#
# See docs/proposals/004-media-mount-self-healing.md for the full rationale.
#
# What it does (idempotent — safe to run at any time, by hand or from udev)
#   1. Exit immediately if /mnt/media is mounted AND readable
#   2. Lazily unmount a mounted-but-DEAD /mnt/media (readdir returns EIO)
#   3. systemctl start mnt-media.mount  — systemd-fsck runs as its passno-2
#      dependency, so boot and repair share one code path
#   4. Only if a mount was actually performed, and VM 150 is already running:
#      qm stop 150 && qm start 150   (never `qm reboot` — socket race)
#   5. Notify ntfy on every repair, give-up and refusal
#
# Deliberately NOT done
#   - Never STARTS a stopped VM 150. A stopped VM is somebody's decision.
#   - Never mounts anything at a path other than $MEDIA_DIR.
#   - Never fscks by hand — the mount unit's dependency owns that.
#   - Never restarts the VM more than $MAX_RESTARTS times per $RESTART_WINDOW.
#
# Requires: findmnt + flock (util-linux), qm (pve-manager), curl,
#           /etc/ntfy.topic (mode 600).
# Env overrides: MEDIA_DIR, SENTINEL, VMID, MAX_RESTARTS, RESTART_WINDOW

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly MOUNT_UNIT="mnt-media.mount"
readonly DEV_LINK="/dev/disk/by-label/media"
# Child that exists only on the real media filesystem — separates "mounted"
# from "mounted but empty" and from an empty stand-in dir on pve-root.
readonly SENTINEL="${SENTINEL:-library}"
readonly VMID="${VMID:-150}"
readonly LOCK="/run/media-autoheal.lock"
readonly STATE_DIR="/var/lib/media-autoheal"
readonly RESTART_LOG="$STATE_DIR/vm-restarts"
# 3 VM restarts per hour. Above this the bus is flapping, not glitching, and a
# human needs to look at the cable rather than have the VM cycled underneath them.
readonly MAX_RESTARTS="${MAX_RESTARTS:-3}"
readonly RESTART_WINDOW="${RESTART_WINDOW:-3600}"
readonly NTFY_TOPIC_FILE="/etc/ntfy.topic"

log() { echo "media-autoheal: $*"; }
err() { echo "media-autoheal: $*" >&2; }

# Alerting must never change the repair's outcome: a dead ntfy is a different
# fault from a dead media disk.
notify() {
  local title=$1 prio=$2 body=$3 topic
  [[ -r "$NTFY_TOPIC_FILE" ]] || { err "no $NTFY_TOPIC_FILE — not notifying"; return 0; }
  topic=$(< "$NTFY_TOPIC_FILE"); topic=${topic//[$'\t\r\n ']/}
  [[ -n "$topic" ]] || return 0
  curl -fsS --max-time 10 --retry 2 --retry-delay 3 \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: floppy_disk" \
    -d "$body" "https://ntfy.sh/${topic}" >/dev/null \
    || err "ntfy push failed (message was: $title — $body)"
}

is_mounted()  { findmnt --noheadings --first-only --mountpoint "$MEDIA_DIR" >/dev/null 2>&1; }
# readdir is the only probe that reaches the backing store. stat/df are served
# from cached dentries and a pinned inode, and pass against a shut-down ext4 —
# the whole lesson of 2026-08-03. Do not "optimise" this into a -d test.
is_readable() { ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1; }

wait_for_device() {
  local waited=0
  while (( waited < 30 )); do
    [[ -e "$DEV_LINK" ]] && return 0
    sleep 1
    (( waited++ ))
  done
  return 1
}

# Sliding-window rate limit on VM restarts. Keeps only in-window timestamps so
# the file cannot grow without bound.
restart_budget_ok() {
  local now cutoff kept=()
  now=$(date +%s); cutoff=$(( now - RESTART_WINDOW ))
  mkdir -p "$STATE_DIR"
  if [[ -f "$RESTART_LOG" ]]; then
    local ts
    while read -r ts; do
      [[ "$ts" =~ ^[0-9]+$ ]] && (( ts > cutoff )) && kept+=("$ts")
    done < "$RESTART_LOG"
  fi
  if (( ${#kept[@]} >= MAX_RESTARTS )); then
    printf '%s\n' "${kept[@]}" > "$RESTART_LOG"
    return 1
  fi
  kept+=("$now")
  printf '%s\n' "${kept[@]}" > "$RESTART_LOG"
  return 0
}

vm_running() { [[ "$(qm status "$VMID" 2>/dev/null)" == "status: running" ]]; }

main() {
  # udev can fire this several times in seconds while a bridge re-enumerates.
  # Serialise, and let the losers exit quietly.
  exec 9>"$LOCK"
  flock -n 9 || { log "another run holds $LOCK — nothing to do"; exit 0; }

  if is_mounted && is_readable; then
    log "$MEDIA_DIR is mounted and readable — nothing to heal"
    exit 0
  fi

  if is_mounted; then
    # Mounted but readdir fails: the backing device went away under a live
    # mount. Lazy detach — virtiofsd still holds references and a plain umount
    # would return EBUSY.
    log "$MEDIA_DIR is mounted but not readable — detaching the dead mount"
    umount -l "$MEDIA_DIR" || err "lazy umount of $MEDIA_DIR failed — continuing"
  fi

  if ! wait_for_device; then
    err "$DEV_LINK never appeared — the disk is not on the bus"
    notify "media disk absent" "high" \
      "$DEV_LINK did not appear within 30 s. $MEDIA_DIR is DOWN and cannot be healed automatically — check the USB cable on geralt."
    exit 1
  fi

  log "starting $MOUNT_UNIT"
  if ! systemctl start "$MOUNT_UNIT"; then
    err "$MOUNT_UNIT failed to start"
    notify "media remount FAILED" "urgent" \
      "$MOUNT_UNIT failed to start on geralt. Check 'systemctl status $MOUNT_UNIT' and 'journalctl -u systemd-fsck@*' — fsck may need a manual run."
    exit 1
  fi

  if ! is_readable; then
    err "$MEDIA_DIR mounted but $SENTINEL still unreadable"
    notify "media remount incomplete" "urgent" \
      "$MEDIA_DIR mounted on geralt but $SENTINEL is still unreadable. Manual investigation needed."
    exit 1
  fi
  log "$MEDIA_DIR remounted and readable"

  # Host is healed. ciri is not: its virtiofsd still points at the inode that
  # died. Only a cold restart re-resolves --shared-dir.
  if ! vm_running; then
    log "VM $VMID is not running — leaving it alone"
    notify "media disk remounted" "default" \
      "$MEDIA_DIR was remounted on geralt after a bus re-enumeration. VM $VMID was not running, so it was left stopped."
    exit 0
  fi

  if ! restart_budget_ok; then
    err "VM $VMID restart budget exhausted ($MAX_RESTARTS per $((RESTART_WINDOW/60)) min)"
    notify "media disk FLAPPING" "urgent" \
      "$MEDIA_DIR was remounted on geralt, but VM $VMID has already been restarted $MAX_RESTARTS times in $((RESTART_WINDOW/60)) minutes. Refusing to restart again — the USB bus is flapping. ciri is still serving a dead media mount; check the cable."
    exit 1
  fi

  log "restarting VM $VMID so virtiofsd re-resolves $MEDIA_DIR"
  if ! qm stop "$VMID"; then
    err "qm stop $VMID failed"
    notify "ciri restart FAILED" "urgent" \
      "$MEDIA_DIR was remounted on geralt but 'qm stop $VMID' failed. ciri is still serving a dead media mount."
    exit 1
  fi
  if ! qm start "$VMID"; then
    err "qm start $VMID failed"
    notify "ciri DOWN" "urgent" \
      "'qm stop $VMID' succeeded but 'qm start $VMID' FAILED on geralt. ciri is DOWN — start it by hand."
    exit 1
  fi

  log "VM $VMID restarted — media path healed end to end"
  notify "media mount healed" "default" \
    "The media disk dropped off the bus on geralt and was automatically remounted; ciri (VM $VMID) was restarted so virtiofsd re-resolved the share. No action needed — but a repeat means the USB cable wants checking."
}

main "$@"
```

### `media-autoheal.service` → `/etc/systemd/system/` (0644)

```ini
[Unit]
Description=Re-mount the media disk and re-attach ciri after a USB re-enumeration
# udev fires this repeatedly while a bridge re-enumerates. The script also takes
# a flock, but stopping systemd from queueing runs is cheaper than serialising
# them. Above the burst the script's own ntfy alert has already told someone.
StartLimitIntervalSec=1h
StartLimitBurst=5

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/media-autoheal.sh
# A VM stop+start is not quick, and the script must not be killed halfway
# through leaving ciri stopped.
TimeoutStartSec=600
```

### `99-media-autoheal.rules` → `/etc/udev/rules.d/` (0644)

```
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="media", ENV{ID_FS_TYPE}=="ext4", TAG+="systemd", ENV{SYSTEMD_WANTS}+="media-autoheal.service"
```

## 4. Deploy and test

```bash
# on geralt, as root, from scripts/proxmox/
install -m 0755 media-autoheal.sh       /usr/local/sbin/
install -m 0644 media-autoheal.service  /etc/systemd/system/
install -m 0644 99-media-autoheal.rules /etc/udev/rules.d/
systemctl daemon-reload && udevadm control --reload
```

**Test by unbinding the USB device**, not by pulling the cable — the same
`ACTION=="add"` path a real re-enumeration takes, without stressing a connector
that is already the prime suspect:

```bash
# resolve the USB path for the media disk (1-3 at time of writing)
readlink -f /sys/block/sdc/../..

echo -n '1-3' > /sys/bus/usb/drivers/usb/unbind   # disk disappears
echo -n '1-3' > /sys/bus/usb/drivers/usb/bind     # re-enumerates → rule fires
journalctl -u media-autoheal.service -f
```

Expected: mount returns, VM 150 stops and starts, one ntfy titled *media mount
healed*. Then confirm from ciri that `ls /mnt/media/library` enumerates.

**Also worth testing deliberately**, because these are the paths that matter when
it counts:

| Test | Expected |
|---|---|
| Run the script with everything healthy | exits immediately, "nothing to heal", no VM restart |
| Unbind/bind 4× rapidly | flock + budget hold; at most 3 restarts, then a *media disk FLAPPING* alert |
| Unbind, stop VM 150, bind | mounts, does **not** start the VM, sends the "left stopped" notice |

### Verified assumptions (read-only, on geralt, 2026-08-22)

The design rests on four facts, all checked before writing it:

| Assumption | Checked |
|---|---|
| udev exposes `ID_FS_LABEL=media`, `ID_FS_TYPE=ext4`, `SUBSYSTEM=block` on the partition | `udevadm info --query=property --name=/dev/sdc1` — all three present |
| the device already carries the `systemd` tag (so `SYSTEMD_WANTS` is honoured) | `CURRENT_TAGS=:systemd:` |
| `qm status 150` prints exactly `status: running` | confirmed — the script's parser depends on it |
| `/etc/ntfy.topic` (0600), `/usr/local/sbin`, `flock` all present on geralt | confirmed |

The script passes `shellcheck` clean and `bash -n`.

## 5. Companion fix: make the alert survive being ignored

Not strictly part of self-healing, but it comes from the same RCA and is
**unimplemented for the same reason**, so it belongs in the same decision.

**Every Uptime-Kuma monitor currently has `resend_interval = 0`** — notify once
on the down transition, then never again. On 2026-08-10 the push monitor detected
the fault in 10 seconds and Kuma fired exactly **one** ntfy, at 00:16 AM. It was
received. Nothing ever repeated it, and the outage ran 12 days.

Autoheal would have fixed that particular incident without anyone waking up — but
it explicitly cannot fix the class where the disk *does not come back*
(`media disk absent`, `media disk FLAPPING`, `ciri DOWN`). Those still depend
entirely on a notification landing. A single midnight buzz is not an alerting
strategy.

**Proposed**: set **Resend Notification if Down X times** to a 30–60 minute
equivalent on every monitor. In the UI this is per-monitor; there are 29
monitors, so it is a bulk edit or a one-off DB update on LXC 104.

Cheapest high-value change in the lab: one field, no new moving parts.

## 6. Alternatives considered

| Alternative | Why not |
|---|---|
| `x-systemd.automount` in fstab | autofs mounts **on access**, but virtiofsd already holds its fd and never re-traverses the automount point — so the guest is never healed. Solves the smaller half of the problem and adds a moving part |
| A polling timer instead of udev | works, but adds latency for no benefit and runs forever to catch a rare event. udev already knows the exact moment the disk returns |
| `RUN+=` directly in the udev rule | udev kills long-running event handlers; a VM stop+start is minutes. Would fail exactly when it mattered |
| Restart only the media containers on ciri, not the VM | cannot work — the stale inode is held by `virtiofsd` on the **host**, outside the guest entirely. No guest-side action can reattach it |
| Replace virtiofs with **NFS** | genuinely better: the client recovers on its own and no VM restart is ever needed. Larger change, touches every media stack, and deserves its own proposal. Filed as future work since 08-03 |

## 7. Risks

| Risk | Mitigation |
|---|---|
| A script restarts ciri unattended, interrupting Immich/Paperless/memos/sure | only fires when the media disk actually re-appears after a real drop, capped at 3/hour, and never on a healthy system. The alternative today is a 12-day outage |
| Restart loop on a flapping bus | flock + sliding-window budget + `StartLimitBurst`; past the cap it alerts and stops |
| `fsck` needs manual intervention and the mount fails | the script stops and sends an *urgent* ntfy rather than retrying |
| Masking a degrading cable by healing silently | every heal sends an ntfy saying a repeat means the cable wants checking. This is why the success path notifies at all |

## Follow-ups

- Move the three files into `scripts/proxmox/` and write them up in that
  directory's README **when deployed**, per the as-built convention.
- Fold the result into [storage.md](../storage.md) as a postscript on the
  2026-08-10 incident once it has caught a real drop.
- **Reseat or replace the USB cable first.** This proposal shortens outages; it
  does not stop them. The link has been running at **USB 2.0 since 2026-08-15**
  (`speed=480`), which is itself unresolved.
- Revisit **NFS instead of virtiofs** as the structural fix (§6).
