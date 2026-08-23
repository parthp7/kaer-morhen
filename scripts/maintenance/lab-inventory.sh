#!/usr/bin/env bash
#
# lab-inventory.sh — read-only "what is out of date, everywhere" report.
#
# Why this exists
#   The house policy is that nothing auto-updates, so every upgrade is a human
#   decision. A human decision needs an input, and until now that input did not
#   exist: version state was spread across two nodes, eight LXCs, one VM and
#   ~30 pinned images, with no single view. The first run of this script
#   (2026-08-23) immediately found drift nobody had noticed — geralt 98 packages
#   behind yennefer, the two nodes on different pve-manager versions, and six of
#   eight LXCs reporting "0 pending" purely because their apt cache was six
#   weeks stale.
#
# The stale-cache trap this exists to defeat
#   `apt list --upgradable` answers from the LOCAL cache. A container whose
#   cache was last refreshed in July reports zero upgradable packages while
#   being months behind. A "0" is therefore only meaningful next to the cache
#   date, so this script always prints both and marks anything older than
#   STALE_DAYS as UNKNOWN rather than letting it read as healthy.
#
# What it reports (in order)
#   1. Nodes      — PVE version, running vs newest installed kernel, reboot-needed,
#                   pending count + cache age, enterprise-repo state, failed units
#   2. LXCs       — per node: id, hostname, pending count, cache age, stale flag
#   3. Docker VM  — OS, kernel, Docker/Compose/nvidia-ctk versions, pending, cache age
#   4. Images     — running image tags vs the tags pinned in this repo (drift both ways)
#   5. Invariants — geralt's boot-critical settings that a kernel upgrade can silently
#                   drop (vfio D3, usb-storage quirks, VM150 onboot, grub, ZFS ARC)
#
# It never changes state
#   Every remote command is a read. In particular it NEVER runs `apt update` —
#   that rewrites the package lists, and `CLAUDE.md` forbids state-changing
#   commands over ssh. Refreshing caches is the user's job; this script's
#   contribution is telling you which caches need it.
#
# Usage
#   scripts/maintenance/lab-inventory.sh            # report, always exits 0
#   scripts/maintenance/lab-inventory.sh --strict   # exit 1 if an invariant fails
#
# Requires: ssh access to the node aliases below (root), and this repo checked out.
# Env overrides:
#   REPO_DIR NODES DOCKER_HOST GPU_NODE SSH_TIMEOUT STALE_DAYS
#
set -euo pipefail

readonly REPO_DIR="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
readonly NODES="${NODES:-lab-geralt lab-yennefer}"
readonly DOCKER_HOST="${DOCKER_HOST:-lab-ciri}"
readonly GPU_NODE="${GPU_NODE:-lab-geralt}"
readonly SSH_TIMEOUT="${SSH_TIMEOUT:-15}"
readonly STALE_DAYS="${STALE_DAYS:-7}"

STRICT=0
[[ "${1:-}" == "--strict" ]] && STRICT=1
readonly STRICT

INVARIANT_FAILURES=0
INVARIANT_UNKNOWN=0

# --- helpers ---------------------------------------------------------------

# Portable bounded-time wrapper. `timeout(1)` is coreutils and is NOT present on
# a stock macOS, which is where this script normally runs -- the first version
# called it unconditionally, every remote read failed, `|| true` swallowed the
# error, and the report printed a confident "6 INVARIANTS FAILED" for a lab it
# had never actually contacted. Prefer timeout/gtimeout when installed; other-
# wise bound the session with ssh's own keepalives, which is what actually kills
# a hung connection.
RSH_UNREACHABLE=0
rsh() {
  local host="$1"; shift
  local out rc
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout $((SSH_TIMEOUT + 5)) ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
          "$host" "$@" 2>/dev/null); rc=$?
  elif command -v gtimeout >/dev/null 2>&1; then
    out=$(gtimeout $((SSH_TIMEOUT + 5)) ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
          "$host" "$@" 2>/dev/null); rc=$?
  else
    out=$(ssh -o BatchMode=yes -o ConnectTimeout="$SSH_TIMEOUT" \
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3 \
          "$host" "$@" 2>/dev/null); rc=$?
  fi
  # An unreachable host must degrade to a labelled row rather than abort the
  # report under `set -e` -- but it must NEVER be reported as a failed check.
  if (( rc != 0 )); then RSH_UNREACHABLE=1; else RSH_UNREACHABLE=0; fi
  # Terminate the last line. Without the newline a `while read` consumer silently
  # discards the final record -- which dropped the last LXC of every node (104
  # uptime-kuma, 204 beszel) from the report while looking perfectly healthy.
  # Command substitution strips the trailing newline, so blob callers are unaffected.
  printf '%s\n' "$out"
  return 0
}

