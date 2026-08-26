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
#     2. the tunnel interface is gone                 → kill-switch has failed open
#     3. no egress at all from the netns              → tunnel down / kill-switch shut
#     4. LEAK: netns egress IP == ciri's public IP    → traffic is bypassing the VPN
#     5. qBittorrent's API is unreachable             → dead client behind a live tunnel
#     6. gluetun's port-forwarding service has EXITED → PF is gone until a restart
#
#   Why 6 is hard and not soft: gluetun's PF retry loop covers the "get external
#   IPv4 address" RPC but NOT the "add UDP port mapping" RPC that follows it. A
#   refusal on the second one during PF *startup* (i.e. straight after a VPN
#   reconnect) is not retried — it propagates to the [vpn] supervisor, which does
#   nothing because the tunnel itself is healthy. Port forwarding is then over for
#   the life of the container. Observed 2026-07-30 (v3.41.1, ~22h) and again
#   2026-08-25 (v3.41.3, 8.7h): both times the container stayed "healthy", every
#   other monitor stayed green, and only a restart recovered it. Waiting cannot
#   help, so waiting out $MAX_STRIKES would only delay the page by ~30 minutes.
#
#   NOT a hard check: which organisation owns the exit IP. The first version of this
#   script hard-failed unless the exit's `organization` contained "proton", which
#   raised a FALSE leak alert across four runs (2026-07-29 23:45 → 2026-07-30 00:01)
#   when gluetun rotated onto a Proton server whose address block is registered to
#   its upstream datacenter:
#       AS208172 Proton AG → AS199218 Proton AG → AS43350 NForce Entertainment B.V.
#   All three are the same VPN. Proton rents capacity and does not own all the IP
#   space it exits from, so neither the ASN nor the org string is a stable identity —
#   pinning either only relocates the whack-a-mole. The exit's org is now reported in
#   the message for human context and never decides the verdict.
#
#   The leak invariant is just: egress != ciri's own public IP. That is the actual
#   definition of the failure, needs no allowlist, and cannot go stale.
#
#   SOFT (push up, message says degraded; escalates to down after $MAX_STRIKES
#   consecutive runs) — things that self-heal and would otherwise cry wolf:
#     7. forwarded port == 0, gluetun STILL RETRYING — Proton drops NAT-PMP
#                                     server-side intermittently (refused or timed
#                                     out); gluetun re-requests and usually wins
#                                     within a beat or two — three such dips on
#                                     2026-08-25 alone all cleared themselves.
#                                     qbit-port-sync deliberately keeps qBit's last
#                                     good port on a 0, so torrenting continues
#                                     meanwhile. Paging on this would be noise;
#                                     never noticing it going permanent would be
#                                     worse — which is what case 6 above is for.
#     8. forwarded port != qBit's listen_port — qbit-port-sync polls every 30s, so a
#                                     brief mismatch right after a rotation is normal.
#                                     A persistent one means the sidecar is broken.
#     9. qBit's external address != the tunnel's — gluetun's own healthcheck can
#                                     restart the VPN under a running client (5
#                                     times in the 36h to 2026-08-25). When it does,
#                                     qBittorrent can be left bound to the torn-down
#                                     interface: connection_status "firewalled", 0
#                                     DHT nodes, nothing moving — while every check
#                                     above still passes. That ran 8.7h unseen on
#                                     2026-08-25 because nothing looked at the
#                                     client's own idea of where it lives.
#                                     Soft because qBit learns its address from
#                                     peer/tracker feedback and legitimately lags a
#                                     rotation; a lag clears, a stranded client
#                                     never does, and the strike counter is exactly
#                                     that distinction.
#
#   Rule of thumb: a leak is never acceptable and always pages. So does a fault that
#   provably cannot self-heal. Everything that has ever recovered on its own gets
#   $MAX_STRIKES to do it.
#
# Fail-closed, without crying wolf
#   "Cannot determine" is never treated as "fine". If ciri's own public IP can't be
#   fetched, the comparison falls back to the last-known value cached in $STATE_DIR;
#   if there is no cache either, the run is DEGRADED (soft) rather than a hard page —
#   so a transient ipify outage can't fake a leak, but a persistent inability to
#   verify still escalates through the strike counter. The one thing this script must
#   never do is report a clean green because a lookup broke.
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
#   servarr-vpn-health.sh              # run from a systemd timer on ciri
#   servarr-vpn-health.sh --dry-run    # verify a deploy by hand: same checks and
#                                      # same exit status, but pushes nothing to
#                                      # Kuma and leaves the strike counter alone
#
# Deploy (on ciri) — see scripts/monitoring/README.md for the unit + timer
#   sudo install -m 0755 servarr-vpn-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' | sudo tee /etc/kuma-push.servarr-vpn >/dev/null
#   sudo chmod 600 /etc/kuma-push.servarr-vpn
#
# Requires: curl, jq, docker (must be able to `docker exec gluetun`). The push URL
#           carries a token, so it lives ONLY in that 0600 file and in
#           secrets.local.yaml — never here.
# Env overrides: GLUETUN_CTR, TUN_IF, MAX_STRIKES, KUMA_URL_FILE, STATE_DIR,
#                PF_QUIET_SECS,
#                HOST_IP_OVERRIDE (test hook — see the leak-path test in the README)

