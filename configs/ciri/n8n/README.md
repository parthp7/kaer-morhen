# n8n — workflow engine; first job: HDFC alert SMS → Sure (ciri stack)

n8n on **ciri** (VM 150), live at `ciri:/data/stacks/n8n/`:

| Service | Image | Port | Name |
|---|---|---|---|
| n8n | `docker.io/n8nio/n8n:2.37.10` | **5678** | `n8n.kaermorhen.fyi` |

The lab's first workflow engine. It exists to run one pipeline — every HDFC
Bank alert SMS on the iPhone becomes a de-duplicated, correctly signed
transaction in [Sure](../sure/README.md) within minutes, with no manual step
per transaction. Design, rationale and rejected alternatives:
[proposal 010](../../../docs/proposals/010-bank-alerts-to-sure.md).

**Status: designed and tested on the Mac, NOT yet deployed** (2026-09-04).
The runbook is proposal 010's Phases A–E; nothing here has run on ciri.

## Files

- `compose.yaml` — to be the verbatim copy of the live file once deployed
  (scp'd from the VM after every change, per the mirror rule in `CLAUDE.md`)
- `.env.example` — placeholders; the real `.env` is `chmod 600` and VM-only
- `parser/hdfc.js` — the SMS parser: noise gate, HDFC templates, the
  `external_id` rule, and `toSure()` which builds the API body. **The single
  source of truth** — the workflow embeds it verbatim.
- `parser/run-fixtures.js` — runs the parser over `parser/fixtures/*.txt`
  and fails on any mismatch. `parser/fixtures/private/` is git-ignored for
  unredacted real messages.
- `workflows/build-workflow.js` — generates `workflows/hdfc-sms-to-sure.json`
  from the parser plus the n8n glue. Re-run after every parser change, then
  re-import in the n8n UI.
- `workflows/hdfc-sms-to-sure.json` — the importable workflow. Contains no
  secrets, hosts or ids: those come from `$env` and from two credentials
  attached in the UI.
- `shortcut/README.md` — the iPhone automation, step by step, and the
  spike checks that decide whether this design works at all.

## How the pipeline works

```
iPhone SMS ──(Shortcuts: Message contains "HDFC")──► Send Email, subject HDFC-SMS
        ──► relay Gmail INBOX ──(IMAP IDLE)──► n8n "Relay inbox (IMAP)"
        ──► Parse HDFC SMS (Code)  status: ok | skip | unparsed | reject
              ok       ──► Create in Sure (POST /api/v1/transactions) ──► Kuma push
              unparsed ──► Ollama /api/chat (JSON schema) ──► Validate ──► ok ──► Create in Sure
              reject / LLM failure / Sure or Ollama HTTP error ──► ntfy "needs review"
              skip     ──► nothing
```

Key behaviours, each argued in the proposal:

- **Idempotent writes.** Every POST carries `external_id` + `source:
  "hdfc-sms"`. Sure 0.7.3 returns the existing entry (HTTP 200) instead of
  creating a second one, so a re-delivered mail, a re-run execution, or a
  duplicate SMS cannot double-count. `external_id` is the bank's own
  reference (`ref:<UPI/RRN/NEFT ref>`) when the SMS carries one, else
  `sha:<sha256 of the normalised text>`.
- **Never guess an account.** The SMS's last-4 must equal
  `HDFC_SAVINGS_LAST4` or `HDFC_CC_LAST4`; anything else is rejected to ntfy.
- **Sign comes from `nature`.** Savings debit → `expense`, savings credit →
  `income`; card spend → `expense`, card payment/refund → `inflow` (reduces
  the liability; it is not income). Amounts are always sent positive.
- **The LLM is a fallback, not the parser.** Only messages that pass the
  money-movement gate but match no template reach Ollama; its JSON is then
  checked against the text (amount and last-4 must literally appear) before
  anything is posted. Failure goes to a human via ntfy, never silently.
- **Gmail is the queue.** If ciri or n8n is down, unread relay mails wait;
  the IMAP trigger fetches `UNSEEN` + `SUBJECT "HDFC-SMS"` on reconnect and
  marks them read only after the run starts.

## Where the data goes

Bank alert text passes through: the phone's Mail outbox, the relay Gmail
(Google's servers — the one hop outside the lab, accepted by decision
2026-09-04 because Tailscale is not always on), n8n's execution history on
`/data` (pruned after 7 days, `EXECUTIONS_DATA_MAX_AGE=168`), Ollama on the
same VM for the fallback path only, and Sure's database, which is the
durable copy. Nothing goes to n8n's cloud: diagnostics, version checks,
templates and personalisation are all off in `compose.yaml`.

## Auth

- **n8n's own login gates the editor.** Same reasoning as shrink and
  Homepage: Caddy is on yennefer, so the port on `.150` bypasses anything
  Caddy adds. `N8N_SECURE_COOKIE=true` means the login cookie is only set
  over HTTPS, i.e. only via `https://n8n.kaermorhen.fyi` — the bare port
  shows a secure-cookie notice instead of a login form, by design.
- **Two credentials live in n8n's encrypted store** (key =
  `N8N_ENCRYPTION_KEY` from `.env`): the relay mailbox IMAP login (Gmail
  app password) and Sure's API key as a *Header Auth* credential
  (`X-Api-Key`). Both are also in `secrets.local.yaml`. Losing the
  encryption key loses both; re-entering them is the recovery.
