# 011 — BRIEF / PROMPT ONLY, NOT A PROPOSAL

> **This file is not proposal 011.** It is the prompt and the verified findings to
> hand a future session so it can *write* proposal 011 without re-deriving
> anything. Session date: **2026-09-12**. Number 011 is reserved.
>
> When the proposal is written, it replaces this file
> (`011-temperature-monitoring.md`) and this one is deleted.

---

## The prompt (paste this)

```
Write docs/proposals/011-temperature-monitoring.md in the same style as
proposals 007 and 008: numbered sections, as-executed runbook steps, an
"alternatives considered" section, and a "what is left before building" section.

Goal: track temperature for every component in the lab that can report one —
CPU, GPU, NVMe SSDs, internal SATA SSD/HDDs, and the external USB HDD — so the
data can answer one question: does the lab need better airflow, and where?

Constraints and decisions already settled (do not re-litigate; see the
"Verified findings" section of 011-temperature-monitoring.prompt.md):
  - Beszel and Pulse both stay. Do not propose retiring either. The reasoning
    is recorded in docs/monitoring.md "Tool scope — Beszel vs Pulse".
  - No new monitoring tool. Beszel owns metrics, Pulse owns the Proxmox/PBS
    view, Kuma owns up/down. Grafana/Prometheus was argued down in proposal
    001 §2 and nothing has changed.
  - All modifying commands are run by the user, not the agent. Read-only
    verification over SSH only.
  - Prefer zero-cost/zero-hardware fixes first.

Cover at minimum:
  1. Why now — geralt's throttle counters (numbers in the findings below).
  2. What each sensor source can and cannot see, and why (hwmon vs smartctl vs
     nvidia-smi vs VFIO).
  3. The four gaps and the fix for each, cheapest first.
  4. Alert thresholds — Beszel's temperature threshold is GLOBAL per host, so
     decide explicitly what it is set for and who owns disk temps.
  5. Airflow remediation options for geralt, with the cheap/reversible ones
     first, and a way to measure whether each one worked.
  6. A verification section: what to measure, for how long, before calling any
     airflow change effective.

Read first: docs/monitoring.md, docs/hardware-inventory.md, docs/storage.md,
docs/gpu-passthrough.md, docs/proposals/008-lab-dashboard.md,
docs/proposals/001-initial-infrastructure-plan.md §2.
```

---

## Verified findings — 2026-09-12, read-only over SSH

Everything below was measured, not assumed. A future session should not re-derive it.

### Temperatures as measured

| Sensor | geralt | yennefer |
|---|---|---|
| CPU package | 59–64 °C sustained, **transient spikes to 85 °C** | 47 °C |
| Chassis (`acpitz`) | 61–63 °C | 27 °C |
| PCH | 60 °C | 42 °C |
| NVMe composite | 54 / 55 °C | — (SATA only) |
| NVMe sensor 2 | **68 °C** | — |
| Internal HDD | 43 °C | 40 °C |
| Boot SSD | 55 °C | 37 °C |
| External media HDD | 42–46 °C | — |

Sampled at load average ~1.0 on a 12-thread CPU, i.e. near-idle.
**yennefer is cold everywhere and needs no airflow work. This is a geralt-only
problem.** It also explains the media disk's 39 → 46 °C drift recorded in
`storage.md` — that disk sits in geralt's thermal shadow.

### Why "it idles at 60 °C" understates it

geralt, 18 days uptime:

```
package_throttle_count:         493,252
package_throttle_total_time_ms: 3,495,920    (~58 min)
core_throttle_count:            347,060
core_throttle_total_time_ms:    2,517,252    (~42 min)
max single throttle event:      517 ms
```

~19 thermal-limit excursions per minute, each sub-second. Only 0.22 % of uptime
throttled, so not an emergency — but the CPU is repeatedly hitting its limit, and
**this is invisible to both Beszel and Pulse because both poll at ~60 s.** The
throttle counters, not the temperature gauge, are the correct metric for this
fault.

### The four gaps

