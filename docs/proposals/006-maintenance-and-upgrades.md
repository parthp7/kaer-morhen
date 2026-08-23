# Proposal 006 — routine maintenance and deliberate upgrades (whole lab)

- **Status**: **Tooling built and verified 2026-08-23; first maintenance pass not
  yet run.** The three scripts in
  [`scripts/maintenance/`](../../scripts/maintenance/) are deployed to the repo,
  pass `shellcheck`, and have been exercised against the live lab in both their
  passing and failing directions (§5). The runbook in this document has **not**
  yet been executed end to end — Phases A–E below are the plan, not a record.
  Four Phase-0 prerequisites are named in §4; one of them (Kuma's
  `resend_interval`) outranks everything else here and is not this proposal's
  invention. Outstanding: the first yennefer pass (D6), the first geralt pass
  (D7), and the docker tiers (§3.3).
- **Date**: 2026-08-23
- **Scope**: both PVE nodes, all 8 LXCs, VM 150 (`ciri`) and its ~30 container
  images. Does **not** cover major database upgrades (§3.3, tier 3), the PVE 9→10
  jump, or anything about *what* to install — only how upgrading is decided,
  performed, and proven not to have broken anything.
- **Decisions taken up front**: nothing auto-updates — this proposal implements
  the existing house policy rather than replacing it (2026-08-23); node reboots
  require physical presence (2026-08-23, forced by hardware, §2); upgrades are
  tiered by risk rather than applied wholesale (2026-08-23). Rationale in §2,
  cost in §7.
- **Closes**: the unrecorded "check the enterprise repos on the PVE nodes too"
  item from [backups.md](../backups.md) — verified disabled on both nodes
  2026-08-23 (§4, Phase 0).

Addresses use the `<LAN_PREFIX>` placeholder per `CLAUDE.md`; the public domain
`kaermorhen.fyi` is written out in full per the same file's exception.

---

## 0. Execution contract (read first if you are the agent running this)

1. **The user runs every modifying command.** Blocks below are labelled
   **[USER]** or **[VERIFY]**. Never run a [USER] block. In particular `apt
   update` is a [USER] command — it rewrites the package lists, and `CLAUDE.md`
   forbids state-changing commands over ssh.
2. **Phase gates**: each phase ends with verification. Do not start the next
   phase until every check in the current one matches its expected output.
3. **One node per window, never both** (§2). If the phase order is broken, stop.
4. **Verify before commit**: nothing is committed until it has been deployed and
   observed working on the live system.

---

## 1. The problem

There is no update procedure. Patching, kernel upgrades and image bumps have
happened ad hoc, and the only written guidance is a scattering of one-liners in
per-stack READMEs — *"bump deliberately, read release notes"* — which say what
to think about but not when, in what order, or how to know afterwards that
nothing broke.

The cost of that gap is already measurable. Running
[`lab-inventory.sh`](../../scripts/maintenance/lab-inventory.sh) for the first
time on 2026-08-23 found, in about ninety seconds:

| Finding | Detail |
|---|---|
| The nodes have silently diverged | geralt on `pve-manager` **9.2.4**, yennefer on **9.2.11** — the docs claimed both were 9.2.4 |
| geralt is far behind | **98** pending packages, including `stable-security`; yennefer had 2 |
| Most guests are unmeasured, not current | **six of eight LXCs** reported "0 pending" purely because their apt cache dated from July |
| The proxy advertises a service that does not exist | `books.kaermorhen.fyi` → **502**; the audiobookshelf stack was mirrored into the repo but never deployed |
| Two pinned tags are not pins | `sure:stable` and `valkey:9` both float |

None of these were known. All of them are the kind of thing that is invisible
until the day it matters.

### What the existing mitigations do and do not cover

