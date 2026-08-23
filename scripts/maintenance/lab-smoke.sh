#!/usr/bin/env bash
#
# lab-smoke.sh — post-upgrade smoke test for every proxied service.
#
# Why this exists
#   After an upgrade the question is "did anything break", and the honest answer
#   needs more than one ping. This walks the reverse proxy's own service
#   manifest and checks each service end to end, separating the three failure
#   modes that otherwise look identical from a browser:
#
#     DNS broken      -> Pi-hole stopped answering <app>.kaermorhen.fyi
#     proxy broken    -> Caddy down, or its wildcard cert expired
#     backend broken  -> Caddy is up and returns 502/503/504 for that app
#
#   A single "the site is down" cannot tell those apart; this can, which is the
#   difference between a five-minute fix and an evening.
#
# Why it addresses the proxy by --resolve
#   The two PVE nodes deliberately resolve via the router and CANNOT resolve
#   kaermorhen.fyi or kaermorhen.internal at all. A hostname-based check already
#   cost this lab fourteen days of a silently dead heartbeat (see
#   scripts/backup/README.md). `curl --resolve` pins the name to the proxy IP,
#   so the HTTP leg works from ANY host regardless of its resolver -- and DNS is
#   then tested separately and explicitly, as its own assertion, against both
#   Pi-holes. Never conflate the two.
#
# What it checks
#   1. DNS      — every service name resolves to the proxy on BOTH Pi-holes
#                 (a mismatch means nebula-sync drift: pihole-1 is authoritative)
#   2. HTTPS    — TLS completes and the backend answers non-5xx
#   3. Cert     — days remaining on the wildcard *.kaermorhen.fyi certificate
#   4. Docker   — no container on the docker VM is exited or unhealthy
#
# Verdict rule
#   FAIL on 000 (no connection / TLS failure) and on any 5xx -- 502/503/504 is
#   precisely how Caddy reports a dead backend. Any other status PASSES: 200,
#   302 to a login, 401 and 403 are all "the app answered", and asserting an
#   exact code per app would produce false failures every time an app changes
#   its redirect. This is a smoke test; deep per-stack behaviour is
#   lab-deep-check.sh's job.
#
# Usage
#   scripts/maintenance/lab-smoke.sh                # everything
#   scripts/maintenance/lab-smoke.sh --no-dns       # skip the Pi-hole assertions
#   scripts/maintenance/lab-smoke.sh --only jellyfin,immich
#
# Requires: curl, dig, openssl locally; ssh to the docker VM for the container check.
# Env overrides:
#   REPO_DIR SECRETS_FILE LAN_PREFIX PROXY_OCTET PIHOLE1_OCTET PIHOLE2_OCTET
#   DOCKER_HOST DOMAIN HTTP_TIMEOUT CERT_WARN_DAYS
#
set -euo pipefail

readonly REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly SECRETS_FILE="${SECRETS_FILE:-$REPO_DIR/secrets.local.yaml}"
readonly CADDYFILE="${CADDYFILE:-$REPO_DIR/configs/yennefer/proxy/Caddyfile}"
readonly DOMAIN="${DOMAIN:-kaermorhen.fyi}"
readonly PROXY_OCTET="${PROXY_OCTET:-202}"
readonly PIHOLE1_OCTET="${PIHOLE1_OCTET:-101}"
readonly PIHOLE2_OCTET="${PIHOLE2_OCTET:-201}"
readonly DOCKER_HOST="${DOCKER_HOST:-lab-ciri}"
readonly HTTP_TIMEOUT="${HTTP_TIMEOUT:-15}"
readonly CERT_WARN_DAYS="${CERT_WARN_DAYS:-21}"

DO_DNS=1
ONLY=""
while (( $# )); do
  case "$1" in
    --no-dns) DO_DNS=0 ;;
    --only)   ONLY="${2:-}"; shift ;;
    -h|--help) sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

PASS=0; FAIL=0; WARN=0

