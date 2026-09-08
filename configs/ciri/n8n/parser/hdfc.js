// hdfc.js — turn one HDFC Bank alert SMS into a Sure transaction payload.
//
// Pure functions, no I/O, no n8n globals. The same text is embedded verbatim
// into the "Parse HDFC SMS" Code node by workflows/build-workflow.js, and run
// against parser/fixtures/ by parser/run-fixtures.js. Edit it here only.
//
// Contract:
//   parseSms(text, opts)  -> { status, txn?, reason?, raw }
//       status: 'ok'        txn is complete and safe to post
//               'skip'      not a transaction (OTP, promo, reminder, decline…)
//               'unparsed'  looks like a transaction but no template matched
//               'reject'    a template matched but a required field is
//                           missing or the instrument is unknown
//   toSure(txn, env)      -> the JSON body for POST /api/v1/transactions
//
// Design rules (proposal 010 §4):
//   - never guess an account: an SMS naming an instrument that is not one of
//     the configured last-4s is rejected, not routed to a default;
//   - never invent a reference: external_id is the bank's own ref when the
//     SMS carries one, else a hash of the normalised text;
//   - amounts are always positive here; Sure's `nature` carries the sign.

'use strict';

// ---------------------------------------------------------------- helpers --

const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12 };

function pad2(n) { return String(n).padStart(2, '0'); }

// dd/mm/yy, dd-mm-yy, dd-mm-yyyy, dd-MMM-yy, dd-MMM-yyyy, yyyy-mm-dd — with
// or without a trailing :HH:MM:SS. Returns 'YYYY-MM-DD' or null.
function parseDate(s) {
  if (!s) return null;
  let m = s.match(/(\d{4})-(\d{2})-(\d{2})/);
  if (m) return `${m[1]}-${m[2]}-${m[3]}`;
  m = s.match(/(\d{1,2})[-/]([A-Za-z]{3})[-/](\d{2,4})/);
  if (m) {
    const mon = MONTHS[m[2].toLowerCase()];
    if (!mon) return null;
    const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    return `${y}-${pad2(mon)}-${pad2(m[1])}`;
  }
  m = s.match(/(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})/);
  if (m) {
    const y = m[3].length === 2 ? 2000 + Number(m[3]) : Number(m[3]);
    const mon = Number(m[2]);
    const d = Number(m[1]);
    if (mon < 1 || mon > 12 || d < 1 || d > 31) return null;
    return `${y}-${pad2(mon)}-${pad2(d)}`;
  }
  return null;
}

// "Rs.1,234.50", "Rs 1234", "INR 5,000.00" -> 1234.5 (number) or null.
function parseAmount(s) {
  if (!s) return null;
  const m = s.match(/(?:Rs\.?|INR)\s*([\d,]+(?:\.\d{1,2})?)/i);
  if (!m) return null;
  const n = Number(m[1].replace(/,/g, ''));
  return Number.isFinite(n) && n > 0 ? n : null;
}

// Collapse whitespace and drop the boilerplate tail so templates stay short.
function normalise(text) {
  return String(text || '')
    .replace(/\r/g, '')
    .replace(/\s+/g, ' ')
    // "Not You?", "Not U?" (the card-network wording), "If not done by you".
    .replace(/\s*(?:Not\s*You\??|Not\s*U\??|If not done by you|If not you)\b.*$/i, '')
    .replace(/\s*(?:Avl|Avail(?:able)?)\.?\s*(?:bal|balance)\b.*$/i, (t) => ` ${t.trim()}`)
    .trim();
}

// Words that mark a non-transaction. Checked before any template.
const NOISE = [
  /\bOTP\b/i, /one[- ]time password/i, /verification code/i,
  // NB "Rs.X without OTP/PIN …" is a real card charge, not an OTP message;
  // parseSms masks that phrase before running this list (see NO_OTP_CHARGE).
  /\bwill be debited\b/i, /\bwill be deducted\b/i, /\bis due\b/i, /\bdue on\b/i, /\breminder\b/i,
  /\bdeclined\b/i, /\bfailed\b/i, /\bunsuccessful\b/i, /could not be processed/i,
  /\brequested\b.*\b(?:money|payment|Rs)/i, /\bcollect request\b/i,
  /\bapply\b/i, /\boffer\b/i, /\bcashback of up to\b/i, /\bT&C\b/i,
  /\bstatement\b.*\bgenerated\b/i, /\bmini statement\b/i,
  /\bbal(?:ance)? (?:as on|is|in)\b/i, /\bblocked\b/i, /\bhotlisted\b/i,
  /\blogin\b/i, /\bpassword\b/i, /\bPIN\b/i,
];

