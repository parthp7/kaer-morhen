# Proposal 007 — UPS power protection for the lab

- **Status**: **DECIDED, NOT YET PURCHASED (2026-08-26).** Model selected —
  **APC Back-UPS Pro BR1000G-IN**, §5 — pending budget; buy when a good price
  appears. Nothing bought, nothing deployed.
- **Date**: 2026-08-26 (revised same day after the requirements were sharpened
  and two candidates were eliminated by hands-on inspection)
- **Scope**: mains protection for the network switch, the two laptop nodes'
  chargers, and headroom for a future mini-PC. The ISP GPON router is **already
  covered** by its own dedicated mini-UPS and is out of scope (§7). Does not cover
  generator/inverter integration or whole-home backup.
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

**Second finding — and its limits.** ciri showed *nothing* in its logs during
these outages. It is a VM, and the Linux bridge on geralt holds the guest's
virtio link UP when the physical uplink dies, so the guest sees silent packet
loss and never a carrier event. No VM or LXC can observe the *carrier* event;
only geralt and yennefer can.

**That is not the same as being blind, and an earlier draft of this doc wrongly
said it was.** Uptime-Kuma catches these loudly, as an unmistakable simultaneous
burst — `pihole2-dns, beszel, pbs, yennefer-ping, router, tailscale-1, sure,
proxy-caddy, proxy-tls` all dropping within the same minute and recovering about
two minutes later. Checked against Kuma's own heartbeat table, **7 of the 8
outages above were caught**, and Kuma additionally recorded a ninth at 18:25 IST
on 2026-08-26 that postdates the kernel log pull.

The one it missed is the useful detail: the 35-second outage on 2026-08-25
21:58:45 fell entirely between beats. The ping monitors run at **60 s intervals**,
the beats at 21:58:35-39 were all up, and the next at 21:59:35-39 were up again.
**Outages shorter than the ping interval can pass unrecorded** — whether that
matters depends on whether a sub-60 s cut is enough to unseat gluetun; the 60 s
one on 2026-08-25 certainly was.

So the residual gap is narrow and is *not* detection:

- Kuma records the **event**, never the **cause**. A simultaneous burst looks
  identical to yennefer dying or to Kuma's own host losing its NIC. What proves
  it is the switch is two machines with two different NIC chipsets logging
  `Link Down` **at the same second**, and that lives only in kernel logs.
- The burst was recognised in real time on every occurrence. What was not made
  was the connection between "power blip, monitors flapped, back in two minutes"
  and "gluetun has silently lost port forwarding for the next 8.7 hours". **That
  is a correlation gap, not a monitoring gap** — and it is why this took two
  RCAs (§8.2).

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

**The laptops already have internal batteries**, and they are healthy enough to
matter. Measured 2026-08-26 from `/sys/class/power_supply/BAT*`:

| Node | Health vs design | Note |
|---|---|---|
| geralt | **64 %** | rides out a 34-83 s cut easily, but visibly aging |
| yennefer | **86 %** | healthy |

Both rode out every outage in §1 unaided — they were never what broke. **The only
device in the rack with zero ride-through is the switch, at ~5-8 W.** On a 600-660 W
unit that is ~1 % load; with both laptop chargers, ~9 %.

**So capacity is not a differentiator between any of the candidates** — every one
of them has runtime to spare at this load. The decision is entirely about
features (§3), which is why the cheapest unit is not automatically the right one.

Track geralt's battery as a related item: it is that node's own built-in
ride-through, and below roughly 40 % of design the wall UPS becomes load-bearing
for geralt too.

There is also a mild argument for **not** putting the laptop chargers on battery
outlets: during an outage the UPS battery ends up charging the laptop batteries
through two conversion steps. See §5 for how the recommended unit's socket split
handles this cleanly.

---

## 3. Requirements (as stated) and how they map to specs

Ranked as they actually bind, hardest first. Budget: **~₹10 k target, ₹13-15 k
available immediately**; beyond that means months of saving.

