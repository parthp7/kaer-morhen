# Proposal 008 — Lab dashboard: Homepage + OliveTin on ciri, Pulse on yennefer

- **Status**: **DRAFT, execution-ready — designed 2026-09-02, nothing deployed.**
  The runbook is as-planned, not as-executed; "As-built deviations" is empty
  until it runs. Second pass the same day verified every widget schema, the
  OliveTin config keys, the qBit API contract and the pins against upstream
  docs/registries, and ran read-only pre-flight checks on ciri and yennefer
  (§11). What is still *unverified* is listed there too — read §11 before
  Phase B.
- **Date**: 2026-09-02
- **Scope**: one new compose stack `homepage` on **ciri** (Homepage 2.x,
  OliveTin, a Docker socket proxy, a static file server for script results);
  one new LXC **205 `pulse`** on **yennefer**; three Caddy routes + Pi-hole
  records; read-only tokens on PVE, PBS and each app; three Kuma
  monitors; three small host-side scripts on geralt, yennefer and ciri.
  **Nothing here can change anything** — no restarts, no file writes, no
  package installs. §1 records what was dropped and why.
- **Decisions taken up front (2026-09-02)**: Homepage over Homarr (git-tracked
  YAML, §10); Docker container on ciri, not an LXC (§2 — the full impact
  assessment); OliveTin is the *single* script runner for both on-demand
  buttons and timed collectors (§6); progress is shown as a percent figure,
  not a bar (§6); Pulse provides the per-guest Proxmox/PBS view (§7);
  **Homepage's own login gate instead of Caddy basic auth** — the session
  first chose basic auth, then found Homepage 2.0 (released 2026) ships a
  password gate that also covers the port Caddy proxies to, which basic auth
  at Caddy never could. Rationale in §4; reversible in one line if disliked.

Addresses use `<LAN_PREFIX>` per `CLAUDE.md` and the last-octet convention from
[network.md](../network.md). `kaermorhen.fyi` is written in full, as decided
in [proposal 003](003-reverse-proxy.md).

---

## 0. Execution contract (read first if you are the agent running this)

- **The human runs every command that changes state.** The agent's job is to
  hand over exact commands, then verify with read-only checks (`docker ps`,
  `curl`, `pct list`, `journalctl`). Same contract as proposals 005–007.
- **Existing stacks are not touched.** Container status and stats come through
  the socket proxy by *container name* (§5); no labels are added to the other
  ten compose files, so nothing is recreated and nothing restarts.
- **Order matters only across phases**: A (tokens) → B (stack) → C (proxy, DNS,
  Kuma) → D (Pulse) → E (verify) → F (mirror). Inside a phase, steps are
  independent unless a step says otherwise.
- **Rollback** at any point: `docker compose down` in the stack dir removes
  everything on ciri; `pct destroy 205` removes Pulse; revert the Caddyfile
  and `dns.hosts`; revoke the tokens. No other host state is changed except
  the three forced-command SSH keys (§6), which are one line each to remove.
- **Do not skip §4.** The dashboard concentrates every read key in the lab in
  one `.env`. The whole design assumes that file is `chmod 600` and that the
  login gate is on before the Caddy route exists.

## 1. Requirements — kept, softened, dropped

From the 2026-09-02 session. "Flexible on requirements; workarounds accepted."

| Requirement | Verdict | How |
|---|---|---|
| One dashboard, plug-and-play tiles, easy to rearrange | **Kept** | Homepage: groups + tiles in YAML, one file per concern (§5) |
| Docker service stats (status, CPU, memory) | **Kept — hard** | socket proxy → Homepage's Docker integration, per container (§5). Per-container *history* stays in Beszel, already collecting |
| Proxmox node / VM / LXC resource summary, read-only | **Kept** | Homepage `proxmox` tile per node (counts + node CPU/mem); per-guest rows in Pulse (§7) |
| Custom scripts with results on the dashboard, e.g. qBit move progress | **Kept — hard** | OliveTin runs them on a timer and on demand; results land as JSON tiles (§6) |
| Progress *bar* | **Softened** | percent figure + moved/total bytes. Homepage's `customapi` tile renders numbers, not bars |
| Filesystem status: free space and contents | **Softened** | free space yes (`resources` tile for local disks, a script tile for the NFS media share); directory *listing* dropped |
| Upload / rename / move files | **Dropped** | the user marked it soft; nothing in this design has write access anywhere |
| Restart Docker services from the dashboard | **Dropped** | Homepage is read-only by design. Dockge would add it later as its own stack; not in scope |
| Control Proxmox | **Dropped** | user: "just stats are fine" |

## 2. Placement: Docker container on ciri vs LXC — impact assessment

Measured live on 2026-09-02 (read-only): ciri 24 G with ~20 G available and
28 containers in 10 stacks; yennefer 8 G with ~6 G available, five LXCs
capped at 4 G total, load 0.4 on 4 threads; geralt has ~3 G host slack after
ciri's fixed 24 G ([docker-vm.md](../docker-vm.md) memory budget).

| Aspect | Container on ciri | LXC (geralt or yennefer) |
|---|---|---|
| **Docker stats (hard req.)** | socket proxy on a compose-internal network; the socket never leaves the VM, no TCP port opens | needs the Docker API on the LAN: a socket proxy bound to ciri's LAN IP over plain HTTP, or Docker TLS client certs. Every container's env and mounts become readable by anyone on LAN/tailnet |
| **Custom scripts** | the data they read (qBit scratch, NFS media mount, Docker) is on ciri; one SSH hop to localhost | SSH into ciri regardless, or bind the media dataset host-side. Same scripts, one more network path |
| **Memory** | ~250 MB out of RAM already reserved at the host → ecosystem cost zero | geralt: eats the ~3 G slack that feeds ARC + virtiofs cache. yennefer: fits, but every widget poll crosses the switch on an i3 |
| **Failure domain** | dies with geralt/ciri; Beszel + Kuma on yennefer already push that to the phone | survives geralt, but every Docker tile goes red — the same fact Beszel/Kuma already report |
| **Network path** | Docker, qBit, *arr, Jellyfin, Immich, scripts: localhost. Only PVE/PBS/Beszel/Kuma/Pulse tiles cross the LAN | every tile crosses the LAN; proposal 007 recorded switch outages that would show as flapping tiles |
| **Secrets** | `.env` + `.env.example`, the existing convention | a systemd `EnvironmentFile` — a second secrets pattern to document |
| **Access** | published port on ciri (Caddy is on yennefer, so a LAN port is unavoidable either way) + Homepage's own login | same, plus Node install by hand (house rule: no Docker-in-LXC, see [uptime-kuma.md](../uptime-kuma.md)) |
| **Backups / maintenance** | in geralt's nightly `--all` job automatically; update = tag bump in the weekly ciri pass | new guest in the VMID map, the weekly apt loop, and a Kuma-style `git pull && pnpm build` row in [maintenance.md](../maintenance.md) |
| **Repo trackability** | `configs/ciri/homepage/` like every other stack | equal — same YAML, different deploy path |

**Decision: container on ciri.** The LXC wins one axis (surviving geralt) and
that axis is already covered. Everything else is either a wash or favours
ciri, and the hard requirement — Docker stats — is materially safer there.

The one exception goes the other way: **Pulse** lives in an LXC on yennefer
(§7), for the same reason the Beszel hub does — a watcher of geralt should not
sit on geralt.

## 3. Target architecture

```
phone / laptop ──HTTPS──▶ Caddy (LXC 202)  ──▶ home.kaermorhen.fyi     → ciri:3010  Homepage
   (LAN or tailnet)                         ──▶ olivetin.kaermorhen.fyi → ciri:1337  OliveTin
                                            ──▶ pulse.kaermorhen.fyi    → .205:7655 Pulse

ciri (VM 150) — compose stack `homepage`, network homepage_net
  homepage ──▶ socket-proxy ──▶ /var/run/docker.sock (ro, GET /containers only)
  homepage ──▶ results (static-web-server, internal only) ◀── /results/*.json ◀── olivetin
  olivetin ──ssh (forced command)──▶ ciri:   qbit-move | media-df | updates
                                  ──▶ geralt:  updates
                                  ──▶ yennefer: updates
  homepage ──LAN──▶ PVE API ×2, PBS, Beszel hub, Kuma, Pi-hole, app APIs on ciri

yennefer — LXC 205 `pulse` ──▶ PVE API (cluster), PBS API   (read-only tokens)
```

