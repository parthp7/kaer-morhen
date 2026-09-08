#!/usr/bin/env node
// run-validator-tests.js — exercise the "Validate LLM output" Code node.
//
// Usage:
//   node parser/run-validator-tests.js
//   docker run --rm -v "$PWD:/w" -w /w node:22-alpine node parser/run-validator-tests.js
//
// Why this exists: the fixture suite covers parseSms/toSure only. The LLM
// validator is the component most likely to accept something wrong — it runs
// exactly on the messages no template understands — and it had no coverage at
// all. Both defects found in production on 2026-09-08 lived here:
//
//   * external_id became "ref:Rs.640": the model returned the amount as the
//     reference and the rule only asked whether the string appeared in the
//     text;
//   * the replacement shape test still admitted "Call 18002586161" — HDFC
//     boilerplate, identical in every alert — which would have collapsed
//     every fallback transaction into the first one.
//
// external_id is the duplicate guard, so a wrong reference does not create a
// wrong row: it silently swallows a real transaction as a repeat. That is why
// the id cases below are the centre of this file.
//
// It runs the GENERATED node out of workflows/hdfc-sms-to-sure.json, not the
// builder source, so an escaping bug in the template literal (a lone \d being
// eaten, which happened) fails here too. Regenerate before running.

'use strict';

const fs = require('fs');
const path = require('path');

const WORKFLOW = path.join(__dirname, '..', 'workflows', 'hdfc-sms-to-sure.json');
const NODE_NAME = 'Validate LLM output';

const ENV = {
  HDFC_SAVINGS_LAST4: '1234',
  HDFC_CC_LAST4: '9876',
  HDFC_DEBIT_CARD_LAST4: '4567',
  SURE_ACCOUNT_ID_SAVINGS: 'acct-savings',
  SURE_ACCOUNT_ID_CC: 'acct-cc',
  SURE_TAG_ID_AUTO_SMS: 'tag-auto-sms',
};

function loadValidator() {
  const wf = JSON.parse(fs.readFileSync(WORKFLOW, 'utf8'));
  const node = wf.nodes.find((n) => n.name === NODE_NAME);
  if (!node) throw new Error(`no "${NODE_NAME}" node in ${WORKFLOW}`);
  if (node.parameters.mode !== 'runOnceForEachItem') {
    throw new Error(`"${NODE_NAME}" must run once for each item (paired-item tracking); got ${node.parameters.mode}`);
  }
  // The node body uses top-level `return`, which is legal in a Function body.
  const fn = new Function('$json', '$', '$env', 'require', node.parameters.jsCode);
  return (sms, llmContent, receivedAt) => {
    const src = { sms, receivedAt: receivedAt || '2026-09-08', status: 'unparsed' };
    const $ = () => ({ item: { json: src } });
    const $json = { message: { content: llmContent } };
    return fn($json, $, ENV, require);
  };
}

