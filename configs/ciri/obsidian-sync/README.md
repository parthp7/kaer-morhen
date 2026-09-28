# obsidian-sync — CouchDB for Obsidian Self-hosted LiveSync

Feature-rich, AI-assisted note-taking. **Obsidian runs on the clients**
(Mac + iPhone); ciri hosts only the CouchDB replication target. AI comes from
the existing local stack — [configs/ciri/ai](../ai/README.md) — over the LAN.

| Piece | Value |
|---|---|
| Live path | `ciri:/data/stacks/obsidian-sync/` (mirror of this directory) |
| Client URI | `https://obsidian.kaermorhen.fyi` — Caddy on LXC 202 ([proposal 003](../../../docs/proposals/003-reverse-proxy.md)); **every client uses this**, on LAN and over Tailscale |
| CouchDB (backend) | `http://<LAN_PREFIX>.150:5984` — **authenticated**, no anonymous access |
| Fauxton admin UI | `http://<LAN_PREFIX>.150:5984/_utils` |
| Database | `oxenfurt` (created by the plugin, not by hand) |
| Data | `./data` on `/data` — **does** ride the nightly PBS job |
| Chat model | `qwen2.5:7b-instruct` on the existing Ollama (`:11434/v1`) |
| Embeddings | **client-side**, inside Obsidian — never touches ciri's GPU |
| Clients today | Mac + iPhone, both via the HTTPS URI, **LiveSync mode** (verified 2026-09-28) |

## Why this shape

- **Obsidian is a client app, so the server bill is one small container.**
  Everything that makes Obsidian feature-rich (plugins, canvas, graph,
  Dataview) is local to the client and costs ciri nothing. Compare the
  alternatives evaluated: AFFiNE/Docmost/Outline are 3–5 containers, and
  Docmost and Outline have no AI at all.
- **Notes stay plain Markdown on disk.** Best backup and exit story of any
  candidate: every synced device holds a complete vault, on top of PBS.
- **Embeddings run on the client, not on ciri.** This is the deliberate
  hardware call — see below.

## Hardware interactions (the constraints that shaped this)

- **The 6 GB GTX 1060 is the binding resource, and it is shared with Jellyfin
  NVENC.** `OLLAMA_MAX_LOADED_MODELS=1` (set 2026-07-31 after the co-residency
  incident — see [ai/compose.yaml](../ai/compose.yaml)) means Ollama holds
  exactly one model. A server-side embedding model would therefore evict the
  chat model on every single question, or force that setting back to 2 and
  reintroduce the bug. Running embeddings **client-side** sidesteps both: the
  `ai` stack is not modified by this deployment at all.
