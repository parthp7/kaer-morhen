# ciri services map

Every service on **ciri** (Docker VM 150 on geralt): how it connects, and which
Uptime Kuma check watches it. This is a sharing and presenting overview. The
as-built detail lives in [docker-vm.md](docker-vm.md), each stack's README
under [`configs/ciri/`](../configs/ciri/), and [uptime-kuma.md](uptime-kuma.md).

Nothing on ciri is exposed to the internet:
- **On the LAN**, Caddy serves HTTPS names (`*.kaermorhen.fyi`) with one wildcard certificate.
- **Away from home**, Tailscale routes into the LAN.

IPs, keys, push URLs and credentials are left out on purpose.

Monitor roster as of **2026-11-10**, read from Kuma's live `lab` status page:
**40 monitors in 5 groups**.

**Kuma badges used below**

| Badge | Meaning |
|---|---|
| ✅ `HTTP` / `KW` / `PING` / `DNS` / `TLS` | polled by Kuma (KW = keyword must appear in the page) |
| 🟣 `PUSH` | functional heartbeat sent by a script (tests real behaviour, not just "is it up") |
| ⚠️ `NONE` | not monitored, a gap |
| ➖ `N/A` | nothing to check (no port, batch job) |

**Contents**
1. [Overview](#1-overview)
2. [Media: request → download → stream](#2-media-request--download--stream)
3. [Reading: manga and books](#3-reading-manga-and-books)
4. [Personal apps](#4-personal-apps)
5. [AI](#5-ai)
6. [Dashboard and DNS sync](#6-dashboard-and-dns-sync)
7. [Monitoring](#7-monitoring)

---

## 1. Overview

```mermaid
flowchart LR
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef vpn fill:#e6f4ef,stroke:#0f8a6a,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  lan["Home devices"] --> caddy
  remote["Phone / laptop<br/>away from home"] --> ts["Tailscale subnet router<br/>primary + standby · ✅ PING"]:::access
  ts -->|subnet route| caddy["Caddy reverse proxy<br/>wildcard TLS · ✅ PING ✅ TLS"]:::access
  dns["Pi-hole pair<br/>*.kaermorhen.fyi → Caddy · ✅ DNS"]:::access --> caddy
  kuma["Uptime Kuma<br/>40 monitors → ntfy"]:::mon

  subgraph ciri["ciri · Docker VM · 15 stacks"]
    direction TB
    media["Media<br/>servarr · jellyfin<br/>✅ ×8 🟣 PUSH×3"]
    reading["Reading<br/>manga · books<br/>✅ HTTP×3"]
    personal["Personal apps<br/>immich · paperless · sure · n8n<br/>vaultwarden · memos · shrink<br/>✅ HTTP×8 🟣 PUSH"]
    gaps["Not monitored<br/>ai stack · obsidian-sync<br/>⚠️ NONE"]
    ops["Dashboard & DNS<br/>homepage · nebula-sync<br/>✅ HTTP ✅ KW"]
  end

  caddy -->|HTTPS| ciri
  kuma -.->|checks| ciri

  media --> nfs["geralt USB HDD<br/>NFS media · 🟣 PUSH×2"]
  personal --> photos["geralt photos<br/>virtiofs · 🟣 PUSH"]
  ciri --> disks["ciri local disks<br/>apps, DBs, scratch, models"]
  media --> gpu["GTX 1060<br/>Jellyfin + Ollama · 🟣 PUSH"]
  gaps --> gpu
  media --> proton["Proton VPN<br/>torrent + manga tunnels"]:::vpn
  reading --> proton
```

| Stack | What it does | Kuma |
|---|---|---|
| [servarr](../configs/ciri/servarr/README.md) | Seerr, Sonarr, Radarr, Prowlarr, Bazarr, FlareSolverr, and qBittorrent behind gluetun | ✅ HTTP×7, 🟣 VPN health |
| [jellyfin](../configs/ciri/jellyfin/README.md) | Media server, NVENC on the GTX 1060, library read-only | ✅ HTTP, 🟣 GPU health |
| [manga](../configs/ciri/manga/README.md) | Suwayomi (in its own Secure Core tunnel) and the Komga reader | ✅ HTTP×2 |
| [books](../configs/ciri/books/README.md) | Kavita ebook reader | ✅ HTTP |
| [immich](../configs/ciri/immich/README.md) | Photos, ML (CPU), valkey, postgres | ✅ HTTP |
| [paperless](../configs/ciri/paperless/README.md) | Documents with OCR, postgres, redis, daily dump | ✅ HTTP |
| [sure](../configs/ciri/sure/README.md) | Personal finance: web, worker, postgres, redis, daily dump | ✅ HTTP (via Caddy) |
| [n8n](../configs/ciri/n8n/README.md) | Workflow engine for the bank SMS → Sure pipeline | ✅ HTTP, 🟣 ingest push |
| [vaultwarden](../configs/ciri/vaultwarden/README.md) | Password manager | ✅ HTTP |
| [memos](../configs/ciri/memos/README.md) | Quick notes | ✅ HTTP |
| [obsidian-sync](../configs/ciri/obsidian-sync/README.md) | CouchDB for Obsidian LiveSync | ⚠️ none |
| [shrink](../configs/ciri/shrink/README.md) | Stirling-PDF and Mazanoke | ✅ HTTP×2 |
| [ai](../configs/ciri/ai/README.md) | Ollama, Open WebUI, SearXNG | ⚠️ none (GPU push only) |
| [homepage](../configs/ciri/homepage/README.md) | Homepage dashboard, OliveTin, Docker socket proxy | ✅ HTTP, ✅ KW |
| [nebula-sync](../configs/ciri/nebula-sync/README.md) | Mirrors pihole-1 to pihole-2 every hour | ➖ by design |

---

## 2. Media: request → download → stream

```mermaid
flowchart TB
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef vpn fill:#e6f4ef,stroke:#0f8a6a,color:#1d1d1f
  classDef net fill:#fbf1e4,stroke:#9a5b13,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  browser["Home browser"] --> caddy["Caddy<br/>✅ PING ✅ TLS"]:::access
  ts["Tailscale"]:::access
  phone["Phone / laptop"] --> ts
  ts --> caddy
  tv["Samsung TV<br/>Jellyfin Tizen"] -->|by IP| jellyfin
  caddy -->|requests.*| seerr
  caddy -->|jellyfin.*| jellyfin

  subgraph ciri["ciri · servarr + jellyfin"]
    seerr["Seerr<br/>✅ KW"] --> sonarr["Sonarr · TV<br/>✅ KW"]
    seerr --> radarr["Radarr · Movies<br/>✅ KW"]
    prowlarr["Prowlarr<br/>✅ KW"] -->|search| sonarr
    prowlarr -->|search| radarr
    prowlarr --> flare["FlareSolverr<br/>✅ KW"]
    sonarr -->|API| bazarr["Bazarr · subtitles<br/>✅ KW"]
    jellyfin["Jellyfin · NVENC<br/>✅ HTTP 🟣 PUSH"]
    scratch["NVMe scratch<br/>in-flight downloads"]

    subgraph gluetun["gluetun · kill-switch · 🟣 VPN health"]
      qbit["qBittorrent<br/>✅ HTTP"]
      psync["qbit-port-sync<br/>copies forwarded port"] -->|port| qbit
    end
  end

  sonarr -->|grab| qbit
  radarr -->|grab| qbit
  prowlarr -->|tracker search, outside VPN| indexers["Indexers"]:::net
  flare --> indexers
  proton["Proton VPN<br/>P2P + port forwarding"]:::vpn
  swarm["Torrent swarm<br/>sees VPN IP only"]:::net
  qbit ==>|WireGuard| proton
  proton ==> swarm
  qbit --> scratch

  subgraph geralt["geralt · NFS media · 🟣 PUSH×2"]
    complete["downloads/complete"]
    library["library/ movies · tv"]
  end

  scratch -->|on completion| complete
  complete -->|hardlink import, 0 bytes copied| library
  bazarr -->|.srt| library
  library -->|read-only| jellyfin

  kuma["Uptime Kuma"]:::mon -.->|VPN health| gluetun
  style gluetun fill:#e6f4ef,stroke:#0f8a6a
```

- **Kill-switch:** qBittorrent has no network of its own, only gluetun's. When the tunnel is down there is no route out, so traffic can't fall back to the home IP.
- **Rotating port:** Proton changes the forwarded port. Every 30 s, qbit-port-sync copies it into qBittorrent and never writes 0.
- **Hardlink contract:** `downloads/` and `library/` share one filesystem, so an import is an instant link with no copy.
- **Missing-mount guard:** if the NFS media share is missing, the media containers refuse to start. They never write to the VM's own disk instead.
- **VPN health check:** it makes a real request from inside the tunnel. A leak alerts immediately, other failures alert after 3 runs, and stranded or orphaned clients are fixed by ordered restarts (at most 3 per 6 h, never on a leak).

---

## 3. Reading: manga and books

```mermaid
flowchart LR
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef vpn fill:#e6f4ef,stroke:#0f8a6a,color:#1d1d1f
  classDef net fill:#fbf1e4,stroke:#9a5b13,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  reader["Phone / tablet / Mac"] --> caddy["Caddy<br/>✅ PING ✅ TLS"]:::access
  caddy -->|sources.*| suwa
  caddy -->|manga.*| komga
  caddy -->|books.*| kavita

  subgraph ciri["ciri · manga + books"]
    subgraph mg["manga-gluetun · kill-switch"]
      suwa["Suwayomi<br/>✅ HTTP"] --> mflare["FlareSolverr<br/>in tunnel"]
    end
    mdisk["Manga disk<br/>CBZ · local zvol, no backup"]
    komga["Komga · manga reader<br/>✅ HTTP"]
    bdisk["/data/books"]
    kavita["Kavita · ebooks<br/>✅ HTTP"]
  end

  sc["Proton Secure Core<br/>double hop"]:::vpn
  src["Manga sources"]:::net
  suwa ==>|all source traffic| sc
  sc ==> src
  suwa -->|writes CBZ| mdisk
  mdisk -->|reads files| komga
  bdisk -->|read-only| kavita
  kuma["Uptime Kuma"]:::mon -.-> suwa
  kuma -.-> komga
  kuma -.-> kavita
  style mg fill:#e6f4ef,stroke:#0f8a6a
```

- **Separate tunnel:** the manga tunnel is a second gluetun. If it fails, the torrent tunnel is unaffected, and the reverse is also true.
- **Readers stay up:** Suwayomi and Komga only share a directory, never a network, so Komga and Kavita still work when the VPN is down.
- **Tunnel alarm:** Suwayomi is only reachable through the tunnel's port, so a red Suwayomi monitor means the manga tunnel is down.

---

## 4. Personal apps

```mermaid
flowchart LR
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef net fill:#fbf1e4,stroke:#9a5b13,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  phone["Phone · iOS apps"] --> caddy["Caddy<br/>✅ PING ✅ TLS"]:::access
  mac["Mac / browser"] --> caddy
  subgraph ciri["ciri · personal apps"]
    vault["Vaultwarden<br/>✅ HTTP"]
    paper["Paperless · OCR<br/>pg · redis · daily dump<br/>✅ HTTP"]
    immich["Immich<br/>server + ML · valkey · pg<br/>✅ HTTP"]
    memos["Memos<br/>✅ HTTP"]
    couch["CouchDB · Obsidian LiveSync<br/>⚠️ NONE"]
    shrink["Stirling-PDF + Mazanoke<br/>✅ HTTP×2"]
    n8n["n8n<br/>parse + de-duplicate<br/>✅ HTTP 🟣 PUSH"]
    sure["Sure · finance<br/>web + worker · pg · redis<br/>✅ HTTP"]
    ollama["Ollama"]
  end

  caddy --> vault & paper & immich & memos & couch & shrink & n8n & sure
  iphone["iPhone<br/>bank alert SMS → Shortcut"] -->|email| relay["Mail relay inbox<br/>dedicated account"]:::net
  relay -->|polled| n8n
  n8n -->|API| sure
  sure -->|AI chat| ollama
  immich -->|originals| photos["geralt photos<br/>virtiofs · restic nightly · 🟣 PUSH"]
  ciri --> data["ciri /data<br/>app data + DBs · PBS nightly"]
  n8n -.->|push on every Sure write| kuma["Uptime Kuma"]:::mon
```

- **Bank SMS → Sure:** an iPhone automation forwards each bank SMS to a dedicated mail inbox. n8n polls it, parses and de-duplicates, then writes to Sure's API. Every write sends a Kuma heartbeat, and the monitor goes red after 48 h of silence.
- **Backups:** app data and databases on `/data` go to PBS nightly. Paperless and Sure also keep daily `pg_dump`s. Photo originals live on geralt and are backed up nightly with restic.
- **HTTPS matters:** Obsidian mobile, the n8n login and Vaultwarden all need real TLS, which they get from Caddy's wildcard certificate.

---

## 5. AI

```mermaid
flowchart LR
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  browser["Browser / phone"] --> caddy["Caddy<br/>✅ PING ✅ TLS"]:::access
  caddy -->|chat.*| owui
  caddy -->|ollama.* · API has no auth| ollama

  subgraph ciri["ciri · ai stack"]
    owui["Open WebUI<br/>chat · RAG · web search<br/>⚠️ NONE"] -->|prompts| ollama["Ollama<br/>OpenAI-compatible API<br/>⚠️ NONE"]
    owui -->|search| searx["SearXNG<br/>internal only"]
    sure["Sure"] -->|AI chat| ollama
    models["/mnt/ai-models<br/>weights, no backup"] -->|loads| ollama
    ollama -->|CUDA| gpu["GTX 1060 · 6 GB<br/>🟣 PUSH"]
  end

  gpu --- jellyfin["Jellyfin NVENC<br/>shares the card"]
  kuma["Uptime Kuma"]:::mon -.->|NVENC test encode| gpu
```

- **Shared GPU:** a loaded model holds VRAM until keep-alive frees it. gpu-health counts a failed encode as contention, not a fault, while VRAM is busy.
- **Gap:** Ollama and Open WebUI have no Kuma check yet, so a dead container is only noticed when you try to use it.

---

## 6. Dashboard and DNS sync

```mermaid
flowchart LR
  classDef access fill:#e9effc,stroke:#2f5fd0,color:#1d1d1f
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  browser["Browser"] --> caddy["Caddy<br/>✅ PING ✅ TLS"]:::access
  caddy -->|home.*| hp
  caddy -->|olivetin.*| olive

  subgraph ciri["ciri · dashboard"]
    hp["Homepage<br/>own login · ✅ HTTP"] -->|container status| sock["Docker socket proxy<br/>read-only, POST refused"]
    olive["OliveTin<br/>fixed script whitelist · ✅ KW"]
    neb["nebula-sync<br/>hourly mirror · ➖ N/A"]
  end

  hp -->|widgets, read-only tokens| apis["Kuma · Proxmox · *arr APIs"]
  olive -->|forced-command ssh| hosts["Lab hosts"]
  neb -->|read| ph1["pihole-1 · source of truth<br/>✅ DNS"]
  neb -->|write| ph2["pihole-2 · mirror<br/>✅ DNS"]
  kuma["Uptime Kuma"]:::mon -.-> hp
  kuma -.-> olive
```

- **Read-only dashboard:** the Docker socket proxy rejects writes, and every API token Homepage uses is read-only.
- **OliveTin:** runs only whitelisted scripts, over ssh keys locked to a single forced command.
- **DNS changes go on pihole-1 only.** pihole-2 is overwritten every hour.

---

## 7. Monitoring

```mermaid
flowchart LR
  classDef mon fill:#fff,stroke:#b4233c,color:#1d1d1f

  kuma["Uptime Kuma<br/>LXC on geralt<br/>40 monitors · 5 groups"]:::mon
  kuma -.->|GET every 60 s| polls["HTTP / keyword polls<br/>each app's own endpoint"]
  kuma -.->|ping / DNS| pings["ciri · Caddy · Tailscale ×2<br/>router · switch · Pi-holes"]
  push["Push scripts<br/>vpn · mount · export · gpu · backup · n8n"] -.->|heartbeat| kuma
  push -->|triggers| fix["servarr-vpn-remediate<br/>ordered restarts, max 3 per 6 h"]
  kuma -.-> ntfy["ntfy → phone"]
  kuma -.->|lab status page| hp["Homepage tile"]
  beszel["Beszel on yennefer<br/>container + host metrics"]
```

### Active monitors for ciri

| Group | Monitor | Type | Checks | A green result proves |
|---|---|---|---|---|
| media-stack | jellyfin | ✅ HTTP | `:8096` | Media server answers |
| media-stack | qbittorrent | ✅ HTTP | `:8080` (via gluetun) | qBit is alive, and so is gluetun, since the port is published through it |
| media-stack | prowlarr · sonarr · radarr | ✅ KW | `/ping` → `OK` | Each *arr app is up |
| media-stack | bazarr | ✅ KW | `:6767` → `Bazarr` | The UI renders |
| media-stack | seerr | ✅ KW | `/api/v1/status` → `version` | The request API answers |
| media-stack | flaresolverr | ✅ KW | `:8191` → `FlareSolverr is ready` | The solver is ready |
| media-stack | servarr vpn health | 🟣 PUSH | every 180 s | Real egress is the VPN IP, the tunnel is up, port-fwd is synced, the client isn't orphaned |
| media-stack | media mount | 🟣 PUSH | 360 s | ciri can actually read the NFS media share |
| reading-stack | komga · kavita | ✅ HTTP | health endpoints | Readers are up |
| reading-stack | suwayomi | ✅ HTTP | `:4567` with credentials | Suwayomi is up, so the manga tunnel is up |
| ciri | ciri-ping | ✅ PING | VM | The VM is alive |
| ciri | gpu health | 🟣 PUSH | 360 s | A real NVENC encode works inside Jellyfin |
| ciri | immich · paperless · memos · pdf-stirling | ✅ HTTP | app ports | Each app answers |
| ciri | image-mazanoke | ✅ HTTP | basic auth | The real page is served past basic auth |
| ciri | vaultwarden | ✅ HTTP | `/alive` | Vault answers, checked directly and not through the proxy |
| ciri | sure | ✅ HTTP | `https://sure.kaermorhen.fyi` | Finance app through Caddy |
| ciri | n8n | ✅ HTTP | `/healthz` | Workflow engine is up |
| ciri | n8n-hdfc-ingest | 🟣 PUSH | 48 h window | The bank pipeline wrote to Sure recently |
| ciri | home | ✅ HTTP | `:3010`, 2xx–3xx | Dashboard is up (its login redirect counts as up) |
| ciri | olivetin | ✅ KW | `OliveTin` | Script runner renders |
| infra | proxy-caddy / proxy-tls | ✅ PING / TLS | Caddy, cert | Proxy is up, certificate valid and not expiring |
| infra | media-export | 🟣 PUSH | 60 s, from geralt | geralt is exporting the media disk over NFS |
| infra | photos-backup | 🟣 PUSH | 25 h window | The nightly photo backup ran |

### Not covered by Kuma

- ⚠️ **Ollama, Open WebUI:** no check yet. Planned: keyword check on Ollama, HTTP on Open WebUI.
- ⚠️ **CouchDB (obsidian-sync):** no check yet. Planned: `/_up` with basic auth.
- ➖ **nebula-sync:** by design. No port and an hourly batch job, so a failure shows up as Pi-hole drift.
- ➖ **gluetun, qbit-port-sync, manga-gluetun:** covered indirectly by the qbittorrent and suwayomi checks and the VPN-health push.
- ➖ **SearXNG, socket proxy, databases, redis/valkey, ML workers:** internal only. Covered through their parent app's check, with container state in Beszel.
- ➖ **Uptime Kuma itself:** runs on geralt and goes down with it. Beszel on yennefer covers that host.
