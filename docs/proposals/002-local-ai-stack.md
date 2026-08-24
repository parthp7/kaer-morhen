# Proposal 002 — Local AI stack on ciri (Ollama + Open WebUI + SearXNG)

- **Status**: **Implemented 2026-07-31** — RAM upgrade (§5) done, ciri raised to
  24 G per the §7 budget, stack deployed on ciri, all three models pulled, web
  search working end-to-end, Sure wired and verified 2026-08-01 (§4).
  Amended since: GPU moved from `deploy.resources` to **CDI** on 2026-08-02
  alongside Jellyfin, and `gpu-health.sh` monitoring landed 2026-08-05.
  Remaining: **HTTP liveness monitors for ollama/open-webui, and a DNS name**
  (§6). As-built detail lives in
  [configs/ciri/ai/README.md](../../configs/ciri/ai/README.md).
- **Date**: 2026-07-29
- **Scope**: VM 150 `ciri` on `geralt`; see
  [gpu-passthrough.md](../gpu-passthrough.md) (which already listed Ollama as
  the intended future GPU consumer) and [docker-vm.md](../docker-vm.md)

Self-hosted LLM for general chat and deep research with live web search, plus
an OpenAI-compatible API endpoint that other apps (Sure, Obsidian plugins,
future Paperless tooling) can integrate with — the API part is a first-class
requirement, not an afterthought.

## 1. Why ciri, and the constraints that drove the design

- The GTX 1060 (6 GB) is VFIO-attached to ciri and can only go to one VM
  (proposal 001 §3 decision), so the AI stack is another compose stack on
  ciri — not a new VM in the reserved 151–189 band.
- **VRAM (6 GB), not RAM, is today's model ceiling.** More ciri RAM only buys
  slow CPU-offloaded models, which is why the interim answer is an 8B model
  fully in VRAM and the real upgrade is host RAM (§5).
- geralt live budget: **32 GB total since 2026-07-31** (was 16 GB when this was
  drafted). At the moment this section was written ciri still held 10240 MB,
  leaving ~18 GB of slack — which is what made the §2 MoE tier viable. That
  slack was then spent: ciri now runs at **24576 MB** per the §7 budget.
- ciri prerequisites already in place: nvidia driver 580.x + container toolkit,
  `nvidia` runtime registered; ports 8090 and 11434 free.

## 2. Model plan

Primary use cases (user, 2026-07-31): **realtime general-purpose chat + web
research on current data**, plus data analysis and general conversations.
Mapping (all three pulled; Open WebUI default = qwen3:8b):

| Use case | Model | Fit | Expected speed |
|---|---|---|---|
| Realtime chat / quick search-augmented answers (default) | **qwen3:8b** (Q4_K_M, ~5.2 GB) | fully in 6 GB VRAM | ~20–30 tok/s — the "realtime" model |
| Fast long-context web-RAG (many pages in context) | qwen3:4b (~2.6 GB) | VRAM + large KV cache | ~45+ tok/s |
| Deep research / data analysis (quality over latency) | **qwen3:30b-a3b MoE** (Q4, ~18.6 GB) | CPU+GPU hybrid, ~3B active/token | ~10–15 tok/s |
| Dense fallback if MoE underwhelms | qwen3:14b (~9 GB) | ~55% GPU offload | ~5–8 tok/s |

Pascal note: compute 6.1 still supported by Ollama (driver ≥570), but CUDA 13
drops Pascal — deprecation will come eventually; llama.cpp is the fallback.

**Measured on first deploy (2026-07-31):** qwen3:30b-a3b sustains **9.4 tok/s**
(49/49 layers "offloaded" but 40 overflowing to system RAM: 14.3 G CPU-mapped
vs 4.3 G in VRAM) — at the low end of the 10–15 estimate, usable for research.
qwen3:8b is interactive (a few seconds to first token) once it fits in VRAM.

