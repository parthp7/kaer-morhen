#!/usr/bin/env bash
# restic-photos.sh — restic backup of /steel/photos (Immich originals +
# in-app DB dumps) from geralt to the repo on yennefer's backup disk.
#
# Usage:  restic-photos.sh backup   # daily: backup + retention (forget --prune)
#         restic-photos.sh check    # monthly: verify 10% of repo data end-to-end
# Not usually run by hand — driven by restic-photos.timer /
# restic-photos-check.timer (systemd, runs as root on geralt).
#
# Deploy:   install -m 0755 restic-photos.sh /usr/local/bin/
# Requires: /etc/restic-photos.env  (RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE,
#             optional KUMA_PUSH_URL — see restic-photos.env.example)
#           /etc/restic-photos.pass (chmod 600; copy lives in password manager —
#             losing it means losing the backups)
#           /etc/ntfy.topic         (chmod 600; failure alerts, same file
#             smartd-ntfy.sh uses)
#           restic + batch SSH root@yennefer (repo transport)
set -euo pipefail

MODE="${1:?usage: restic-photos.sh backup|check}"
SOURCE="/steel/photos"

notify_fail() {
  local topic
  topic="$(cat /etc/ntfy.topic 2>/dev/null)" || return 0
  curl -fsS --max-time 15 \
    -H "Title: restic photos ${MODE} FAILED on $(hostname -s)" \
    -H "Priority: high" \
    -d "journalctl -u restic-photos* for detail" \
    "https://ntfy.sh/${topic}" >/dev/null || true
}
trap notify_fail ERR

case "$MODE" in
  backup)
    restic backup --tag immich "$SOURCE"
    restic forget --keep-daily 7 --keep-weekly 4 --keep-monthly 6 --prune
    # Dead-man switch: Kuma alerts if this ping stops arriving — catches a
    # silently-disabled timer, which a failure-only alert never would.
    if [[ -n "${KUMA_PUSH_URL:-}" ]]; then
      curl -fsS --max-time 15 "${KUMA_PUSH_URL}" >/dev/null || true
    fi
    ;;
  check)
    # Reads + re-hashes a rotating 10% of repo pack data: bit-rot detection
    # for a repo sitting on plain ext4 (yennefer has no ZFS by design).
    restic check --read-data-subset=10%
    ;;
  *)
    echo "unknown mode: ${MODE}" >&2
    exit 2
    ;;
esac
