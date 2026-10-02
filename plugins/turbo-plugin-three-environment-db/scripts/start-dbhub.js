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
const os = require('os');
const path = require('path');
const { spawn, spawnSync } = require('child_process');

const DBHUB_SPEC = '@bytebase/dbhub@1.4.0';
// Forward-slash form, used only in messages so they read the same on every platform.
const CONFIG_REL = '.turbo-plugin/dbhub.local.toml';

// ---------------------------------------------------------------------------------------------
// WHERE DBHUB IS INSTALLED (issue #200)
//
// This used to be `npx -y <spec>`. npx installs into a cache directory npm names by hashing the
// spec, and if that install is interrupted -- the first start of a new version takes about a
// minute, longer than Claude Code waits for an MCP server, so it IS interrupted -- npm leaves a
// directory with node_modules/ but no package.json. Every later `npm exec` reads that package.json
// first and dies with ENOENT; it never reinstalls. The server stayed CONNECTION_CLOSED until
// someone found and deleted the directory by hand. We cannot repair that from here: the hash is
// npm's internal business, so the launcher cannot know which directory is the broken one.
//
// So the launcher owns the install instead: one directory per pinned version under the plugin's
// data directory, which only ever exists complete (see runInstaller), and dbhub is then started
// with plain `node <entry>` -- no npx, no npm on the hot path.
//
// CLAUDE_PLUGIN_DATA is the per-plugin directory Claude Code keeps across plugin updates; outside
// Claude Code (running this by hand) a temp directory stands in. Either way a missing install is
// only ever a re-download, never a broken state.
//
// The temp fallback is PER USER and must be OWNED by us. On a shared Unix host /tmp is writable by
// everyone, so a fixed name there could be created first by someone else, pre-filled with a marker
// and an entry point of their choosing -- which this launcher would then run as us. The user name
// in the path keeps users apart; the owner check (see checkDataRoot) is what actually closes it.
const DATA_ENV = 'CLAUDE_PLUGIN_DATA';
const DATA_FROM_ENV = Boolean(process.env[DATA_ENV]);
const DATA_ROOT = process.env[DATA_ENV] ||
    path.join(os.tmpdir(), `turbo-plugin-three-environment-db-${currentUserName()}`);
const DBHUB_BASE = path.join(DATA_ROOT, 'dbhub');
const DBHUB_VERSION = DBHUB_SPEC.slice(DBHUB_SPEC.lastIndexOf('@') + 1);
const INSTALL_DIR = path.join(DBHUB_BASE, DBHUB_VERSION);
const MARKER = '.tp-installed';
const LOCK_DIR = `${INSTALL_DIR}.lock`;
const LOCK_PID_FILE = path.join(LOCK_DIR, 'pid');
const LOG_FILE = `${INSTALL_DIR}.install.log`;
const INSTALL_FLAG = '--install-dbhub';
const POLL_MS = 500;
const WAIT_LIMIT_MS = 30 * 60 * 1000;

function say(message) {
    process.stderr.write(message + '\n');
}

function isFile(p) {
    try { return fs.statSync(p).isFile(); } catch (e) { return false; }
}

function isDirectory(p) {
    try { return fs.statSync(p).isDirectory(); } catch (e) { return false; }
}

function currentUserName() {
    let name = '';
    try { name = os.userInfo().username; } catch (e) { name = ''; }
    // Only characters that are safe in a directory name on every platform.
    name = String(name || process.env.USERNAME || process.env.USER || 'user').replace(/[^A-Za-z0-9._-]/g, '_');
    return name || 'user';
}

// The temp fallback only: create it private, and refuse one that someone else created. Windows has
// no uid and a per-user temp directory to begin with, so there is nothing to check there. The data
// directory Claude Code hands us is its own business and is not second-guessed.
function checkDataRoot() {
    if (DATA_FROM_ENV || typeof process.getuid !== 'function') return '';
    try {
        fs.mkdirSync(DATA_ROOT, { recursive: true, mode: 0o700 });
        const st = fs.lstatSync(DATA_ROOT);
        if (!st.isDirectory()) return `${DATA_ROOT} is not a directory`;
        if (st.uid !== process.getuid()) return `${DATA_ROOT} belongs to another user`;
        if (st.mode & 0o022) return `${DATA_ROOT} is writable by other users`;
    } catch (e) {
        return `cannot use ${DATA_ROOT}: ${e.message}`;
    }
    return '';
}

function configIn(dir) {
    return path.join(dir, '.turbo-plugin', 'dbhub.local.toml');
}

