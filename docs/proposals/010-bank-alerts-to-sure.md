# Proposal 010 — Bank alerts to Sure: HDFC SMS → relay mailbox → n8n → Sure

- **Status**: **DESIGNED, parser tested, NOT deployed** (2026-09-04). Every
  file exists in the repo and the parser passes its fixture suite on the
  Mac; nothing has run on ciri, the phone, or Gmail. Phase A (the phone
  spike) decides whether the design survives contact with iOS, and it comes
  before anything else. "As-built deviations" is empty until then.
- **Date**: 2026-09-04
- **Scope**: one new compose stack `n8n` on **ciri**; one workflow inside
  it; one iPhone Shortcuts automation; one dedicated Gmail account; one
  Caddy route; one Pi-hole record; two Kuma monitors; one Sure API key and
  one Sure tag. **No existing stack is touched** and nothing is restarted.
  Phase 1 covers the **HDFC savings account and HDFC credit card** only.
- **Decisions taken up front (2026-09-04, with the user)**: capture by
  **email relay**, not a webhook, because Tailscale on the phone is not
  always on (§2); a **new dedicated Gmail** as the relay inbox (§5); **n8n**
  as the engine rather than a bespoke service (§2); HDFC's own alert emails,
  other banks and investments are follow-ups, not phase 1.

Addresses use `<LAN_PREFIX>` per `CLAUDE.md` and the last-octet convention from
[network.md](../network.md). `kaermorhen.fyi` is written in full, as decided in
[proposal 003](003-reverse-proxy.md).

---

## 0. Execution contract (read first if you are the agent running this)

- **Execute from [010-execution-checklist.md](010-execution-checklist.md)**,
  one step at a time, each with its own read-only Verify. This file is the
  why; that file is the ladder.

- **The human runs every command that changes state** — on ciri, on the
  Caddy and Pi-hole containers, in the n8n and Sure UIs, on the phone, in
  Gmail. The agent hands over exact commands and verifies with read-only
  checks (`docker ps`, `curl`, `ollama list`). Same contract as 005–009.
- **Order matters across phases and this time inside Phase A too**: A
  (phone + mailbox spike, then fixtures) → B (stack, Sure key, workflow) →
  C (proxy, DNS, Kuma) → D (verify) → E (mirror). Phase A3 is a go/no-go:
  if the Shortcut cannot send mail from a locked phone, stop and record it.
- **Rollback**: `docker compose down` in `/data/stacks/n8n` removes the
  engine; delete the Shortcut automation; revoke the Sure API key in
  Settings → API Keys; revert the Caddyfile block and the `dns.hosts` entry.
  Transactions already created in Sure carry the `auto:sms` tag and
  `source: hdfc-sms`, so they can be found and bulk-deleted if the design
  is abandoned.
- **Do not publish the route before the container answers** (proposal 003
  §3). Phase C comes after Phase B for that reason.
- **Nothing in this design writes to HDFC.** It only reads what the bank
  already sends the phone.

## 1. The requirement

From the 2026-09-04 session: *"I find myself struggling to input all my
banking transactions manually into Sure … My iPhone receives transaction
messages every time I do a transaction — via card, UPI, etc. … I want a way
to capture transactions (if not realtime, then latest fetch on demand)."*

| Requirement | Verdict | How |
|---|---|---|
| Every HDFC transaction appears in Sure without typing it | **Kept — hard** | SMS is the only per-transaction signal the bank pushes; capture it (§3) |
| Correct sign and account | **Kept — hard** | `nature` from debit/credit and instrument; account routed by last-4, never guessed (§6) |
| No duplicates, ever, including retries | **Kept — hard** | Sure's `external_id` + `source` idempotency, verified on the running 0.7.3 (§6, §10) |
| Latest data within minutes, not real-time | **Kept** | IMAP IDLE on the relay inbox: the mail arrives seconds after the SMS; the user accepted minutes (§2) |
| Works whether or not Tailscale is on | **Kept — hard** | The phone never talks to the lab; it sends mail (§2) |
| Financial data stays private | **Softened, deliberately** | One hop outside the lab — the relay Gmail — accepted as the price of not depending on the VPN (§4) |
| Nothing silently dropped | **Kept — hard** | Every non-`ok` outcome reaches the phone via ntfy with the raw text (§6) |
| Investments | **Dropped from phase 1** | Not in the SMS; CAS-statement import is a follow-up |
| Transactions under HDFC's SMS thresholds | **Dropped from phase 1** | HDFC stopped SMS below ₹100 sent / ₹500 received (2024); its emails cover them — follow-up |

## 2. Why this shape

