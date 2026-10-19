#!/usr/bin/env bash
# media-link-health.sh — Uptime-Kuma push monitor: count the media disk's USB
# drops, and catch a silent downgrade of its link.
#
# Why this exists
#   Two faults on this disk were invisible for weeks, for opposite reasons.
#
#   1. THE DROPS WERE HIDDEN BY THE FIX FOR THEM. Proposal 005's
#      media-autoheal.sh remounts and re-exports in ~14 s after a USB
#      re-enumeration. Between 2026-08-24 and 2026-09-02 it did that 54 times
#      and nobody noticed: every outage was shorter than the monitors' probe
#      interval, so media-mount-health and media-export-health stayed green
#      throughout. The 08-10 fault ran 12 days and was impossible to ignore;
#      this one fired every few hours and produced no signal a human acted on.
#      An auto-healer that hides a fault must be paired with something that
#      COUNTS it — this script is that something.
#
#   2. THE LINK QUIETLY FELL BACK TO USB 2.0 AND STAYED THERE. On 2026-08-15 the
#      bridge re-enumerated at 480 Mb/s instead of 5000. Nothing was down, so
#      nothing alerted — for eighteen days. `max_sectors_kb` fell 1024 -> 120 with
#      it, capping every command at 120 KB, and sequential reads collapsed to
#      9.8 MB/s. That is what starved Jellyfin on 2026-09-02: 16 of 16 nfsd
#      threads blocked in D state on one move-on-completion, while `ls`, `df` and
#      a cached `dd` all still returned at ~3 GB/s and every existing monitor
#      passed. Speed is not liveness, and no liveness check can see this.
#
#   Full history: docs/storage.md, incidents 2026-08-10/22 and 2026-09-02.
#
# What it checks (in order; first failure wins)
#   1. the media disk is present         — resolvable via /dev/disk/by-label/media
#   2. its USB link is SuperSpeed        — >= $MIN_SPEED (5000 Mb/s); catches 08-15
#   3. max_sectors_kb is not capped      — >= $MIN_SECTORS_KB (1024); catches 09-02
#   4. drops in the rolling window       — <= $DROP_MAX `USB disconnect` events on
#                                          this disk's physical port in $WINDOW_H h
#
#   Checks 2-3 answer "degraded but up". Check 4 answers "repaired so fast that
#   nothing else can see it". The count rides in the `up` message too, so Kuma's
#   history shows the trend while the monitor is still green.
#
# Deliberately NOT checked here: whether the mount is alive and exported. That is
# media-export-health.sh's job, and duplicating it would double-alert on one fault.
#
# Deploy (on geralt)
#   install -m 0755 media-link-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' > /etc/kuma-push.media-link && chmod 600 /etc/kuma-push.media-link
#   install -m 0644 media-link-health.{service,timer} /etc/systemd/system/
#   systemctl daemon-reload && systemctl enable --now media-link-health.timer
#   # Kuma: Push monitor, heartbeat 600 s (twice the timer period), resend 60 min
#
#   The push URL must be the BARE base URL addressed BY IP — see the two traps in
#   scripts/monitoring/README.md; both apply verbatim here.
#
# Requires: journalctl (persistent journal), GNU date, curl.
# Env overrides: MEDIA_LABEL, MIN_SPEED, MIN_SECTORS_KB, WINDOW_H, DROP_MAX,
#                DROP_PORT_RE, KUMA_URL_FILE

set -euo pipefail

readonly MEDIA_LABEL="${MEDIA_LABEL:-media}"
# SuperSpeed. The drive negotiated 5000 on a good connector and 480 on the bad
# one; there is no legitimate reason for it to sit below 5000.
readonly MIN_SPEED="${MIN_SPEED:-5000}"
# usb-storage's transfer ceiling. 1024 at SuperSpeed, 120 when the link fell back.
readonly MIN_SECTORS_KB="${MIN_SECTORS_KB:-1024}"
readonly WINDOW_H="${WINDOW_H:-24}"
# 0 = any drop inside the window is worth a human looking. Raise it only to ride
# out a known-bad phase, and lower it back afterwards — the whole point of this
# monitor is that a self-healed drop still gets counted.
readonly DROP_MAX="${DROP_MAX:-0}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.media-link}"

push() {
  local status=$1 msg=$2 url
  [[ -r "$KUMA_URL_FILE" ]] || { echo "media-link-health: cannot read $KUMA_URL_FILE — not pushing" >&2; return 0; }
  url=$(< "$KUMA_URL_FILE"); url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "media-link-health: $KUMA_URL_FILE is empty" >&2; return 0; }
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "media-link-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