| # | Requirement | What to actually look for |
|---|---|---|
| 1 | **Battery level on the display** | LCD showing **minutes remaining** — a battery *health* indicator or a bar of LEDs does not satisfy this |
| 2 | **No beeping during an outage** | See below — this one is sharper than it looks |
| 3 | Longevity, 24/7 duty | Line-interactive with **AVR** |
| 4 | 3-4 sockets | India 3-pin 6A; IEC C13 needs adapters (§5) |
| 5 | Replaceable battery | **Soft** — acceptable to replace the whole unit if it is cheap enough |
| 6 | Good support reviews | India service presence, published SLA, genuine RBC channel |

**Requirements 1 and 2 are the same requirement.** The point of seeing minutes
remaining is precisely so the UPS never has to *tell* you anything audibly.

**The beeping requirement implies a USB port.** On every APC unit considered here
the on-battery alarm is mutable **per event** (short press of the power button),
but disabling it **permanently** requires PowerChute over USB. §1 records eight
outages in two days — per-event muting means walking to the UPS eight times. So a
data port is effectively mandatory, not a nice-to-have. This is what eliminated
the cheapest candidate (§5).

**AVR is the underrated one.** It corrects minor voltage swings *without*
switching to battery. Given fluctuating mains, this is what determines whether
the battery gets cycled a dozen times a day or left alone.

### The strategy fork behind requirement 5

A UPS running 24/7 in Indian ambient heat with fluctuating mains will exhaust its
battery in **2-3 years whatever it cost** — that is the dominant failure mode, not
the electronics. So "replaceable battery" is soft only if the plan is to replace
the unit:

- **Buy once, run 8-10 years, swap batteries** → replaceability is not soft, it
  *is* the plan.
- **Buy cheap, replace the whole unit every ~3 years** → replaceability genuinely
  does not matter.

The money barely separates the two strategies — see the 9-year comparison in §6.
**Since TCO is close to a wash, the choice falls entirely to requirements 1-3**,
and that is what §5 decides on.

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

**RESOLVED 2026-08-26 — stepped wave accepted.** The planned future node is a
brick-powered mini-PC, which is the case stepped wave handles without argument.
The pure-sine Smart-UPS options (§5) are therefore out of scope on cost, and the
budget question settles at ~₹13.6 k rather than ₹30 k+. Revisit only if the plan
changes to an SFF/tower machine with an internal active-PFC PSU.

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

**SELECTED 2026-08-26.** It is the only widely-stocked India-market unit that
satisfies every requirement in §3 simultaneously — and, decisively, the only one
of the three candidates that confirms **both** requirement 1 (minutes remaining on
the LCD) and requirement 2 (USB → PowerChute → permanently disabled alarm). The
two cheaper units each fail both. At ₹13,589 it sits at the top of the
immediately-available budget, so purchase waits on a good price rather than on a
decision.

**The 4 + 2 socket split maps onto this lab exactly**: switch + (future) mini-PC
on the battery outlets — two of four used, real headroom — and the two laptop
chargers on the surge-only pair. That gets the laptops surge protection without
spending battery runtime on devices that carry their own (§2). The router needs
no outlet here (§7).

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

### Eliminated — APC **Easy UPS BVX1200LI-IN** (~₹7,850)

Line-interactive, AVR, 6 India sockets, user-replaceable battery, 2 yr UPS / 1 yr
battery — good on paper and the cheapest thing that nearly qualified. **Out on
requirement 1**: it has an **LED status display, not an LCD** — utility/unit
condition lights, no minutes-remaining readout. The BVX line is also known to
alarm continuously on battery with no practical way to silence it, which fails
requirement 2 as well.

### Eliminated — APC **BX1100C-IN** (~₹6,620–7,599)

The tempting one: ₹6 k cheaper than the BR, 1100 VA / 660 W, AVR, and the
listings advertise an LCD. Published sources contradicted each other on both
points that mattered, so it was **checked by hand 2026-08-26**:

- **No USB / data port** on either the front or rear panel. Consistent with the
  SKU's own name — *"without auto shutdown software"* — despite some resellers
  claiming serial + PowerChute support. **Fails requirement 2**: without USB the
  alarm can only be muted per event, and §1 says that would be eight trips to the
  UPS in two days.
- The display is a **battery *health* indicator, not a battery *level* indicator**.
  **Fails requirement 1.**

Recorded in full because the online sources are actively misleading here, and the
next person pricing this will hit the same contradiction.

### Budget — Vertiv **Liebert ITON CX 1000VA** (~₹4,800–6,000)