| Existing | Covers | Does not cover |
|---|---|---|
| Per-stack README upgrade lines | *That* a stack needs care, and where its release notes are | When to look, what order, what to verify after |
| PBS nightly `--all 1` + proven restore | Rollback for any **guest** | The PVE **hosts** — nothing backs up bare metal |
| Uptime-Kuma (~31 monitors) | A service stopped answering | Anything functional; and it notifies **once** (§4, Phase 0) |
| Beszel thresholds | CPU/RAM/disk/temperature drift | Versions, patch level, image drift |
| The four functional Push monitors | GPU encode, NFS both ends, VPN egress — genuinely deep | Only fire on their own timers; not tied to an upgrade |

The functional monitors are the good news: the hard part — probes that survive
a lying `df` — is already solved and paid for. What is missing is orchestration.

---

## 2. Decisions and why

### The controlling constraint: neither node can be woken remotely

WoL was tested and **fails on both** — geralt's Killer E2400 `alx` driver has no
WoL support in mainline, and yennefer's consumer HP firmware has no S5 wake path
([hardware-inventory.md](../hardware-inventory.md)). Neither has a BMC. A reboot
that does not come back is a trip to the laptop.

Everything else follows from that:

| Decision | Why |
|---|---|
| **One node per window, never both** | Rebooting yennefer takes down PBS, Caddy (every `*.kaermorhen.fyi`), Tailscale primary, pihole-2 and the Beszel hub. Rebooting geralt takes down Kuma, pihole-1, tailscale-2 and *everything* on ciri. Each node's outage is survivable only because the other is up; overlapping them removes the redundancy that was the entire point of the mirror-pair design |
| **yennefer first, geralt second** | yennefer's guests are small infra LXCs, so the procedure is proven on the low-stakes node while geralt — and therefore Kuma and every service — is alive to observe it. geralt carries the GPU landmine and goes second with the day's procedure already validated |
| **Guests before the host** | A host reboot then brings back already-current guests, and guest breakage is attributable *before* the kernel changes underneath it |
| **Weekly excludes host reboots** | That is what makes the weekly pass a remote, 30-minute job that will actually get done. Kernel patches queue for the monthly physical window — the honest consequence of having no remote power-on |
| **Tiered docker upgrades, not big-bang** | A failure in a batch of thirty is unattributable and its rollback is all-or-nothing. Per-stack, rollback is re-pinning one tag |
| **Nothing auto-updates** | Pre-existing house policy, stated in the Beszel, Kuma, Tailscale and Caddy docs. This proposal implements it, it does not revisit it |

### Why a report, not a cron job

The obvious design is a timer that emails "you have 98 updates". It was
rejected: the lab already has one channel (ntfy) carrying alerts that mean
*something is broken now*, and diluting it with routine advisory noise is how
that channel stops being read — the same reasoning that keeps `Exited (0)` a
WARN and not a FAIL in the smoke test. `lab-inventory.sh` is run **when you sit
down to do the work**, which is also the only moment its answer is actionable.

### What this deliberately does not do