- **The chat model must not be a thinking model.** `qwen3:*` emit a hidden
  reasoning block; Obsidian Copilot renders it inline as a garbage prefix on
  every reply (logancyang/obsidian-copilot#2133, #2030), and thinking is only
  disableable per-request — no Modelfile setting exists (ollama#14809). Same
  root cause as the Sure incident. Hence `qwen2.5:7b-instruct`.
- **VRAM fit for `qwen2.5:7b-instruct`**: 4.7 GB weights + ~0.24 GB q8_0 KV at
  the global `OLLAMA_CONTEXT_LENGTH=8192` + compute buffers ≈ **5.4 GB**,
  inside 6 GB. It is *smaller* than the qwen3:8b already proven to fit. Verify
  with `ollama ps` showing `100% GPU` — anything else means CPU spill.
- **Weights land on `/mnt/ai-models`** (scsi2, `backup=0`), not `/data`: 4.7 GB
  of re-downloadable GGUF stays out of PBS. 35 G free there.
- **CouchDB storage is append-only + fsync**, so the PBS snapshot taken under
  `qemu-guest-agent` fs-freeze is crash-consistent and recoverable — no dump
  hook needed, unlike the Postgres stacks.
- **RAM**: CouchDB idles at ~100–150 MB. Negligible against ciri's 24 G, and it
  does not compete with the 30B MoE's ~15–16 G resident footprint.

## Deploy runbook

Run every step on the VM as `ciri` unless noted. Steps are ordered so each one
is verifiable before the next.

### 1. Stack files + secrets

```sh
# from the Mac, in the repo checkout
rsync -av --exclude='.env' configs/ciri/obsidian-sync/ lab-ciri:/data/stacks/obsidian-sync/
```

```sh
# ciri
cd /data/stacks/obsidian-sync
cp .env.example .env && chmod 600 .env
# fill it in:
#   COUCHDB_USER      — pick a name, NOT "admin"
#   COUCHDB_PASSWORD  — openssl rand -hex 24
#   COUCHDB_SECRET    — openssl rand -hex 32
```

### 2. Pre-create and chown the mounts — before first start

```sh
# ciri
mkdir -p /data/stacks/obsidian-sync/data
sudo chown -R 5984:5984 /data/stacks/obsidian-sync/data \
                        /data/stacks/obsidian-sync/couchdb
```

uid 5984 is `couchdb` inside the image. The entrypoint would fix this itself
(it starts as root, chowns, then drops via `setpriv`), but doing it up front
makes first start deterministic and is required if `user:` is ever pinned.

### 3. Start and verify the server

```sh
cd /data/stacks/obsidian-sync && docker compose up -d
docker logs obsidian-couchdb --tail 30      # no crash loop, no "Admin Party" error
```

```sh
# system databases exist (proves single_node=true worked)
source .env
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/_all_dbs
#   -> ["_replicator","_users"]   (_global_changes may also appear)

# anonymous access is refused (proves require_valid_user)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:5984/_all_dbs
#   -> 401

# LiveSync's required settings actually took
curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" \
  http://127.0.0.1:5984/_node/_local/_config/cors
#   -> origins include app://obsidian.md ; credentials true
```

```sh
# the tracked baseline was NOT chosen as the config write target
grep -c '^;' couchdb/00-livesync.ini    # -> non-zero: comments intact
grep -l 'pbkdf2' couchdb/*.ini          # -> couchdb/docker.ini ONLY
```

If `00-livesync.ini` ever shows a `-pbkdf2-` admin hash or has lost its
comments, the filename ordering has been broken — see Gotchas.

### 4. Pull the chat model

```sh
# ciri — ~4.7 GB, lands on /mnt/ai-models
docker exec ollama ollama pull qwen2.5:7b-instruct
docker exec ollama ollama run qwen2.5:7b-instruct --verbose "hi"
docker exec ollama ollama ps          # MUST show 100% GPU
```

### 5. Obsidian on the Mac

1. Install Obsidian; create the vault (or open an existing one). **Back it up
   first** — step 3 of the plugin wizard overwrites one side.
2. Community plugins → install and enable **Self-hosted LiveSync**.
3. LiveSync settings → wizard:
   - URI `https://obsidian.kaermorhen.fyi`, username/password from `.env`,
     database `oxenfurt`. (The Mac originally used the plain LAN URI; it was
     repointed on 2026-09-28 — same database, no rebuild needed.)
   - **Test Database Connection** → must pass.
   - **Check database configuration** → every row green. This is the plugin
     verifying the server-side settings from `couchdb/00-livesync.ini`. A red
     row can be fixed here, but the fix lands in `docker.ini`, not the tracked
     baseline — reconcile it afterwards (see Gotchas).
   - Set the **E2EE passphrase** and store it in the password manager — notes
     are encrypted client-side before they reach CouchDB, and it is not
     recoverable.
   - Preset **LiveSync**, then initialise the server ("Rebuild everything" /
     "I understand, overwrite server") — correct on a first device against an
     empty database.
   - **Confirm the preset actually took**: Sync Settings → Synchronization
     Preset → **LiveSync** → Apply. The 2026-08-05 setup finished with *every*
     trigger off (live, on-start, on-save, periodic), so the vault uploaded once
     and then silently stopped syncing until 2026-09-28. `isConfigured` being
     true says nothing about whether anything replicates — check §Verify.
4. **Copilot** plugin — chat only:
   - Provider: Ollama (or Custom OpenAI-compatible)
   - Base URL `http://<LAN_PREFIX>.150:11434/v1`, API key any non-empty string
   - Model `qwen2.5:7b-instruct`
5. **Smart Connections** plugin — semantic search, embeddings local to the Mac.
   Leave the embedding provider on its bundled local model; do **not** point it
   at Ollama, that is the whole point of the split.

### 6. Additional devices (iPhone — done 2026-09-28)

1. On an already-syncing device (the Mac), confirm its URI is the HTTPS one —
   the new device inherits it, and a plain-HTTP URI is unusable on mobile.
2. LiveSync → Setup → **Copy current settings as a new setup URI**. It asks
   for a passphrase that encrypts the URI itself. Move the URI via the password
   manager or AirDrop — it carries the CouchDB login and the E2EE passphrase.
3. On the phone: create an **empty** vault `oxenfurt` with **Store in iCloud
   OFF** (see Gotchas — no second sync tool), enable community plugins, install
   and enable Self-hosted LiveSync.
4. **Use the copied setup URI**, enter its passphrase, and choose **set up as a
   secondary / subsequent device**. Never "rebuild" or "overwrite remote" from
   a secondary — that replaces the server copy with the new, empty vault.
5. Skip Smart Connections on mobile (on-device embeddings are slow there). If
   Copilot is wanted, try `https://ollama.kaermorhen.fyi` rather than the
   plain-HTTP LAN port.

## Verify

All server-side checks are read-only.

```sh
# doc_count / update_seq — must rise after any edit on any device (notes are
# E2EE, so you cannot find a note by name server-side; the counter is the proof)
ssh lab-ciri 'cd /data/stacks/obsidian-sync && set -a && . ./.env && set +a && curl -s -u "$COUCHDB_USER:$COUCHDB_PASSWORD" http://127.0.0.1:5984/oxenfurt | grep -oE "\"doc_count\":[0-9]+|\"update_seq\":\"[0-9]+"'

# who is talking, and by which path: field 6 is the Host header
# (obsidian.kaermorhen.fyi = through Caddy), field 7 the client address
ssh lab-ciri 'docker logs --since 1h obsidian-couchdb 2>&1 | grep " /oxenfurt" | awk "{print \$6, \$7}" | sort | uniq -c'
```

A healthy live client shows repeated `GET /oxenfurt/_changes?...heartbeat=30000`
(its open feed) and, after edits, `POST /oxenfurt/_revs_diff` + `_bulk_docs`.
A handful of `404`s on `_local/…` at a device's first connection are normal
(checkpoint not yet written). The end-to-end proof is by eye: edit on one
device, see it on the other within seconds.

Verified 2026-09-28: Mac and iPhone both via Caddy; phone first on LAN Wi-Fi,
then on mobile data over Tailscale (arrives from `tailscale-1`, `.203`);
a note created on the phone appeared on the Mac.

## Gotchas

- **`docker.ini` in `couchdb/` is runtime state and holds credentials.** Never
  copy it into the repo — only `00-livesync.ini` is tracked.
- **Never rename `couchdb/00-livesync.ini`.** CouchDB writes every runtime
  config change into the *last* ini of its chain (`config.erl`:
  `get_write_file -> lists:last`, directories expanded with `lists:sort`). The
  `00-` prefix keeps the tracked baseline ahead of the entrypoint's
  `docker.ini`, so `docker.ini` stays the write target. Called `local.ini` it
  would sort last and CouchDB would (a) rewrite it, stripping the comments and
  diverging from the repo, and (b) persist the **hashed admin password** into
  it on first start — `couch_password_hasher` calls
  `config:set("admins", …, Persist=true)`, which targets that same file. The
  mirror rule would then push a credential into git. Full reasoning is in the
  file's header.
- **After a UI-side config fix, reconcile deliberately.** The LiveSync "Check
  database configuration" panel's Fix buttons write into `docker.ini`, which
  overrides the baseline. Diff it and fold any keeper into `00-livesync.ini`,
  then re-`scp` *that* file — do not mirror `docker.ini`.
- **No healthcheck on the container.** The image purges `curl` and ships no
  `wget`, so any HTTP healthcheck silently fails and parks it `unhealthy`.
  Liveness belongs to Uptime-Kuma (follow-up), which must send Basic auth
  because `require_valid_user = true`.
- **`.smart-env/` (Smart Connections' embedding index) must never sync.**
  LiveSync skips dotfolders by default, so this is safe as shipped — but if
  **Hidden File Sync** is ever enabled, exclude it explicitly or every
  re-embed will replicate a large binary index to every device.
- **Mobile will not work over plain HTTP.** Obsidian on iOS/Android requires a
  publicly-trusted TLS certificate; self-signed is rejected by the plugin.
  Hence every client uses `https://obsidian.kaermorhen.fyi` (production
  wildcard cert on Caddy), not the `:5984` LAN port.
- **Do not run a second sync tool on the same vault** (iCloud/Syncthing/Git).
  Concurrent writers to the same files corrupt LiveSync's chunk state. On iOS
  this means creating the vault with **Store in iCloud off**.
- **iOS syncs only while Obsidian is in the foreground.** No background
  replication; the phone catches up when the app is opened.
- **CouchDB's log shows the real client, not Caddy.** Requests through the
  proxy log the client's own address (the Mac's or phone's LAN address, or
  `.203` for anything arriving over Tailscale) with Host `obsidian.kaermorhen.fyi` —
  never `.202`. Filter by the Host field to tell proxied from direct traffic;
  grepping for `.202` finds nothing and wrongly suggests the proxy is unused.

## Follow-ups

- **Monitoring**: Uptime-Kuma HTTP monitor on `http://<LAN_PREFIX>.150:5984/_up`
  with Basic auth, expecting `"status":"ok"`; per
  [uptime-kuma.md](../../../docs/uptime-kuma.md) conventions.
- ~~**DNS**: `obsidian.kaermorhen.internal`~~ — superseded by
  `obsidian.kaermorhen.fyi` (Pi-hole records from proposal 003).
- ~~**Mobile sync**~~ — **done 2026-09-28.** The TLS it needed arrived with
  the Caddy reverse proxy (LXC 202, DNS-01 wildcard cert, proposal 003).
  iPhone syncs on LAN and off-LAN via the Tailscale subnet router; the
  `[cors]` origins here needed no change.
- **Compaction watch**: LiveSync keeps revision history, so the database grows
  faster than the vault. CouchDB's built-in auto-compactor handles the normal
  case; if `./data` grows out of proportion, check the plugin's history
  settings first, then compact manually
  (`curl -X POST -H 'Content-Type: application/json' -u … .../oxenfurt/_compact`).
- **App-level backup** once the [backups.md](../../../docs/backups.md) next
  phase lands — though every synced client is already a full replica.