set -euo pipefail

readonly GLUETUN_CTR="${GLUETUN_CTR:-gluetun}"
# The WireGuard interface inside gluetun's netns. Its presence is a vendor-neutral
# proof that the tunnel exists at all — unlike the exit IP's registered owner, this
# cannot drift when the provider rotates servers or upstream hosts.
readonly TUN_IF="${TUN_IF:-tun0}"
# 6 consecutive degraded runs. At the 300s timer that is ~30 minutes — long enough
# to ride out a Proton PF rotation, short enough to catch a stuck sidecar the same
# evening.
readonly MAX_STRIKES="${MAX_STRIKES:-6}"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.servarr-vpn}"
readonly STATE_DIR="${STATE_DIR:-/var/lib/servarr-vpn-health}"
readonly STRIKE_FILE="$STATE_DIR/degraded.strikes"
# Last successfully-resolved public IP of ciri itself. Lets the leak comparison
# survive a transient outage of the external IP lookup without going blind.
readonly HOST_IP_CACHE="$STATE_DIR/host-public-ip"
# Test hook: pretend ciri's public IP is this. Setting it to the CURRENT egress IP
# simulates a leak exactly, which is how the hard path is exercised without
# touching the tunnel. See scripts/monitoring/README.md.
readonly HOST_IP_OVERRIDE="${HOST_IP_OVERRIDE:-}"
# How long gluetun's port-forwarding component may be silent, while the forwarded
# port is 0, before we call it dead rather than retrying. A live retry loop logs a
# [port forwarding] line every ~5s; the worst gap measured inside one is 127s (a
# single 9-try RPC timeout). A dead one logs nothing at all — 8.7 hours of it on
# 2026-08-25. 600s is ~5x the worst live gap and still well inside the ~30 min the
# strike counter would otherwise take.
readonly PF_QUIET_SECS="${PF_QUIET_SECS:-600}"
# How long to wait out a forwarded port that reads 0 while gluetun is still
# retrying, before counting it as a strike. Measured on 2026-08-26 against a Proton
# server that refused NAT-PMP on nearly every renewal: 12 dips in 41 minutes, each
# lasting 11-80s (median 18s), and the forwarded port came back as the SAME 45257
# every single time — qBittorrent's listen_port never changed and it stayed
# connected with 368 DHT nodes throughout. A 5-minute sampler lands in those
# troughs about 13% of the time and banks strikes for a fault nothing experienced.
# Polled, not slept: this usually costs a few seconds, and only pays the full
# budget when the dip is real. 60s + the checks + a worst-case retrying push still
# fits inside the unit's TimeoutStartSec=150.
readonly PF_RECHECK_SECS="${PF_RECHECK_SECS:-60}"
readonly PF_RECHECK_STEP=5
# --dry-run: verify a deployment by hand without touching shared state. A manual
# run is otherwise indistinguishable from a timer run — it pushes a real heartbeat
# to Kuma and increments the strike counter, so checking that the script works can
# itself walk a soft condition closer to a page. Observed 2026-08-26: a hand-run
# took the counter 1 -> 2.
DRY_RUN=0

