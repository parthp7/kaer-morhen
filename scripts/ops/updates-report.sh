#!/usr/bin/env bash
# updates-report.sh — pending apt upgrades on this host and, on a PVE node,
# inside every RUNNING LXC. Prints ONE JSON object. Read-only apart from
# refreshing apt's lists (the same `apt update` the weekly pass runs); never
# installs anything. Counts apt only — Kuma (npm), Pi-hole, Caddy plugins and
# Docker images are not apt and stay manual (maintenance.md).
# Requires: apt, jq; pct on PVE nodes.
set -euo pipefail

count_upgradable() {   # stdin-free; prints an integer, never fails
  apt-get update -qq >/dev/null 2>&1 || true
  apt list --upgradable 2>/dev/null | grep -c '/' || true
}

host=$(hostname -s)
pending=$(count_upgradable)

if command -v pct >/dev/null 2>&1; then
  guests=$(
    pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | while read -r id; do
      name=$(pct config "$id" | awk '/^hostname:/{print $2}')
      n=$(pct exec "$id" -- sh -c 'apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c /' 2>/dev/null || true)
      jq -nc --arg id "$id" --arg name "$name" --argjson n "${n:-0}" '{id:$id, name:$name, pending:$n}'
    done | jq -s .
  )
  jq -nc --arg h "$host" --argjson p "$pending" --argjson g "$guests" \
    '{host:$h, pending:$p, guests:$g, checked:(now|todate)}'
else
  jq -nc --arg h "$host" --argjson p "$pending" '{host:$h, pending:$p, checked:(now|todate)}'
fi