# Walk up from the block device to the USB device node that owns it. Never
# address this disk as /dev/sdX: it has walked sdb -> sdm -> sdn -> sdv -> sdb
# across re-enumerations, and the kernel name is meaningless between drops.
usb_dev_dir() {
  local dev sysdir
  dev=$(readlink -f "/dev/disk/by-label/$MEDIA_LABEL" 2>/dev/null) || return 1
  [[ -b "$dev" ]] || return 1
  sysdir=$(readlink -f "/sys/class/block/$(basename "$dev")") || return 1
  # /sys/class/block/sdb1 -> .../2-3/2-3:1.0/host6/.../block/sdb/sdb1
  while [[ "$sysdir" != "/" ]]; do
    if [[ -f "$sysdir/speed" && -f "$sysdir/idVendor" ]]; then
      printf '%s\n' "$sysdir"
      return 0
    fi
    sysdir=$(dirname "$sysdir")
  done
  return 1
}

# The whole-disk queue directory (sdb, not sdb1) — max_sectors_kb lives there.
disk_queue_dir() {
  local dev part
  dev=$(readlink -f "/dev/disk/by-label/$MEDIA_LABEL" 2>/dev/null) || return 1
  part=$(basename "$dev")
  # /sys/class/block/sdb1/.. is the parent disk for a partition.
  if [[ -d "/sys/class/block/$part/../queue" ]]; then
    readlink -f "/sys/class/block/$part/../queue"
  elif [[ -d "/sys/class/block/$part/queue" ]]; then
    readlink -f "/sys/class/block/$part/queue"
  else
    return 1
  fi
}

# Count `usb <bus>-<port>: USB disconnect` for THIS disk's physical port over the
# window. The bus number changes when the link renegotiates (1-3 at 480, 2-3 at
# 5000), so match the port and let the bus float.
#
# -k implies -b and would silently scope the count to the current boot, which is
# exactly wrong for a rolling window: use the kernel transport match instead.
count_drops() {
  local port_re=$1 since
  since=$(date -d "-${WINDOW_H} hours" '+%Y-%m-%d %H:%M:%S')
  journalctl --since "$since" _TRANSPORT=kernel --no-pager 2>/dev/null \
    | grep -cE "usb ${port_re}: USB disconnect" || true
}

# How much of the window the journal can actually speak for. A fresh boot or a
# vacuumed journal makes "0 drops in 24 h" a claim the data does not support.
observed_hours() {
  local since first now_s first_s
  since=$(date -d "-${WINDOW_H} hours" '+%Y-%m-%d %H:%M:%S')
  # `head` closes the pipe and journalctl dies of SIGPIPE; with pipefail that
  # reads as a failed query and the window silently becomes unknown. Drop
  # pipefail for this one pipeline only.
  first=$(set +o pipefail
          journalctl --since "$since" _TRANSPORT=kernel --no-pager -o short-unix 2>/dev/null \
          | head -n 1 | cut -d' ' -f1 | cut -d. -f1) || return 1
  [[ "$first" =~ ^[0-9]+$ ]] || return 1
  now_s=$(date +%s); first_s=$first
  awk -v a="$now_s" -v b="$first_s" 'BEGIN{printf "%.1f", (a-b)/3600}'
}

check() {
  local usbdir qdir speed sectors port port_re drops seen

  if ! usbdir=$(usb_dev_dir); then
    echo "media disk (label '$MEDIA_LABEL') is not present on any USB bus"
    return 1
  fi
  port=$(basename "$usbdir")                 # e.g. 2-3
  port_re="[0-9]+-${port#*-}"                # e.g. [0-9]+-3
  port_re=${port_re//./\\.}                  # a hub path like 2-3.1 has a literal dot

  speed=$(cat "$usbdir/speed" 2>/dev/null || echo 0)
  drops=$(count_drops "$port_re")
  seen=$(observed_hours || echo "?")

  # Report the counts in every verdict, pass or fail — a degraded link and a
  # drop storm usually arrive together, and whichever one wins the `return 1`
  # should not hide the other.
  local facts="link ${speed}M on $port, ${drops} drop(s) in ${seen}/${WINDOW_H} h"

  if (( speed < MIN_SPEED )); then
    echo "USB link is ${speed}M, expected >= ${MIN_SPEED}M — silent fallback, reseat the connector ($facts)"
    return 1
  fi

  if qdir=$(disk_queue_dir); then
    sectors=$(cat "$qdir/max_sectors_kb" 2>/dev/null || echo 0)
    if (( sectors < MIN_SECTORS_KB )); then
      echo "max_sectors_kb is ${sectors}, expected >= ${MIN_SECTORS_KB} — transfers are capped ($facts)"
      return 1
    fi
  else
    sectors="?"
  fi

  if (( drops > DROP_MAX )); then
    echo "${drops} USB drop(s) on port $port in the last ${WINDOW_H} h (max ${DROP_MAX}) — self-healed, still a hardware fault ($facts)"
    return 1
  fi

  echo "ok: ${speed}M on $port, max_sectors_kb ${sectors}, ${drops} drop(s) in ${seen}/${WINDOW_H} h"
  return 0
}

main() {
  local detail
  if detail=$(check); then
    push "up" "$detail"
    echo "media-link-health: $detail"
  else
    push "down" "$detail"
    echo "media-link-health: FAIL — $detail" >&2
    exit 1
  fi
}

main "$@"