function isInstalled() {
    return isFile(path.join(INSTALL_DIR, MARKER)) && isFile(dbhubEntry(INSTALL_DIR));
}

// Read from the package's own manifest rather than hard-coding dist/index.js, so a version bump
// that moves the entry point does not need a launcher change.
function dbhubEntry(root) {
    const pkgDir = path.join(root, 'node_modules', '@bytebase', 'dbhub');
    let bin = 'dist/index.js';
    try {
        const pkg = JSON.parse(fs.readFileSync(path.join(pkgDir, 'package.json'), 'utf8'));
        if (typeof pkg.bin === 'string') bin = pkg.bin;
        else if (pkg.bin && typeof pkg.bin.dbhub === 'string') bin = pkg.bin.dbhub;
    } catch (e) { /* fall through to the default; isFile() on the result decides */ }
    return path.join(pkgDir, bin);
}

function isAlive(pid) {
    if (!pid) return false;
    try { process.kill(pid, 0); return true; } catch (e) { return e.code === 'EPERM'; }
}

function removeTree(p) {
    try { fs.rmSync(p, { recursive: true, force: true, maxRetries: 3 }); } catch (e) { /* best effort */ }
}

function sleepMs(ms) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// npm is a .cmd shim on Windows, which cannot be spawned without a shell -- and spawning through a
// shell would split arguments on spaces, which real paths have (`C:\Users\Some Name\...`). So run
// npm's own entry point with the very node executing this file: no shell, no quoting rules.
// TP_DBHUB_NPM_CLI exists for the tests, which substitute a fake npm so no download happens.
function findNpmCli() {
    if (process.env.TP_DBHUB_NPM_CLI) return process.env.TP_DBHUB_NPM_CLI;
    const nodeDir = path.dirname(process.execPath);
    const candidates = [
        // Windows official installer, and any layout with npm beside the node binary.
        path.join(nodeDir, 'node_modules', 'npm', 'bin', 'npm-cli.js'),
        // Unix prefix layout: <prefix>/bin/node with <prefix>/lib/node_modules (nvm, brew, distro).
        path.join(nodeDir, '..', 'lib', 'node_modules', 'npm', 'bin', 'npm-cli.js'),
    ];
    for (const c of candidates) {
        if (isFile(c)) return c;
    }
    return '';
}
const npmCli = findNpmCli();

const argv = process.argv.slice(2);
if (argv[0] === INSTALL_FLAG) {
    runInstaller();
}
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

// The LOGICAL command, which is what the tests assert: which package, at which version, against
// which config. Where the package was installed to is an implementation concern, not a contract,
// and printing it here would make the tests depend on the machine.
const dbhubArgs = ['--transport', 'stdio', '--config', config];

if (printOnly) {
    process.stdout.write([DBHUB_SPEC].concat(dbhubArgs).join('\n') + '\n');
    process.exit(0);
}

const dataProblem = checkDataRoot();
if (dataProblem) {
    say(`tp-dbhub: refusing to install or run dbhub from ${DATA_ROOT}: ${dataProblem}.`);
    say(`Remove it (or set ${DATA_ENV} to a directory of your own) and reconnect.`);
    process.exit(0);
}

if (isInstalled()) {
    runDbhub();
} else {
    installThenRun(true);
}

function runDbhub() {
    const result = spawnSync(process.execPath, [dbhubEntry(INSTALL_DIR)].concat(dbhubArgs), { stdio: 'inherit' });
    if (result.error) {
        say(`tp-dbhub: could not start ${DBHUB_SPEC}: ${result.error.message}`);
        process.exit(0);
    }
    process.exit(result.status === null ? 0 : result.status);
}

