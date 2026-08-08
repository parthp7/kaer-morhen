# ai — local LLM stack (Ollama + Open WebUI + SearXNG)

Self-hosted LLM for realtime chat, web research on current data, and data
analysis, plus an OpenAI-compatible LAN API for other apps. Design decisions,
model evaluation, and the memory budget live in
[proposals/002](../../../docs/proposals/002-local-ai-stack.md); this README is
the as-built operational record.

| Piece | Value |
|---|---|
| Live path | `ciri:/data/stacks/ai/` (mirror of this directory) |
| Open WebUI | `http://<LAN_PREFIX>.150:8090` — chat UI, web search toggle, RAG, per-user API keys |
| Ollama API | `http://<LAN_PREFIX>.150:11434` — native + OpenAI-compatible under `/v1`, unauthenticated (flat LAN) |
| SearXNG | internal-only (`ai_net`), no published port |
| Model weights | `/mnt/ai-models/ollama` — dedicated 64 G scsi2 zvol, **`backup=0`** (re-downloadable, kept out of PBS) |
| GPU | GTX 1060 6 GB, shared with Jellyfin NVENC; `OLLAMA_KEEP_ALIVE=10m` frees VRAM after idle |

## Models

| Model | Where it runs | Speed | Use for |
|---|---|---|---|
| `qwen3:8b` (default) | fully in VRAM | ~20–30 tok/s | realtime chat, quick web-search answers |
| `qwen3:4b` | VRAM + big KV cache | ~45+ tok/s | fast web-RAG over many pages |
| `qwen3:30b-a3b` | CPU+GPU hybrid (~15–16 G RAM resident) | ~10–15 tok/s | deep research, data analysis — quality over latency |

`OLLAMA_MAX_LOADED_MODELS=1` (was 2 until 2026-07-31): with only 6 GB of VRAM,
**one ~5 GB model at a time** is the real limit. The 30B pins ~4.3 GB of VRAM
for its offloaded layers even though most of it lives in RAM, so a co-resident
8B gets pushed off the GPU and runs at CPU speed. Switching models now costs an
unload/reload, which is cheap while the weights are still in page cache.

**Thinking models need a patient client.** qwen3:* emit a long hidden
reasoning block that no OpenAI-compatible client strips, and it cannot be
disabled by configuration — only per-request (`think: false`, or
`reasoning_effort: "none"` on `/v1`), which most clients never send. Open WebUI
is fine because it renders reasoning as collapsible UI. Anything else either
needs its response timeout raised (as Sure now does —
[configs/ciri/sure](../sure/README.md)) or should point at a non-thinking
instruct model such as `qwen2.5:7b-instruct`. Check a new client's timeout
*before* blaming the model: the failure looks like an app bug, not slowness.

## Latency tuning (learned the hard way, 2026-07-31)

- **There is no multi-minute "warmup".** Cold model load from the NVMe-backed
  zvol is ~5–15 s (visible in `docker logs ollama`); after that the model stays
  resident for `OLLAMA_KEEP_ALIVE` (10 m). If a reply takes minutes, something
  is misconfigured — check `docker exec ollama ollama ps`: the `PROCESSOR`
  column must say `100% GPU` for qwen3:8b. Any `N% CPU` split means the model +
  KV cache no longer fit in 6 G VRAM (first-run incident: 16 k f16 context
  pushed it to 7.8 G → 34% CPU → ~4.6 tok/s).
- **Context is the VRAM lever**: global `OLLAMA_CONTEXT_LENGTH=8192` +
  `OLLAMA_KV_CACHE_TYPE=q8_0` keeps the 8b fully on GPU. Give the research
  model its long window per-model (Open WebUI → Admin → Models →
  `qwen3:30b-a3b` → Advanced → `num_ctx` 16384) — its KV sits in system RAM.
