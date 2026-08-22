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
