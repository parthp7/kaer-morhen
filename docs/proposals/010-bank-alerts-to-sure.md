# Proposal 010 — Bank alerts to Sure: HDFC SMS → relay mailbox → n8n → Sure

- **Status**: **BUILT and verified** (2026-09-08). Phases A–E executed on
  the live lab; every check in the execution checklist passed, and what each
  one actually returned is in "As-built deviations" below. The pipeline has
  been running unattended since 2026-09-08 and has captured real
  transactions. Measured end to end: **SMS to Sure row in under 1 min 30 s**
  with the phone locked (D7). Five defects were found by running it that the
  fixture suite could not catch — see the deviations.
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
| `HDFC_SAVINGS_LAST4` / `HDFC_CC_LAST4` / `HDFC_DEBIT_CARD_LAST4` | in `.env`; the routing table. The debit card is a third last-4 that routes to the **savings** account: ATM and POS alerts name the card, not the account (found in A4) |
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

Recorded as each checklist step's *Verify* actually returned. Dates are the
day the step ran, not the day it was designed.

- **A1 (2026-09-06) — pass, no deviation.** Relay Gmail created with 2-Step
  Verification and an app password named `n8n`. `grep -c RELAY_MAILBOX
  secrets.local.yaml` returned `2`; both keys carry non-empty values (the
  app password is the expected 16 characters, spaces stripped).
  `secrets.local.yaml` is mode `600` and matched by `.gitignore:1`
  (`secrets.local.*`), so no value is tracked. The optional "delete
  `subject:HDFC-SMS older_than:30d`" Gmail filter was deliberately **not**
  created: the inbox stays the raw audit log while Phase D is being
  verified.
- **A2 (2026-09-07) — pass, one deliberate choice.** The Message automation
  was built as specified (sender empty, *Message Contains* `HDFC`, Run
  Immediately, Notify off; one Send Email action, subject `HDFC-SMS`, body =
  Shortcut Input, Show Compose Sheet off) and is listed under Shortcuts →
  Automation. **The *From* account is iCloud** — §10 item 2's first
  documented fallback was taken up front rather than held in reserve, so a
  later A3a failure cannot be blamed on the sending account. A first test
  transaction produced a mail in the relay inbox.
- **A3a (2026-09-07) — PASS. The go/no-go clears.** §10 item 2's one
  knowingly-unverified assumption is now verified on the real device: with
  Wi-Fi and mobile data on, Low Power Mode on, the phone locked and never
  touched, the HDFC SMS produced a mail in the relay inbox within about a
  minute. The Tailscale-webhook fallback (§9, §10 item 2) is **not**
  needed and Phase B proceeds as designed.
  *First attempt was discarded as inconclusive, not failed*: it changed
  connectivity and lock state together (data + Wi-Fi off, locked, then
  unlocked and data on), so a mail that left only after the unlock was
  equally consistent with "Mail queued it for the network" and with "iOS
  refused Send Email on the lock screen". The re-run changed nothing but
  the lock, which is what made it decisive. Worth remembering for any
  future phone spike: test one variable at a time, because both worlds
  produce an identical inbox.
- **A3c (2026-09-07) — pass, out of order.** Covered by that first attempt:
  with Wi-Fi and mobile data off, the automation ran and Mail held the
  message; it was delivered once the phone was back online. Low Power Mode
  was on throughout and changed nothing. Not re-run after A3a, since A3a
  proved the lock is not the gate and the queueing behaviour was never in
  doubt.
- **A3b (2026-09-07) — pass, with a latency caveat worth keeping.** After a
  reboot and the one required post-boot unlock, the phone was locked and a
  payment made; the mail arrived, but the automation did not run for about
  **3–4 minutes** after the SMS landed (the phone was picked up, unlocked
  and used during the wait, so this is "iOS deferred it while busy", not
  "iOS never ran it"). Not a failure: §1 accepted "minutes, not real-time",
  and the Kuma push monitor's heartbeat is 48 h, so a deferral of this size
  raises no alarm and loses no message. It does mean **D7's measured
  latency should not be read as a bound** — a freshly rebooted or busy
  phone can add minutes ahead of anything the lab does.
- **Mail shape confirmed (2026-09-07).** On the mails already in the relay
  inbox the subject is exactly `HDFC-SMS` and the body is the full SMS
  text — so the Shortcut Input variable is bound correctly and the IMAP
  filter `["UNSEEN", ["SUBJECT", "HDFC-SMS"]]` will match. This removes the
  two silent-failure modes (blank body, drifted subject) that would
  otherwise have surfaced as an unexplained D3.
