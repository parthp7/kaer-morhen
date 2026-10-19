#!/usr/bin/env bash
# servarr-vpn-remediate.sh — the auto-fix half of servarr-vpn-health.sh: restart
#                            the VPN stack in order, waiting on real state between
#                            steps, then prove it worked.
#
# Why this exists
#   servarr-vpn-health.sh has always known the cure for its recurring verdicts and
#   printed it in the alert ("restart qbittorrent and qbit-port-sync"). Nothing
#   applied it. A stranded client ran ~15 h on 2026-10-11 and ~49 h on 2026-10-17,
#   both times until someone read the alert and restarted it by hand. qBit's own
#   log confirmed the 10-17 one was real: no "Detected external IP" for 49 h.
#
# The ladder (instance name = action)
#   sync    restart qbit-port-sync → wait until gluetun's forwarded port == qBit's
#           listen_port
#   client  restart qbittorrent → wait for its API → then `sync`. For a client
#           stranded on a torn-down tunnel: its sockets died with the old tun0
#           and never re-bind.
#   full    restart gluetun → wait for healthy + egress + a non-zero forwarded port
#           → then `client`. For port forwarding that has EXITED. Order matters: a
#           gluetun restart strands EVERY container in its netns (configs/ciri/
#           servarr/README.md, 2026-09-09), so both dependents always follow.
#   Every wait polls real state against a wall-clock deadline instead of sleeping
#   a fixed time. A step that times out fails the ladder.
#
#   Then verify with `servarr-vpn-health.sh --dry-run`. Its verdict must be "ok:",
#   not just exit 0: below MAX_STRIKES a degraded run also exits 0. If sync or
#   client fails, escalate once to full. If full fails, stop and say so.
#
# Guard rails
#   - Media mounts first. qBittorrent's binds are create_host_path:false, so
#     restarting it while NFS or the scratch disk is gone turns a degraded client
#     into one that will not start. Checked with `timeout`, because a hard NFS
#     mount blocks instead of erroring.
#   - At most $MAX_ACTIONS runs per $WINDOW_SECS (default 3 per 6 h). After that,
#     one ntfy saying it gave up, and the health monitor's paging takes over.
#     A loop of restarts is not a fix.
#   - flock -n: one ladder at a time. A second trigger while one runs is a no-op.
#   - Never touches anything but the three named containers. ciri also runs
#     manga-gluetun, which is a different stack.
#
# Notifications
#   One ntfy per run, with the steps taken and the outcome. A successful auto-fix
#   usually lands before the health monitor escalates, so Kuma may never go red.
#   Without this message the fix would be invisible.
#
# Usage
#   servarr-vpn-remediate.sh <sync|client|full>             # via servarr-vpn-remediate@<action>
#   servarr-vpn-remediate.sh --dry-run <sync|client|full>   # print the ladder, touch nothing
#
# Deploy (on ciri) — see scripts/monitoring/README.md for the template unit
#   sudo install -m 0755 servarr-vpn-remediate.sh /usr/local/bin/
#   printf '%s\n' '<NTFY_TOPIC>' | sudo tee /etc/ntfy.topic >/dev/null
#   sudo chmod 600 /etc/ntfy.topic
#
# Requires: curl, jq, docker, flock, timeout; /usr/local/bin/servarr-vpn-health.sh.
# Env overrides: GLUETUN_CTR, QBIT_CTR, SYNC_CTR, STATE_DIR, HEALTH_SCRIPT,
#                NTFY_TOPIC_FILE, MAX_ACTIONS, WINDOW_SECS

set -euo pipefail

readonly GLUETUN_CTR="${GLUETUN_CTR:-gluetun}"
readonly QBIT_CTR="${QBIT_CTR:-qbittorrent}"
readonly SYNC_CTR="${SYNC_CTR:-qbit-port-sync}"
# Shared with servarr-vpn-health.sh: a successful fix resets its counters here.
readonly STATE_DIR="${STATE_DIR:-/var/lib/servarr-vpn-health}"
readonly HEALTH_SCRIPT="${HEALTH_SCRIPT:-/usr/local/bin/servarr-vpn-health.sh}"
readonly NTFY_TOPIC_FILE="${NTFY_TOPIC_FILE:-/etc/ntfy.topic}"
readonly MAX_ACTIONS="${MAX_ACTIONS:-3}"
readonly WINDOW_SECS="${WINDOW_SECS:-21600}"
readonly HISTORY_FILE="$STATE_DIR/remediate.log"
readonly LOCK_FILE="$STATE_DIR/remediate.lock"
# The bind sources of qbittorrent in configs/ciri/servarr/compose.yaml.
readonly MOUNTS=(/mnt/media/downloads /mnt/torrents/incomplete)
DRY_RUN=0
STEPS=()

