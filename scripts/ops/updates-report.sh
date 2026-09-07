#!/usr/bin/env bash
# updates-report.sh — pending apt upgrades on this host and, on a PVE node,
# inside every RUNNING LXC. Prints ONE JSON object. Read-only apart from
# refreshing apt's lists (the same `apt update` the weekly pass runs); never
# installs anything. Counts apt only — Kuma (npm), Pi-hole, Caddy plugins and
# Docker images are not apt and stay manual (maintenance.md).
# Deliberately jq-free: the PVE nodes don't ship jq and this must not pull a
# package onto a hypervisor for a dashboard tile. Requires: apt; pct on PVE.
set -euo pipefail

count_upgradable() {   # prints an integer, never fails
  local n
  apt-get update -qq >/dev/null 2>&1 || true
  n=$(apt list --upgradable 2>/dev/null | grep -c '/' || true)
  n=${n//[^0-9]/}
  printf '%s' "${n:-0}"
}

host=$(hostname -s)
pending=$(count_upgradable)
checked=$(date -u +%Y-%m-%dT%H:%M:%SZ)

if command -v pct >/dev/null 2>&1; then
  guests=""
  while read -r id; do
    [[ -n $id ]] || continue
    name=$(pct config "$id" | awk '/^hostname:/{print $2}')
    # </dev/null: pct exec must not swallow the id list on the loop's stdin
    n=$(pct exec "$id" -- sh -c 'apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c /' </dev/null 2>/dev/null || true)
    n=${n//[^0-9]/}
    guests+="${guests:+,}{\"id\":\"$id\",\"name\":\"$name\",\"pending\":${n:-0}}"
  done < <(pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}')
  printf '{"host":"%s","pending":%s,"guests":[%s],"checked":"%s"}\n' "$host" "$pending" "$guests" "$checked"
else
  printf '{"host":"%s","pending":%s,"checked":"%s"}\n' "$host" "$pending" "$checked"
fi
