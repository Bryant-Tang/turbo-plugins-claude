#!/usr/bin/env node
'use strict';
//
// Resolve which dbhub config to use, then run DBHub. This is the launcher `.mcp.json` starts.
//
//   node start-dbhub.js <session-root> [--print-command]
//
// ---------------------------------------------------------------------------------------------
// WHY THIS IS JAVASCRIPT (and the only script in this repo that is)
//
// A plugin's `.mcp.json` takes a literal `command` string and nothing else -- no per-platform
// branch (verified against the plugin reference, 2026-08-03). Claude Code spawns that command
// RAW against the OS PATH; it does NOT go through Claude Code's own shell the way hooks do. On
// Windows that distinction is fatal:
//
//     bash -> C:\WINDOWS\system32\bash.exe   (the WSL relay; no distro => execvpe fails)
//     sh   -> does not exist
//     git  -> C:\Program Files\Git\cmd\git.exe   (Git ships bash in bin\, which is NOT on PATH)
//
// So `"command": "bash"` cannot work on a stock Git-for-Windows machine, however normal it looks
// from inside Git Bash. (It shipped anyway, because this plugin's SessionStart hook uses `bash`
// successfully -- but hooks run through Claude Code's shell. Same word, different launcher.)
//
// `node` is the one interpreter that is on PATH under the SAME NAME on Windows, macOS and Linux.
// Hence one .js instead of the usual .ps1 + .sh pair: the pair rule exists so the two platforms
// cannot drift, and a single implementation satisfies that goal more directly than two files do.
// ---------------------------------------------------------------------------------------------
//
// WHY NO CONTAINER
//
// This used to be `docker run -v <config>:/dbhub.toml`. A bind mount whose source does not exist
// is CREATED BY DOCKER as a directory, so every folder a session was ever opened in collected a
// stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY that then blocked its own fix (no
// file of that name can be created afterwards). Running the npm package takes no mount at all, so
// that entire class of bug is structurally impossible rather than guarded against. It also drops
// the Windows path-translation step the mount needed.
//
// The version is PINNED on purpose. A floating tag trades "might go stale" for "might break one
// morning with no diagnosis", and only the first of those can be fixed by a reminder -- see
// .github/workflows/dbhub-version-check.yml, which opens an issue when a newer version ships.
// Upgrading: bump DBHUB_SPEC, run the plugin's tests, then start it once against a real database
// (the tests assert the argv, not dbhub's own behaviour).
//
// ---------------------------------------------------------------------------------------------
// CONFIG RESOLUTION (D1, decided 2026-08-03)
//
//   a) <session-root>/.turbo-plugin/dbhub.local.toml, if present, always wins. That is how a
//      workspace says "use this database" when several projects could answer.
//   b) otherwise the IMMEDIATE subdirectories are scanned; exactly one match is used.
//   c) several matches -> stop and list them. Guessing which database to connect to is not a
//      recoverable mistake. The message says how to settle it.
//   d) no match -> stop and say where it looked.
//
// Deeper nesting is deliberately not searched: which database you connect to must not depend on
// how far down someone buried a file.
//
// EVERY failure exits 0. A non-zero exit is reported to the user as a crashed MCP server, which
// is alarming and unhelpful when the real answer is "this project has no database configured".
// Explanations go to stderr; stdout stays empty so nothing is mistaken for a protocol message.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const DBHUB_SPEC = '@bytebase/dbhub@1.2.0';
// Forward-slash form, used only in messages so they read the same on every platform.
const CONFIG_REL = '.turbo-plugin/dbhub.local.toml';

function say(message) {
    process.stderr.write(message + '\n');
}

function isFile(p) {
    try { return fs.statSync(p).isFile(); } catch (e) { return false; }
}

function isDirectory(p) {
    try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
}

function configIn(dir) {
    return path.join(dir, '.turbo-plugin', 'dbhub.local.toml');
}

