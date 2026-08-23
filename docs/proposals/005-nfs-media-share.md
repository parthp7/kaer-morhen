# Proposal 005 — NFS media share on a dedicated storage network

- **Status**: **DEPLOYED 2026-08-23.** Phases A, B and C complete; Phase D
  passed on D1, D2, **D3**, D4, D5 and D6 (only D7 worst-case-boot not run).
  The design text and runbook below are preserved **as written**, so they no
  longer match the system in the twelve places listed in
  [As-built deviations](#as-built-deviations-2026-08-23) — read that section
  before trusting any command here. Phase E doc reconciliation is **complete**
  (`b50c29f`); this document, both directory READMEs, `storage.md`,
  `network.md`, `docker-vm.md` and `uptime-kuma.md` all reflect as-built.
- **Scope**: `geralt` (NFS server, storage bridge, autoheal) and `ciri`
  (NFS client, new scratch disk, servarr changes). `yennefer` untouched.
  **`/steel/photos` and its virtiofs share are explicitly out of scope** —
  photos will grow into steel and stay exactly as they are.
- **Supersedes**: the VM-restart half of
  [proposal 004](004-media-mount-self-healing.md). The host-remount half of 004
  (udev → remount) is absorbed here (§6, Appendix A); the `qm stop/start` half
  becomes unnecessary, which was the point. 004's §5 (Kuma `resend_interval`)
  is carried forward unchanged (§8).
- **Decided with**: virtiofs pinning analysis in
  [storage.md](../storage.md#incident-2026-08-10--22--usb-link-fault-12-day-silent-outage)
  (three incidents: 2026-07-27, 08-03, 08-10).

Placeholders per `CLAUDE.md`: `<LAN_PREFIX>` as usual, plus a new
`<STORAGE_PREFIX>` (the `10.x.y` part of the storage /24), both resolved in
`secrets.local.yaml`. Storage-net addresses follow the **same last-octet
convention as the LAN**: geralt `.21`, ciri `.150`.

---

## 0. Execution contract (read first if you are the agent running this)

This section binds whoever executes the runbook — human or model.

1. **The user runs every modifying command.** `CLAUDE.md` forbids write
   commands over ssh, and the standing working pattern is: agent prepares the
   exact command block, user runs it (in their own terminal, or via `! ssh …`
   in the session), agent then **verifies read-only** over `ssh lab-geralt` /
   `ssh lab-ciri`. Commands below are labelled **[USER]** or **[VERIFY]**
   accordingly. Never "helpfully" run a [USER] block yourself.
2. **Placeholder resolution**: real values live in the git-ignored
   `secrets.local.yaml` at the repo root. Before Phase A, ensure it contains a
   `STORAGE_PREFIX` entry (see A0). When generating command blocks for the
   user, substitute real values; when writing anything tracked by git, keep
   placeholders. Never let a real prefix, token, or push URL into a tracked
   file.
3. **Phase gates**: each phase ends with verification. Do not start the next
   phase until every check in the current one matches its expected output.
   If a check fails, stop and diagnose — do not improvise ahead.
4. **Verify before commit** (standing rule): repo mirroring (Phase E) happens
   only after Phase D passes on the live system.
5. **Never `qm reboot 150`** — cold `qm stop` + `qm start` only (documented
   socket race, storage.md). And per storage.md's standing lesson, do not
   physically handle the USB disk or its cable during any of this.
6. Full file contents live in the appendices; the phases reference them.
   Nothing needs to be derived — if you find yourself inventing a config
   line that is not in this document, stop and re-read.

---

## 1. Why NFS, restated in one paragraph

virtiofsd resolves `--shared-dir` **once**, at VM start, and pins that inode
for the life of the process. Every USB drop therefore costs a **cold restart of
ciri** — all ~20 containers, Immich and Paperless included — to heal a share
that only the media stack uses. An NFS client holds a *network* handle, not an
inode: when the server-side mount comes back, `hard`-mounted clients unblock
and carry on. The repair becomes **host-side only** (remount + re-export,
automated in §6), the VM never restarts, and containers never notice beyond
blocked I/O during the outage window. Filed as "the better structural answer"
since 08-03; this proposal builds it.

What NFS does **not** fix: the drops themselves. The USB link is the root
cause and the cable still wants replacing
([storage.md, 08-10 fixes](../storage.md#fixes-and-which-failure-each-one-answers-2)).
This shrinks a drop's blast radius from "restart the VM, by hand, whenever a
human notices" to "media I/O stalls for ~a minute, then resumes by itself".

## 2. Target architecture

```
geralt                                        ciri (VM 150)
──────                                        ─────────────
USB disk ── /mnt/media (ext4, LABEL=media)
              │
              ├── library/   ◄─ hardlink ─┐   *arr:      /mnt/media      → /data
              └── downloads/complete/  ◄──┘   qBit save:  /mnt/media/downloads → /data/downloads
              exported by nfsd, v4.2 only     qBit temp:  /mnt/torrents/incomplete → /data/incomplete
              bind: <STORAGE_PREFIX>.21               │
                    │                         scsi3 100G zvol (silver, backup=0)
                    │    vmbr1 (NO physical port)     ext4 LABEL=torrents, /mnt/torrents
                    └────────────────────────────┐
                                         net1: <STORAGE_PREFIX>.150
photos ── virtiofs ─────────────────────── /mnt/photos   (UNCHANGED)
```

Three moves, one per requirement:

| Requirement | Design answer |
|---|---|
| Separate IP for NFS | **`vmbr1`, a bridge with no physical port**, private `<STORAGE_PREFIX>.0/24`. NFS binds to `.21` on it and is unreachable from the LAN *by topology* — no firewall rule to get wrong. Storage traffic never touches `nic0` |
| Self-healing, no VM restart | NFS `hard` mounts on ciri + the host-side half of proposal 004 (udev → remount → `exportfs -ra`), §6 |
| Incomplete on NVMe, complete on NFS, hardlinks intact | new 100G scsi3 zvol for in-flight torrents; qBittorrent's own move-on-completion carries the finished file to `downloads/complete` on the NFS share, which is the **same filesystem** as `library/` — the \*arr import stays an instant hardlink (§4) |

### Why a bridge with no port, not an alias on vmbr0

An alias IP (`<LAN_PREFIX>.23` on vmbr0) would work and is less config, but its
isolation is an export allowlist plus an optional firewall rule — two things
that can drift. A port-less bridge cannot leak: there is no physical path from
the LAN to `<STORAGE_PREFIX>.21`. It also keeps NFS chatter off the physical
NIC (the `alx` NIC already logs chronic AER noise), and host↔guest traffic on a
local bridge runs at virtio/memory speed. Decided 2026-08-22.

**Subnet constraint (checked 2026-08-23)**: ciri's docker bridges already
occupy `172.17.0.0/16`–`172.26.0.0/16` and docker grows into `172.16.0.0/12`
on demand — the storage subnet must therefore come from `10.0.0.0/8`. Avoid
`10.2.0.0/24` (gluetun's WireGuard address, an isolated netns but keep it
unambiguous). Suggested value: `10.77.0` — confirm against `ip route` on both
machines in step A0.

## 3. The failure modes, replayed against this design

The three incidents are the test suite. Replaying each:

| Incident | Under virtiofs (what happened) | Under this design |
|---|---|---|
| 07-27 boot race — virtiofsd pinned the empty placeholder dir | ciri served a 68G wrong filesystem for 16 h; silent `downloads/` on pve-root | the **`mountpoint`** export option refuses to export a path that is not a mountpoint — clients get a mount/`ESTALE` failure, never the placeholder. The `create_host_path:false` guards stay as the second layer |
| 08-03 mid-flight drop — host remount could not heal the pinned inode | 14 h 43 m outage, manual remount **+ VM restart** | autoheal remounts and re-exports in ~seconds; `hard`-mounted clients unblock. **No VM restart** |
| 08-10 drop + nothing re-arms the mount | 12-day outage | same as above — the udev half of 004 is deployed here, and the fixed `fsid` (§5) keeps client handles valid across the remount |

## 4. Torrent data path

### Current (all on the USB disk)

qBittorrent already splits temp/save (`Session\TempPath=/data/downloads/incomplete`,
`Session\DefaultSavePath=/data/downloads/complete` — verified in its live
config 2026-08-22) — but both live on `/mnt/media`, so every in-flight torrent
hammers the USB disk with random writes. Exactly the write pattern the 08-03
SMR RCA said to keep off this disk. `/mnt/media/downloads` is currently empty
(4 KB), so there is no data migration at all.

### Proposed

| Stage | Filesystem | Path (host view → container view) |
|---|---|---|
| downloading (in-flight) | **NVMe** — scsi3 zvol, ext4 `LABEL=torrents` | `/mnt/torrents/incomplete` → `/data/incomplete` |
| completed + seeding | **NFS** (USB disk) | `/mnt/media/downloads/complete` → `/data/downloads/complete` |
| imported library | **NFS** (same fs) | `/mnt/media/library` → `/data/library` |

- qBittorrent itself performs the move on completion (temp path → save path).
  Across filesystems that is a copy+delete: one **sequential** write to the USB
  disk — the SMR-friendliest workload there is, and the accepted speed cost.
- **THE HARDLINK CONTRACT survives intact**: the \*arr still mount `/mnt/media`
  at `/data` and see the completed file at `/data/downloads/complete/…`, the
  same path qBittorrent reports. `complete/` and `library/` are one ext4
  filesystem on the server, reached through **one NFS mount** in the guest —
  `link()` over NFS is supported and stays an instant 0-byte hardlink. The
  contract's wording in the servarr compose header changes only from "one ext4
  filesystem (the USB HDD)" to "one NFS mount" (Appendix E); the rule (never
  split downloads/ and library/ into separate volumes inside an \*arr) is
  unchanged.
- **Incomplete is deliberately NOT on the NFS share** — if it were, every
  in-flight block would cross to the USB disk twice (write + move) and the SMR
  stall candidates would be back. It is also deliberately **not on `/data`**
  (scsi1): `/data` is in the nightly PBS job, and torrent scratch would inflate
  every snapshot for nothing. A separate `backup=0` disk is the `ai-models`
  precedent, applied again.
- **Resilience side-effect worth naming**: during a media outage qBittorrent
  keeps *downloading* — in-flight torrents touch only NVMe. Completed moves
  fail/queue until NFS returns, then qBittorrent retries. The scratch disk is
  the buffer that makes an outage invisible to the download pipeline.

### Sizing the scratch disk: 100G

Sized for the stated workload — parallel Sonarr season grabs alongside movies:
a 1080p season pack runs ~20–50G, 4K movies 20–80G, and `incomplete/` holds
only what is actively downloading (plus anything finished-but-unmovable during
an NFS outage). Two season packs + two movies in flight ≈ 80–120G worst case.
100G covers it, leaves ~280G free on silver, and the zvol is thin — unused
space costs nothing. If it ever pinches: `qm resize 150 scsi3 +50G` then
`resize2fs /dev/disk/by-label/torrents` in the guest — online, no restart.
When the scratch fills, qBittorrent errors the affected torrents and resumes
when space frees — annoying, not destructive.

## 5. Server design (geralt) — rationale

(The literal files live in Appendix B; the deploy steps in Phase A.)

- **Storage bridge** `vmbr1`, `bridge-ports none`, `<STORAGE_PREFIX>.21/24`.
  Applied with `ifreload -a` — no reboot, no effect on vmbr0.
- **Dedicated user**: virtiofs passed guest uids straight through, so geralt
  never needed uid 13000 (verified absent 2026-08-22). NFS with `all_squash`
  writes as a *host* identity, so the media owner becomes a real, named,
  locked account — `jaskier`, uid/gid 13000, `nologin`, no home. Same id the
  containers already use (`PUID/PGID 13000`), so existing file ownership on
  the disk is already correct — **no chown of the media tree**.
- **NFS v4.2 only, bound to the storage IP** via `/etc/nfs.conf.d/`:
  single port 2049, no v3, no rpcbind surface. `nfs-kernel-server` is not yet
  installed (verified 2026-08-22; `nfs-common` is).
- **The export** (one line, every option load-bearing):

| Option | Why |
|---|---|
| `<STORAGE_PREFIX>.150` (one host, no subnet) | only ciri may mount, even on the storage net |
| `rw` | the \*arr import (hardlink+rename) and qBittorrent's completed-move both write |
| `sync` | this disk's failure mode is *dropping mid-write*; `async` would widen every drop into more journal damage. The speed cost lands on completed-moves and is accepted |
| `all_squash,anonuid=13000,anongid=13000` | **every** guest identity — root included — becomes `jaskier` on disk. Stronger than `root_squash`: a compromised container gains at most what the media owner has. Jellyfin (runs as root, ro bind) reads as 13000, which owns everything — fine |
| `mountpoint` | refuse to export `/mnt/media` unless something is mounted there — the NFS analogue of the `create_host_path:false` guards, and the direct answer to 07-27's empty-placeholder failure |
| `fsid=101` | pins the export's identity so client file handles remain valid when the *same* filesystem is remounted after a USB drop — the property §6 leans on. (101 = arbitrary, unique, recorded here) |
| `no_subtree_check` | standard for whole-filesystem exports; subtree checking breaks renames — the \*arr's bread and butter |

- **Boot ordering** drop-in on `nfs-server.service`: `After=mnt-media.mount`,
  ordering **only** — an absent USB disk must never block boot; the
  `mountpoint` export option owns correctness.

## 6. Self-healing (the surviving half of proposal 004)

004's udev rule and service unit deploy essentially as designed; the script
loses the entire VM-restart apparatus (`qm` calls, `vm_running`, the
restart-budget machinery — remount+re-export is cheap and safe on every flap,
which is precisely what made rate-limiting a *VM restart* necessary and makes
it unnecessary here). Step 4 becomes `exportfs -ra`:

```
USB re-enumeration
  → udev ACTION=="add", ID_FS_LABEL=="media"        (unchanged from 004)
    → media-autoheal.service (oneshot)              (unchanged from 004)
      → media-autoheal.sh                           (full text: Appendix A)
          1. mounted AND readable?           → exit, nothing to heal
          2. mounted but dead (readdir EIO)? → umount -l
          3. systemctl start mnt-media.mount → fsck runs as its dependency
          4. exportfs -ra                    → re-evaluates the `mountpoint`
                                               export against the fresh mount
          5. ntfy on every repair / refusal / failure
```

`flock`, the readdir liveness probe, `wait_for_device`, and notify-on-success
("a self-healing system that heals silently is hiding a degrading cable") all
survive from 004 unchanged. 004's four verified assumptions (udev exposes
`ID_FS_LABEL=media`/`ID_FS_TYPE=ext4`/`SUBSYSTEM=block`; `CURRENT_TAGS=:systemd:`;
`/etc/ntfy.topic` 0600 present; `flock` present) were checked read-only on
geralt 2026-08-22 and still hold.

Client side needs **no healing logic at all**: `hard` mounts block in-flight
I/O until the server answers, then resume.

Recovery timeline for a repeat of 08-10: drop at T+0 → disk re-enumerates
~T+1 s → udev fires → fsck + mount + re-export complete around T+10–60 s →
blocked reads on ciri unblock. Jellyfin playback stalls and resumes (or needs
one client retry); the \*arr's next poll succeeds; **nothing restarts**.

Known edge, documented rather than engineered around: a client holding an open
file across the remount can see one `ESTALE` on that handle and recovers on
reopen. If a heal ever leaves clients stuck in `ESTALE` (not expected with a
fixed `fsid`, but NFS has corners), the escalation is
`systemctl restart nfs-server` **on geralt** — still no VM restart. In the
runbook, not automated; wait for evidence.

## 7. Client design (ciri) — rationale

(Literal fstab/compose content: Appendices D–E; deploy steps in Phase C.)

- **New NIC via cloud-init, not hand-rolled netplan**: cloud-init already owns
  ciri's netplan (it wrote eth0), so net1 goes in through
  `qm set … --ipconfig1` and regenerates cleanly instead of fighting
  `50-cloud-init.yaml`. No gateway on ipconfig1 — the storage net routes
  nothing.
- **The media mount keeps the mountpoint `/mnt/media`** → zero compose changes
  for Jellyfin, the \*arr, Bazarr, Audiobookshelf; every existing ro flag and
  `create_host_path:false` guard keeps working.
- Mount options:

| Option | Why |
|---|---|
| `hard` (never `soft`) | `soft` turns a server outage into `EIO` at the application — i.e. reintroduces exactly the corruption-shaped failures this design removes. `hard` blocks and resumes. Cost: processes in `D` state during an outage (a `docker stop jellyfin` mid-outage hangs until the share returns or a kill) — accepted |
| `timeo=150,retrans=3` | 15 s initial retransmit on TCP; minutes of visible stall before it matters, retries continue underneath regardless |
| `x-systemd.automount` + `_netdev,nofail` | boot resilience: ciri must come up fully (Immich, Paperless, …) even if geralt's NFS isn't ready. First *access* mounts the share; a Docker bind resolving `/mnt/media/library` **is** an access and triggers it. If the server is down, the path is absent and the media stack's guards fail those containers loudly — identical blast radius to today's `nofail` virtiofs. (004 §6 rejected automount — that objection was virtiofs-specific: virtiofsd never re-traverses the automount point. It dies with virtiofs) |
| `vers=4.2` | matches the server's only offered version; server-side copy for free |

  **Executor note — stacked autofs mount**: with `x-systemd.automount`,
  mountinfo holds an `autofs` entry at `/mnt/media` *underneath* the `nfs4`
  mount. `findmnt --first-only --mountpoint /mnt/media` therefore returns
  `autofs`, not `nfs4`. Every check that asserts the fstype must use the
  pattern in Appendix C (trigger, then `findmnt … | tail -1`).
- **Scratch disk**: scsi3 100G, `backup=0` (same reason as scsi2/ai-models:
  disposable data must not inflate nightly PBS snapshots), ext4
  `LABEL=torrents`, mounted `/mnt/torrents` with `nofail`.
- **servarr changes are two lines of config**: one new bind on qBittorrent
  (Appendix E) and one qBittorrent setting (`Session\TempPath` →
  `/data/incomplete`). The \*arr, gluetun, qbit-port-sync, Prowlarr, Bazarr,
  Jellyseerr, FlareSolverr, and the whole Jellyfin stack: untouched.
- **Hookscript**: `/mnt/media` leaves the virtiofs share list (it is no longer
  one); `/steel/photos` stays gated as `required`. Exact edit: Appendix F.

## 8. Monitoring

Detection already works (08-10 proved it); it adapts rather than grows:

| Monitor | Change |
|---|---|
| `media-mount-health.sh` on ciri (Kuma push, existing) | keep — now an **end-to-end NFS probe**. Three edits (exact text: Appendix C): expected fstype `virtiofs`→`nfs4` with the stacked-autofs pattern; `timeout 30` on every command that touches the mount (`df`, `ls`, `dd`) because against a `hard` mount a dead server *blocks* instead of erroring — the `timeout` converts "hung" into a failed check; header note. The readdir + byte-read checks stay the load-bearing ones, unchanged in spirit |
| **NEW** `media-export-health.sh` on geralt (Kuma push, full text: Appendix B4) | the server-side view, so a host-only fault is attributed correctly: mount present → sentinel readdir → byte-read of the existing `.mount-health` file → `nfs-server` active → export listed → nfsd listening on `<STORAGE_PREFIX>.21:2049`. Same push pattern as `gpu-health`; runs from a 60 s systemd timer |
| autoheal ntfy (§6) | every heal/refusal/failure notifies |
| Kuma `resend_interval` (004 §5) | **carried forward unchanged and still the highest-value fix in the lab**: 30–60 min resend on all monitors. Autoheal shrinks outages; resend covers the class where the disk doesn't come back. Independent of everything else — do it with Phase A |
| scratch disk watchline | `/mnt/torrents` ≥ 85 % means either a huge batch or NFS has been down a while (completed-moves queuing). Beszel's agent already graphs guest disks; add a dedicated check only if it ever actually bites |

## 9. Security summary

| Layer | Control |
|---|---|
| Network | port-less bridge — NFS not reachable from LAN by topology; nfsd additionally bound to `<STORAGE_PREFIX>.21`; v4.2-only = single port 2049, no rpcbind portmap surface |
| Export | allowlisted to exactly `<STORAGE_PREFIX>.150`; `mountpoint` guard against serving the placeholder |
| Identity | `all_squash` → dedicated locked system user `jaskier` (13000, nologin) — guest root included; blast radius of any container compromise on this share = the media files, which are disposable by charter |
| Guest | per-container ro binds and `create_host_path:false` guards unchanged; qBittorrent still sees `downloads/` + `incomplete/` only, never `library/` |
| Honest limitation | AUTH_SYS trusts the client's claimed uid — anyone root *on ciri* can use the share regardless. Kerberos would close it and is absurd overkill for a single-admin lab with one client; recorded, accepted |

## 10. Speed, honestly

- **Bottleneck is the USB disk, not NFS.** The link has been stuck at USB 2.0
  (~35 MB/s) since 08-15 anyway; vmbr1 is virtio host↔guest — GB/s-class. NFS
  protocol overhead is noise behind a 35 MB/s disk.
- **Streaming (reads)**: unchanged in practice; a remux tops out ~10 MB/s.
- **Completed-move**: a 10G file NVMe→NFS takes ~5 min at USB 2 speeds,
  ~invisible if the cable fix restores SuperSpeed. Background; seeding
  continues from the NFS copy afterwards.
- **\*arr import**: still a hardlink — still instant.
- **In-flight torrent I/O**: *faster* than today — random writes move from the
  worst disk in the lab to the best one.
- `sync` export: costs on metadata-heavy bursts (the import rename storm);
  accepted for crash-consistency on a disk whose specialty is vanishing
  mid-write.

## 11. Alternatives considered

| Alternative | Why not |
|---|---|
| Proposal 004 as written (auto VM restart) | automates the outage instead of removing it; every drop still cold-cycles Immich/Paperless/memos/sure. Rejected 2026-08-22 in favour of this |
| Alias IP on vmbr0 | isolation-by-allowlist instead of isolation-by-topology; decided against 2026-08-22 (§2) |
| Move library to steel | cleanest fix, but steel is reserved for photo growth — vetoed 2026-08-22 |
| SMB/Samba instead of NFS | userspace server, weaker hardlink/rename semantics for the \*arr, heavier daemon; NFS is the native answer between two Linux boxes |
| `soft` NFS mounts | turns outages into application-level `EIO` — reintroduces the failure class being removed |
| USB passthrough of the disk into ciri | stacks QEMU's USB layer on an already-flaky physical link; host loses all visibility; rejected in the option review |
| Incomplete on `/data` (scsi1) instead of a new zvol | inflates nightly PBS snapshots with torrent scratch; separate `backup=0` disk is the established `ai-models` pattern |

---

# RUNBOOK

Total planned downtime: **one final cold restart of ciri** (Phase C) — the
restart that removes the reason for restarts. All of Phase A and B run with
everything up.

## Phase A — geralt: bridge, user, NFS server, autoheal (zero impact)

### A0. Choose and record the storage prefix

**[VERIFY]** (agent, read-only — collision check):

```bash
ssh lab-geralt "ip route"
ssh lab-ciri  "ip route"
```

Expected: no route overlapping the chosen `10.x.y.0/24` (suggested `10.77.0`;
anything in `172.16/12` is disqualified — docker owns it on ciri). Record the
choice in `secrets.local.yaml` as `STORAGE_PREFIX: 10.77.0` (or the chosen
value). All commands below write `<STORAGE_PREFIX>` — substitute when handing
blocks to the user.

### A1. Storage bridge

**[USER]** on geralt (append to `/etc/network/interfaces`, then reload):

```bash
cat >> /etc/network/interfaces <<'EOF'

auto vmbr1
iface vmbr1 inet static
	address <STORAGE_PREFIX>.21/24
	bridge-ports none
	bridge-stp off
	bridge-fd 0
# Storage-only bridge: NFS media share to ciri. No physical port on purpose —
# unreachable from the LAN by construction. See docs/proposals/005.
EOF
ifreload -a
```

**[VERIFY]**:

```bash
ssh lab-geralt "ip -br addr show vmbr1"
```

Expected: `vmbr1  UP  <STORAGE_PREFIX>.21/24 …`. Also confirm from a LAN
machine (e.g. this laptop): `ping -c2 -W2 <STORAGE_PREFIX>.21` **fails** —
that failure is the isolation working.

### A2. Dedicated user

**[USER]** on geralt:

```bash
groupadd --gid 13000 jaskier
useradd --uid 13000 --gid 13000 --system --shell /usr/sbin/nologin \
        --home-dir /nonexistent --no-create-home jaskier
```

**[VERIFY]**: `ssh lab-geralt "getent passwd 13000; getent group 13000"` →
`jaskier:x:13000:13000:…:/nonexistent:/usr/sbin/nologin` and `jaskier:x:13000:`.

### A3. NFS server

**[USER]** on geralt — install, then configure, then restart (the package
starts with defaults; the restart applies ours):

```bash
apt-get update && apt-get install -y nfs-kernel-server

# v4.2-only, storage-IP-only — Appendix B1
cat > /etc/nfs.conf.d/kaermorhen.conf <<'EOF'
[nfsd]
host=<STORAGE_PREFIX>.21
vers3=n
vers4=y
vers4.0=n
vers4.1=n
vers4.2=y
EOF

# the export — Appendix B2 (ONE line)
cat > /etc/exports <<'EOF'
/mnt/media <STORAGE_PREFIX>.150(rw,sync,no_subtree_check,all_squash,anonuid=13000,anongid=13000,mountpoint,fsid=101)
EOF

# ordering only — absent disk must never block boot (§5)
mkdir -p /etc/systemd/system/nfs-server.service.d
cat > /etc/systemd/system/nfs-server.service.d/media.conf <<'EOF'
[Unit]
After=mnt-media.mount
EOF

systemctl daemon-reload
systemctl restart nfs-server
exportfs -ra
```

**[VERIFY]**:

```bash
ssh lab-geralt "systemctl is-active nfs-server; exportfs -v; ss -tln | grep 2049; cat /proc/fs/nfsd/versions"
```

Expected: `active`; the export listed with
`(rw,…,all_squash,anonuid=13000,anongid=13000,fsid=101,mountpoint,…)`;
**2049 listening on `<STORAGE_PREFIX>.21` only** (not `0.0.0.0`, not the LAN
IP); versions line showing `-3 +4 -4.0 -4.1 +4.2` (v3 and 4.0/4.1 off).
From a LAN machine: `nc -zw2 <STORAGE_PREFIX>.21 2049` times out — good.

Negative test (the allowlist): **[USER]** on geralt
`mkdir -p /mnt/nfstest && mount -t nfs4 -o vers=4.2 <STORAGE_PREFIX>.21:/mnt/media /mnt/nfstest`
→ **must fail** (geralt is `.21`, not `.150`; only ciri may mount). Then
`rmdir /mnt/nfstest`. That failure is the security test passing.

### A4. Autoheal (Appendix A + B3)

**[USER]** on geralt, with the three files from the appendices staged (repo →
host via `scp` or paste):

```bash
install -m 0755 media-autoheal.sh       /usr/local/sbin/
install -m 0644 media-autoheal.service  /etc/systemd/system/
install -m 0644 99-media-autoheal.rules /etc/udev/rules.d/
systemctl daemon-reload && udevadm control --reload
```

**[VERIFY]**:

```bash
ssh lab-geralt "bash -n /usr/local/sbin/media-autoheal.sh && echo SYNTAX-OK; \
  systemd-analyze verify /etc/systemd/system/media-autoheal.service && echo UNIT-OK; \
  ls -l /etc/udev/rules.d/99-media-autoheal.rules"
```

Then a **healthy-system dry run** — **[USER]**:
`systemctl start media-autoheal.service` →
**[VERIFY]** `ssh lab-geralt "journalctl -u media-autoheal.service -n5 --no-pager"`
expected: `…/mnt/media is mounted and readable — nothing to heal`, exit 0,
**no ntfy sent**.

(The live unbind/rebind heal test waits for Phase D, when clients exist.)

### A5. Server-side health monitor (Appendix B4 + B5)

1. **[USER]** In Kuma (LXC 104, UI): New Monitor → type **Push**, name
   `media-export geralt`, heartbeat interval **60 s**, retries 2; attach the
   ntfy notification. Copy the push URL.
2. **[USER]** on geralt:

```bash
install -m 0755 media-export-health.sh /usr/local/bin/
printf '%s\n' '<KUMA_PUSH_URL>' > /etc/kuma-push.media-export
chmod 600 /etc/kuma-push.media-export
install -m 0644 media-export-health.service media-export-health.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now media-export-health.timer
```

**[VERIFY]**:

```bash
ssh lab-geralt "systemctl list-timers media-export-health.timer --no-pager; journalctl -u media-export-health.service -n3 --no-pager"
```

Expected: timer active, last run logged `ok: …`, and the Kuma monitor green.

### A6. Kuma resend_interval (004 §5, independent)

**[USER]** In the Kuma UI, set **"Resend Notification if Down X times
consecutively"** on every monitor to the equivalent of 30–60 min (e.g. 30 with
60 s heartbeats). Bulk-editable via the settings of each monitor; ~30 monitors.
No verification beyond spot-checking two monitors' saved settings.

## Phase B — VM config, applied but inert until next start

**[USER]** on geralt:

```bash
qm set 150 --net1 virtio,bridge=vmbr1
qm set 150 --ipconfig1 ip=<STORAGE_PREFIX>.150/24
qm set 150 --scsi3 silver-guests:100,backup=0,discard=on,iothread=1,ssd=1
```

(No gateway on ipconfig1 — deliberate, §7. The disk is allocated immediately;
NIC and cloud-init network land at next start.)

**[VERIFY]**:

```bash
ssh lab-geralt "qm config 150 | grep -E 'net1|ipconfig1|scsi3'"
```

Expected: the three lines exactly as set, `scsi3: silver-guests:vm-150-disk-<N>,backup=0,…,size=100G`.

## Phase C — the last restart (cutover)

### C0. Pre-stage inside ciri (VM still running on virtiofs — all harmless now, active at next boot)

**[USER]** on ciri:

```bash
sudo apt-get update && sudo apt-get install -y nfs-common

sudo sed -i 's|^media /mnt/media virtiofs defaults,nofail 0 0$|<STORAGE_PREFIX>.21:/mnt/media  /mnt/media  nfs4  vers=4.2,hard,noatime,timeo=150,retrans=3,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30  0 0|' /etc/fstab

echo 'LABEL=torrents /mnt/torrents ext4 defaults,noatime,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/torrents
```

(The full target fstab is Appendix D — diff against it. The nfs4 line does
nothing while the virtiofs mount is still active this boot; `LABEL=torrents`
doesn't exist yet, `nofail` skips it. The **photos virtiofs line must remain
untouched**.)

**[VERIFY]**:

```bash
ssh lab-ciri "cat /etc/fstab; dpkg -l nfs-common | tail -1"
```

Expected: fstab matches Appendix D except `/mnt/torrents` not yet formatted;
photos line unchanged; nfs-common `ii`.

### C1. Stop the media stacks

**[USER]** on ciri:

```bash
cd /data/stacks/servarr && docker compose down
cd /data/stacks/jellyfin && docker compose down
cd /data/stacks/audiobookshelf && docker compose down
```

(Immich, Paperless, memos, sure, AI, obsidian-sync etc. keep running until the
VM stop; they need no changes and come back on their own at start.)

### C2. The restart

**[USER]** on geralt:

```bash
qm stop 150
qm set 150 --delete virtiofs1        # media leaves virtiofs; photos (virtiofs0) STAYS
qm start 150
```

Cold stop/start, never `qm reboot` (socket race, storage.md). The hookscript
will print its advisory-media line for the last time or pass photos only —
either is fine this once; it is edited in C5.

**[VERIFY]** (wait ~60 s for boot):

```bash
ssh lab-geralt "qm status 150; qm config 150 | grep -c virtiofs"
ssh lab-ciri  "ip -br addr show; findmnt /mnt/media; findmnt /mnt/photos; ls /mnt/media/library | head -3"
```

Expected: `status: running`; virtiofs count **1** (photos only). On ciri:
eth0 as before **plus** a NIC with `<STORAGE_PREFIX>.150/24`; `/mnt/photos`
still `virtiofs`; the `ls` **triggers the automount** and enumerates the
library; `findmnt /mnt/media` then shows the stacked `autofs` + `nfs4` entries
with `<STORAGE_PREFIX>.21:/mnt/media` as source. If the `ls` hangs >30 s,
check A3's verifications again before anything else.

### C3. Format and mount the scratch disk

**[VERIFY]** first — identify the new 100G disk (expected `/dev/sdd`, but
never assume): `ssh lab-ciri "lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT"` — exactly
one 100G disk with no filesystem.

**[USER]** on ciri (substitute the verified device):

```bash
sudo mkfs.ext4 -L torrents /dev/sdd
sudo systemctl daemon-reload
sudo mount /mnt/torrents
sudo install -d -o 13000 -g 13000 /mnt/torrents/incomplete
```

Also ensure the completed-downloads tree exists on the share — run from ciri
**through NFS**, which doubles as the first `all_squash` write test:

```bash
sudo mkdir -p /mnt/media/downloads/complete
```

**[VERIFY]**:

```bash
ssh lab-ciri  "findmnt /mnt/torrents; ls -ld /mnt/torrents/incomplete /mnt/media/downloads/complete"
ssh lab-geralt "ls -ldn /mnt/media/downloads /mnt/media/downloads/complete"
```

Expected: `/mnt/torrents` mounted ext4; on **geralt** the dirs created from
ciri's root shell are owned **13000:13000** — that is `all_squash` verified
before a single container starts.

### C4. servarr compose + qBittorrent setting, stacks up

**[USER]** on ciri: apply the qBittorrent volumes change from Appendix E to
`/data/stacks/servarr/compose.yaml` (one added bind + header comment edits),
then:

```bash
cd /data/stacks/servarr && docker compose up -d
cd /data/stacks/jellyfin && docker compose up -d
cd /data/stacks/audiobookshelf && docker compose up -d
```

Then in the qBittorrent WebUI (`:8080` via gluetun): Options → Downloads →
**"Keep incomplete torrents in:"** → `/data/incomplete` → Save. (This writes
`Session\TempPath=/data/incomplete`; the save path stays
`/data/downloads/complete`. Alternative if the UI misbehaves: stop the
container, edit `Session\TempPath` in
`/data/stacks/servarr/qbittorrent/qBittorrent/qBittorrent.conf`, start it.)

**[VERIFY]**:

```bash
ssh lab-ciri "docker ps --format '{{.Names}}\t{{.Status}}' | sort; \
  grep -E 'Session\\\\(TempPath|DefaultSavePath)' /data/stacks/servarr/qbittorrent/qBittorrent/qBittorrent.conf"
```

Expected: all media containers `Up` (none restarting); `TempPath=/data/incomplete`,
`DefaultSavePath=/data/downloads/complete`.

### C5. Hookscript + ciri health-script edits

**[USER]** on geralt: apply Appendix F to
`/var/lib/vz/snippets/vm150-require-virtiofs.sh` (media entry out, photos
stays `required`).
**[USER]** on ciri: apply Appendix C to `/usr/local/bin/media-mount-health.sh`.

**[VERIFY]**:

```bash
ssh lab-geralt "bash -n /var/lib/vz/snippets/vm150-require-virtiofs.sh && grep -c '/mnt/media' /var/lib/vz/snippets/vm150-require-virtiofs.sh"
ssh lab-ciri  "sudo systemctl start media-mount-health.service; journalctl -u media-mount-health.service -n3 --no-pager"
```

Expected: hookscript syntax-clean, `/mnt/media` only in comments (grep count
matches Appendix F); health run logs `ok: /mnt/media …GiB nfs4, library
readable, bytes read (…)` and Kuma monitor 23 stays green.

## Phase D — verification (the contract tests)

Run in order. Every one must pass before Phase E.

| # | Test | Commands | Expected |
|---|---|---|---|
| D1 | **Hardlink contract** | **[USER]** on ciri: `docker exec -u 13000 sonarr sh -c 'echo probe > /data/downloads/complete/.hl-probe && ln /data/downloads/complete/.hl-probe /data/library/.hl-probe && stat -c %h /data/library/.hl-probe && rm /data/downloads/complete/.hl-probe /data/library/.hl-probe'` | prints `2` — hardlink across downloads→library over NFS works, 0 extra bytes |
| D2 | **all_squash** | already proven in C3; re-check any new file on geralt with `ls -ln` | owner `13000:13000` regardless of creating uid |
| D3 | **Real torrent end-to-end** | **[USER]** grab something small via Sonarr/Radarr; **[VERIFY]** `ssh lab-ciri "ls /mnt/torrents/incomplete"` during, `ls /mnt/media/downloads/complete` + `stat -c %h` on the imported library file after | in-flight file on NVMe scratch; completed file moved to NFS; import is a hardlink (links=2 while seeding) |
| D4 | **The heal, live** | **[USER]** on geralt, while Jellyfin is mid-playback. First resolve the USB port id: `DEV=$(basename "$(readlink -f /dev/disk/by-label/media)")` then `udevadm info -q path -n "/dev/${DEV%%[0-9]*}"` — the `N-M` segment right after `usbN/` is the port (was `1-3` per 004; **re-verify, the 08-15 cascade bounced between `2-3` and `1-3`**). Then `echo -n '<PORT>' > /sys/bus/usb/drivers/usb/unbind; sleep 5; echo -n '<PORT>' > /sys/bus/usb/drivers/usb/bind` (unbind/bind, never cable-pulling — same `ACTION=="add"` path without stressing the prime-suspect connector); **[VERIFY]** `ssh lab-geralt "journalctl -u media-autoheal.service -n20 --no-pager"` and `ssh lab-ciri "uptime; ls /mnt/media/library >/dev/null && echo CLIENT-RECOVERED"` | autoheal logs remount + `exportfs -ra` + "healed"; **one** ntfy *media mount healed*; playback stalls ≤~1 min and resumes; **ciri uptime unbroken, zero container restarts** (`docker ps` start times unchanged) |
| D5 | **Heal is idempotent** | **[USER]** `systemctl start media-autoheal.service` on healthy system | "nothing to heal", no ntfy |
| D6 | **LAN isolation** | from this laptop: `nc -zw2 <STORAGE_PREFIX>.21 2049; ping -c2 -W2 <STORAGE_PREFIX>.21` | both fail — no route from the LAN |
| D7 | **Worst-case boot** (optional but recommended once) | **[USER]** on geralt `systemctl stop nfs-server`, then `qm stop 150 && qm start 150`; after checks, `systemctl start nfs-server` | ciri boots fully; Immich/Paperless/etc healthy; media containers **down loudly** via `create_host_path` guards; after nfs-server returns + `docker compose up -d`, media stack healthy. Blast radius identical to today's `nofail` virtiofs |

## Phase E — as-built mirroring (only after D passes)

Per repo convention (`scp` verbatim, placeholders for anything sensitive):

1. `configs/ciri/servarr/compose.yaml` — mirror; rewrite the HARDLINK CONTRACT
   header per Appendix E; note the TempPath change + scratch disk in its README.
2. `scripts/proxmox/`: `media-autoheal.sh`, `media-autoheal.service`,
   `99-media-autoheal.rules` (Appendices A, B3) + README entries; update
   `vm150-require-virtiofs.sh` to the Appendix F text and its README.
3. `scripts/monitoring/`: updated `media-mount-health.sh` (Appendix C), new
   `media-export-health.sh` + units (Appendix B4/B5), README entries.
4. `docs/network.md`: claim `<STORAGE_PREFIX>.0/24` + vmbr1 in the registry;
   note ciri's net1. `docs/docker-vm.md`: scsi3 + net1. `docs/storage.md`:
   postscript on the 08-10 incident pointing here; scsi3 row in the ciri zvol
   table (`backup=0`). `docs/uptime-kuma.md`: the new push monitor + the
   resend_interval change.
5. Mark proposal 004 `Superseded by 005` in its header; flip this proposal's
   status to deployed-as-built with the date.
6. `secrets.local.yaml`: `STORAGE_PREFIX`, the new Kuma push URL.
7. Commit (user's call, per working pattern).

**Rollback** (any point after C2, if something is unfixably wrong):
`qm stop 150` → `qm set 150 --virtiofs1 dirid=media` → restore the virtiofs
fstab line on ciri (swap the nfs4 line back) → `qm start 150` → revert the
compose/TempPath edits. The export, bridge, scratch disk and autoheal can all
sit idle harmlessly meanwhile. Nothing in Phases A–B is destructive.

---

## As-built deviations (2026-08-23)

Found while executing the runbook. Each is a place the document above is
**wrong or incomplete** against the deployed system.

| # | Where | What the document says | What is actually true |
|---|---|---|---|
| 1 | §9, B1 | "v4.2-only = no rpcbind/mountd portmap surface" | Untrue as built. `rpcbind` listens on `:111` (pre-existing, installed with `nfs-common` in July) and `rpc.mountd` on four random high ports, all `0.0.0.0`. `rpc.mountd` **cannot** be bound to an interface — no bind flag exists (`-H` is `ha-callout`) and `nfs.conf(5)` documents `host=` only under `[nfsd]`; `nfs-mountd.service` also ignores `/etc/default/nfs-kernel-server`. Mitigated by masking `rpc-statd` (v3 NLM only; nothing requires it — `RequiredBy=`/`BoundBy=` both empty). |
| 2 | A1 verify | expects `vmbr1  UP  …` | A port-less bridge reports `state UNKNOWN` until a guest tap joins it. Check the link **flags** (`UP,LOWER_UP`), not operstate. |
| 3 | — (omitted) | nothing about geralt's `/etc/fstab` | `x-systemd.before=pve-guests.service,x-systemd.device-timeout=30` existed **only** because virtiofsd resolved `--shared-dir` at VM start. Now vestigial, and it delays guest start on a flaky USB disk for no benefit. Removed in C5; the hookscript header referencing it was updated too. |
| 4 | A5, B4 | `<KUMA_PUSH_URL>` placeholder | Must be the **bare** base URL over **IP**: `http://<LAN_PREFIX>.104:3001/api/push/<token>`. geralt cannot resolve `kaermorhen.internal` or the public domain (router DNS by design), and a trailing `?status=up&…` from Kuma's UI would leave two `status` params — Kuma reads the first and the monitor reports `up` forever. |
| 5 | B5 | `OnUnitActiveSec=60`, default `AccuracySec` | Cannot meet a 60 s Kuma window. Measured 61/72/75/90 s intervals — every beat late. Replaced with `OnCalendar=*:*:0/30` + `AccuracySec=1s` (measured 30.0 s, no drift). Push at ~half the Kuma interval. |
| 6 | — | `docs/uptime-kuma.md` claims push URLs live in `secrets.local.yaml` | They did not; none were recorded. `KUMA_PUSH_MEDIA_EXPORT` added. The `KUMA_ADMIN_USER` comment also still says LXC 103; Kuma is **104**. |
| 7 | §7 | recommends cloud-init for net1, no caveat | `qm set --ipconfig1` changes the cloud-init **instance-id**, so cloud-init re-runs per-instance modules on next boot and **regenerates the guest's SSH host keys**. Expect `REMOTE HOST IDENTIFICATION HAS CHANGED` on every admin machine. Verify via `qm guest exec 150 -- ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` before clearing `known_hosts` — never clear it blind. |
| 8 | C1, C4 | stops/starts an `audiobookshelf` stack | Not deployed on ciri — no stack directory, no container. Only `jellyfin` and `servarr` bind `/mnt/media`. |
| 9 | C2 verify | `qm config 150 \| grep -c virtiofs` → expect 1 | Returns **2** even when correct: the hookscript filename `vm150-require-virtiofs.sh` contains the word. Anchor it: `grep -c '^virtiofs'`. |
| 10 | Appendix C-2 | `timeout 30` on "every command that touches the mount", listing checks 3-5 | Misses **check 2's `[[ -d ]]`**, a bare `stat()` that blocks forever on a `hard` mount with a dead server — systemd then SIGKILLs the unit having pushed nothing, degrading a precise `status=down` into mere heartbeat silence. Fixed. |
| 11 | **Appendix A** | "readdir is the only probe that reaches the backing store" | **False, and it silently defeated the entire heal.** See below. |
| 12 | §3, §5 | credits the `mountpoint` export option with answering 07-27 | It does — but it only asserts that *something* is mounted. It went on exporting a filesystem in `shutdown` state throughout the 2026-08-23 test, so it does **not** cover mounted-but-dead (the 08-03 class). |

### #11 in detail — the healer must not be weaker than its monitors

On the first live heal test the disk re-enumerated `sdb`→`sdc`, udev fired, and
`media-autoheal.sh` ran — and concluded *"mounted and readable — nothing to
heal"*, leaving `/mnt/media` as the dead `sdb1` (mount option `shutdown`) and
nfsd serving a corpse. Jellyfin playback failed; both Kuma monitors went red.

On that same dead mount:

```
ls -1 /mnt/media/library                     -> audiobooks movies tv   exit 0
dd iflag=direct .../library/.mount-health    -> Input/output error     exit 1
```

`library/` has three entries and had been read seconds earlier, so the readdir
was served **entirely from the dentry cache** and never touched the disk. Both
health scripts caught the fault correctly, because both use `O_DIRECT` — the
healer was the only component using a weaker probe than the thing watching it.

`is_readable()` is now readdir **and** an `O_DIRECT` byte read, both under
`timeout`. **Proposal 004 carries the identical flaw** in the same function; had
004 been deployed instead, its VM restart would never have fired either.

After the fix, re-running the same unbind/bind: repair completed in **13 s**,
ciri's uptime unbroken, **zero container restarts**, one ntfy delivered.

### D3 result (2026-08-23) — the hardlink contract at scale

The real-torrent test ran itself: one movie resumed by hand, plus five episodes
Sonarr grabbed on its own, **six parallel completions and imports across two
\*arr instances**, ~10 GB written to the share in about 11 minutes.

Every stage behaved:

| Stage | Evidence |
|---|---|
| in-flight → NVMe | a resumed torrent downloading in `/mnt/torrents/incomplete` while the imports ran |
| completed → NFS | six files landed in `downloads/complete` on the share |
| the move | qBittorrent's own move-on-completion — one **sequential** write per file to the SMR disk, which was the entire point of the scratch disk |
| \*arr import | **6/6 at `links=2` with identical inodes** — genuine hardlinks over NFS, 0 extra bytes |
| rename + subs | Radarr foldered and renamed correctly; Bazarr fetched an SDH track (a real new file, `links=1`) |

The aggregate is the strongest statement of the contract available:

```
library/ + downloads/complete/
  apparent size (double-counts hardlinks):  521.4 GiB
  actual blocks consumed (each inode once):   265 G
```

**~256 GiB of the share is hardlinks costing nothing**, over NFS. Had `link()`
degraded to a copy — the risk §4 flagged — that would have been ~256 GiB of
duplicated writes onto the worst disk in the lab.

No errors, no monitor blips, and the media disk saw only sequential writes
throughout.

### Also worth recording

- **The USB link is back at SuperSpeed** — `/sys/bus/usb/devices/2-3/speed` =
  `5000`, `version 3.00`. `storage.md` records it stuck at 480 since 08-15.
- **The USB port id moved**: 004 recorded `1-3`; it is now `2-3`. Re-resolve it
  before any unbind test rather than trusting a recorded value.
- **`/data/incomplete` was unnecessary.** The scratch disk is nested over
  `/data/downloads/incomplete` instead, so the container keeps the original
  `complete/` + `incomplete/` pair side by side and only the backing store
  changed (USB → NVMe). Docker orders binds by target depth, so the NFS parent
  mounts first and the NVMe scratch lands on top.
- `/mnt/media/downloads/complete` was **not** empty as §4 claims — it holds live
  seeding data, and 7.3 G of stale partials remain in the NFS
  `downloads/incomplete/` underneath the scratch mount. Confirmed orphaned by
  D3: a resumed torrent restarted from zero on the scratch disk rather than
  picking up its old partial, because the path it now writes to is a different
  filesystem. Safe to delete from geralt, where the path is not shadowed.

## Follow-ups

- **Still replace the USB cable** — the link is at USB 2.0 since 08-15 and the
  root cause outranks every mitigation in this file.
- If a heal ever strands clients in `ESTALE`: add
  `systemctl restart nfs-server` to the autoheal script *then*, with evidence.
- Revisit scratch sizing only if `/mnt/torrents` alerts.

---

# Appendix A — `media-autoheal.sh` (complete, → geralt `/usr/local/sbin/`, 0755)

Derived from proposal 004's script: VM-restart apparatus removed
(`VMID`, `vm_running`, `restart_budget_ok`, `STATE_DIR`, the `qm` block and
their ntfy texts), step 4 is now `exportfs -ra`. Everything else — flock,
readdir probe, wait_for_device, ntfy discipline — unchanged from 004.

```bash
#!/usr/bin/env bash
# media-autoheal.sh — re-mount the media USB disk after a bus re-enumeration
#                     and refresh its NFS export.
#
# See docs/proposals/005-nfs-media-share.md (supersedes the VM-restart half of
# proposal 004: ciri consumes this disk over NFS now, and NFS clients recover
# on their own once the export is back — no VM restart, ever).
#
# What it does (idempotent — safe to run at any time, by hand or from udev)
#   1. Exit immediately if /mnt/media is mounted AND readable
#   2. Lazily unmount a mounted-but-DEAD /mnt/media (readdir returns EIO)
#   3. systemctl start mnt-media.mount  — systemd-fsck runs as its passno-2
#      dependency, so boot and repair share one code path
#   4. exportfs -ra — re-evaluates the `mountpoint`-guarded export against the
#      fresh mount so nfsd serves the real filesystem again
#   5. Notify ntfy on every repair, give-up and refusal
#
# Deliberately NOT done
#   - Never mounts anything at a path other than $MEDIA_DIR.
#   - Never fscks by hand — the mount unit's dependency owns that.
#   - No rate limiting: remount+re-export is cheap and safe on every flap.
#     (004 rate-limited VM restarts; there are none here.)
#
# Requires: findmnt + flock (util-linux), exportfs (nfs-kernel-server), curl,
#           /etc/ntfy.topic (mode 600).
# Env overrides: MEDIA_DIR, SENTINEL

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly MOUNT_UNIT="mnt-media.mount"
readonly DEV_LINK="/dev/disk/by-label/media"
# Child that exists only on the real media filesystem — separates "mounted"
# from "mounted but empty" and from an empty stand-in dir on pve-root.
readonly SENTINEL="${SENTINEL:-library}"
readonly LOCK="/run/media-autoheal.lock"
readonly NTFY_TOPIC_FILE="/etc/ntfy.topic"

log() { echo "media-autoheal: $*"; }
err() { echo "media-autoheal: $*" >&2; }

# Alerting must never change the repair's outcome: a dead ntfy is a different
# fault from a dead media disk.
notify() {
  local title=$1 prio=$2 body=$3 topic
  [[ -r "$NTFY_TOPIC_FILE" ]] || { err "no $NTFY_TOPIC_FILE — not notifying"; return 0; }
  topic=$(< "$NTFY_TOPIC_FILE"); topic=${topic//[$'\t\r\n ']/}
  [[ -n "$topic" ]] || return 0
  curl -fsS --max-time 10 --retry 2 --retry-delay 3 \
    -H "Title: $title" -H "Priority: $prio" -H "Tags: floppy_disk" \
    -d "$body" "https://ntfy.sh/${topic}" >/dev/null \
    || err "ntfy push failed (message was: $title — $body)"
}

is_mounted()  { findmnt --noheadings --first-only --mountpoint "$MEDIA_DIR" >/dev/null 2>&1; }
# readdir is the only probe that reaches the backing store. stat/df are served
# from cached dentries and pass against a shut-down ext4 — the whole lesson of
# 2026-08-03. Do not "optimise" this into a -d test.
is_readable() { ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1; }

wait_for_device() {
  local waited=0
  while (( waited < 30 )); do
    [[ -e "$DEV_LINK" ]] && return 0
    sleep 1
    (( waited++ ))
  done
  return 1
}

main() {
  # udev can fire this several times in seconds while a bridge re-enumerates.
  # Serialise, and let the losers exit quietly.
  exec 9>"$LOCK"
  flock -n 9 || { log "another run holds $LOCK — nothing to do"; exit 0; }

  if is_mounted && is_readable; then
    log "$MEDIA_DIR is mounted and readable — nothing to heal"
    exit 0
  fi

  if is_mounted; then
    # Mounted but readdir fails: the backing device went away under a live
    # mount. Lazy detach — nfsd/clients may still hold references and a plain
    # umount would return EBUSY.
    log "$MEDIA_DIR is mounted but not readable — detaching the dead mount"
    umount -l "$MEDIA_DIR" || err "lazy umount of $MEDIA_DIR failed — continuing"
  fi

  if ! wait_for_device; then
    err "$DEV_LINK never appeared — the disk is not on the bus"
    notify "media disk absent" "high" \
      "$DEV_LINK did not appear within 30 s. $MEDIA_DIR is DOWN and cannot be healed automatically — check the USB cable on geralt. NFS clients on ciri are blocked until it returns."
    exit 1
  fi

  log "starting $MOUNT_UNIT"
  if ! systemctl start "$MOUNT_UNIT"; then
    err "$MOUNT_UNIT failed to start"
    notify "media remount FAILED" "urgent" \
      "$MOUNT_UNIT failed to start on geralt. Check 'systemctl status $MOUNT_UNIT' and 'journalctl -u systemd-fsck@*' — fsck may need a manual run. NFS clients on ciri are blocked until this is fixed."
    exit 1
  fi

  if ! is_readable; then
    err "$MEDIA_DIR mounted but $SENTINEL still unreadable"
    notify "media remount incomplete" "urgent" \
      "$MEDIA_DIR mounted on geralt but $SENTINEL is still unreadable. Manual investigation needed."
    exit 1
  fi
  log "$MEDIA_DIR remounted and readable"

  # Host mount is healed; refresh the export table so the `mountpoint`-guarded
  # export is re-evaluated against the fresh mount. Clients (hard mounts)
  # recover on their own from here.
  if ! exportfs -ra; then
    err "exportfs -ra failed"
    notify "media export refresh FAILED" "urgent" \
      "$MEDIA_DIR was remounted on geralt but 'exportfs -ra' failed — ciri's NFS clients may stay blocked. Check 'exportfs -v' and 'systemctl status nfs-server'."
    exit 1
  fi

  log "export refreshed — media path healed end to end"
  notify "media mount healed" "default" \
    "The media disk dropped off the bus on geralt and was automatically remounted and re-exported; NFS clients on ciri recover on their own. No action needed — but a repeat means the USB cable wants checking."
}

main "$@"
```

# Appendix B — geralt config files (complete)

### B1. `/etc/nfs.conf.d/kaermorhen.conf`

```ini
[nfsd]
# storage bridge only — nothing on the LAN can even complete a TCP handshake
host=<STORAGE_PREFIX>.21
# v4.2 only: single port 2049, no rpcbind/mountd portmap surface, and v4.2
# brings server-side copy. v3 has no business here.
vers3=n
vers4=y
vers4.0=n
vers4.1=n
vers4.2=y
```

### B2. `/etc/exports` (one line; option rationale in §5)

```
/mnt/media <STORAGE_PREFIX>.150(rw,sync,no_subtree_check,all_squash,anonuid=13000,anongid=13000,mountpoint,fsid=101)
```

### B3. `media-autoheal.service` (→ `/etc/systemd/system/`, 0644) and `99-media-autoheal.rules` (→ `/etc/udev/rules.d/`, 0644)

```ini
[Unit]
Description=Re-mount the media disk and refresh its NFS export after a USB re-enumeration
# udev fires this repeatedly while a bridge re-enumerates. The script also takes
# a flock, but stopping systemd from queueing runs is cheaper than serialising
# them. Above the burst the script's own ntfy alert has already told someone.
StartLimitIntervalSec=1h
StartLimitBurst=5

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/media-autoheal.sh
# fsck of the 1 TB disk after an aborted journal can take a while; the script
# must not be killed mid-repair.
TimeoutStartSec=600
```

```
ACTION=="add", SUBSYSTEM=="block", ENV{ID_FS_LABEL}=="media", ENV{ID_FS_TYPE}=="ext4", TAG+="systemd", ENV{SYSTEMD_WANTS}+="media-autoheal.service"
```

(Both byte-identical to proposal 004 except the service Description.)

### B4. `media-export-health.sh` (complete, → geralt `/usr/local/bin/`, 0755)

```bash
#!/usr/bin/env bash
# media-export-health.sh — Uptime-Kuma push monitor: prove geralt is SERVING
# the real media disk over NFS.
#
# The client-side monitor (media-mount-health.sh on ciri) sees the end-to-end
# truth but cannot say WHERE a fault is. This is the server-side half, so a
# host-only fault (disk dropped, nfsd dead, export vanished) is attributed
# correctly and caught even if ciri is down.
#
# What it checks (in order; first failure wins)
#   1. /mnt/media is a mount point of type ext4       — not the pve-root placeholder
#   2. /mnt/media/library can be ENUMERATED (readdir) — reaches the backing store
#   3. library/.mount-health can be READ (bytes)      — same sentinel file the
#                                                       ciri monitor reads
#   4. nfs-server.service is active
#   5. the export table still lists /mnt/media        — `mountpoint` guard means
#                                                       a dead mount silently
#                                                       drops the export; catch it
#   6. nfsd is listening on <STORAGE_PREFIX>.21:2049
#
# Behaviour: identical contract to media-mount-health.sh — push up/down with a
# reason; exit 1 on failure so `systemctl --failed` shows it host-side too.
#
# Deploy (on geralt) — see docs/proposals/005 Phase A5
#   install -m 0755 media-export-health.sh /usr/local/bin/
#   printf '%s\n' '<KUMA_PUSH_URL>' > /etc/kuma-push.media-export && chmod 600 /etc/kuma-push.media-export
#
# Requires: curl, findmnt (util-linux), exportfs, ss (iproute2).
# Env overrides: MEDIA_DIR, KUMA_URL_FILE, NFS_BIND_IP

set -euo pipefail

readonly MEDIA_DIR="${MEDIA_DIR:-/mnt/media}"
readonly SENTINEL="library"
readonly HEALTH_FILE="$MEDIA_DIR/$SENTINEL/.mount-health"
readonly KUMA_URL_FILE="${KUMA_URL_FILE:-/etc/kuma-push.media-export}"
# Real storage-net IP; not a placeholder file on the host. Set at install time.
readonly NFS_BIND_IP="${NFS_BIND_IP:-$(ip -4 -br addr show vmbr1 2>/dev/null | awk '{print $3}' | cut -d/ -f1)}"

push() {
  local status=$1 msg=$2 url
  [[ -r "$KUMA_URL_FILE" ]] || { echo "media-export-health: cannot read $KUMA_URL_FILE — not pushing" >&2; return 0; }
  url=$(< "$KUMA_URL_FILE"); url=${url//[$'\t\r\n ']/}
  [[ -n "$url" ]] || { echo "media-export-health: $KUMA_URL_FILE is empty" >&2; return 0; }
  if ! curl -fsS --max-time 10 --retry 2 --retry-delay 3 --retry-connrefused --get \
        --data-urlencode "status=$status" --data-urlencode "msg=$msg" \
        "$url" >/dev/null; then
    echo "media-export-health: push to Uptime-Kuma failed (check itself said: $status/$msg)" >&2
  fi
}

check() {
  local fstype
  # 1. exact mountpoint match — --target would fall back to pve-root (the
  #    hookscript's documented trap).
  if ! fstype=$(findmnt --noheadings --first-only --output FSTYPE \
                        --mountpoint "$MEDIA_DIR" 2>/dev/null); then
    echo "$MEDIA_DIR is not a mount point"
    return 1
  fi
  if [[ "$fstype" != "ext4" ]]; then
    echo "$MEDIA_DIR is $fstype, expected ext4"
    return 1
  fi

  # 2. readdir reaches the backing store; stat/df do not (lesson of 08-03).
  if ! timeout 30 ls -1 "$MEDIA_DIR/$SENTINEL" >/dev/null 2>&1; then
    echo "cannot enumerate $MEDIA_DIR/$SENTINEL — mounted but dead"
    return 1
  fi

  # 3. bytes, O_DIRECT — bypass the page cache (ext4 supports it).
  if ! timeout 30 dd if="$HEALTH_FILE" of=/dev/null bs=4096 count=1 iflag=direct 2>/dev/null; then
    echo "cannot read $HEALTH_FILE"
    return 1
  fi

  # 4-6. the serving side.
  if ! systemctl is-active --quiet nfs-server; then
    echo "nfs-server is not active"
    return 1
  fi
  if ! exportfs -s 2>/dev/null | grep -q "^$MEDIA_DIR\b"; then
    echo "$MEDIA_DIR is not in the export table (mountpoint guard tripped?)"
    return 1
  fi
  if [[ -n "$NFS_BIND_IP" ]] && ! ss -tln "sport = :2049" | grep -q "$NFS_BIND_IP:2049"; then
    echo "nfsd is not listening on $NFS_BIND_IP:2049"
    return 1
  fi

  echo "ok: $MEDIA_DIR ext4 mounted, $SENTINEL readable, exported, nfsd on ${NFS_BIND_IP:-?}:2049"
  return 0
}

main() {
  local detail
  if detail=$(check); then
    push "up" "$detail"
    echo "media-export-health: $detail"
  else
    push "down" "$detail"
    echo "media-export-health: FAIL — $detail" >&2
    exit 1
  fi
}

main "$@"
```

### B5. `media-export-health.service` + `.timer` (→ `/etc/systemd/system/`, 0644)

```ini
[Unit]
Description=Push media NFS export health to Uptime-Kuma

[Service]
Type=oneshot
ExecStart=/usr/local/bin/media-export-health.sh
# the script's own `timeout 30`s bound the probes; this bounds everything else
TimeoutStartSec=90
```

```ini
[Unit]
Description=Run media-export-health every 60s

[Timer]
OnBootSec=90
OnUnitActiveSec=60

[Install]
WantedBy=timers.target
```

# Appendix C — exact edits to `media-mount-health.sh` (on ciri)

Three changes; everything else stays byte-identical.

**C-1. Fstype expectation + the stacked-autofs trap.** With
`x-systemd.automount` there are TWO mounts at `/mnt/media` in mountinfo —
`autofs` (systemd's trigger) underneath `nfs4` — and
`findmnt --first-only` returns `autofs`, a guaranteed false alarm. Replace:

```bash
readonly EXPECTED_FSTYPE="virtiofs"
```

with

```bash
readonly EXPECTED_FSTYPE="nfs4"
```

and replace the whole check-1 block (the `findmnt`/`fstype` lines and their
comment, through the first two `return 1`s) with:

```bash
  # 1. Trigger the automount first (x-systemd.automount mounts on access), then
  #    read the TOP mount at this path. mountinfo holds a stacked pair here —
  #    systemd's `autofs` trigger underneath the real `nfs4` mount — and
  #    --first-only returns the autofs entry: a guaranteed false alarm. tail -1
  #    is the top of the stack. `timeout` because against a `hard` NFS mount a
  #    dead server BLOCKS instead of erroring — hung must become "down".
  timeout 30 ls "$MEDIA_DIR" >/dev/null 2>&1 || true
  fstype=$(findmnt --noheadings --output FSTYPE --mountpoint "$MEDIA_DIR" 2>/dev/null | tail -1)
  if [[ -z "$fstype" ]]; then
    echo "$MEDIA_DIR is not a mount point"
    return 1
  fi
  if [[ "$fstype" != "$EXPECTED_FSTYPE" ]]; then
    echo "$MEDIA_DIR is $fstype, expected $EXPECTED_FSTYPE"
    return 1
  fi
```

**C-2. `timeout 30` on every command that touches the mount** (hard mounts
block; without this the script hangs instead of failing and Kuma only reddens
on missed heartbeats — slower and less specific):

- check 3: `size_kb=$(df -Pk "$MEDIA_DIR" | …)` → `size_kb=$(timeout 30 df -Pk "$MEDIA_DIR" | …)`
- check 4: `if ! ls -1 …` → `if ! timeout 30 ls -1 …`
- check 5, both dd calls: `dd_err=$(dd …)` → `dd_err=$(timeout 30 dd …)`
  (a timeout exits 124 with empty output; the existing error paths handle it)

**C-3. Header**: under "What it checks", change check 1's text to
`is a real mount point of type nfs4 (top of the automount stack)`, and append
one line to the history block:
`2026-XX-XX: media moved from virtiofs to NFS (proposal 005); same checks, new fstype.`

MIN_GIB (800), the sentinel, HEALTH_FILE (`.mount-health` already exists on
the disk and is reused by both monitors), push logic, unit/timer: unchanged.

# Appendix D — ciri `/etc/fstab`, complete target state

```
LABEL=cloudimg-rootfs	/	 ext4	discard,commit=30,errors=remount-ro	0 1
LABEL=BOOT	/boot	ext4	defaults	0 2
LABEL=UEFI	/boot/efi	vfat	umask=0077	0 1
LABEL=data /data ext4 defaults,noatime,nofail 0 2
photos /mnt/photos virtiofs defaults,nofail 0 0
<STORAGE_PREFIX>.21:/mnt/media  /mnt/media  nfs4  vers=4.2,hard,noatime,timeo=150,retrans=3,_netdev,nofail,x-systemd.automount,x-systemd.mount-timeout=30  0 0
LABEL=ai-models /mnt/ai-models ext4 defaults,nofail 0 2
LABEL=torrents /mnt/torrents ext4 defaults,noatime,nofail 0 2
/swapfile none swap sw 0 0
```

(Diff vs today: the `media … virtiofs` line replaced by the nfs4 line; the
`LABEL=torrents` line appended. **The photos line must not change.**)

# Appendix E — servarr `compose.yaml`, exact changes

**E-1. qBittorrent volumes** — replace the existing `volumes:` list of the
`qbittorrent` service with (only the last entry is new; existing comments on
the downloads bind stay):

```yaml
    volumes:
      - ./qbittorrent:/config
      # Scoped to downloads ONLY (no library access). Same sub-path the *arr see
      # under /data/downloads, so the hardlink source path matches with no remote
      # path mapping. create_host_path:false is the missing-mount guard (see the
      # 2026-07-27 incident note above) — with NFS+automount, resolving this
      # path is what triggers the mount; if the server is down the path is
      # absent and the container refuses to start. Fail loud.
      - type: bind
        source: /mnt/media/downloads
        target: /data/downloads
        bind:
          create_host_path: false
      # In-flight torrent scratch on local NVMe (scsi3, LABEL=torrents,
      # backup=0) — proposal 005. Random write I/O stays off the USB disk (the
      # 08-03 SMR RCA); qBittorrent's TempPath points here and its own
      # move-on-completion carries finished files to /data/downloads/complete.
      # Same guard: absent scratch disk ⇒ fail loud, never silently write to
      # the VM root disk.
      - type: bind
        source: /mnt/torrents/incomplete
        target: /data/incomplete
        bind:
          create_host_path: false
```

**E-2. THE HARDLINK CONTRACT header** — replace the existing paragraph with:

```yaml
# THE HARDLINK CONTRACT (do not break):
#   The *arr mount /mnt/media at /data (seeing /data/downloads AND /data/library);
#   qBittorrent mounts /mnt/media/downloads at /data/downloads (downloads only)
#   plus /mnt/torrents/incomplete at /data/incomplete (in-flight scratch, local
#   NVMe — proposal 005). Completed torrents land in /data/downloads/complete,
#   where the *arr see them at the SAME path, so an import into
#   /data/library/{movies,tv,audiobooks} — one NFS mount backed by one ext4
#   filesystem on geralt — is an instant hardlink (0 extra bytes) instead of a
#   slow copy. Keep downloads/ and library/ on the one /data mount inside each
#   *arr; never split them into separate volumes there. incomplete/ is the ONLY
#   piece allowed on a different filesystem — qBittorrent itself does that move.
```

No other service in this file changes. The `media_guard` anchor, the \*arr
binds, gluetun, qbit-port-sync: untouched.

# Appendix F — exact edit to `vm150-require-virtiofs.sh`

Replace the `SHARES` array:

```bash
readonly SHARES=(
  "/steel/photos:zfs:library:required"   # virtiofs0 — Immich originals (irreplaceable)
  "/mnt/media:ext4:library:advisory"     # virtiofs1 — USB media disk (disposable)
)
```

with:

```bash
readonly SHARES=(
  "/steel/photos:zfs:library:required"   # virtiofs0 — Immich originals (irreplaceable)
  # /mnt/media left this list with proposal 005 (2026-XX-XX): the media disk is
  # served to ciri over NFS now, not virtiofs, so there is no start-time inode
  # pin to guard. Its availability is autoheal's + the export `mountpoint`
  # guard's problem; the media containers still have their own bind guards.
)
```

And in the header comment, under "Why the two tiers are NOT symmetric", append
to the `/mnt/media` paragraph: `(Historical since proposal 005 — media is NFS
now and no longer passes through this hook at all.)` The two-tier explanation
itself stays: it documents why photos blocks and why that reasoning survives.
