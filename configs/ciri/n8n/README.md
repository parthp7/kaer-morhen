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

**Status: built and verified** (2026-09-08). Deployed on ciri, published in
n8n, monitored in Kuma, and carrying real transactions into Sure. The runbook
and what each verification returned: [proposal 010](../../../docs/proposals/010-bank-alerts-to-sure.md).

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
- `parser/run-validator-tests.js` — 20 cases against the **"Validate LLM
  output" node as generated**, covering what the fixture suite structurally
  cannot: the LLM path. It runs the node out of
  `workflows/hdfc-sms-to-sure.json` with `$json` / `$` / `$env` mocked, so an
  escaping bug in the builder's template literal fails here too. Regenerate
  before running it.
- `workflows/build-workflow.js` — generates `workflows/hdfc-sms-to-sure.json`
  from the parser plus the n8n glue. Re-run after every parser change, then
  re-import in the n8n UI.
- `workflows/hdfc-sms-to-sure.json` — the importable workflow. Contains no
  secrets, hosts or ids: those come from `$env` and from two credentials
  attached in the UI.
- `shortcut/README.md` — the iPhone automation, step by step, and the
  spike checks that decide whether this design works at all.

## Testing

Three commands, and the first two must be run **separately** — the tracked
fixtures use `1234`/`9876`/`4567` while the private ones need the real
last-4s, so no single invocation can be green for both:

```bash
cd configs/ciri/n8n
docker run --rm -v "$PWD:/w" -w /w node:22-alpine node parser/run-fixtures.js parser/fixtures/hdfc-sms.txt
docker run --rm -e HDFC_SAVINGS_LAST4=… -e HDFC_CC_LAST4=… -e HDFC_DEBIT_CARD_LAST4=… \
  -v "$PWD:/w" -w /w node:22-alpine node parser/run-fixtures.js parser/fixtures/private/real.txt
docker run --rm -v "$PWD:/w" -w /w node:22-alpine node workflows/build-workflow.js
docker run --rm -v "$PWD:/w" -w /w node:22-alpine node parser/run-validator-tests.js
```

**What each covers, and the gap between them.** `run-fixtures.js` exercises
`parseSms` and `toSure` — the regex path. `run-validator-tests.js` exercises
the LLM path, which has different failure modes: it is the only place where
an outside model's output becomes an `external_id`, and `external_id` is the
duplicate guard, so a wrong reference does not create a wrong row — it
silently swallows a real transaction as a repeat. Two such bugs reached
production on 2026-09-08 and both are now regression cases. Neither suite
covers the n8n glue itself (routing between nodes, credentials, the IMAP
trigger); that is what proposal 010's Phase D does by hand.

## Deploying a change without losing the execution history

With no env set, `build-workflow.js` writes the tracked JSON — placeholder
credentials, no workflow id. Importing *that* in the UI creates a **new**
workflow, so the old one's runs have to be thrown away with it:
`execution_entity` foreign-keys to `workflowId`.

Supplying the ids makes the output an in-place update instead. Both routes
below upsert on `id`, so the workflow keeps its id and its executions; they
differ only in whether you have to switch it back on by hand. The five values
live in `secrets.local.yaml`; the credential ids are stable and only change if
a credential is recreated.

Build the deploy JSON first, either way:

```bash
cd configs/ciri/n8n
OUT=$(mktemp -d)
sed -nE 's/^(N8N_WORKFLOW_ID|N8N_CRED_[A-Z]+_(IMAP|SURE)):[[:space:]]*(.*[^[:space:]])[[:space:]]*$/\1=\3/p' \
  /path/to/secrets.local.yaml > "$OUT/deploy.env"

docker run --rm --env-file "$OUT/deploy.env" \
  -v "$PWD:/w" -v "$OUT:/out" -w /w \
  node:22-alpine node workflows/build-workflow.js --out /out/hdfc-deploy.json
```

**Route A — CLI, then Publish in the UI.** No API key needed. The import
leaves the workflow deactivated (see the first gotcha), so this is two steps:

```bash
scp "$OUT/hdfc-deploy.json" lab-ciri:/data/stacks/n8n/n8n-data/
ssh lab-ciri 'docker exec n8n n8n import:workflow --input=/home/node/.n8n/hdfc-deploy.json'
ssh lab-ciri 'rm /data/stacks/n8n/n8n-data/hdfc-deploy.json'
# then: open the workflow in n8n and Publish
ssh lab-ciri 'cd /data/stacks/n8n && docker compose restart n8n'   # not optional, see below
```

Alert mail that arrives while it is off is not lost — it stays `UNSEEN` and
drains on the next activation, the same way it did through the four-day Gmail
outage of 2026-09-11.