- **It does not apply anything.** All three scripts are read-only (the deep
  check's default dry mode included). Applying is a [USER] action, always.
- **It does not cover database major upgrades** (§3.3, tier 3). Those need
  dump+restore and their own proposal.
- **It does not add a monitor.** Post-upgrade verification is a thing you run,
  not a thing that watches — Kuma already watches, and §4 Phase 0 fixes the
  reason it currently cannot be trusted to keep telling you.

---

## 3. Architecture

### 3.1 The three scripts

Full documentation: [`scripts/maintenance/README.md`](../../scripts/maintenance/README.md).

| Script | Answers | Run when |
|---|---|---|
| `lab-inventory.sh` | "What is out of date, and where?" | Before deciding anything |
| `lab-smoke.sh` | "Does everything still answer?" | After every upgrade |
| `lab-deep-check.sh` | "Do the things that *work* still work?" | After touching the relevant stack |

They run from the laptop, not from a host, and are not on timers — deliberately
(§2, "why a report").

### 3.2 Part 1 — node, LXC and VM maintenance

Per-node sequence:

```
verify backups green  →  guests (LXCs, then ciri)  →  host apt  →  reboot host
   →  post-reboot invariants  →  smoke test  →  (only then) next node
```

**Post-reboot invariants — geralt.** These are not generic health checks. Each
one is a documented way this lab has broken, and each is checked automatically
by `lab-inventory.sh`:

| Invariant | Why a kernel upgrade threatens it |
|---|---|
| `vfio_pci disable_idle_d3` = `Y` | Takes effect **only through the initramfs**, and a new kernel builds a new initramfs. Without it the idle GTX 1060 drops to D3cold, resume hits MSI's Optimus `PGON` AML bug, and the host **wedges hard** 68–124 s after boot — no panic, no oops, empty pstore. 6/6 reproduction |
| `usb_storage quirks` = `0bc2:ab24:u` | Same initramfs exposure. It makes `uas` decline the SMR media disk and restored SMART. Delivered via `modprobe.d`, deliberately **not** the kernel cmdline — the GRUB route caused boot hangs 3-in-6 and was reverted. **Do not re-add it to GRUB** |
| VM 150 `onboot: 1` | Counter-intuitive and load-bearing: setting `onboot: 0` before maintenance **arms** the D3cold bug, because nothing claims the GPU at boot and it idles into D3cold. Resist the instinct to disable autostart "for safety" |
| `GRUB_CMDLINE_LINUX_DEFAULT` empty | `quiet` was removed 2026-07-28 because a boot hang was invisible without console output; a grub package upgrade can restore it |
| `zfs_arc_max` = 2 GiB | `/etc/modprobe.d/zfs.conf`, persisted through initramfs — same class of risk |
| `/mnt/media` is ext4 and exported | Reuses `media-export-health.sh` verbatim |

**Restarting ciri.** Never `qm reboot 150`. Back-to-back stop/start races the
kernel tearing down the IOMMU group and fails with `Could not open
'/dev/vfio/2': Device or resource busy`. Use `qm stop 150` → wait for the group
to release → `qm start 150`. And `qm start 150` succeeding does **not** mean
Jellyfin works — check `docker ps` for `jellyfin` and `ollama`, because the CDI
spec race can leave them dead. GP106M has no FLR, so a wedged GPU means a full
geralt reboot.

**Per-guest exceptions.**

| Guest | Deviation from plain `apt full-upgrade` |
|---|---|
| **202 `proxy` (Caddy)** | `apt upgrade` replaces the custom build and **silently drops the `caddy-dns/cloudflare` plugin**. DNS-01 renewals then fail ~30 days later with "no solvers available" — far enough from the upgrade to be baffling. Re-run `caddy add-package github.com/caddy-dns/cloudflare` and confirm with `caddy list-modules \| grep cloudflare`. Its own checklist line, not a footnote |
| **104 `uptime-kuma`** | Not apt: `systemctl stop` → `git fetch --all && npm run setup` as the `uptime-kuma` user → start |
| **150 `ciri`** | Ubuntu apt, plus Docker from Docker's repo and `nvidia-container-toolkit` from NVIDIA's. A toolkit upgrade regenerates the CDI spec and can re-race dockerd — confirm the `docker.service.d/wait-for-cdi.conf` drop-in survived and `NVIDIA_CTK_CDI_OUTPUT_FILE_PATH` still points at `/etc/cdi/nvidia.yaml` (the shipped default `/var/run/cdi` is tmpfs and wipes every boot) |
| Both nodes | The subscription-nag patch (`/usr/local/bin/pve-remove-nag.sh`) is already wired to an apt hook at `/etc/apt/apt.conf.d/no-nag-script` and re-applies itself — no manual step, recorded here because it was in no document |

### 3.3 Part 2 — docker upgrade tiers

Rollback is always: re-pin the previous tag, `docker compose up -d`. The previous
tag is written into the registry in [maintenance.md](../maintenance.md) *before*
the bump, which is what makes rollback a 30-second operation rather than
archaeology.

| Tier | Services | Handling |
|---|---|---|
| **0 — stateless** | nebula-sync, flaresolverr, searxng, `alpine` sidecar, memos | Bump in bulk, one `pull` + `up -d`, smoke test |
| **1 — stateful, well-behaved** | jellyseerr, bazarr, prowlarr, open-webui, ollama, couchdb (within 3.x) | One stack at a time, release notes, verify that stack's function |
| **2 — one at a time, notes first** | Immich, Paperless, Sonarr, Radarr, qBittorrent, gluetun, Jellyfin, Sure | Own window, own verification, recorded rollback tag |
| **3 — out of scope here** | postgres 16→17/18, redis 7.4→8, valkey, Immich's pg14+VectorChord | Needs dump+restore and its own proposal. Note postgres **18 moved the data mount point** — the reason 16 was chosen |

**Tier-2 hard steps.**

- **Never restart `gluetun` alone.** qBittorrent and the port-sync sidecar run
  `network_mode: service:gluetun`; restarting gluetun destroys the netns under a
  running qBittorrent. Recovery is
  `docker restart gluetun && sleep 8 && docker restart qbittorrent`. A
  full-stack restart self-heals; a partial one does not.
- **Any gluetun bump must be checked against `/v1/portforward`** — the sidecar
  hardcodes that path and gluetun has moved it before.
- **Jellyfin and Ollama are one change unit** — they share the GPU via CDI.
- **After a Jellyfin *major*, re-run the Samsung Tizen sideload**
  ([apps2samsung](../../configs/ciri/apps2samsung/)) — the TV client does not
  auto-update.
- **Sure's bind-mounted initializer monkeypatches
  `Chat::UNDELIVERED_RESPONSE_TIMEOUT`** — an upstream refactor of `chat.rb`
  breaks it silently. Verify AI chat still answers.
- **`docker compose pull` skips profile-gated services.** The
  `postgres-backup-local` sidecars sit behind `profiles: [backup]` and need
  `--profile backup`; they must move in lockstep with the postgres major or
  `pg_dump` version-mismatches against the server.
- **Immich**: service names `database`/`redis` are load-bearing DNS names; the
  `.immich` marker files must exist; do **not** substitute plain `postgres:16`
  for the VectorChord build.
- **Restarting dockerd restarts every container on ciri** — schedule it.

**Pre-flight, every docker upgrade.** Mount guards (`create_host_path: false`)
mean jellyfin, qbittorrent, sonarr, radarr, bazarr and ollama **refuse to start**
on recreate if `/mnt/media/library`, `/mnt/torrents/incomplete` or
`/mnt/ai-models` is absent. Verify mounts *before* pulling. Check `/data`
headroom, and `docker image prune` after.

---

## 4. Runbook

### Phase 0 — prerequisites (once, before any upgrade)

| # | Item | State |
|---|---|---|
| 0.1 | **Kuma `resend_interval = 0` on ~29 of ~31 monitors** — Kuma notifies **once** on a down transition then goes silent forever. This turned a 10-second detection into a **12-day** outage. Set to 30, matching `media-export`/`media-mount`. Its own docs already call it *"the cheapest high-value fix"* and *"still the highest-value change in the lab"* | **OPEN — do this first.** A post-upgrade process that leans on Kuma is meaningless until it is done |
| 0.2 | PVE enterprise repos disabled on both nodes | **DONE** — verified 2026-08-23: `pve-enterprise` and ceph enterprise both `Enabled: false`, `pve-no-subscription` active on both. Closes the open item in [backups.md](../backups.md) |
| 0.3 | Backups green and datastore has headroom | **DONE** — verified 2026-08-23: all guests finished 04:00–04:08, `pbs-vault` **5.83%** used (894 GiB free) |
| 0.4 | Pin the two floating tags (`sure:stable`, `valkey:9`) | **OPEN.** `sure:stable` currently resolves to **v0.7.2**. A rollback cannot name a version it never recorded |

**[VERIFY]** re-run 0.2/0.3 at the start of any window:

```bash
scripts/maintenance/lab-inventory.sh
```

### Phase A — decide (remote, ~5 min)

**[VERIFY]**

```bash
scripts/maintenance/lab-inventory.sh
scripts/maintenance/lab-smoke.sh          # baseline BEFORE changing anything
```

A failure in the *baseline* smoke test is pre-existing and must be understood
before upgrading, not diagnosed afterwards as if the upgrade caused it.

### Phase B — refresh what is unmeasured (remote)

Stale caches make "0 pending" meaningless (§1). **[USER]**, per node:

```bash
apt update                                  # on the node
for id in $(pct list | awk 'NR>1 {print $1}'); do pct exec "$id" -- apt update; done
```

**[VERIFY]**: re-run `lab-inventory.sh`; no row should read `cache Nd stale`.

### Phase C — guests (remote, weekly)

**[USER]**, per node, LXCs first then ciri:

```bash
pct exec <id> -- apt full-upgrade -y
```

Then the exceptions in §3.2 — **Caddy's plugin above all**.

**[VERIFY]**

```bash
scripts/maintenance/lab-smoke.sh
scripts/maintenance/lab-deep-check.sh
```

### Phase D — host and kernel (physical presence, monthly)

**One node. yennefer first.** **[USER]**:

```bash
apt full-upgrade -y
reboot
```

**[VERIFY]** once it returns:

```bash
scripts/maintenance/lab-inventory.sh --strict     # invariants must be OK
scripts/maintenance/lab-smoke.sh
scripts/maintenance/lab-deep-check.sh
```

Only when every check passes, repeat for **geralt** — where `--strict` matters
most, because it is the node with the six invariants.

### Phase E — record

Update the registry in [maintenance.md](../maintenance.md) with the new
versions and the date. Mirror any changed compose file back into `configs/` per
the `CLAUDE.md` mirror rule. Append as-built deviations to this document.

**Rollback.** Guest broken → restore from PBS (`pct restore` / `qm restore`, loop
proven 2026-07-10). Container broken → re-pin the previous tag, `up -d`. Host
broken and not booting → physical access; there is no host-level backup, which
is why `--strict` gates the invariants and why the nodes are never done together.

---

## 5. Verification

Tooling verified 2026-08-23 against the live lab, in both directions:

| # | Test | Result |
|---|---|---|
| D1 | `lab-inventory.sh` | **PASS** — both nodes, all 8 LXCs, ciri, image drift, 6/6 invariants OK |
| D2 | `lab-smoke.sh` full | **PASS with a real finding** — 22 services, 44 assertions, one genuine 502 (`books`) |
| D3 | Smoke test can go red | **PASS** — the `books` 502 is a live demonstration that a dead backend is detected; exit code 1 |
| D4 | `lab-deep-check.sh` dry | **PASS** — `media-export` + `media-client` green, `— not pushing` confirmed on the wire, no Kuma state changed |
| D5 | Deep check can go red | **PASS** — `EXTRA_ENV="MIN_GIB=99999"` → FAIL with a labelled reason, exit 1, no alert fired |
| D6 | First yennefer pass | **NOT YET RUN** |
| D7 | First geralt pass | **NOT YET RUN** |

D3 and D5 matter as much as the green runs. A monitor that has never been red has
not been tested — the same argument that produced the functional Push monitors
after liveness proved insufficient three separate times.

---

## 6. Known sharp edges

- **`timeout(1)` does not exist on macOS** (hit 2026-08-23). The first
  `lab-inventory.sh` wrapped every ssh call in it; on the laptop every remote
  read failed, `|| true` swallowed the error, and the report printed a confident
  `6 INVARIANTS FAILED` for a lab it had never contacted. **A checking tool that
  cannot distinguish *unreachable* from *failed* is worse than no tool**, because
  it is believed. Fixed by preferring `timeout`/`gtimeout` when present,
  otherwise bounding the session with ssh keepalives, and by reporting an unread
  value as `UNREADABLE` — never as a pass, never as a failure.
- **Positional parsing of a remote payload silently misattributes fields** (hit
  2026-08-23). Any remote command emitting zero lines instead of one shifts every
  field after it; the invariants section reported grub's cmdline as `VM 150
  onboot` and a filesystem type as `zfs_arc_max` — both plausible-looking and
  both wrong. All payloads are now `key<TAB>value`, addressed by key.
- **`printf '%s'` without a trailing newline drops the last record** of a `while
  read` consumer (hit 2026-08-23) — this silently omitted the final LXC of every
  node (104 `uptime-kuma`, 204 `beszel`) from a report that otherwise looked
  complete. The most dangerous class of bug in a checking tool is the one that
  makes it quietly check *less* than it claims.
- **`pct exec` inside a `while read` loop consumes the loop's stdin** — redirect
  `</dev/null`.
- **A stale apt cache reports "0 upgradable"**, which reads as healthy and is not.
- **`apt upgrade` drops Caddy's DNS plugin**, and the consequence appears ~30
  days later at renewal, not at upgrade time.

---

## 7. Cost and risks

| Risk | Mitigation |
|---|---|
| A node does not come back from a reboot | Physical presence is mandatory for host reboots; one node at a time, so the other still serves DNS, Tailscale and alerting |
| An upgrade breaks a service and it is not noticed | Smoke + deep check are gates, not suggestions; Phase 0.1 restores Kuma's ability to keep telling you |
| A kernel upgrade drops a boot-critical module parameter | Six invariants checked automatically; `--strict` fails the gate |
| Rollback needed for a guest | PBS nightly `--all`, restore loop proven 2026-07-10 |
| Rollback needed for a **host** | **Not covered** — no host-level backup exists. Accepted; this is why the nodes are staggered and the invariants gated |
| Batch upgrade makes a failure unattributable | Tiering (§3.3); tier 2 is one stack per window |
| Routine advisory noise erodes the alert channel | No timer, no ntfy: the inventory is pulled when you sit down to work (§2) |

Time cost: ~30 min weekly (remote), ~1 h per node monthly (physical), ~2 h
quarterly for docker tiers.

---

## 8. Open items

- **Kuma `resend_interval` (Phase 0.1) — OPEN, and it outranks everything else
  in this document.** It is not this proposal's finding; it has been the named
  highest-value change in the lab since the 12-day outage.
- **`books.kaermorhen.fyi` returns 502 — OPEN (found 2026-08-23).** The
  Caddyfile routes it to an audiobookshelf backend on `:13378` that was never
  deployed; `configs/ciri/audiobookshelf/` is in the repo but untracked and
  there is no `/data/stacks/audiobookshelf`. Either deploy the stack or remove
  the route — an advertised service that 502s trains you to ignore a red smoke
  test.
- **The two floating tags (Phase 0.4) — OPEN.**
- **geralt is 98 packages behind including security updates — OPEN**, and is the
  natural first real exercise of Phase D.
- **The node-level version divergence is unexplained** — yennefer reached
  `pve-manager` 9.2.11 while geralt sat at 9.2.4, with no record of when or why.
  The registry in [maintenance.md](../maintenance.md) exists so this cannot
  recur silently.
- **A stale-cache guard could be automated** — a weekly read-only timer that only
  reports cache age (never applies, never alerts) was considered and deferred as
  premature; revisit if Phase B is repeatedly forgotten.
- **Host-level backup remains absent.** Out of scope here, but it is the one
  rollback path this proposal cannot offer.
