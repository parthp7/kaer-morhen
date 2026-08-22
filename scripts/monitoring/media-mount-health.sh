#!/usr/bin/env bash
# media-mount-health.sh — Uptime-Kuma push monitor: prove ciri sees the REAL media disk.
#
# Why this exists
#   2026-07-27: geralt rebooted; virtiofsd resolved its --shared-dir at 15:22:17,
#   mnt-media.mount completed at 15:22:19. virtiofsd pins that inode for the life
#   of the VM, so ciri was served the empty placeholder directory on pve-root —
#   a 68 GB filesystem where the 916 GB USB disk should have been.
#
#   Every Uptime-Kuma monitor and every Beszel panel stayed GREEN for ~16 hours.
#   Nothing was down: the containers were up and answering, just pointed at the
#   wrong filesystem. qBittorrent marked all 20 torrents missingFiles and Radarr
#   lost its root folder while the dashboards showed a healthy stack.
#
#   Liveness cannot see this class of failure. Size can — that is the whole idea
#   behind check 3 below.
#
# What it checks (in order; first failure wins)
#   1. $MEDIA_DIR is a real mount point of type virtiofs  — not a stray empty dir
#   2. $MEDIA_DIR/library exists                          — present only on the real disk
#   3. the filesystem is at least $MIN_GIB                — catches 2026-07-27 exactly:
#                                                           pve-root reports 68 G,
#                                                           the media disk 916 G
#   4. $MEDIA_DIR/library can be ENUMERATED (readdir)     — catches 2026-08-03
#   5. $HEALTH_FILE can be READ (bytes, not metadata)     — catches 2026-08-03
#
#   Checks 1-3 answer 2026-07-27 (wrong filesystem: wrong identity, wrong size).
#   Checks 4-5 answer 2026-08-03 (dead filesystem: RIGHT identity, RIGHT size).
#
#   2026-08-03: the USB disk dropped off the bus mid-write at 00:56:48; the host
#   unmounted it, but virtiofsd kept serving its pinned inode on a shut-down ext4.
#   This script pushed 166 CONSECUTIVE `ok` HEARTBEATS over 14 h 43 m while every
#   real read returned EIO — Jellyfin logged `Input/output error: '/media/movies'`
#   at 09:11 and Radarr lost its root folder, all while Kuma stayed green.
#
#   Why 1-3 all passed against a dead filesystem:
#     findmnt  → still `virtiofs`  (the guest mount never went away)
#
#   2026-08-23: media moved from virtiofs to NFS (proposal 005); same checks,
#   new fstype (nfs4, read from the TOP of the autofs+nfs4 stack), plus a
#   `timeout` on every command that touches the mount — a `hard` NFS mount
#   BLOCKS on a dead server rather than erroring, and hung must become "down".
#     -d test  → still succeeded   (virtiofsd's pinned fd + cached dentries)
#     df       → still 915 GiB     (statfs on the pinned inode returns the real
#                                   geometry of the detached filesystem)
#
#   So the old claim "check 3 is the load-bearing one" is FALSE for this failure
#   mode. Size cannot distinguish a live filesystem from a dead one — only an
#   actual read can. That is the entire point of checks 4 and 5; do not "optimise"
#   them back into stat() calls.
#
# Behaviour
#   All good      → push status=up   → Kuma heartbeat green
#   Check failed  → push status=down with the reason → Kuma red → ntfy, and exit 1
#                   so `systemctl --failed` shows it on the host too
#   Script/timer dead → no heartbeat at all → Kuma reddens on its own. The push
#                   monitor's silence is the backstop for this script failing.
#
# Usage
#   media-mount-health.sh        # no arguments; run from a systemd timer on ciri
#
# Deploy (on ciri) — see scripts/monitoring/README.md for the unit + timer
#   sudo install -m 0755 media-mount-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.media-mount >/dev/null
#   sudo chmod 600 /etc/kuma-push.media-mount
#
# Requires: curl, findmnt (util-linux), GNU df. The push URL carries a token, so
#           it lives ONLY in that 0600 file and in secrets.local.yaml — never here.
# Env overrides: MEDIA_DIR, MIN_GIB, KUMA_URL_FILE

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly EXPECTED_FSTYPE="nfs4"
readonly SENTINEL="library"
# 800 GiB: comfortably above the ~68 G placeholder and below the ~916 G real disk,
# with room for a future larger drive. Not a capacity check — a wrong-disk check.
readonly MIN_GIB="${MIN_GIB:-800}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.media-mount}"
# A small real file that exists ONLY on the media disk. Read for its bytes, not
# its metadata — see checks 4/5. Created once at deploy time:
#   dd if=/dev/urandom of=/mnt/media/library/.mount-health bs=4096 count=1
readonly HEALTH_FILE="${HEALTH_FILE:-$MEDIA_DIR/$SENTINEL/.mount-health}"

