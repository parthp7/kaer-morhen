# 013 — yennefer boot SSD replacement: part 1, burn-in test of the new drive

**Status:** part 1 **PASSED** 2026-11-16 (results at the end). Part 2 not started.
**Why:** yennefer's boot SSD (NFORCE 256M2 G2, `sdb`) hangs its controller on a
fixed LBA zone, sectors ~2.71M–2.79M, which sits inside `pve-swap`. A
`dd` read freezes at the same byte every time, before and after a reseat. The
fault is in the drive, and reformatting won't remove it. Swap is off as a stopgap.
**New drive:** EVM 256GB M.2 2280 SATA, part `EVMM2/256GB`, serial `<NEW_SSD_SERIAL>`.

Part 1 (this doc) proves the new drive is sound **before** anything is installed
on it. Part 2, the fresh Proxmox install plus restore, is a separate doc that is
only written once part 1 passes.

## Boot medium — recommendation

yennefer has one M.2 slot, so the test runs from a USB stick with the new SSD in
that slot.

**Use [Ventoy](https://www.ventoy.net) on one stick (≥ 8 GB) carrying two ISOs:**

| ISO | Used for |
|---|---|
| **SystemRescue** (latest stable) | Part 1, this test. It is a live system with `smartctl`, `hdparm`, `blkdiscard`, `openssl`, `dd`, `badblocks` (and usually `fio`) built in. It needs no install and no network. |
| **Proxmox VE 9.x ISO** (latest stable, matching the current 9.2 line) | Part 2, the install. Having it on the same stick saves a re-flash. |

Why not the alternatives:

- **Proxmox installer.** Not a live environment. Its debug shell lacks the test tools.
- **Ubuntu live.** Would work, but `smartmontools` and `fio` need `apt` and a
  network in the live session.

Fallback: if the PVE ISO won't boot through Ventoy, flash it on its own with
balenaEtcher or `dd` for part 2.

**As run (2026-11-16):** a single 8 GB stick, flashed from the Mac with `dd`, one ISO
at a time. It carries SystemRescue for part 1 and is re-flashed with the PVE ISO
for part 2. Ventoy has no macOS installer, so it wasn't used.
HP boot keys: **Esc** opens the startup menu, **F9** the boot device list,
**F10** BIOS setup. If the stick is refused, disable Secure Boot in F10.

## Blast radius while yennefer is down

- **LAN:** the switch normally runs off yennefer's USB (an accepted trade-off since
  2026-09-11). **For this maintenance it has been moved to wall power (2026-11-16),
  so yennefer's power cycles won't drop the LAN.** Move it back to yennefer's USB
  once part 2 is finished, if that is still the plan.
- **Down for the duration:** PBS (CT 200), so no backups;
  `pihole-2` and `tailscale-1` fail over to geralt's pair; and the other yennefer
  LXCs (201–205). Kuma will alert on these, which is expected.
- **Not affected:** geralt and ciri. The nodes are **standalone** (no corosync
  cluster, checked 2026-11-16), so there is no quorum loss on geralt.
- **The WD backup HDD (`sda`) stays connected** and holds the only local copy of
  the vzdump and the PBS datastore. Every write command below targets the new SSD
  **by `/dev/disk/by-id/` path, never `/dev/sdX`**. Device letters can swap in a
  live system.

---

## Step ladder

Each step has **Do**, then **Verify**, then **Done when**. You run everything.
Paste the outputs back for review: I can't reach SystemRescue over ssh, and I
won't anyway, since the tests write.

### Step 0 — Pre-flight on the old drive (yennefer still running)

**Do**

1. Run a fresh PBS backup of 201–205: GUI → Datacenter → Backup → select the job → **Run now**.
2. Copy the restore inputs to the Mac. This is a read from yennefer, run from the Mac:
   ```bash
   mkdir -p ~/yennefer-rebuild
   scp lab-yennefer:/mnt/backup/yennefer-host-2026-11-15.tgz ~/yennefer-rebuild/
   scp lab-yennefer:/mnt/backup/dump/dump/vzdump-lxc-200-2026_11_16-00_42_31.tar.zst ~/yennefer-rebuild/
   ```
3. Build the Ventoy stick with both ISOs. Check each ISO's SHA-256 against the
   publisher's value.

**Verify**

