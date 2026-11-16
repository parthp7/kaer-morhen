#!/usr/bin/env bash
# ssd-burnin.sh — unattended, DESTRUCTIVE burn-in of a SATA SSD from a live system.
#
# Purpose: prove a new drive before installing on it (proposal 013). Runs:
#   1. SMART baseline (attributes + error log)
#   2. full-surface write of a unique, reproducible AES-CTR stream (hashed on the way in)
#   3. full read-back, direct I/O, hash compared, which catches bad blocks AND fake capacity
#   4. 10-min random 4k read/write controller stress (only if fio is installed)
#   5. second full read pass
#   6. SMART after + kernel log scan, then PASS/FAIL. On PASS, blkdiscard (TRIM all).
# A background monitor logs temperature, SMART LBA counters and kernel-log size every
# 60 s. Nobody needs to watch: review the log directory afterwards.
#
# Usage:   bash ssd-burnin.sh <by-id match>        e.g.  bash ssd-burnin.sh EVMM2
#   <by-id match> is a substring that must match EXACTLY ONE whole-disk entry in
#   /dev/disk/by-id/ata-* (never a /dev/sdX name; device letters move in live systems).
# Output:  /root/burnin/  (summary.txt, monitor.log, smart-*.txt, dmesg.txt, *.sha)
# Needs:   root, bash ≥ 4.4, smartctl, openssl, sha256sum, dd, blkdiscard; fio optional.
# Safety:  refuses a disk with mounted partitions or a WDC model, shows model/serial
#          and waits 20 s before writing (Ctrl+C to abort).
set -euo pipefail

match="${1:?usage: bash ssd-burnin.sh <by-id substring, e.g. EVMM2>}"
out=/root/burnin
mkdir -p "$out"
log() { printf '%s  %s\n' "$(date '+%F %T')" "$*" | tee -a "$out/summary.txt"; }