# Push a heartbeat to Kuma. A push failure is reported but must NOT change the
# verdict: "Kuma is unreachable" is a different fault from "the VPN is leaking".
push() {
  local status=$1 msg=$2 url
  if (( DRY_RUN )); then
    echo "servarr-vpn-health: [dry-run] would push status=$status msg=$msg" >&2
    return 0
  fi
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

# Is gluetun's port-forwarding component still trying? Only ask when the forwarded
# port is 0 — a HEALTHY port forward is silent between rotations, so silence on its
# own means nothing.
#
# Echoes: retrying | exited | unknown
#
# "unknown" is load-bearing rather than defensive padding. On 2026-07-30 gluetun's
# container log held a corrupt length-prefixed record and `docker logs` returned
# NOTHING at all while the container was perfectly fine — the exact input that would
# make a naive "no PF lines, therefore dead" test page falsely, forever. So the
# window's TOTAL line count is checked too: qbit-port-sync polls the control server
# every 30s and gluetun logs every request, so a readable log over $PF_QUIET_SECS is
# never empty. Empty means the log is unreadable, not that gluetun is quiet.
pf_service_state() {
  local log pf
  if ! log=$(docker logs "$GLUETUN_CTR" --since "${PF_QUIET_SECS}s" 2>&1) || [[ -z "$log" ]]; then
    echo unknown
    return 0
  fi
  pf=$(printf '%s\n' "$log" | grep -c 'port forwarding' || true)
  if (( pf > 0 )); then echo retrying; else echo exited; fi
}

# Current forwarded port, or empty if it cannot be read.
fetch_pf_port() {
  in_netns wget -qO- --timeout=10 http://127.0.0.1:8000/v1/portforward \
    | jq -r '.port // empty' || true
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
  (( DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || true
  echo "$1" > "$STRIKE_FILE" 2>/dev/null || true
}

# Emits a verdict line on stdout. Return: 0 healthy, 1 hard failure, 2 degraded.
check() {
  local ctl vpn_ip host_ip org pf_port qbit_port qbit_xfer qbit_ip
  local waited note="" deadline started

  # 1. gluetun's control server. If this is unreachable the container is gone or
  #    wedged, and nothing below can be trusted.
  if ! ctl=$(in_netns wget -qO- --timeout=10 http://127.0.0.1:8000/v1/publicip/ip) \
     || [[ -z "$ctl" ]]; then
    echo "gluetun control server unreachable — container down, wedged, or renamed"
    return 1
  fi

  # Informational only — see the header. Never a verdict.
  org=$(printf '%s' "$ctl" | jq -r '.organization // empty')
  [[ -n "$org" ]] || org="unknown org"

  # 2. Tunnel interface. Vendor-neutral: if this is gone but egress still works,
  #    the kill-switch has failed open regardless of what the exit IP looks like.
  if ! in_netns ip -o addr show "$TUN_IF" | grep -q inet; then
    echo "tunnel interface $TUN_IF is missing from gluetun's netns — kill-switch has failed open"
    return 1
  fi

  # 3. Real egress test: an actual outbound request from inside the torrent netns.
  #    This is the heart of the monitor — everything else is corroboration.
  if ! vpn_ip=$(in_netns wget -qO- --timeout=15 https://api.ipify.org) || [[ -z "$vpn_ip" ]]; then
    echo "no egress from gluetun netns — tunnel down or kill-switch engaged (torrenting is stopped)"
    return 1
  fi

  # 4. Compare against ciri's own public IP — the whole leak test. On a lookup
  #    failure fall back to the cached value rather than going blind; only refresh
  #    the cache from a real lookup, never from the override.
  if [[ -n "$HOST_IP_OVERRIDE" ]]; then
    host_ip="$HOST_IP_OVERRIDE"
  else
    host_ip=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)
    if [[ -n "$host_ip" ]]; then
      mkdir -p "$STATE_DIR" 2>/dev/null || true
      echo "$host_ip" > "$HOST_IP_CACHE" 2>/dev/null || true
    elif [[ -r "$HOST_IP_CACHE" ]]; then
      host_ip=$(< "$HOST_IP_CACHE")
    fi
  fi

  if [[ -z "$host_ip" ]]; then
    # Soft, not hard: an ipify outage must not fake a leak. The strike counter still
    # escalates if we stay unable to verify.
    echo "degraded: cannot verify egress — ciri's public IP lookup failed and no cached value (egress is $vpn_ip, $org)"
    return 2
  fi

  if [[ "$vpn_ip" == "$host_ip" ]]; then
    echo "LEAK: torrent egress $vpn_ip is ciri's own public IP — traffic is NOT going through the VPN"
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
  # Same endpoint family, same netns, same severity: if preferences answered and
  # this did not, the API is not healthy and "cannot determine" is not "fine".
  if ! qbit_xfer=$(in_netns wget -qO- --timeout=10 \
                     http://127.0.0.1:8080/api/v2/transfer/info) || [[ -z "$qbit_xfer" ]]; then
    echo "qBittorrent API answered preferences but not transfer/info — client is not healthy"
    return 1
  fi

  # --- Hard checks all passed. Everything below is soft. --------------------

  # 6. Is qBittorrent bound to the CURRENT tunnel generation? See the header note.
  #    Empty is not stale: a freshly started client has had no peer feedback yet.
  qbit_ip=$(printf '%s' "$qbit_xfer" | jq -r '.last_external_address_v4 // empty')
  if [[ -n "$qbit_ip" && "$qbit_ip" != "$vpn_ip" ]]; then
    echo "degraded: qBittorrent still thinks it exits $qbit_ip but the tunnel now exits $vpn_ip — client stranded on a torn-down tunnel; restart qbittorrent and qbit-port-sync"
    return 2
  fi

  pf_port=$(fetch_pf_port)

  if [[ -z "$pf_port" || ! "$pf_port" =~ ^[0-9]+$ ]]; then
    echo "degraded: gluetun did not report a forwarded port (egress ok via $vpn_ip)"
    return 2
  fi

  if (( pf_port == 0 )); then
    # The distinction this monitor could not make for its first month: a 0 that
    # gluetun is still working on, versus a 0 it has given up on. Same symptom,
    # opposite responses — one wants patience, the other wants a restart tonight.
    case "$(pf_service_state)" in
      exited)
        echo "gluetun's port-forwarding service has EXITED — forwarded port 0 with no [port forwarding] log activity for ${PF_QUIET_SECS}s. This does not self-heal: restart gluetun, then qbittorrent and qbit-port-sync. (egress ok via $vpn_ip, qBit holding stale port $qbit_port)"
        return 1
        ;;
      retrying)
        # Ride out the oscillation before calling it a fault — see $PF_RECHECK_SECS.
        # A genuinely stuck 0 is still 0 at the end of the budget; a churning one is
        # not, and nothing downstream ever noticed it.
        # Bounded by wall clock, not by iteration count: each re-read can itself
        # burn its 10s wget timeout, so counting steps could overrun the unit's
        # TimeoutStartSec and turn a cosmetic dip into a killed service.
        deadline=$(( SECONDS + PF_RECHECK_SECS ))
        started=$SECONDS
        while (( SECONDS < deadline )); do
          sleep "$PF_RECHECK_STEP"
          pf_port=$(fetch_pf_port)
          if [[ "$pf_port" =~ ^[0-9]+$ ]] && (( pf_port != 0 )); then
            break
          fi
        done
        waited=$(( SECONDS - started ))
        if [[ ! "$pf_port" =~ ^[0-9]+$ ]] || (( pf_port == 0 )); then
          echo "degraded: forwarded port is 0 and gluetun is still retrying NAT-PMP (still 0 after ${PF_RECHECK_SECS}s); qBit still on last good port $qbit_port, egress ok via $vpn_ip"
          return 2
        fi
        # Came back mid-run. Reported, not counted: the mapping churned, the port
        # did not, and nothing downstream lost a packet over it. Falls through to
        # the normal comparisons with the recovered value.
        note=" (rode out a ${waited}s NAT-PMP dip)"
        ;;
      *)
        echo "degraded: forwarded port is 0 and gluetun's log is unreadable, so retrying cannot be told from dead; qBit still on last good port $qbit_port, egress ok via $vpn_ip"
        return 2
        ;;
    esac
  fi

  if (( pf_port != qbit_port )); then
    echo "degraded: gluetun forwarded port $pf_port != qBit listen_port $qbit_port — qbit-port-sync has not caught up"
    return 2
  fi

  echo "ok: egress $vpn_ip ($org), port-forward $pf_port matches qBit, no leak${note}"
  return 0
}

main() {
  local detail rc strikes
  case "${1:-}" in
    --dry-run|-n) DRY_RUN=1 ;;
    "")           ;;
    *)            echo "usage: ${0##*/} [--dry-run]" >&2; exit 64 ;;
  esac

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