⚠️ **Context length is the VRAM lever — the first-run trap.** The planned
`OLLAMA_CONTEXT_LENGTH=16384` gave qwen3:8b a 2.4 G f16 KV cache; 5.0 G weights
+ KV + compute = 7.8 G against 6 G of VRAM, so llama.cpp silently spilled 34 %
to CPU and generation collapsed to **4.6 tok/s**. Combined with qwen3's hidden
thinking block that presents as "the model is frozen" (observed: ~5 minutes for
one reply), not as slowness. Fix applied: global context 8192 plus
`OLLAMA_FLASH_ATTENTION=1` + `OLLAMA_KV_CACHE_TYPE=q8_0`, which cut the 8b's KV
cache to 612 MiB and restored full-GPU residency. The research model gets
`num_ctx` 16384 per-model in Open WebUI instead, where its KV lives in cheap
system RAM. **Diagnostic**: `docker exec ollama ollama ps` — the `PROCESSOR`
column must read `100% GPU` for qwen3:8b; any `% CPU` means it no longer fits.

**Corollary found 2026-08-24:** the same diagnostic was never applied to
`qwen3:30b-a3b`, which at **18 GB cannot fit the 6 GB card at all** — it had
been running on CPU at ~12 tok/s since it was pulled. That is fine for
interactive Open WebUI use (the thinking block renders as a collapsible
section, so latency reads as normal), but it made Sure's AI chat look broken:
a multi-tool reply took 311 s against a 90 s browser watchdog. Sure now uses
`qwen2.5:7b-instruct` (100% GPU, 4.8 GB, ~40 s replies). **Run `ollama ps` for
every model an API client uses, not just the small ones** — see
[sure/README](../../configs/ciri/sure/README.md).

## 3. Stack (`configs/ciri/ai/` → `ciri:/data/stacks/ai/`)

Three services, lab conventions (pinned tags, `container_name`,
`restart: unless-stopped`, TZ=Asia/Kolkata, dedicated bridge network,
secrets only from `.env`):

- **ollama** `ollama/ollama:0.32.15` — port `11434:11434` (LAN API);
  GPU wired the same way as Jellyfin — originally
  `deploy.resources.reservations.devices`, **migrated to CDI**
  (`devices: ["nvidia.com/gpu=all"]`) on 2026-08-02 in lockstep with that
  stack since they share the card ([gpu-passthrough.md](../gpu-passthrough.md));
  `OLLAMA_KEEP_ALIVE=10m` so VRAM frees for NVENC transcodes;
  models volume on a **new scsi2 64 G disk (`backup=0`) at `/mnt/ai-models`**
  so ~10–15 GB of re-downloadable GGUFs stay out of nightly PBS backups.
- **open-webui** `ghcr.io/open-webui/open-webui:v0.11.0` — port `8090:8080`;
  `OLLAMA_BASE_URL=http://ollama:11434`; web search via SearXNG (verify exact
  env names against v0.11 docs at deploy — they have churned across versions);
  data volume on `/data/docker` (chats/config DO get backed up).
- **searxng** `searxng/searxng:2026.8.22-9fea41204` — internal-only (no
  published port); `settings.yml` with `formats: [html, json]` (JSON is
  required by Open WebUI); limiter off.

### Disk (user runs, before first deploy)

```
# geralt — hot-plug; verify with lsblk in ciri, reboot ciri only if it doesn't appear
qm set 150 --scsi2 silver-guests:64,discard=on,iothread=1,ssd=1,backup=0
# ciri
mkfs.ext4 -L ai-models /dev/sdc
# fstab: LABEL=ai-models /mnt/ai-models ext4 defaults,nofail 0 2
mkdir -p /mnt/ai-models/ollama
```

## 4. API integrations

- **Ollama native/OpenAI-compatible**: `http://<LAN_PREFIX>.150:11434/v1`,
  api key `ollama` (unauthenticated — same flat-LAN + Tailscale exposure as
  every other service; revisit when the reverse proxy LXC 202 gets built).
  Obsidian (Copilot / Text Generator plugins) points here, model `qwen3:8b`.
