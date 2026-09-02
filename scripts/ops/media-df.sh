#!/usr/bin/env bash
# media-df.sh — is the NFS media share REALLY mounted, and how full is it?
# `findmnt` must report nfs4: the path is an automount trigger, so an unmounted
# share shows as `autofs` (or nothing) and df would happily describe the root
# disk instead — the 2026-07-27 trap. Prints ONE JSON object. Read-only.
set -euo pipefail
MEDIA_DIR=${MEDIA_DIR:-/mnt/media}
fstype=$(findmnt -n -o FSTYPE --target "$MEDIA_DIR" 2>/dev/null || true)
if [[ $fstype == nfs4 ]]; then
  read -r size used avail pct < <(df -B1 --output=size,used,avail,pcent "$MEDIA_DIR" | tail -1)
  jq -nc --argjson s "$size" --argjson u "$used" --argjson a "$avail" --argjson p "${pct%\%}" \
    '{mounted:true, size:$s, used:$u, avail:$a, pct:$p, updated:(now|todate)}'
else
  jq -nc --arg t "${fstype:-none}" '{mounted:false, fstype:$t, size:0, used:0, avail:0, pct:0, updated:(now|todate)}'
fi
