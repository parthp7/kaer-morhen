#!/usr/bin/env bash
# collect.sh — run ONE whitelisted word on ONE host over the ops key and store
# the JSON it returns for Homepage's customapi tiles.
# Usage: collect.sh <word> <host-alias>     (aliases from ~/.ssh/config)
# Writes /results/<word>.json atomically; on failure writes {"error":…} so the
# tile shows the fault instead of a stale number.
set -euo pipefail
word=${1:?word}; host=${2:?host}
out="/results/${word}.json"; tmp="${out}.tmp"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$word" > "$tmp" 2>/dev/null \
   && jq -e . "$tmp" >/dev/null 2>&1; then
  mv -f "$tmp" "$out"
else
  jq -nc --arg w "$word" --arg h "$host" '{error:true, word:$w, host:$h, updated:(now|todate)}' > "$tmp"
  mv -f "$tmp" "$out"
  echo "collect: $word on $host failed" >&2; exit 1
fi
cat "$out"
