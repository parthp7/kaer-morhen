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
#
#   Check 3 is the load-bearing one. Existence alone would NOT have caught the
#   incident once Docker auto-created `downloads/` on the placeholder.
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
readonly EXPECTED_FSTYPE="virtiofs"
readonly SENTINEL="library"
# 800 GiB: comfortably above the ~68 G placeholder and below the ~916 G real disk,
# with room for a future larger drive. Not a capacity check — a wrong-disk check.
readonly MIN_GIB="${MIN_GIB:-800}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.media-mount}"

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
  local fstype size_kb size_gib

  # 1. --mountpoint matches EXACTLY. --target would fall back to the parent mount
  #    and cheerfully report the root filesystem as if it were the media disk —
  #    the same trap the VM 150 hookscript avoids.
  if ! fstype=$(findmnt --noheadings --first-only --output FSTYPE \
                        --mountpoint "$MEDIA_DIR" 2>/dev/null); then
    echo "$MEDIA_DIR is not a mount point"
    return 1
  fi

  if [[ "$fstype" != "$EXPECTED_FSTYPE" ]]; then
    echo "$MEDIA_DIR is $fstype, expected $EXPECTED_FSTYPE"
    return 1
  fi

  # 2. Sentinel directory — exists only on the real media filesystem.
  if [[ ! -d "$MEDIA_DIR/$SENTINEL" ]]; then
    echo "$MEDIA_DIR/$SENTINEL missing — wrong or empty filesystem"
    return 1
  fi

  # 3. Size — the check that actually catches a pinned placeholder.
  size_kb=$(df -Pk "$MEDIA_DIR" | awk 'NR==2 {print $2}')
  if [[ -z "$size_kb" || "$size_kb" != *[0-9]* ]]; then
    echo "could not read filesystem size for $MEDIA_DIR"
    return 1
  fi
  size_gib=$(( size_kb / 1024 / 1024 ))
  if (( size_gib < MIN_GIB )); then
    echo "$MEDIA_DIR is only ${size_gib}GiB, expected >=${MIN_GIB}GiB — virtiofs is serving the wrong directory"
    return 1
  fi

  echo "ok: $MEDIA_DIR ${size_gib}GiB $fstype, $SENTINEL present"
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