**Why SMS at all.** HDFC exposes no push API, no daily export, and no
Account Aggregator access to individuals (§9). The SMS alert is the one
per-transaction signal the bank already delivers, it lands within seconds,
and it carries the amount, the instrument's last-4, a date, a counterparty
and — for UPI, NEFT and IMPS — the bank's own reference number. That
reference is the key to everything downstream: it is the same number that
appears in the statement narration, so a later CSV reconciliation can match
rows the phone missed.

**Why email relay and not a webhook.** The lab has no inbound path from the
internet by design (proposal 003 §6: even the public DNS zone is empty).
An iPhone Shortcut can only reach ciri while Tailscale is connected, and
the user's answer was that it often is not. So the Shortcut sends the SMS as
an email to a mailbox the lab *polls*: Mail's outbox queues it when the
phone is offline, Gmail holds it when ciri is down, and n8n fetches
whatever is unread when it comes back. The queue is free and needs no
service in the lab. The cost is minutes of latency and one hop through
Google, both accepted.

**Why n8n and not a small Python service.** Both were offered; the user
chose n8n. It is the lab's first workflow engine, and the parts of this
pipeline that are *not* the parser — IMAP with IDLE and reconnect, HTTP
with credentials, retries, execution history you can click through, an
error branch that fans out to ntfy — are exactly what n8n gives for free.
The parser itself stays plain JavaScript in the repo, tested outside n8n,
and is pasted into a Code node by a build script so the two cannot drift.

**Why regex first and an LLM second.** Bank SMS are templated: a dozen
regexes cover the common shapes deterministically, and deterministic is
what you want for money. The local Ollama is the fallback for the message
no template recognises, with a JSON schema on the response and a validator
that refuses any field not literally present in the text. It runs on the
same VM, so nothing leaves the LAN for the fallback either, and it is
`qwen2.5:7b-instruct` — a non-thinking model that fits the GPU — for the
reasons proposal 002 §4 and the Sure README learned the hard way.

## 3. Target architecture

```
iPhone                              Gmail (dedicated relay)          ciri (VM 150)
──────                              ───────────────────────          ─────────────────────────────────
HDFC SMS ─► Shortcuts automation ─► INBOX ◄──── IMAP IDLE ─────── n8n  "Relay inbox (IMAP)"
  "Message contains HDFC"            subject HDFC-SMS                    │  UNSEEN + SUBJECT filter
  → Send Email (no compose sheet)    body = the SMS                       ▼
                                                                    "Parse HDFC SMS" (Code)
                                                                      ok │ unparsed │ reject │ skip
                                                          ┌──────────────┘    │         │       └─ nothing
                                                          │                   ▼         │
                                                          │        "Ollama extract" ─► "Validate LLM output"
                                                          │            /api/chat, JSON schema    │ ok
                                                          ▼◄─────────────────────────────────────┘
                                                   "Create in Sure"  POST /api/v1/transactions
                                                     external_id + source → idempotent
                                                          │ 2xx                     │ error
                                                          ▼                         ▼
                                                   "Kuma push (heartbeat)"    "ntfy: needs review" ◄─ reject, LLM fail
```

| Piece | Where | Detail |
|---|---|---|
| Capture | iPhone, Shortcuts | personal automation: Message contains `HDFC` → Send Email, subject `HDFC-SMS`, Show Compose Sheet off. Built by hand ([shortcut/README](../../configs/ciri/n8n/shortcut/README.md)) |
| Relay inbox | Gmail, dedicated account | 2FA + app password, IMAP. Only the phone writes to it |
| Engine | ciri, `docker.io/n8nio/n8n:2.37.10` (published 2026-09-04) | host port **5678** (free on ciri 2026-09-04; not among 3000/3010/1337/8081/3474/5230/…). SQLite, `./n8n-data` on `/data` |
| Workflow | `configs/ciri/n8n/workflows/hdfc-sms-to-sure.json` | 11 nodes, generated by `build-workflow.js` from `parser/hdfc.js` |
| Parser | `configs/ciri/n8n/parser/hdfc.js` | noise gate, 10 HDFC templates, ref/last-4/date extractors, `toSure()`; 19 fixtures pass |
| LLM fallback | Ollama on ciri, `qwen2.5:7b-instruct` | `/api/chat` with `format` = JSON schema, `temperature 0`; validated before use |
| Sink | Sure on ciri, `POST /api/v1/transactions` | `X-Api-Key` (read_write); `external_id` + `source: hdfc-sms`; tag `auto:sms` |
| Route | Caddy LXC 202 | `n8n.kaermorhen.fyi` → `.150:5678` (Appendix A); Pi-hole `dns.hosts` → `.202` |
| Monitors | Kuma LXC 104 | HTTP on `/healthz` by IP; Push `n8n-hdfc-ingest`, 48 h heartbeat |
| Alerts | ntfy.sh, the lab topic | every reject / unparsed-after-LLM / HTTP error, raw SMS in the body |

