# scripts/ops — read-only collectors behind the dashboard's forced-command key

Host-side half of [proposal 008](../../docs/proposals/008-lab-dashboard.md) §6.
OliveTin (in the `homepage` stack on ciri) runs `ssh <host> <word>` with one
dedicated key; on the target that key is bound to `ops-dispatch.sh` as a
forced command, so the *only* thing the key can do is run one of these
scripts, with no arguments. Every script prints exactly one JSON object.

| Script | Installed on | Word | Does |
|---|---|---|---|
| `ops-dispatch.sh` | geralt, yennefer, ciri → `/usr/local/sbin/` | — | matches `SSH_ORIGINAL_COMMAND` against the whitelist, `exec`s the script, refuses everything else (exit 126) |
| `updates-report.sh` | all three → `/usr/local/lib/ops/` | `updates` | `apt-get update` + count of `apt list --upgradable`; on PVE nodes also inside every running LXC via `pct exec` |
| `qbit-move-progress.sh` | ciri only | `qbit-move` | torrents in state `moving` from the qBit API; `du -sb` of the destination vs `total_size` → percent |
| `media-df.sh` | ciri only | `media-df` | `findmnt` must say `nfs4` (autofs = not mounted), then `df` of `/mnt/media` |

Deploy and the `authorized_keys` lines: proposal 008 Phase B2. On ciri the key
runs `sudo -n ops-dispatch.sh "$SSH_ORIGINAL_COMMAND"` (sudo strips the
variable, so the word travels as `$1`); on the PVE nodes the key sits on root
and the dispatcher reads the variable directly. Requirements:
`jq` everywhere (`apt install jq` on ciri), `/etc/ops/qbit.env` (0600) on
ciri for `qbit-move-progress.sh`. All scripts pass `shellcheck`.

**Read-only by design.** `apt-get update` refreshes package lists (the same
step the weekly maintenance pass runs) and nothing else is written anywhere.
