#!/usr/bin/env bash
# servarr-vpn-health.sh — Uptime-Kuma push monitor: prove qBittorrent's traffic
#                         still leaves through the VPN, and that it can accept peers.
#
# Why this exists
#   qBittorrent shares gluetun's network namespace, so gluetun's kill-switch is
#   the only thing between the torrent client and the home IP. That protection is
#   invisible: if it ever stopped working, every container would still be "up",
#   every Kuma HTTP monitor would stay green, and the first symptom would arrive
#   by post. This is the same blind spot as the 2026-07-27 media-mount incident
#   (see media-mount-health.sh) — liveness cannot see a wrong-egress failure.
#
#   So this monitor asks the only question that matters: make a real outbound
#   request FROM INSIDE the torrent netns and check where the internet says it
#   came from. Not "is gluetun running" — where does the traffic actually exit.
#
# Two severities, deliberately
#   HARD (push down immediately) — things that must never be true:
#     1. gluetun's control server is unreachable      → can't verify anything
#     2. no egress at all from the netns              → tunnel down / kill-switch shut
#     3. LEAK: netns egress IP == ciri's public IP    → traffic is bypassing the VPN
#     4. LEAK: egress IP is not the VPN provider's    → tunnel up but wrong exit
#     5. qBittorrent's API is unreachable             → dead client behind a live tunnel
#
#   SOFT (push up, message says degraded; escalates to down after $MAX_STRIKES
#   consecutive runs) — things that self-heal and would otherwise cry wolf:
#     6. forwarded port == 0        — Proton drops PF server-side intermittently
#                                     (NAT-PMP refused); gluetun re-requests it on
#                                     reconnect. qbit-port-sync deliberately keeps
#                                     qBit's last good port on a 0, so torrenting
#                                     continues meanwhile. Paging on this would be
#                                     noise; never noticing it going permanent
#                                     would be worse.
#     7. forwarded port != qBit's listen_port — qbit-port-sync polls every 30s, so a
#                                     brief mismatch right after a rotation is normal.
#                                     A persistent one means the sidecar is broken.
#
#   Rule of thumb: a leak is never acceptable and always pages. A missing forwarded
#   port only means slower torrents, and only pages once it stops being transient.
#
# Fail-closed
#   "Cannot determine" is never treated as "fine". If ciri's own public IP can't be
#   fetched the IP comparison is impossible, so the verdict falls back to the
#   provider check — and if that can't be made either, the run is a HARD failure.
#   The one thing this script must never do is report green because a lookup broke.
#
# Behaviour
#   Healthy    → push status=up   → Kuma heartbeat green
#   Degraded   → push status=up with a "degraded:" message → green, but the reason is
#                visible in Kuma's heartbeat log; exits 0
#   Hard fail  → push status=down with the reason → Kuma red → ntfy, and exit 1 so
#                `systemctl --failed` shows it on ciri too
#   Script/timer dead → no heartbeat → Kuma reddens on its own (the backstop)
#
# Usage
#   servarr-vpn-health.sh        # no arguments; run from a systemd timer on ciri
#
# Deploy (on ciri) — see scripts/monitoring/README.md for the unit + timer
#   sudo install -m 0755 servarr-vpn-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.servarr-vpn >/dev/null
#   sudo chmod 600 /etc/kuma-push.servarr-vpn
#
# Requires: curl, jq, docker (must be able to `docker exec gluetun`). The push URL
#           carries a token, so it lives ONLY in that 0600 file and in
#           secrets.local.yaml — never here.
# Env overrides: GLUETUN_CTR, EXPECTED_ORG, MAX_STRIKES, KUMA_URL_FILE, STATE_DIR

set -euo pipefail

readonly GLUETUN_CTR="${GLUETUN_CTR:-gluetun}"
# Substring match, case-insensitive, against the `organization` gluetun reports for
# its own exit IP (currently "AS208172 Proton AG"). Deliberately loose: Proton
# renames ASNs far more often than it stops being Proton.
readonly EXPECTED_ORG="${EXPECTED_ORG:-proton}"
# 6 consecutive degraded runs. At the 300s timer that is ~30 minutes — long enough
# to ride out a Proton PF rotation, short enough to catch a stuck sidecar the same
# evening.
readonly MAX_STRIKES="${MAX_STRIKES:-6}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.servarr-vpn}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/servarr-vpn-health}"
readonly STRIKE_FILE="$STATE_DIR/degraded.strikes"

# Push a heartbeat to Kuma. A push failure is reported but must NOT change the
# verdict: "Kuma is unreachable" is a different fault from "the VPN is leaking".
push() {
  local status=$1 msg=$2 url
  if [[ ! -r "$KUMA_URL_FILE" ]]; then
    echo "servarr-vpn-health: cannot read $KUMA_URL_FILE — not pushing" >&2
    return 0
  fi
  url=$(< "$KUMA_URL_FILE")
  url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "servarr-vpn-health: $KUMA_URL_FILE is empty" >&2; return 0; }

  # --retry: a single dropped push is a missed heartbeat, and Kuma cannot tell that
  # apart from the tunnel being down. Observed for real on the media monitor
  # 2026-07-29 22:21:43. Worst case here is 10+3+10+3+10 = 36s — the unit's
  # TimeoutStartSec must leave room for it on top of the checks.
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" \
        --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "servarr-vpn-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