# Extract a TAB-delimited field from a labelled remote payload.
# Positional (sed -n Np) parsing was tried first and is unsafe: any remote
# command that emits ZERO lines instead of one silently shifts every field
# after it, so "VM 150 onboot" reported grub's cmdline and zfs_arc_max
# reported a filesystem type. Labelled fields cannot slip.
kv() { awk -v k="$2" -F'\t' '$1==k {sub(/^[^\t]*\t/,""); print; exit}' <<<"$1"; }

hr()      { printf '%s\n' "------------------------------------------------------------------"; }
section() { printf '\n== %s ==\n' "$1"; }

# Days since an epoch timestamp; prints "?" when the input is not a number.
days_since() {
  local ts="${1:-}"
  [[ "$ts" =~ ^[0-9]+$ ]] || { printf '?'; return; }
  printf '%d' $(( ( $(date +%s) - ts ) / 86400 ))
}

# "12 (age 41d STALE)" / "0 (age 1d)" / "UNKNOWN (cache 41d stale)"
pending_cell() {
  local count="$1" age="$2"
  if [[ ! "$age" =~ ^[0-9]+$ ]]; then
    printf 'UNKNOWN (no cache)'
  elif (( age > STALE_DAYS )) && [[ "$count" == "0" ]]; then
    printf 'UNKNOWN (cache %sd stale)' "$age"
  elif (( age > STALE_DAYS )); then
    printf '>=%s (cache %sd stale)' "$count" "$age"
  else
    printf '%s (cache %sd)' "$count" "$age"
  fi
}

# check <label> <actual> <expected>
# A blank actual means "we could not read it", which is NOT the same as "it is
# wrong" -- reporting an unread value as FAIL is how a monitoring script lies.
check() {
  local label="$1" actual="$2" expected="$3"
  if [[ -z "$actual" ]]; then
    printf '  ??    %-26s UNREADABLE (expected: %s)\n' "$label" "$expected"
    INVARIANT_UNKNOWN=$(( INVARIANT_UNKNOWN + 1 ))
  elif [[ "$actual" == "$expected" ]]; then
    printf '  OK    %-26s %s\n' "$label" "$actual"
  else
    printf '  FAIL  %-26s %s (expected: %s)\n' "$label" "$actual" "$expected"
    INVARIANT_FAILURES=$(( INVARIANT_FAILURES + 1 ))
  fi
}

# --- 1. nodes --------------------------------------------------------------