- **A4 (2026-09-07) — pass, after five parser fixes and one design decision.**
  18 real messages were collected (not the ~30 asked for; the missing shapes
  are noted below). **Every one of the 19 synthetic fixtures passed and, on
  the first run, every real transaction message failed.** §10 item 15 said a
  green synthetic suite means "the code does what the fixtures say"; this is
  what that looks like in practice.

  *Checklist contradiction found.* The amended A4 row requires one runner
  invocation with the real last-4s injected, and also requires the tracked
  fixtures to keep using `1234`/`9876`. Both cannot hold: with real values in
  the environment the 11 synthetic `ok` blocks reject as
  `unknown-instrument`, which is what produced a misleading `19/32 — 13
  FAILED` before the files were separated. The two files must be run
  separately, which is now documented in `run-fixtures.js` and the stack
  README. **The same contradiction applies verbatim to D1**, whose command
  takes no file argument: run as written today it reports `27/37 — 10
  FAILED` on a parser that is actually green.

  *What the real messages broke, and the fix in each case:*

  | Real shape | Was | Fix |
  |---|---|---|
  | `UPI Mandate: Sent Rs…`, `AutoPay (E-mandate) Success!` | `skip` (noise) | HDFC uses "mandate"/"autopay" for both announcements and completions. That vocabulary is now noise only when the message does not also say the debit executed (`EXECUTED` in `hdfc.js`) |
  | `AutoPay … Txn Amt:INR…` | `skip` (no-money-movement) | the money-movement gate knew no verb for it — the message says "Txn Amt", never "debited". Added, plus a new `autopay-card-success` template |
  | `DEAR HDFCBANK CARDMEMBER, PAYMENT OF…` | `skip` (not-hdfc) | `\bHDFC\b` has no word boundary inside "HDFCBANK", so a real card-payment alert was discarded as another bank's. Leading boundary only now; `card-payment-received` also learned the all-caps wording, which omits "HDFC Bank" before "CREDIT CARD" |
  | `Withdrawn Rs… From HDFC Bank Card x…` | `unparsed`, then `reject` | ATM alerts name the **debit card**, whose last-4 is neither configured instrument. New `atm-withdrawal-card` template and a third routing entry, `HDFC_DEBIT_CARD_LAST4` → the savings account |
  | `UPDATE: INR… debited from HDFC Bank XX…` | `skip` (noise) | the credit-card bill's savings leg. New `cc-bill-autopay-debit` template, named so the row is legible; `account-debited` also learned the bare "HDFC Bank XX1234" form and an "Info:" clause between date and balance |
  | `UPI Mandate: … A/c 1234` | `reject` (missing:last4) | `last4Of`'s account pattern was case-sensitive and matched neither "A/C" nor "a/c" for the mixed-case "A/c". Also added HDFC's "CC 9876" / "DC 4567" shorthand |

  *Design decision (2026-09-07).* HDFC reports a credit-card bill paid by
  standing instruction as two messages: the savings debit and the card
  payment. Both are now recorded, as §10 item 11 intended, and Sure pairs
  them. The user's first labelling kept only the card leg; recording one side
  of a transfer would have drifted the savings balance upward by the bill
  amount every month, so the design's position was kept.

  *Risk accepted.* One autopay card charge also arrives twice on the **same**
  card — as `Rs.X without OTP/PIN …` and as `AutoPay (E-mandate) Success!`.
  They share no reference, so `external_id` cannot pair them and one shape
  has to be dropped by rule. The `without OTP/PIN` shape is dropped, on the
  user's confirmation that ordinary contactless taps arrive as normal
  `Spent Rs.X On HDFC Bank Card …` messages. If HDFC ever reuses that wording
  for a standalone spend, it becomes a silent loss — the one place in this
  design where a message is discarded without a human seeing it.

  *Coverage still thin.* Six templates have no real-world example:
  `upi-received`, `account-debited`, `atm-withdrawal` (account-worded),
  `refund-reversal`, and the NEFT/IMPS credit shapes. The user has no refund
  in recent history; the rest are to be added iteratively as they occur, with
  the `unparsed` → ntfy path as the net. Treated as accepted, not closed.

  *Leak caught in review.* The first version of these fixes quoted the user's
  real messages verbatim in `hdfc.js` comments — real account last-4s, a real
  UPI reference and a real mandate id — which `build-workflow.js` then
  embedded into the tracked workflow JSON. All of it was redacted before
  anything was staged; a repo-wide `git grep` for each real value now returns
  nothing. The redacted tracked fixtures change every digit run, amount,
  balance and merchant name, keeping only the bank's wording and punctuation.

  *Final state:* `30/30` tracked fixtures and `18/18` private ones pass;
  `build-workflow.js` regenerates 11 nodes. Diff touches `parser/hdfc.js`,
  `parser/run-fixtures.js` (quoted `expect:` values, so multi-word
  counterparties can be asserted), `parser/fixtures/hdfc-sms.txt`,
  `workflows/build-workflow.js`, `workflows/hdfc-sms-to-sure.json` and
  `.env.example` — two files more than the checklist's "only
  parser/fixtures/workflow", both because of the new routing variable.
  `compose.yaml` gained the matching `HDFC_DEBIT_CARD_LAST4: ${HDFC_DEBIT_CARD_LAST4:-}`
  passthrough during the review — a gap in the first pass, which plumbed the
  variable everywhere except the one file that hands it to the container.