- **Sure API key scope: `read_write`**, created in Sure → Settings → API
  Keys. It can create and edit transactions in every account of the family;
  there is no per-account scope, so the account routing in the parser is the
  only guard.

## Layout & ownership (in the VM)

```
/data/stacks/n8n/          ciri:ciri — compose.yaml, .env (600)
└── n8n-data/              uid 1000 (the image's `node` user): SQLite db,
                           encrypted credentials, execution history
```

Rides geralt's nightly 04:00 PBS job with the rest of `/data`. The
workflow definition is additionally kept in this repo (regenerated, not
exported — see Files).

## Monitoring

- Kuma **HTTP** monitor `n8n` on `http://<LAN_PREFIX>.150:5678/healthz`
  (answers 200 without auth).
- Kuma **Push** monitor `n8n-hdfc-ingest`, heartbeat **48 h**: the
  workflow pushes after every successful Sure write. Silence for two days
  means either no transactions (plausible on a quiet weekend) or a dead
  pipeline — the HTTP monitor tells the two apart. Per uptime-kuma.md, a
  monitor that has never been green has only been created: watch it turn
  green once.
- **ntfy** carries the human-in-the-loop path: every `reject`, every
  failed LLM validation, every non-2xx from Sure or Ollama, with the raw
  SMS in the body.

## Gotchas

- **`require('crypto')` in a Code node needs `NODE_FUNCTION_ALLOW_BUILTIN`.**
  2.x runs Code nodes in a task runner where built-in imports are off by
  default. `compose.yaml` allows exactly `crypto`.
- **`$env` in Code nodes needs `N8N_BLOCK_ENV_ACCESS_IN_NODE=false`.** It is
  the default today, set explicitly so a default flip cannot silently break
  every account lookup.
- **`WEBHOOK_URL` is deprecated since 2.35** — the compose file uses
  `N8N_WEBHOOK_URL`. Older guides still show the old name.
- **The IMAP trigger's "Custom Email Config" is node-imap search syntax**,
  a JSON array: `["UNSEEN", ["SUBJECT", "HDFC-SMS"]]`. Mark-as-read is the
  post-process action; if it is ever set to "nothing", every reconnect
  re-delivers the whole inbox — harmless thanks to `external_id`, but noisy.
- **Own-account transfers produce two alerts** (paying the credit card from
  savings: a savings debit and a card inflow). Both are created; Sure's
  transfer matching pairs them. Not solved here.
- **HDFC stopped SMS for small UPI amounts** (below ₹100 sent / ₹500
  received, since 2024). Those transactions are invisible to this pipeline
  until the email-alert follow-up lands (HDFC emails every UPI transaction).
- **The fixtures are synthetic** until Phase A4 replaces them with redacted
  real messages. A template that passes the synthetic set can still miss the
  bank's actual wording; that is what the `unparsed` → ntfy path is for.
- **Thinking models need `think:false` per request.** The fallback points at
  `qwen2.5:7b-instruct`, which does not think; switching `OLLAMA_MODEL` to a
  `qwen3:*` model without adding `think: false` to the request body in
  `build-workflow.js` reintroduces the 2–3 minute replies documented in
  [configs/ciri/ai](../ai/README.md).

## Follow-ups

- Second source: HDFC's own alert emails (every UPI transaction is emailed)
  forwarded into the relay inbox by a Gmail filter — a second extractor in
  the same workflow.
- Reconciliation: drop the manual HDFC CSV into a watched folder → Sure
  Imports API, matching on UPI ref / amount+date, to catch what the phone
  missed.
- Investments: CAMS/KFintech CAS statement import into Sure holdings.
- Homepage tile once proposal 008's Apps group grows.