// The first start after a version bump (or on a new machine) has to download the package, which
// took ~58s on a real machine -- longer than Claude Code waits for an MCP server to answer. So the
// download runs in a DETACHED child: if Claude Code gives up on us and kills this process, the
// install carries on and the next connect finds it finished. This process only waits for it.
//
// canTakeOver: whether a waiter may start its own install if the one it is waiting for dies. True
// on the first attempt only, so a launcher takes over at most once and cannot loop.
function installThenRun(canTakeOver) {
    const lock = takeLock();
    if (lock.error) {
        // Not "someone else holds it": we cannot create anything there at all (permissions, a
        // read-only disk). Waiting would only end in a misleading "did not finish".
        say(`tp-dbhub: cannot install ${DBHUB_SPEC}: ${lock.error}`);
        process.exit(0);
    }
    if (!lock.taken) {
        // Another launcher (a second session, or a reconnect) is already installing. Do not start a
        // second download into the same place -- wait for that one.
        say(`tp-dbhub: ${DBHUB_SPEC} is being installed by another session; waiting for it.`);
        waitForInstall(canTakeOver);
        return;
    }

    if (!npmCli) {
        releaseLock();
        say('tp-dbhub: found node but not npm, so the dbhub package cannot be fetched.');
        say(`  node: ${process.execPath}`);
        say('Install npm (it ships with Node) and reopen the session.');
        process.exit(0);
    }

    say(`tp-dbhub: installing ${DBHUB_SPEC} (first start of this version; this can take a minute).`);
    say(`  into: ${INSTALL_DIR}`);
    say(`  log:  ${LOG_FILE}`);

    let child;
    try {
        fs.mkdirSync(DATA_ROOT, { recursive: true });
        const log = fs.openSync(LOG_FILE, 'w');
        child = spawn(process.execPath, [__filename, INSTALL_FLAG], {
            detached: true,
            windowsHide: true,
            // stdout of THIS process is the MCP protocol channel. Nothing npm prints may reach it,
            // so the installer writes to a log file only, never to an inherited stream.
            stdio: ['ignore', log, log],
            env: Object.assign({}, process.env, { [DATA_ENV]: DATA_ROOT }),
        });
        fs.closeSync(log);
    } catch (e) {
        releaseLock();
        say(`tp-dbhub: could not start the installer: ${e.message}`);
        process.exit(0);
    }
    child.on('error', (e) => {
        releaseLock();
        say(`tp-dbhub: could not start the installer: ${e.message}`);
        process.exit(0);
    });
    try { fs.writeFileSync(LOCK_PID_FILE, String(child.pid)); } catch (e) { /* lock stays age-based */ }
    child.unref();
    waitForInstall(false);
}

// Poll rather than wait on the child: the installer may belong to another launcher, and the end
// state that matters is "installed" or "nobody is installing any more", not one process's exit.
//
// If the installer we were waiting on DIED (its lock is still there, its pid is gone -- killed
// along with the session that started it), a waiter that has not installed yet takes over instead
// of giving up. An installer that FAILED releases its lock, so that case is reported, not retried:
// a second identical npm run would only fail the same way, a minute later.
function waitForInstall(canTakeOver) {
    const started = Date.now();
    const timer = setInterval(() => {
        if (isInstalled()) {
            clearInterval(timer);
            runDbhub();
            return;
        }
        const lockHeld = fs.existsSync(LOCK_DIR);
        const stale = lockHeld && lockIsStale();
        if (lockHeld && !stale && Date.now() - started < WAIT_LIMIT_MS) return;
        clearInterval(timer);
        if (stale && canTakeOver) {
            say('tp-dbhub: the session that was installing it went away; installing here instead.');
            installThenRun(false);
            return;
        }
        reportFailedInstall();
        process.exit(0);
    }, POLL_MS);
}

function reportFailedInstall() {
    say(`tp-dbhub: installing ${DBHUB_SPEC} did not finish.`);
    let tail = '';
    try { tail = fs.readFileSync(LOG_FILE, 'utf8').trim().split(/\r?\n/).slice(-15).join('\n'); } catch (e) { tail = ''; }
    if (tail) {
        say(`  last lines of ${LOG_FILE}:`);
        for (const line of tail.split('\n')) say(`    ${line}`);
    }
    say('Nothing half-installed was kept, so reconnecting (/mcp) simply tries again.');
}

// ---------------------------------------------------------------------------------------------
// INSTALLER (the detached child started above)
//
// Installs into a staging directory of its own, and only once npm has finished AND the entry
// point is really there does it write the marker and rename the whole directory into place. A
// rename is atomic, so INSTALL_DIR either does not exist or is complete -- there is no state in
// which a killed install leaves something the next start mistakes for an installation. That is
// exactly the state `npx` left behind in issue #200: a cache directory with node_modules/ but no
// package.json, which npm then refused to read on every later start, forever.
function runInstaller() {
    const staging = `${INSTALL_DIR}.staging-${process.pid}`;
    let code = 1;
    try {
        removeDeadStaging();
        removeTree(staging);
        fs.mkdirSync(staging, { recursive: true });
        fs.writeFileSync(path.join(staging, 'package.json'),
            JSON.stringify({ name: 'tp-dbhub-runtime', private: true }, null, 2) + '\n');
        if (!npmCli) throw new Error('npm was not found next to node');
        const npm = spawnSync(process.execPath,
            [npmCli, 'install', '--prefix', staging, '--no-audit', '--no-fund', '--omit=dev', DBHUB_SPEC],
            { stdio: 'inherit', windowsHide: true });
        if (npm.error) throw npm.error;
        if (npm.status !== 0) throw new Error(`npm install exited ${npm.status}`);
        if (!isFile(dbhubEntry(staging))) throw new Error(`npm finished but ${dbhubEntry(staging)} is missing`);
        fs.writeFileSync(path.join(staging, MARKER), DBHUB_SPEC + '\n');
        promote(staging);
        console.log(`tp-dbhub: installed ${DBHUB_SPEC}`);
        removeOtherVersions();
        code = 0;
    } catch (e) {
        console.log(`tp-dbhub: install failed: ${e.message}`);
        removeTree(staging);
    } finally {
        releaseLock();
    }
    process.exit(code);
}

