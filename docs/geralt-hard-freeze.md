# geralt hard freeze — 2026-11-06

geralt (MSI GP63) froze solid at about **07:09 IST on 2026-11-06**, 4 d 6 h into its
first boot on kernel `7.0.14-26-pve`. It stayed powered, with the fans running and the
keyboard backlit, but did not respond to the keyboard and was gone from the LAN. It
logged nothing about the failure. About 53 minutes earlier yennefer's boot SSD had
dropped out for the second time in two days
([storage.md](storage.md) § Incident 2026-11-06), so **both nodes were down at once**
and no alert went out. Found on site around 13:00, rebooted 13:14.

**Root cause: not confirmed.** The leading suspect is the kernel, because it is the one
change shared by both of the day's failures. The procedure to test that is in
[maintenance.md](maintenance.md) § Rollback.

## Timeline (IST)

| When | Event |
|---|---|
| 11-02 00:28:56 | Boot on `7.0.14-26-pve` after the 2026-11-01/02 maintenance pass. The previous boot ran 70 days on `7.0.14-12-pve` without a problem |
| hourly | `_Q9A` ACPI error triplet on the console (see below), last one at **06:08:07** |
| 06:16 → 07:09 | yennefer is dead. geralt keeps running and only logs `pbs-vault: error fetching datastores - 400 Bad Request` every 10 s |
| 07:08:00–07:08:11 | Routine daily ssh from a container into ciri (the same key at the same minute on 11-05). Closed cleanly. Not involved |
| 07:08:11 | ciri's last journal entry |
| 07:09:00 | `media-export-health` pushes OK to Kuma: media disk mounted, NFS exported |
| **07:09:09** | **geralt's last journal entry.** Nothing in it is abnormal |
| ~07:09:11 | The next hourly `_Q9A` event was due. It never reached the console or the journal |
| ~13:00 | On site: screen frozen on the 06:08 ACPI lines, fans running, keyboard backlight on, keys ignored. No ARP entry for geralt from the LAN |
| 13:14:22 | Reboot. All guests came back (ciri 13:15) |

The journal flushes in the background, so the last ~30 s before a freeze can be lost.
The freeze happened somewhere between 07:09:09 and about 07:09:40.

## What the console showed

The photo was transcribed by hand, so some characters are garbled. The lines are the
same three-error triplet, repeating about every 3,665 s:

```
ACPI Error: No handler for Region [VRTC] (...) [SystemCMOS] (20251212/evregion-131)
ACPI Error: Region SystemCMOS (ID=5) has no handler (20251212/exfldio-261)
No Local Variables are initialized for Method [_Q9A]
No Arguments are initialized for method [_Q9A]
ACPI Error: Aborting method \_SB.PCI0.LPCB.EC._Q9A due to previous error (AE_NOT_EXIST) (20251212/psparse-543)
```

`_Q9A` is a query handler of the embedded controller. The firmware's AML reads a CMOS
region (`VRTC`) the kernel has no handler for, and the method aborts. **This is old
noise, not the fault:**

| Boot | Kernel | Span | `_Q9A` aborts | Outcome |
|---|---|---|---|---|
| -2 | `7.0.14-12-pve` | 08-24 → 11-02, 70 days | 1637 | clean |
| -1 | `7.0.14-26-pve` | 11-02 → 11-06, 4.3 days | 100 | **froze** |

Both are about one per hour, and the same three error kinds, with nothing else in
either boot. The freeze landing about 2 s before an event was due is worth noting.
1,737 earlier events passed harmlessly, though, so the timing alone proves nothing.

## What it was not

| Candidate | Ruled out by |
|---|---|
| Thermal shutdown | A thermal trip **cuts power**; geralt stayed on with fans running. Zero throttling or over-threshold lines in the boot |
| Kernel panic | No panic or oops on screen, and nothing in `/sys/fs/pstore` or `/var/lib/systemd/pstore` |
| Hard or soft lockup of a CPU | NMI watchdog was enabled and printed nothing. A single locked CPU would have been reported by the others |
| Machine-check / hardware error | No MCE, APEI or BERT records at the next boot |
| The GPU D3cold wedge ([gpu-passthrough.md](gpu-passthrough.md) § Gotchas) | Same "no panic, empty pstore" signature, but none of its lines (`PGON`, `AE_AML_LOOP_TIMEOUT`, `vfio-pci … not ready after resume`), and that one hits 68–124 s after boot, not 4 days in. `disable_idle_d3` is `Y`, GPU in `D0`, `runtime_suspended_time` 0 |
| The other boot invariants | `usb_storage quirks` `0bc2:ab24:u`, VM 150 `onboot: 1`, empty `GRUB_CMDLINE_LINUX_DEFAULT`, all as expected |
| yennefer's outage | geralt mounts nothing from yennefer. `pbs-vault` is an HTTP storage, and it only produced the 400 errors above |
| The fan / EC tooling | `ec_sys` is loaded **read-only**, and no unit or script on geralt writes EC registers |
| Media disk | `/mnt/media` was healthy at 07:09:00. Its last USB disconnect was 11-05 06:49 and it re-attached by itself |

Everything else stopping while the EC kept fans and backlight going means **the whole
CPU side stopped together**, not one subsystem. The usual causes are a firmware/SMM
hang, a hardware fault, or a kernel bug that stops interrupts on every core.

## Suspects, ranked

1. **Kernel `7.0.14-26-pve`.** It is new on both nodes since 11-01/02, and both nodes
   failed for the first time within four days of it. yennefer's SSD had run 70 days on
   `7.0.14-12` with no errors. A correlation across two machines, not a proof.
2. **Firmware: an EC/ACPI event.** The `_Q9A` timing. It has fired harmlessly about
   1,700 times, so it would need a rare race, and probably something new in the kernel
   to trigger it.
3. **Hardware.** geralt runs hot ([geralt-thermals.md](geralt-thermals.md), repaste
   pending), but no thermal evidence exists for this event.

## Why nothing alerted

Kuma (LXC 103) runs on geralt and watches yennefer. Beszel (LXC 204) runs on yennefer
and watches geralt. The cross-watch design covers **one** node failing. With both
down, the watchers died with the watched, and the alerts would have needed a working
LAN, DNS and WAN path from inside the lab anyway. The lab was down for about 7 hours
and was found only because services stopped working.

## Actions

| Action | Status | Answers |
|---|---|---|
| Reboot geralt | **DONE** 13:14 | the freeze |
| Pin `7.0.14-12-pve` on **both** nodes ([maintenance.md](maintenance.md) § Rollback) | **OPEN** | suspect 1. Run it for 2+ weeks, several times the 4-day gap. A repeat on the old kernel clears the kernel; a clean run plus continued yennefer health convicts it |
| An external "is the lab alive" check: a free hosted uptime monitor or a phone app watching a Tailscale address or a Kuma push from outside | **OPEN** | the silent double failure |
| If it freezes again: photograph the whole screen **before** rebooting, press Caps Lock (does its LED toggle?) and try `Alt+SysRq+S`, `U`, `B` (sync, remount read-only, reboot; `kernel.sysrq = 438` allows them, but not the debug dumps). A response to either means the kernel was still alive, note fan noise and how hot the chassis is | standing | tells a full CPU hang from a dead console |
