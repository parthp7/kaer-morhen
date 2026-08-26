# Proposal 007 — UPS power protection for the lab

- **Status**: **RESEARCH / NOT PURCHASED.** Evaluation only — no hardware bought,
  nothing deployed. Decision and budget are the user's.
- **Date**: 2026-08-26
- **Scope**: mains protection for the network switch, the two laptop nodes'
  chargers, and headroom for a future mini-PC. Does **not** cover the ISP GPON
  router (see §7), generator/inverter integration, or whole-home backup.
- **Trigger**: not theoretical. See §1 — a power fluctuation caused an 8.7-hour
  outage on 2026-08-25.

---

## 1. Why this exists — the incident that forced it

Mains fluctuation power-cycles the network switch. Both bare-metal nodes lose
link **at the same second**, proving the switch (not a cable or NIC) is the
common cause — `alx` on geralt and `r8169` on yennefer are different chipsets on
different machines:

| geralt `alx` | yennefer `r8169` | down for |
|---|---|---|
| Aug 25 15:00:54 → 15:01:54 | 15:00:54 → 15:01:55 | 60 s |
| Aug 25 21:50:12 → 21:51:35 | 21:50:12 → 21:51:36 | 83 s |
| Aug 25 21:56:16 → 21:56:59 | 21:56:17 → 21:57:00 | 43 s |
| Aug 25 21:58:45 → 21:59:20 | 21:58:46 → 21:59:21 | 35 s |
| Aug 26 12:18:20 → 12:19:18 | 12:18:20 → 12:19:19 | 58 s |
| Aug 26 12:48:24 → 12:48:58 | 12:48:24 → 12:49:00 | 34 s |
| Aug 26 17:49:17 → 17:50:18 | 17:49:18 → 17:50:19 | 61 s |
| Aug 26 17:55:06 → 17:55:48 | 17:55:06 → 17:55:49 | 42 s |

Neither host rebooted (both up 2 days). Outage length 34–83 s is a
reboot-and-renegotiate, not a cable fault.

**What it cost on 2026-08-25**: the 60-second blackout at 15:00:54 failed
gluetun's healthcheck, which tore down the VPN (`HEALTH_RESTART_VPN=on`), hopped
four servers, and hit the one port-forwarding code path that has no retry.
Result: **8.7 hours with no forwarded port and qBittorrent stranded on a
torn-down tunnel**, ending only when the containers were restarted by hand. Full
write-up in [uptime-kuma.md](../uptime-kuma.md) and
[`scripts/monitoring/servarr-vpn-health.sh`](../../scripts/monitoring/servarr-vpn-health.sh).

**A UPS on the switch removes the trigger entirely.** Everything else done since
(the monitor's `exited` classifier, the stranded-client check,
`HEALTH_RESTART_VPN`) is mitigation for a fault that would simply stop happening.

**Second finding, worth recording separately**: ciri showed *nothing* in its logs
during these outages. It is a VM, and the Linux bridge on geralt holds the
guest's virtio link UP when the physical uplink dies — the guest sees silent
packet loss, never a carrier event. **No VM or LXC in this lab can observe this
class of outage.** Only geralt and yennefer can. This is a monitoring blind spot
independent of the UPS decision (§8).

**Not related**: geralt's PCIe/NIC defect
([geralt-nic-throughput.md](../geralt-nic-throughput.md)) has **not** regressed —
`nic-pcie-tune.service` is enabled and active and there have been **0 AER errors**
since 2026-08-25. These link-downs are a different fault with a different cause.

---

## 2. Load sizing

| Device | Typical draw | Notes |
|---|---|---|
| Gigabit switch | 4–8 W | the device that actually matters here |
| geralt charger | ~25 W | laptop, lid-closed server duty |
| yennefer charger | ~25 W | as above |
| **Subtotal today** | **~60 W** | call it 90 W with peaks |
| Future mini-PC | 10–15 W idle, 35–65 W load | proposal 001's likely next node |
| **Future total** | **~100–130 W typical** | ~200 W absolute worst case |