- **Thinking mode**: qwen3 models emit a hidden reasoning block before the
  visible answer — at degraded speeds this looks like "nothing happening".
  Reliable control is **per-request only**: `think: false` on `/api/chat`, or
  `reasoning_effort: "none"` on `/v1` (both measured to cut a trivial reply
  from hundreds of tokens to ~10). Qwen3's `/no_think` text switch is only
  *partially* honoured here — measured 419 → 285 tokens, not ~10 — so don't
  rely on it, and there is no Modelfile parameter for it
  ([ollama#14809](https://github.com/ollama/ollama/issues/14809)). Leave
  thinking on for research/analysis, where it earns its tokens.
- Web search inflates prompts by thousands of tokens (first prompt: 4.6 k);
  prompt processing at full GPU is several hundred tok/s, so this costs
  seconds — but it compounds badly with any CPU spill.

## First deploy (runbook)

```sh
# 1. Models disk — geralt (hot-plug; reboot ciri only if sdc doesn't appear):
qm set 150 --scsi2 silver-guests:64,discard=on,iothread=1,ssd=1,backup=0

# 2. ciri — filesystem, mount, swap safety valve:
sudo mkfs.ext4 -L ai-models /dev/sdc
echo 'LABEL=ai-models /mnt/ai-models ext4 defaults,nofail 0 2' | sudo tee -a /etc/fstab
sudo mkdir -p /mnt/ai-models && sudo mount /mnt/ai-models
sudo mkdir -p /mnt/ai-models/ollama
# 4 G swapfile (ciri had none): resident 30B + an Immich ML burst should
# degrade, not OOM-kill:
sudo fallocate -l 4G /swapfile && sudo chmod 600 /swapfile
sudo mkswap /swapfile && sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab

# 3. Stack (from the repo checkout):
rsync -av configs/ciri/ai/ lab-ciri:/data/stacks/ai/   # or scp the three files
ssh lab-ciri 'cd /data/stacks/ai && cp .env.example .env && chmod 600 .env'
# fill .env with real values: openssl rand -hex 32 for each
ssh lab-ciri 'cd /data/stacks/ai && docker compose up -d'

# 4. Models (~27 GB total, lands on /mnt/ai-models):
docker exec ollama ollama pull qwen3:8b
docker exec ollama ollama pull qwen3:4b
docker exec ollama ollama pull qwen3:30b-a3b
```

First browser visit to `:8090` creates the admin account. Then: Admin Panel →
Settings → Models → set `qwen3:8b` as default; the web-search toggle appears
in the chat input (+ menu).

**ConfigVar gotcha**: the `ENABLE_WEB_SEARCH`/`SEARXNG_QUERY_URL`/… env values
are persisted into Open WebUI's DB on first boot. After that, compose edits to
them are IGNORED — change web-search settings in Admin Panel → Settings →
Web Search instead.

## API integrations

- **Obsidian** (Copilot / Text Generator plugin): OpenAI-compatible provider,
  base URL `http://<LAN_PREFIX>.150:11434/v1`, API key `ollama` (any non-empty
  string), model `qwen3:8b`. Works over Tailscale too (subnet router).
- **Keyed access** (when a real key is wanted): Open WebUI → Settings →
  Account → API keys; OpenAI-compatible endpoint under
  `http://<LAN_PREFIX>.150:8090/api/`.
- **Sure**: wired 2026-07-31, verified 2026-08-01. Needs all three of
  `OPENAI_ACCESS_TOKEN=ollama`,
  `OPENAI_URI_BASE=http://<LAN_PREFIX>.150:11434/v1`, and
  `OPENAI_MODEL=qwen3:30b-a3b` in its `.env` (the model is mandatory for custom
  providers, and the host IP is mandatory because Sure pins external DNS).
  Running a *thinking* model there also required raising Sure's hardcoded
  response timeout via a mounted initializer. Details:
  [configs/ciri/sure](../sure/README.md).
- Future consumers: paperless-ai / paperless-gpt, Karakeep.

## Monitoring

**In place:**
- `scripts/monitoring/gpu-health.sh` (Push monitor, 5-min timer on ciri, live
  since 2026-08-05) — runs a real NVENC encode inside the jellyfin container
  and separately checks that ollama still has GPU access. An encode failure
  *while a model is resident* is treated as soft/strike-counted, because
  contention on the shared 6 GB card is expected and self-heals via
  `OLLAMA_KEEP_ALIVE`. See [monitoring README](../../../scripts/monitoring/README.md).
- Beszel graphs the GPU via ciri's agent. Sustained 30B runs load all 6 cores
  on a laptop cooler — watch temps on long research sessions.

**Still TODO** — neither service has an HTTP liveness check, so a dead ollama
or open-webui is currently only noticed by using it:
- HTTP keyword on `http://<LAN_PREFIX>.150:11434` — expect `Ollama is running`
- HTTP on `http://<LAN_PREFIX>.150:8090`

(per [uptime-kuma.md](../../../docs/uptime-kuma.md) conventions)

## Verification (after deploy)

1. `docker exec ollama ollama run qwen3:8b --verbose "hello"` → ≥20 tok/s eval;
   `nvidia-smi` shows ~5 GB during, freed ~10 min after.
2. Web search on: ask about a current news item → cited, current answer.
3. `curl http://<LAN_PREFIX>.150:11434/v1/models` from another machine.
4. `free -h` on ciri: ≥ ~2 G available **while** the 30B is resident.
5. Next nightly PBS: ciri backup size did not jump by ~27 GB.

## Risks / gotchas

- **VRAM contention**: a 4K tone-mapped NVENC transcode + resident model can
  collide; keep-alive mitigates. Pascal has no FLR — a wedged GPU means a full
  geralt reboot ([gpu-passthrough.md](../../../docs/gpu-passthrough.md)).
  When Jellyfin transcodes fail, **contention is not the default explanation** —
  distinguish it from a container losing GPU access altogether using the table
  in the [jellyfin README](../jellyfin/README.md#is-it-the-daemon-reload-or-vram-contention-with-ollama).
  Short version: contention fails *after* CUDA initialises and only while a
  model is resident; `docker exec ollama ollama ps` shows what is loaded.
- **GPU wired in via CDI** (`devices: ["nvidia.com/gpu=all"]`) since
  2026-08-02, replacing `deploy.resources.reservations.devices` — changed in
  lockstep with the jellyfin stack because they share the card. Rationale:
  [jellyfin README](../jellyfin/README.md#making-gpu-access-survive-daemon-reload).
- Pascal (compute 6.1) still supported by Ollama (driver ≥570), but CUDA 13
  drops Pascal — deprecation eventually; llama.cpp is the fallback.
- open-webui pinned v0.11.0 (2 days old at pinning) — drop to v0.10.x if flaky.
