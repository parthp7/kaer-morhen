# iPhone side — the "HDFC SMS → relay inbox" automation

The phone is the only place the SMS exists, so this is the capture point.
It is a Shortcuts **personal automation**, built by hand on the phone (there
is no file to import — Shortcuts automations cannot be exported). Design and
the reasons behind the choices: [proposal 010](../../../../docs/proposals/010-bank-alerts-to-sure.md)
§2 and §4.

What it does: every SMS whose text contains `HDFC` is sent, as-is, as an
email with subject `HDFC-SMS` to the dedicated relay Gmail. n8n on ciri
watches that inbox. Nothing on the phone talks to the lab directly, which is
why it works with Tailscale off.

## Build it (iOS 17 or later)

1. **Shortcuts → Automation → + (New Automation) → Message.**
2. Trigger settings:
   - *Sender*: leave **empty**. HDFC's SMS sender IDs (`VM-HDFCBK`,
     `AD-HDFCBK`, `JD-HDFCBK`, …) differ by telco route and are not phone
     numbers, so a contact-based filter misses some of them.
   - *Message Contains*: `HDFC`
   - *Run Immediately* (not "Run After Confirmation"), and switch **Notify
     When Run** off. Without "Run Immediately" the phone asks before every
     message and the pipeline is manual again.
3. **Next → New Blank Automation**, then add ONE action: **Send Email**
   (the Mail app action, not Gmail's).
   - *Recipients*: the relay mailbox address (`RELAY_MAILBOX` in
     `secrets.local.yaml`).
   - *Subject*: `HDFC-SMS` — exactly this; the n8n IMAP filter is
     `SUBJECT "HDFC-SMS"` and ignores everything else in the inbox.
   - *Body*: the **Shortcut Input** variable (the message text). Tap the body
     field, choose *Select Variable → Shortcut Input*. If the variable
     offers a type, pick *Message* → *Content*.
   - Open the action's options (the `>` chevron) and turn **Show Compose
     Sheet OFF**. With it on, the mail sits in a compose window waiting for a
     tap. Set *From* to the account you want the mail to leave from (any
     account configured in Mail.app; iCloud is fine).
4. **Done.** No confirmation dialog should appear when the next HDFC SMS
   lands.

## Spike checks (Phase A3 of the proposal — do these before anything on ciri)

| # | Check | Pass |
|---|---|---|
| A3a | Lock the phone, make a small UPI payment | the relay inbox has a mail with subject `HDFC-SMS` and the SMS as the body within a minute |
| A3b | Reboot the phone, unlock it once, lock it, make a payment | same result — iOS does not run automations before the first unlock after boot, so this proves the steady state |
| A3c | Airplane mode on, make no payment, receive an old SMS? (not possible) — instead: Wi-Fi + mobile data off, wait for an SMS, then turn data on | the mail arrives once the phone is online: Mail's outbox queues it |

If **A3a fails** with the phone locked but works unlocked, iOS is refusing
the Send Email action on the lock screen for this Mail account. Two known
fixes, try in order: use the iCloud account as the *From* account; or replace
the Send Email action with *Get Contents of URL* posting to n8n over the
tailnet (the design the user declined as primary because the VPN is not
always on). Record whichever it is under "As-built deviations" in the
proposal.

## Known limits of the Message trigger

- Fires only for messages that arrive **after** the automation is created;
  nothing historical is replayed. Backfill is the CSV reconciliation follow-up
  in the proposal, not the phone.
- iOS filters some sender IDs into *Unknown Senders* / *Transactions* /
  *Junk* folders. The trigger still fires for filtered messages in current
  iOS versions, but a message that iOS classifies as **junk** may be dropped
  before Shortcuts sees it. If a transaction is missing, check Messages →
  Filters → Junk first.
- The action sends real mail: the relay mailbox will show the phone's
  Mail account as the sender. That address is a lab secret in the sense that
  spam to it would trigger nothing (the subject filter) but would fill the
  inbox — keep the relay address out of anything public.
- One SMS can be split by the carrier into two messages; the automation
  then sends two mails, and the parser sees two half-messages. n8n reports
  both as `unparsed` to ntfy, which is the correct outcome: a human
  reconstructs it. HDFC alerts are short enough that this is rare.

## Collecting fixtures (Phase A4)

Copy ~30 real HDFC alerts into `parser/fixtures/private/real.txt` on the Mac
in the fixture format (one block per SMS, `expect:` line first). That
directory is git-ignored. Then redact a representative set — change every
digit run and every name, keep the wording — into
`parser/fixtures/hdfc-sms.txt` so the tests can be committed. Run
`parser/run-fixtures.js` against both.
