#!/usr/bin/env node
// run-fixtures.js — run parser/hdfc.js over the fixture files and compare
// against each block's `expect:` line. Exit 1 on any mismatch.
//
// Usage:
//   node parser/run-fixtures.js                 # fixtures/hdfc-sms.txt + fixtures/private/*.txt
//   node parser/run-fixtures.js some-file.txt   # just that file
//   # no node on the laptop? any docker host works:
//   docker run --rm -v "$PWD/parser:/p:ro" node:22-alpine node /p/run-fixtures.js
//
// The env used for account routing is fixed here (savings 1234, credit card
// 9876, debit card 4567) to match the synthetic fixtures. Private fixtures
// using real last-4s override via HDFC_SAVINGS_LAST4 / HDFC_CC_LAST4 /
// HDFC_DEBIT_CARD_LAST4 in the environment — and because those overrides make
// the synthetic fixtures reject, RUN THE TWO FILES SEPARATELY:
//   node parser/run-fixtures.js parser/fixtures/hdfc-sms.txt          # defaults
//   HDFC_..._LAST4=… node parser/run-fixtures.js parser/fixtures/private/real.txt

'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { parseSms, toSure } = require('./hdfc.js');

const ENV = {
  HDFC_SAVINGS_LAST4: process.env.HDFC_SAVINGS_LAST4 || '1234',
  HDFC_CC_LAST4: process.env.HDFC_CC_LAST4 || '9876',
  HDFC_DEBIT_CARD_LAST4: process.env.HDFC_DEBIT_CARD_LAST4 || '4567',
  SURE_ACCOUNT_ID_SAVINGS: 'acct-savings',
  SURE_ACCOUNT_ID_CC: 'acct-cc',
  SURE_TAG_ID_AUTO_SMS: 'tag-auto-sms',
};
const sha256 = (s) => crypto.createHash('sha256').update(s, 'utf8').digest('hex');

function loadBlocks(file) {
  const text = fs.readFileSync(file, 'utf8');
  const blocks = [];
  let cur = null;
  for (const line of text.split('\n')) {
    if (line.trim() === '') { if (cur) { blocks.push(cur); cur = null; } continue; }
    if (!cur) {
      if (line.startsWith('#')) continue;               // file-level comment
      const m = line.match(/^expect:\s*(\S+)\s*(.*)$/);
      if (!m) throw new Error(`${file}: block must start with "expect:" — got: ${line}`);
      const want = { status: m[1] };
      // key=value, or key="value with spaces" — counterparties are often
      // several words ("APPLE MEDIA SERVICES"), and splitting on whitespace
      // silently truncated the expectation to its first word.
      const kvRe = /([A-Za-z_]\w*)=(?:"([^"]*)"|(\S*))/g;
      let kv;
      while ((kv = kvRe.exec(m[2])) !== null) {
        want[kv[1]] = kv[2] !== undefined ? kv[2] : kv[3];
      }
      cur = { file, want, lines: [] };
      continue;
    }
    if (line.startsWith('#')) continue;
    cur.lines.push(line);
  }
  if (cur) blocks.push(cur);
  return blocks;
}

function run(block) {
  const raw = block.lines.join('\n');
  const res = parseSms(raw, { receivedAt: '2026-09-04', hash: sha256 });
  let status = res.status;
  let sure = null;
  let reason = res.reason || '';
  if (status === 'ok') {
    const s = toSure(res.txn, ENV);
    if (s.ok) sure = s.body.transaction; else { status = 'reject'; reason = s.reason; }
  }
  const got = { status, reason };
  if (res.txn) {
    Object.assign(got, {
      kind: res.txn.kind, amount: res.txn.amount, date: res.txn.date,
      last4: res.txn.last4, channel: res.txn.channel, ref: res.txn.ref,
      template: res.txn.template, counterparty: res.txn.counterparty,
      externalId: res.txn.externalId,
    });
  }
  const diffs = [];
  // Invariant, not a per-fixture expectation: every row that reaches Sure must
  // carry the original SMS in its notes, or the audit trail the design
  // promises is empty.
  if (status === 'ok' && sure) {
    const want = String(raw).replace(/\s+/g, ' ').trim().slice(0, 40);
    if (want && !String(sure.notes || '').replace(/\s+/g, ' ').includes(want)) {
      diffs.push('notes: raw SMS missing from the Sure notes');
    }
  }
  for (const [k, v] of Object.entries(block.want)) {
    const g = got[k] == null ? '' : String(got[k]);
    if (g !== String(v)) diffs.push(`${k}: want ${JSON.stringify(v)} got ${JSON.stringify(g)}`);
  }
  return { got, sure, diffs, raw };
}

function main() {
  const here = __dirname;
  let files = process.argv.slice(2);
  if (!files.length) {
    files = [path.join(here, 'fixtures', 'hdfc-sms.txt')];
    const priv = path.join(here, 'fixtures', 'private');
    if (fs.existsSync(priv)) {
      for (const f of fs.readdirSync(priv).sort()) if (f.endsWith('.txt')) files.push(path.join(priv, f));
    }
  }
  let total = 0, failed = 0;
  for (const file of files) {
    for (const block of loadBlocks(file)) {
      total += 1;
      const r = run(block);
      const ok = r.diffs.length === 0;
      if (!ok) failed += 1;
      const head = r.raw.replace(/\s+/g, ' ').slice(0, 60);
      const summary = r.got.status === 'ok'
        ? `${r.got.kind} ${r.got.amount} ${r.got.date} *${r.got.last4} ${r.got.channel} ${r.got.template} -> ${r.sure.nature} ${r.sure.account_id} ${r.sure.external_id}`
        : `${r.got.status} (${r.got.reason})`;
      console.log(`${ok ? 'PASS' : 'FAIL'}  ${summary}\n      ${head}${r.raw.length > 60 ? '…' : ''}`);
      for (const d of r.diffs) console.log(`      ! ${d}`);
    }
  }
  console.log(`\n${total - failed}/${total} fixtures passed${failed ? ` — ${failed} FAILED` : ''}`);
  process.exit(failed ? 1 : 0);
}

main();