## 4. Where the bank data actually goes

Say it plainly, because this is the section that matters.

- **The phone's Mail outbox**, then **Google's servers** (the relay Gmail).
  This is the one hop outside the lab, and it is the direct consequence of
  the user's decision not to depend on Tailscale. Mitigations: the account
  exists for nothing else, has 2FA, and its app password sits only in n8n's
  encrypted store and `secrets.local.yaml`. Mails are marked read, not
  deleted, so the inbox is also a raw audit log; a Gmail filter can
  auto-delete after 30 days if that log is unwanted.
- **n8n's execution history** on `/data/stacks/n8n/n8n-data/` holds the
  SMS text of every run for 7 days (`EXECUTIONS_DATA_MAX_AGE=168`), then
  prunes. It rides the nightly PBS job like the rest of `/data`.
- **Ollama**, same VM, fallback path only, nothing persisted.
- **Sure's Postgres** is the durable copy, with the raw SMS in the
  transaction's notes so a wrong parse can be audited from the row itself.
- **Nowhere else.** n8n's telemetry, version checks, template gallery and
  personalisation survey are all off in `compose.yaml`; the ntfy messages
  contain the SMS text but go to the same secret topic every other lab
  alert uses.

## 5. Access, secrets

**n8n's own login gates the editor**, and Caddy stays a plain proxy — the
same argument as proposals 008 §4 and 009 §5: the port on `.150` bypasses
whatever the proxy adds. `N8N_SECURE_COOKIE=true` (the default, set
explicitly) means the session cookie is only ever set over HTTPS, so the
bare port literally cannot log in; the editor is reached at
`https://n8n.kaermorhen.fyi` only.

**The Sure API key has family-wide write scope.** There is no per-account
key. The parser's refusal to route an unknown last-4 is therefore the only
guard against writing into the wrong account, which is why it rejects
rather than defaults.

Keys to add to `secrets.local.yaml`:

| Key | Purpose |
|---|---|
| `RELAY_MAILBOX` | the dedicated Gmail address |
| `RELAY_MAILBOX_APP_PASSWORD` | its app password (entered as the n8n IMAP credential) |
| `N8N_ENCRYPTION_KEY` | `openssl rand -hex 32`; in `.env`; losing it loses every n8n credential |
| `N8N_OWNER_EMAIL` / `N8N_OWNER_PASSWORD` | the editor's owner account, created on first login |
| `SURE_API_KEY_N8N` | Sure → Settings → API Keys, `read_write` (entered as the n8n Header Auth credential) |
| `SURE_ACCOUNT_ID_SAVINGS` / `SURE_ACCOUNT_ID_CC` / `SURE_TAG_ID_AUTO_SMS` | from `GET /api/v1/accounts` and the tag's edit URL; in `.env` |
| `HDFC_SAVINGS_LAST4` / `HDFC_CC_LAST4` | in `.env`; the routing table |
| `KUMA_PUSH_URL_N8N_HDFC` | the push monitor's URL; in `.env` |

## 6. The message model — what the parser promises

`parser/hdfc.js` turns one SMS into exactly one of four outcomes:

| Status | Meaning | Goes to |
|---|---|---|
| `ok` | a template matched and amount, date, last-4, kind are all present, and the last-4 is a configured instrument | Sure |
| `skip` | not a transaction: OTP, "will be debited", mandate, offer, failed/declined, balance enquiry, not HDFC | nothing |
| `unparsed` | money-movement words and an amount, but no template | Ollama, then the validator |
| `reject` | a template matched but a field is missing, or the instrument is unknown | ntfy, with the raw SMS |

Rules that are load-bearing:

- **Sign**: savings debit → `nature: expense`, savings credit → `income`;
  card spend → `expense` on the credit-card account; card payment or
  refund → `inflow` (it reduces a liability; calling it income would
  inflate the income statement). Amounts are always posted positive; Sure
  applies the sign from `nature`.
- **`external_id`**: `ref:<bank ref>` when the SMS carries a UPI/RRN/NEFT/
  IMPS reference, else `sha:<sha256 of the whitespace-normalised text>`.
  Card spends carry no reference, so two identical card SMS on the same day
  (same amount, merchant, timestamp to the second) would collapse into one —
  the timestamp makes this vanishingly rare, and the alternative (no
  idempotency for cards) is worse.
- **Never guess an account.** A last-4 that is neither configured value is
  a `reject`, not a default. This is the guard described in §5.
