#!/usr/bin/env bash
# collect-updates.sh — `updates` on every host given, merged into one report.
# Usage: collect-updates.sh <host-alias>...
# A host that fails is recorded as {"host":…, "error":true}, not dropped.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 host..." >&2; exit 2; }
out=/results/updates.json; tmp="${out}.tmp"
for h in "$@"; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" updates 2>/dev/null \
    || jq -nc --arg h "$h" '{host:$h, error:true, pending:0}'
done | jq -s '{updated:(now|todate), pending_total:(map(.pending // 0) | add), hosts:.}' > "$tmp"
mv -f "$tmp" "$out"
jq -r '.hosts[] | "\(.host): \(.pending) pending" + (if .guests then " (" + ([.guests[] | "\(.name)=\(.pending)"] | join(", ")) + ")" else "" end)' "$out"
