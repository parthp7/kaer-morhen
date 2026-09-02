#!/usr/bin/env bash
# qbit-move-progress.sh — progress of qBittorrent's move-on-completion from the
# NVMe scratch (/mnt/torrents/incomplete) to the media share
# (/mnt/media/downloads/complete), as ONE JSON object. Progress = bytes present
# at the destination vs the torrent's total_size — exact for qBit's sequential
# copy. Read-only: qBit API login + `du`.
# Requires: curl, jq, /etc/ops/qbit.env (QBIT_URL, QBIT_USER, QBIT_PASS; 0600).
# Env overrides: COMPLETE_DIR (host path), QBIT_COMPLETE_PREFIX (path as qBit sees it).
set -euo pipefail
# shellcheck source=/dev/null
. /etc/ops/qbit.env
COMPLETE_DIR=${COMPLETE_DIR:-/mnt/media/downloads/complete}
QBIT_COMPLETE_PREFIX=${QBIT_COMPLETE_PREFIX:-/data/downloads/complete}

# qBit's WebUI API rejects requests whose Referer/Origin doesn't match the Host
# it was reached on (CSRF guard) — send it explicitly on every call.
jar=$(mktemp); trap 'rm -f "$jar"' EXIT
curl -fsS -c "$jar" -H "Referer: $QBIT_URL" \
  --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS" \
  "$QBIT_URL/api/v2/auth/login" >/dev/null
moving=$(curl -fsS -b "$jar" -H "Referer: $QBIT_URL" "$QBIT_URL/api/v2/torrents/info" \
  | jq -r '.[] | select(.state=="moving") | [.name, .total_size, .content_path] | @tsv')

items=$(
  while IFS=$'\t' read -r name total cpath; do
    [[ -n ${name:-} ]] || continue
    if [[ $cpath == "$QBIT_COMPLETE_PREFIX"* ]]; then
      dest="${COMPLETE_DIR}${cpath#"$QBIT_COMPLETE_PREFIX"}"
    else
      dest="$COMPLETE_DIR/$name"
    fi
    done_b=$(du -sb "$dest" 2>/dev/null | cut -f1 || true)
    jq -nc --arg n "$name" --argjson t "${total:-0}" --argjson d "${done_b:-0}" \
      '{name:$n, total:$t, done:$d, pct:(if $t>0 then (($d*100/$t)|floor) else 0 end)}'
  done <<<"$moving" | jq -s .
)

jq -nc --argjson items "$items" '{
  updated: (now|todate),
  moving:  ($items|length),
  current: (if ($items|length)>0 then "\($items[0].name) \($items[0].pct)%" else "idle" end),
  pct:     (if ($items|length)>0 then $items[0].pct else 0 end),
  items:   $items
}'