- **The LLM's answer is checked against the text**: the amount must appear
  in the SMS with or without separators, the last-4 must appear, the
  reference is only kept if it appears, `is_transaction:false` is a `skip`.
  Anything else is a `reject`. The model can only ever *choose* among
  strings that are in the message; it cannot invent one that reaches Sure.
- **Noise before templates.** The gate runs first so that an OTP mentioning
  "Rs." can never match a template by accident.
- **Names** are the counterparty as the SMS states it (`SWIGGY`,
  `grocer@okaxis`, `ACME PVT LTD-SALARY AUG`); Sure's rules and its local-AI
  categorisation take it from there. `notes` carries channel, reference,
  template id and the raw SMS.

Templates in phase 1 (all synthetic until A4): UPI sent, UPI debited-to-VPA,
account debited, account credited/deposited, UPI received, card spent,
credit-card payment received, refund/reversal, ATM withdrawal. **The
fixtures are written in the shapes HDFC alerts are commonly reported to
take, not copied from a real inbox.** A4 replaces them; until then a
template that passes the suite can still miss the bank's real wording, and
the `unparsed` → LLM → ntfy path is what catches that.

## 7. Resource budget

| Item | Cost | Against |
|---|---|---|
| n8n image | ~450 MB on `/data` | ~67 GB free on 2026-09-02 |
| n8n runtime | 300–500 MB RSS idle, one Node process plus the task runner | ciri has ~20 GB headroom |
| Execution history | KB per run, pruned at 7 days | negligible |
| Ollama fallback | loads `qwen2.5:7b-instruct` (4.8 GB VRAM) on demand; ~10–40 s per call | shares the 1060 with Jellyfin and Open WebUI (`OLLAMA_MAX_LOADED_MODELS=1`): a fallback call evicts whatever model is resident. Rare by construction |
| Gmail | free tier, a few hundred small mails a month | — |

Nothing here competes for disk bandwidth or the media path.

## 8. Monitoring, backups, maintenance

- **Kuma** (LXC 104): HTTP monitor on `http://<LAN_PREFIX>.150:5678/healthz`
  (200 without auth) and a **Push** monitor `n8n-hdfc-ingest` with a
  **48 h** heartbeat fed after every successful Sure write. Silence means
  "no transactions" or "dead pipeline"; the HTTP monitor tells them apart.
  Per [uptime-kuma.md](../uptime-kuma.md): *a monitor that has never been
  green has only been created* — test C2 makes it green before it is
  trusted. Kuma is addressed by IP, so no `/etc/hosts` line on 104 is needed.
- **ntfy** is the human-in-the-loop path, not a monitor: every `reject`,
  every failed LLM validation, every non-2xx from Sure or Ollama.
- **Beszel** already reports the container through ciri's agent.
- **Backups**: `/data/stacks/n8n/` rides geralt's nightly PBS job. The
  workflow is regenerated from the repo, not exported, so a restore needs
  only `n8n-data/` plus `N8N_ENCRYPTION_KEY` from `.env`.
- **Maintenance**: one row in the version registry in
  [maintenance.md](../maintenance.md), tier 1, bumped in the quarterly ciri
  pass. n8n ships weekly; stay on the `2.37.x` line until the next pass and
  re-check the three env facts in §10 on any minor bump.

## 9. Alternatives considered

| Candidate | Why not |
|---|---|
| **Tailscale webhook** (Shortcut POSTs to ciri) | the first design offered; declined by the user because the VPN is not always on. Kept as the fallback if A3a fails (§10) |
| **Account Aggregator** (Sahamati / Finvu / OneMoney) | consented statement pulls exist, but only regulated FIUs may request data. An individual cannot register; a self-hosted app cannot be an FIU |
| **NetBanking scraping** | against the terms of service, breaks on every UI change, and every login needs an OTP that lands on the same phone the SMS does |
| **HDFC's monthly statement email** | a month of latency; useful later as a reconciliation source, not as the feed |
| **HDFC's per-transaction alert emails** | real, and they cover the sub-threshold UPI amounts SMS no longer does — but the user wants SMS first and email checked later. The same workflow takes a second extractor; follow-up |
| **SMS-forwarder apps** | Android only. iOS exposes SMS to third parties solely through Shortcuts' Message trigger |
| **Bespoke Python service** (FastAPI + IMAP + SQLite) | offered and viable; the user chose n8n. The parser is the same code either way |
| **Adapting smartMoney** (Laravel, Firefly III) | proves the regex-plus-LLM shape works, but drags in PHP, MySQL and a Firefly adapter for nothing this design needs |
| **Sure's CSV Imports API as the primary path** | needs a CSV that only a human can generate from the HDFC app; becomes the reconciliation follow-up |

## 10. Gotchas and pre-flight facts for the executing agent

Verified on 2026-09-04 unless marked otherwise.