// Mandate/autopay vocabulary is ambiguous: HDFC uses it both to announce a
// future deduction ("E-Mandate! Rs.75 will be deducted on 01/09/26") and to
// report one that has already happened ("UPI Mandate: Sent Rs.49.00 …",
// "AutoPay (E-mandate) Success!"). The announcements are noise; the
// completions are real money leaving a real account and were being dropped
// silently until 2026-09-07. So this family only counts as noise when the
// message does not also say the debit executed.
const MANDATE_WORDS = [
  /\bmandate\b/i, /\bautopay\b/i, /\be-?NACH\b/i, /\bSI\b.*\bregistered\b/i,
];
const EXECUTED = /(?:\bSuccess\b|^\s*(?:UPI\s+Mandate:\s*)?Sent\s+(?:Rs|INR)|\bdebited\s+from\b|\bhas been\s+(?:debited|deducted)\b)/i;

const CHANNEL_HINTS = [
  [/\bUPI\b|\bVPA\b|@[a-z]{2,}\b/i, 'upi'],
  [/\bNEFT\b/i, 'neft'], [/\bIMPS\b/i, 'imps'], [/\bRTGS\b/i, 'rtgs'],
  [/\bATM\b|\bwithdrawn\b/i, 'atm'],
  [/\bcard\b|\bPOS\b|\bECOM\b/i, 'card'],
];

function channelOf(text) {
  for (const [re, ch] of CHANNEL_HINTS) if (re.test(text)) return ch;
  return 'other';
}

