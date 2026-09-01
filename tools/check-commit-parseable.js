#!/usr/bin/env node
'use strict';

// Verdict half of tools/check-commit-parseable.sh: can release-please parse this commit message?
//
// The authority here is the SAME parser release-please uses -- @conventional-commits/parser, a
// strict PEG grammar -- not a hand-rolled approximation. That matters: release-please also depends
// on the lenient regex parser (conventional-changelog-conventionalcommits), and commitlint and
// every editor plugin use that family too. A message can sail through all of those and still be
// rejected here, which is exactly how the failure this guard exists for stayed invisible.
//
// Exit codes are three-valued on purpose:
//   0  parseable
//   1  NOT parseable  -- release-please would silently drop this commit
//   2  the parser itself is unavailable -- infrastructure problem, never read as "all fine"
//
// Usage: node check-commit-parseable.js <file-containing-one-commit-message>

const fs = require('fs');

const file = process.argv[2];
if (!file) {
  process.stderr.write('usage: check-commit-parseable.js <message-file>\n');
  process.exit(2);
}

let parser;
try {
  ({ parser } = require('@conventional-commits/parser'));
} catch (e) {
  process.stderr.write(
    'check-commit-parseable: @conventional-commits/parser is not installed.\n' +
    '  This check cannot answer without it, and answering "fine" would defeat its purpose.\n' +
    '  Install it first, e.g.:  npm install --no-save @conventional-commits/parser@0.4.1\n'
  );
  process.exit(2);
}

let msg;
try {
  msg = fs.readFileSync(file, 'utf8');
} catch (e) {
  process.stderr.write(`check-commit-parseable: cannot read ${file}: ${e.message}\n`);
  process.exit(2);
}

// The one construct that has ever tripped this grammar in this repo: a '(' that closes on a LATER
// line. Reported only as a HINT -- the parser above is what decides, so a future failure with a
// different cause still fails, it just gets a less specific message.
function unbalancedParenLine(text) {
  const lines = text.split('\n');
  for (let i = 0; i < lines.length; i++) {
    let depth = 0;
    for (const ch of lines[i]) {
      if (ch === '(') depth++;
      else if (ch === ')') depth--;
    }
    if (depth !== 0) return { lineNo: i + 1, text: lines[i] };
  }
  return null;
}

try {
  parser(msg);
  process.exit(0);
} catch (e) {
  const first = String(e.message).split('\n')[0];
  process.stderr.write(`  parser: ${first}\n`);
  const hint = unbalancedParenLine(msg);
  if (hint) {
    process.stderr.write(
      `  likely cause: line ${hint.lineNo} leaves a parenthesis open across the line break.\n` +
      `    ${hint.text.trim().slice(0, 100)}\n` +
      '    Close it on the same line, or use a dash or square brackets instead.\n'
    );
  }
  process.exit(1);
}