- The PBS task log shows all five backups `OK`.
- `shasum -a 256 ~/yennefer-rebuild/*` on the Mac. Compare the vzdump against
  `ssh lab-yennefer 'sha256sum /mnt/backup/dump/dump/vzdump-lxc-200-*.tar.zst'`. I can do this comparison for you.

**Done when** the backups are fresh, both files are on the Mac with matching hashes, and the stick is ready.

### Step 1 — Swap the drive

**Do**

1. `shutdown -h now` on yennefer. The LAN drops here.
2. Unplug power. Remove the old SSD, **label it "BAD — LBA ~2.71M, swap zone"**
   and store it untouched. It is the fallback if the new drive fails.
3. Fit the EVM SSD. Plug in the stick and power on, then Esc → F9 → USB → Ventoy → SystemRescue (default boot entry).

**Verify** (SystemRescue console)
```bash
lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN
ls -l /dev/disk/by-id/ | grep -v part
```

**Done when** an `EVM…` disk of ~238.5 GiB is listed with serial `<NEW_SSD_SERIAL>`, and the WD shows as a separate disk.

### Step 2 — Lock the target and take a baseline

**Do**
```bash
D=/dev/disk/by-id/ata-EVM…        # tab-complete the EVM entry, NOT the WDC one
readlink -f "$D"                   # note the /dev/sdX it maps to
smartctl -x "$D" | tee /root/smart-before.txt
cat /sys/class/scsi_host/host*/link_power_management_policy
dmesg -C                           # clear the kernel ring so later checks are clean
```

**Verify** in `smart-before.txt`:

- Model `EVM…` and serial matching the label.
- Record the exact byte count from `User Capacity`.
- `SMART overall-health: PASSED`.
- Power-on hours and lifetime writes near 0, since the drive is new.
- Reallocated, pending, uncorrectable and CRC (attribute 199) counts at 0.
- Note whether the drive lists TRIM and self-test support.

**Done when** the identity matches and the baseline is clean. If power-on hours
or lifetime writes are large, the drive is used or refurbished. Stop and decide
whether to return it.

### Step 3 — SMART self-tests

**Do**
```bash
smartctl -t short "$D"; sleep 150; smartctl -l selftest "$D"
smartctl -t long  "$D"   # prints an estimated duration; wait that long
smartctl -l selftest "$D"
```

**Done when** both tests show `Completed without error`. If the drive doesn't
support self-tests, note it and continue. Steps 4–5 are the real test anyway.

### Step 4 — Full-surface write, then verify every byte (destructive)

This writes **unique**, reproducible data across the whole drive, then reads it
all back and compares hashes. Unique data matters: it also catches a drive that
lies about its capacity and wraps writes around. A repeating pattern, such as
`badblocks -t random`, would miss that. The read-back is also the exact access
pattern that killed the old drive.

**Do** (expect ~30–60 min write and ~10–15 min read, since budget DRAM-less drives slow down once their SLC cache fills)
```bash
BYTES=$(blockdev --getsize64 "$D"); echo "$BYTES"
stream() { openssl enc -aes-128-ctr -nosalt -pass pass:yennefer-burnin </dev/zero 2>/dev/null | head -c "$BYTES"; }

# write: hash the stream on the way in
stream | tee >(sha256sum > /root/written.sha) \
       | dd of="$D" bs=1M iflag=fullblock oflag=direct status=progress
sync

# read back, bypassing cache
dd if="$D" bs=1M iflag=direct status=progress | sha256sum > /root/read.sha
cat /root/written.sha /root/read.sha
```
In a second console (Alt+F2), keep an eye on temperature and errors:
```bash
watch -n 30 'smartctl -A '"$D"' | grep -i temp; dmesg | tail -5'
```

**Verify**

- The two hashes are **identical**.
- `dd` reports `$BYTES` bytes copied, with no `Input/output error`.
- Note the write speed through the run. A drop to ~100–150 MB/s after the cache
  fills is normal. A stall to 0 or a hang is not.

**Done when** the hashes match and both passes finish without error.

### Step 5 — Second read pass plus kernel check