# Run a command inside gluetun's netns. Every probe that must prove where torrent
# traffic exits has to go through here — running it on ciri would measure ciri.
in_netns() {
  docker exec "$GLUETUN_CTR" "$@" 2>/dev/null
}

# Consecutive-degraded bookkeeping. Kept out of /tmp so a reboot doesn't silently
# reset a genuinely stuck port back to strike 0.
read_strikes() {
  local n
  if [[ -r "$STRIKE_FILE" ]] && n=$(< "$STRIKE_FILE") && [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "$n"
  else
    echo 0
  fi
}

write_strikes() {
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STRIKE_FILE" 2>/dev/null || true
}

# Emits a verdict line on stdout. Return: 0 healthy, 1 hard failure, 2 degraded.
check() {
  local ctl vpn_ip host_ip org pf_port qbit_port

  # 1. gluetun's control server. If this is unreachable the container is gone or
  #    wedged, and nothing below can be trusted.
  if ! ctl=$(in_netns wget -qO- --timeout=10 http://127.0.0.1:8000/v1/publicip/ip) \
     || [[ -z "$ctl" ]]; then
    echo "gluetun control server unreachable — container down, wedged, or renamed"
    return 1
  fi

  org=$(printf '%s' "$ctl" | jq -r '.organization // empty')

  # 2. Real egress test: an actual outbound request from inside the torrent netns.
  #    This is the heart of the monitor — everything else is corroboration.
  if ! vpn_ip=$(in_netns wget -qO- --timeout=15 https://api.ipify.org) || [[ -z "$vpn_ip" ]]; then
    echo "no egress from gluetun netns — tunnel down or kill-switch engaged (torrenting is stopped)"
    return 1
  fi

  # 3. Compare against ciri's own public IP. If this lookup fails we do NOT get to
  #    call it healthy — we fall through to the provider check below.
  host_ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)

  if [[ -n "$host_ip" && "$vpn_ip" == "$host_ip" ]]; then
    echo "LEAK: torrent egress $vpn_ip is ciri's own public IP — traffic is NOT going through the VPN"
    return 1
  fi

  # 4. Provider check. Catches a tunnel that is up but exiting somewhere unexpected,
  #    and is the sole leak evidence when the host-IP lookup above failed.
  if [[ -z "$org" ]]; then
    if [[ -z "$host_ip" ]]; then
      echo "cannot verify egress: gluetun reports no organization AND ciri's public IP lookup failed"
      return 1
    fi
  elif [[ "${org,,}" != *"${EXPECTED_ORG,,}"* ]]; then
    echo "LEAK: torrent egress $vpn_ip belongs to '$org', expected '$EXPECTED_ORG'"
    return 1
  fi

  # 5. qBittorrent alive behind the tunnel. Unauthenticated because it comes from
  #    localhost inside the shared netns (qBit's localhost-bypass must stay ON).
  if ! qbit_port=$(in_netns wget -qO- --timeout=10 \
                     http://127.0.0.1:8080/api/v2/app/preferences \
                   | jq -r '.listen_port // empty') || [[ -z "$qbit_port" ]]; then
    echo "qBittorrent API unreachable behind a healthy tunnel — client dead or localhost-bypass off"
    return 1
  fi

  # --- Hard checks all passed. Everything below is soft. --------------------
  pf_port=$(in_netns wget -qO- --timeout=10 http://127.0.0.1:8000/v1/portforward \
            | jq -r '.port // empty' || true)

  if [[ -z "$pf_port" || ! "$pf_port" =~ ^[0-9]+$ ]]; then
    echo "degraded: gluetun did not report a forwarded port (egress ok via $vpn_ip)"
    return 2
  fi

  if (( pf_port == 0 )); then
    echo "degraded: Proton forwarded port is 0 (NAT-PMP refused); qBit still on last good port $qbit_port, egress ok via $vpn_ip"
    return 2
  fi

  if (( pf_port != qbit_port )); then
    echo "degraded: gluetun forwarded port $pf_port != qBit listen_port $qbit_port — qbit-port-sync has not caught up"
    return 2
  fi

  echo "ok: egress $vpn_ip ($org), port-forward $pf_port matches qBit, no leak"
  return 0
}

main() {
  local detail rc strikes

  set +e
  detail=$(check)
  rc=$?
  set -e

  case $rc in
    0)
      write_strikes 0
      push "up" "$detail"
      echo "servarr-vpn-health: $detail"
      ;;
    2)
      strikes=$(( $(read_strikes) + 1 ))
      write_strikes "$strikes"
      if (( strikes >= MAX_STRIKES )); then
        # Stopped being transient. Escalate to a real alert.
        detail="$detail [persisted $strikes consecutive checks]"
        push "down" "$detail"
        echo "servarr-vpn-health: FAIL — $detail" >&2
        exit 1
      fi
      push "up" "$detail [strike $strikes/$MAX_STRIKES]"
      echo "servarr-vpn-health: $detail [strike $strikes/$MAX_STRIKES]"
      ;;
    *)
      # Hard failures do not touch the strike counter: they are their own alert,
      # and zeroing it here would let a leak mask an already-escalating port fault.
      push "down" "$detail"
      echo "servarr-vpn-health: FAIL — $detail" >&2
      exit 1
      ;;
  esac
}

main "$@"