1. **Sure 0.7.3 has the idempotency this design leans on.** Read from the
   `v0.7.3` tag of `we-promise/sure`: `transactions_controller.rb` looks up
   `account.entries.find_by(external_id:, source:)`, returns the existing
   entry with 200 on a repeat, and rescues `RecordNotUnique`. `source` given
   without `external_id` is a 422. Re-verify on every Sure upgrade.
2. **iOS is the unknown.** Message automations can run without
   confirmation and Send Email sends silently with the compose sheet off —
   both documented — but whether the pair runs *on a locked phone* for the
   user's Mail account is only knowable by trying. That is A3a, and it is
   the go/no-go. If it fails, the fallback is the Tailscale webhook variant
   of the same automation, and this file's deviations section says so.
3. **The Shortcut filters on text, not sender.** HDFC's sender IDs
   (`VM-HDFCBK`, `AD-HDFCBK`, …) vary by route and are not phone numbers, so
   a contact filter misses some. "Message contains HDFC" catches them all
   and the parser's noise gate discards the rest.
4. **n8n 2.x runs Code nodes in a task runner** where built-in modules are
   blocked; `NODE_FUNCTION_ALLOW_BUILTIN=crypto` is required for the
   sha256 fallback id. `N8N_RUNNERS_ENABLED` is deprecated in 2.x and not
   set. `N8N_BLOCK_ENV_ACCESS_IN_NODE` defaults to `false` and is set
   explicitly because the workflow reads its whole configuration from `$env`.
5. **`WEBHOOK_URL` was renamed `N8N_WEBHOOK_URL` in 2.35.** The old name
   still works with a warning; the compose file uses the new one.
6. **n8n's expression tokenizer ends at the first `}}`.** The Ollama request
   body is one big `={{ JSON.stringify({...}) }}` expression containing a
   JSON schema; `build-workflow.js` pretty-prints the schema so nested
   braces never sit adjacent, and it throws if a stray `}}` appears. Do not
   hand-edit that node in the UI and re-export — regenerate.
7. **The IMAP trigger's "Custom Email Config" is node-imap search syntax**:
   `["UNSEEN", ["SUBJECT", "HDFC-SMS"]]`. It uses IMAP IDLE (`onmail`), so
   delivery is seconds, with a forced reconnect every 60 min. Gmail needs
   2FA and an app password; plain-password IMAP no longer exists.
8. **`$('Parse HDFC SMS').item` needs per-item mode.** The LLM validator
   runs "once for each item" so n8n's paired-item tracking resolves the
   right source record across the HTTP node; in all-items mode the indices
   would not line up because the Switch had filtered the list.
9. **Sure's family currency must be INR.** The body sends `currency: INR`;
   if the family is set to anything else, every row becomes a foreign-
   currency transaction. Check Settings → Preferences before B2.
10. **Fallback dates are computed in IST.** When an SMS carries no date the
    parser uses the mail's Date header shifted +5:30 before taking the day,
    so a 01:00 IST alert does not land on the previous day. The SMS date
    always wins when present.
11. **Own-account transfers create two rows** (savings debit + card inflow
    when paying the card bill). Sure's transfer matching pairs them; not
    solved here.
12. **HDFC does not SMS small UPI amounts** (below ₹100 sent / ₹500 received
    since 2024). Those are invisible to phase 1. The email follow-up covers
    them.
13. **The bare port cannot log in, by design.** `N8N_SECURE_COOKIE=true`
    shows a "secure cookie" notice at `http://<LAN_PREFIX>.150:5678`. Use
    the HTTPS name. Do not "fix" it by setting the variable to false.
14. **Execution history contains bank SMS text.** Pruned at 7 days; if that
    is too long, `EXECUTIONS_DATA_MAX_AGE` is the knob. Setting
    `EXECUTIONS_DATA_SAVE_ON_SUCCESS=none` would remove the ability to see
    *why* a row was created, which is worth more than the privacy delta on a
    disk that is already inside the lab.
15. **The fixtures are synthetic** (§6). Treat a green suite as "the code
    does what the fixtures say", not "the code understands HDFC".

---

# RUNBOOK

The Mac is the working copy; **every step below that changes the lab, the
phone, Gmail or Sure is run by the human.** File paths on the Mac are
relative to the repo root.

## Phase A — the phone side and the relay inbox (go/no-go)

### A1. Relay mailbox

1. Create a new Google account used for nothing else. Turn on 2-Step
   Verification. Create an **App password** (Google Account → Security →
   2-Step Verification → App passwords) named `n8n`.
2. Record `RELAY_MAILBOX` and `RELAY_MAILBOX_APP_PASSWORD` in
   `secrets.local.yaml`.