# Push a heartbeat to Kuma. A push failure is reported but must NOT change the
# verdict: "Kuma is unreachable" is a different fault from "the media disk is wrong".
push() {
  local status=$1 msg=$2 url
  if [[ ! -r "$KUMA_URL_FILE" ]]; then
    echo "media-mount-health: cannot read $KUMA_URL_FILE — not pushing" >&2
    return 0
  fi
  url=$(< "$KUMA_URL_FILE")
  url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "media-mount-health: $KUMA_URL_FILE is empty" >&2; return 0; }

  # --retry: a single dropped push is a missed heartbeat, and Kuma cannot tell that
  # apart from the media disk being gone. Observed for real 2026-07-29 22:21:43.
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" \
        --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "media-mount-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

check() {
  local fstype size_kb size_gib dd_err read_mode="O_DIRECT"

  # 1. Trigger the automount first (x-systemd.automount mounts on access), then
  #    read the TOP mount at this path. mountinfo holds a stacked pair here —
  #    systemd's `autofs` trigger underneath the real `nfs4` mount — and
  #    --first-only returns the autofs entry: a guaranteed false alarm. tail -1
  #    is the top of the stack. `timeout` because against a `hard` NFS mount a
  #    dead server BLOCKS instead of erroring — hung must become "down".
  #    --mountpoint still matches EXACTLY: --target would fall back to the parent
  #    mount and cheerfully report the root filesystem as if it were the media disk.
  timeout 30 ls "$MEDIA_DIR" >/dev/null 2>&1 || true
  fstype=$(findmnt --noheadings --output FSTYPE --mountpoint "$MEDIA_DIR" 2>/dev/null | tail -1)
  if [[ -z "$fstype" ]]; then
    echo "$MEDIA_DIR is not a mount point"
    return 1
  fi

  if [[ "$fstype" != "$EXPECTED_FSTYPE" ]]; then
    echo "$MEDIA_DIR is $fstype, expected $EXPECTED_FSTYPE"
    return 1
  fi

  # 2. Sentinel directory — exists only on the real media filesystem.
  #    `timeout` for the same reason as checks 1 and 3-5: a bare [[ -d ]] is a
  #    stat() that BLOCKS forever against a hard NFS mount whose server is gone,
  #    and the unit would be SIGKILLed by TimeoutStartSec having pushed nothing.
  if ! timeout 30 test -d "$MEDIA_DIR/$SENTINEL"; then
    echo "$MEDIA_DIR/$SENTINEL missing — wrong or empty filesystem"
    return 1
  fi

  # 3. Size — the check that actually catches a pinned placeholder.
  size_kb=$(timeout 30 df -Pk "$MEDIA_DIR" | awk 'NR==2 {print $2}')
  if [[ -z "$size_kb" || "$size_kb" != *[0-9]* ]]; then
    echo "could not read filesystem size for $MEDIA_DIR"
    return 1
  fi
  size_gib=$(( size_kb / 1024 / 1024 ))
  if (( size_gib < MIN_GIB )); then
    echo "$MEDIA_DIR is only ${size_gib}GiB, expected >=${MIN_GIB}GiB — virtiofs is serving the wrong directory"
    return 1
  fi

  # 4. Enumerate the directory. readdir must reach virtiofsd for any entry not
  #    already in the guest dentry cache, so it sees a dead backing store that
  #    stat() does not. On 2026-08-03 this is precisely what failed for Jellyfin
  #    (`Input/output error: '/media/movies'`) while checks 1-3 all still passed.
  if ! timeout 30 ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1; then
    echo "cannot enumerate $MEDIA_DIR/$SENTINEL — mounted but not readable (host mount likely dropped)"
    return 1
  fi

  # 5. Read actual bytes. O_DIRECT bypasses the guest page cache and forces the
  #    read through virtiofsd to the host filesystem — a cached page would
  #    otherwise mask a dead backing store. If the kernel rejects the flag itself
  #    (EINVAL, i.e. this virtiofs does not support O_DIRECT) fall back to a
  #    buffered read rather than raise a false alarm; the fallback is weaker
  #    because the page cache can serve it, hence check 4 is kept independent.
  if [[ ! -e "$HEALTH_FILE" ]]; then
    echo "$HEALTH_FILE missing — create it on the real disk: dd if=/dev/urandom of=$HEALTH_FILE bs=4096 count=1"
    return 1
  fi

  if ! dd_err=$(timeout 30 dd if="$HEALTH_FILE" of=/dev/null bs=4096 count=1 iflag=direct 2>&1); then
    if [[ "$dd_err" == *"Invalid argument"* ]]; then
      read_mode="buffered"
      if ! dd_err=$(timeout 30 dd if="$HEALTH_FILE" of=/dev/null bs=4096 count=1 2>&1); then
        echo "cannot read $HEALTH_FILE (buffered): ${dd_err%%$'\n'*}"
        return 1
      fi
    else
      echo "cannot read $HEALTH_FILE (O_DIRECT): ${dd_err%%$'\n'*}"
      return 1
    fi
  fi

  echo "ok: $MEDIA_DIR ${size_gib}GiB $fstype, $SENTINEL readable, bytes read ($read_mode)"
  return 0
}

main() {
  local detail
  if detail=$(check); then
    push "up" "$detail"
    echo "media-mount-health: $detail"
  else
    push "down" "$detail"
    echo "media-mount-health: FAIL — $detail" >&2
    exit 1
  fi
}

main "$@"
