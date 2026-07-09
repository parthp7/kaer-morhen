# Monitoring & alerting setup

Monitoring stack for cluster **kaermorhen**, built 2026-07-10.
Design rationale (Beszel vs Grafana/Netdata debate): [Proposal 001 §2](proposals/001-initial-infrastructure-plan.md).
IDs/IPs follow the [network plan](network.md); storage referenced: [storage.md](storage.md).

Two layers, one phone notification channel:

1. **Beszel** — metrics dashboard + threshold alerts (CPU, memory, disk, net,
   temperature, host-down, SMART view, Docker stats later).
2. **Native failure alerting** — the services that *own* each failure report it
   directly: PVE's notification system (backup job failures), `zed` (ZFS pool
   faults), `smartd` (disk pre-failure). A metrics dashboard is the wrong owner
   for these; the natives were already installed and only needed wiring.

Everything delivers to a single **ntfy.sh topic** subscribed on the phone.

## Architecture

| Piece | Where | Detail |
|---|---|---|
| Beszel hub | LXC **102** on geralt (`.102`) | Debian 13, unprivileged, nesting=1, 1 core / 512 MiB, UI `http://<LAN_PREFIX>.102:8090` |
| Beszel agent | both PVE hosts, bare metal | `beszel-agent.service`, binary install, ~15 MiB RAM |
| Alert delivery | **ntfy.sh** public server, secret topic | topic in `secrets.local.yaml` (`NTFY_TOPIC`) and `/etc/ntfy.topic` on each node |
| PVE notifications | webhook target `ntfy`, both nodes | fires on vzdump failures etc. via `default-matcher` |
| zed → ntfy | geralt | native OpenZFS 2.2+ support; pool faults, checksum errors, scrub results |
| smartd → ntfy | both nodes | `-M exec` handler [`scripts/monitoring/smartd-ntfy.sh`](../scripts/monitoring/smartd-ntfy.sh) |
| ZFS scrub | geralt, stock PVE cron | `/etc/cron.d/zfsutils-linux`: scrub 2nd Sunday, TRIM 1st Sunday monthly |

**Why public ntfy.sh, not self-hosted**: alert delivery must live *outside* the
lab's failure domain — a self-hosted ntfy on a dead node delivers nothing. The
topic name is the only credential (anyone who knows it can read/post), so it is
random and treated as a secret.

**Known blind spot**: the hub lives on geralt, so a total geralt failure cannot
alert (yennefer-down *is* alerted — the hub outlives it). Closing this is a
future item: Uptime-Kuma watching geralt from yennefer's band, or an external
heartbeat check (healthchecks.io-style dead-man switch).

## Build runbook

All commands as **root** on the node indicated. As-executed 2026-07-10,
including corrections discovered along the way (called out inline).

### 0. ntfy topic

```bash
# generate once, anywhere
echo "kaermorhen-$(openssl rand -hex 6)"
```

- Record as `NTFY_TOPIC` in `secrets.local.yaml`; it is `<NTFY_TOPIC>` in all
  tracked files.
- Subscribe to the topic in the ntfy phone app.
- Test delivery first: `curl -d "hello" https://ntfy.sh/<NTFY_TOPIC>`

```bash
# BOTH nodes — local copy for services (smartd handler reads this)
echo "<NTFY_TOPIC>" > /etc/ntfy.topic && chmod 600 /etc/ntfy.topic
```

### 1. Beszel hub — LXC 102 (geralt)

```bash
pct create 102 local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst \
  --hostname beszel --unprivileged 1 --features nesting=1 \
  --cores 1 --memory 512 --swap 256 \
  --rootfs silver-guests:4 \
  --net0 name=eth0,bridge=vmbr0,ip=<LAN_PREFIX>.102/24,gw=<LAN_PREFIX>.1 \
  --onboot 1 --start 1

pct exec 102 -- bash -c 'apt update && apt install -y curl'
pct exec 102 -- bash -c 'curl -sL https://get.beszel.dev/hub -o /tmp/install-hub.sh \
  && chmod +x /tmp/install-hub.sh && /tmp/install-hub.sh'
pct exec 102 -- systemctl status beszel-hub --no-pager
```

