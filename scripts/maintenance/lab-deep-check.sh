#!/usr/bin/env bash
#
# lab-deep-check.sh — run the lab's functional health checks as named assertions.
#
# Why this exists
#   lab-smoke.sh proves every service ANSWERS. It cannot prove a service still
#   WORKS: Jellyfin returns 302 just as cheerfully when its GPU encoder has
#   vanished, and `df` reported 916 G throughout a twelve-day media outage.
#   This lab already learned that distinction three separate times and answered
#   it by building functional Push monitors that do real work -- a real NVENC
#   encode, a real O_DIRECT byte read, a real request out through the VPN netns.
#
#   Those scripts already exist and already share the contract an integration
#   test needs: exit 0 healthy, exit 1 failed, verdict printed to stdout. So
#   this reuses them rather than reinventing the probes. It adds orchestration,
#   not checks.
#
# The alert-noise trap this defeats
#   Running those scripts by hand pushes a REAL heartbeat to Uptime-Kuma and, on
#   failure, reddens the monitor and fires ntfy at whatever hour you are
#   testing. Every one of them guards its push behind a readable token file, so
#   pointing KUMA_URL_FILE at a path that does not exist makes push() print
#   "cannot read ... not pushing" and return 0, leaving the verdict untouched.
#   That is the supported test path and it is the DEFAULT here. Use --push only
#   when you deliberately want the heartbeat recorded.
#
# Assertions
#   gpu          ciri    real 1s h264_nvenc encode inside the jellyfin container
#   media-client ciri    /mnt/media is nfs4, size floor, O_DIRECT byte read
#   media-export geralt  /mnt/media is ext4, exported, nfsd bound, O_DIRECT read
#   vpn          ciri    real egress from inside gluetun's netns, IP != ciri's own
#   backup       geralt  restic check --read-data-subset=10% (SLOW: minutes)
#
# Usage
#   scripts/maintenance/lab-deep-check.sh                   # all but backup
#   scripts/maintenance/lab-deep-check.sh --only gpu,vpn
#   scripts/maintenance/lab-deep-check.sh --with-backup     # include restic check
#   scripts/maintenance/lab-deep-check.sh --push            # record real heartbeats
#
# Proving an assertion can actually fail
#   A check that has never been red has not been tested. Each underlying script
#   ships a documented failure hook; pass it through with EXTRA_ENV, e.g.
#     EXTRA_ENV="MIN_GIB=99999"        --only media-client
#     EXTRA_ENV="FORCE_ENCODE_FAIL=1"  --only gpu
#     EXTRA_ENV="HOST_IP_OVERRIDE=<vpn_ip>" --only vpn
#   In the default dry mode these exercise the failure path without pushing a
#   red heartbeat or waking anyone up.
#
# Requires: ssh (as root) to the docker VM and the storage node.
# Env overrides: DOCKER_HOST STORAGE_NODE SSH_TIMEOUT KUMA_URL_FILE EXTRA_ENV
#
set -euo pipefail

readonly DOCKER_HOST="${DOCKER_HOST:-lab-ciri}"
readonly STORAGE_NODE="${STORAGE_NODE:-lab-geralt}"
readonly SSH_TIMEOUT="${SSH_TIMEOUT:-20}"
# A path that cannot exist: makes every push() a no-op without touching Kuma.
readonly NO_PUSH_FILE="${KUMA_URL_FILE:-/nonexistent/lab-deep-check-no-push}"

ONLY=""; WITH_BACKUP=0; PUSH=0
while (( $# )); do
  case "$1" in
    --only)        ONLY="${2:-}"; shift ;;
    --with-backup) WITH_BACKUP=1 ;;
    --push)        PUSH=1 ;;
    -h|--help)     sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; SKIP=0

# name | host | remote command (without the env prefix)
assertion_cmd() {
  case "$1" in
    gpu)          printf '%s\t%s' "$DOCKER_HOST"  '/usr/local/bin/gpu-health.sh' ;;
    media-client) printf '%s\t%s' "$DOCKER_HOST"  '/usr/local/bin/media-mount-health.sh' ;;
    media-export) printf '%s\t%s' "$STORAGE_NODE" '/usr/local/bin/media-export-health.sh' ;;
    vpn)          printf '%s\t%s' "$DOCKER_HOST"  '/usr/local/bin/servarr-vpn-health.sh' ;;
    backup)       printf '%s\t%s' "$STORAGE_NODE" '/usr/local/bin/restic-photos.sh check' ;;
    *) return 1 ;;
  esac
}

run_assertion() {
  local name="$1" host cmd env_prefix out rc
  IFS=$'\t' read -r host cmd <<<"$(assertion_cmd "$name")"

  if (( PUSH )); then
    env_prefix=""
  else
    env_prefix="KUMA_URL_FILE=$NO_PUSH_FILE "
  fi
  # Test hooks go through `env VAR=...` deliberately: a bare `VAR=... cmd` over
  # ssh depends on the remote shell not resetting the environment and fails
  # silently-wrong when it does. Same reasoning as the scripts' own READMEs.
  [[ -n "${EXTRA_ENV:-}" ]] && env_prefix="env ${env_prefix}${EXTRA_ENV} "

  printf '  %-14s %-12s ' "$name" "$host"
  set +e
  out=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
        -o ServerAliveInterval=10 -o ServerAliveCountMax=6 \
        "$host" "${env_prefix}${cmd}" 2>&1)
  rc=$?
  set -e

  # The verdict these scripts print is the LAST meaningful line; the push
  # no-op notice is chatter and must not be mistaken for the verdict.
  local verdict
  verdict=$(printf '%s\n' "$out" | grep -vE 'not pushing|cannot read' | grep -vE '^\s*$' | tail -1)

  case "$rc" in
    0) printf '\033[32mPASS\033[0m  %s\n' "${verdict:0:96}"; PASS=$((PASS+1)) ;;
    2) printf '\033[33mDEGRADED\033[0m %s\n' "${verdict:0:96}"; PASS=$((PASS+1)) ;;
    255) printf '\033[31mUNREACHABLE\033[0m ssh to %s failed\n' "$host"; FAIL=$((FAIL+1)) ;;
    *) printf '\033[31mFAIL\033[0m  (rc=%s) %s\n' "$rc" "${verdict:0:88}"; FAIL=$((FAIL+1)) ;;
  esac
}

main() {
  local all="gpu media-client media-export vpn"
  (( WITH_BACKUP )) && all="$all backup"

  local selected="$all" name
  if [[ -n "$ONLY" ]]; then selected="${ONLY//,/ }"; fi

  printf 'kaermorhen deep check — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  if (( PUSH )); then
    printf 'mode: PUSH — heartbeats WILL be recorded and failures WILL alert\n'
  else
    printf 'mode: dry (KUMA_URL_FILE unreadable — no heartbeat, no ntfy)\n'
  fi
  printf '\n  %-14s %-12s %s\n' "ASSERTION" "HOST" "RESULT"

  for name in $selected; do
    if ! assertion_cmd "$name" >/dev/null 2>&1; then
      printf '  %-14s %-12s \033[33mSKIP\033[0m  unknown assertion\n' "$name" "-"
      SKIP=$((SKIP+1)); continue
    fi
    run_assertion "$name"
  done

  printf '\n------------------------------------------------------------------\n'
  printf 'PASS %d · FAIL %d · SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
  (( FAIL == 0 )) || exit 1
  exit 0
}

main