| # | Gap | Fix | Cost |
|---|---|---|---|
| 1 | **`drivetemp` not loaded on either node** (module present, not loaded) — this is why no SATA disk temps appear in *either* dashboard | `modprobe drivetemp` + persist in `/etc/modules`; geralt's `steel` HDD and yennefer's SSD + backup HDD then appear as hwmon sensors that **both tools pick up with no config** | free, one line |
| 2 | **External USB media disk temp is unreachable via hwmon** — USB-SATA bridges do not expose it; only `smartctl -d sat` reads it (works thanks to the `0bc2:ab24:u` quirk). Beszel 0.19 added SMART but external/USB SMART is a known upstream gap, `smartctl --scan` reports USB disks as `-d scsi`, and the agent runs as `User=beszel` without `CAP_SYS_RAWIO` | extend the existing `scripts/monitoring/media-link-health.sh` push pattern to carry temperature to Kuma | free |
| 3 | **GPU telemetry is BROKEN right now** — see below | reboot ciri | free |
| 4 | **Sub-second thermal spikes invisible to any 60 s poller** | push `thermal_throttle/*` counters to Kuma, same pattern as #2 | free |

### Gap 3 in detail — GPU telemetry is currently dead

`nvidia-smi` on ciri fails: `Failed to initialize NVML: Driver/library version mismatch`.

| | Version |
|---|---|
| Loaded kernel module (`/proc/driver/nvidia/version`) | **580.173.02** |
| Installed userspace packages (`libnvidia-*-580-server`) | **580.178.04** |
| ciri last boot | 2026-08-24 16:48 (18 days) |

An apt upgrade replaced the userspace libraries after the last boot, so the
matching kernel module was never loaded. **A ciri reboot fixes it.**

Two consequences worth stating in the proposal:

- `docs/monitoring.md` records the Beszel GPU panel as live and verified
  2026-07-23. It is almost certainly dead now and nothing alerted. That
  documentation line is stale.
- This is the same **silent CPU-fallback** failure class as the earlier Ollama
  incident (an 18 GB model ran on CPU for three weeks). Jellyfin hardware
  transcoding and Ollama GPU inference should both be re-verified after the
  reboot, not assumed.

### Sensor-source reference

| Component | Readable by | Notes |
|---|---|---|
| CPU package + per-core | `coretemp` via hwmon | already flowing to Beszel on both nodes |
| Chassis / PCH | `acpitz`, `pch_*` | already flowing |
| NVMe SSDs | `nvme` hwmon | geralt only; yennefer's M.2 slot is SATA |
| SATA SSD/HDD | **`drivetemp`** hwmon, or `smartctl` | module not loaded — gap 1 |
| External USB HDD | **`smartctl -d sat` only** | never appears in hwmon — gap 2 |
| GPU (GTX 1060) | **`nvidia-smi` inside ciri only** | VFIO-bound; host and PVE API both see nothing |

`lm-sensors` is **not** installed on either node and is **not needed** — every
source above is either hwmon sysfs or `smartctl`.

### Environment facts

- Beszel agents: `0.18.7` on geralt, yennefer **and ciri**. Latest is **0.19.0**
  (2026-09-03), which adds SMART data and GPU telemetry — an upgrade is a
  candidate step, following `maintenance.md` house policy (pinned version,
  auto-update off).
- geralt agent already sets
  `EXTRA_FILESYSTEMS=/silver__silver-zfs,/steel__steel-zfs,/mnt/media__media-usb`.
- Beszel's temperature alert threshold is **global per host** (one value for all
  sensors, `monitoring.md` gotchas) and is currently **85 °C / 10 min** — exactly
  where geralt's spikes land, so it will flap once disks start reporting. The
  proposal must decide this explicitly.
- Pulse is `v6.4.1` in LXC 205, agentless, alerting deliberately off.

### Open questions for the proposal to settle

1. Beszel 0.19.0 upgrade — worth it for SMART + GPU telemetry, or does the
   Kuma push-script route cover gaps 2 and 4 well enough on its own?
2. Does Beszel's 0.19 SMART implementation actually read a USB bridge behind
   `-d sat`? If not, gap 2 stays a script regardless of version.
3. Granting the agent `CAP_SYS_RAWIO` — acceptable, or keep SMART with `smartd`
   and the push scripts?
4. Where does the global-threshold conflict land: lower to ~80 °C as early
   warning, or keep 85 °C for the CPU and leave disks entirely to `smartd`?
5. Airflow remediation for geralt — elevation/stand, dust clearing, thermal
   repaste (2018 chassis, original paste), placement relative to the external
   disk, lid-open vs closed. Which are worth doing, in what order, and how is
   each one's effect measured? The throttle counters are the obvious before/after
   metric since they are cumulative and sensitive.
