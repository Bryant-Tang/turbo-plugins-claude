'use strict';
// Stand-in for npm-cli.js, used by the start-dbhub install tests through TP_DBHUB_NPM_CLI so that
// nothing is downloaded. It understands just the one call the launcher makes:
//
//   node fake-npm-cli.js install --prefix <dir> ... <spec>
//
// and lays down a fake @bytebase/dbhub whose entry point prints its argv to stdout. Behaviour is
// picked by FAKE_NPM_MODE:
//   ok    (default) install and exit 0
//   fail  print an npm-looking error and exit 1, installing nothing
//   slow  wait FAKE_NPM_DELAY_MS (default 3000) first, then install -- for the interrupted case
//
// It also prints to STDOUT on purpose, the way real npm does ("added N packages"): the launcher's
// stdout is the MCP protocol channel, and the tests assert none of this reaches it.
const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const prefix = args[args.indexOf('--prefix') + 1];
const mode = process.env.FAKE_NPM_MODE || 'ok';

function sleepMs(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

if (process.env.FAKE_NPM_CALLS) fs.appendFileSync(process.env.FAKE_NPM_CALLS, 'install\n');

if (mode === 'fail') {
    console.log('npm error code E404');
    console.log('npm error 404 Not Found - fake registry');
    process.exit(1);
}
if (mode === 'slow') sleepMs(Number(process.env.FAKE_NPM_DELAY_MS || 3000));

const pkgDir = path.join(prefix, 'node_modules', '@bytebase', 'dbhub');
fs.mkdirSync(path.join(pkgDir, 'dist'), { recursive: true });
fs.writeFileSync(path.join(pkgDir, 'package.json'),
    JSON.stringify({ name: '@bytebase/dbhub', bin: { dbhub: 'dist/index.js' } }) + '\n');
fs.writeFileSync(path.join(pkgDir, 'dist', 'index.js'),
    "process.stdout.write('FAKE-DBHUB ' + process.argv.slice(2).join(' ') + '\\n');\n");
console.log('added 1 package in 0s');