- **The hub's unit is `beszel-hub.service`** — not `beszel` (as some docs
  suggest) and not `beszel-agent` (that's the host agent's unit).
- No `--auto-update`: the alerting stack updates when we choose (re-run the
  install script).
- Nightly 04:00 `--all 1` backup job covers CT 102 automatically from day one.

Browser → `http://<LAN_PREFIX>.102:8090` → create the admin account (recorded
in `secrets.local.yaml` as `BESZEL_ADMIN_USER` / `BESZEL_ADMIN_PASSWORD`).

### 2. Agents on both PVE hosts (bare metal)

The agent runs directly on each node — that is what sees host temperatures,
ZFS mountpoints, and SMART. In the hub UI, **Add System** (name `geralt`, host
`<LAN_PREFIX>.21`; then `yennefer`, `.22`) — the dialog generates the exact
install command with that hub's key/token:

```bash
# on the node, from the Add System dialog
curl -sL https://get.beszel.dev -o /tmp/install-agent.sh && chmod +x /tmp/install-agent.sh \
  && /tmp/install-agent.sh -k "<BESZEL_PUBKEY>" -t "<BESZEL_TOKEN>"
```

Default connection mode: hub polls agent on port 45876 — fine on the flat LAN.

Teach each agent about the non-root filesystems (default is `/` only):

```bash
systemctl edit beszel-agent
# geralt:    [Service]  Environment="EXTRA_FILESYSTEMS=/silver,/steel"
# yennefer:  [Service]  Environment="EXTRA_FILESYSTEMS=/mnt/backup"
systemctl restart beszel-agent
```

Temperatures (coretemp) and the SMART tab appeared without extra packages —
PVE ships smartmontools; no lm-sensors needed on this hardware.

### 3. Beszel alerts → ntfy

Hub UI → **Settings → Notifications** → add URL (Shoutrrr schema), then Test:

```
ntfy://ntfy.sh/<NTFY_TOPIC>
```

Per-system alert thresholds (bell icon on each system):

| Alert | geralt | yennefer | Rationale |
|---|---|---|---|
| Status (down) | on | on | host-down within ~1 min |
| Temperature | 85 °C / 10 min | 85 °C / 10 min | threshold is global per host → set for the CPU; disk temps are smartd's job |
| Disk usage | 80 % / 30 min | 80 % / 30 min | matches the ZFS ~80 % watchline (storage.md) |
| CPU | 90 % / 20 min | 90 % / 20 min | long window — transcodes/OCR legitimately spike |
| Memory | 90 % / 10 min | 85 % / 10 min | yennefer tighter: 8 GB has no slack |

Beszel alerts are **static thresholds**, not anomaly detection — accepted
trade-off (Proposal 001 §2 debate). The real "sudden failure" cases are owned
by step 4.

### 4. Native failure alerts → same topic

#### 4a. PVE notification system (BOTH nodes — standalone, nothing syncs)

UI path (the config file wants base64-encoded templates — UI is the sane way):
Datacenter → Notifications → **Add → Webhook**:

- Name `ntfy`, URL `https://ntfy.sh/<NTFY_TOPIC>`, Method POST
- Header `Title` = `{{ title }}`, Body `{{ message }}`
- **Test** button → phone.

Then edit `default-matcher` to also target `ntfy` (kept `mail-to-root` too —
harmless, goes nowhere). Covers vzdump job failures, replication, fencing,
package-update notices.

#### 4b. zed → ntfy (geralt — ZFS pool faults)

Native in OpenZFS ≥ 2.2. **The file is `/etc/zfs/zed.d/zed.rc`** (not
`/etc/zfs/zed.rc` as commonly written):

```bash
# /etc/zfs/zed.d/zed.rc — uncomment/set:
#   ZED_NTFY_TOPIC="<NTFY_TOPIC>"
# ZED_NTFY_URL left unset — zed defaults it to https://ntfy.sh
systemctl restart zfs-zed
```