# ---- resolve and guard the target -------------------------------------------
mapfile -t hits < <(find /dev/disk/by-id -name "ata-*${match}*" ! -name '*-part*' | sort)
[[ ${#hits[@]} -eq 1 ]] || { echo "need exactly 1 by-id match for '$match', got ${#hits[@]}: ${hits[*]}" >&2; exit 1; }
D="${hits[0]}"
dev="$(readlink -f "$D")"
info="$(smartctl -i "$D")"
model="$(awk -F': *' '/Device Model/{print $2}' <<<"$info")"
serial="$(awk -F': *' '/Serial Number/{print $2}' <<<"$info")"
[[ "$model" != *WDC* ]] || { echo "refusing: target is a WDC disk ($model)" >&2; exit 1; }
if grep -q "^${dev}" /proc/mounts; then echo "refusing: $dev has mounted partitions" >&2; exit 1; fi
BYTES="$(blockdev --getsize64 "$D")"

log "TARGET $D -> $dev | model=$model serial=$serial bytes=$BYTES"
echo ">>> ALL DATA ON $dev ($model $serial) WILL BE DESTROYED. Ctrl+C within 20 s to abort."
sleep 20

# ---- background monitor ------------------------------------------------------
monitor() {
  echo "time temp_C lbas_written lbas_read dmesg_lines" > "$out/monitor.log"
  while :; do
    a="$(smartctl -A "$D" 2>/dev/null)"
    printf '%s %s %s %s %s\n' "$(date +%T)" \
      "$(awk '$2 ~ /Temperature/ {print $10; exit}' <<<"$a")" \
      "$(awk '$2 == "Total_LBAs_Written" {print $10}' <<<"$a")" \
      "$(awk '$2 == "Total_LBAs_Read" {print $10}' <<<"$a")" \
      "$(dmesg | wc -l)" >> "$out/monitor.log"
    sleep 60
  done
}
dmesg -C
monitor & mon_pid=$!
trap 'kill "$mon_pid" 2>/dev/null || true' EXIT

# ---- 1. baseline -------------------------------------------------------------
smartctl -x "$D" > "$out/smart-before.txt" || true
smartctl -A "$D" > "$out/attrs-before.txt" || true
fail=0

# ---- 2. write ----------------------------------------------------------------
stream() { { openssl enc -aes-128-ctr -nosalt -pass pass:ssd-burnin </dev/zero 2>/dev/null || true; } | head -c "$BYTES"; }
log "WRITE start"
t0=$SECONDS
set +e
stream | tee >(sha256sum | cut -d' ' -f1 > "$out/written.sha") \
       | dd of="$D" bs=1M iflag=fullblock oflag=direct status=none 2>>"$out/dd-errors.txt"
rc=("${PIPESTATUS[@]}")
sync
set -e
for _ in $(seq 30); do [[ -s "$out/written.sha" ]] && break; sleep 1; done
dt=$((SECONDS - t0)); log "WRITE end rc=${rc[*]} ${dt}s avg $((BYTES / 1048576 / (dt > 0 ? dt : 1))) MiB/s"
[[ "${rc[2]}" -eq 0 ]] || { log "FAIL write: dd rc=${rc[2]}"; fail=1; }

# ---- 3. read-back + compare --------------------------------------------------
log "READ1 start"
t0=$SECONDS
set +e
dd if="$D" bs=1M iflag=direct status=none 2>>"$out/dd-errors.txt" | sha256sum | cut -d' ' -f1 > "$out/read.sha"
rrc=${PIPESTATUS[0]}
set -e
dt=$((SECONDS - t0)); log "READ1 end rc=$rrc ${dt}s avg $((BYTES / 1048576 / (dt > 0 ? dt : 1))) MiB/s"
[[ "$rrc" -eq 0 ]] || { log "FAIL read1: dd rc=$rrc"; fail=1; }
if [[ -s "$out/written.sha" && "$(cat "$out/written.sha")" == "$(cat "$out/read.sha")" ]]; then
  log "HASH match $(cat "$out/read.sha")"
else
  log "FAIL hash mismatch written=$(cat "$out/written.sha" 2>/dev/null) read=$(cat "$out/read.sha")"; fail=1
fi

# ---- 4. controller stress (optional) -----------------------------------------
if command -v fio >/dev/null; then
  log "FIO randrw 4k qd32 600s start"
  set +e
  fio --name=stress --filename="$D" --direct=1 --ioengine=libaio --rw=randrw --bs=4k \
      --iodepth=32 --runtime=600 --time_based --group_reporting > "$out/fio.txt" 2>&1
  frc=$?
  set -e
  log "FIO end rc=$frc"
  [[ "$frc" -eq 0 ]] || { log "FAIL fio rc=$frc"; fail=1; }
else
  log "FIO not installed, stress step skipped"
fi

# ---- 5. second read pass -----------------------------------------------------
log "READ2 start"
t0=$SECONDS
set +e
dd if="$D" of=/dev/null bs=1M iflag=direct status=none 2>>"$out/dd-errors.txt"
r2=$?
set -e
dt=$((SECONDS - t0)); log "READ2 end rc=$r2 ${dt}s"
[[ "$r2" -eq 0 ]] || { log "FAIL read2: dd rc=$r2"; fail=1; }

# ---- 6. SMART after + kernel log ---------------------------------------------
smartctl -x "$D" > "$out/smart-after.txt" || true
smartctl -A "$D" > "$out/attrs-after.txt" || true
dmesg -T > "$out/dmesg.txt"
if grep -Eiq 'ata[0-9]+.*(error|exception|reset|frozen|failed)|I/O error|DID_BAD_TARGET' "$out/dmesg.txt"; then
  log "FAIL kernel log has ata/I/O errors (see dmesg.txt)"; fail=1
else
  log "KERNEL log clean"
fi
for id in 1 5 196 197 198 199; do
  b="$(awk -v i="$id" '$1 == i {print $NF}' "$out/attrs-before.txt")"
  a="$(awk -v i="$id" '$1 == i {print $NF}' "$out/attrs-after.txt")"
  [[ -z "$a" ]] && continue
  # fail if the counter moved during the run, or was ever non-zero
  if [[ "$a" != "$b" ]] || (( a != 0 )); then log "FAIL SMART attr $id before=$b after=$a"; fail=1; fi
done
if grep -q 'Error Log not supported' "$out/smart-after.txt"; then
  log "INFO drive has no SMART error log"
elif ! grep -q 'No Errors Logged' "$out/smart-after.txt"; then
  log "WARN SMART error log not empty (see smart-after.txt)"
fi
log "TEMP max $(awk 'NR > 1 && $2 != "" {if ($2 > m) m = $2} END {print m}' "$out/monitor.log") C"

# ---- verdict ------------------------------------------------------------------
if [[ "$fail" -eq 0 ]]; then
  blkdiscard "$D" && log "BLKDISCARD done"
  log "RESULT: PASS"
else
  log "RESULT: FAIL (drive left as-is for inspection)"
fi
