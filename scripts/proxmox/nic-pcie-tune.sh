#!/usr/bin/env bash
#
# nic-pcie-tune.sh — disable ASPM and 802.3x flow control on a PCIe NIC.
#
# Why this exists
#   geralt's Killer E2400 (Atheros, `alx` driver) shipped two independent
#   defects, both found while investigating slow `apt` downloads on 2026-08-24
#   (full RCA: docs/geralt-nic-throughput.md):
#
#   1. ASPM L0s was enabled on both ends of the link, with the device declaring
#      *unlimited* L1 exit latency and NOT asserting ASPM optionality
#      compliance. The result was a correctable PCIe error storm --
#      RxErr / BadTLP / BadDLLP / Timeout -- running at ~24,800 errors/hour and
#      3.9 MILLION since boot. Clearing ASPM on the device and its upstream
#      bridge takes that to exactly ZERO.
#
#   2. 802.3x flow control was negotiated ON. When the NIC overruns its RX FIFO
#      it emits PAUSE frames, throttling the switch port for ALL inbound
#      traffic instead of dropping one packet and letting TCP recover in
#      microseconds. yennefer's Realtek negotiates pause OFF and never does this.
#
#   Neither of these is the root cause of the slow downloads -- that is the
#   NIC's ~5% RX FIFO drop rate under load, which is not tunable (`alx` exposes
#   neither ring sizing nor interrupt coalescing). Both are worth fixing anyway:
#   a link that logs 24,800 correctable errors an hour is a link degrading in a
#   way nobody is watching, and PAUSE frames turn a one-packet problem into a
#   link-wide stall.
#
# Why a systemd unit and not the kernel cmdline
#   `pcie_aspm=off` on the cmdline would cover the ASPM half. It is deliberately
#   NOT used here: geralt has a documented history of intermittent boot hangs
#   caused by a GRUB cmdline change (the usb-storage quirks incident,
#   2026-07-28, reverted -- see docs/storage.md). Boot-path changes on this node
#   have a bad track record, so this stays out of the boot path entirely and
#   also covers flow control, which the cmdline cannot.
#
# What it does NOT do
#   It does not make WAN downloads fast. See the RCA for the apt-cache
#   workaround, which is the actual mitigation.
#
# Usage
#   nic-pcie-tune.sh                 # uses the defaults below
#   NIC=nic0 PCI_DEV=0000:05:00.0 nic-pcie-tune.sh
#
# Deploy (on geralt)
#   install -m 0755 nic-pcie-tune.sh /usr/local/sbin/
#   install -m 0644 nic-pcie-tune.service /etc/systemd/system/
#   systemctl daemon-reload && systemctl enable --now nic-pcie-tune.service
#
# Requires: setpci, ethtool, lspci (pciutils). Root.
# Env overrides: NIC, PCI_DEV, DISABLE_ASPM, DISABLE_PAUSE
#
set -euo pipefail

readonly NIC="${NIC:-nic0}"
readonly PCI_DEV="${PCI_DEV:-0000:05:00.0}"
readonly DISABLE_ASPM="${DISABLE_ASPM:-1}"
readonly DISABLE_PAUSE="${DISABLE_PAUSE:-1}"

log() { printf 'nic-pcie-tune: %s\n' "$*"; }
die() { printf 'nic-pcie-tune: FAIL — %s\n' "$*" >&2; exit 1; }

# ASPM is negotiated per LINK, so it must be cleared on BOTH ends -- the device
# and its upstream bridge. Clearing only the endpoint leaves the link in L0s.
upstream_bridge() {
  local path; path=$(readlink -f "/sys/bus/pci/devices/$PCI_DEV" 2>/dev/null) || return 1
  basename "$(dirname "$path")"
}

# Clear the low 2 bits (ASPM control) of the PCIe Link Control register.
clear_aspm() {
  local dev="$1" cur new
  cur=$(setpci -s "$dev" CAP_EXP+10.w 2>/dev/null) || { log "no PCIe cap on $dev — skipping"; return 0; }
  new=$(printf '%04x' $(( 0x$cur & ~0x3 )))
  if [[ "$cur" == "$new" ]]; then
    log "$dev ASPM already disabled (LnkCtl=0x$cur)"
  else
    setpci -s "$dev" "CAP_EXP+10.w=$new" || die "setpci failed on $dev"
    log "$dev ASPM disabled (LnkCtl 0x$cur -> 0x$new)"
  fi
}

main() {
  [[ -e "/sys/bus/pci/devices/$PCI_DEV" ]] || die "PCI device $PCI_DEV not present"

  if (( DISABLE_ASPM )); then
    local br
    br=$(upstream_bridge) || die "cannot resolve upstream bridge for $PCI_DEV"
    log "device=$PCI_DEV bridge=$br"
    clear_aspm "$br"
    clear_aspm "$PCI_DEV"
  fi

  if (( DISABLE_PAUSE )); then
    if [[ -e "/sys/class/net/$NIC" ]]; then
      # `|| true`: some drivers reject autoneg off; the pause settings still
      # apply, and a non-zero exit here must not fail the whole unit.
      ethtool -A "$NIC" autoneg off rx off tx off 2>/dev/null || true
      log "$NIC flow control: $(ethtool -a "$NIC" 2>/dev/null | awk '/^RX:/{r=$2} /^TX:/{t=$2} END{print "rx="r" tx="t}')"
    else
      log "interface $NIC not present — skipping flow control"
    fi
  fi

  # Report the AER counter so the journal carries a before/after trail.
  local aer="/sys/bus/pci/devices/$PCI_DEV/aer_dev_correctable"
  [[ -r "$aer" ]] && log "AER correctable total at apply time: $(awk '/TOTAL_ERR_COR/{print $2}' "$aer")"
  log "done"
}

main "$@"
