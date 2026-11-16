# scripts/hardware

| Script | What it does |
|---|---|
| `ssd-burnin.sh` | Unattended, **destructive** burn-in of a SATA SSD from a live system (SystemRescue). It writes a unique stream to every byte, reads it back and compares hashes, runs an optional fio stress test, does a second read, then compares SMART before and after. It ends with PASS/FAIL and, on PASS, a TRIM of the whole drive. Logs go to `/root/burnin/`. Written for the yennefer SSD replacement ([proposal 013](../../docs/proposals/013-yennefer-ssd-replacement.md)). |

## ssd-burnin.sh: how it was run

The live system runs from RAM (SystemRescue `copytoram`), so there's no repo checkout on it.
Copy the script over its built-in sshd:

```bash
# on the live system: set a throwaway root password, note the IP
passwd
ip -br a
# on the Mac
scp scripts/hardware/ssd-burnin.sh root@<LIVE_IP>:
# on the live system console
bash ssd-burnin.sh EVMM2          # substring of /dev/disk/by-id/ata-<model>_<serial>
# afterwards, on the Mac
scp -r root@<LIVE_IP>:/root/burnin <somewhere>/
```

The argument has to match exactly one whole-disk `ata-*` entry. The script refuses
a disk that is mounted or is a WDC, and waits 20 s before writing.
