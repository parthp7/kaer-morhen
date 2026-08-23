# Maintenance & upgrade scripts

Three read-mostly scripts that make the recurring maintenance pass cheap enough
to actually happen. Design and rationale:
[docs/proposals/006-maintenance-and-upgrades.md](../../docs/proposals/006-maintenance-and-upgrades.md).
Operating procedure and the version registry:
[docs/maintenance.md](../../docs/maintenance.md).

Unlike everything in `scripts/monitoring/`, these are **not** deployed to a host
and **not** driven by a timer. They run from the laptop, on demand, against the
lab over ssh — which is the whole point: the house policy is that nothing
auto-updates, so the input to an upgrade decision has to be something a human
runs when they sit down to do the work.

| Script | Runs from | Touches state? | Purpose |
|---|---|---|---|
| `lab-inventory.sh` | laptop | **No** — pure reads | What is out of date, everywhere, in one report |
| `lab-smoke.sh` | laptop | **No** — pure reads | Post-upgrade: every proxied service still answers |
| `lab-deep-check.sh` | laptop | No, in the default dry mode | Post-upgrade: the things that *work* still work |

All three exit `0` on success and `1` on failure, so they chain in a runbook.

## `lab-inventory.sh`

```bash
scripts/maintenance/lab-inventory.sh            # report; always exits 0
scripts/maintenance/lab-inventory.sh --strict   # exit 1 if an invariant fails
```

Reports, in order: node PVE/kernel versions and reboot-needed state, pending
package counts with cache age, enterprise-repo state, every LXC, the docker VM's
Docker/Compose/nvidia-ctk versions, container image drift against this repo, and
geralt's six boot-critical invariants.

**It never runs `apt update`.** That rewrites the package lists, and `CLAUDE.md`
forbids state-changing commands over ssh. Refreshing caches is the user's job;
this script's contribution is telling you *which* caches need it.

### The stale-cache trap it exists to defeat

`apt list --upgradable` answers from the **local** cache. A container whose cache
was last refreshed six weeks ago reports zero upgradable packages while being
months behind. A `0` is therefore only meaningful next to the cache date, so the
report always prints both and renders a stale zero as `UNKNOWN (cache 43d
stale)` — never as a clean bill of health.

This is not hypothetical: on the first run (2026-08-23) six of eight LXCs
reported "0 pending" purely because their caches dated from July.

### Env overrides

`REPO_DIR` `NODES` `DOCKER_HOST` `GPU_NODE` `SSH_TIMEOUT` `STALE_DAYS` (default 7).

## `lab-smoke.sh`

```bash
scripts/maintenance/lab-smoke.sh                      # everything
scripts/maintenance/lab-smoke.sh --no-dns             # skip the Pi-hole assertions
scripts/maintenance/lab-smoke.sh --only jellyfin,immich
```

Walks the reverse proxy's own service manifest and separates the three failure
modes that look identical from a browser:

| Layer | Assertion | Catches |
|---|---|---|
| DNS | both Pi-holes answer `<app>.kaermorhen.fyi` with the proxy IP | nebula-sync drift — pihole-1 is authoritative, pihole-2 is overwritten hourly |
| Proxy | TLS handshake completes; wildcard cert days remaining | Caddy down, or a DNS-01 renewal quietly failing |
| Backend | non-5xx through Caddy | a dead app behind a healthy proxy (Caddy answers 502) |
| Containers | nothing exited non-zero or unhealthy | a stack that came back wrong after a restart |

**The manifest is the `Caddyfile` itself**, so a service added to the proxy is
covered here automatically — there is no second list to forget to update.

### Why it addresses the proxy with `curl --resolve`

The PVE nodes deliberately resolve via the router and **cannot resolve
`kaermorhen.fyi` or `kaermorhen.internal` at all**. A hostname-based check
already cost this lab fourteen days of a silently dead heartbeat (see
[`scripts/backup/README.md`](../backup/README.md)). `--resolve` pins the name to
the proxy IP so the HTTP leg works from *any* host regardless of its resolver,
and DNS is then asserted separately and explicitly against both Pi-holes.
Never conflate the two.

### Verdict rule, and why it is deliberately loose

`FAIL` on `000` (no connection / TLS failure) and on any `5xx` — 502/503/504 is
exactly how Caddy reports a dead backend. **Everything else passes**: 200, a 302
to a login, 401, 403 and 308 are all "the app answered". Asserting an exact code
per app would produce a false failure every time an app changed its redirect,
and a check that cries wolf gets ignored. Deep behaviour is the next script's
job.

An `Exited (0)` container is a **WARN**, not a FAIL — it is a one-shot leftover
(a `docker compose run` that lost its `--rm`), not a fault. Grading cruft the
same as a crash trains you to ignore the check.

### Env overrides

`REPO_DIR` `SECRETS_FILE` `LAN_PREFIX` `PROXY_OCTET` `PIHOLE1_OCTET`
`PIHOLE2_OCTET` `DOCKER_HOST` `DOMAIN` `HTTP_TIMEOUT` `CERT_WARN_DAYS` (21).

`LAN_PREFIX` is read from the git-ignored `secrets.local.yaml` and never
hardcoded, per `CLAUDE.md`.

## `lab-deep-check.sh`

```bash
scripts/maintenance/lab-deep-check.sh                 # all but backup
scripts/maintenance/lab-deep-check.sh --only gpu,vpn
scripts/maintenance/lab-deep-check.sh --with-backup   # adds restic check (slow)
scripts/maintenance/lab-deep-check.sh --push          # record real heartbeats
```

`lab-smoke.sh` proves every service *answers*. It cannot prove a service still
*works*: Jellyfin returns 302 just as cheerfully when its GPU encoder has
vanished, and `df` reported 916 G throughout a twelve-day media outage.