report_nodes() {
  section "Proxmox nodes"
  local node
  for node in $NODES; do
    local blob pve running newest pending cache_ts age ent failed
    # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
    blob=$(rsh "$node" '
      printf "pve\t%s\n"     "$(pveversion 2>/dev/null)"
      printf "running\t%s\n" "$(uname -r)"
      printf "newest\t%s\n"  "$(dpkg -l | awk "/^ii +proxmox-kernel-[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-pve(-signed)?[[:space:]]/ {print \$2}" | sed "s/^proxmox-kernel-//; s/-signed$//" | sort -V | tail -1)"
      printf "pending\t%s\n" "$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
      printf "cachets\t%s\n" "$(stat -c %Y /var/lib/apt/lists 2>/dev/null)"
      printf "ent\t%s\n"     "$(grep -l "pve-enterprise\|ceph-squid" /etc/apt/sources.list.d/*.sources 2>/dev/null | xargs -r grep -h "^Enabled:" | sort -u | paste -sd" " -)"
      printf "failed\t%s\n"  "$(systemctl --failed --no-legend | wc -l)"
    ')
    pve=$(kv "$blob" pve)
    running=$(kv "$blob" running)
    newest=$(kv "$blob" newest)
    pending=$(kv "$blob" pending)
    cache_ts=$(kv "$blob" cachets)
    ent=$(kv "$blob" ent)
    failed=$(kv "$blob" failed)
    age=$(days_since "$cache_ts")

    printf '\n%s\n' "$node"
    printf '  %-22s %s\n' "pve-manager"    "${pve:-UNREACHABLE}"
    printf '  %-22s %s\n' "kernel running" "${running:-?}"
    printf '  %-22s %s\n' "kernel newest"  "${newest:-?}"
    # uname -r and the stripped package name are the same shape (7.0.14-4-pve),
    # so this is an equality test, not a substring test.
    if [[ -n "$running" && -n "$newest" && "$running" != "$newest" ]]; then
      printf '  %-22s %s\n' "REBOOT NEEDED" "running $running, installed $newest"
    fi
    printf '  %-22s %s\n' "pending pkgs"   "$(pending_cell "${pending:-0}" "$age")"
    printf '  %-22s %s\n' "enterprise repo" "${ent:-? } (want: Enabled: false)"
    printf '  %-22s %s\n' "failed units"   "${failed:-?}"
  done
}

# --- 2. LXCs ---------------------------------------------------------------

report_lxcs() {
  section "LXC guests"
  local node
  for node in $NODES; do
    printf '\n%s\n' "$node"
    printf '  %-6s %-16s %s\n' "VMID" "HOSTNAME" "PENDING"
    # One ssh round trip per node; the inner loop runs on the node itself.
    # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
    rsh "$node" '
      pct list | tail -n +2 | awk "{print \$1, \$2}" | while read -r id status; do
        name=$(pct config "$id" </dev/null 2>/dev/null | sed -n "s/^hostname: //p")
        if [ "$status" != "running" ]; then
          echo "$id ${name:-?} - $status"
          continue
        fi
        cnt=$(pct exec "$id" -- apt list --upgradable </dev/null 2>/dev/null | tail -n +2 | wc -l)
        ts=$(pct exec "$id" -- stat -c %Y /var/lib/apt/lists </dev/null 2>/dev/null || echo -)
        echo "$id ${name:-?} ${cnt:-?} ${ts:-tot}"
      done
    ' | while read -r id name cnt ts; do
        if [[ "$cnt" == "-" ]]; then
          printf '  %-6s %-16s %s\n' "$id" "$name" "not running ($ts)"
        else
          printf '  %-6s %-16s %s\n' "$id" "$name" "$(pending_cell "$cnt" "$(days_since "$ts")")"
        fi
      done
  done
}

# --- 3. docker VM ----------------------------------------------------------

report_docker_host() {
  section "Docker VM ($DOCKER_HOST)"
  local blob
  # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
  blob=$(rsh "$DOCKER_HOST" '
    printf "os\t%s\n"      "$(. /etc/os-release; echo "$PRETTY_NAME")"
    printf "kernel\t%s\n"  "$(uname -r)"
    printf "docker\t%s\n"  "$(docker --version 2>/dev/null | sed "s/,.*//")"
    printf "compose\t%s\n" "$(docker compose version 2>/dev/null | head -1)"
    printf "ctk\t%s\n"     "$(nvidia-ctk --version 2>/dev/null | head -1)"
    printf "pending\t%s\n" "$(apt list --upgradable 2>/dev/null | tail -n +2 | wc -l)"
    printf "cachets\t%s\n" "$(stat -c %Y /var/lib/apt/lists 2>/dev/null)"
  ')
  printf '  %-22s %s\n' "os"         "$(kv "$blob" os)"
  printf '  %-22s %s\n' "kernel"     "$(kv "$blob" kernel)"
  printf '  %-22s %s\n' "docker"     "$(kv "$blob" docker)"
  printf '  %-22s %s\n' "compose"    "$(kv "$blob" compose)"
  printf '  %-22s %s\n' "nvidia-ctk" "$(kv "$blob" ctk)"
  printf '  %-22s %s\n' "pending pkgs" \
    "$(pending_cell "$(kv "$blob" pending)" "$(days_since "$(kv "$blob" cachets)")")"
}

# --- 4. image drift --------------------------------------------------------

report_images() {
  section "Container images — live vs repo"

  local live repo
  # Normalise away the implicit docker.io/ prefix on both sides so that
  # `docker.io/valkey/valkey:9` in compose and `valkey/valkey:9` in `docker ps`
  # do not read as drift.
  # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
  live=$(rsh "$DOCKER_HOST" 'docker ps --format "{{.Image}}"' \
         | sed 's#^docker\.io/##' | sort -u)

  # Every image: line in the mirrored compose files. The repo is supposed to be
  # a byte-identical mirror of /data/stacks, so a mismatch is real drift.
  repo=$(grep -rhE '^\s*image:\s*' "$REPO_DIR"/configs/*/*/compose.yaml 2>/dev/null \
         | sed -E 's/^[[:space:]]*image:[[:space:]]*//; s/[[:space:]]*(#.*)?$//' \
         | sed 's#^docker\.io/##' | sort -u)

  printf '\n  Running but NOT pinned in repo (investigate):\n'
  comm -23 <(printf '%s\n' "$live") <(printf '%s\n' "$repo") | sed 's/^/    /' || true
  printf '\n  Pinned in repo but NOT running (stack down, or not deployed):\n'
  comm -13 <(printf '%s\n' "$live") <(printf '%s\n' "$repo") | sed 's/^/    /' || true

  printf '\n  Floating tags (violate the pinning policy — a rollback cannot name a version):\n'
  printf '%s\n' "$repo" | grep -E ':(latest|stable|[0-9]+)$' | sed 's/^/    /' || true
}

# --- 5. invariants ---------------------------------------------------------

report_invariants() {
  section "Boot-critical invariants ($GPU_NODE)"
  echo "  These are the settings a kernel or package upgrade can silently drop."
  local blob
  # shellcheck disable=SC2016  # single quotes intentional: the REMOTE shell expands this
  blob=$(rsh "$GPU_NODE" '
    printf "d3\t%s\n"     "$(cat /sys/module/vfio_pci/parameters/disable_idle_d3 2>/dev/null)"
    printf "quirks\t%s\n" "$(cat /sys/module/usb_storage/parameters/quirks 2>/dev/null)"
    printf "onboot\t%s\n" "$(qm config 150 2>/dev/null | sed -n "s/^onboot: //p")"
    printf "grub\t%s\n"   "$(sed -n "s/^GRUB_CMDLINE_LINUX_DEFAULT=//p" /etc/default/grub 2>/dev/null)"
    printf "arc\t%s\n"    "$(cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null)"
    printf "media\t%s\n"  "$(findmnt --first-only --mountpoint /mnt/media -o FSTYPE -n 2>/dev/null)"
  ')
  if (( RSH_UNREACHABLE )) || [[ -z "${blob//[$'\n' ]/}" ]]; then
    printf '  %s is UNREACHABLE - invariants not checked.\n' "$GPU_NODE"
    INVARIANT_UNKNOWN=$(( INVARIANT_UNKNOWN + 6 ))
    return 0
  fi
  echo
  check "vfio disable_idle_d3"    "$(kv "$blob" d3)"     "Y"
  check "usb_storage quirks"      "$(kv "$blob" quirks)" "0bc2:ab24:u"
  check "VM 150 onboot"           "$(kv "$blob" onboot)" "1"
  check "grub cmdline (no quiet)" "$(kv "$blob" grub)"   '""'
  check "zfs_arc_max (2 GiB)"     "$(kv "$blob" arc)"    "2147483648"
  check "/mnt/media fstype"       "$(kv "$blob" media)"  "ext4"
}

# --- main ------------------------------------------------------------------

main() {
  printf 'kaermorhen lab inventory — %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')"
  printf 'repo: %s\n' "$REPO_DIR"
  hr
  report_nodes
  report_lxcs
  report_docker_host
  report_images
  report_invariants
  echo
  hr
  if (( INVARIANT_FAILURES > 0 )); then
    printf 'INVARIANTS: %d FAILED — do not proceed with upgrades until resolved.\n' "$INVARIANT_FAILURES"
    (( INVARIANT_UNKNOWN > 0 )) && printf 'INVARIANTS: %d UNREADABLE.\n' "$INVARIANT_UNKNOWN"
    (( STRICT )) && exit 1
  elif (( INVARIANT_UNKNOWN > 0 )); then
    printf 'INVARIANTS: %d UNREADABLE — host unreachable or value missing.\n' "$INVARIANT_UNKNOWN"
    printf '            This is NOT a pass. Resolve access before upgrading.\n'
    (( STRICT )) && exit 1
  else
    printf 'INVARIANTS: all passed.\n'
  fi
  printf 'Note: "UNKNOWN (cache Nd stale)" means apt update has not run there —\n'
  printf '      the count is not zero, it is unmeasured. Refresh before deciding.\n'
  exit 0
}

main "$@"