// Each case: what the SMS said, what the model claimed, what must come out.
const CASES = [
  // ---- the two live near-misses, as regressions -------------------------
  {
    name: 'model returns the AMOUNT as the reference (live bug, D6)',
    sms: 'HDFC Bank alert: a purchase of Rs.640 was made today using your account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234', reference: 'Rs.640' },
    expect: { status: 'ok', externalIdStarts: 'sha:', externalIdNot: 'ref:Rs.640' },
  },
  {
    name: 'model returns the HELPLINE number as the reference (identical in every alert)',
    sms: 'Rs.640 spent using your account ending 1234. Not You? Call 18002586161/SMS BLOCK UPI to 7308080808',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234', reference: '18002586161' },
    expect: { status: 'ok', externalIdStarts: 'sha:', externalIdNot: 'ref:18002586161' },
  },
  {
    name: 'two different messages with no reference get DIFFERENT sha ids',
    pair: [
      { sms: 'A purchase of Rs.640 on account ending 1234 at SHOP ONE. Call 18002586161',
        llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234' } },
      { sms: 'A purchase of Rs.640 on account ending 1234 at SHOP TWO. Call 18002586161',
        llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234' } },
    ],
    expect: { distinctIds: true },
  },
  {
    name: 'a GENUINE keyword-anchored reference is still used',
    sms: 'Rs.20.00 sent from a/c 1234 to SHOP on 05/09/26 Ref 129081488311. Call 18002586161',
    llm: { is_transaction: true, kind: 'debit', amount: 20, account_last4: '1234', reference: '129081488311' },
    expect: { status: 'ok', externalId: 'ref:129081488311' },
  },
  {
    name: 'reference is taken from the TEXT, not the model — model lying is ignored',
    sms: 'Rs.20.00 sent from a/c 1234 on 05/09/26 Ref 129081488311. Call 18002586161',
    llm: { is_transaction: true, kind: 'debit', amount: 20, account_last4: '1234', reference: '999999999999' },
    expect: { status: 'ok', externalId: 'ref:129081488311' },
  },

  // ---- the model must not invent anything -------------------------------
  {
    name: 'amount not present in the text is rejected',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 999, account_last4: '1234' },
    expect: { status: 'reject', reason: 'llm:amount-not-in-text' },
  },
  {
    name: 'last-4 not present in the text is rejected',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '4321' },
    expect: { status: 'reject', reason: 'llm:last4-not-in-text' },
  },
  {
    name: 'an unconfigured instrument is rejected, never defaulted',
    sms: 'A purchase of Rs.640 on account ending 5555.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '5555' },
    expect: { status: 'reject', reasonHas: 'unknown-instrument' },
  },
  {
    name: 'is_transaction:false becomes a skip, not a row',
    sms: 'Your OTP is 482913 for a txn of Rs.640 on account ending 1234.',
    llm: { is_transaction: false },
    expect: { status: 'skip' },
  },
  { name: 'a bad kind is rejected',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'sideways', amount: 640, account_last4: '1234' },
    expect: { status: 'reject', reason: 'llm:bad-kind' } },
  { name: 'a non-numeric amount is rejected',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 'lots', account_last4: '1234' },
    expect: { status: 'reject', reason: 'llm:bad-amount' } },
  { name: 'malformed JSON from the model is rejected, not thrown',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    raw: '{not json at all',
    expect: { status: 'reject', reason: 'llm:no-json' } },
  { name: 'an empty reply is rejected',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    raw: '', expect: { status: 'reject', reason: 'llm:no-json' } },

  // ---- routing and sign, on the path that bypasses the templates --------
  {
    name: 'credit-card spend routes to the card as an expense',
    sms: 'Rs.640 spent on card ending 9876 at SHOP.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '9876', instrument: 'card' },
    expect: { status: 'ok', accountId: 'acct-cc', nature: 'expense' },
  },
  {
    name: 'credit to a card is an inflow, not income (it reduces a liability)',
    sms: 'Rs.640 credited to card ending 9876.',
    llm: { is_transaction: true, kind: 'credit', amount: 640, account_last4: '9876', instrument: 'card' },
    expect: { status: 'ok', accountId: 'acct-cc', nature: 'inflow' },
  },
  {
    name: 'credit to the savings account is income',
    sms: 'Rs.640 credited to a/c ending 1234.',
    llm: { is_transaction: true, kind: 'credit', amount: 640, account_last4: '1234' },
    expect: { status: 'ok', accountId: 'acct-savings', nature: 'income' },
  },
  {
    name: 'the debit card routes to SAVINGS and stays an expense',
    sms: 'Withdrawn Rs.640 from card ending 4567 at an ATM.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '4567', instrument: 'card' },
    expect: { status: 'ok', accountId: 'acct-savings', nature: 'expense' },
  },

  // ---- the audit trail the design promises ------------------------------
  {
    name: 'the row carries the raw SMS in its notes',
    sms: 'A purchase of Rs.640 on account ending 1234 at SOME SHOP.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234' },
    expect: { status: 'ok', notesHasSms: true },
  },
  {
    name: 'a missing date falls back to the mail date rather than failing',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234' },
    expect: { status: 'ok', date: '2026-09-08' },
  },
  {
    name: 'the tag is attached',
    sms: 'A purchase of Rs.640 on account ending 1234.',
    llm: { is_transaction: true, kind: 'debit', amount: 640, account_last4: '1234' },
    expect: { status: 'ok', tag: 'tag-auto-sms' },
  },
];