3. Optional now, recommended later: a Gmail filter `subject:HDFC-SMS older_than:30d`
   → delete, once the pipeline is trusted.

### A2. The Shortcut

Build it exactly as [configs/ciri/n8n/shortcut/README.md](../../configs/ciri/n8n/shortcut/README.md)
describes: Message trigger, *contains* `HDFC`, Run Immediately, Notify off;
one Send Email action to `RELAY_MAILBOX`, subject `HDFC-SMS`, body =
Shortcut Input, Show Compose Sheet **off**.

### A3. Spike checks — the go/no-go

| # | Do | Pass |
|---|---|---|
| A3a | Lock the phone, make a small UPI payment | a mail with subject `HDFC-SMS` and the SMS as its body is in the relay inbox within a minute |
| A3b | Reboot, unlock once, lock, pay again | same |
| A3c | Wi-Fi and mobile data off, receive an SMS, turn data back on | the mail arrives once online (Mail queues it) |

If A3a fails on the locked screen, try the iCloud account as the *From*
account first; if it still fails, stop here and record it under "As-built
deviations" — the fallback is the Tailscale-webhook variant, which is a
different Phase B.

### A4. Fixtures from the real inbox

Copy ~30 real HDFC alerts covering UPI sent/received, card spend,
NEFT/IMPS credit, ATM, card payment, refund, and at least five
non-transactions into `configs/ciri/n8n/parser/fixtures/private/real.txt`
(git-ignored) in the fixture format. Redact a representative set into
`parser/fixtures/hdfc-sms.txt`. Then, on the Mac:

```bash
cd configs/ciri/n8n
docker run --rm -v "$PWD:/w" -w /w node:22-alpine node parser/run-fixtures.js
```

Fix templates until it is green, then regenerate the workflow:

```bash
docker run --rm -v "$PWD:/w" -w /w node:22-alpine node workflows/build-workflow.js
```

## Phase B — the stack on ciri, the Sure key, the workflow

### B1. Directories and files

```bash
# ciri
sudo mkdir -p /data/stacks/n8n/n8n-data
sudo chown ciri: /data/stacks/n8n
sudo chown -R 1000:1000 /data/stacks/n8n/n8n-data     # the image's `node` user
```

```bash
# Mac → ciri
scp configs/ciri/n8n/compose.yaml lab-ciri:/data/stacks/n8n/compose.yaml
scp configs/ciri/n8n/.env.example lab-ciri:/data/stacks/n8n/.env
```

```bash
# ciri — fill in every <PLACEHOLDER> and <LAN_PREFIX>, then:
chmod 600 /data/stacks/n8n/.env
openssl rand -hex 32     # → N8N_ENCRYPTION_KEY, also into secrets.local.yaml
```

`SURE_ACCOUNT_ID_*`, `SURE_TAG_ID_AUTO_SMS` and `KUMA_PUSH_URL` are not
known yet; leave the placeholders for B2/C3 — compose fails loudly on the
`:?` ones, which is the point. Set `KUMA_PUSH_URL=` (empty) for now.

### B2. Sure: API key, tag, account ids

1. Sure → Settings → **API Keys** → create, scope **read/write**, name
   `n8n-hdfc-ingest` → `SURE_API_KEY_N8N` in `secrets.local.yaml`.
2. Settings → **Tags** → create `auto:sms`. The id is the UUID in the tag's
   edit URL → `SURE_TAG_ID_AUTO_SMS`.
3. Settings → Preferences: confirm the family currency is **INR** (§10 item 9).
4. Account ids (read-only, from the Mac or ciri):

```bash
curl -s -H "X-Api-Key: $SURE_API_KEY_N8N" http://<LAN_PREFIX>.150:3000/api/v1/accounts \
  | python3 -c 'import sys,json; [print(a["id"], a["account_type"], a["name"]) for a in json.load(sys.stdin)["accounts"]]'
```

Put the savings and credit-card ids into `.env`.

### B3. Bring it up

```bash
# ciri
cd /data/stacks/n8n
docker compose config >/dev/null      # every ${VAR:?} satisfied?
docker compose pull
docker compose up -d
docker compose logs --tail 50 n8n     # wait for "Editor is now accessible"
curl -s http://127.0.0.1:5678/healthz # {"status":"ok"}
docker exec ollama ollama list | grep qwen2.5   # the fallback model is present
```

*(verify, read-only)* `docker ps --filter name=n8n` shows `healthy`.

### B4. Owner account, credentials, workflow — in the n8n UI

The editor is only reachable over HTTPS (§5), so **do C1 and C2 first**,
then open `https://n8n.kaermorhen.fyi`:

1. First visit creates the **owner** account → `N8N_OWNER_*` in
   `secrets.local.yaml`.
