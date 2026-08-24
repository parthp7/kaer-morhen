# scripts/proxmox

Host-level scripts for the Proxmox nodes (see [docs/storage.md](../../docs/storage.md)).

## vm150-require-virtiofs.sh

Proxmox `hookscript` for VM 150 (ciri). Refuses to start the VM when a **required**
virtiofs-shared host directory is not the real backing filesystem, and warns but
starts anyway for **advisory** ones.

- **Deployed to**: `/var/lib/vz/snippets/vm150-require-virtiofs.sh` on geralt (0755)
- **Wired via**: `qm set 150 --hookscript local:snippets/vm150-require-virtiofs.sh`
- Tiers: `/steel/photos` **required** (Immich originals, irreplaceable).
  `/mnt/media` left the list on 2026-08-23 — it is served over NFS now, not
  virtiofs, so there is no start-time inode pin to guard.

Added after the [2026-07-27 wrong-filesystem incident](../../docs/storage.md#incident-2026-07-27--28--virtiofs-served-the-wrong-filesystem).
It covers `pre-start` only — it cannot see a disk that drops **while the VM
runs**, which is what [proposal 004](../../docs/proposals/004-media-mount-self-healing.md)
is for.

## media-autoheal.sh + media-autoheal.service + 99-media-autoheal.rules

Self-healing media mount. When the USB media disk re-enumerates after a bus
drop, udev starts a oneshot service that remounts `/mnt/media` and refreshes its
NFS export — so ciri's `hard` NFS clients unblock on their own.

- **Deployed to** geralt: `/usr/local/sbin/media-autoheal.sh` (0755),
  `/etc/systemd/system/media-autoheal.service` (0644),
  `/etc/udev/rules.d/99-media-autoheal.rules` (0644)
- **Trigger**: `ACTION=="add"` on `ID_FS_LABEL=media` + `ID_FS_TYPE=ext4`.
  Matching on **label, not kernel name**, is the whole point — the name changing
  (`sdb`→`sdc`→`sdd`) is the failure mode.
- **Repair**: dead-mount detach (`umount -l`) → `systemctl start mnt-media.mount`
  (systemd-fsck runs as its passno-2 dependency, so boot and repair share one
  code path) → `exportfs -ra`. ntfy on every repair, refusal and failure.
- **No VM restart, ever.** That was
  [proposal 004](../../docs/proposals/004-media-mount-self-healing.md)'s design,
  necessary only because virtiofsd pinned the share's inode at VM start.
  [Proposal 005](../../docs/proposals/005-nfs-media-share.md) moved media to NFS
  and removed the constraint; the rate-limiting apparatus 004 needed went with it.

### The liveness probe is two-stage, and both stages matter

`is_readable()` does a readdir **and** an `O_DIRECT` byte read of
`library/.mount-health`. Do not reduce it to either half:

| Probe | Catches | Misses |
|---|---|---|
| `stat` / `-d` / `df` | nothing useful | a shut-down ext4 — `df` reported 916 G throughout the 2026-08-10 outage |
| readdir alone | mounted-but-wrong/empty filesystem | **a dead backing store**, when the directory is small and recently accessed |
| readdir + `O_DIRECT` | both | — |

Measured on the first live heal test, 2026-08-23. The disk had re-enumerated
`sdb`→`sdc` and `/mnt/media` was still the dead `sdb1` (mount option
`shutdown`). On that same corpse:

```
ls -1 /mnt/media/library                     -> audiobooks movies tv   exit 0
dd iflag=direct .../library/.mount-health    -> Input/output error     exit 1
```

The three-entry directory was served entirely from the dentry cache, so the
readdir-only probe returned true and autoheal exited *"nothing to heal"* while
nfsd went on exporting a dead filesystem. **A healer must never use a weaker
probe than the monitors watching it** — `media-mount-health.sh` and
`media-export-health.sh` had both correctly flagged the fault via `O_DIRECT`
while autoheal insisted all was well.

Verified end to end 2026-08-23 (USB unbind/bind on port `2-3`): heal completed
in **13 s**, ciri's uptime unbroken, **zero container restarts**.

## `nic-pcie-tune.sh` + `nic-pcie-tune.service`

Disables PCIe ASPM and 802.3x flow control on geralt's primary NIC at boot.
Full analysis: [docs/geralt-nic-throughput.md](../../docs/geralt-nic-throughput.md).

Two defects on the Killer E2400 (`alx`), both found on 2026-08-24 while chasing
slow `apt` downloads, both **fixed here and neither the actual cause**:

- **ASPM L0s enabled** on both ends of the link, device declaring *unlimited* L1
  exit latency and not asserting ASPM optionality compliance — a correctable PCIe
  error storm at **~24,800/hour**, 3.9 million since boot. Clearing ASPM on the
  device *and* its upstream bridge (it is negotiated per link, so one end is not
  enough) takes it to **0**.
- **802.3x flow control negotiated on** — an RX FIFO overrun made the NIC emit
  PAUSE frames, stalling the switch port for all inbound traffic instead of
  dropping one packet. yennefer's Realtek negotiates pause off and never does this.

The real cause of the slow downloads is a ~5% RX FIFO drop rate under load that
`alx` gives no way to tune; the mitigation is a LAN-local apt cache, not this
script. These fixes are kept anyway: a link logging 24,800 correctable errors an
hour is degrading unwatched, and PAUSE frames escalate a one-packet problem into
a link-wide stall.

**Why a systemd unit and not `pcie_aspm=off` on the cmdline.** geralt has a
documented history of intermittent boot hangs caused by a GRUB cmdline change
(the reverted `usb-storage.quirks` attempt, 2026-07-28 — see
[storage.md](../../docs/storage.md)). Boot-path changes on this node have a bad
track record, so this stays out of it entirely — and the cmdline could not cover
flow control anyway.

```bash
# deploy on geralt
install -m 0755 nic-pcie-tune.sh /usr/local/sbin/
install -m 0644 nic-pcie-tune.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now nic-pcie-tune.service

# verify
systemctl status nic-pcie-tune --no-pager
lspci -vv -s 05:00.0 | grep LnkCtl          # expect: ASPM Disabled
ethtool -a nic0                             # expect: RX: off / TX: off
grep TOTAL_ERR_COR /sys/bus/pci/devices/0000:05:00.0/aer_dev_correctable  # sample twice
```

Env overrides: `NIC`, `PCI_DEV`, `DISABLE_ASPM`, `DISABLE_PAUSE`. The unit runs
`Before=network-pre.target` so the link is clean before the bridge comes up, and
carries an explicit `TimeoutStartSec` — a `Type=oneshot` unit with the default
infinite timeout would hang `network-pre.target` forever if `setpci` wedged.
