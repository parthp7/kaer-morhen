# geralt: slow WAN downloads — RCA (2026-08-24)

**Symptom.** `apt full-upgrade` on geralt crawls, capping around 100–450 kB/s
against `download.proxmox.com`, while yennefer finishes quickly. Long-standing
and reproducible across every upgrade.

**Verdict.** geralt's Killer E2400 NIC (`alx` driver) drops **~5% of received
packets** into RX FIFO overflow under load. On the LAN that is invisible; across
a 172 ms WAN path it collapses TCP throughput by ~500×. Two adjacent defects
(a PCIe ASPM error storm and 802.3x flow control) were found and fixed along the
way — **neither was the cause**. The NIC fault itself is not tunable.

Related: [hardware-inventory.md](hardware-inventory.md) (the NIC and its AER
noise), [network.md](network.md), [maintenance.md](maintenance.md).

---

## 1. It is not the mirror, and not the internet

The obvious hypothesis — a slow Proxmox mirror — is disproven. Both nodes
resolve `download.proxmox.com` to the **same IP** (`117.120.5.231`) via the
**same resolver** (the router), and measured against that exact IP with an
explicit `Host:` header:

| Host | ICMP RTT | TCP connect | 20 s steady-state |
|---|---|---|---|
| yennefer | 172.9 ms | 0.17 s | **6.7 MB/s** |
| geralt | 172.8 ms | 0.17 s | **132 kB/s** |

Same target, same path, same switch, **51× apart**. The mirror is fine —
yennefer has pulled 37 MB/s from it. The fault is host-local to geralt.

## 2. What was eliminated

Each of these was measured, not assumed:

| Suspect | Verdict |
|---|---|
| Slow Proxmox mirror | **No** — yennefer gets 6.7–37 MB/s from the same IP |
| Different mirror / geo-DNS | **No** — both nodes resolve to the identical IP |
| Link speed / duplex | **No** — both 1000 Mb/s full duplex, both PCIe 2.5 GT/s x1 |
| CPU starvation | **No** — the RX CPU was **99% idle** (1490/1500 idle ticks) during a transfer |
| Memory pressure | **No** — 23 GB free, and every TCP pressure counter (`PruneCalled`, `RcvPruned`, `TCPMemoryPressures`, `TCPBacklogDrop`) reads **0** |
| VM/VFIO contention | **No** — ciri was **stopped** for these tests and geralt was still slow |
| IOMMU DMA translation | **No** — active on **both** nodes, no cmdline params, 0 DMAR faults |
| Receive window | **No** — `rcv_wnd` 1.34 MB, ample for the bandwidth-delay product |
| PCIe ASPM error storm | **Contributing defect, fixed — not the cause** (§3) |
| 802.3x flow control | **Contributing defect, fixed — not the cause** (§4) |

## 3. Defect one — ASPM L0s, and a 3.9-million-error PCIe link

geralt's NIC and yennefer's differ in exactly the way that matters:

| | geralt (Killer E2400) | yennefer (RTL8111) |
|---|---|---|
| `LnkCtl` | **`ASPM L0s L1 Enabled`** (`0x0143`) | `ASPM L1 Enabled` — **no L0s** |
| L1 exit latency | **`unlimited`** | `<64 us` |
| ASPM opt. compliance | **`ASPMOptComp-`** | `ASPMOptComp+` |
| L1 substates | none | full L1.1 / L1.2 |

L0s active, an unbounded wake latency, and no compliance claim is the textbook
recipe for correctable PCIe errors on Atheros parts. The counters agreed:

```
RxErr    1,007,038      BadTLP     294,994
BadDLLP  2,360,425      Timeout    446,209
TOTAL_ERR_COR          3,920,508      (~24,800/hour, while idle)
```

**Fix, verified**: clear the ASPM bits on the endpoint *and* its upstream
bridge — ASPM is negotiated per link, so one end is not enough.

```bash
setpci -s 00:1d.6 CAP_EXP+10.w=0c40     # upstream bridge
setpci -s 05:00.0 CAP_EXP+10.w=0140     # the NIC
```

Result: **~24,800 errors/hour → 0**. Throughput: **unchanged**. A real defect,
fixed; not the one causing the symptom.

This is the same family of fault as the D3cold/PGON hang in
[gpu-passthrough.md](gpu-passthrough.md) — this laptop's firmware has bad PCIe
power management generally.

## 4. Defect two — flow control turning a dropped packet into a stalled link

geralt negotiated 802.3x pause **on**; yennefer negotiated it **off**. So when
the NIC overran its FIFO, geralt emitted PAUSE frames — **37,484** of them —
telling the switch to stop sending *everything*, rather than dropping one packet
and letting TCP recover in microseconds.

**Fix, verified**: `ethtool -A nic0 autoneg off rx off tx off` → PAUSE frames
per transfer went 372 → **0**. Throughput: **unchanged**. Also a real defect,
also not the cause.

## 5. Root cause — the NIC drops ~5% of RX under load, and RTT does the rest

With ASPM clean, pause disabled, CPU idle and memory free, a 15 s transfer still
measured:

```
rx packets 1534    FIFO overflow drops 84    ->  LOSS RATE 5.19%
```

