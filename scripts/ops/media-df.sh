#!/usr/bin/env bash
# media-df.sh — is the NFS media share really usable, and how full is it?
#
# Three states, because "is it in the mount table" and "does it answer" are
# different questions:
#   unmounted   — no nfs4 filesystem at the path (automount never fired, or
#                 the share was unmounted)
#   unreachable — the nfs4 mount is present but the server's nfsd is not
#                 answering (the 2026-09-07 E5 finding: stopping nfs-server on
#                 geralt leaves the client mount in place, so a findmnt-only
#                 check reports the share healthy while nothing can be read)
#   ok          — mounted and answering; sizes are real
#
# The path is an automount trigger, so `findmnt` lists TWO filesystems there
# when the share is up (the `autofs` trigger AND the `nfs4` mount on top) and
# only `autofs` when it is down. Look for an nfs4 line; a naive "first line"
# check always says autofs and reports the share missing — the 2026-09-03
# as-built bug. If nothing nfs4 is there, df would happily describe the root
# disk instead (the 2026-07-27 trap), so df is only run after the check.
#
# The mount is `hard`, so df against a dead server blocks indefinitely and
# would hang this collector (and pile up OliveTin runs) instead of reporting.
# Hence: probe the server's nfsd port first, and still cap df with a timeout.
#
# Prints ONE JSON object. Read-only. Env: MEDIA_DIR, PROBE_TIMEOUT, DF_TIMEOUT.
set -euo pipefail
MEDIA_DIR=${MEDIA_DIR:-/mnt/media}
PROBE_TIMEOUT=${PROBE_TIMEOUT:-3}
DF_TIMEOUT=${DF_TIMEOUT:-8}
NFSD_PORT=${NFSD_PORT:-2049}

emit() { # state mounted fstype size used avail pct
  jq -nc --arg st "$1" --argjson m "$2" --arg t "$3" \
    --argjson s "$4" --argjson u "$5" --argjson a "$6" --argjson p "$7" \
    '{mounted:$m, state:$st, fstype:$t, size:$s, used:$u, avail:$a, pct:$p,
      updated:(now|todate)}'
}

# `|| types=` because pipefail + a missing path would otherwise abort the
# script with no JSON at all.
types=$(findmnt -n -o FSTYPE "$MEDIA_DIR" 2>/dev/null | tr '\n' ',' | sed 's/,$//') || types=
if ! grep -qw nfs4 <<<"$types"; then
  emit unmounted false "${types:-none}" 0 0 0 0
  exit 0
fi

addr=$(findmnt -n -t nfs4 -o OPTIONS "$MEDIA_DIR" 2>/dev/null \
  | tr ',' '\n' | sed -n 's/^addr=//p' | head -1) || addr=
if [[ -n $addr ]] \
  && ! timeout "$PROBE_TIMEOUT" bash -c ": </dev/tcp/$addr/$NFSD_PORT" 2>/dev/null; then
  emit unreachable false nfs4 0 0 0 0
  exit 0
fi

# No pipe here: a pipeline would report tail's status, not timeout's.
if ! raw=$(timeout -k 2 "$DF_TIMEOUT" \
    df -B1 --output=size,used,avail,pcent "$MEDIA_DIR" 2>/dev/null); then
  emit unreachable false nfs4 0 0 0 0
  exit 0
fi
read -r size used avail pct < <(tail -1 <<<"$raw")
emit ok true nfs4 "$size" "$used" "$avail" "${pct%\%}"