- **B1 (2026-09-07) — pass.** `/data/stacks/n8n` and `n8n-data` are
  `ciri:ciri`, which *is* `1000:1000` (ciri is uid 1000), so the image's
  `node` user owns its SQLite db and credential store; `.env` is `600`,
  `compose.yaml` hashes byte-identical to the repo mirror (E1's check for
  this file already satisfied); no live placeholders outside comments;
  no container started.

  *Deviation from the runbook, and it is the better behaviour.* B1 says to
  leave `SURE_ACCOUNT_ID_SAVINGS` / `SURE_ACCOUNT_ID_CC` as literal
  `<PLACEHOLDER>` text until B2. They were left **empty** instead. `${VAR:?}`
  fails on empty as well as unset, so the guard still fires — verified:
  `docker compose config` exits 1 naming exactly those two variables. Had the
  literal placeholder text been kept, `:?` would have been *satisfied* and the
  string `<SURE_ACCOUNT_ID_CC>` would have been injected into the container as
  a real account id. **The runbook's wording should say empty, not
  placeholder.**

  *Checklist Verify is weaker than it looks.* `grep -c "<" .env` → `2` was
  reported, but neither hit was a Sure account id: one was a `<LAN_PREFIX>`
  mention inside a header **comment** and the other a half-edited
  `KUMA_PUSH_URL`. The count matched the prediction for the wrong reasons.
  `grep -v "^#" .env | grep -c "<"` is the check that means something.

  *`KUMA_PUSH_URL` took three attempts*, all for the same reason: the `sed`
  was being run on the Mac, where `/data/stacks/n8n/.env` does not exist, so
  it changed nothing on ciri and reported nothing. An intermediate edit had
  removed only the `<KUMA_PUSH_TOKEN_N8N_HDFC>` token and left a truncated
  `…/api/push` URL — worse than either extreme, because `${KUMA_PUSH_URL:-}`
  accepts it silently and every heartbeat would have POSTed to a valid-looking
  endpoint that is not a monitor. Now empty, as C3 expects.
- **B2 (2026-09-07) — pass, and the runbook's tag instruction is wrong.**
  API key `n8n-hdfc-ingest` (read/write) created and recorded as
  `SURE_API_KEY_N8N`; family currency confirmed **INR** (§10 item 9). The two
  account ids in ciri's `.env` were checked against `GET /api/v1/accounts` and
  resolve to the `depository` account "HDFC" and the `credit_card` account
  "HDFC-Credit-card"; the tag id resolves to `auto:sms`. `docker compose
  config` now exits **0** — every `${VAR:?}` guard satisfied by supplying
  values, not by weakening the guard.

  *Runbook correction.* B2 step 2 says to create the `auto:sms` tag and "copy
  the UUID from its edit URL". On Sure 0.7.3 the tag editor is a **modal** —
  the URL never changes, so there is no id to copy. The route that works is an
  endpoint the proposal never mentions: **`GET /api/v1/tags`**, which returns
  `[{id, name, color, created_at, …}]` for every tag and accepts the same
  `X-Api-Key`. Useful beyond this step: `GET /api/v1/transactions` rows carry
  a `tags` array, `external_id` and `source`, so D3–D5 can assert the tag and
  the idempotency fields straight from the API rather than from the UI.

  *Process note.* Several B1/B2 commands were run on the Mac rather than on
  ciri — `/data/stacks/n8n/.env` does not exist there, so `sed -i` failed
  quietly and three rounds of "done" reported changes that had not happened.
  Every value in this phase is therefore verified by reading it back from
  ciri, never from the fact that a command was reported as run.
- **B3 (2026-09-07) — pass.** `n8nio/n8n:2.37.10` up and **healthy**,
  `0.0.0.0:5678->5678`, `/healthz` → `{"status":"ok"}` from inside the VM.
  `n8n-data/` initialised as uid/gid `1000` (`database.sqlite` plus its WAL,
  `config` mode 600). Log: `Recorded version change: (none) -> 2.37.10` and
  `Editor is now accessible via: https://n8n.kaermorhen.fyi` — the name C1/C2
  are about to make real. `qwen2.5:7b-instruct` (4.7 GB) present on Ollama, so
  B3's model check passed without a pull. The only two lines matching "error"
  are the migration `AddErrorColumnsToTestRuns`, not failures.

  *Deprecation to act on later, captured now.* Startup warns that
  **`N8N_RUNNERS_TASK_TIMEOUT` will drop from 300 s to 60 s** in a future
  version. §7 budgets the Ollama fallback at 10–40 s, but that is on a GPU
  shared with Jellyfin and Open WebUI where a fallback call may first evict a
  resident model. **D6 measures the real figure**; if it lands near a minute,
  pin `N8N_RUNNERS_TASK_TIMEOUT=300` in `compose.yaml` before the next n8n
  upgrade halves it silently and turns the fallback path into intermittent
  ntfy alerts. Same startup log also warns about
  `N8N_UNVERIFIED_PACKAGES_ENABLED` and two compression limits — none of them
  touch this workflow.