ok()   { printf '  \033[32mPASS\033[0m  %-34s %s\n' "$1" "${2:-}"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %-34s %s\n' "$1" "${2:-}"; FAIL=$((FAIL+1)); }
warn() { printf '  \033[33mWARN\033[0m  %-34s %s\n' "$1" "${2:-}"; WARN=$((WARN+1)); }

# LAN_PREFIX is a secret per CLAUDE.md and lives only in the git-ignored
# secrets file. Read it, never hardcode it, and let the environment win.
resolve_prefix() {
  if [[ -n "${LAN_PREFIX:-}" ]]; then printf '%s' "$LAN_PREFIX"; return; fi
  [[ -r "$SECRETS_FILE" ]] || {
    printf 'cannot read %s and LAN_PREFIX is unset\n' "$SECRETS_FILE" >&2; exit 2; }
  sed -n 's/^LAN_PREFIX:[[:space:]]*//p' "$SECRETS_FILE" | tr -d '"'\''[:space:]' | head -1
}

# The Caddyfile is the service manifest -- every name the proxy dispatches on.
# Using it means a service added to the proxy is covered here automatically,
# with no second list to forget to update.
service_names() {
  grep -oE "[a-z0-9-]+\.${DOMAIN//./\\.}" "$CADDYFILE" | sort -u | grep -vE "^\*\." || true
}

main() {
  local prefix proxy ph1 ph2
  prefix="$(resolve_prefix)"
  proxy="${prefix}.${PROXY_OCTET}"
  ph1="${prefix}.${PIHOLE1_OCTET}"
  ph2="${prefix}.${PIHOLE2_OCTET}"

  local names
  names="$(service_names)"
  if [[ -n "$ONLY" ]]; then
    names="$(printf '%s\n' "$names" | grep -E "^(${ONLY//,/|})\.")" || true
  fi
  [[ -n "$names" ]] || { printf 'no service names found in %s\n' "$CADDYFILE" >&2; exit 2; }

  printf 'kaermorhen lab smoke test — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'proxy %s · manifest %s (%s services)\n' \
    "$proxy" "${CADDYFILE#"$REPO_DIR"/}" "$(wc -l <<<"$names" | tr -d ' ')"

  # --- 1. proxy reachable, and its certificate ---------------------------
  # These are one probe deliberately. A bare-IP request is NOT a reachability
  # test here: Caddy serves a single wildcard site and refuses a request whose
  # Host header it does not recognise, so a refusal proves nothing. Completing
  # a TLS handshake with SNI does prove it, and it is the same handshake the
  # certificate check already needs.
  printf '\n== proxy ==\n'
  local first end_date end_epoch days
  first="$(head -1 <<<"$names")"
  end_date="$(openssl s_client -servername "$first" -connect "${proxy}:443" </dev/null 2>/dev/null \
             | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//')" || true
  if [[ -n "$end_date" ]]; then
    ok "caddy answering TLS on :443"
    if end_epoch="$(date -j -f '%b %e %T %Y %Z' "$end_date" '+%s' 2>/dev/null)" \
       || end_epoch="$(date -d "$end_date" '+%s' 2>/dev/null)"; then
      days=$(( (end_epoch - $(date +%s)) / 86400 ))
      if   (( days < 0 ));               then bad  "wildcard cert" "EXPIRED ${days#-}d ago"
      elif (( days < CERT_WARN_DAYS ));  then warn "wildcard cert" "$days days left — renewal may be failing"
      else                                    ok   "wildcard cert" "$days days left"
      fi
    else
      warn "wildcard cert" "could not parse notAfter: $end_date"
    fi
  else
    bad "caddy answering TLS on :443" "no TLS handshake — everything below will fail"
    bad "wildcard cert" "could not read certificate"
  fi

  # --- 3. DNS on both Pi-holes -------------------------------------------
  if (( DO_DNS )); then
    printf '\n== dns (both Pi-holes must agree; pihole-1 is authoritative) ==\n'
    local n a1 a2
    while read -r n; do
      [[ -n "$n" ]] || continue
      a1="$(dig +short +time=3 +tries=1 "@$ph1" "$n" 2>/dev/null | tail -1)"
      a2="$(dig +short +time=3 +tries=1 "@$ph2" "$n" 2>/dev/null | tail -1)"
      if [[ "$a1" == "$proxy" && "$a2" == "$proxy" ]]; then
        ok "dns $n"
      elif [[ "$a1" == "$proxy" && "$a2" != "$proxy" ]]; then
        bad "dns $n" "pihole-2 says '${a2:-NXDOMAIN}' — nebula-sync drift"
      elif [[ -z "$a1" && -z "$a2" ]]; then
        bad "dns $n" "no A record on either Pi-hole"
      else
        bad "dns $n" "pihole-1='${a1:-NXDOMAIN}' pihole-2='${a2:-NXDOMAIN}' want=$proxy"
      fi
    done <<<"$names"
  fi

  # --- 4. HTTPS through the proxy ----------------------------------------
  printf '\n== https (via --resolve, resolver-independent) ==\n'
  local code
  while read -r n; do
    [[ -n "$n" ]] || continue
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time "$HTTP_TIMEOUT" \
            --resolve "${n}:443:${proxy}" "https://${n}/" 2>/dev/null || echo 000)"
    case "$code" in
      000)      bad "https $n" "no response (TLS or connection failure)" ;;
      5??)      bad "https $n" "HTTP $code — backend down behind Caddy" ;;
      *)        ok  "https $n" "HTTP $code" ;;
    esac
  done <<<"$names"

  # --- 5. container health -----------------------------------------------
  printf '\n== containers (%s) ==\n' "$DOCKER_HOST"
  local rows found=0
  # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
  rows="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$DOCKER_HOST" \
    'docker ps -a --format "{{.Names}}\t{{.Status}}"' 2>/dev/null)" || true
  if [[ -z "${rows//[[:space:]]/}" ]]; then
    bad "container inventory" "could not reach $DOCKER_HOST"
  else
    while IFS=$'\t' read -r cname cstatus; do
      [[ -n "$cname" ]] || continue
      case "$cstatus" in
        *unhealthy*)      bad  "container $cname" "$cstatus"; found=1 ;;
        Up*)              : ;;
        "Exited (0)"*)    warn "container $cname" "$cstatus — one-shot leftover, safe to prune"; found=1 ;;
        *)                bad  "container $cname" "$cstatus"; found=1 ;;
      esac
    done <<<"$rows"
    (( found )) || ok "all containers up and healthy"
  fi

  printf '\n------------------------------------------------------------------\n'
  printf 'PASS %d · WARN %d · FAIL %d\n' "$PASS" "$WARN" "$FAIL"
  (( FAIL == 0 )) || exit 1
  exit 0
}

main