**Route B — public API, no manual step.** Needs `N8N_PUBLIC_API_KEY` in
`secrets.local.yaml` (Settings → n8n API). `publishIfActive` defaults to true,
so an update to a published workflow is re-published automatically:

```bash
# id/active are readOnly and the schema is additionalProperties:false, so the
# body is the four writable fields — sending the generated file as-is is a 400.
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); json.dump({k:d[k] for k in ('name','nodes','connections','settings')}, open(sys.argv[2],'w'))" \
  "$OUT/hdfc-deploy.json" "$OUT/put.json"

curl -sS -X PUT "https://n8n.kaermorhen.fyi/api/v1/workflows/$N8N_WORKFLOW_ID" \
  -H "X-N8N-API-KEY: $N8N_PUBLIC_API_KEY" \
  -H 'Content-Type: application/json' --data @"$OUT/put.json"
```

Four things that bite:

- **The CLI always deactivates what it imports.** `import.service.js` sets
  `active = false` and `activeVersionId = null` before the upsert, every time.
  The only flag that activates them again, `--activeState=fromJson`, throws
  outside queue or multi-main mode, which this single-main deployment is not —
  so on ciri the CLI import is *always* followed by a manual Publish. The
  execution history survives regardless; only the on/off state is lost.
- **Route A needs the restart, and the reason is not obvious.** `docker exec`
  runs the import in its *own* process, so the deactivate it performs updates
  the database but cannot tear down the trigger living in the running server.
  Publishing then adds a second one: observed 2026-09-17 as **two** established
  connections to port 993, one holding the pre-import parser, with no way to
  tell which would win a message. The container log is the tell — a genuine
  re-activation prints `Activated workflow "…" (ID: …)`, and after the import
  and Publish there was none. Restarting resolves it to exactly one trigger
  loaded from the database.
- **The file must sit under `/data/stacks/n8n/n8n-data`** for Route A — that
  is the only host path mounted into the container (at `/home/node/.n8n`).
- **Never push the tracked JSON to a live workflow.** Its `<SET IN UI>`
  credential stubs replace the real bindings; the call succeeds and every run
  afterwards fails. A deploy build carries the real credential ids.
- **A deploy build refuses to write the tracked file** (`--out` is required),
  so instance ids cannot reach git by accident.
- **Verify by id, not by name.** The point of this path is that
  `workflow_entity.id` and the execution history are unchanged; a new id in
  the response means something fell back to creating a workflow.

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
  `HDFC_SAVINGS_LAST4`, `HDFC_CC_LAST4` or `HDFC_DEBIT_CARD_LAST4`; anything
  else is rejected to ntfy. The debit card is its own last-4 — ATM and POS
  alerts name the card rather than the account — and routes to the savings
  account, as an expense, not as a card.
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
- **Run the two fixture files separately.** `run-fixtures.js` with no
  arguments runs the tracked synthetic set *and* `fixtures/private/`, but the
  two need different routing env: the synthetic blocks use `1234`/`9876`/`4567`
  and the private ones the real last-4s, so one invocation can only ever be
  green for one of them. Pass the file explicitly.
- **HDFC says "mandate" and "autopay" about both futures and facts.**
  "E-Mandate! Rs.49 will be deducted…" is an announcement; "UPI Mandate: Sent
  Rs.49.00…" and "AutoPay (E-mandate) Success!" are completed debits. The
  noise gate only treats that vocabulary as noise when the message does not
  also say the debit executed (`EXECUTED` in `hdfc.js`). Before A4 all three
  were dropped silently.
- **A mandate id is not a reference.** "Mandate ID: …" is the same string
  every month, so using it as `external_id` would collapse a whole year of a
  subscription into one transaction. `refOf()` deliberately does not match it;
  those rows fall through to the `sha:` id, whose text includes the date.
- **One autopay card charge arrives twice** — once as "Rs.X without OTP/PIN …"
  and once as "AutoPay (E-mandate) Success!", with no shared reference. Both
  are recorded under the **same deterministic `external_id`**
  (`autopay:<last4>:<date>:<amount>`), so Sure keeps one row whichever lands
  first, and a "without OTP/PIN" charge with no AutoPay twin is still
  captured instead of silently dropped. Two distinct autopay charges on one
  card on the same day for the same amount would collapse into one; mandates
  are per merchant, so that is the rarer failure.
- **The fixtures were synthetic** until Phase A4 (2026-09-07) added a redacted
  set captured from a real inbox. Six of the ten original templates still have
  no real-world example — `upi-received`, `account-debited`, `atm-withdrawal`
  (the account-worded variant), `refund-reversal` and the NEFT/IMPS shapes —
  so a template that passes can still miss the bank's actual wording; that is
  what the `unparsed` → ntfy path is for.
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