// The bank's own reference, if any. Order matters: UPI/RRN first.
function refOf(text) {
  const pats = [
    /\bUPI\s*(?:Ref(?:erence)?\.?\s*(?:No\.?)?)?\s*[:#-]?\s*(\d{12})\b/i,
    /\(UPI\s*(\d{12})\)/i,
    /\bRRN\s*[:#-]?\s*(\d{12})\b/i,
    /\bRef(?:erence)?\.?\s*(?:No\.?|Number)?\s*[:#-]?\s*([A-Z]?\d{9,18})\b/i,
    /\bIMPS\s*(?:Ref(?:erence)?\.?\s*(?:No\.?)?)?\s*[:#-]?\s*(\d{12})\b/i,
    /\bNEFT\s*(?:Cr|Dr)?[- ]*(?:Ref\.?\s*)?[:#-]?\s*([A-Z]\d{12,16})\b/i,
  ];
  for (const re of pats) {
    const m = text.match(re);
    if (m) return m[1];
  }
  return null;
}

// Last four digits of the account or card named in the SMS.
function last4Of(text) {
  const pats = [
    /\b(?:A\/?C|Acct|Account)\.?\s*(?:no\.?\s*)?(?:ending\s*(?:with\s*)?)?[Xx*]*\s?(\d{4})\b/i,
    /\bCard\s*(?:no\.?\s*)?(?:ending\s*(?:with\s*)?)?[Xx*]*\s?(\d{4})\b/i,
    // HDFC's own shorthand in autopay alerts: "Via:HDFC Bank CC 9876".
    /\b(?:CC|DC)\s*[Xx*]*\s?(\d{4})\b/i,
    /\bending\s*(?:with\s*)?[Xx*]*(\d{4})\b/i,
    /[Xx*]{2,}(\d{4})\b/,
  ];
  for (const re of pats) {
    const m = text.match(re);
    if (m) return m[1];
  }
  return null;
}

function clean(s) {
  return String(s || '').replace(/\s+/g, ' ').replace(/[.\s]+$/, '').trim();
}

// ------------------------------------------------------------- templates --
// Each template: a regex over the normalised text and a mapper returning the
// fields it can vouch for. Anything it does not return is filled from the
// generic extractors above. Keep them specific: a template that matches
// everything is worse than no template, because 'unparsed' goes to the LLM
// fallback and a human, while a wrong 'ok' goes straight into Sure.
const TEMPLATES = [
  {
    id: 'upi-sent',
    re: /^Sent\s+(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+From\s+HDFC\s+Bank\s+(?<acct>A\/C\s*[Xx*]*\d{4})\s+To\s+(?<to>.+?)\s+On\s+(?<date>\S+)/i,
    // The "Sent … Ref <12 digits>" shape never says "UPI" in the body (the
    // word only appears in the stripped "SMS BLOCK UPI" tail), so name the
    // channel here rather than letting the generic hint fall to 'other'.
    map: (g) => ({ kind: 'debit', counterparty: g.to, instrument: 'account', channel: 'upi' }),
  },
  {
    // "UPI Mandate: Sent Rs.49.00 from HDFC Bank A/c 1234 To APPLE MEDIA
    // SERVICES 01/09/26 Ref 903945538020" — an executed autopay debit. Unlike
    // upi-sent it is not anchored on "Sent", the account has no X prefix and
    // the date carries no "On". It does carry a per-charge Ref, so the
    // external_id is ref-based and each month's charge is distinct.
    id: 'upi-mandate-sent',
    re: /^UPI\s+Mandate:\s*Sent\s+(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+from\s+HDFC\s+Bank\s+(?<acct>A\/c\s*[Xx*]*\d{4})\s+To\s+(?<to>.+?)\s+(?<date>\d{1,2}[-/]\d{1,2}[-/]\d{2,4})\b/i,
    map: (g) => ({ kind: 'debit', counterparty: g.to, instrument: 'account', channel: 'upi' }),
  },
  {
    id: 'upi-debited-vpa',
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:has been\s+)?debited\s+from\s+(?:HDFC\s+Bank\s+)?(?<acct>a\/c\s*[Xx*]*\d{4}).*?\bto\s+(?:VPA\s+)?(?<to>\S+@\S+|[^()]+?)(?:\s+on\s+(?<date>\S+))?\s*(?:\(UPI|\bUPI\b)/i,
    map: (g) => ({ kind: 'debit', counterparty: g.to, instrument: 'account' }),
  },
  {
    // The credit-card bill paid by standing instruction: the savings leg.
    // Kept as its own template purely for the name — "HDFC debit" on a
    // five-figure row is useless in a ledger, and this is one half of a
    // transfer Sure has to pair with the card-side inflow.
    id: 'cc-bill-autopay-debit',
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+debited\s+from\s+(?:HDFC\s+Bank\s+)?(?<acct>(?:a\/c\s*)?[Xx*]{2,}\d{4})\s+on\s+(?<date>\S+).*?\bInfo\s*:\s*CC\b.*?\bAutopay\b/i,
    map: () => ({ kind: 'debit', counterparty: 'Credit card bill payment', instrument: 'account', channel: 'other' }),
  },
  {
    id: 'account-debited',
    // The account may be written "a/c XX1234" or bare as "HDFC Bank XX1234",
    // and the tail is no longer anchored on "Avl"/end-of-string: the SI-TAD
    // alerts put an "Info: …" clause between the date and the balance.
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:has been\s+)?debited\s+from\s+(?:HDFC\s+Bank\s+)?(?<acct>a\/c\s*(?:no\.?\s*)?[Xx*]*\d{4}|[Xx*]{2,}\d{4})\s+on\s+(?<date>\S+)(?:\s+(?:to|at|for|towards)\s+(?<to>.+?)(?=\s+Avl\b|$))?/i,
    map: (g) => ({ kind: 'debit', counterparty: g.to || null, instrument: 'account' }),
  },
  {
    id: 'account-credited',
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:is\s+|has been\s+)?(?:credited\s+to|deposited\s+in(?:to)?)\s+(?:your\s+)?(?:HDFC\s+Bank\s+)?(?<acct>a\/c\s*(?:no\.?\s*)?[Xx*]*\d{4})\s+on\s+(?<date>\S+)(?:\s+(?:from|for|by|towards)\s+(?<from>.+?))?(?:\s+Avl|\s*$)/i,
    map: (g) => ({ kind: 'credit', counterparty: g.from || null, instrument: 'account' }),
  },
  {
    id: 'upi-received',
    re: /^Received\s+(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:in|to)\s+(?:your\s+)?(?:HDFC\s+Bank\s+)?(?<acct>A\/C\s*[Xx*]*\d{4})\s+from\s+(?<from>.+?)\s+On\s+(?<date>\S+)/i,
    map: (g) => ({ kind: 'credit', counterparty: g.from, instrument: 'account', channel: 'upi' }),
  },
  {
    id: 'card-spent',
    re: /(?:^|\b)(?:Spent|Txn of|Transaction of)?\s*(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:spent\s+)?(?:on|using)\s+(?:your\s+)?HDFC\s+Bank\s+(?:(?<ctype>Credit|Debit)\s+)?Card\s*(?<card>(?:no\.?\s*)?(?:ending\s*)?[Xx*]*\d{4})\s+(?:at|on|for)\s+(?<at>.+?)\s+on\s+(?<date>\S+)/i,
    map: (g) => ({ kind: 'debit', counterparty: g.at, instrument: 'card', cardType: (g.ctype || '').toLowerCase() || null }),
  },
  {
    // "Rs.349.5 without OTP/PIN HDFC Bank Card x9876 At EXAMPLE TEL On
    // 2026-09-05:12:09:17." — see NO_OTP_CHARGE. Shares its external_id
    // scheme with autopay-card-success.
    id: 'card-no-otp',
    re: /^(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+without\s+OTP\s*\/\s*PIN\s+HDFC\s+Bank\s+(?:(?<ctype>Credit|Debit)\s+)?Card\s*(?<card>[Xx*]*\d{4})\s+At\s+(?<at>.+?)\s+On\s+(?<date>\S+)/i,
    map: (g) => ({ kind: 'debit', counterparty: g.at, instrument: 'card', channel: 'card', idScheme: 'autopay' }),
  },
  {
    id: 'card-payment-received',
    // "HDFC Bank" is optional here: the CARDMEMBER wording says only "YOUR
    // CREDIT CARD ENDING WITH 9876". Safe because parseSms has already
    // established the message is HDFC's.
    re: /Payment\s+of\s+(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:has been\s+)?(?:received|credited)\s+(?:towards|to|on)\s+(?:your\s+)?(?:HDFC\s+Bank\s+)?Credit\s+Card\s*(?<card>(?:ending\s*(?:with\s*)?)?[Xx*]*\d{4})(?:\s+on\s+(?<date>\S+))?/i,
    map: () => ({ kind: 'credit', counterparty: 'Credit card payment', instrument: 'card', cardType: 'credit' }),
  },
  {
    id: 'refund-reversal',
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:has been\s+)?(?:refunded|reversed|credited back)\s+(?:to|on)\s+(?:your\s+)?(?:HDFC\s+Bank\s+)?(?<inst>(?:Credit\s+|Debit\s+)?Card|a\/c)\s*(?<acct>(?:ending\s*)?[Xx*]*\d{4})(?:\s+on\s+(?<date>\S+))?(?:\s+(?:for|from|by)\s+(?<from>.+?))?(?:\s+Avl|\s*$)/i,
    map: (g) => ({ kind: 'credit', counterparty: g.from || 'Refund', instrument: /card/i.test(g.inst) ? 'card' : 'account' }),
  },
  {
    // "AutoPay (E-mandate) Success! For WWW EXAMPLE TEL IN Txn Amt:INR349.50
    // Dt:05/09/2026 Via:HDFC Bank CC 9876 Mandate ID: Zk9QmXr4T2".
    // NOTE: the Mandate ID is stable for the life of the mandate — the same
    // string every month — so it must never become the reference. refOf()
    // only recognises Ref/UPI/RRN/NEFT/IMPS keywords, none of which appear
    // here, so the external_id falls through to sha: over the normalised
    // text, which includes Dt and therefore differs per charge. Do not add a
    // "Mandate ID" pattern to refOf without re-reading this.
    id: 'autopay-card-success',
    re: /AutoPay\s*\(E-?mandate\)\s*Success!?\s*For\s+(?<to>.+?)\s+Txn\s*Amt\s*:?\s*(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s*Dt\s*:?\s*(?<date>\S+?)\s+Via\s*:?\s*HDFC\s+Bank\s+(?:CC|Credit\s+Card|DC|Debit\s+Card|A\/c)\s*(?<card>[Xx*]*\d{4})/i,
    map: (g) => ({ kind: 'debit', counterparty: g.to, instrument: 'card', channel: 'card', idScheme: 'autopay' }),
  },
  {
    // ATM cash: the message names the DEBIT CARD, not the account, so its
    // last-4 is neither the savings nor the credit-card number. Routing it
    // needs HDFC_DEBIT_CARD_LAST4 (see toSure).
    id: 'atm-withdrawal-card',
    re: /^Withdrawn\s+(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+From\s+HDFC\s+Bank\s+(?:(?<ctype>Credit|Debit)\s+)?Card\s*(?<card>[Xx*]*\d{4})\s+At\s+(?<at>.+?)\s+On\s+(?<date>\S+)/i,
    map: (g) => ({ kind: 'debit', counterparty: g.at, instrument: 'card', channel: 'atm' }),
  },
  {
    id: 'atm-withdrawal',
    re: /(?<amt>(?:Rs\.?|INR)\s*[\d,]+(?:\.\d{1,2})?)\s+(?:has been\s+)?withdrawn\s+(?:from\s+)?(?:HDFC\s+Bank\s+)?(?<acct>a\/c\s*[Xx*]*\d{4})?.*?\bon\s+(?<date>\S+)/i,
    map: () => ({ kind: 'debit', counterparty: 'ATM withdrawal', instrument: 'account', channel: 'atm' }),
  },
];

// A message that names money moving but matched no template. Cheap gate so
// the LLM fallback only sees plausible transactions.
const LOOKS_LIKE_TXN = /(?:Rs\.?|INR)\s*[\d,]+/i;
const MOVEMENT = /\b(?:sent|debited|deducted|spent|paid|withdrawn|credited|deposited|received|refund(?:ed)?|reversed|purchase)\b|\bTxn\s*Amt\b|\bwithout\s+OTP\b/i;

// A merchant-initiated (tokenised / standing-instruction) card charge. HDFC
// usually announces the same charge a second time as "AutoPay (E-mandate)
// Success!", and the two share no reference. Rather than drop one shape by
// rule — a silent loss the day HDFC sends this wording for a charge with no
// AutoPay twin — both templates derive the SAME deterministic external_id
// (card last-4 + date + amount), so Sure collapses the pair and a lone
// message is still recorded. Two distinct autopay charges on one card, same
// day, same amount would also collapse; mandates are per merchant, so that
// is far rarer than the loss it prevents.
const NO_OTP_CHARGE = /without\s+OTP\s*\/\s*PIN/i;

// ------------------------------------------------------------------ main --

// opts: { receivedAt: 'YYYY-MM-DD' (fallback date), hash: fn(text)->hex }
function parseSms(text, opts) {
  const o = opts || {};
  const raw = String(text || '');
  const norm = normalise(raw);
  const out = { raw, norm };

  if (!norm) return Object.assign(out, { status: 'skip', reason: 'empty' });
  // "\bHDFC\b" missed "DEAR HDFCBANK CARDMEMBER" — no word boundary between
  // HDFC and BANK — and threw away real card-payment alerts as another
  // bank's mail. Leading boundary only.
  if (!/\bHDFC/i.test(norm)) return Object.assign(out, { status: 'skip', reason: 'not-hdfc' });
  // The OTP/PIN noise rules must not fire on "without OTP/PIN" charges.
  const forNoise = norm.replace(NO_OTP_CHARGE, 'w/o auth');
  for (const re of NOISE) {
    if (re.test(forNoise)) return Object.assign(out, { status: 'skip', reason: `noise:${re.source.slice(0, 24)}` });
  }
  if (!EXECUTED.test(norm)) {
    for (const re of MANDATE_WORDS) {
      if (re.test(norm)) return Object.assign(out, { status: 'skip', reason: `noise:${re.source.slice(0, 24)}` });
    }
  }
  if (!LOOKS_LIKE_TXN.test(norm) || !MOVEMENT.test(norm)) {
    return Object.assign(out, { status: 'skip', reason: 'no-money-movement' });
  }

  let hit = null;
  for (const t of TEMPLATES) {
    const m = norm.match(t.re);
    if (m) { hit = { t, g: m.groups || {} }; break; }
  }
  if (!hit) return Object.assign(out, { status: 'unparsed', reason: 'no-template' });

  const g = hit.g;
  const mapped = hit.t.map(g);
  const txn = {
    template: hit.t.id,
    kind: mapped.kind,
    amount: parseAmount(g.amt || norm),
    currency: 'INR',
    date: parseDate(g.date || '') || parseDate(norm) || o.receivedAt || null,
    last4: last4Of(g.acct || g.card || '') || last4Of(norm),
    instrument: mapped.instrument,
    cardType: mapped.cardType || null,
    channel: mapped.channel || channelOf(norm),
    counterparty: clean(mapped.counterparty) || null,
    ref: refOf(norm),
    // toSure() puts this in the Sure row's notes so a wrong parse can be
    // audited from the row itself (§4, §6). It was missing until 2026-09-08,
    // which made `sms:` empty on every regex-parsed row while the LLM path —
    // which sets raw itself — carried it. The fixtures never asserted notes,
    // so the suite stayed green through it.
    raw,
  };

  const missing = ['kind', 'amount', 'date', 'last4'].filter((k) => !txn[k]);
  if (missing.length) {
    return Object.assign(out, { status: 'reject', reason: `missing:${missing.join(',')}`, txn });
  }
  if (txn.ref) txn.externalId = `ref:${txn.ref}`;
  else if (mapped.idScheme === 'autopay') txn.externalId = `autopay:${txn.last4}:${txn.date}:${txn.amount.toFixed(2)}`;
  else txn.externalId = `sha:${(o.hash ? o.hash(norm) : fallbackHash(norm)).slice(0, 40)}`;
  return Object.assign(out, { status: 'ok', txn });
}

// Only used when no crypto hash is supplied (fixtures runner supplies one;
// the Code node supplies require('crypto')). Deterministic, not
// cryptographic — good enough to make an external_id stable per text.
function fallbackHash(s) {
  let h1 = 0x811c9dc5, h2 = 0x01000193;
  for (let i = 0; i < s.length; i++) {
    h1 = Math.imul(h1 ^ s.charCodeAt(i), 0x01000193) >>> 0;
    h2 = Math.imul(h2 + s.charCodeAt(i), 0x811c9dc5) >>> 0;
  }
  return h1.toString(16).padStart(8, '0') + h2.toString(16).padStart(8, '0');
}

// env: { HDFC_SAVINGS_LAST4, HDFC_CC_LAST4, HDFC_DEBIT_CARD_LAST4,
//        SURE_ACCOUNT_ID_SAVINGS,
//        SURE_ACCOUNT_ID_CC, SURE_TAG_ID_AUTO_SMS }
// Returns { ok:true, body } or { ok:false, reason }.
function toSure(txn, env) {
  const e = env || {};
  let accountId = null;
  let isCard = false;
  if (txn.last4 === e.HDFC_CC_LAST4) { accountId = e.SURE_ACCOUNT_ID_CC; isCard = true; }
  else if (txn.last4 === e.HDFC_SAVINGS_LAST4) { accountId = e.SURE_ACCOUNT_ID_SAVINGS; }
  // ATM and POS alerts name the debit card, whose last-4 differs from the
  // account's. It is the savings account's instrument, so it routes there and
  // is deliberately NOT a card for sign purposes: a debit is an expense.
  else if (e.HDFC_DEBIT_CARD_LAST4 && txn.last4 === e.HDFC_DEBIT_CARD_LAST4) { accountId = e.SURE_ACCOUNT_ID_SAVINGS; }
  if (!accountId) return { ok: false, reason: `unknown-instrument:${txn.last4}` };

  // Sure: expense/outflow store positive (money leaving), income/inflow
  // negative. For a credit card, spend is an expense and a payment or
  // refund is an inflow (it reduces the liability, it is not income).
  let nature;
  if (txn.kind === 'debit') nature = 'expense';
  else nature = isCard ? 'inflow' : 'income';

  const name = txn.counterparty || (txn.kind === 'debit' ? 'HDFC debit' : 'HDFC credit');
  const notes = [
    `channel=${txn.channel}`,
    txn.ref ? `ref=${txn.ref}` : null,
    `template=${txn.template}`,
    `sms: ${txn.raw || ''}`.trim(),
  ].filter(Boolean).join('\n');

  const body = {
    transaction: {
      account_id: accountId,
      date: txn.date,
      amount: txn.amount,
      currency: txn.currency || 'INR',
      name: name.slice(0, 120),
      nature,
      notes: notes.slice(0, 2000),
      external_id: txn.externalId,
      source: 'hdfc-sms',
    },
  };
  if (e.SURE_TAG_ID_AUTO_SMS) body.transaction.tag_ids = [e.SURE_TAG_ID_AUTO_SMS];
  return { ok: true, body };
}

const api = { parseSms, toSure, normalise, parseAmount, parseDate, refOf, last4Of, TEMPLATES };
if (typeof module !== 'undefined' && module.exports) module.exports = api;
