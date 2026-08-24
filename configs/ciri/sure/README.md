# sure — personal finance (ciri stack)

Sure ([we-promise/sure](https://github.com/we-promise/sure), the community
fork of Maybe Finance) on **ciri** (VM 150), live at `ciri:/data/stacks/sure/`,
port **3000**. Fresh deployment 2026-07-13 — the old-host backup was
deliberately discarded (decision: start clean, little data in it).

Services: `web` (Rails app), `worker` (Sidekiq), `db` (Postgres 16),
`redis`, and an opt-in `backup` (daily `pg_dump`, `--profile backup`).

## Files

- `compose.yaml` — verbatim copy of the live file (scp'd from the VM after
  every change, per the mirror convention in `CLAUDE.md`)
- `.env.example` — placeholder template; real `.env` lives only in the VM,
  chmod 600

## Changes vs the upstream example compose

- **App image pinned to `0.7.3`** — ghcr publishes no semver tags for sure
  (only `sha-<commit>` + `stable`), so `:stable` was used at deploy time
  (2026-07-13) as an accepted deviation. It was pinned to the resolved
  version 2026-08-23 (then v0.7.2) and bumped to **0.7.3 on 2026-08-24**, so a
  rollback can name a version. Support images stay pinned: `postgres:16` (kept per the
  old-host analysis in `docs/docker-vm.md`), `redis:7.4-alpine`,
  `postgres-backup-local:16`.
- **Bind mounts instead of named volumes** — `./storage`, `./postgres-data`,
  `./redis-data`, `./backups` under the stack dir, so all state lives on the
  `/data` disk like the other stacks.
- **No insecure defaults** — upstream ships a sample `SECRET_KEY_BASE` and
  `sure_password` as fallbacks; here both use `${VAR:?}` so compose fails
  loudly if `.env` is missing.
- **Kept the upstream `dns: 8.8.8.8/1.1.1.1`** on web/worker — documented
  workaround for Yahoo Finance sync hanging on IPv6-first DNS answers. This
  bypasses Pi-hole for these two containers only.
- **`container_name`s set** (`sure`, `sure-worker`, `sure-db`, `sure-redis`)
  for readable `docker ps`/Kuma targets.
- HTTP only (`RAILS_FORCE_SSL/ASSUME_SSL=false`) — LAN/tailnet access, no
  reverse proxy in front.
- AI chat/rules wired to the **local Ollama** (`configs/ciri/ai`,
  [proposal 002](../../../docs/proposals/002-local-ai-stack.md)) instead of
  hosted OpenAI — no API costs, no financial data leaving the LAN. See below.

## Local AI provider

Sure's `Provider::Openai` supports any OpenAI-compatible endpoint. Three
`.env` keys turn it on (see `.env.example`):

| Key | Value | Why |
|---|---|---|
| `OPENAI_ACCESS_TOKEN` | `ollama` | presence check only — Sure's `configured?` and Ollama both accept any non-empty string |
| `OPENAI_URI_BASE` | `http://<LAN_PREFIX>.150:11434/v1` | marks it a "custom provider" |
| `OPENAI_MODEL` | `qwen2.5:7b-instruct` | **required** once `OPENAI_URI_BASE` is set (was `qwen3:8b`, then `qwen3:30b-a3b`; changed 2026-08-24) |

Behaviour that falls out of `provider/openai.rb` + `provider/registry.rb`
(read from the running image 2026-07-31, ruby-openai 8.1.0):

- A blank `OPENAI_MODEL` with a custom base makes the registry return **nil**
  and log `Custom OpenAI provider configured without a model` — the AI
  features silently do nothing. This is the #1 misconfiguration.
- `supports_responses_endpoint?` defaults to `!custom_provider?`, so a custom
  base **automatically** uses `/v1/chat/completions` rather than OpenAI's
  `/v1/responses` (which Ollama doesn't implement). No override needed;
  `OPENAI_SUPPORTS_RESPONSES_ENDPOINT` exists if it ever misdetects.
- `supports_model?` returns true for any model name under a custom base, so
  `qwen3:*` isn't rejected by the `gpt-*`/`o1`/`o3` allow-list.
- Timeout raised to **420 s** (`OPENAI_REQUEST_TIMEOUT`, default 60) — local
  inference plus thinking tokens can exceed a minute, and a tool-calling reply
  chains several requests. Was 300 s until 2026-08-24.

**Why the host IP and not `http://ollama:11434`**: `sure_net` and `ai_net` are
separate bridge networks, and these containers pin `dns: 8.8.8.8/1.1.1.1` (the
Yahoo Finance IPv6 workaround), so `kaermorhen.internal` names don't resolve
inside them either. Ollama publishes `11434` on the host, so the VM IP works
from both networks — verified from `sure` and `sure-worker` (HTTP 200).

### Model choice, and the response-timeout patch

Learned 2026-07-31 by shipping it: the first wiring used `qwen3:8b` and every
chat produced *no visible reply at all*.

What actually happened — Ollama answered fine (`POST /v1/chat/completions` →
200) and Sure received the reply (usage recorded: 3807 prompt tokens, 959–1588
completion tokens). But qwen3 is a hybrid reasoning model and most of those
completion tokens were its hidden thinking block, so each reply took **2–3
minutes**. Sure's UI gave up first (`POST .../report_timeout`), the user hit
retry, and **retry deletes the pending `AssistantMessage`**. When the original
job finally finished it tried to insert its `tool_calls` row against a
`message_id` that no longer existed:

```
PG::ForeignKeyViolation: insert or update on table "tool_calls"
violates foreign key constraint "fk_rails_9c8daee481"   # message_id → messages.id
```

The reply was then discarded — hence "no response". The give-away is that the
`messages` table keeps only the `UserMessage`, with every assistant row gone.

#### The timeout is the real constraint — and it is patchable

Two timers discard the reply, and **neither is an ENV var or a Setting**
(verified against the running image 2026-08-01):

| Timer | Where | Value |
|---|---|---|
| Browser watchdog | `chat_controller.js`, Stimulus `responseTimeout` | 90 000 ms |
| Server-side gate | `Chat::UNDELIVERED_RESPONSE_TIMEOUT` (chat.rb) | `60.seconds` |

The browser only *reports*; the server re-checks under a row lock and is what
actually destroys the message. So raising **only** the server constant is
enough — the watchdog still POSTs at 90 s, the server declines to act, the
message survives, and the reply renders over Turbo Stream when Sidekiq
finishes. That is what `initializers/zz_llm_response_timeout.rb` does; it is
bind-mounted (not baked in) because `:stable` is a moving tag. Tune with
`LLM_UNDELIVERED_RESPONSE_TIMEOUT` (now 400 s; was 240 s until 2026-08-24).

Note this also means "just wait longer" never worked on stock Sure: the
watchdog destroys the pending message at 90 s **whether or not you press
retry**.

#### So which model?

With the timeout raised, thinking models become viable and it is a plain
quality/latency trade:

| Model | Reply time | GPU | Notes |
|---|---|---|---|
| `qwen3:30b-a3b` | ~2–5 min | **no — 18 GB vs 6 GB VRAM, runs on CPU at ~12 tok/s** | best comprehension; `tools` + `thinking` confirmed via `ollama show` |
| `qwen3:8b` | ~1–2 min | partial (5.2 GB) | middle ground |
| **`qwen2.5:7b-instruct`** | **~40 s** | **100% GPU (4.8 GB)** | **current choice (2026-08-24)**; no thinking, works on stock Sure with no patch |

**Current setting: `qwen2.5:7b-instruct`** (changed 2026-08-24 — see "The 30b
model never fit the GPU" below).

**How much does thinking actually buy here?** Less than you would expect,
because the arithmetic is not the model's job. Sure ships 15 tools
(`get_balance_sheet`, `get_income_statement`, `get_transactions`, …) whose Ruby
implementations return *already-computed* figures, and the system prompt
demands terse output ("Provide ONLY the most important numbers", "Do NOT add
introductions or conclusions"). The model's real work is choosing the right
tool, building correct date/account arguments, reading JSON, and formatting
currency — all instruct-model strengths. Thinking earns its cost on multi-hop
questions ("compare dining spend across three quarters against income"), where
several tool calls must be chained and cross-referenced. If answers feel like
they misread the data, **model size helps more than thinking does** — prefer
the 30B over an 8B with reasoning switched on.

If replies are slower than the table, check `docker exec ollama ollama ps` —
`PROCESSOR` must read `100% GPU` for the small models. The 6 GB card fits only
**one** ~5 GB model at a time, which is why the AI stack sets
`OLLAMA_MAX_LOADED_MODELS=1`; pointing Sure and Open WebUI at different models
means each switch pays a reload.

For reference, thinking can only be disabled per-request (`think: false` on
`/api/chat`, `reasoning_effort: "none"` on `/v1` — both verified to cut a
trivial reply to ~10 tokens). Sure sends neither, Ollama has no Modelfile
parameter for it ([ollama#14809](https://github.com/ollama/ollama/issues/14809)),
and qwen3's `/no_think` text switch is only partially honoured (419 → 285
tokens). Hence: raise the timeout, or pick a non-thinking model.

#### The 30b model never fit the GPU (found 2026-08-24)

The 2026-07-31 analysis above framed this purely as a *thinking* problem. An
RCA after the 0.7.3 upgrade found a second, larger factor that had been
present the whole time: **`qwen3:30b-a3b` is an 18 GB model on a 6 GB card.**
It never ran on the GPU at all. Ollama measured **11.99 tok/s**, i.e. CPU-speed
inference, and `ollama ps` would have shown it — the check was simply never run
for the 30b, only for the small models.

Combined with multi-round-trip tool calling (each call re-emits a 700–800 token
reasoning block), a two-part question cost **four LLM round trips and 311 s of
job time**. Measured before and after switching to `qwen2.5:7b-instruct`:

| | `qwen3:30b-a3b` | `qwen2.5:7b-instruct` |
|---|---|---|
| `AssistantResponseJob` | **311.5 s** | **40.3 s** |
| Completion tokens/call | 374–1693 | 47–71 |
| Single tool-call probe | ~225 s | **12.9 s** |
| `ollama ps` PROCESSOR | CPU (18 GB model) | **100% GPU (4.8 GB)** |

Both return a well-formed `finish_reason: tool_calls`, so nothing was lost on
capability for this workload. **Check `ollama ps` before blaming latency on
thinking** — a model that does not fit VRAM costs far more than reasoning does.

The trigger for the RCA was AI chat appearing dead after the 0.7.3 upgrade. It
was not: the mounted initializer loaded correctly in both `web` and `worker`
(`Chat::UNDELIVERED_RESPONSE_TIMEOUT` still exists in 0.7.3 at `chat.rb:138`),
the reply was generated, and it rendered ~3 min later. The 90 s browser
watchdog is what made it look broken.

One residual gap closed at the same time: the guard was **240 s against an
observed 311 s job**, so a reload past 240 s could still have destroyed a live
reply. Timeouts are now `LLM_UNDELIVERED_RESPONSE_TIMEOUT=400` and
`OPENAI_REQUEST_TIMEOUT=420`, preserving the invariant that a hung HTTP call
fails *after* the message guard rather than before it.

## Layout & ownership (in the VM)

```
/data/stacks/sure/             ciri:ciri — stack dir, compose.yaml, .env (600)
├── storage/                   Rails ActiveStorage (uploads, imports)
├── postgres-data/             postgres (uid 999) — the database
├── redis-data/                redis cache/queue (regenerable)
└── backups/                   daily pg_dump output (backup profile)
```

`ls` shows `postgres-data`/`redis-data` owned by **beszel** — that's just the
VM's uid-999 user colliding with the containers' internal uid 999; nothing
runs as the Beszel agent here.

## First-run notes

- First signup at `http://<LAN_PREFIX>.150:3000` becomes the admin account;
  after creating it, disable open registration in Settings → Self-Hosting.
- Upgrades: `stable` is a moving tag, so `docker compose pull && docker
  compose up -d web worker` moves to the newest release. Check the
  [release notes](https://github.com/we-promise/sure/releases) first.

## Follow-ups

- DNS name on pihole-1 (nebula-sync mirrors to pihole-2)
- Uptime-Kuma HTTP monitor on `:3000`
- `backup` profile enabled 2026-07-13; dumps land daily at midnight
  (IST since the 2026-07-14 TZ standardization; the first ran at UTC
  midnight) — verify `.sql.gz` files appear in `backups/daily/`, then fold
  offsite copies into the restic phase of `docs/backups.md`