- **Open WebUI keyed API**: per-user API keys (Settings → Account),
  OpenAI-compatible under `http://<LAN_PREFIX>.150:8090/api/`.
- **Sure**: done 2026-07-31 — `OPENAI_ACCESS_TOKEN` + `OPENAI_URI_BASE` +
  `OPENAI_MODEL` (all three required; a custom base with a blank model makes
  Sure's provider registry return nil silently) plus a 300 s request timeout.
  Must use the host IP, not `http://ollama:11434`: separate bridge networks and
  Sure pins `dns: 8.8.8.8`. **Must also use a non-thinking model**
  (`qwen2.5:7b-instruct`) — see the lesson below.
  Details: [configs/ciri/sure](../../configs/ciri/sure/README.md).

### Lesson: thinking models are wrong for API consumers

qwen3's hidden reasoning block is a *UI feature*, not a model feature. Open
WebUI renders it as a collapsible section, so it reads as normal. Every other
OpenAI-compatible client just waits on it, and 900–1600 thinking tokens at
local speeds means 2–3 minutes per reply. In Sure that cascaded into silent
data loss: UI timeout → user retry → retry deletes the pending
`AssistantMessage` → the still-running job's `tool_calls` insert fails its
foreign key → the finished reply is discarded with nothing rendered.

Ollama can disable thinking only per request (`think: false`, or
`reasoning_effort: "none"` on `/v1`); there is no Modelfile parameter for it
([ollama#14809](https://github.com/ollama/ollama/issues/14809)) and Qwen3's
`/no_think` text switch is only partially honoured.

**Resolution (2026-08-01):** the constraint turned out to be Sure's *timeout*,
not thinking as such — it discards any reply older than a hardcoded 60 s
(server) / 90 s (browser watchdog), with no ENV or Setting to change either,
and it does so whether or not the user retries. Since the browser only reports
and the server decides, raising the one server constant via a bind-mounted
Rails initializer is sufficient and survives image pulls. **Rule for this lab:
when adding a new consumer of the AI stack, check its response timeout first;
if it can't be raised, give that client a non-thinking instruct model.**

## 5. RAM upgrade — **DONE 2026-07-31**

Ordered 2026-07-29 as SK Hynix **HMA82GS6CJR8N-VK** (16 GB DDR4-2666 CL19 2Rx8
1.2 V SODIMM); the seller shipped an equivalent **Micron 16ATF2G64HZ-2G6E1**
instead. Compatibility reasoning held either way — identical JEDEC spec to the
existing Samsung M471A2K43CB1-CTD, and the platform (i7-8750H: DDR4-2666
dual-channel; MSI GP63 8RE: 2 slots, 32 GB max, ChannelB-DIMM0 empty) takes it.
Dual channel doubles memory bandwidth (~19 → ~38 GB/s), which directly speeds
CPU-side token generation.

Installed and **verified working 2026-07-31**: `dmidecode -t memory` shows
2× 16 GB dual-rank at the full 2667 MT/s with no BIOS downclock, `free -h`
reports 31 Gi, and memtest86+ 7.20 passed **2 full passes with 0 errors**.

⚠️ The install was immediately followed by repeated ~90 s host hangs that looked
exactly like a bad DIMM. **They were unrelated to the RAM** — root cause was the
Optimus dGPU D3cold / ACPI `PGON` bug, fixed with `disable_idle_d3=1`
([gpu-passthrough.md](../gpu-passthrough.md) gotchas). Recorded here because the
coincidence in timing was extremely convincing and cost a full diagnostic cycle.

Remaining steps:

1. ~~`qm set 150 --memory 24576`, reboot ciri~~ — **done 2026-07-31**, verified
   (ciri sees 23 Gi, geralt ~3.4 G available). See §7 for the full budget.
2. `ollama pull qwen3:30b-a3b` (~19 GB, lands on scsi2); research/analysis
   model, qwen3:8b stays for fast chat.
3. ~~Update hardware-inventory.md / docker-vm.md to 32 GB~~ — done 2026-07-31.

## 7. Memory budget (as-built 2026-07-31)

**geralt (31.3 GiB usable):**

| Allocation | Size | Notes |
|---|---|---|
| ciri VM | **24 G** | hard reservation — VFIO-pinned, `balloon: 0` |
| ZFS ARC cap | 2 G (unchanged) | `steel` HDD workload is light; not worth host slack |
| LXC caps 101/103/104 | 1.5 G | cgroup caps, real use ~0.2 G |
| PVE host + slack | ~3.8 G (~3.4 G measured available) | includes virtiofsd page cache for `/mnt/media` streaming + vzdump reads |

**Inside ciri (24 G):** ~4.3 G current stacks + ~15–16 G resident 30B MoE
during inference (≈18.6 G weights − ~5 G in VRAM + KV cache) + ~2 G reserved
for future apps (Obsidian LiveSync/CouchDB etc.) + guest page cache.

Guardrails: `OLLAMA_MAX_LOADED_MODELS=1` — planned as 2 on the assumption that
"8B in VRAM + 30B in RAM" could coexist, corrected on 2026-07-31 once the 30B
turned out to pin ~4.3 G of VRAM for its offloaded layers too, squeezing a
co-resident 8B onto the CPU. Six GB of VRAM holds **one** ~5 G model at full
speed. Plus `OLLAMA_KEEP_ALIVE=10m` and a **4 G swapfile on ciri** (had none)
so an Immich ML burst on top of a resident model degrades instead of
OOM-killing.

**Observed with the 30B resident (2026-07-31):** ciri reports only ~3.9 G
"used" but ~18 G in buff/cache, because Ollama **mmaps** the weights — the model
counts as page cache, not RSS. The kernel evicted ~2.7 G of idle anonymous
pages from the other stacks into swap to make room. That is the swapfile doing
exactly its job; it is not memory pressure, and `free -h` "used" understates
what the AI stack actually occupies. Judge headroom by `available` (~15–19 G
observed) rather than `used`, and don't be alarmed by non-zero swap here.

**yennefer (7.7 GiB): unchanged.** 1.7 G used; caps 3.5 G. Future proposal-001
items still fit: HAOS VM 2 G + reverse-proxy LXC 202 at 256–512 M leave
~1.5 G+ slack.

## 6. Monitoring, docs, verification (at deploy time)

- Uptime-Kuma: HTTP keyword monitor `:11434` ("Ollama is running") + HTTP
  `:8090` — **still outstanding.** GPU access itself is covered by
  `gpu-health.sh` since 2026-08-05, but nothing checks that either service is
  answering HTTP.
- Docs: ~~docker-vm.md RAM figure~~ (done — now 24576 MB),
  ~~gpu-passthrough.md consumer table (Ollama future → live)~~ (done
  2026-08-08), ~~storage.md scsi2 / `backup=0` rationale~~ (done 2026-08-08).
  uptime-kuma.md gains the two monitors above when they are created.
- Verify: nvidia-smi shows ollama ~5 GB during generation and frees after
  keep-alive; `ollama run qwen3:8b --verbose` ≥20 tok/s; web-search answer with
  citations on a current-events question; `/v1/chat/completions` curl from the
  LAN; ciri ≥ ~3.5 GB RAM available; next PBS backup size unchanged.

## Risks

- VRAM contention with Jellyfin NVENC (4K tone-mapped transcode + resident
  model); keep-alive mitigates. Pascal has no FLR — a wedged GPU needs a full
  geralt reboot (accepted constraint).
- open-webui v0.11.0 was 2 days old at pinning; drop back one minor if flaky.
- Sustained 30B MoE inference loads all 6 cores on a laptop cooler — watch
  Beszel temps on first long runs.
