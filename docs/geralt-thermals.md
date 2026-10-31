# geralt: thermal analysis (2026-10-21)

**Question.** Is geralt running too hot for its workload, and does it need a
repaste or another remedy?

**Verdict.** Yes, the CPU runs hot for a very light workload. Every other
component is within limits. Two things push the CPU temperature up:

1. **A software policy** that keeps the CPU at maximum boost. The PVE kernel
   defaults `intel_pstate` to the `performance` governor with EPP
   `performance`, so every short burst jumps straight to 4.1 GHz. **Changed
   2026-10-21** (§5). After 11 days, light workloads run about 7 °C cooler,
   but heavy CPU-plus-GPU bursts still throttle as often as before (§5a).
2. **Ageing thermal paste.** It has been repasted 2–3 times; the last was
   about 2–3 years ago, before geralt became a 24/7 server. Small rises in load cause steep
   temperature rises, the CPU hits its 100 °C limit at about 5 % average
   use, and the throttling is lopsided across cores (§3). **A repaste and
   fan clean are pending** (§6).

Linux has no fan driver for this model. The fans are now read directly from
the embedded controller, and the factory curve tops out at 75 % (§4).

Related: [hardware-inventory.md](hardware-inventory.md) (the hardware),
[monitoring.md](monitoring.md) (Beszel and alerting),
[gpu-passthrough.md](gpu-passthrough.md) (the dGPU shares the CPU's cooler),
[maintenance.md](maintenance.md).

**Setting.** Room temperature is 25–40 °C. The laptop stands upright with
the lid closed, in an "L" against the floor, and nothing blocks the intakes
or exhausts.

---

## 1. Method

All data was gathered read-only.

- **Beszel history**: the hub's `data.db` (LXC 204) was copied off the box
  and queried locally. Coverage: 30 days of 8-hour buckets, 7 days of 2-hour
  buckets, 12 hours of 10-minute buckets and the last hour of 1-minute
  samples. Samples from geralt, ciri (GPU) and yennefer were matched by
  nearest timestamp.
- **Beszel limitation**: temperatures are stored as **bucket averages only**.
  Only CPU usage has a stored max (`cpum`). Short peaks show up in the
  1-minute data and the kernel throttle counters, not in the long history.
- **Live sources on geralt**: hwmon (`coretemp`, `acpitz`,
  `pch_cannonlake`, nvme), the `thermal_throttle` counters, the RAPL power
  limits and energy counter, cpuidle residency, and `smartctl` on all four
  disks.
- **Useless sensors**: yennefer's `acpitz` reads a flat 27.8 °C, and
  geralt's Kingston "Sensor 2" reads a flat ~72 °C. Neither changes with load,
  so neither tells us anything (yennefer's is no proxy for room temperature).

## 2. The workload is light

| Metric | 30-day picture |
|---|---|
| Average CPU use, 8-hour buckets | 3.5–8.4 % |
| Highest 2-hour peak CPU use | ~40 % |
| Load average | ~0.5–1.7 on 12 threads |
| Package power | 13–20 W idle or light, ~30 W during disk-heavy bursts; PL1 45 W / PL2 90 W |
| GTX 1060 (in ciri) | idle P8, ~4 W, 46–50 °C; bursts up to 44 W / 71 °C |
| Idle states | healthy: most time in C6, C8 and C10 |

## 3. CPU temperatures relative to load (before the change)

| Situation | Avg CPU use | Package temp |
|---|---|---|
| Quietest 8-hour windows (10-18, 10-19) | 3.5 % | 59–61 °C |
| Typical 8-hour windows | ~5 % | 62–66 °C |
| Mild bump, 2-hour buckets (10-15 morning) | 8.5 % | 71–73 °C |
| 1-minute samples during brief bursts | 7–11 % | **78–88 °C** |
| 10-20 14:10 UTC, 10-minute bucket, CPU and GPU (44 W) together | 30 % | **89.5 °C average**, `acpitz` 92 °C |

What this shows:

- **Steep response.** About half a core of extra work (+4 % average CPU)
  adds 8–10 °C. Heat isn't leaving the chip efficiently.
- **The 100 °C limit is hit at idle-class load.** Package throttle counter
  after 57 days of uptime: **659,543 events, 4,821 s (~80 min) in total**
  (`/sys/devices/system/cpu/cpu0/thermal_throttle/`). The kernel no longer
  logs these events, which is why the journal shows nothing.
- **Lopsided.** Per-core throttle counts for cpu0–5 are 471k, 21k, 219k,
  21k, 38k and 11k. Two cores do almost all the throttling. Live, the cores
  spread 71–81 °C at moderate load. That pattern fits uneven or pumped-out
  paste.
- **The alert has been firing.** Beszel's 85 °C / 10-minute temperature
  alert fired 27 times between 07-27 and 10-20 (§8).
- **Shared heat pipes.** On the GP63 the CPU and dGPU share one cooler. The
  14:10 GPU burst pushed the CPU to 89 °C at only 30 % use. AI or transcode
  work in ciri heats the CPU directly.

## 4. Other components

| Component | Typical / live | Limits | Notes |
|---|---|---|---|
| Chipset (`pch_cannonlake`) | 58–66 °C | — | normal for this generation |
| Kingston SNVSE500G (`silver`) | 53–58 °C | 85 / 95 | fine; ignore "Sensor 2" (flat ~72 °C) |
| WD SN520 (boot) | 54–56 °C | 82 / 86 | fine now; **lifetime log: 221 min above the 82 °C warning limit**, undated |
| Seagate ST1000LM049 (`steel`) | 41 °C | 60 | fine now; **lifetime max 67 °C**, attribute 190 flagged `In_the_past`, undated |
| USB media disk | 46 °C (max 49) | — | fine |
| GTX 1060 | 46–50 °C idle, 71 °C under load | — | fine |

The two lifetime overheat records may date from the laptop's gaming years.
They are baselined in §7, so any growth from here means it happened in
service.

### Fan speed is invisible to Linux

There is no fan hwmon device. MSI laptops expose fans only through the
embedded controller (EC), and the in-kernel `msi-ec` driver (`CONFIG_MSI_EC=m`,
kernel 7.0.14) only recognises a fixed list of EC firmware versions.
geralt's `16P5EMS1.109` isn't on it, so the driver refuses to load. This is
the same dead end the 2026-07-12 charge-cap investigation hit
([hardware-inventory.md](hardware-inventory.md), battery note).

The upstream [msi-ec](https://github.com/BeardOverflow/msi-ec) project knows
the sister board (`16P5EMS1.103`, GE63 Raider 8RE, config `CONF_G1_10`). Its
register map for that board:

| EC offset | Meaning |
|---|---|
| `0x68` | CPU temperature (as the EC sees it) |
| `0x71` | CPU fan speed, % |
| `0x80` | GPU temperature |
| `0x89` | GPU fan speed, % |
| `0xA0` | EC firmware string (already read this way in July) |
| `0xF4` | fan mode (auto / basic / advanced) |
| `0x98` bit 7 | Cooler Boost |

| Step | Do | Verify (read-only) | Status |
|---|---|---|---|
| F1 | On geralt: `modprobe ec_sys` (in-tree; `write_support` defaults to off) | `cat /sys/module/ec_sys/parameters/write_support` → `N`; `/sys/kernel/debug/ec/ec0/io` exists | **done 2026-10-21**, `N`; made persistent the same day |
| F2 | — | Dump EC RAM; check `0xA0` holds `16P5EMS1.109`, `0x68` follows `coretemp` and `0x80` follows ciri's `nvidia-smi` | **done**: firmware string ✓, EC CPU 52 vs coretemp 53 ✓, EC GPU 46 vs nvidia-smi 46 ✓ |
| F3 | Short CPU load to make the fans ramp | `0x71` / `0x89` rise with temperature and match what you hear | **done**, results below |
| F4 | Decide how to surface it | — | **declined**: no fan-failure alert, see below |

Persistent since 2026-10-21 (verified: the file contains `ec_sys`, and there
is no `options` line, so `write_support` stays `N`):

```bash
echo ec_sys > /etc/modules-load.d/ec_sys.conf
```

#### Confirmed EC map (16P5EMS1.109)

From a 2-minute 6-thread load (01:34:35–01:36:35 IST, 2026-10-21; package
54 → 82 °C), sampled every 5 s:

| Offset | Meaning | Evidence |
|---|---|---|
| `0x68` | CPU temp, °C | tracked coretemp within ~1–2 °C throughout |
| `0x6A–0x6F` | CPU fan curve temperatures: 50, 57, 64, 71, 78, 85 °C | fan steps landed on these |
| `0x71` | CPU fan, % | 47 → 54 at 67 °C → 61 at 71 °C → 68 at 77 °C; stepped back down with hysteresis after the load |
| `0x72–0x78` | CPU fan curve speeds: 0, 40, 47, 54, 61, 68, **75 %** | — |
| `0x80` | GPU temp, °C | matches nvidia-smi |
| `0x82–0x87` / `0x8A–0x90` | GPU fan curve: 55/60/65/70/75/80 °C → 0/45/50/55/62/70/**78 %** | not exercised (GPU stayed 46–48 °C) |
| `0x89` | GPU fan, % | stayed at 45 %, as expected |
| `0xCC–0xCD` | CPU fan tachometer, 16-bit; RPM ≈ 478000 ÷ value | 197 → 117 under load (≈2,430 → 4,090 RPM), lagging fan % by ~30 s as fan inertia would |
| `0xCA–0xCB` | GPU fan tachometer, same formula | steady 174–180 (≈2,700 RPM) while the GPU fan held 45 % |
| `0x98` bit 7 | Cooler Boost (both fans to 100 %) | off (`0x02`) |
| `0xF4` | fan mode | `0x0C` = auto |

The RPM formula is the convention used by MSI fan tools. The inverse relation
is proven here, but the absolute RPM is unverified.

**Key finding: in auto mode the fans top out at 75 % (CPU) / 78 % (GPU),**
and the last step only starts at 85 °C (CPU) / 80 °C (GPU). Under the test
load the CPU fan sat at 68 % while the package reached 82 °C. The headroom
between that and 100 % is reachable only through Cooler Boost or a custom
curve, both of which are **EC writes** (`write_support=1`). Not proposed
yet: a bad EC write on a box with no remote power-on is a physical-visit
failure. Revisit after the repaste if temperatures are still high.

#### F4: surfacing it

Beszel has no input for custom metrics, and `msi-ec` (in-tree or DKMS) would
not register a hwmon fan either, so this won't appear as a Beszel graph
whichever driver we use.

**Fan-failure alert: declined 2026-10-21.** Both fans have a long track
record. The laptop has had 7+ years of heavy use, including multi-hour gaming
sessions. The CPU fan was replaced about 3 years ago after a broken blade
fragment made it underspin and rattle, and both fans have run smoothly since.
A sudden stall is unlikely, and the 85 °C Beszel alert already catches any
cooling loss that matters. The registers stay readable for spot checks:

```bash
# read-only spot check: CPU temp, CPU fan %, GPU temp, GPU fan %
od -A n -t u1 -j 0x68 -N 1 /sys/kernel/debug/ec/ec0/io   # CPU temp, °C
od -A n -t u1 -j 0x71 -N 1 /sys/kernel/debug/ec/ec0/io   # CPU fan, %
od -A n -t u1 -j 0x80 -N 1 /sys/kernel/debug/ec/ec0/io   # GPU temp, °C
od -A n -t u1 -j 0x89 -N 1 /sys/kernel/debug/ec/ec0/io   # GPU fan, %
```

Never load `ec_sys` with `write_support=1` outside a deliberate, planned EC
change.

## 5. Change applied 2026-10-21: CPU policy

Executed by the user on geralt, about 01:10 IST:

```bash
echo powersave | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
echo balance_performance | tee /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference
echo 85 > /sys/devices/system/cpu/intel_pstate/max_perf_pct    # cap ~3.5 GHz
```

The governor has to change first: with `intel_pstate` in HWP mode, the
`performance` governor locks EPP at `performance` and the EPP write is
refused.

Verified (read-only, 01:17 IST): 12/12 cores `powersave` /
`balance_performance`, `max_perf_pct=85`, `no_turbo=0`. At idle the cores
sit at 800–900 MHz and peak at 3,493 MHz, package 52–54 °C at 13–17 W. The
same load before the change ran 62–66 °C. This was night time, so a cooler
room accounts for part of the drop. The 7-day Beszel comparison in §7 is the
real test.

**Made persistent 2026-10-21 (~01:53 IST)** with a oneshot unit; without
it, the reboot in the monthly maintenance pass would revert all three
settings. Verified (read-only): unit `enabled` + `active`,
`Result=success`, exit 0, `systemd-analyze verify` clean, live values
unchanged (12× `powersave`, 12× `balance_performance`, `max_perf_pct=85`).
**Still unproven across a real reboot**: re-run the verify block after the
next maintenance pass.

```ini
# /etc/systemd/system/cpu-power-policy.service
[Unit]
Description=CPU power policy: powersave + balance_performance EPP, 85% max perf (docs/geralt-thermals.md)

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu[0-9]*/cpufreq; do echo powersave > "$c/scaling_governor"; echo balance_performance > "$c/energy_performance_preference"; done; echo 85 > /sys/devices/system/cpu/intel_pstate/max_perf_pct'

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now cpu-power-policy.service
# verify
systemctl is-enabled cpu-power-policy.service      # enabled
sort /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor | uniq -c
cat /sys/devices/system/cpu/intel_pstate/max_perf_pct
```

**Rollback:** `systemctl disable --now cpu-power-policy.service`, then write
`performance` to `scaling_governor` and `100` to `max_perf_pct` (or reboot).

## 5a. Result after 11 days (checked 2026-11-01)

**Verdict.** Light workloads now run **about 7 °C cooler**. Heavy combined
CPU and GPU bursts **still hit the limit**: daily throttling is unchanged,
and the 85 °C alert fired once more. The policy fixed the everyday
temperature; the cooler's capacity under load is still the repaste's job
(§6).

Beszel 8-hour buckets, matched as in §1. "Before" is 10-02 → 10-20
(57 buckets), "after" is 10-21 → 10-31 (33 buckets). The 2-hour buckets for
10-24 → 10-31 agree (package mean 54.8 °C).

| | Before | After | Change |
|---|---|---|---|
| CPU package, mean / median | 63.5 / 63.4 °C | **55.2 / 54.9 °C** | **−8.3 °C** |
| CPU package, range | 59.2–70.7 °C | 53.0–62.5 °C | max −8 °C |
| `acpitz` | 64.6 °C | 56.8 °C | −7.8 °C |
| Average CPU use | 4.8 % | 9.3 % | see below |
| Chipset (`pch_cannonlake`) | 60.0 °C | 62.9 °C | +2.9 °C |
| GTX 1060 (idle, ~4.5 W) | 47.7 °C | 51.0 °C | +3.3 °C |
| NVMe composite (Kingston / WD) | 53.4 / 55.0 °C | 53.8 / 54.6 °C | no change |
| yennefer CPU package (rough room-temperature proxy) | 43.8 °C | 42.8 °C | −1.0 °C |

- **About 7 of the 8 °C is the change.** yennefer cooled by only ~1 °C over
  the same period, so the room was only slightly cooler.
- **CPU use doubled, not the work.** At 800–900 MHz the same work keeps the
  cores busy for a larger share of each second. The drop holds at every load
  level: 8–10 % CPU now averages 54.7 °C, where 4–6 % used to average
  63.7 °C.
- **Chipset and GPU are ~3 °C warmer, probably from slower fans.** The CPU
  now sits below the curve's 64 °C step (§4), so the fan holds 47 % instead
  of 54 % and moves less air over the shared heat pipe and the chipset. This
  is an inference, and both are well within limits.
- **One more alert:** 85 °C from 10-25 18:07 to 18:29 UTC (23:37–23:59 IST).
  In that 2-hour bucket geralt's CPU use peaked at 53 % while ciri's GPU was
  working (~15 W average, ~9 % utilisation), likely a local-AI burst. Same
  pattern as the 10-20 alert: CPU and GPU loaded together on the shared heat
  pipe.
- **Throttling per day is unchanged:**

  | | Before (57 d 8 h to 10-21 01:16 IST) | After (10.96 d to 11-01 00:20 IST) |
  |---|---|---|
  | Package throttle events | ~11,500/day | ~11,740/day (+128,653) |
  | Time at the 100 °C limit | ~84 s/day | ~93 s/day (+1,020 s) |
  | Core increments cpu0–5 | — | +71,482 / +3,977 / +65,438 / +1,014 / +20,848 / +464 |

  The same two cores dominate. A 60-second idle check on 11-01 showed **zero**
  new events (hottest core 66 °C), so all of it comes from load bursts. Some
  of the before period was hotter summer weather, so "unchanged" is not
  "worse".
- **Persistence:** still live on 11-01 (12× `powersave` /
  `balance_performance`, `max_perf_pct=85`, unit `active`, `ec_sys`
  `write_support=N`). No reboot since 2026-08-24, so surviving a reboot is
  **still unproven**.

## 6. Pending: repaste and fan clean

Treat it as a maintenance window. geralt needs someone at the machine to
power on (no WoL), and ciri and Uptime-Kuma go down with it. DNS and
Tailscale fail over to yennefer.

- Clean both fans and the heatsink fins. Dust in the fins causes the same
  symptoms as dry paste.
- Repaste **both** the CPU and GPU dies (shared heat pipes).
- Inspect the GPU memory and power-circuit thermal pads, and replace them
  only at the measured thickness. Wrong-thickness pads lift the heatsink off
  the dies.
- Optional, free or cheap: raise the laptop's base, or put a small USB fan
  at the intakes. Most useful at 35–40 °C room temperature.

**Done when** (compare with §7): typical package temperature in the 50s at
~5 % average CPU, short bursts below ~75 °C, and the package throttle
counter roughly flat week to week.

## 7. Baselines (2026-10-21, ~01:16 IST, 57 d 8 h uptime)

| Measure | Value | Re-read with |
|---|---|---|
| Package throttle count / total time | 659,543 / 4,821,467 ms | `cat /sys/devices/system/cpu/cpu0/thermal_throttle/package_throttle_{count,total_time_ms}` |
| Core throttle counts cpu0–5 | 471,163 / 20,752 / 218,935 / 21,300 / 38,223 / 10,931 | `grep -h . /sys/devices/system/cpu/cpu{0..5}/thermal_throttle/core_throttle_count` |
| Beszel 8-hour package average, pre-change | 59.2–70.7 °C, typically 62–66 °C | Beszel → geralt → Temperature, 30-day view |
| WD SN520 warning-temperature time | 221 min | `smartctl -a /dev/nvme1n1 \| grep 'Warning  Comp'` |
| Seagate `steel` attr 190 worst / 194 worst | 033 (67 °C) / 067 | `smartctl -A /dev/sda \| grep -E '^19[04]'` |
| Beszel temperature alerts fired | 27 (07-27 → 10-20) | hub DB `alerts_history`, or the ntfy feed |

Throttle counters reset on reboot, so record the uptime with every reading.

**Re-read 2026-11-01 00:20 IST** (68 d 7 h uptime, same boot, CPU policy in
place):

| Measure | Value |
|---|---|
| Package throttle count / total time | 788,196 / 5,841,679 ms |
| Core throttle counts cpu0–5 | 542,645 / 24,729 / 284,373 / 22,314 / 59,071 / 11,395 |
| Beszel 8-hour package average, post-change | 53.0–62.5 °C, mean 55.2 °C |
| Beszel temperature alerts fired | 28 (one more, 10-25) |

The repaste comparison should be measured against these post-policy values,
not the 10-21 ones, so it isolates the repaste's effect.

## 8. Open

- After the next reboot, confirm that `cpu-power-policy.service` and the
  `ec_sys` autoload both came back on their own (§5 verify block, plus
  `cat /sys/module/ec_sys/parameters/write_support` → `N`). Both were
  installed and verified live 2026-10-21.
- Fan visibility: F1–F3 done and persistent 2026-10-21, F4 alert declined (§4).
- **After the repaste**, revisit Cooler Boost or a custom curve to lift the
  75 % auto-curve ceiling (EC write) (§4). Deferred by decision: the user
  will raise it once the repaste is done.
- Repaste and fan clean (§6), then a 7-day Beszel comparison against the
  2026-11-01 re-read in §7.
- Alert count after the policy change: 28 (one more, 10-25, §5a).
- Beszel's 85 °C / 10-minute temperature alert has **already fired 27
  times** (2026-07-27 to 2026-10-20, ~228 min in total; per month: Jul 11,
  Aug 7, Sep 3, Oct 6). The latest ran 10-20 14:07–14:32 UTC, the GPU-burst
  bucket in §3. Check the count again after the repaste. A fully healthy
  cooler at this workload should keep it near zero.
