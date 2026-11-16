# 013 — yennefer boot SSD replacement: part 1, burn-in test of the new drive

**Status:** **DONE 2026-11-16.** Part 1 passed; part 2 installed, restored and verified the same night.
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

---

# Part 2: fresh Proxmox VE install and restore

**Inputs, all verified 2026-11-16:**
- **Host config tarball:** `/mnt/backup/yennefer-host-2026-11-15.tgz`.
- **Container backups for 200–205:** in `/mnt/backup/dump/dump/`. They are stopped-mode vzdumps from 11-16, newer than the PBS copies from 11-14.
- **Mac copies:** identical copies of the tarball and all six container backups are in `~/workspace/homelab-backup/yennefer-rebuild/`.
- **Installer:** PVE **9.2-1** ISO on the stick (re-flashed with `dd`).

**Approach:** a fresh install rather than a clone (cloning would have meant
reading the old drive's bad zone). Then put back the host-level state the
installer can't know about:
- the SSH identity (host keys and authorized keys);
- the `/etc/pve` config (storage, backup job, users and API tokens for Pulse and
  homepage, the ntfy notification target);
- the host tweaks (ALPM udev rule, smartd to ntfy, kernel pin, Beszel agent);
- the six containers.

### A. Install (laptop console)

1. Boot the stick (Esc → F9 → USB) → **Install Proxmox VE (Graphical)**.
2. **Target harddisk: the 238 GB `EVMM2/256GB` drive. NOT the 931 GB WDC**, which holds every backup.
   - Options → `ext4`, leave the sizes at their defaults (~60 GB root, ~8 GB swap, the rest goes to the `data` thin pool).
3. Country India, timezone **Asia/Kolkata**, keyboard U.S. English.
4. Root password, and email the same as before.
5. Network:
   - interface `nic0`, and leave **pin network interface names** on, because the old config uses `nic0`;
   - hostname `yennefer.kaermorhen.internal`;
   - IP `<YENNEFER_IP>/24`, gateway `<LAN_PREFIX>.1`, DNS `<LAN_PREFIX>.1`.
6. Install → reboot → remove the stick.

**Done when** `https://<YENNEFER_IP>:8006` shows the login page.

### B. Everything else, over SSH from the Mac (you run it; easier than typing on the laptop)

First login only (the host keys are new until B2):
```bash
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@<YENNEFER_IP>
```

**B1. Mount the backup disk and unpack the old config**
```bash
mkdir -p /mnt/backup
echo 'LABEL=backup /mnt/backup ext4 defaults,noatime,nofail 0 2' >> /etc/fstab
systemctl daemon-reload && mount /mnt/backup && ls /mnt/backup /mnt/backup/dump/dump
mkdir -p /root/old && tar -xzf /mnt/backup/yennefer-host-2026-11-15.tgz -C /root/old
```
Done when the ls shows `pbs/`, `dump/` and the six `vzdump-lxc-20*-2026_11_16-*` files.

**B2. SSH identity**

Restores the old host keys, so `known_hosts` on the Mac, geralt and ciri stays valid.
It also restores the authorized keys and root's own keys.
```bash
cp -a /root/old/etc/ssh/ssh_host_* /etc/ssh/
cp /root/old/etc/pve/priv/authorized_keys /etc/pve/priv/authorized_keys
cp -a /root/old/root/.ssh/id_rsa /root/old/root/.ssh/id_rsa.pub /root/old/root/.ssh/config /root/.ssh/
systemctl restart ssh
```
Done when `exit` then plain `ssh lab-yennefer` logs in with no host-key warning and no password.

**B3. Repos, upgrade, kernel pin**

7.0.14-12 is the kernel this hardware ran clean for 70 days, and it matches geralt's pin.
```bash
cp /root/old/etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/
apt update && apt full-upgrade -y
apt install -y proxmox-kernel-7.0.14-12-pve-signed
proxmox-boot-tool kernel pin 7.0.14-12-pve
```
Done when `apt update` shows no `enterprise.proxmox.com` 401 errors and the pin command reports success.

**B4. Proxmox config**

Restores storage, the 04:30 PBS job, users and API tokens (Pulse, homepage), and ntfy notifications.
```bash
cd /root/old/etc/pve
cp storage.cfg jobs.cfg user.cfg notifications.cfg datacenter.cfg /etc/pve/
mkdir -p /etc/pve/priv/storage
cp priv/token.cfg priv/notifications.cfg /etc/pve/priv/
cp priv/storage/pbs-vault.pw /etc/pve/priv/storage/
pvesm status
```
Done when `local`, `local-lvm` and `backup-dump` are `active`. `pbs-vault` stays inactive until CT 200 is up.

**B5. Host tweaks: ALPM, smartd → ntfy, Beszel agent**
```bash
cp /root/old/etc/udev/rules.d/60-ssd-alpm.rules /etc/udev/rules.d/
cp /root/old/etc/ntfy.topic /etc/ntfy.topic && chmod 600 /etc/ntfy.topic
install -m 755 /root/old/root/smartd-ntfy.sh /usr/local/bin/smartd-ntfy.sh
cp /root/old/etc/smartd.conf /etc/smartd.conf && systemctl restart smartd

S=/root/old/etc/systemd/system/beszel-agent.service
K=$(sed -n 's/.*"KEY=\(.*\)"$/\1/p' $S); T=$(sed -n 's/.*"TOKEN=\(.*\)"$/\1/p' $S)
curl -sL https://get.beszel.dev -o /tmp/install-agent.sh && bash /tmp/install-agent.sh -k "$K" -t "$T"
mkdir -p /etc/systemd/system/beszel-agent.service.d
cp /root/old/etc/systemd/system/beszel-agent.service.d/override.conf /etc/systemd/system/beszel-agent.service.d/
systemctl daemon-reload && systemctl restart beszel-agent && systemctl is-active beszel-agent smartd
```
Done when both report `active`. If the Beszel installer prompts, accept the defaults.

**B6. Restore the six containers**

The six backups are ~2 GB compressed and ~16 GB once restored, which is well inside the drive's ~90 GB fast cache.
```bash
cd /mnt/backup/dump/dump
for id in 200 201 202 203 204 205; do
  pct restore $id vzdump-lxc-$id-2026_11_16-*.tar.zst --storage local-lvm || break
done
pct config 200 | grep mp0      # expect: mp0: /mnt/backup/pbs,mp=/datastore
pct config 203 | grep dev0     # expect: dev0: /dev/net/tun
```
If `mp0` is missing: `pct set 200 -mp0 /mnt/backup/pbs,mp=/datastore`.

**B7. Reboot**

This applies the kernel pin and the ALPM rule. All six containers come back via `onboot: 1`.
```bash
reboot
```

### C. Verify, after the reboot

```bash
uname -r                                                   # 7.0.14-12-pve
swapon --show                                              # /dev/dm-? ~8G — swap back ON
ls -l /sys/block/sd*/device | grep -o 'host[0-9]'; cat /sys/class/scsi_host/host*/link_power_management_policy
pct list                                                   # 200–205 running
pvesm status                                               # all four active, incl. pbs-vault
```

Then check from outside the host:
- **Pi-hole:** `dig @<LAN_PREFIX>.201 google.com` answers.
- **Tailscale:** `pct exec 203 -- tailscale status` shows it online.
- **Kuma:** all yennefer monitors are green.
- **Beszel:** yennefer is reporting.
- **Pulse:** sees yennefer. **Pulse pins the PVE TLS fingerprint**, so after a reinstall its log shows
  `certificate fingerprint mismatch`. Get the new fingerprint with
  `openssl s_client -connect localhost:8006 </dev/null 2>/dev/null | openssl x509 -noout -fingerprint -sha256`
  and paste it into Pulse → Settings → Proxmox → yennefer → Fingerprint. (Done 2026-11-16.)
- **PBS:** GUI → Datacenter → Backup → Run now. All six back up to `pbs-vault` OK.

**Done when** all of the above pass.

### D. After

- Old SSD: keep it labelled for ~2 weeks of clean running, then retire it.
- Switch power: move it back to yennefer's USB if that's still wanted.
- Docs: update `hardware-inventory.md` (sdb model, firmware, the DRAM-less write profile) and `storage.md` (yennefer section).
- Delete `/root/old` once everything is verified. It holds private keys, though only
  in a root-only directory.