2. **Workflows → Import from File** → `configs/ciri/n8n/workflows/hdfc-sms-to-sure.json`.
3. Open **Relay inbox (IMAP)** → Credential → create *IMAP*: host
   `imap.gmail.com`, port `993`, SSL/TLS on, user `RELAY_MAILBOX`, password
   the app password.
4. Open **Create in Sure** → Credential → create *Header Auth*: name
   `X-Api-Key`, value `SURE_API_KEY_N8N`.
5. Save, then **Activate** the workflow.

## Phase C — proxy, DNS, Kuma

### C1. Caddyfile (LXC 202) — Appendix A, then

```bash
caddy adapt --config /etc/caddy/Caddyfile && set -a && . /etc/caddy/cloudflare.env && set +a \
  && caddy validate --config /etc/caddy/Caddyfile && systemctl reload caddy
```

### C2. Pi-hole record (pihole-1 only; replace-not-append — read first)

```bash
pct exec 101 -- pihole-FTL --config dns.hosts       # current array
pct exec 101 -- pihole-FTL --config dns.hosts '[ …all existing…, "<LAN_PREFIX>.202 n8n.kaermorhen.fyi" ]'
# ciri: force the sync to pihole-2
docker compose -f /data/stacks/nebula-sync/compose.yaml run --rm sync-now
```

### C3. Kuma monitors (LXC 104 UI)

1. **HTTP** `n8n` → `http://<LAN_PREFIX>.150:5678/healthz`, 60 s, ntfy on.
2. **Push** `n8n-hdfc-ingest` → heartbeat **172800** s, retries 0, ntfy on.
   Copy the push URL **without** the `?status=up…` query (uptime-kuma.md
   explains why) into `.env` as `KUMA_PUSH_URL`, then on ciri:
   `docker compose up -d` to re-read the environment.

## Phase D — verification (the contract tests)

| # | Test | Pass |
|---|---|---|
| D1 | `docker run … node parser/run-fixtures.js` on the Mac | every fixture passes, including the real ones from A4 |
| D2 | Idempotency, directly against Sure (human runs, then deletes the probe row in the UI): the `curl` below **twice** | first `201`, second `200`; exactly one "idempotency probe" row in Sure |
| D3 | From the phone's Mail app, send the relay a mail with subject `HDFC-SMS` and a fixture SMS as the body | an n8n execution within a minute; a Sure transaction with the right account, sign, date and the `auto:sms` tag; Kuma push turns **green** |
| D4 | Send the same mail again | execution runs, "Create in Sure" shows `statusCode: 200`, no second row |
| D5 | Send the unknown-instrument fixture (`x5555`) | no Sure row; an ntfy "needs review (reject: unknown-instrument:5555)" with the SMS text |
| D6 | Send a reworded transaction no template knows | execution goes through "Ollama extract" and "Validate LLM output"; either a correct Sure row **or** an ntfy — never silence. Note the Ollama call time |
| D7 | A real UPI payment, phone locked | the row appears in Sure; record the observed minutes here |
| D8 | `docker compose stop n8n`, make a payment, wait 5 min, `docker compose start n8n` | the queued mail is fetched on reconnect and the row appears |
| D9 | `http://<LAN_PREFIX>.150:5678` in a browser | the secure-cookie notice, no login form; `https://n8n.kaermorhen.fyi` logs in with a valid certificate on the phone |
| D10 | `docker stop n8n` for 2 minutes | Kuma `n8n` goes down → ntfy; recovers on start |

The D2 probe:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  -H "X-Api-Key: $SURE_API_KEY_N8N" -H 'Content-Type: application/json' \
  http://<LAN_PREFIX>.150:3000/api/v1/transactions \
  -d '{"transaction":{"account_id":"<SURE_ACCOUNT_ID_SAVINGS>","date":"2026-09-04","amount":1,"name":"idempotency probe","nature":"expense","external_id":"probe:1","source":"hdfc-sms"}}'