function check(out, want, second) {
  const j = out && out.json ? out.json : {};
  // the node returns the whole POST body ({transaction: {...}}), unlike
  // run-fixtures.js which unwraps it
  const sure = j.sure ? (j.sure.transaction || j.sure) : null;
  const txn = j.txn || null;
  const diffs = [];
  const eq = (label, got, exp) => { if (got !== exp) diffs.push(`${label}: want ${JSON.stringify(exp)} got ${JSON.stringify(got)}`); };

  if (want.status) eq('status', j.status, want.status);
  if (want.reason) eq('reason', j.reason, want.reason);
  if (want.reasonHas && !String(j.reason || '').includes(want.reasonHas)) {
    diffs.push(`reason: want it to contain ${JSON.stringify(want.reasonHas)} got ${JSON.stringify(j.reason)}`);
  }
  if (want.externalId) eq('external_id', sure && sure.external_id, want.externalId);
  if (want.externalIdStarts && !String(sure && sure.external_id).startsWith(want.externalIdStarts)) {
    diffs.push(`external_id: want it to start with ${want.externalIdStarts} got ${JSON.stringify(sure && sure.external_id)}`);
  }
  if (want.externalIdNot && String(sure && sure.external_id) === want.externalIdNot) {
    diffs.push(`external_id: must NOT be ${want.externalIdNot}`);
  }
  if (want.accountId) eq('account_id', sure && sure.account_id, want.accountId);
  if (want.nature) eq('nature', sure && sure.nature, want.nature);
  if (want.date) eq('date', sure && sure.date, want.date);
  if (want.tag) eq('tag', sure && sure.tag_ids && sure.tag_ids[0], want.tag);
  if (want.notesHasSms) {
    const notes = String((sure && sure.notes) || '');
    const body = notes.split('sms:')[1] || '';
    if (body.trim().length === 0) diffs.push('notes: the raw SMS is missing (audit trail empty)');
  }
  if (want.distinctIds) {
    const a = sure && sure.external_id;
    const sb = second && second.json && second.json.sure;
    const b = sb && (sb.transaction || sb).external_id;
    if (!a || !b) diffs.push('distinctIds: one of the two rows did not reach Sure');
    else if (a === b) diffs.push(`distinctIds: both messages produced ${a} — a real transaction would be swallowed`);
  }
  if (txn && txn.template && txn.template !== 'llm') diffs.push(`template: expected "llm" got ${JSON.stringify(txn.template)}`);
  return diffs;
}

function main() {
  const run = loadValidator();
  let total = 0, failed = 0;
  for (const c of CASES) {
    total += 1;
    let out = null, second = null, err = null;
    try {
      if (c.pair) {
        out = run(c.pair[0].sms, JSON.stringify(c.pair[0].llm));
        second = run(c.pair[1].sms, JSON.stringify(c.pair[1].llm));
      } else {
        const content = c.raw !== undefined ? c.raw : JSON.stringify(c.llm);
        out = run(c.sms, content);
      }
    } catch (e) { err = e; }
    const diffs = err ? [`threw: ${err.message}`] : check(out, c.expect, second);
    if (diffs.length) failed += 1;
    const j = (out && out.json) || {};
    const summary = j.status === 'ok'
      ? (() => { const b = j.sure && (j.sure.transaction || j.sure) || {}; return `ok -> ${b.nature} ${b.account_id} ${b.external_id}`; })()
      : `${j.status || '?'} (${j.reason || ''})`;
    console.log(`${diffs.length ? 'FAIL' : 'PASS'}  ${c.name}\n      ${summary}`);
    for (const d of diffs) console.log(`      ! ${d}`);
  }
  console.log(`\n${total - failed}/${total} validator cases passed${failed ? ` — ${failed} FAILED` : ''}`);
  process.exit(failed ? 1 : 0);
}

main();