Cheap and widely available, but **offline/standby, not line-interactive**,
simulated sine wave, and no meaningful display. Fails the AVR, display, and
"battery only ever replaced" criteria. Listed for completeness; not recommended
against the stated requirements.

---

## 6. Total cost of ownership

Over ~9 years, assuming the battery is exhausted every ~3 years either way (§3):

| | BR1000G-IN (swap batteries) | BX1100C-IN (replace unit) |
|---|---|---|
| Unit | ~₹13,600 | ~₹7,000 |
| Battery swaps | 2 × ~₹5,000 = ₹10,000 | — |
| Units needed | 1 | 3 |
| **9-year total** | **~₹23,600** | **~₹21,000** |

**Roughly a wash**, with the cheap-and-replace strategy marginally ahead on money
alone. So money does not decide this — §3 requirements 1-3 do, and there the BR
wins on the two things that were actually verified: a **minutes-remaining**
readout rather than a health indicator, and a **USB port** for permanently
disabling the alarm. Plus USB shutdown integration (§8.1) and not re-buying and
re-cabling hardware every three years.

Two caveats on the BX column, since the sources were unreliable (§5): its battery
is sealed but described as replaceable by some sellers and not by others, and its
warranty is quoted as both 1 and 2 years. If its battery *is* swappable its column
improves — it still fails requirements 1 and 2, which is why it was eliminated on
features rather than on cost.

---

## 7. The ISP GPON router — already covered, and cannot share this UPS

**The router has its own dedicated mini-UPS and stays up through outages.** It
also sits in a different room from the lab, reached over a long LAN run to the
switch, so it could not share this UPS even if it needed to.

The switch and both laptops sit together and currently run from one extension off
a wall socket — a single UPS covers all three.

This closes what would otherwise have been the obvious gap: with the router
independently backed and the laptops carrying their own batteries (§2), the
switch was genuinely the **only** unprotected link in the chain, which is exactly
what §1 shows breaking. Of the BR1000G-IN's four battery outlets, only two are
spoken for (switch, future mini-PC), leaving real headroom.

**Wiring**: run it **wall → UPS → devices**. Do not hang the UPS off the end of
the extension. With six sockets on the unit the extension may become unnecessary
entirely.

---

## 8. Follow-on work this unlocks

1. **`apcupsd` or NUT over USB → graceful shutdown.** Plug the UPS USB into
   geralt, run NUT in server mode, make yennefer a NUT client. Both nodes then
   shut down cleanly on low battery instead of dropping. This is the main reason
   to prefer a UPS with real USB comms over a dumb one, and it fits the existing
   Proxmox setup directly.
2. **Name the cause, don't just detect the event (§1).** Kuma already catches
   these; it cannot say *why*. A small push monitor or journal watch on
   geralt/yennefer for kernel `Link Down` would label the burst "switch
   power-cycled" instead of leaving it as nine unrelated-looking failures, and
   would also catch the sub-60 s outages the 60 s ping interval misses. Lower
   priority than it looked while this was mistaken for a blind spot — the
   detection exists, only the attribution is missing.
3. **Revisit `HEALTH_RESTART_VPN`.** With the switch on battery, the spurious
   reconnects should stop; the setting can then be reconsidered on its merits
   rather than as damage control.

---

## 9. Before buying — what is left

Resolved: §4 (stepped wave accepted), §7 (router already covered), model choice
(§5). Remaining:

- [ ] Watch for a good price on BR1000G-IN — ₹13,589 was the Aug 2026 floor
      against a ~₹16,000 ceiling, so the spread is worth waiting out
- [ ] Seller must be an authorised APC channel — counterfeit RBCs are a known
      problem, and the RBC144 spread (₹3,000–7,000) is wide enough to be a
      warning sign in itself
- [ ] Optional: confirm measured draw of the actual switch + chargers rather than
      the estimates in §2 — a plug-in power meter settles it in five minutes.
      Low priority now that §2 has established capacity is not a differentiator

**On arrival**, before it is load-bearing:
- [ ] Disable the audible alarm permanently via PowerChute over USB — this is the
      whole reason for the model choice, so prove it works
- [ ] Wire wall → UPS → devices (§7)
- [ ] Set up `apcupsd`/NUT (§8.1)

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
