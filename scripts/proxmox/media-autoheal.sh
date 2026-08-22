#!/usr/bin/env bash
# media-autoheal.sh — re-mount the media USB disk after a bus re-enumeration
#                     and refresh its NFS export.
#
# See docs/proposals/005-nfs-media-share.md (supersedes the VM-restart half of
# proposal 004: ciri consumes this disk over NFS now, and NFS clients recover
# on their own once the export is back — no VM restart, ever).
#
# What it does (idempotent — safe to run at any time, by hand or from udev)
#   1. Exit immediately if /mnt/media is mounted AND readable
#   2. Lazily unmount a mounted-but-DEAD /mnt/media (readdir returns EIO)
#   3. systemctl start mnt-media.mount  — systemd-fsck runs as its passno-2
#      dependency, so boot and repair share one code path
#   4. exportfs -ra — re-evaluates the `mountpoint`-guarded export against the
#      fresh mount so nfsd serves the real filesystem again
#   5. Notify ntfy on every repair, give-up and refusal
#
# Deliberately NOT done
#   - Never mounts anything at a path other than $MEDIA_DIR.
#   - Never fscks by hand — the mount unit's dependency owns that.
#   - No rate limiting: remount+re-export is cheap and safe on every flap.
#     (004 rate-limited VM restarts; there are none here.)
#
# Requires: findmnt + flock (util-linux), exportfs (nfs-kernel-server), curl,
#           /etc/ntfy.topic (mode 600).
# Env overrides: MEDIA_DIR, SENTINEL, HEALTH_FILE

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly MOUNT_UNIT="mnt-media.mount"
readonly DEV_LINK="/dev/disk/by-label/media"
# Child that exists only on the real media filesystem — separates "mounted"
# from "mounted but empty" and from an empty stand-in dir on pve-root.
readonly SENTINEL="${SENTINEL:-library}"
# Byte-read target for the O_DIRECT liveness probe below. Same file both Kuma
# health scripts read; it lives on the media filesystem itself.
readonly HEALTH_FILE="${HEALTH_FILE:-$MEDIA_DIR/$SENTINEL/.mount-health}"
readonly LOCK="/run/media-autoheal.lock"
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
# Liveness probe. Two stages, and BOTH are load-bearing:
#
#   readdir  — catches "mounted, but the wrong/empty filesystem". stat/df pass
#              against a shut-down ext4, so never "optimise" this into a -d test.
#   O_DIRECT — catches "mounted, right filesystem, but the backing store is GONE".
#              readdir ALONE IS NOT ENOUGH: a small, recently-accessed directory
#              is served entirely from the dentry cache and succeeds against a
#              dead device. Measured 2026-08-23 during the first live heal test:
#              the disk re-enumerated sdb -> sdc, /mnt/media was still the dead
#              sdb1 (mount option `shutdown`), and on that same corpse
#                  ls -1 /mnt/media/library            -> 3 entries, exit 0
#                  dd iflag=direct .../.mount-health   -> EIO,       exit 1
#              so this function returned true and autoheal exited "nothing to
#              heal" while the export served a dead filesystem. O_DIRECT bypasses
#              the page cache and is the only probe that actually reaches the
#              disk — it is what media-mount-health.sh and media-export-health.sh
#              have always used, and autoheal must not be weaker than its monitors.
#
# `timeout` bounds both: against a wedged device these can block indefinitely.
is_readable() {
  timeout 10 ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1 || return 1
  timeout 10 dd if="$HEALTH_FILE" of=/dev/null bs=4096 count=1 iflag=direct \
    >/dev/null 2>&1
}

wait_for_device() {
  local waited=0
  while (( waited < 30 )); do
    [[ -e "$DEV_LINK" ]] && return 0
    sleep 1
    (( waited++ ))
  done
  return 1
}

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
    # mount. Lazy detach — nfsd/clients may still hold references and a plain
    # umount would return EBUSY.
    log "$MEDIA_DIR is mounted but not readable — detaching the dead mount"
    umount -l "$MEDIA_DIR" || err "lazy umount of $MEDIA_DIR failed — continuing"
  fi

  if ! wait_for_device; then
    err "$DEV_LINK never appeared — the disk is not on the bus"
    notify "media disk absent" "high" \
      "$DEV_LINK did not appear within 30 s. $MEDIA_DIR is DOWN and cannot be healed automatically — check the USB cable on geralt. NFS clients on ciri are blocked until it returns."
    exit 1
  fi

  log "starting $MOUNT_UNIT"
  if ! systemctl start "$MOUNT_UNIT"; then
    err "$MOUNT_UNIT failed to start"
    notify "media remount FAILED" "urgent" \
      "$MOUNT_UNIT failed to start on geralt. Check 'systemctl status $MOUNT_UNIT' and 'journalctl -u systemd-fsck@*' — fsck may need a manual run. NFS clients on ciri are blocked until this is fixed."
    exit 1
  fi

  if ! is_readable; then
    err "$MEDIA_DIR mounted but $SENTINEL still unreadable"
    notify "media remount incomplete" "urgent" \
      "$MEDIA_DIR mounted on geralt but $SENTINEL is still unreadable. Manual investigation needed."
    exit 1
  fi
  log "$MEDIA_DIR remounted and readable"

  # Host mount is healed; refresh the export table so the `mountpoint`-guarded
  # export is re-evaluated against the fresh mount. Clients (hard mounts)
  # recover on their own from here.
  if ! exportfs -ra; then
    err "exportfs -ra failed"
    notify "media export refresh FAILED" "urgent" \
      "$MEDIA_DIR was remounted on geralt but 'exportfs -ra' failed — ciri's NFS clients may stay blocked. Check 'exportfs -v' and 'systemctl status nfs-server'."
    exit 1
  fi

  log "export refreshed — media path healed end to end"
  notify "media mount healed" "default" \
    "The media disk dropped off the bus on geralt and was automatically remounted and re-exported; NFS clients on ciri recover on their own. No action needed — but a repeat means the USB cable wants checking."
}

main "$@"