log() {
  echo "servarr-vpn-remediate: $*" >&2
}

# A failed notification is logged, never fatal: the fix matters more than the
# message about it.
notify() {
  local title=$1 body=$2 priority=${3:-default} topic
  if (( DRY_RUN )); then
    log "[dry-run] would ntfy ($priority) $title — $body"
    return 0
  fi
  if [[ ! -r "$NTFY_TOPIC_FILE" ]]; then
    log "cannot read $NTFY_TOPIC_FILE — not notifying ($title)"
    return 0
  fi
  topic=$(< "$NTFY_TOPIC_FILE")
  topic=${topic//[$'\t\r\n ']/}
  curl -fsS --max-time 15 --retry 2 --retry-delay 3 \
    -H "Title: $title" \
    -H "Priority: $priority" \
    -d "$body" \
    "https://ntfy.sh/${topic}" >/dev/null \
    || log "ntfy push failed ($title)"
}

in_netns() {
  docker exec "$GLUETUN_CTR" "$@" 2>/dev/null
}

step() {
  STEPS+=("$*")
  log "$*"
}

# Poll a probe until it succeeds or the wall-clock budget runs out. Bounded by
# time, not by iteration count, because each probe can itself burn a timeout.
wait_for() {
  local what=$1 secs=$2 deadline started
  shift 2
  if (( DRY_RUN )); then
    log "[dry-run] would wait ≤${secs}s for $what"
    return 0
  fi
  started=$SECONDS
  deadline=$(( SECONDS + secs ))
  while (( SECONDS < deadline )); do
    if "$@"; then
      step "  $what after $(( SECONDS - started ))s"
      return 0
    fi
    sleep 3
  done
  step "  TIMED OUT after ${secs}s waiting for $what"
  return 1
}

restart() {
  if (( DRY_RUN )); then
    log "[dry-run] would docker restart $1"
    return 0
  fi
  step "restart $1"
  docker restart "$1" >/dev/null
}

# --- probes ------------------------------------------------------------------

pf_port() {
  in_netns wget -qO- --timeout=5 http://127.0.0.1:8000/v1/portforward \
    | jq -r '.port // empty' 2>/dev/null || true
}

qbit_api_up() {
  [[ -n "$(in_netns wget -qO- --timeout=5 http://127.0.0.1:8080/api/v2/app/version)" ]]
}

gluetun_ready() {
  local health ip port
  health=$(docker inspect -f '{{.State.Health.Status}}' "$GLUETUN_CTR" 2>/dev/null) || return 1
  [[ "$health" == healthy ]] || return 1
  ip=$(in_netns wget -qO- --timeout=5 http://127.0.0.1:8000/v1/publicip/ip | jq -r '.public_ip // empty' 2>/dev/null) || return 1
  [[ -n "$ip" ]] || return 1
  port=$(pf_port)
  [[ "$port" =~ ^[0-9]+$ ]] && (( port != 0 ))
}

ports_match() {
  local pf qp
  pf=$(pf_port)
  qp=$(in_netns wget -qO- --timeout=5 http://127.0.0.1:8080/api/v2/app/preferences \
         | jq -r '.listen_port // empty' 2>/dev/null) || return 1
  [[ "$pf" =~ ^[0-9]+$ && "$qp" =~ ^[0-9]+$ ]] && (( pf != 0 && pf == qp ))
}

# --- the ladder ----------------------------------------------------------------

# The port-sync sidecar polls every 30s and writes on its first poll after a
# restart, so 90s is three polls of margin.
do_sync() {
  restart "$SYNC_CTR"
  wait_for "forwarded port == qBit listen_port" 90 ports_match
}

do_client() {
  restart "$QBIT_CTR"
  wait_for "qBittorrent API" 90 qbit_api_up || return 1
  do_sync
}

# 180s: a WireGuard reconnect plus Proton's NAT-PMP, which has been measured
# refusing for 11-80s at a time (2026-08-26).
do_full() {
  restart "$GLUETUN_CTR"
  wait_for "gluetun healthy with egress and a forwarded port" 180 gluetun_ready || return 1
  do_client
}

# Two attempts, 20s apart: a fresh client can land in a Proton NAT-PMP dip, and
# one unlucky sample should not escalate to a gluetun restart.
verify() {
  local out i
  if (( DRY_RUN )); then
    log "[dry-run] would verify with $HEALTH_SCRIPT --dry-run"
    return 0
  fi
  for i in 1 2; do
    out=$("$HEALTH_SCRIPT" --dry-run 2>/dev/null || true)
    if [[ "$out" == "servarr-vpn-health: ok:"* ]]; then
      step "verified: ${out#servarr-vpn-health: }"
      return 0
    fi
    step "verify $i/2 not ok: ${out#servarr-vpn-health: }"
    (( i == 2 )) || sleep 20
  done
  return 1
}

run_ladder() {
  case $1 in
    sync)   do_sync ;;
    client) do_client ;;
    full)   do_full ;;
  esac
}