**Do**
```bash
dd if="$D" of=/dev/null bs=1M iflag=direct status=progress
dmesg -T | grep -Ei 'ata[0-9]+|reset|frozen|failed command|I/O error|DID_BAD_TARGET'
```
Optional, if `command -v fio` finds it: run a 10-minute random mixed load to stress the controller. The old failure was a controller hang.
```bash
fio --name=stress --filename="$D" --direct=1 --ioengine=libaio --rw=randrw \
    --bs=4k --iodepth=32 --runtime=600 --time_based --group_reporting
```

**Done when** the read pass completes, the `dmesg` grep shows only the boot-time
link-up lines (no resets, freezes or errors), and fio, if run, finishes with
`err=0`.

### Step 6 — After-SMART and reset

**Do**
```bash
smartctl -x "$D" | tee /root/smart-after.txt
diff <(grep -E '^ *(5|187|196|197|198|199|231|241) ' /root/smart-before.txt) \
     <(grep -E '^ *(5|187|196|197|198|199|231|241) ' /root/smart-after.txt)
blkdiscard "$D"            # return every cell to "free" for the install
```
The attribute IDs vary by vendor. If the grep is empty, compare the full
attribute tables by eye.

**Done when** reallocated, pending, uncorrectable and CRC counts are still 0.
Only the writes counter (≈ +256 GB) and power-on hours should have moved.

---

## Pass / fail

| Result | Next |
|---|---|
| **All steps pass** | Shut down with the new SSD left in and go to part 2, the fresh PVE 9.x install and restore (doc written after this passes). |
| **Any I/O error, reset, hash mismatch, or SMART media counters > 0** | The drive is bad: return it. Refit the labelled old SSD. yennefer runs as before, swap off, until the next drive arrives. |
| **CRC (199) > 0 but media counters clean** | This points at the slot or connector, not the drive. Reseat it and rerun step 5 before judging. |

## Outputs to keep

Copy `/root/smart-before.txt`, `/root/smart-after.txt` and both `.sha` files off
before shutting down. SystemRescue keeps nothing after a reboot. Options: photograph
the key lines, or mount a spare USB stick and copy them there. **Don't write them to
the WD backup disk.** They get pasted here and summarised in `docs/storage.md`
after part 2.

---

## As-run results — 2026-11-16 — PASS

Run unattended with [`scripts/hardware/ssd-burnin.sh`](../../scripts/hardware/ssd-burnin.sh)
from SystemRescue in `copytoram` mode, with the stick removed after boot. Steps 4–6
were automated. Start 13:47 UTC, end 15:48 UTC.

| Check | Result |
|---|---|
| Identity | `EVMM2/256GB`, firmware HDFEF3.4, 256,060,514,304 B, 0 power-on hours, 0 bytes written when new |
| SMART self-tests | short ✅, extended (90 min) ✅ |
| Full write, unique AES-CTR stream | rc 0. 71.6 min, avg 56 MiB/s |
| Full read-back | rc 0, **SHA-256 match**: no bad blocks, capacity is genuine |
| Second raw read | rc 0, ~270 MB/s (15.6 min) |
| Kernel log | 0 ata/IO/reset messages |
| SMART 1/5/196/197/198/199 | 0 before and after. CRC 0, uncorrectable 0 |
| Temperature | 22 → max 38 °C |
| fio stress | skipped (not shipped on SystemRescue) |
| End state | `blkdiscard` done, ready for install |

**Write profile.** About 90 GB at the CPU-bound ~115 MB/s (the drive's SLC cache),
then a steady **~49 MB/s** for the rest of the run, with no stalls. The drive is
DRAM-less, so large sustained writes (bulk restores, big vzdumps landing on this
SSD) will run at that speed once past the cache. That's fine for a boot and
light-guest disk.

**Firmware quirks — not faults, don't alert on them:**
- Device Statistics "Percentage Used Endurance Indicator" read 91 before and 73
  after, with flag `C` set. A "used" value can't go down, so the field is unreliable.
- Device Statistics temperature reads -41/-14 °C, which is also garbage. Attribute
  194 is the correct temperature.
- The drive has no SMART error log ("not supported"). The script's
  "error log not empty" WARN is a false positive caused by that.
- Track wear with attribute 165 (max erase count, 11 → 17) and 167 (avg, 10 → 13).

**Gotcha.** The first SystemRescue session (booted without copytoram) lost the stick to a
USB disconnect, and every later binary load failed with squashfs I/O errors. Always
use `copytoram` for long tests.