This lab already answered that problem by building functional Push monitors that
do real work. Those scripts already share the contract an integration test
needs — **exit 0 healthy, exit 1 failed, verdict on stdout** — so this
orchestrates them rather than reinventing the probes.

| Assertion | Host | Proves |
|---|---|---|
| `gpu` | ciri | a real 1 s `h264_nvenc` encode inside the jellyfin container |
| `media-client` | ciri | `/mnt/media` is `nfs4`, size floor, **O_DIRECT** byte read |
| `media-export` | geralt | `/mnt/media` is ext4, exported, nfsd bound, O_DIRECT read |
| `vpn` | ciri | real egress from inside gluetun's netns, IP ≠ ciri's own |
| `backup` | geralt | `restic check --read-data-subset=10%` (minutes — opt in) |

### The alert-noise trap it defeats — and why dry is the default

Running those scripts by hand pushes a **real** heartbeat to Uptime-Kuma and, on
failure, reddens the monitor and fires ntfy at whatever hour you are testing.
Every one of them guards its push behind a readable token file, so pointing
`KUMA_URL_FILE` at a path that cannot exist makes `push()` print
`cannot read … — not pushing` and return 0, leaving the verdict untouched.

That is the supported test path and it is the **default** here. `--push` opts
back in when you deliberately want the heartbeat recorded.

### Proving an assertion can actually fail

A check that has never been red has not been tested. Each underlying script
ships a documented failure hook; pass it through with `EXTRA_ENV`:

```bash
EXTRA_ENV="MIN_GIB=99999"             scripts/maintenance/lab-deep-check.sh --only media-client
EXTRA_ENV="FORCE_ENCODE_FAIL=1"       scripts/maintenance/lab-deep-check.sh --only gpu
EXTRA_ENV="HOST_IP_OVERRIDE=<vpn_ip>" scripts/maintenance/lab-deep-check.sh --only vpn
```

In the default dry mode these exercise the failure path without pushing a red
heartbeat or waking anyone up. `EXTRA_ENV` is applied through `env VAR=…`
deliberately — a bare `VAR=… cmd` over ssh depends on the remote shell not
resetting the environment and fails silently-wrong when it does.

Exit code `2` from an underlying script means **degraded** (a soft, strike-counted
failure) and is reported as `DEGRADED`, counted as a pass — that is the
scripts' own severity model, not something invented here.

## Traps hit while building these (2026-08-23)

- **`timeout(1)` does not exist on macOS.** The first version of
  `lab-inventory.sh` wrapped every ssh call in `timeout`, so on the laptop every
  remote read failed, `|| true` swallowed the error, and the report confidently
  printed `6 INVARIANTS FAILED` for a lab it had never contacted. Now it prefers
  `timeout`/`gtimeout` when installed and otherwise bounds the session with
  ssh's own `ServerAliveInterval`/`ServerAliveCountMax`.
- **A health check must distinguish *unreachable* from *failed*.** Reporting an
  unread value as `FAIL` is how a monitoring script lies. `check()` prints
  `UNREADABLE` for an empty value, counts it separately, and `--strict` still
  refuses to call it a pass.
- **Positional line parsing of a remote payload is unsafe.** Any remote command
  that emits zero lines instead of one shifts every field after it — the
  invariants section reported grub's cmdline as `VM 150 onboot` and a filesystem
  type as `zfs_arc_max`. All remote payloads are now `key<TAB>value` and are
  addressed by key, which cannot slip.
- **`printf '%s'` without a trailing newline silently drops the last record** of
  a `while read` consumer. This dropped the final LXC of every node (104
  `uptime-kuma`, 204 `beszel`) from the report while it looked perfectly healthy.
- **`pct exec` inside a `while read` loop eats the loop's stdin.** Every `pct`
  call in a remote loop is redirected `</dev/null`.
- **A bare-IP request is not a reachability test for Caddy** — it serves one
  wildcard site and refuses a request whose `Host` it does not recognise, so a
  refusal proves nothing. Reachability is derived from the TLS handshake the
  cert check already performs.

## Conventions

Per `CLAUDE.md`: `#!/usr/bin/env bash`, `set -euo pipefail`, a header comment
block giving purpose / rationale / usage / requirements / env overrides,
`readonly` env-overridable config, and `shellcheck` clean before commit. All
three pass `shellcheck` and `bash -n` with no suppressions except annotated
`SC2016` on remote payloads, where single quotes are intentional so the *remote*
shell expands them.

## As-built (verified 2026-08-23)

| Check | Result |
|---|---|
| `lab-inventory.sh` against the live lab | Reports both nodes, all 8 LXCs, ciri, image drift, 6/6 invariants OK |
| `lab-inventory.sh --strict` with a bad target | Exits 1; fields correctly attributed, no misalignment |
| `lab-smoke.sh` full run | 22 services; 44 assertions; found one genuine 502 (see below) |
| `lab-smoke.sh` exit code | `1` with a real failure, `0` when clean (WARN does not gate) |
| `lab-deep-check.sh` dry, read-only assertions | `media-export` and `media-client` PASS, `— not pushing` confirmed on the wire |
| `lab-deep-check.sh` induced failure | `EXTRA_ENV="MIN_GIB=99999"` → FAIL with a labelled reason, exit 1, no alert |

**First-run findings** (all real, none introduced by the scripts): geralt 98
packages behind yennefer's 2 and on an older `pve-manager` (9.2.4 vs 9.2.11);
six of eight LXC apt caches 6+ weeks stale; `books.kaermorhen.fyi` returning 502
because the proxy routes to an audiobookshelf stack that was never deployed; and
one 6-week-old exited `nebula-sync` one-shot leftover.