# --- guard rails ---------------------------------------------------------------

mounts_ok() {
  local m
  for m in "${MOUNTS[@]}"; do
    if ! timeout 30 test -d "$m"; then
      echo "$m"
      return 1
    fi
  done
}

# Number of runs inside the window. Each run is one line: "<epoch> <action> <result>".
recent_runs() {
  local now=$1
  [[ -r "$HISTORY_FILE" ]] || { echo 0; return 0; }
  awk -v cutoff=$(( now - WINDOW_SECS )) '$1 >= cutoff { n++ } END { print n + 0 }' "$HISTORY_FILE"
}

record() {
  (( DRY_RUN )) && return 0
  echo "$1 $2 $3" >> "$HISTORY_FILE"
  # Keep the file bounded; only the window matters.
  tail -n 200 "$HISTORY_FILE" > "$HISTORY_FILE.tmp" && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE"
}

reset_health_counters() {
  (( DRY_RUN )) && return 0
  echo 0 > "$STATE_DIR/degraded.strikes"
  echo "" > "$STATE_DIR/reason"
  echo 0 > "$STATE_DIR/reason.count"
}

main() {
  local action now n missing result priority title
  if [[ "${1:-}" == --dry-run || "${1:-}" == -n ]]; then
    DRY_RUN=1
    shift
  fi
  action=${1:-}
  case $action in
    sync|client|full) ;;
    *) echo "usage: ${0##*/} [--dry-run] <sync|client|full>" >&2; exit 64 ;;
  esac

  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    log "another remediation is already running — nothing to do"
    exit 0
  fi

  now=$(date +%s)
  n=$(recent_runs "$now")
  if (( n >= MAX_ACTIONS )); then
    log "rate limit: $n run(s) in the last $(( WINDOW_SECS / 3600 ))h — not acting"
    notify "servarr auto-fix gave up" \
      "Wanted to run '$action' but already ran $n time(s) in the last $(( WINDOW_SECS / 3600 ))h. Not restarting again; servarr vpn health will keep paging until someone looks. History: $HISTORY_FILE on $(hostname -s)." \
      high
    exit 1
  fi

  if ! missing=$(mounts_ok); then
    log "precondition failed: $missing is not reachable"
    notify "servarr auto-fix skipped" \
      "Wanted to run '$action' but $missing is not reachable, and qBittorrent will not start without it. Fix the media path first (media mount monitor)." \
      high
    exit 1
  fi

  log "starting '$action' (run $(( n + 1 ))/$MAX_ACTIONS in window)"
  result=failed
  if run_ladder "$action" && verify; then
    result=fixed
  elif [[ "$action" != full ]]; then
    step "'$action' did not fix it — escalating to full"
    if do_full && verify; then
      result=fixed-by-full
    fi
  fi
  record "$now" "$action" "$result"

  if [[ "$result" == failed ]]; then
    title="servarr auto-fix FAILED ($action)"
    priority=high
  else
    reset_health_counters
    title="servarr auto-fixed ($action)"
    [[ "$result" == fixed-by-full ]] && title="servarr auto-fixed ($action → full)"
    priority=default
  fi
  notify "$title" "$(printf '%s\n' "${STEPS[@]:-no steps (dry run)}")" "$priority"
  log "result: $result"
  [[ "$result" != failed ]]
}

main "$@"