function promote(staging) {
    // A directory at INSTALL_DIR without the marker cannot come from this code, but if one is there
    // it is not an installation and must not block the rename.
    if (fs.existsSync(INSTALL_DIR) && !isInstalled()) removeTree(INSTALL_DIR);
    for (let attempt = 0; ; attempt++) {
        try {
            fs.renameSync(staging, INSTALL_DIR);
            return;
        } catch (e) {
            if (isInstalled()) {
                // Someone else finished first; theirs is as good as ours.
                removeTree(staging);
                return;
            }
            // Windows: a virus scanner briefly holding a freshly written file makes the rename fail.
            if (attempt >= 10) throw e;
            sleepMs(500);
        }
    }
}

// Each version bump installs a new directory of a few hundred packages next to the old one. Once the
// new one is in place nothing will start the old one again (the launcher only ever runs the version
// it pins), so it goes. Best effort: on Windows a session still running the old version keeps some
// of its files locked, and whatever is left is retried after the next bump.
function removeOtherVersions() {
    let entries = [];
    try { entries = fs.readdirSync(DBHUB_BASE); } catch (e) { return; }
    const mine = path.basename(INSTALL_DIR);
    for (const name of entries) {
        if (name === mine || name.startsWith(mine + '.')) continue;
        // Another version's lock or staging directory belongs to an installer that may still be
        // running (an older plugin version in another session); leave those to it.
        if (/\.(lock|staging-\d+)$/.test(name)) continue;
        removeTree(path.join(DBHUB_BASE, name));
    }
}

function removeDeadStaging() {
    let entries = [];
    try { entries = fs.readdirSync(path.dirname(INSTALL_DIR)); } catch (e) { return; }
    const prefix = path.basename(INSTALL_DIR) + '.staging-';
    for (const name of entries) {
        if (!name.startsWith(prefix)) continue;
        const pid = Number(name.slice(prefix.length));
        if (pid !== process.pid && !isAlive(pid)) removeTree(path.join(path.dirname(INSTALL_DIR), name));
    }
}

// ---------------------------------------------------------------------------------------------
// LOCK -- so two launchers starting together download once, not twice. Correctness does not
// depend on it (each installer has its own staging directory and the rename decides), so a stale
// lock is simply taken over.
//
// Returns { taken: true } when the lock is ours, { taken: false } when another installer holds it,
// and { error } when the lock cannot be created at all -- that last one is not "somebody else is
// installing", and must not be reported as if it were.
function takeLock() {
    for (let attempt = 0; attempt < 2; attempt++) {
        try {
            fs.mkdirSync(path.dirname(LOCK_DIR), { recursive: true });
            fs.mkdirSync(LOCK_DIR);
            return { taken: true };
        } catch (e) {
            if (e.code !== 'EEXIST') return { taken: false, error: `cannot create ${LOCK_DIR}: ${e.message}` };
            if (!lockIsStale()) return { taken: false };
            removeTree(LOCK_DIR);
        }
    }
    return { taken: false };
}

function releaseLock() {
    removeTree(LOCK_DIR);
}

function lockIsStale() {
    let age = 0;
    try { age = Date.now() - fs.statSync(LOCK_DIR).mtimeMs; } catch (e) { return false; }
    if (age > WAIT_LIMIT_MS) return true;
    let pid = 0;
    try { pid = Number(fs.readFileSync(LOCK_PID_FILE, 'utf8').trim()); } catch (e) { pid = 0; }
    // No pid yet: the launcher that took the lock is between mkdir and writing it.
    if (!pid) return age > 60 * 1000;
    return !isAlive(pid);
}