Fires on pool degradation, I/O and checksum errors, and scrub completions.
Scrubs themselves are already scheduled by stock PVE
(`/etc/cron.d/zfsutils-linux`, 2nd Sunday monthly) — so silent bit-rot gets
surfaced at least monthly.

#### 4c. smartd → ntfy (BOTH nodes — disk pre-failure)

Handler script lives in the repo: [`scripts/monitoring/smartd-ntfy.sh`](../scripts/monitoring/smartd-ntfy.sh).

```bash
install -m 0755 smartd-ntfy.sh /usr/local/bin/smartd-ntfy.sh

# /etc/smartd.conf — replace the default DEVICESCAN line with:
#   DEVICESCAN -a -n standby,q -m <nomailer> -M exec /usr/local/bin/smartd-ntfy.sh
systemctl restart smartmontools

# full-chain test: temporarily append " -M test" to that line, restart,
# confirm on phone, revert.
```

- `-a` — health status, failing/prefail attributes, reallocated + pending
  sectors, self-test and ATA error log growth.
- `-n standby,q` — don't spin up sleeping HDDs just to poll them.
- `-m <nomailer>` is literal — required boilerplate when using `-M exec`.
- Limit: attribute 199 (UDMA CRC — geralt's HDD sits at 37) is *not* alerted
  on growth by default; it is visible in Beszel's SMART tab — check when
  curious (the storage.md watchline).

### 5. Verification (read-only)

```bash
# geralt
pct status 102
pct exec 102 -- systemctl is-active beszel-hub
curl -s -o /dev/null -w '%{http_code}\n' http://<LAN_PREFIX>.102:8090   # 200
systemctl is-active beszel-agent zfs-zed smartmontools
systemctl cat beszel-agent | grep EXTRA_FILESYSTEMS
grep -E '^ZED_NTFY' /etc/zfs/zed.d/zed.rc
grep -v '^#' /etc/smartd.conf | grep DEVICESCAN
cat /etc/cron.d/zfsutils-linux            # TRIM 1st Sunday, scrub 2nd Sunday
cat /etc/pve/notifications.cfg           # webhook 'ntfy' + default-matcher

# yennefer (same minus zed/zfs lines)
systemctl is-active beszel-agent smartmontools
systemctl cat beszel-agent | grep EXTRA_FILESYSTEMS
grep -v '^#' /etc/smartd.conf | grep DEVICESCAN
cat /etc/pve/notifications.cfg
```

Verified 2026-07-10: hub running (`beszel-hub.service`, UI 200), agents active
on both hosts with correct `EXTRA_FILESYSTEMS`, zed topic set, smartd handlers
in place (`/etc/ntfy.topic` mode 600 on both), PVE webhook target + matcher on
both nodes, scrub cron present. ntfy delivery confirmed on phone at every
stage (Beszel test, PVE test button, smartd `-M test`).

## Gotchas recap

- Hub systemd unit is **`beszel-hub.service`**; host agents are
  `beszel-agent.service`.
- zed config path is **`/etc/zfs/zed.d/zed.rc`**.
- Beszel's temperature alert threshold is global per host (one value for all
  sensors) — set it for the CPU; disks are smartd's job.
- PVE notification config is per node — standalone nodes need it done twice.
- `-m <nomailer>` must accompany smartd's `-M exec`.
- Agents only watch `/` by default — `EXTRA_FILESYSTEMS` for everything else.

## Next steps (not yet built)

- **geralt-down blind spot**: Uptime-Kuma (or a dead-man heartbeat) running
  *off geralt* — note network.md currently pencils Uptime-Kuma as 103 on
  geralt; reconsider placing it on yennefer instead.
- **Docker stats**: install the agent inside docker VM 150 when it exists —
  per-container metrics appear in the same dashboard.
- **GPU panel**: GTX 1060 monitoring needs nvidia drivers wherever the GPU
  lives; decide after the passthrough choice (host drivers vs VM passthrough
  are mutually exclusive).
- **Grafana + Prometheus** (optional, later): compose stack in VM 150 if
  custom dashboards become wanted; coexists with Beszel, agents stay.
