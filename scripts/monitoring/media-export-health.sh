#!/usr/bin/env bash
# media-export-health.sh — Uptime-Kuma push monitor: prove geralt is SERVING
# the real media disk over NFS.
#
# The client-side monitor (media-mount-health.sh on ciri) sees the end-to-end
# truth but cannot say WHERE a fault is. This is the server-side half, so a
# host-only fault (disk dropped, nfsd dead, export vanished) is attributed
# correctly and caught even if ciri is down.
#
# What it checks (in order; first failure wins)
#   1. /mnt/media is a mount point of type ext4       — not the pve-root placeholder
#   2. /mnt/media/library can be ENUMERATED (readdir) — reaches the backing store
#   3. library/.mount-health can be READ (bytes)      — same sentinel file the
#                                                       ciri monitor reads
#   4. nfs-server.service is active
#   5. the export table still lists /mnt/media        — `mountpoint` guard means
#                                                       a dead mount silently
#                                                       drops the export; catch it
#   6. nfsd is listening on <STORAGE_PREFIX>.21:2049
#
# Behaviour: identical contract to media-mount-health.sh — push up/down with a
# reason; exit 1 on failure so `systemctl --failed` shows it host-side too.
#
# Deploy (on geralt) — see docs/proposals/005 Phase A5
#   install -m 0755 media-export-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' > /etc/kuma-push.media-export && chmod 600 /etc/kuma-push.media-export
#
# Requires: curl, findmnt (util-linux), exportfs, ss (iproute2).
# Env overrides: MEDIA_DIR, KUMA_URL_FILE, NFS_BIND_IP

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly SENTINEL="library"
readonly HEALTH_FILE="$MEDIA_DIR/$SENTINEL/.mount-health"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.media-export}"
# Real storage-net IP; not a placeholder file on the host. Set at install time.
readonly NFS_BIND_IP="${NFS_BIND_IP:-$(ip -4 -br addr show vmbr1 2>/dev/null | awk '{print $3}' | cut -d/ -f1)}"

push() {
  local status=$1 msg=$2 url
  [[ -r "$KUMA_URL_FILE" ]] || { echo "media-export-health: cannot read $KUMA_URL_FILE — not pushing" >&2; return 0; }
  url=$(< "$KUMA_URL_FILE"); url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "media-export-health: $KUMA_URL_FILE is empty" >&2; return 0; }
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "media-export-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

check() {
  local fstype
  # 1. exact mountpoint match — --target would fall back to pve-root (the
  #    hookscript's documented trap).
  if ! fstype=$(findmnt --noheadings --first-only --output FSTYPE \
                        --mountpoint "$MEDIA_DIR" 2>/dev/null); then
    echo "$MEDIA_DIR is not a mount point"
    return 1
  fi
  if [[ "$fstype" != "ext4" ]]; then
    echo "$MEDIA_DIR is $fstype, expected ext4"
    return 1
  fi

  # 2. readdir reaches the backing store; stat/df do not (lesson of 08-03).
  if ! timeout 30 ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1; then
    echo "cannot enumerate $MEDIA_DIR/$SENTINEL — mounted but dead"
    return 1
  fi

  # 3. bytes, O_DIRECT — bypass the page cache (ext4 supports it).
  if ! timeout 30 dd if="$HEALTH_FILE" of=/dev/null bs=4096 count=1 iflag=direct 2>/dev/null; then
    echo "cannot read $HEALTH_FILE"
    return 1
  fi

  # 4-6. the serving side.
  if ! systemctl is-active --quiet nfs-server; then
    echo "nfs-server is not active"
    return 1
  fi
  if ! exportfs -s 2>/dev/null | grep -q "^$MEDIA_DIR\b"; then
    echo "$MEDIA_DIR is not in the export table (mountpoint guard tripped?)"
    return 1
  fi
  if [[ -n "$NFS_BIND_IP" ]] && ! ss -tln "sport = :2049" | grep -q "$NFS_BIND_IP:2049"; then
    echo "nfsd is not listening on $NFS_BIND_IP:2049"
    return 1
  fi

  echo "ok: $MEDIA_DIR ext4 mounted, $SENTINEL readable, exported, nfsd on ${NFS_BIND_IP:-?}:2049"
  return 0
}

main() {
  local detail
  if detail=$(check); then
    push "up" "$detail"
    echo "media-export-health: $detail"
  else
    push "down" "$detail"
    echo "media-export-health: FAIL — $detail" >&2
    exit 1
  fi
}

main "$@"