**A 1000 VA / 600 W unit is already generous** — the future load sits at roughly
20 % of capacity, which is also where lead-acid runtime curves are most
favourable. Buying 1500 VA buys runtime, not capability.

**The laptops already have internal batteries.** They ride out a 60-second cut
unaided — they were never what broke on 2026-08-25. This changes the sizing
logic: the load that genuinely needs battery backing is the switch (~8 W) and,
later, the mini-PC. At switch-only load any unit here runs for *hours*.

There is also a mild argument for **not** putting the laptop chargers on battery
outlets: during an outage the UPS battery ends up charging the laptop batteries
through two conversion steps. See §5 for how the recommended unit's socket split
handles this cleanly.

---

## 3. Requirements (as stated) and how they map to specs

| Requirement | What to actually look for |
|---|---|
| Display | LCD showing input V, load W, runtime remaining — not just status LEDs |
| No continuous beeping | Mutable alarm: on-unit Quick Mute **and** permanent disable via software |
| Replaceable battery, cheaper than the UPS | A published **RBC** (Replacement Battery Cartridge) part number, user-swappable, sold retail |
| Good support reviews | India service presence, published response SLA, genuine RBC channel |
| Lasts long, only battery replaced | Line-interactive with AVR — corrects brownouts without cycling the battery |
| Future mini-PC support | Enough watts, and see the waveform trap in §4 |
| 3–4 sockets | India 3-pin 6A sockets; IEC C13 needs adapters (§6) |

**AVR is the underrated one.** It corrects minor voltage swings *without*
switching to battery. Given fluctuating mains, this is what determines whether
the battery gets cycled a dozen times a day or left alone — i.e. whether "only
ever replace the battery" is realistic.

---

## 4. The waveform trap — check this before buying anything

Indian resellers routinely advertise the APC BR series as **"pure sine wave"**.
It is not. Schneider's own datasheets list the BR-G family — BR1000G-IN and
BR1500G-IN included — as **stepped approximation to a sinewave**. One APC partner
store's blog says "pure sine wave" in its prose and "stepped sine wave" in its own
spec table on the same page.

**Does it matter here? Probably not, and this is worth being precise about
rather than dogmatic:**

- Stepped wave is fine for **external power bricks** (SMPS) — the switch, both
  laptop chargers, and the great majority of mini-PCs (Intel NUC, Beelink,
  Minisforum all ship 19 V DC bricks).
- Stepped wave is a real risk for an **internal active-PFC ATX PSU** — a full
  SFF/tower PC or a NAS with an internal supply. Symptoms are buzzing, or the PSU
  dropping out on transfer to battery.

So: if "future homelab" means a mini-PC on a DC brick, the stepped-wave units are
fine and pure sine is a waste of money. If it might mean a proper SFF box with an
internal PSU, buy pure sine now. **This is the single decision that changes the
budget**, roughly ₹15 k versus ₹30 k+.

---

## 5. Candidates

### Recommended — APC Back-UPS Pro **BR1000G-IN**

| | |
|---|---|
| Rating | 1000 VA / **600 W**, 230 V, line-interactive + AVR |
| Sockets | **6 × India 3-pin 6A — 4 battery-backed + 2 surge-only** |
| Display | LCD: input voltage, output watts, minutes remaining |
| Battery | **User-replaceable, hot-swappable**, cartridge **RBC144** (2 × 12 V 9 Ah SMF) |
| Waveform | Stepped approximation (see §4) |
| Comms | USB — works with `apcupsd` and NUT (§8) |
| Warranty | 2 years |
| Price (Aug 2026) | **~₹13,600–16,000** (Amazon.in / Flipkart; verify at purchase) |
| RBC144 price | **~₹3,000–6,500** depending on seller — comfortably under the UPS price ✅ |

