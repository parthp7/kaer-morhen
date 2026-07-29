# Proposal 002 — Local AI stack on ciri (Ollama + Open WebUI + SearXNG)

- **Status**: **Draft** — approved in planning 2026-07-29, nothing deployed yet.
  The RAM upgrade (§5) is ordered but **not arrived**; all specs in as-built
  docs remain at 16 GB until the module is installed and confirmed working.
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
- geralt live budget (verified 2026-07-29): 16 GB total, ciri at 10240 MB fixed
  (docker-vm.md's 8192 figure is stale), 2 GiB ARC cap, ~2 GB true slack.
- ciri prerequisites already in place: nvidia driver 580.x + container toolkit,
  `nvidia` runtime registered; ports 8090 and 11434 free.

## 2. Model plan

| Tier | Model | Fit | Expected speed |
|---|---|---|---|
| Now — daily driver | qwen3:8b (Q4_K_M, ~5.2 GB) | fully in 6 GB VRAM | ~20–30 tok/s |
| Now — long-context web-RAG | qwen3:4b (~2.6 GB) | VRAM + large KV cache | ~45+ tok/s |
| Optional vision | gemma3:4b | fits | fast |
| After §5 RAM | **qwen3:30b-a3b MoE** (Q4, ~18.6 GB) | CPU+GPU hybrid, ~3B active/token | ~10–15 tok/s |
| After §5, dense fallback | qwen3:14b (~9 GB) | ~55% GPU offload | ~5–8 tok/s |

Pascal note: compute 6.1 still supported by Ollama (driver ≥570), but CUDA 13
drops Pascal — deprecation will come eventually; llama.cpp is the fallback.

## 3. Stack (`configs/ciri/ai/` → `ciri:/data/stacks/ai/`)

Three services, lab conventions (pinned tags, `container_name`,
`restart: unless-stopped`, TZ=Asia/Kolkata, dedicated bridge network,
secrets only from `.env`):

- **ollama** `ollama/ollama:0.32.5` — port `11434:11434` (LAN API);
  GPU via the same `deploy.resources.reservations.devices` block as Jellyfin;
  `OLLAMA_KEEP_ALIVE=10m` so VRAM frees for NVENC transcodes;
  models volume on a **new scsi2 64 G disk (`backup=0`) at `/mnt/ai-models`**
  so ~10–15 GB of re-downloadable GGUFs stay out of nightly PBS backups.
- **open-webui** `ghcr.io/open-webui/open-webui:v0.11.0` — port `8090:8080`;
  `OLLAMA_BASE_URL=http://ollama:11434`; web search via SearXNG (verify exact
  env names against v0.11 docs at deploy — they have churned across versions);
  data volume on `/data/docker` (chats/config DO get backed up).
- **searxng** `searxng/searxng:2026.7.28-c01178d03` — internal-only (no
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
- **Sure**: point its OpenAI provider env at the Ollama `/v1` endpoint (verify
  Sure's exact env var names at implementation; Maybe fork with OpenAI
  support); update the `configs/ciri/sure` mirror after.

## 5. RAM upgrade (ordered, NOT yet arrived)

Ordered 2026-07-29: SK Hynix **HMA82GS6CJR8N-VK** — 16 GB DDR4-2666 CL19 2Rx8
1.2 V SODIMM. Compatibility verified against the existing Samsung
M471A2K43CB1-CTD (identical JEDEC spec; vendor mix fine) and the platform
(i7-8750H: DDR4-2666 dual-channel; MSI GP63 8RE: 2 slots, 32 GB max,
ChannelB-DIMM0 empty). Dual channel doubles memory bandwidth (~19 → ~38 GB/s),
which directly speeds CPU-side token generation.

When it arrives and **only after the user confirms it working**
(`dmidecode -t memory` → 2× 16 GB @ 2667 MT/s, `free -h` ≈ 31 Gi, stable):

1. `qm set 150 --memory 24576`, reboot ciri. New budget: 24 G ciri + 2 G ARC
   (optionally raise to 3–4 G) + ~2 G host/LXCs + ~2 G slack.
2. `ollama pull qwen3:30b-a3b` (~19 GB, lands on scsi2); default model for
   research, qwen3:8b stays for fast chat.
3. Only then update hardware-inventory.md / docker-vm.md to 32 GB.

## 6. Monitoring, docs, verification (at deploy time)

- Uptime-Kuma: HTTP keyword monitor `:11434` ("Ollama is running") + HTTP `:8090`.
- Docs to touch: docker-vm.md stack table (+ fix stale 8 G RAM figure),
  gpu-passthrough.md (Ollama future → live), storage.md (scsi2, backup=0
  rationale), uptime-kuma.md.
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