Idle, over 25 s: **0 drops**. So this is not a constant hardware fault — the NIC
cannot absorb sustained inbound bursts, at rates as low as 126 kB/s, with the
receiving CPU 99% idle. `alx` exposes **neither ring sizing nor interrupt
coalescing** (`ethtool -g` and `-c` both return *Operation not supported*), so
there is nothing to tune.

**Why 5% loss is survivable on the LAN and fatal on the WAN.** TCP throughput
follows roughly `MSS / (RTT × √p)` — inversely proportional to RTT. The same NIC,
the same drops, two paths:

| Path | RTT | Throughput |
|---|---|---|
| geralt → yennefer (LAN) | **0.46 ms** | **26–65 MB/s** |
| geralt → Proxmox (WAN) | **172 ms** | **126 kB/s** |

A **500× difference from the same NIC with the same defect.** On the LAN a lost
packet is recovered in under a millisecond; across 172 ms each loss costs a full
round trip and CUBIC halves the window before it can regrow. This also explains
why Debian (24 ms edge) gave geralt 4.8 MB/s while Proxmox (172 ms) gave 0.13 —
same NIC, same loss, different RTT.

## 6. What to do about it

**The loss is not fixable in software.** The remaining options, cheapest first:

| Option | Cost | Notes |
|---|---|---|
| **Local apt cache on the LAN** (recommended) | free | Put `apt-cacher-ng` on yennefer or ciri. geralt then fetches at **LAN RTT**, where 5% loss is harmless — §5 measured 26–65 MB/s. Also dedupes downloads across both nodes and all guests |
| USB3 Gigabit adapter | ~₹800 | Bypasses `alx` entirely (`r8152`/`ax88179` are solid). The only option that fixes geralt's WAN throughput generally, not just apt |
| Out-of-tree `alx`/`atl1c` driver | free, fiddly | DKMS against PVE kernels; upstream `alx` is a minimal reimplementation and this is a known-weak part |
| Accept it | free | geralt only needs WAN bandwidth during monthly upgrades |

**Keep the §3 and §4 fixes regardless.** They do not solve the symptom, but a
link logging 24,800 correctable errors an hour is degrading unwatched, and PAUSE
frames escalate a one-packet problem into a link-wide stall. Both are made
persistent by
[`scripts/proxmox/nic-pcie-tune.sh`](../scripts/proxmox/nic-pcie-tune.sh) and its
systemd unit — deliberately **not** a GRUB cmdline change, because geralt has a
history of boot hangs from exactly that (see [storage.md](storage.md), the
reverted `usb-storage.quirks` attempt).

## 6a. Fix status (2026-08-24)

| Fix | Applied | Persistent |
|---|---|---|
| ASPM cleared on device + upstream bridge | **Yes, verified** — ~24,800 errors/hour → **0** | **No** — runtime `setpci` only |
| 802.3x flow control disabled | **Yes, verified** — PAUSE frames per transfer 372 → **0** | **No** — runtime `ethtool` only |
| `nic-pcie-tune.service` deployed | **No** | — |
| LAN apt cache | **No — deferred by decision 2026-08-24**, not rejected | — |

> **Both fixes revert on reboot.** They live only in PCI config space and the
> NIC's runtime settings. Until
> [`nic-pcie-tune.service`](../scripts/proxmox/nic-pcie-tune.sh) is installed and
> enabled, every reboot restores ASPM L0s and re-enables pause, and the AER storm
> resumes at ~24,800/hour. Deploying it is three commands and needs no reboot of
> its own — see [scripts/proxmox/README.md](../scripts/proxmox/README.md).

## 6b. Observed consequence for the geralt maintenance pass

geralt's first full maintenance pass (D7, [proposal 006](proposals/006-maintenance-and-upgrades.md))
ran with the NIC in this state: **98 packages, including 31 security updates,
downloaded at roughly 130 kB/s** because the packages come from
`download.proxmox.com` at 172 ms RTT — precisely the path this RCA describes.
The upgrade itself was unaffected; only the download phase was slow.

This is the concrete cost of the defect, and the reason the LAN apt cache in §6
is the mitigation that matters: at LAN RTT the same 5% loss yields 26–65 MB/s,
so the identical download would finish in seconds rather than tens of minutes.
Any future pass on geralt pays this tax until the cache exists.

## 7. Open

- **Local apt cache — deferred 2026-08-24, not rejected.** The recommended
  mitigation, and the only one that removes the download tax without new
  hardware. Every geralt upgrade pays ~130 kB/s until it exists.
- **`nic-pcie-tune.service` — written, not deployed.** Until it is, both fixes
  in §3 and §4 are lost on every reboot (§6a).
- **The 5% drop rate is unexplained at the hardware level.** It is reproducible,
  load-dependent, and independent of CPU, memory, ASPM and flow control. Whether
  it is a silicon limitation, an `alx` descriptor-refill bug, or a failing part
  is untested — a USB3 adapter would settle it in one measurement.
- **Watch the AER counter.** Now that it should read 0, any future growth is a
  genuine signal rather than background noise:
  `grep TOTAL_ERR_COR /sys/bus/pci/devices/0000:05:00.0/aer_dev_correctable`