**Why this one**: it is the only widely-stocked India-market unit that satisfies
every stated requirement simultaneously — LCD, genuine user-replaceable RBC with
a real retail channel, AVR, native India sockets, USB monitoring, 2-year warranty.

**The 4 + 2 socket split maps onto this lab exactly**: switch + (future) mini-PC +
router on the four battery outlets; the two laptop chargers on the two surge-only
outlets. That gets the laptops surge protection without spending battery runtime
on devices that carry their own.

**Known caveats from owner reports**: battery life is typically **2–3 years** in
Indian conditions (heat and poor mains both shorten it) — one long-term owner
reported 3 years 5 months. Some early-life battery failures are reported, replaced
under warranty without much friction. On battery it beeps 4× every 30 s; that is
mutable. Continuous beeping means low battery and is *deliberately* not mutable.

**Alarm control**: short-press the power button (<2 s) for Quick Mute; disable
permanently via PowerChute (`UPS Settings → Audible Alarm → Disabled`). Battery-
replacement and charger warnings cannot be muted by design.

### If the future is an SFF PC — APC **Smart-UPS SMC1000I-2UC / SMT1000I**

Genuine pure sine wave, better LCD, SmartConnect cloud monitoring, user-
replaceable batteries, 3-year warranty. **Two practical catches**: roughly 2–3× the
price, and these are **IEC C13 outlets**, not India 3-pin — every device needs a
C13 cable or adapter, which is fine for a mini-PC and annoying for laptop bricks.
No reliable India retail price found in this research; sold through distributors,
so expect to request a quote.

### Budget — Vertiv **Liebert ITON CX 1000VA** (~₹4,800–6,000)

Cheap and widely available, but **offline/standby, not line-interactive**,
simulated sine wave, and no meaningful display. Fails the AVR, display, and
"battery only ever replaced" criteria. Listed for completeness; not recommended
against the stated requirements.

### Not recommended — APC **BX** series (BX1100C-IN etc.)

Cheaper sibling of the BR, and the trap to avoid: **battery is not user-
replaceable**, 1-year warranty, simulated wave. When the battery dies you replace
the whole unit — the exact opposite of the stated goal.

---

## 6. Total cost of ownership

Over ~8 years, assuming a battery swap every 3 years:

| | BR1000G-IN | BX1100C-IN |
|---|---|---|
| Unit | ~₹15,000 | ~₹8,000 |
| Battery swaps | 2 × ~₹5,000 = ₹10,000 | not possible — replace unit |
| Units needed | 1 | ~3 |
| **8-year total** | **~₹25,000** | **~₹24,000** |

Roughly equal on money — and the BR wins decisively on everything that isn't
money: AVR, LCD, USB shutdown integration, 2-year warranty, and not re-buying and
re-cabling hardware every three years.

---

## 7. Gap: the ISP GPON router is not in scope

The stated plan covers switch + two laptop chargers. **The ISP GPON router is
not on that list.** Without it on battery, a mains cut still kills WAN — the LAN
and all local services survive, but internet does not.

For the 2026-08-25 incident that is *sufficient*, because what broke was the
**switch** taking down LAN connectivity between ciri, the Pi-holes, and the
gateway. But if the goal is "ride out a power cut", the router belongs on a
battery outlet too. The BR1000G-IN has four; three are spoken for.

---

## 8. Follow-on work this unlocks

1. **`apcupsd` or NUT over USB → graceful shutdown.** Plug the UPS USB into
   geralt, run NUT in server mode, make yennefer a NUT client. Both nodes then
   shut down cleanly on low battery instead of dropping. This is the main reason
   to prefer a UPS with real USB comms over a dumb one, and it fits the existing
   Proxmox setup directly.
2. **Close the link-flap blind spot (§1).** Nothing currently records these
   outages — the two hosts that can see them don't report them, and no guest can
   see them at all. A small Kuma push or journal watch on geralt/yennefer for
   `Link Down` would have identified this root cause in minutes rather than
   across two RCAs.