| Piece | Where | Detail |
|---|---|---|
| Homepage | ciri, `ghcr.io/gethomepage/homepage:v2.2.0` | host port **3010** (3000 is Sure's), login gate on, config in `./homepage/*.yaml` |
| Docker socket proxy | ciri, `lscr.io/linuxserver/socket-proxy:3.4.4` | `CONTAINERS=1`, `POST=0`, read-only rootfs, **no published port** |
| OliveTin | ciri, `docker.io/jamesread/olivetin:3000.19.0` + 2 packages (Appendix D) | port 1337 (LAN, for Caddy), local user login, actions = ssh to hosts |
| Results server | ciri, `docker.io/joseluisq/static-web-server:2.44.0` | serves `./results/` on the compose network only |
| Host scripts | geralt, yennefer, ciri — `/usr/local/lib/ops/*.sh` | reached via one forced-command SSH key (§6) |
| Pulse | LXC **205** on yennefer, `.205`, Debian 13 unprivileged, 1 core / 512 MiB | native install (`install.sh --version v6.4.1`), port 7655, auto-update **off** |
| Routes | Caddy LXC 202 | `home`, `olivetin`, `pulse` under `kaermorhen.fyi`; Pi-hole `dns.hosts` → `.202` |
| Monitors | Kuma LXC 104 | HTTP on the three published ports |

Version pins as of 2026-09-02: Homepage **v2.2.0** (released that day — read
its notes; v2.1.x is the fallback if it misbehaves), OliveTin **3000.19.0**
(2026-08-11), socket-proxy **3.4.4**, static-web-server **2.44.0**
(2026-07-31), Pulse **v6.4.1** (2026-08-29).

## 4. Access and secrets

**Why not Caddy basic auth** (the session's first answer). Caddy is in LXC 202
on yennefer, so Homepage *must* publish a port on ciri's LAN IP for Caddy to
reach it — and that port bypasses anything Caddy adds. Basic auth would
protect the pretty URL and leave `<LAN_PREFIX>.150:3010` open to the LAN and
the tailnet. Homepage 2.0 introduced its own gate (`HOMEPAGE_AUTH_ENABLED`,
password or OIDC) which sits in the app itself, so it holds on both paths.
One login, one place. Caddy stays a plain `reverse_proxy` like every other
route.

Two residual notes, both recorded rather than solved:

- Homepage applies **no rate limit** to password attempts (its docs say so;
  failures log as `<nextauth> Failed password sign-in attempt`). The port is
  reachable only from the LAN and the tailnet, both of which are already the
  trust boundary for PVE's own UI. Acceptable here; revisit if the lab ever
  exposes anything publicly.
- `HOMEPAGE_ALLOWED_HOSTS` must list every `Host` the app is reached by:
  `home.kaermorhen.fyi` and `<LAN_PREFIX>.150:3010` (the latter for Kuma and
  for troubleshooting; 3010 because Sure already publishes 3000 on ciri). Wrong Host → "Host not allowed", which is *not* auth.

**OliveTin** has its own local-user login (`authRequireGuestsToLogin: true`,
Appendix D). It can execute things, so it is the more sensitive of the two
UIs — but everything it can execute is a fixed, read-only whitelist (§6).

**Secrets.** All in the stack's `.env` (`chmod 600`, VM only) and referenced
from the YAML as `{{HOMEPAGE_VAR_<NAME>}}`, Homepage's documented
substitution. The tracked `.env.example` carries placeholders. Keys to add to
`secrets.local.yaml`:

| Key | Purpose | Created in |
|---|---|---|
| `HOMEPAGE_AUTH_SECRET` | cookie signing, ≥ 32 random chars | `openssl rand -hex 32` |
| `HOMEPAGE_AUTH_PASSWORD` | the login | your password manager |
| `PVE_HOMEPAGE_TOKEN` | `homepage@pve!dashboard` secret, role PVEAuditor | Phase A1 |
| `PBS_HOMEPAGE_TOKEN` | `homepage@pbs!dashboard` secret, role Audit | Phase A2 |
| `QBIT_USER` / `QBIT_PASSWORD` | qBittorrent WebUI login (already exists) | — |
| `RADARR_API_KEY`, `SONARR_API_KEY`, `PROWLARR_API_KEY`, `BAZARR_API_KEY`, `SEERR_API_KEY` | each app's Settings → General | Phase A4 |
| `JELLYFIN_API_KEY`, `IMMICH_API_KEY`, `PAPERLESS_API_TOKEN` | app-issued keys | Phase A4 |
| `PIHOLE_APP_PASSWORD` | Pi-hole v6 app password (Settings → Web/API) | Phase A4 |
| `OLIVETIN_PASSWORD_HASH` | argon2id hash for OliveTin's local user | Phase B3 |
| `OPS_SSH_KEY` | the forced-command key pair (private half lives only in the stack dir) | Phase B2 |

Every token is **read-only by role**, and each one is revocable on its own
without touching the others.

## 5. What is on the dashboard (tiles → source → credential)

Homepage splits config into `settings.yaml` (theme, layout, groups),
`docker.yaml` (how to reach Docker), `services.yaml` (one entry per tile, in
groups), `widgets.yaml` (the header row), `bookmarks.yaml`. Full files in
Appendix C.

**Why `services.yaml` and not Docker labels.** Homepage can discover tiles
from `homepage.*` labels on containers. That would mean editing ten compose
files and `up -d` on each, recreating 28 containers for a cosmetic gain. The
alternative — `server: ciri` + `container: <name>` per entry — gives the same
status dot and stats with zero changes outside this stack. Labels remain an
option per stack later.

| Group | Tile | Live data | Credential |
|---|---|---|---|
| **Lab** | geralt, yennefer | `proxmox` widget with `node:` set → VMs/LXCs running/total, node CPU, mem | `PVE_HOMEPAGE_TOKEN` (one token, cluster-wide user; each tile points at its own node so one node's death doesn't blank the other) |
| | PBS | `proxmoxbackupserver` → datastore usage, failed tasks | `PBS_HOMEPAGE_TOKEN` |
| | Beszel | **link tile only.** Homepage's `beszel` widget requires a PocketBase *superuser* login (its docs, verified 2026-09-02), i.e. full hub admin rights in the dashboard's `.env`. Not worth it for two numbers; Beszel is one click away and Pulse covers per-guest. Opt in later with `BESZEL_ADMIN_*` + `version: 2` (hub is 0.18.7 ≥ 0.9) if wanted | — |
| | Uptime Kuma | `uptimekuma` → up/down counts, incidents; needs a **status page** (`lab`) to exist in Kuma | none (status page is public within the LAN) |
| | Pulse | link tile + status dot via Kuma | — |
| | Pi-hole ×2 | `pihole` v6 → queries, blocked % | `PIHOLE_APP_PASSWORD` |
| **ciri** | Storage | `resources` info widget: `/host/data` (Docker + stacks), `/host/torrents` (scratch) — bind-mounted read-only. **Not** `/mnt/media`: an absent NFS mount would silently report ciri's root disk (the exact trap the servarr guards exist for), so the media share gets its own script tile below |
| | Media share | `customapi` → `results/media-df.json`: mounted?, size, used, free % | none (internal) |
| | qBit move | `customapi` → `results/qbit-move.json`: torrents moving, current name + %, bytes | none (internal) |
| | Pending updates | `customapi` → `results/updates.json`: total pending, per host, when checked | none (internal) |
| **Media** | Jellyfin | `jellyfin` → streams, library counts | `JELLYFIN_API_KEY` |
| | qBittorrent | `qbittorrent` → down/up rate, leech/seed | `QBIT_*` (reached at `<LAN_PREFIX>.150:8080`, gluetun's published port) |
| | Radarr, Sonarr, Prowlarr, Bazarr | wanted/queued/missing | per-app API key |
| | Seerr | `seerr` type (the old `jellyseerr`/`overseerr` are aliases) → pending/approved requests | `SEERR_API_KEY` |
| **Apps** | Immich | `immich` (`version: 2`) → photos, videos, storage | `IMMICH_API_KEY` |
| | Paperless | `paperlessngx` → docs, inbox | `PAPERLESS_API_TOKEN` |
| | Open WebUI, Ollama, memos, Sure, Obsidian/CouchDB, SearXNG | status dot + container stats only (no widget upstream) | — |
| **Header** | datetime, web search, `resources` CPU/mem of ciri | — | — |

Every tile in **Media** and **Apps** carries `container: <name>` so the
status dot and the CPU/mem stats popover come from the socket proxy.

## 6. Custom scripts — the OliveTin design

**One mechanism for everything: OliveTin runs `ssh <host> <word>`.** The
word is matched by a **forced-command dispatcher** on the target against a
fixed whitelist; there are no arguments, no shell, no other commands. The
same key opens three hosts, each with its own tiny whitelist:

| Host | Whitelist | Runs as |
|---|---|---|
| ciri | `qbit-move`, `media-df`, `updates` | `ciri` → `sudo -n` the dispatcher (one sudoers line, that path only) |
| geralt | `updates` | root (forced command, `restrict`) |
| yennefer | `updates` | root (forced command, `restrict`) |

Why not run the scripts *inside* the OliveTin container with the media and
scratch disks bind-mounted? Because `/mnt/media` is an `x-systemd.automount`
trigger: bind-mounting it into a container either pins the empty trigger dir
or, with the servarr-style guard, makes the container **fail to start when
media is down** — the one moment the dashboard should be up. Running on the
host through SSH sees the real automount, needs no mounts in the container,
and reuses the one channel the updates check needs anyway.

Why a static results directory instead of Homepage calling OliveTin's API?
OliveTin's `StartActionAndWait` returns stdout as a *string*, which a
`customapi` tile cannot parse into fields. So each collector writes a JSON
file atomically (`tmp` + `mv`) to `./results/`, a 5 MB static server offers
it on the compose network, and Homepage reads plain JSON. Buttons in
OliveTin's UI show the same output on demand, with history.

| Action | Trigger | What it does | Output |
|---|---|---|---|
| `qbit-move` | cron every minute | qBit API → torrents in state `moving`; `du -sb` of the destination vs `total_size` | `qbit-move.json`: `moving`, `current` ("name 63%"), `pct`, `items[]` |
| `media-df` | cron every 5 min | `findmnt` type must be `nfs4` (autofs = not mounted), then `df` | `media-df.json`: `mounted`, `size`, `used`, `avail`, `pct` |
| `updates` | button + cron daily 07:30 IST | on each host: `apt-get update`, count `apt list --upgradable`; on PVE nodes also inside every *running* LXC via `pct exec` | `updates.json`: `pending_total`, `hosts[]` with per-guest counts, `updated` |
| `show-updates` | button | `jq .` of the last report, for reading in OliveTin | — |

Honest limits: `updates` counts **apt** packages only — Kuma (npm), Pi-hole
itself, Caddy's plugin and Docker image tags are not apt and stay in
[maintenance.md](../maintenance.md)'s manual rows. `apt-get update` is the
same cache refresh the weekly maintenance pass runs; it installs nothing.
The move-progress figure is `du` of the destination file, which is exact
for qBit's sequential copy; ETA is not attempted.

Scripts: dispatcher + three collectors in [`scripts/ops/`](../../scripts/ops/)
(Appendix E), OliveTin-side wrappers in the stack dir (Appendix D).

## 7. Pulse — the Proxmox/PBS view

Homepage's `proxmox` tile stops at node totals. Pulse (rcourtman) gives the
per-guest table — every VM and LXC with CPU, memory, disk, uptime — plus
storage, **backup status per guest** and PBS datastores, in one page that
embeds or links from Homepage. Community edition is free with 7-day history;
nothing here needs the paid tiers.

- **LXC 205 on yennefer**, functional name `pulse`, Debian 13 unprivileged,
  nesting=1, 1 core / 512 MiB, `local-lvm:4`, `.205`. Same profile as the
  Beszel hub; same placement logic (watch geralt from the stable node).
- **Native install** via the signed `install.sh --version v6.4.1` inside the
  LXC — not the project's own "create an LXC" one-liner, which picks its own
  VMID/template and bypasses the house `pct create`. If the installer refuses
  Debian 13, the fallback is the release tarball + the systemd unit from its
  INSTALL.md (a known Trixie issue exists upstream; check first).
- **Credentials**: Pulse generates a *setup script* per PVE/PBS node that
  creates a privilege-separated user and a custom read-only role (it needs a
  few privileges beyond `PVEAuditor`, e.g. `VM.GuestAgent.Audit` for guest
  disk usage, which is why it doesn't reuse the Homepage token). **Read the
  script before running it on the node.** Because geralt+yennefer are one
  cluster, the PVE user is created once.
- **Auto-update off** (Settings → System → Updates) — house policy; updates go
  in the weekly pass as `install.sh --version <next>`.
- **Notifications off.** PVE already notifies on vzdump failures, `zed` on
  pool faults, Beszel on thresholds. A fourth alert source is noise.
- **No Docker agent.** Beszel's agent on ciri already delivers per-container
  stats; two agents would report the same thing twice.

## 8. Monitoring the monitor, backups, maintenance

| Item | Detail |
|---|---|
| Kuma `home` | HTTP `http://<LAN_PREFIX>.150:3010/` — set *Accepted Status Codes* to `200-299` **and** `300-399` (with the gate on, `/` answers with a redirect to `/login`; Kuma's default accepts 2xx only). Needs the IP:port in `HOMEPAGE_ALLOWED_HOSTS` |
| Kuma `olivetin` | HTTP-Keyword `http://<LAN_PREFIX>.150:1337/` → `OliveTin` |
| Kuma `pulse` | HTTP `http://<LAN_PREFIX>.205:7655/` 2xx–3xx |
| Backups | stack dir (config, results, ssh key) rides in geralt's nightly job with the rest of `/data`. LXC 205 is covered by yennefer's 04:30 job. Pulse's own config (`/etc/pulse/*.enc`) is inside the LXC — recreating from scratch is a 15-minute job anyway |
| [maintenance.md](../maintenance.md) rows to add | `150 ciri`: the `homepage` stack has a **`build:`** (OliveTin + 2 packages) — bump `FROM` and `docker compose build --pull` before `up -d`. `205 pulse`: not apt; `install.sh --version <tag>` |
| [network.md](../network.md) | claim 205 on yennefer; three new names in the `dns.hosts` count |

## 9. Resource budget

| Component | RAM (idle, expected) | Where it comes from |
|---|---|---|
| Homepage | ~150–250 MB | ciri's 24 G, ~20 G free today |
| OliveTin | ~30 MB | same |
| socket-proxy + results server | ~10 MB | same |
| Pulse LXC | ~100–150 MB (cap 512) | yennefer's ~6 G available |

Host-level impact: **zero** on geralt (ciri's memory is fixed), one 512 MiB
*cap* on yennefer. Polling load: Homepage refreshes tiles on view, not
continuously; OliveTin's cron adds one `ssh` + `du` a minute on ciri.

## 10. Alternatives considered

- **Homarr** — closest single tool to "one dashboard with control": GUI tiles,
  Proxmox widget, Docker start/stop/restart. Rejected because its config lives
  in a database, not in files this repo can track; and control was dropped.
- **Grafana + Prometheus (+ pve-exporter, cAdvisor)** — most capable, least
  plug-and-play. Already argued down in [proposal 001 §2](001-initial-infrastructure-plan.md);
  nothing changed.
- **Dockge / Komodo / Portainer** — Docker *control*, not a dashboard. Dockge
  maps 1:1 onto `/data/stacks/` and is the obvious add-on if restarts are ever
  wanted; Komodo is multi-host GitOps and over-scoped for one Docker VM.
- **Cockpit** (+ files, packagekit) — per-host updates, services, files. Knows
  nothing about compose stacks and is host-centric; would need one per node.
- **Netdata / Glances** — deep per-host metrics; Beszel already owns that slot.
- **Homepage in an LXC** — §2.

## 11. Gotchas and pre-flight facts for the executing agent

Read-only checks run 2026-09-02, and the traps found while verifying upstream
docs. Every item here changed something in the runbook or appendices.

**Pre-flight facts (verified live):**

| Fact | Consequence |
|---|---|
| ciri already listens on **3000** (Sure) | Homepage publishes **3010** → Caddy, Kuma, `HOMEPAGE_ALLOWED_HOSTS` all say 3010 |
| ciri: `jq` 1.8.1 and `argon2` are in apt; `ciri` has passwordless sudo, uid 1000, is in `docker`; sshd has `PasswordAuthentication no` | B2/B3 need no extra repos; the forced-command key is the only new auth path |
| yennefer: template `debian-13-standard_13.1-2_amd64.tar.zst` present in `local`; VMID 205 unused; `.205` silent | Phase D's `pct create` line is valid as written |
| Beszel hub is **0.18.7** | ≥ 0.9, so Homepage's widget v2 *would* work — but it needs a superuser login, so it stays a link tile |
| SearXNG has **no published port** (internal to the `ai` stack) | header search uses DuckDuckGo, not SearXNG |
| Docker 29.7.2 on ciri | compose `build:` and `--pull` behave as documented; nothing version-specific |

**Traps (each already handled in the text, listed so nobody "simplifies" them away):**

1. **`sudo` drops `SSH_ORIGINAL_COMMAND`** (`env_reset`). On ciri the word is
   passed as an argument in the forced command, the dispatcher accepts `$1`,
   and the sudoers line lists the three exact argument forms. A bare path in
   sudoers would allow *no* arguments and every call would fail with a
   password prompt (`sudo -n` → "a password is required").
2. **OliveTin cron runs as the pseudo-user `cron`** once ACLs are on. Without
   the `cron` ACL and `acls: [admins, cron]` on the timed actions, the
   dashboard tiles just never populate and nothing logs an error.
3. **OliveTin password hashes are argon2id**, not bcrypt. The docs' recipe is
   in B3. A bcrypt string is silently "wrong password".
4. **OliveTin runs as user `olivetin`** in the image (uid 1000 upstream). The
   ssh dir is mounted at `/home/olivetin/.ssh` and must be `700`/`600`, owned
   by uid 1000. Confirm with `docker compose exec olivetin id` in B4; if the
   uid differs, `chown` the ssh dir to that uid (host-side) — do **not** loosen
   modes, ssh refuses a world-readable key or config.
5. **qBittorrent's API needs a matching `Referer`** (CSRF guard) or it answers
   403/"Forbidden" even with correct credentials. The script sends it. Also:
   qBit bans a client after repeated failed logins — if the tile shows an
   error, check the credentials *once*, don't let cron hammer it (stop the
   OliveTin container while fixing `/etc/ops/qbit.env`).
6. **Homepage's `beszel` widget requires a PocketBase superuser.** Dropped;
   don't re-add it with the hub admin password without noting the trade-off.
7. **Homepage `proxmox` widget + token privsep.** Create the token with
   `--privsep 0` (A1). With privilege separation on, the token has no ACLs of
   its own and the tile shows nothing — the most common failure in Homepage's
   discussions.
8. **`HOMEPAGE_ALLOWED_HOSTS` is a Host-header allow-list, not auth.** Every
   name/IP:port the app is reached by must be listed, or the response is
   "Host not allowed". `HOMEPAGE_EXTERNAL_URL` is the login callback base, so
   logging in via the raw IP may bounce to the FQDN — expected.
9. **Kuma's default accepted codes are 2xx.** With the login gate on, `/`
   redirects → add `300-399` or the monitor is permanently down.
10. **Uptime Kuma widget needs a status page** (`slug: lab`) containing the
    monitors you want counted; there is no other API. Create it in A4.
11. **`/mnt/media` must not be bind-mounted into any dashboard container.**
    It is an automount trigger; a bind either pins the empty dir (wrong "free
    space" = ciri's root disk) or, with a guard, makes the container fail to
    start when media is down. The media tile is a host-side script for this
    reason; the `resources` widget only sees `/data` and `/mnt/torrents`.
12. **Pi-hole `dns.hosts` is replace-not-append** (proposal 003 gotcha). Read
    the current array, resend it whole plus the three new records.
13. **Pulse's installer may hang on the agent bundle** on Debian 13 LXCs; the
    manual tarball path in Phase D is the fallback, not a workaround to skip.
14. **Homepage v2.2.0 is one day old.** If tiles misbehave in a way the config
    doesn't explain, pin `v2.1.2` (the previous release) before debugging YAML.
15. **The Pulse PVE setup script must be read before running** — it creates a
    user + custom role on the cluster. It should use `VM.GuestAgent.*`
    privileges on PVE 9; if it mentions `VM.Monitor`, that is the pre-PVE-9
    variant and the wrong script was generated.

**Still unverified (check at deploy, cheap to fix):**

- OliveTin: that `icon:` accepts an HTML entity like `&#x1F4E6;` (docs show
  named icons and emoji; if it renders literally, use an emoji character).
- OliveTin: the exact uid of user `olivetin` in `3000.19.0` (item 4).
- static-web-server: whether it emits any `Cache-Control` on plain files
  (Homepage fetches server-side each refresh, so a header would only matter
  if a proxy sat between them — none does).
- Homepage `proxmoxbackupserver` widget with a *token* rather than a password
  works per its docs; if it errors, the PBS docs' `user@pbs!token` id in
  `username` is the field to double-check.

---

# RUNBOOK

All commands run by the human. `<...>` are placeholders from
`secrets.local.yaml`. Steps marked *(verify)* are the read-only checks the
agent runs afterwards.

## Phase A — tokens and accounts (no impact on anything running)

### A1. PVE token (once — users are cluster-wide). On **geralt**:

```bash
pveum user add homepage@pve --comment "dashboard, read-only (proposal 008)"
pveum acl modify / --users homepage@pve --roles PVEAuditor
# privsep 0: the token inherits the user's (auditor-only) permissions. With
# privsep 1 the token has NO permissions until ACLs are set on the token itself
# — the classic "Proxmox widget shows nothing" trap in Homepage's discussions.
pveum user token add homepage@pve dashboard --privsep 0
# → record the printed value as PVE_HOMEPAGE_TOKEN. Token id: homepage@pve!dashboard
```

*(verify)* `pveum user token permissions homepage@pve dashboard` shows
`PVEAuditor` on `/`.

### A2. PBS token. On **PBS (pct exec 200 …)**:

```bash
proxmox-backup-manager user create homepage@pbs --comment "dashboard, read-only"
proxmox-backup-manager acl update / Audit --auth-id homepage@pbs
proxmox-backup-manager user generate-token homepage@pbs dashboard
proxmox-backup-manager acl update / Audit --auth-id 'homepage@pbs!dashboard'
# → PBS_HOMEPAGE_TOKEN
```

### A3. Beszel — nothing to do

Dropped: the widget needs a superuser (§5). The tile is a link. If opted in
later, the hub admin login from `secrets.local.yaml` (`BESZEL_ADMIN_*`) is the
credential, with the security trade-off that implies.

### A4. App keys

| App | Where |
|---|---|
| Radarr / Sonarr / Prowlarr / Bazarr | Settings → General → API Key (already exist; copy) |
| Seerr | Settings → General → API Key |
| Jellyfin | Dashboard → API Keys → + (name `homepage`) |
| Immich | Account → API Keys → New (name `homepage`) |
| Paperless | Admin → Auth Tokens → add for a **read-only** user (create `homepage` user with view-only permissions first) |
| Pi-hole | Settings → Web Interface / API → App password (each Pi-hole) |
| Uptime Kuma | Status Pages → New → slug `lab`, add all monitors, save |

### A5. Pi-hole records and Caddy route names

Decide now, used in Phase C: `home`, `olivetin`, `pulse` under `kaermorhen.fyi`.

## Phase B — the stack on ciri

### B1. Directories and files

```bash
sudo -u ciri mkdir -p /data/stacks/homepage/{homepage,olivetin/scripts,olivetin/ssh,results}
cd /data/stacks/homepage
# copy in: compose.yaml (App. A), .env (from .env.example, App. B, chmod 600),
#          homepage/*.yaml (App. C), olivetin/Dockerfile + config.yaml +
#          scripts/*.sh (App. D), olivetin/ssh/config (from config.example)
chmod 600 .env
# Homepage runs as PUID/PGID 1000 (= ciri); results/ is written by OliveTin (user
# olivetin, uid 1000 upstream) and read by the results server — world-readable is fine, it
# holds nothing secret.
chmod 755 results
```

### B2. The ops key + host-side dispatchers

```bash
# on ciri, in the stack dir — a key that exists nowhere else
ssh-keygen -t ed25519 -N '' -C 'homepage-ops (proposal 008)' -f olivetin/ssh/id_ed25519
ssh-keyscan -H <LAN_PREFIX>.21 <LAN_PREFIX>.22 <LAN_PREFIX>.150 > olivetin/ssh/known_hosts
cp olivetin/ssh/config.example olivetin/ssh/config && $EDITOR olivetin/ssh/config   # real addresses
chown -R ciri:ciri olivetin/ssh && chmod 700 olivetin/ssh && chmod 600 olivetin/ssh/*
# → this dir becomes /home/olivetin/.ssh in the container; ssh enforces these modes
```

Install the receiver on each host (scripts from `scripts/ops/`, Appendix E):

```bash
# geralt AND yennefer (as root):
install -d /usr/local/lib/ops
install -m 0755 ops-dispatch.sh /usr/local/sbin/ops-dispatch.sh
install -m 0755 updates-report.sh /usr/local/lib/ops/updates-report.sh
# ONE line in /root/.ssh/authorized_keys — restrict = no pty, no forwarding, no X11.
# The dispatcher reads the requested word from SSH_ORIGINAL_COMMAND:
#   restrict,command="/usr/local/sbin/ops-dispatch.sh" ssh-ed25519 AAAA… homepage-ops (proposal 008)

# ciri (as root via sudo):
install -d /usr/local/lib/ops /etc/ops
install -m 0755 ops-dispatch.sh /usr/local/sbin/ops-dispatch.sh
install -m 0755 updates-report.sh qbit-move-progress.sh media-df.sh /usr/local/lib/ops/
printf 'QBIT_URL=http://<LAN_PREFIX>.150:8080\nQBIT_USER=<QBIT_USER>\nQBIT_PASS=<QBIT_PASSWORD>\n' > /etc/ops/qbit.env
chmod 600 /etc/ops/qbit.env
apt install -y jq
# sudoers: the dispatcher with EXACTLY one of three arguments, nothing else.
# GOTCHA: sudo's env_reset strips SSH_ORIGINAL_COMMAND, so on ciri the word must
# travel as an argument (see the authorized_keys line) — and sudoers matches
# arguments literally, so a bare path here would allow NO arguments at all.
cat > /etc/sudoers.d/ops-dispatch <<'EOF'
ciri ALL=(root) NOPASSWD: /usr/local/sbin/ops-dispatch.sh updates, /usr/local/sbin/ops-dispatch.sh qbit-move, /usr/local/sbin/ops-dispatch.sh media-df
EOF
chmod 440 /etc/sudoers.d/ops-dispatch && visudo -c
# ONE line in /home/ciri/.ssh/authorized_keys. The \"…\" keeps the word a single
# argv, so `updates; id` arrives as one string and is refused by the case match:
#   restrict,command="sudo -n /usr/local/sbin/ops-dispatch.sh \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 AAAA… homepage-ops (proposal 008)
```

*(verify, from ciri as `ciri`)* — the whitelist holds and nothing else runs:

```bash
ssh -i /data/stacks/homepage/olivetin/ssh/id_ed25519 root@<LAN_PREFIX>.21 updates | jq .pending
ssh -i /data/stacks/homepage/olivetin/ssh/id_ed25519 ciri@<LAN_PREFIX>.150 qbit-move | jq .moving
ssh -i /data/stacks/homepage/olivetin/ssh/id_ed25519 root@<LAN_PREFIX>.21 'id; ls /'   # → "refused: id; ls /"
ssh -i /data/stacks/homepage/olivetin/ssh/id_ed25519 ciri@<LAN_PREFIX>.150 'updates; id'  # → refused (sudo denies the argv)
ssh -i /data/stacks/homepage/olivetin/ssh/id_ed25519 ciri@<LAN_PREFIX>.150                # no word → "refused: <none>"
```

### B3. OliveTin password hash

OliveTin local users take an **argon2id** hash (its docs' exact recipe; `argon2`
is in Ubuntu's repos, confirmed available on ciri 2026-09-02):

```bash
sudo apt install -y argon2
echo -n '<OLIVETIN_PASSWORD>' | argon2 "$(openssl rand -base64 16)" -id -t 4 -m 16 -p 6 -l 32 -e
# → a string starting $argon2id$v=19$m=65536,t=4,p=6$… ; paste into olivetin/config.yaml
#   `password:`. Keep the file 600 on the VM; the tracked copy carries <OLIVETIN_PASSWORD_HASH>.
```

### B4. Bring it up

```bash
cd /data/stacks/homepage
docker compose build --pull        # OliveTin + openssh-clients + jq
docker compose up -d
docker compose logs -f --tail=50   # Homepage: "ready"; OliveTin: actions loaded
```

*(verify)*

```bash
curl -sI http://<LAN_PREFIX>.150:3010/ | head -1               # 307 → /login (gate is on)
curl -s -H 'Host: evil' http://<LAN_PREFIX>.150:3010/ | head -c 80   # Host not allowed
docker compose exec olivetin id                                 # uid must be 1000 (= ciri) or the 600 key is unreadable — see §11
docker compose exec olivetin ssh -o BatchMode=yes ciri media-df   # end-to-end over the mounted ~/.ssh
docker compose exec olivetin ls /results                        # three json files after ≤5 min
docker compose exec homepage wget -qO- http://results/qbit-move.json
docker exec homepage-socket-proxy wget -qO- http://localhost:2375/containers/json | head -c 200   # GET ok
docker exec homepage-socket-proxy wget -qO- --post-data='' http://localhost:2375/containers/qbittorrent/restart  # 403 — POST refused
```

Then log in at **`https://home.kaermorhen.fyi`** (after Phase C; before it,
`http://<LAN_PREFIX>.150:3010` works but the login callback may bounce to
`HOMEPAGE_EXTERNAL_URL` — that is expected, not a fault) and check every tile
shows data, not "API error". Fix keys in `.env` and `docker compose up -d` (Homepage
re-reads env only on restart; YAML edits are picked up live).

## Phase C — proxy, DNS, Kuma

### C1. Caddyfile (LXC 202) — Appendix F, then:

```bash
caddy adapt --config /etc/caddy/Caddyfile && set -a && . /etc/caddy/cloudflare.env && set +a \
  && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### C2. Pi-hole records (pihole-1 only; replace-not-append — read first)

```bash
pct exec 101 -- pihole-FTL --config dns.hosts       # current array
pct exec 101 -- pihole-FTL --config dns.hosts '[ …all existing…, "<LAN_PREFIX>.202 home.kaermorhen.fyi", "<LAN_PREFIX>.202 olivetin.kaermorhen.fyi", "<LAN_PREFIX>.202 pulse.kaermorhen.fyi" ]'
# on ciri: force the sync
docker compose -f /data/stacks/nebula-sync/compose.yaml run --rm sync-now
```

### C3. Kuma monitors — three HTTP monitors per §8, ntfy notification on.

*(verify)* `https://home.kaermorhen.fyi` from a phone on the tailnet → login
page → dashboard. `https://olivetin.kaermorhen.fyi` → OliveTin login.

## Phase D — Pulse, LXC 205 on yennefer

```bash
# template present on yennefer's `local` (pveam list local, 2026-09-02); 205 unused; .205 silent to ping
pct create 205 local:vztmpl/debian-13-standard_13.1-2_amd64.tar.zst \
  --hostname pulse --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.205/24,gw=<LAN_PREFIX>.1 \
  --nameserver <LAN_PREFIX>.101 \
  --onboot 1 --start 1
pct exec 205 -- bash -c 'apt update && apt install -y curl ca-certificates'
pct exec 205 -- bash -c 'curl -fsSL https://raw.githubusercontent.com/rcourtman/Pulse/main/install.sh -o /tmp/pulse-install.sh'
pct exec 205 -- less /tmp/pulse-install.sh      # read it — it runs as root
pct exec 205 -- bash /tmp/pulse-install.sh --version v6.4.1
pct exec 205 -- systemctl status pulse --no-pager
```

**If the installer hangs at "Downloading universal agent bundle…"** (an upstream
issue was filed for exactly this on Debian 13 LXCs in late 2025; the installer's
only documented flag is `--version`, there is no skip-agent switch), Ctrl-C and
do the documented manual install instead — same result, no agent bundle:

```bash
pct exec 205 -- bash -c 'cd /tmp && curl -fsSLO https://github.com/rcourtman/Pulse/releases/download/v6.4.1/pulse-v6.4.1-linux-amd64.tar.gz \
  && tar -xzf pulse-v6.4.1-linux-amd64.tar.gz && install -m 0755 bin/pulse /usr/local/bin/pulse && mkdir -p /etc/pulse'
pct exec 205 -- bash -c 'cat > /etc/systemd/system/pulse.service <<EOF
[Unit]
Description=Pulse monitoring
After=network-online.target
Wants=network-online.target

[Service]
Environment=PULSE_DATA_DIR=/etc/pulse
ExecStart=/usr/local/bin/pulse
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now pulse && systemctl status pulse --no-pager'
```
Record which path was used in "As-built deviations" — it decides the upgrade
command in [maintenance.md](../maintenance.md).

Then in the browser at `http://<LAN_PREFIX>.205:7655`:

1. Set the admin password (record as `PULSE_ADMIN_PASSWORD`).
2. **Settings → System → Updates → automatic updates off.**
3. Settings → Nodes → add PVE: choose "setup script", **read it**, run it on
   geralt once (cluster-wide user + custom role), paste the result.
4. Same for PBS (`https://<LAN_PREFIX>.200:8007`).
5. Notifications: leave disabled (§7).

*(verify)* the Nodes page lists geralt + yennefer with every guest, and
Backups shows last night's job. `pct config 205` matches the create line.

## Phase E — verification (the contract tests)

| # | Test | Pass |
|---|---|---|
| E1 | `https://home.kaermorhen.fyi` on LAN and over the tailnet | login → all tiles populated, no "API error" |
| E2 | `http://<LAN_PREFIX>.150:3010/` bypassing Caddy | still asks for the password |
| E3 | Stop the socket proxy: `docker stop homepage-socket-proxy` | status dots go grey, the rest of the page lives; start again |
| E4 | Start a large torrent that completes; watch `qbit-move` | `current` shows name + rising %, `moving` returns to 0 after |
| E5 | On geralt, `systemctl stop nfs-server` for 60 s (from proposal 005 D7) | Media share tile shows `mounted: false`; Homepage and OliveTin **stay up**; back to `true` after start |
| E6 | Press *Refresh package updates* in OliveTin | `updates.json` refreshes within ~1 min; counts match `apt list --upgradable` run by hand on one host |
| E7 | `ssh … root@<LAN_PREFIX>.21 'cat /etc/shadow'` and `ssh … ciri@<LAN_PREFIX>.150 'updates; id'` with the ops key | `refused:` / sudo denial, exit ≠ 0, nothing executed |
| E8 | Kuma: stop the `homepage` container for 2 min | phone ping, then resolved |
| E9 | Pulse: `pct list` on both nodes vs Pulse's guest table | same set, same running state |

## Phase F — as-built mirroring (only after E passes)

- `scp` the live `compose.yaml`, `homepage/*.yaml`, `olivetin/config.yaml`,
  `olivetin/Dockerfile`, `olivetin/scripts/*` into `configs/ciri/homepage/`
  **verbatim** — then mask: `.env` → `.env.example` (placeholders),
  `olivetin/ssh/config` → `config.example`, the argon2id hash in `config.yaml` →
  `<OLIVETIN_PASSWORD_HASH>`. Never copy `olivetin/ssh/id_ed25519*` or
  `known_hosts`.
- `configs/yennefer/proxy/Caddyfile` — the three new matcher blocks.
- `scripts/ops/` — the four host scripts + README (they are already in the
  repo before deploy; confirm the deployed copies are identical).
- [network.md](../network.md): 205 claimed; `dns.hosts` count +3.
- [maintenance.md](../maintenance.md): rows from §8.
- [uptime-kuma.md](../uptime-kuma.md): the three monitors.
- This file: Status → **Built**, plus the "As-built deviations" section.

## As-built deviations

*(empty — nothing deployed yet)*

## Follow-ups (not in scope)

- Dockge as its own stack if restart-from-browser is ever wanted; it would sit
  on the same `home.*` page as a link tile.
- Gluetun tile (public IP / forwarded port) once its control-server auth is
  configured; today the control server is localhost-only inside the netns.
- Rate limiting on `/api/auth/callback/credentials` at Caddy if the dashboard
  ever leaves the LAN/tailnet trust boundary.

---

# Appendix A — `compose.yaml` (→ `ciri:/data/stacks/homepage/`)

```yaml
# homepage — lab dashboard (proposal 008): Homepage + OliveTin + Docker socket
# proxy + a static server for script results. READ-ONLY by construction: the
# socket proxy refuses POST, every API token is an auditor/read role, and
# OliveTin can only run a fixed whitelist over forced-command ssh.
#
# Lab conventions: pinned tags (checked 2026-09-02), container_name everywhere,
# restart: unless-stopped, TZ=Asia/Kolkata, dedicated bridge network, secrets
# only from .env (${VAR:?} fails loudly). NOTE the `build:` on olivetin — bump
# the FROM in olivetin/Dockerfile and `docker compose build --pull` on upgrade.

services:
  # ---- Docker API, GET-only, never published ------------------------------
  socket-proxy:
    image: lscr.io/linuxserver/socket-proxy:3.4.4
    container_name: homepage-socket-proxy
    restart: unless-stopped
    read_only: true
    tmpfs:
      - /run
    environment:
      TZ: Asia/Kolkata
      CONTAINERS: "1"     # /containers/json, /containers/{id}/json, /containers/{id}/stats
      POST: "0"           # no start/stop/restart/exec — anything but GET is 403
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks:
      - homepage_net

  # ---- The dashboard -------------------------------------------------------
  homepage:
    image: ghcr.io/gethomepage/homepage:v2.2.0
    container_name: homepage
    restart: unless-stopped
    depends_on:
      - socket-proxy
    ports:
      - "3010:3000"       # host 3010: Sure already owns 3000 on ciri. Caddy (LXC 202) and Kuma reach it here; gated by HOMEPAGE_AUTH_*
    environment:
      TZ: Asia/Kolkata
      PUID: "1000"
      PGID: "1000"
      HOMEPAGE_ALLOWED_HOSTS: ${HOMEPAGE_ALLOWED_HOSTS:?set in .env}
      # 2.x login gate — covers the published port, not just the Caddy route (§4)
      HOMEPAGE_AUTH_ENABLED: "true"
      HOMEPAGE_AUTH_SECRET: ${HOMEPAGE_AUTH_SECRET:?set in .env}
      HOMEPAGE_AUTH_PASSWORD: ${HOMEPAGE_AUTH_PASSWORD:?set in .env}
      HOMEPAGE_EXTERNAL_URL: https://home.kaermorhen.fyi
      # {{HOMEPAGE_VAR_*}} substitutions used by homepage/*.yaml
      HOMEPAGE_VAR_LAN_PREFIX: ${LAN_PREFIX:?set in .env}
      HOMEPAGE_VAR_PVE_TOKEN: ${PVE_HOMEPAGE_TOKEN:?set in .env}
      HOMEPAGE_VAR_PBS_TOKEN: ${PBS_HOMEPAGE_TOKEN:?set in .env}
      HOMEPAGE_VAR_QBIT_USER: ${QBIT_USER:?set in .env}
      HOMEPAGE_VAR_QBIT_PASSWORD: ${QBIT_PASSWORD:?set in .env}
      HOMEPAGE_VAR_RADARR_KEY: ${RADARR_API_KEY:?set in .env}
      HOMEPAGE_VAR_SONARR_KEY: ${SONARR_API_KEY:?set in .env}
      HOMEPAGE_VAR_PROWLARR_KEY: ${PROWLARR_API_KEY:?set in .env}
      HOMEPAGE_VAR_BAZARR_KEY: ${BAZARR_API_KEY:?set in .env}
      HOMEPAGE_VAR_SEERR_KEY: ${SEERR_API_KEY:?set in .env}
      HOMEPAGE_VAR_JELLYFIN_KEY: ${JELLYFIN_API_KEY:?set in .env}
      HOMEPAGE_VAR_IMMICH_KEY: ${IMMICH_API_KEY:?set in .env}
      HOMEPAGE_VAR_PAPERLESS_TOKEN: ${PAPERLESS_API_TOKEN:?set in .env}
      HOMEPAGE_VAR_PIHOLE_PASSWORD: ${PIHOLE_APP_PASSWORD:?set in .env}
    volumes:
      - ./homepage:/app/config
      # local disks for the `resources` tile — read-only, always present.
      # /mnt/media is deliberately NOT here (§5): an absent NFS mount would show
      # ciri's root disk. The media share has its own script tile.
      - /data:/host/data:ro
      - /mnt/torrents:/host/torrents:ro
    networks:
      - homepage_net

  # ---- Script runner: buttons + cron, everything over forced-command ssh ---
  olivetin:
    build:
      context: ./olivetin
      dockerfile: Dockerfile
    image: kaermorhen/olivetin:3000.19.0     # local tag of the build; base pinned in the Dockerfile
    container_name: olivetin
    restart: unless-stopped
    ports:
      - "1337:1337"       # LAN, for Caddy; OliveTin's own login gate applies
    environment:
      TZ: Asia/Kolkata
    volumes:
      - ./olivetin/config.yaml:/config/config.yaml:ro
      - ./olivetin/scripts:/scripts:ro
      # The image runs as user `olivetin` (uid 1000 upstream — CONFIRM with
      # `docker compose exec olivetin id` in B4; ciri is 1000 on the host, so the
      # 600/700 files below are readable only if the uids match). Mounted at the
      # user's own ~/.ssh so ssh finds config/key/known_hosts without flags.
      - ./olivetin/ssh:/home/olivetin/.ssh:ro
      - ./results:/results
    networks:
      - homepage_net

  # ---- Results for the customapi tiles — internal only ---------------------
  results:
    image: docker.io/joseluisq/static-web-server:2.44.0
    container_name: homepage-results
    restart: unless-stopped
    environment:
      TZ: Asia/Kolkata
      SERVER_PORT: "80"        # documented defaults, stated for clarity
      SERVER_ROOT: /public     # directory listing is off by default
    volumes:
      - ./results:/public:ro
    networks:
      - homepage_net
    # no ports: — reachable as http://results/ from homepage only

networks:
  homepage_net:
    driver: bridge
```

# Appendix B — `.env.example`

```bash
# homepage stack secrets — copy to .env (chmod 600) on ciri, never commit the real one.
# Every ${VAR:?} in compose.yaml MUST be set here or the stack refuses to start.
# All tokens are READ-ONLY roles (proposal 008 §4). Rotate any one independently.

# --- Homepage itself ---
# Hosts the app may be reached by (comma-separated, no spaces). The IP:port is
# for Kuma and for troubleshooting without Caddy.
HOMEPAGE_ALLOWED_HOSTS=home.kaermorhen.fyi,<LAN_PREFIX>.150:3010
# openssl rand -hex 32
HOMEPAGE_AUTH_SECRET=<HOMEPAGE_AUTH_SECRET>
HOMEPAGE_AUTH_PASSWORD=<HOMEPAGE_AUTH_PASSWORD>
# substituted into homepage/*.yaml as {{HOMEPAGE_VAR_LAN_PREFIX}} so the tracked
# YAML never carries an address
LAN_PREFIX=<LAN_PREFIX>

# --- Proxmox / PBS (Phase A1–A2) ---
PVE_HOMEPAGE_TOKEN=<PVE_HOMEPAGE_TOKEN>          # secret of homepage@pve!dashboard (PVEAuditor)
PBS_HOMEPAGE_TOKEN=<PBS_HOMEPAGE_TOKEN>          # secret of homepage@pbs!dashboard (Audit)

# --- App keys (Phase A4) ---
QBIT_USER=<QBIT_USER>
QBIT_PASSWORD=<QBIT_PASSWORD>
RADARR_API_KEY=<RADARR_API_KEY>
SONARR_API_KEY=<SONARR_API_KEY>
PROWLARR_API_KEY=<PROWLARR_API_KEY>
BAZARR_API_KEY=<BAZARR_API_KEY>
SEERR_API_KEY=<SEERR_API_KEY>
JELLYFIN_API_KEY=<JELLYFIN_API_KEY>
IMMICH_API_KEY=<IMMICH_API_KEY>
PAPERLESS_API_TOKEN=<PAPERLESS_API_TOKEN>
PIHOLE_APP_PASSWORD=<PIHOLE_APP_PASSWORD>
```

# Appendix C — Homepage config (`homepage/`)

### C1. `settings.yaml`

```yaml
title: kaer morhen
theme: dark
color: slate
headerStyle: boxed
target: _self
statusStyle: dot
hideVersion: true
layout:
  Lab:   { style: row, columns: 4 }
  ciri:  { style: row, columns: 4 }
  Media: { style: row, columns: 4 }
  Apps:  { style: row, columns: 4 }
```

### C2. `docker.yaml`

```yaml
ciri:
  host: socket-proxy
  port: 2375
```

### C3. `widgets.yaml` (header row)

```yaml
- resources:
    label: ciri
    cpu: true
    memory: true
    uptime: true
- resources:
    label: local disks
    disk:
      - /host/data
      - /host/torrents
- datetime:
    text_size: xl
    format: { dateStyle: short, timeStyle: short, hour12: false }
- search:
    provider: duckduckgo   # SearXNG is internal to the ai stack (no published port)
    target: _blank
```

### C4. `services.yaml` (abridged — one representative entry per widget type;
the full file follows the same shape)

```yaml
- Lab:
    - geralt:
        icon: proxmox.png
        href: https://geralt.kaermorhen.fyi
        widget:
          type: proxmox
          url: https://{{HOMEPAGE_VAR_LAN_PREFIX}}.21:8006
          username: homepage@pve!dashboard
          password: "{{HOMEPAGE_VAR_PVE_TOKEN}}"
          node: geralt
    - yennefer:
        icon: proxmox.png
        href: https://yennefer.kaermorhen.fyi
        widget:
          type: proxmox
          url: https://{{HOMEPAGE_VAR_LAN_PREFIX}}.22:8006
          username: homepage@pve!dashboard
          password: "{{HOMEPAGE_VAR_PVE_TOKEN}}"
          node: yennefer
    - PBS:
        icon: proxmox.png
        href: https://pbs.kaermorhen.fyi
        widget:
          type: proxmoxbackupserver
          url: https://{{HOMEPAGE_VAR_LAN_PREFIX}}.200:8007
          username: homepage@pbs!dashboard
          password: "{{HOMEPAGE_VAR_PBS_TOKEN}}"
    - Beszel:
        icon: beszel.png
        href: https://beszel.kaermorhen.fyi
        siteMonitor: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.204:8090
        # no widget: it needs a hub superuser login (§5)
    - Uptime Kuma:
        icon: uptime-kuma.png
        href: https://kuma.kaermorhen.fyi
        widget:
          type: uptimekuma
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.104:3001
          slug: lab
    - Pulse:
        icon: mdi-pulse
        href: https://pulse.kaermorhen.fyi
        siteMonitor: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.205:7655
    - Pi-hole 1:
        icon: pi-hole.png
        href: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.101/admin
        widget:
          type: pihole
          version: 6
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.101
          key: "{{HOMEPAGE_VAR_PIHOLE_PASSWORD}}"

- ciri:
    - Media share:
        icon: mdi-nas
        widget:
          type: customapi
          url: http://results/media-df.json
          refreshInterval: 60000
          mappings:
            - { field: mounted, label: mounted, format: text }
            - { field: avail,   label: free,    format: bytes }
            - { field: pct,     label: used,    format: percent }
    - qBit move:
        icon: qbittorrent.png
        widget:
          type: customapi
          url: http://results/qbit-move.json
          refreshInterval: 30000
          mappings:
            - { field: moving,  label: moving,  format: number }
            - { field: current, label: current, format: text }
            - { field: pct,     label: done,    format: percent }
    - Pending updates:
        icon: mdi-package-variant
        href: https://olivetin.kaermorhen.fyi
        widget:
          type: customapi
          url: http://results/updates.json
          refreshInterval: 300000
          mappings:
            - { field: pending_total, label: packages, format: number }
            - { field: updated,       label: checked,  format: relativeDate }

- Media:
    - Jellyfin:
        icon: jellyfin.png
        href: https://jellyfin.kaermorhen.fyi
        server: ciri
        container: jellyfin
        widget:
          type: jellyfin
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:8096
          key: "{{HOMEPAGE_VAR_JELLYFIN_KEY}}"
          enableBlocks: true
    - qBittorrent:
        icon: qbittorrent.png
        href: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:8080
        server: ciri
        container: qbittorrent
        widget:
          type: qbittorrent
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:8080   # gluetun's published port
          username: "{{HOMEPAGE_VAR_QBIT_USER}}"
          password: "{{HOMEPAGE_VAR_QBIT_PASSWORD}}"
    - Radarr:
        icon: radarr.png
        href: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:7878
        server: ciri
        container: radarr
        widget:
          type: radarr
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:7878
          key: "{{HOMEPAGE_VAR_RADARR_KEY}}"
    # Sonarr (8989), Prowlarr (9696), Bazarr (6767): same shape, own key
    - Seerr:
        icon: seerr.png
        href: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:5055
        server: ciri
        container: seerr
        widget:
          type: seerr            # `jellyseerr`/`overseerr` are aliases of this now
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:5055
          key: "{{HOMEPAGE_VAR_SEERR_KEY}}"

- Apps:
    - Immich:
        icon: immich.png
        href: https://immich.kaermorhen.fyi
        server: ciri
        container: immich
        widget:
          type: immich
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:2283
          key: "{{HOMEPAGE_VAR_IMMICH_KEY}}"
          version: 2
    - Paperless:
        icon: paperless-ngx.png
        href: https://paperless.kaermorhen.fyi
        server: ciri
        container: paperless
        widget:
          type: paperlessngx
          url: http://{{HOMEPAGE_VAR_LAN_PREFIX}}.150:8000
          key: "{{HOMEPAGE_VAR_PAPERLESS_TOKEN}}"
    - Open WebUI:   { icon: open-webui.png, href: https://chat.kaermorhen.fyi,    server: ciri, container: open-webui }
    - Ollama:       { icon: ollama.png,     href: https://ollama.kaermorhen.fyi,  server: ciri, container: ollama }
    - memos:        { icon: memos.png,      href: https://memos.kaermorhen.fyi,   server: ciri, container: memos }
    - Sure:         { icon: mdi-finance,    href: https://sure.kaermorhen.fyi,    server: ciri, container: sure }
    - Obsidian sync:{ icon: couchdb.png,    href: https://obsidian.kaermorhen.fyi, server: ciri, container: obsidian-couchdb }
```

`server: ciri` + `container: <name>` is what turns on the status dot and the
stats popover through the socket proxy. Names must match `docker ps` exactly.

# Appendix D — OliveTin (`olivetin/`)

### D1. `Dockerfile`

```dockerfile
# OliveTin + the two tools its actions need. Base is Fedora (microdnf).
# Bump the tag here on upgrade, then: docker compose build --pull && up -d
FROM docker.io/jamesread/olivetin:3000.19.0
RUN microdnf install -y openssh-clients jq && microdnf clean all
```

### D2. `config.yaml`

```yaml
# OliveTin — proposal 008. Every action is `ssh <host> <word>`; the word is
# matched by a forced-command dispatcher on the target (scripts/ops/). Nothing
# here can take arguments, and nothing here can write to anything but /results.
listenAddressSingleHTTPFrontend: 0.0.0.0:1337
pageTitle: kaer morhen — ops
logLevel: info

# Login required; one local user. Argon2id hash generated in Phase B3.
authRequireGuestsToLogin: true
authLocalUsers:
  enabled: true
  users:
    - username: ciri
      usergroup: admins
      password: "<OLIVETIN_PASSWORD_HASH>"

# Allow-list model (OliveTin docs "some actions require admin"): everything is
# denied by default, then granted per ACL. GOTCHA: with ACLs on, cron-triggered
# runs execute as the pseudo-user `cron`, which must be granted exec explicitly
# or the timers silently never fire. Each action names the ACLs that apply.
defaultPermissions:
  view: false
  exec: false
  logs: false
accessControlLists:
  - name: admins
    matchUsergroups: [admins]
    permissions: { view: true, exec: true, logs: true }
  - name: cron
    matchUsernames: [cron]
    permissions: { exec: true }

# No execOnStartup: the docs don't say which pseudo-user a startup run uses
# under ACLs, and the one-minute cron makes it unnecessary.
actions:
  - id: qbit-move
    title: qBittorrent move progress
    icon: "&#x1F4E6;"
    shell: /scripts/collect.sh qbit-move ciri
    timeout: 60
    execOnCron:
      - "* * * * *"
    acls: [admins, cron]

  - id: media-df
    title: Media share free space
    icon: "&#x1F4BF;"
    shell: /scripts/collect.sh media-df ciri
    timeout: 30
    execOnCron:
      - "*/5 * * * *"
    acls: [admins, cron]

  - id: updates
    title: Refresh package updates (all hosts)
    icon: "&#x1F504;"
    shell: /scripts/collect-updates.sh geralt yennefer ciri
    timeout: 300
    execOnCron:
      - "30 7 * * *"
    acls: [admins, cron]

  - id: show-updates
    title: Show last updates report
    icon: "&#x1F4CB;"
    shell: jq . /results/updates.json
    timeout: 10
    acls: [admins]
```

### D3. `scripts/collect.sh`

```bash
#!/usr/bin/env bash
# collect.sh — run ONE whitelisted word on ONE host over the ops key and store
# the JSON it returns for Homepage's customapi tiles.
# Usage: collect.sh <word> <host-alias>     (aliases from ~/.ssh/config)
# Writes /results/<word>.json atomically; on failure writes {"error":…} so the
# tile shows the fault instead of a stale number.
set -euo pipefail
word=${1:?word}; host=${2:?host}
out="/results/${word}.json"; tmp="${out}.tmp"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$host" "$word" > "$tmp" 2>/dev/null \
   && jq -e . "$tmp" >/dev/null 2>&1; then
  mv -f "$tmp" "$out"
else
  jq -nc --arg w "$word" --arg h "$host" '{error:true, word:$w, host:$h, updated:(now|todate)}' > "$tmp"
  mv -f "$tmp" "$out"
  echo "collect: $word on $host failed" >&2; exit 1
fi
cat "$out"
```

### D4. `scripts/collect-updates.sh`

```bash
#!/usr/bin/env bash
# collect-updates.sh — `updates` on every host given, merged into one report.
# Usage: collect-updates.sh <host-alias>...
# A host that fails is recorded as {"host":…, "error":true}, not dropped.
set -euo pipefail
[[ $# -ge 1 ]] || { echo "usage: $0 host..." >&2; exit 2; }
out=/results/updates.json; tmp="${out}.tmp"
for h in "$@"; do
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$h" updates 2>/dev/null \
    || jq -nc --arg h "$h" '{host:$h, error:true, pending:0}'
done | jq -s '{updated:(now|todate), pending_total:(map(.pending // 0) | add), hosts:.}' > "$tmp"
mv -f "$tmp" "$out"
jq -r '.hosts[] | "\(.host): \(.pending) pending" + (if .guests then " (" + ([.guests[] | "\(.name)=\(.pending)"] | join(", ")) + ")" else "" end)' "$out"
```

### D5. `ssh/config.example`

```
# → olivetin/ssh/config (untracked; real addresses). Mounted read-only at
# /home/olivetin/.ssh inside the container, so ssh reads it as ~/.ssh/config:
# dir 700, files 600, owned by uid 1000 — ssh refuses a config it considers
# writable by others. Key + known_hosts live beside it (Phase B2), never committed.
Host *
  IdentityFile ~/.ssh/id_ed25519
  UserKnownHostsFile ~/.ssh/known_hosts
  StrictHostKeyChecking yes
  IdentitiesOnly yes

Host geralt
  HostName <LAN_PREFIX>.21
  User root
Host yennefer
  HostName <LAN_PREFIX>.22
  User root
Host ciri
  HostName <LAN_PREFIX>.150
  User ciri
```

# Appendix E — host-side scripts (→ `scripts/ops/` in the repo)

### E1. `ops-dispatch.sh` (→ `/usr/local/sbin/`, 0755, all three hosts)

```bash
#!/usr/bin/env bash
# ops-dispatch.sh — forced-command receiver for the dashboard's ops SSH key
# (proposal 008 §6). Installed as the `command=` of ONE authorized_keys line.
# The requested word arrives EITHER as $1 (ciri: the forced command is
# `sudo -n ops-dispatch.sh "$SSH_ORIGINAL_COMMAND"`, because sudo's env_reset
# drops the variable) OR in SSH_ORIGINAL_COMMAND (PVE nodes: the key sits on
# root, no sudo). It must equal one whitelisted word exactly; anything else —
# extra args, shell metacharacters, an empty request — is refused with exit
# 126. Words map to scripts in /usr/local/lib/ops; a word whose script is
# absent on this host is refused the same way.
set -euo pipefail
LIB=/usr/local/lib/ops
[[ $# -le 1 ]] || { echo "refused: too many arguments" >&2; exit 126; }
word=${1:-${SSH_ORIGINAL_COMMAND:-}}
case "$word" in
  updates)   script="$LIB/updates-report.sh" ;;
  qbit-move) script="$LIB/qbit-move-progress.sh" ;;
  media-df)  script="$LIB/media-df.sh" ;;
  *) echo "refused: ${word:-<none>}" >&2; exit 126 ;;
esac
[[ -x $script ]] || { echo "refused: $word not available here" >&2; exit 126; }
exec "$script"
```

### E2. `updates-report.sh` (→ `/usr/local/lib/ops/`, all three hosts)

```bash
#!/usr/bin/env bash
# updates-report.sh — pending apt upgrades on this host and, on a PVE node,
# inside every RUNNING LXC. Prints ONE JSON object. Read-only apart from
# refreshing apt's lists (the same `apt update` the weekly pass runs); never
# installs anything. Counts apt only — Kuma (npm), Pi-hole, Caddy plugins and
# Docker images are not apt and stay manual (maintenance.md).
# Requires: apt, jq; pct on PVE nodes.
set -euo pipefail

count_upgradable() {   # stdin-free; prints an integer, never fails
  apt-get update -qq >/dev/null 2>&1 || true
  apt list --upgradable 2>/dev/null | grep -c '/' || true
}

host=$(hostname -s)
pending=$(count_upgradable)

if command -v pct >/dev/null 2>&1; then
  guests=$(
    pct list 2>/dev/null | awk 'NR>1 && $2=="running" {print $1}' | while read -r id; do
      name=$(pct config "$id" | awk '/^hostname:/{print $2}')
      n=$(pct exec "$id" -- sh -c 'apt-get update -qq >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c /' 2>/dev/null || true)
      jq -nc --arg id "$id" --arg name "$name" --argjson n "${n:-0}" '{id:$id, name:$name, pending:$n}'
    done | jq -s .
  )
  jq -nc --arg h "$host" --argjson p "$pending" --argjson g "$guests" \
    '{host:$h, pending:$p, guests:$g, checked:(now|todate)}'
else
  jq -nc --arg h "$host" --argjson p "$pending" '{host:$h, pending:$p, checked:(now|todate)}'
fi
```

### E3. `qbit-move-progress.sh` (→ `/usr/local/lib/ops/`, ciri only)

```bash
#!/usr/bin/env bash
# qbit-move-progress.sh — progress of qBittorrent's move-on-completion from the
# NVMe scratch (/mnt/torrents/incomplete) to the media share
# (/mnt/media/downloads/complete), as ONE JSON object. Progress = bytes present
# at the destination vs the torrent's total_size — exact for qBit's sequential
# copy. Read-only: qBit API login + `du`.
# Requires: curl, jq, /etc/ops/qbit.env (QBIT_URL, QBIT_USER, QBIT_PASS; 0600).
# Env overrides: COMPLETE_DIR (host path), QBIT_COMPLETE_PREFIX (path as qBit sees it).
set -euo pipefail
# shellcheck source=/dev/null
. /etc/ops/qbit.env
COMPLETE_DIR=${COMPLETE_DIR:-/mnt/media/downloads/complete}
QBIT_COMPLETE_PREFIX=${QBIT_COMPLETE_PREFIX:-/data/downloads/complete}

# qBit's WebUI API rejects requests whose Referer/Origin doesn't match the Host
# it was reached on (CSRF guard) — send it explicitly on every call.
jar=$(mktemp); trap 'rm -f "$jar"' EXIT
curl -fsS -c "$jar" -H "Referer: $QBIT_URL" \
  --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS" \
  "$QBIT_URL/api/v2/auth/login" >/dev/null
moving=$(curl -fsS -b "$jar" -H "Referer: $QBIT_URL" "$QBIT_URL/api/v2/torrents/info" \
  | jq -r '.[] | select(.state=="moving") | [.name, .total_size, .content_path] | @tsv')

items=$(
  while IFS=$'\t' read -r name total cpath; do
    [[ -n ${name:-} ]] || continue
    if [[ $cpath == "$QBIT_COMPLETE_PREFIX"* ]]; then
      dest="${COMPLETE_DIR}${cpath#"$QBIT_COMPLETE_PREFIX"}"
    else
      dest="$COMPLETE_DIR/$name"
    fi
    done_b=$(du -sb "$dest" 2>/dev/null | cut -f1 || true)
    jq -nc --arg n "$name" --argjson t "${total:-0}" --argjson d "${done_b:-0}" \
      '{name:$n, total:$t, done:$d, pct:(if $t>0 then (($d*100/$t)|floor) else 0 end)}'
  done <<<"$moving" | jq -s .
)

jq -nc --argjson items "$items" '{
  updated: (now|todate),
  moving:  ($items|length),
  current: (if ($items|length)>0 then "\($items[0].name) \($items[0].pct)%" else "idle" end),
  pct:     (if ($items|length)>0 then $items[0].pct else 0 end),
  items:   $items
}'
```

### E4. `media-df.sh` (→ `/usr/local/lib/ops/`, ciri only)

```bash
#!/usr/bin/env bash
# media-df.sh — is the NFS media share REALLY mounted, and how full is it?
# `findmnt` must report nfs4: the path is an automount trigger, so an unmounted
# share shows as `autofs` (or nothing) and df would happily describe the root
# disk instead — the 2026-07-27 trap. Prints ONE JSON object. Read-only.
set -euo pipefail
MEDIA_DIR=${MEDIA_DIR:-/mnt/media}
fstype=$(findmnt -n -o FSTYPE --target "$MEDIA_DIR" 2>/dev/null || true)
if [[ $fstype == nfs4 ]]; then
  read -r size used avail pct < <(df -B1 --output=size,used,avail,pcent "$MEDIA_DIR" | tail -1)
  jq -nc --argjson s "$size" --argjson u "$used" --argjson a "$avail" --argjson p "${pct%\%}" \
    '{mounted:true, size:$s, used:$u, avail:$a, pct:$p, updated:(now|todate)}'
else
  jq -nc --arg t "${fstype:-none}" '{mounted:false, fstype:$t, size:0, used:0, avail:0, pct:0, updated:(now|todate)}'
fi
```

# Appendix F — Caddyfile additions (LXC 202, inside the wildcard block)

```caddyfile
	# proposal 008 — dashboard, script runner, Proxmox view. All three carry
	# their own login; Caddy is a plain proxy here like everywhere else.
	@home host home.kaermorhen.fyi
	handle @home {
		reverse_proxy <LAN_PREFIX>.150:3010
	}

	@olivetin host olivetin.kaermorhen.fyi
	handle @olivetin {
		reverse_proxy <LAN_PREFIX>.150:1337
	}

	@pulse host pulse.kaermorhen.fyi
	handle @pulse {
		reverse_proxy <LAN_PREFIX>.205:7655
	}
```

## Sources

- Homepage: [installation & env vars](https://gethomepage.dev/installation/) (2.x auth gate, `HOMEPAGE_ALLOWED_HOSTS`), [Docker integration](https://gethomepage.dev/configs/docker/), [Proxmox widget](https://gethomepage.dev/widgets/services/proxmox/), [Beszel widget](https://gethomepage.dev/widgets/services/beszel/), [Custom API widget](https://gethomepage.dev/widgets/services/customapi/), [resources widget](https://gethomepage.dev/widgets/info/resources/), [services.yaml](https://gethomepage.dev/configs/services/), [Docker install (PUID/PGID, `HOMEPAGE_VAR_`)](https://gethomepage.dev/installation/docker/), [Seerr widget](https://gethomepage.dev/widgets/services/seerr/), [Uptime Kuma widget](https://gethomepage.dev/widgets/services/uptime-kuma/), [Pi-hole widget](https://gethomepage.dev/widgets/services/pihole/), [PBS widget](https://gethomepage.dev/widgets/services/proxmoxbackupserver/), [Immich widget](https://gethomepage.dev/widgets/services/immich/), [releases](https://github.com/gethomepage/homepage/releases), [Proxmox token privsep discussion](https://github.com/gethomepage/homepage/discussions/2902)
- OliveTin: [site](https://www.olivetin.app/), [local users (argon2id)](https://docs.olivetin.app/security/local.html), [ACLs](https://docs.olivetin.app/security/acl.html), [admin-actions example](https://docs.olivetin.app/security/example_some_admin_actions.html), [cron trigger + `cron` user](https://docs.olivetin.app/action_execution/oncron.html), [ssh from the container](https://docs.olivetin.app/action_examples/ssh-manual.html), [StartActionAndWait](https://docs.olivetin.app/api/method_StartActionAndWait.html), [packages in the container](https://docs.olivetin.app/reference/containerInstallPackages.html), [releases](https://github.com/OliveTin/OliveTin/releases)
- Pulse: [repository](https://github.com/rcourtman/pulse), [INSTALL.md](https://github.com/rcourtman/Pulse/blob/main/docs/INSTALL.md), [CONFIGURATION.md](https://github.com/rcourtman/Pulse/blob/main/docs/CONFIGURATION.md), [TROUBLESHOOTING.md (PVE privileges, custom role)](https://github.com/rcourtman/Pulse/blob/main/docs/TROUBLESHOOTING.md), [Debian 13 installer hang (#910)](https://github.com/rcourtman/Pulse/issues/910)
- qBittorrent: [WebUI API 5.0 (states, `content_path`, Referer rule)](https://github.com/qbittorrent/qBittorrent/wiki/WebUI-API-(qBittorrent-5.0))
- Socket proxy: [linuxserver/socket-proxy](https://docs.linuxserver.io/images/docker-socket-proxy/)
- Alternatives: [Homarr Docker integration](https://homarr.dev/docs/integrations/docker/), [Komodo vs Portainer vs Dockge (2026)](https://botmonster.com/self-hosting/komodo-vs-portainer-vs-dockge-2026-homelab-decision-guide/)