- **C1 (2026-09-07) — pass, verified narrowly and deliberately.** Caddy
  reloaded at 23:54:12 (`Reloaded caddy.service`, config adapted and POSTed to
  the admin API). The live `@n8n` block on LXC 202 is **byte-identical** to
  the repo mirror, tabs included, and points at `<LAN_PREFIX>.150:5678`; the
  file grew 239 → 250 lines, exactly the block plus its separator. A serve
  test with `curl --resolve`, bypassing DNS entirely since C2 had not run,
  returned **HTTP/2 200** under the existing `CN=*.kaermorhen.fyi` Let's
  Encrypt certificate (valid to 2026-11-10) — no new cert was issued, and
  D9's "valid certificate" half is effectively already proven.

  *C1's Verify as written cannot pass, for two reasons unrelated to n8n.*
  The checklist diffs the whole live Caddyfile against the repo mirror and
  expects empty. It never can:
  1. the live `tls` line carries the real ACME email while the mirror masks it
     as `<ACME_EMAIL>` per `CLAUDE.md`, and the verify's `sed` only masks the
     LAN prefix;
  2. **proposal 008's dashboard block has drifted**: live has it at line 110
     under a terse `# ---- Dashboard ----` header, the repo working tree at
     line 216 under `# ---- Dashboard (proposal 008) ---` with three lines of
     rationale. Same three routes and targets, different placement and
     comments — the mirror was hand-written and never reconciled with what was
     deployed.

  On the user's decision (2026-09-07), C1 was closed by verifying **the n8n
  block alone**, and the drift is left for proposal 008 to reconcile rather
  than being silently rewritten from inside 010. `systemctl show caddy -p
  ActiveEnterTimestamp` is *not* evidence of a reload — it reports the
  service's original start time and is unmoved by `systemctl reload`; the
  journal entry and a serve test are.
- **C2 (2026-09-08) — pass.** Both Pi-holes went **40 → 41** entries with
  nothing dropped, `n8n.kaermorhen.fyi` present on each; `dig` against
  `<LAN_PREFIX>.101` and `<LAN_PREFIX>.201` both answer `<LAN_PREFIX>.202`;
  `curl -sI https://n8n.kaermorhen.fyi` through real DNS returns **HTTP/2
  200**. nebula-sync propagated pihole-1 → pihole-2 on the first run.

  *How the array was built.* `dns.hosts` is replace-not-append, so a malformed
  write would drop all 40 internal names at once. Rather than retyping
  addresses, the new value was derived from the live one on the box: read the
  array, strip the brackets, re-quote each entry, append
  `"<proxy ip> n8n.kaermorhen.fyi"`, then a dry run asserting the count is 41
  and the tail is the new entry — with the previous value saved to a file
  first so a bad write is one command from undone. Worth reusing: the read
  format prints entries bare but the write expects them quoted.

  *Note for anyone repeating the verify:* **pihole-1 is LXC 101 on geralt,
  pihole-2 is LXC 201 on yennefer.** Running `pct exec 201` against geralt
  returns an empty config rather than an error, which reads exactly like "the
  sync failed" when in fact it is the wrong host.