3. **Revisit `HEALTH_RESTART_VPN`.** With the switch on battery, the spurious
   reconnects should stop; the setting can then be reconsidered on its merits
   rather than as damage control.

---

## 9. Before buying — verify these

- [ ] Current retail price of BR1000G-IN and of RBC144 (prices here are Aug 2026
      and move; the RBC range ₹3,000–7,000 is unusually wide, so shop it)
- [ ] Seller is an authorised APC channel — counterfeit RBCs are a known problem
- [ ] Decide §4: mini-PC on a DC brick (stepped is fine) vs. future SFF box with
      internal PSU (buy pure sine now)
- [ ] Decide §7: does the GPON router go on a battery outlet
- [ ] Confirm measured draw of the actual switch + chargers rather than the
      estimates in §2 — a plug-in power meter settles it in five minutes

---

## Sources

- [Schneider Electric India — BR1000G-IN product page](https://www.se.com/in/en/product/BR1000G-IN/apc-backups-pro-1000va-600w-tower-230v-6x-india-6a-outlets-avr-lcd-user-replaceable-battery/)
- [Schneider Electric India — BR1500G-IN product page](https://www.se.com/in/en/product/BR1500G-IN/apc-backups-pro-1500va-865w-tower-230v-6x-6a-indian-outlets-avr-lcd-user-replaceable-battery)
- [BR1000G-IN datasheet (PDF)](https://download.schneider-electric.com/files?p_EnDocType=Product+Data+Sheet&p_File_Id=0&p_File_Name=BR1000G-IN_DATASHEET_IN_en-GB.pdf&p_Reference=BR1000G-IN_DATASHEET)
- [APC BX vs BR series comparison](https://apc.estorewale.com/blog/apc-bx-vs-br-series-which-back-ups-is-right-for-you/)
- [Pure sine vs stepped/simulated sine wave in India](https://apc.estorewale.com/blog/pure-sine-wave-vs-stepped-simulated-sine-wave-ups-which-do-you-really-need-in-india/)
- [APC RBC144 replacement battery — Amazon.in](https://www.amazon.in/APC-Battery-RBC144-BR1000G-BR1500G/dp/B00OJCD79G)
- [RBC144 pricing — Powerwale](https://www.powerwale.com/store/apc-br1000g-in-1500g-in-rbc144-battery-cartridge-12v-9ah/77049)
- [BR1000G-IN on Amazon.in](https://www.amazon.in/APC-UPS-Model-BR1000G-Battery/dp/B0038ZTZ3W)
- [BR1000G-IN on Flipkart (incl. owner reviews)](https://www.flipkart.com/apc-br1000g-in-ups/p/itme9zndpap3gdw7)
- [Why might my APC Back-UPS be beeping? — Schneider FAQ](https://www.se.com/us/en/faqs/FA158827/)
- [BR1000G-IN / BR1500G-IN installation and operation manual](https://manuals.plus/m/90599e5db2d71ce85794878fae2614c82b7489818ab52a176b972d81cd4f1080)
- [APC India warranty and services](https://apc.com/site/support/in/en/warranty-services)
- [Schneider Electric — SMC1000I-2UC datasheet (PDF)](https://docs.rs-online.com/c125/A700000006917392.pdf)
- [Vertiv Liebert ITON CX 1000VA (simulated sine wave) — Moglix](https://www.moglix.com/vertiv-liebert-iton-cx-1000va-ups-with-2x7ah-battery-526110003000/mp/msne5n821rd0kl)
- [apcupsd / NUT on Proxmox — forum thread](https://forum.proxmox.com/threads/apcupsd-or-nut-proxmox-cluster-shutdown.127030/)
- [Best UPS for homelab and NAS — ComputingForGeeks](https://computingforgeeks.com/best-ups-for-homelab-nas/)