// npx is a .cmd shim on Windows, which cannot be spawned without a shell -- and spawning through a
// shell would split arguments on spaces, which real paths have (`C:\Users\Some Name\...`). So run
// npm's own npx entry point with the very node executing this file: no shell, no quoting rules.
function findNpxCli() {
    const nodeDir = path.dirname(process.execPath);
    const candidates = [
        // Windows official installer, and any layout with npm beside the node binary.
        path.join(nodeDir, 'node_modules', 'npm', 'bin', 'npx-cli.js'),
        // Unix prefix layout: <prefix>/bin/node with <prefix>/lib/node_modules (nvm, brew, distro).
        path.join(nodeDir, '..', 'lib', 'node_modules', 'npm', 'bin', 'npx-cli.js'),
    ];
    for (const c of candidates) {
        if (isFile(c)) return c;
    }
    return '';
}

const argv = process.argv.slice(2);
const printOnly = argv.includes('--print-command');
const sessionRoot = argv.filter((a) => a !== '--print-command')[0] || '';

if (!sessionRoot) {
    say('tp-dbhub: no session root was passed to start-dbhub.js, so there is nothing to search.');
    process.exit(0);
}
if (!isDirectory(sessionRoot)) {
    say(`tp-dbhub: '${sessionRoot}' is not a directory; cannot look for ${CONFIG_REL}.`);
    process.exit(0);
}

let config = '';
const rootConfig = configIn(sessionRoot);

if (isFile(rootConfig)) {
    // (a) A config at the session root wins outright.
    config = rootConfig;
} else {
    // (b) Immediate subdirectories only.
    const matches = [];
    let entries = [];
    try {
        entries = fs.readdirSync(sessionRoot);
    } catch (e) {
        entries = [];
    }
    for (const name of entries.sort()) {
        const dir = path.join(sessionRoot, name);
        if (!isDirectory(dir)) continue;
        const candidate = configIn(dir);
        if (isFile(candidate)) matches.push(candidate);
    }

    if (matches.length === 1) {
        config = matches[0];
    } else if (matches.length === 0) {
        // (d)
        say('tp-dbhub: no database config found.');
        say(`  looked for: ${rootConfig}`);
        say(`  and in each project directly under: ${sessionRoot}`);
        say('Run /tp-setup in the project that has a database, then copy');
        say(`  .turbo-plugin/dbhub.example.toml -> ${CONFIG_REL} and fill it in.`);
        // Projects set up before the template was renamed still carry the old name, and this
        // branch is reachable for them: the template is there, only the filled-in config is
        // missing. Naming just the new file would tell them to copy something that is not there.
        say('  (set up before the rename? the template is dbhub.example.local.toml -- same thing)');
        process.exit(0);
    } else {
        // (c)
        say('tp-dbhub: several projects here have a database config, so which one to connect to is ambiguous:');
        for (const m of matches) say(`  ${m}`);
        say(`Pick one by putting a config at the workspace root (${rootConfig}) --`);
        say("copying the chosen project's file there is enough. A root config always wins.");
        process.exit(0);
    }
}

// The LOGICAL command, which is what the tests assert. The actual spawn below reaches npx through
// node so it works on Windows; that detour is an implementation concern, not a contract, and
// printing it here would make the tests depend on where npm happens to be installed.
const runArgs = ['-y', DBHUB_SPEC, '--transport', 'stdio', '--config', config];

if (printOnly) {
    process.stdout.write(['npx'].concat(runArgs).join('\n') + '\n');
    process.exit(0);
}

const npxCli = findNpxCli();
if (!npxCli) {
    say('tp-dbhub: found node but not npm, so the dbhub package cannot be fetched.');
    say(`  node: ${process.execPath}`);
    say('Install npm (it ships with Node) and reopen the session.');
    process.exit(0);
}

const result = spawnSync(process.execPath, [npxCli].concat(runArgs), { stdio: 'inherit' });
if (result.error) {
    say(`tp-dbhub: could not start ${DBHUB_SPEC}: ${result.error.message}`);
    process.exit(0);
}
process.exit(result.status === null ? 0 : result.status);