```

## Phase E — as-built mirroring (only after D passes)

- `scp lab-ciri:/data/stacks/n8n/compose.yaml configs/ciri/n8n/compose.yaml`
  and confirm `git diff` on it is empty (the mirror rule).
- If any template changed on ciri's side of the world (it should not have —
  the parser only changes on the Mac), regenerate and re-import.
- Flip **planned → built** in: this file's Status; `configs/ciri/n8n/README.md`;
  the `n8n` rows in [docker-vm.md](../docker-vm.md),
  [maintenance.md](../maintenance.md) and [uptime-kuma.md](../uptime-kuma.md);
  the "API integrations" note in `configs/ciri/sure/README.md`.
- This file: fill "As-built deviations" with what D7 measured and anything
  A3 taught.

## As-built deviations

*(empty — nothing has been deployed yet)*

## Follow-ups (not in scope)

- **HDFC's alert emails as a second source.** Every UPI transaction is
  emailed, including the ones below the SMS thresholds. A Gmail filter on
  the personal account forwards them to the relay inbox; the workflow gets
  a second branch keyed on the sender. Needs a look at the real email
  format first.
- **Reconciliation.** A watched folder on ciri for the HDFC CSV the app can
  export → Sure's Imports API, or a matcher on `ref:` / amount+date against
  `GET /api/v1/transactions`, to catch anything the phone missed.
- **Investments.** CAMS/KFintech consolidated statements (casparser) into
  Sure holdings. Different data, different pipeline.
- **Homepage tile** for n8n in proposal 008's Apps group.
- **Categorisation.** Sure's rules engine on `name`, or its AI
  auto-categorisation via the local Ollama, once a few weeks of real
  merchant strings have accumulated.

---

# Appendix A — Caddyfile block (→ LXC 202 `/etc/caddy/Caddyfile`)

Already added to the repo mirror at `configs/yennefer/proxy/Caddyfile`
(under "Automation"):

```caddyfile
	# ---- Automation (proposal 010) ------------------------------------------

	@n8n host n8n.kaermorhen.fyi
	handle @n8n {
		# n8n's own login gates the editor. HTTPS here is load-bearing, not
		# cosmetic: N8N_SECURE_COOKIE=true means the session cookie is only
		# ever set over TLS, so the bare port on .150 cannot log in at all.
		# Editor and execution views use WebSockets; Caddy proxies them
		# without extra directives.
		reverse_proxy <LAN_PREFIX>.150:5678
	}
```

# Appendix B — the stack files

Not duplicated here to avoid drift; they are the deliverable:

| File | Lands at |
|---|---|
| `configs/ciri/n8n/compose.yaml` | `ciri:/data/stacks/n8n/compose.yaml` |
| `configs/ciri/n8n/.env.example` | `ciri:/data/stacks/n8n/.env` (filled in, 600) |
| `configs/ciri/n8n/workflows/hdfc-sms-to-sure.json` | imported in the n8n UI |
| `configs/ciri/n8n/parser/hdfc.js` | embedded in the workflow by `build-workflow.js`; never copied by hand |
| `configs/ciri/n8n/shortcut/README.md` | the phone, by hand |

## Sources

- Sure API — transactions: <https://we-promise-sure-88.mintlify.app/api/transactions>;
  accounts: <https://we-promise-sure-88.mintlify.app/api/accounts>;
  imports: <https://we-promise-sure-88.mintlify.app/api/imports>
- Sure `v0.7.3` `app/controllers/api/v1/transactions_controller.rb` (external_id / source idempotency): <https://github.com/we-promise/sure/blob/v0.7.3/app/controllers/api/v1/transactions_controller.rb>
- Apple — automations that can run without asking: <https://support.apple.com/en-au/guide/shortcuts/apd602971e63/ios>;
  communication triggers: <https://support.apple.com/en-au/guide/shortcuts/apdd711f9dff/ios>
- Forward SMS to a webhook with Shortcuts (the Message-trigger recipe): <https://dev.to/noha1337/forward-sms-to-webhook-with-iphone-shortcut-automations-4d6>
- HDFC InstaAlert: <https://www.hdfc.bank.in/ways-to-bank/digital-banking/phone-banking/instaalerts>;
  SMS thresholds for UPI (2024): <https://www.business-standard.com/finance/personal-finance/hdfc-bank-to-stop-sms-alerts-for-upi-payments-up-to-rs-100-check-details-124052901252_1.html>
- n8n docs export (env vars, task runners, 2.x breaking changes): <https://docs.n8n.io/llms-full.txt>;
  Email Trigger (IMAP): <https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.emailimap/>;
  Remove Duplicates: <https://docs.n8n.io/integrations/builtin/core-nodes/n8n-nodes-base.removeduplicates/>;
  EmailReadImap v2 source (IDLE, `customEmailConfig`): <https://github.com/n8n-io/n8n/blob/master/packages/nodes-base/nodes/EmailReadImap/v2/EmailReadImapV2.node.ts>
- n8n image tags (2.37.10 = `stable`, 2026-09-04): <https://hub.docker.com/r/n8nio/n8n/tags>
- Ollama structured outputs: <https://ollama.com/blog/structured-outputs>
- Prior art for regex-plus-LLM SMS parsing: <https://github.com/mrahmadt/smartMoney>,
  <https://github.com/MabudAlam/transaction_sms_parser>,
  <https://github.com/saurabhgupta050890/transaction-sms-parser>