- **B4 (2026-09-08) — pass, after three imports and one parser bug.**
  Workflow `HDFC SMS -> Sure` **active**, 11 nodes, both credentials bound to real
  ids, and an **ESTABLISHED socket to port 993** from the container — the
  proof that the Gmail app password actually authenticates, which no
  pre-activation check could give. Task runner visible on 5679, as 2.x
  expects.

  *Runbook correction: there is no "Activate" button in n8n 2.x.* The UI
  offers **Execute workflow** and **Publish**; publishing is what makes a
  trigger live, and "Execute workflow" would only run one manual fetch. The
  checklist and runbook both still say Activate. `active=1` in
  `workflow_entity` is the authority, not the button label.

  *The pipeline proved itself before it was meant to.* The first publish
  consumed a real unread alert and produced a correct Sure row: ₹55.00 on the
  savings account, `classification: expense`, `external_id:
  ref:<UPI_REF>` (the bank's own UPI reference, not a hash), tagged
  `auto:sms`. Most of D3 was demonstrated by accident.

  *Bug found by reading that row: the audit trail was empty.* `parseSms` built
  its `txn` **without `raw`**, while `toSure` composes notes from `txn.raw` —
  so every regex-parsed row carried `sms:` with nothing after it, losing the
  original text that §4 and §6 both promise for auditing a wrong parse. The
  LLM fallback sets `raw` itself, so only the *common* path was affected. No
  fixture asserted `notes`, so the suite stayed green through it. Fixed in
  `parser/hdfc.js`, and `run-fixtures.js` now enforces an **invariant** rather
  than a per-fixture key: any `ok` row whose notes do not contain the original
  SMS fails. Verified to bite — reverting the one-line fix turns `30/30` into
  `11/30`.

  *Import is fragile in a specific way.* Deleting the workflow and recreating
  it by **pasting** the JSON silently dropped `Create in Sure` — the one node
  carrying an unresolvable credential stub (`"id": "<SET IN UI>"`). The result
  imported cleanly as 10 nodes with no error. **Import from File** keeps all
  11. Publishing that 10-node version would have produced a pipeline that
  parsed every SMS, took the error branch, and wrote **nothing** to Sure while
  looking entirely healthy. Caught only because the node count is checked
  before publish; that check earns its place.

  *Autopay twins, revisited by the review.* The `without OTP/PIN` message is
  no longer dropped by rule. Both it and `AutoPay (E-mandate) Success!` now
  emit the same deterministic `external_id`
  (`autopay:<last4>:<date>:<amount>`), so Sure's idempotency keeps one row
  whichever arrives first, **and a lone charge with no twin is still
  captured** — removing the silent-drop risk recorded under A4. Verified: both
  templates emit `autopay:9876:2026-09-05:349.50`. The private fixture's stale
  `expect: skip` for that shape was updated to `ok`.
- **C3 (2026-09-08) — pass.** Kuma answers `302` on `<LAN_PREFIX>.104:3001`.
  `KUMA_PUSH_URL` is 67 characters, carries **no** `?status=` query and ends
  `/api/push/<token>`, as `uptime-kuma.md` requires. Checked both in `.env`
  **and via `printenv` inside the running container** — the file alone proves
  nothing, because `docker compose up -d` only re-reads the environment if it
  actually recreates the container, and `docker compose restart` would have
  left the previous empty value in place. It recreated (`Up 30 seconds`), the
  workflow stayed `active=1`, and the Gmail IDLE socket re-established on its
  own. Push monitor stays grey until the first successful Sure write (D3).
- **D1 (2026-09-08) — pass.** `30/30` tracked and `18/18` private fixtures.
  Rebuilding the workflow from the current parser produced a **byte-identical**
  JSON, so the committed file is not stale, and the live `Parse HDFC SMS` node
  hashes `de9c2a6243af801d` — the same as the repo's. The parser running in
  production is exactly the code the fixtures test.

  *D1's command inherits A4's contradiction.* As written it takes no file
  argument, so it runs the tracked and private fixtures together under one set
  of last-4s and reports `27/37 — 10 FAILED` against a green parser. Run as
  two invocations, as `run-fixtures.js` now documents.
- **D2 (2026-09-08) — pass. Idempotency proven on the live instance.** Two
  identical POSTs with `external_id: probe:1` and `source: hdfc-sms` returned
  **201 then 200**, and a search found exactly **one** row. §10 item 1 was
  read from the `v0.7.3` source; it is now observed behaviour on this
  deployment, which is what D4 and every re-delivered mail depend on. Probe
  row deleted; `hdfc-sms` baseline before D3 is one real row (₹55.00,
  carrying the bank's own UPI reference).
- **D3 (2026-09-08) — pass.** A `HDFC-SMS` mail sent from the phone's Mail app
  with the UPI-sent fixture produced execution id=2 (`success`, 0.46 s) and
  exactly one new Sure row: ₹500.00, **savings** account, `classification:
  expense`, `external_id: ref:123456789012` (the reference, not a hash), tag
  `auto:sms`, and **notes carrying the complete raw SMS**. That last field is
  the B4 fix proven in production: the same ledger now holds the ₹55 row from
  before the fix, whose notes still end at `sms:` with nothing after it — the
  two sit side by side as evidence.
- **D4 (2026-09-08) — pass.** The identical mail re-sent produced execution
  id=3 (`success`) and **no second row** — still one SWIGGY, two `hdfc-sms`
  rows in total. Idempotency now proven twice: directly against the API at D2,
  and through the whole pipeline here.

  *Kuma push, resolved sideways.* The push monitor had not gone green after
  D3/D4. Rather than create another transaction to force a heartbeat, the
  same mail was sent a **third** time: Sure returned 200 and created nothing,
  but the workflow still pushed its heartbeat, and the monitor went green
  (execution id=4). **A heartbeat is emitted on any successful write,
  including an idempotent 200** — which makes re-sending a known mail the
  cheapest way to exercise the push path without touching the ledger. Worth
  remembering for future monitor testing.

  *Unresolved detail:* the container reported `Up 21 minutes` across the
  push-URL edit, so `docker compose up -d` recreated nothing — meaning the URL
  pasted was identical to the one already present, and the monitor was
  correctly configured at C3 but had simply never received a heartbeat. Old
  and new URLs are both 67 characters, so length cannot distinguish them; the
  monitor's last-heartbeat timestamp is the only outside evidence. **Closed
  2026-09-08**: Kuma's last heartbeat reads 01:33:11 IST, which is execution
  id=4 (`20:03:11` UTC) — so the token in the container is the live monitor's
  and C3's configuration was correct all along.
- **D5 (2026-09-08) — pass.** The `x5555` message produced execution id=5
  (`success`, 0.73 s), an ntfy "needs review (reject: unknown-instrument:5555)"
  on the phone, and **no Sure row** — still 2 `hdfc-sms` rows, nothing named
  TEA STALL, no account touched but the two configured. The §5 guard fires:
  an unknown instrument is rejected to a human, never routed to a default.

  *Read the executions list correctly:* a reject shows **`success`**, not
  `error`. It is a designed outcome, not a failure — a red execution means the
  pipeline broke, while a rejected message is green and reaches the human by
  ntfy.
- **D6 (2026-09-08) — fallback proven, and it found a live silent-loss bug.**
  Execution id=6, `success`, **27.23 s** end to end, `qwen2.5:7b-instruct`
  resident at 100% GPU. The unparsed message reached Ollama, the validator
  confirmed the amount and last-4 both appear literally in the text, and a row
  was created — never silence, as designed.

  **`N8N_RUNNERS_TASK_TIMEOUT` is a non-issue**, contrary to the concern
  raised at B3: it governs Code-node execution, and both Code nodes here run
  in milliseconds. The Ollama call is an HTTP node with its own **180 s**
  timeout, so the 27 s measurement has ample headroom. No pinning needed.

  *The bug.* The validator's reference rule was *"must appear in the text"*
  and nothing more, so when the model returned **`Rs.640`** — the amount — as
  the reference, it was accepted and the row's `external_id` became
  `ref:Rs.640`. Since `external_id` is the duplicate guard, a later ₹640
  purchase on the same account taking the same fallback path would collide and
  be **silently swallowed as a repeat**. Same class of trap as the Mandate ID
  in §10, but on the path that had no shape check. The regex path was never
  exposed: `refOf()` only accepts UPI/RRN/NEFT/IMPS shapes.

  Fixed in `build-workflow.js`: a reference must now match
  `/^[A-Za-z]?\d{9,18}$/` — the same shape `refOf()` accepts — **and** appear
  in the text; anything else falls through to the `sha:` id, which is derived
  from the whole message and is unique per transaction.

  *Two things worth carrying forward.* First, the first attempt at that fix
  was wrong in a way that would have been invisible: `LLM_VALIDATE_CODE` is a
  **JS template literal**, so a lone `\d` is eaten as an escape and the
  generated regex became `/^[A-Za-z]?d{9,18}$/` — matching the letter `d` and
  rejecting every real reference. The surrounding code already writes `\\d`
  for this reason. Always read the *generated* node, not the builder source.
  Second, **the fixture suite cannot cover this code at all**: it exercises
  `parseSms`/`toSure`, while the LLM validator lives in `build-workflow.js`
  and is untested by anything. The rule was therefore checked behaviourally
  against `Rs.640`, `640`, `12345678`, `abc` and two genuine reference shapes.
  A validator test harness is a worthwhile follow-up.
- **D7 (2026-09-08) — pass. End-to-end latency: under 1 min 30 s.** A real UPI
  payment with the phone locked: SMS at **01:54 IST**, execution id=7 at
  **01:55:21 IST**, one correct row (₹1.00, savings, expense, the bank's own
  reference as `external_id`). The whole chain — Shortcut → iCloud Mail →
  Gmail → IMAP IDLE → parse → Sure — ran with no interaction.

  **Read this as one sample, not a bound.** A3b measured iOS deferring the
  automation 3–4 minutes after a reboot, and that delay is phone-side, before
  the lab is involved. The lab's own contribution here is the sub-second
  execution time; everything else is iOS scheduling and mail delivery.

  *Housekeeping:* the fictitious ₹640 `purchase` row was deleted, closing the
  `ref:Rs.640` collision hazard. Execution history restarted at id=7 because
  deleting a workflow deletes its executions — expected, and worth knowing
  before reading an empty list as a fault. The ₹500 SWIGGY row from D3/D4 is
  still present and should be removed once Phase D is finished (since deleted).
- **D8 (2026-09-08) — pass. Gmail-as-queue proven.** n8n was stopped
  `15:32:01Z` → `15:38:41Z` (**6 min 40 s**). A `HDFC-SMS` mail sent during
  the outage sat unread in Gmail and was collected **21 seconds after
  restart** (execution id=13, 21:09:02 IST), producing the expected row
  (₹150.00 "Queue test", `ref:123456789123`). IMAP re-established on its own.

  *Substitution, deliberate:* the checklist says to make a real payment during
  the outage. What D8 actually tests is that **Gmail holds unread mail and the
  IMAP trigger collects it on reconnect** — the phone half was already proven
  at D7 — so a self-sent mail exercises the same path without spending money.
  This rules out the quiet failure where the trigger only ever sees mail that
  arrives while it is connected, which would look perfectly healthy while
  missing every transaction during any outage.

  *What ~19 hours of unattended real traffic showed, unprompted.* By the end
  of 2026-09-08 the pipeline had captured five genuine transactions
  (a utility bill ₹612, two cafeteria meals, a subscription charge ₹149, a ₹1
  UPI) with **7 rows carrying 7 distinct `external_id`s** — the duplicate
  guard has collapsed nothing. Two design decisions are now confirmed on real
  money rather than fixtures:
  - the review's **autopay id scheme is live**: the real subscription charge
    carries `autopay:<card>:2026-09-08:149.00`, not the mandate id;
  - the **B4 notes fix holds** — every row carries its raw SMS except the
    ₹55.00 row of 2026-09-07, which predates the fix and stands as the control.
- **D9 (2026-09-08) — pass.** The bare port `http://<LAN_PREFIX>.150:5678`
  serves the SPA but shows the **secure-cookie notice** and cannot log in;
  `https://n8n.kaermorhen.fyi` logs in on the **phone** with a valid padlock
  (`CN=*.kaermorhen.fyi`, Let's Encrypt, to 2026-11-10). `/healthz` remains
  open without auth on the bare port, which is what the Kuma HTTP monitor
  needs. §5's claim — that the port on `.150` cannot be used to log in, so
  Caddy needs no auth layer of its own — is confirmed on the running system.

  *Limit of the read-only check:* an agent cannot prove this. Wrong
  credentials return `401` over both HTTP and HTTPS, and n8n renders the
  secure-cookie warning **client-side**, so it never appears in the served
  HTML. Only a real browser with a valid password distinguishes "refused
  because insecure" from "refused because wrong password". The phone was used
  deliberately: it has never had the certificate manually trusted, so it
  exercises the real chain.
- **D10 (2026-09-08) — pass.** `docker stop` → `docker start` with the
  container down `15:47:45.86Z` → `15:48:54.79Z` (**68.9 s**) produced both
  ntfy notifications, **down** and **recovered**, from the `n8n` HTTP monitor.
  On restart: `health=healthy`, `/healthz` ok, workflow **active=1 on its
  own**, IMAP re-established. That last property is what lets the pipeline
  survive a host reboot with no human action.

  *Margin worth knowing:* the outage was 69 s against a 60 s polling interval,
  so the alert fired with barely one cycle to spare. A sub-minute blip will
  pass unnoticed — which is the correct trade (it is what stops every restart
  from paging) rather than a defect, but it means Kuma is not a witness to
  brief interruptions.
- **E1 (2026-09-08) — pass.** `compose.yaml` on ciri is byte-identical to the
  repo (`6a4f77b5c9bdf846`); no copy-back was needed, which is the point — the
  file has been untouched on the VM since B1.
- **E2 (2026-09-08) — done.** `planned` → `built` in this file's Status, the
  stack README, and the `n8n` rows in `docker-vm.md`, `maintenance.md`,
  `uptime-kuma.md`, plus the API note in `configs/ciri/sure/README.md` (which
  also gained the two undocumented Sure endpoints found at B2).
- **A late fix the review caught, worth its own entry.** The D6 repair —
  requiring the model's reference to match `/^[A-Za-z]?\d{9,18}$/` *and*
  appear in the text — was **not sufficient**, and the review replaced it.
  HDFC's boilerplate ends every alert with `Call 18002586161`: an 11-digit run
  that passes any shape-plus-presence test and is **identical in every
  message**. Had the model ever returned it, every fallback transaction would
  have shared one `external_id` and collapsed into the first — a worse failure
  than `ref:Rs.640`, because it is systematic rather than occasional.

  The shipped rule does not trust the model for the id at all: `const ref =
  refOf(sms)`, reusing the parser's own keyword-anchored extractor, sliced out
  of `parser/hdfc.js` by the builder so the two paths cannot drift. `refOf()`
  requires a `Ref`/`UPI`/`RRN`/`NEFT`/`IMPS` keyword before the digits, so the
  helpline number is *structurally* unable to become an idempotency key.
  Verified behaviourally against the bundled copy: boilerplate → `null`
  (falls through to the `sha:` id), genuine references still extracted. The
  model's own answer is kept in the stored `llm` blob for audit only.

  *The general lesson:* both D6 failures came from the same place — a rule
  that asks "does this string appear in the message?" without asking "is this
  the kind of thing a reference is". The regex path never had the bug because
  `refOf()` was written to anchor on meaning, not shape.
- **Workflow name fixed at the source (2026-09-08).** The generator emitted
  `HDFC SMS -> Sure (proposal 010)` while the workflow in n8n was kept as
  `HDFC SMS -> Sure`, so every re-import needed a manual rename — and the
  rename never survived the next one. The builder now emits the live name;
  the proposal reference belongs in the repo, not in a workflow title.

- **A4 review (Fable, 2026-09-07) — three corrections on top of the A4 record.**
  1. **`HDFC_DEBIT_CARD_LAST4` never reached n8n.** It was added to
     `.env.example`, the parser and the workflow glue, but not to
     `compose.yaml`'s `environment:` block — so `$env.HDFC_DEBIT_CARD_LAST4`
     would have been undefined in the container and every ATM/debit-card
     alert rejected as `unknown-instrument`. Added as `${HDFC_DEBIT_CARD_LAST4:-}`.
  2. **The "without OTP/PIN" drop-by-rule is withdrawn.** The A4 record
     itself called it "the one place in this design where a message is
     discarded without a human seeing it". Both shapes of an autopay card
     charge are now recorded under a shared deterministic `external_id`
     (`autopay:<last4>:<date>:<amount>`), so Sure collapses the pair and a
     lone "without OTP/PIN" charge is captured. New template `card-no-otp`;
     the OTP/PIN noise rules are masked for that phrase; `normalise` also
     strips the card network's "Not U?" tail. Tracked suite 30/30 after the
     change. **The private fixture for that message still expects `skip`
     and must be flipped to `ok` before D1** (its `externalId` becomes
     `autopay:<cc last4>:2026-09-05:<amount>`).
  3. **The A4/D1 checklist rows now say "two separate runs"** — tracked
     fixtures with the synthetic last-4s, private ones with the real values —
     matching what `run-fixtures.js` already documents.
  The rest of the A4 work stands as recorded: the `EXECUTED` gate for mandate
  vocabulary, the `HDFCBANK` boundary fix, the bare-account and `Info:`
  forms, and the decision to record both legs of the card-bill transfer are
  all correct and were re-verified by rebuilding the workflow from the
  parser (no drift) and running the tracked suite independently.

- **B4 review (Fable, 2026-09-08) — cleared for activation.** Verified
  read-only from the Mac: container `2.37.10` healthy, `/healthz` ok, live
  `compose.yaml` byte-identical to the repo (so the A4-review fix for
  `HDFC_DEBIT_CARD_LAST4` is live — all sixteen pipeline variables are
  present in the container, the debit-card one included; only
  `KUMA_PUSH_URL` is empty, as C3 expects); both Pi-holes answer `.202` for
  the name and Caddy serves it with HTTP/2 200; the bare port answers 200
  (the secure-cookie page). Inside n8n: the imported workflow's two Code
  nodes hash **identical** to the repo JSON (so the post-review parser with
  `card-no-otp` and the debit-card routing is what will run), both
  credentials exist (`imap`, `httpHeaderAuth`), and the workflow is
  **inactive**, which is the state this checkpoint wanted. Four notes:
  1. **Activation is now its own step, B5**, in the checklist, so "B4 done"
     can never mean "already live".
  2. **The `N8N_RUNNERS_TASK_TIMEOUT` deprecation does not touch the Ollama
     call.** The task-runner timeout bounds Code nodes only; the Ollama
     request is an HTTP Request node with its own 180 s `timeout`. The two
     Code nodes here finish in milliseconds. Nothing to pin; the B3 note is
     superseded on that point (the observation itself was correct).
  3. **"Failed to start Python task runner … Python 3 is missing"** in the
     startup log is harmless: the workflow uses JavaScript Code nodes only,
     and the JS runner registered. Cosmetic.
  4. **The private fixture for the "without OTP/PIN" message still expects
     `skip`** — it must be flipped to `ok` before D1 (see the A4 review).
  Runbook corrections Opus surfaced in B1, B2 and C1 (empty-not-placeholder,
  `GET /api/v1/tags`, and a block-level rather than file-level Caddy verify)
  are now folded into the checklist.

- **D6/D7 review (Fable, 2026-09-08) — one fix applied, re-import required.**
  Verified read-only: the active workflow's two Code nodes hash identical to
  the repo, so production runs the tested parser; the three `hdfc-sms` rows in
  Sure are all savings expenses with `auto:sms` and `ref:` ids, and the two
  post-fix rows carry the full raw SMS in their notes while the ₹55 row from
  before the fix ends at `sms:` with nothing after it — the B4 `raw` fix is
  visible in the ledger exactly as D3 claims. D6's escaping fix is correct in
  the *generated* node (`\d`, not `d`), and it does reject both `Rs.640` and
  `640`.

  **The shape rule was necessary but not sufficient, and the residual hole is
  worse than the bug it fixed.** HDFC ends nearly every alert with
  `Call 18002586161` — an 11-digit run that satisfies
  `/^[A-Za-z]?\d{9,18}$/` *and* appears in the text, so it passes both
  halves of the D6 rule. It is also **identical in every message**. Had the
  model ever returned it, every fallback-path transaction would have been
  written with `external_id: ref:18002586161` and collapsed into the first
  one — a silent, permanent loss of every subsequent LLM-parsed transaction,
  where the `Rs.640` bug could only collide with another ₹640 purchase.

  *Fix.* The model is no longer trusted for the id at all. `refOf()` is now
  bundled into the validator from `parser/hdfc.js` (via a small `fnSrc()`
  helper, so both functions it needs come from the file the fixtures test),
  and the reference is `refOf(sms)` — keyword-anchored on Ref/UPI/RRN/NEFT/
  IMPS, which `Call 18002586161` cannot satisfy. The model's own answer is
  kept in the stored `llm` blob for audit. Probed on the generated node:
  boilerplate-only message → `null` (falls through to the unique `sha:` id),
  genuine `Ref 123456789012` → the reference. Tracked fixtures still 30/30.

  *Also learned:* `LLM_VALIDATE_CODE` is a JS template literal, so a backtick
  in a **comment** terminates it and breaks the build — the same class of trap
  as D6's `\d`. The builder now asserts the literal is backtick-free.

  **Action for the executing agent: the validator hash changed**
  `f6a7186f58ff7bda` → `02a99d1c805a4fcf`. Re-import
  `workflows/hdfc-sms-to-sure.json` in the n8n UI and re-run a D6-style
  message before D8. The `Parse HDFC SMS` node is unchanged.

  *Two housekeeping items, unresolved:* the ₹500 SWIGGY row from D3/D4 is
  still in the ledger and should go once Phase D closes; and the live
  workflow is named **"SMS to Sure"** with a new id, while the generated JSON
  is named "HDFC SMS -> Sure (proposal 010)" — a future import will therefore
  create a *second* workflow rather than updating this one. Delete the old
  one on re-import, or rename to match the JSON.

## Follow-ups (not in scope)

- **HDFC's alert emails as a second source.** Every UPI transaction is
  emailed, including the ones below the SMS thresholds. A Gmail filter on
  the personal account forwards them to the relay inbox; the workflow gets
  a second branch keyed on the sender. Needs a look at the real email
  format first.
- **Reconciliation.** A watched folder on ciri for the HDFC CSV the app can
  export → Sure's Imports API, or a matcher on `ref:` / amount+date against
  `GET /api/v1/transactions`, to catch anything the phone missed.
- **A test harness for the LLM validator.** Two bugs have now been found in
  it by hand (D6's `ref:Rs.640`, and the review's `ref:<helpline>`), and the
  fixture suite cannot reach it: it lives in `build-workflow.js`, not
  `parser/hdfc.js`. The shape that works: load the generated node's `jsCode`,
  stub `$json`/`$env`/`$('Parse HDFC SMS')`, and assert on a table of model
  replies — a good one, the amount-as-reference, the helpline-as-reference, a
  wrong last-4, `is_transaction:false`, and malformed JSON.
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
