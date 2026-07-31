#!/usr/bin/env bash
# ps1-delegate.test.sh (shUnit2)
#
# Unit tests for plugins/turbo-plugin-dotnet-framework/scripts/lib/ps1-delegate.sh.
# ps1-delegate dispatches `bash <script>` to `powershell -File <SCRIPTS_DIR>/<script>.ps1 <args...>`.
#
# Cases:
#   1. happy dispatch: a temp scripts/lib/ps1-delegate.sh sibling fake.ps1 that writes a sentinel
#      and exits 0 → delegate invocation prints sentinel, exit code 0.
#   2. missing .ps1: delegate to a non-existent script → powershell -File errors, non-zero exit.
#   3. passthrough exit code: fake.ps1 exits with code 42 → delegate exits 42 (PS error codes pass).
#   4. --kebab-case → -PascalCase translation, incl. the multi-word case that used to fail silently.
#
# ps1-delegate invokes real powershell; on a runner without it the cases SKIP cleanly.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
DELEGATE="$PLUGIN_ROOT/scripts/lib/ps1-delegate.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    # `powershell` specifically, NOT "powershell or pwsh". These scripts reach PowerShell through
    # ps1-delegate.sh, which runs `exec powershell ...` literally, so pwsh being installed does not
    # make them work -- and ubuntu runners DO have pwsh (Pester needs it), which made this gate
    # report "available" and then fail with `powershell: not found`.
    if command -v powershell >/dev/null 2>&1; then HAS_PS=1; fi
}

setUp() {
    [ "$HAS_PS" -eq 1 ] || return 0
    TMPDIR_RT="$(mktemp -d -t turbo-ps1delegate-XXXXXX)"
    mkdir -p "$TMPDIR_RT/scripts/lib"
    cp "$DELEGATE" "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
    chmod +x "$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
    DELEGATE_FAKE="$TMPDIR_RT/scripts/lib/ps1-delegate.sh"
}

tearDown() {
    [ -n "${TMPDIR_RT:-}" ] && rm -rf "$TMPDIR_RT" 2>/dev/null || true
}

test_delegate_exists() {
    [ -f "$DELEGATE" ]
    assertTrue 'ps1-delegate.sh exists' $?
}

test_happy_dispatch() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-happy.ps1" <<'PS1'
[Console]::Out.WriteLine('SENTINEL_TURBO_DELEGATE_OK')
exit 0
PS1
    local out rc
    out="$("$DELEGATE_FAKE" fake-happy 2>&1)"; rc=$?
    assertEquals "Case 1: happy dispatch exit 0 (out=${out:0:200})" 0 "$rc"
    case "$out" in
        *SENTINEL_TURBO_DELEGATE_OK*) assertTrue 'Case 1: sentinel observed' 0 ;;
        *) fail "Case 1: sentinel missing, out='${out:0:200}'" ;;
    esac
}

test_missing_ps1_nonzero() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local rc
    "$DELEGATE_FAKE" no-such-script-here >/dev/null 2>&1; rc=$?
    assertNotEquals 'Case 2: missing .ps1 — delegate exits non-zero' 0 "$rc"
}

test_passthrough_exit_code() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-exit42.ps1" <<'PS1'
exit 42
PS1
    local rc
    "$DELEGATE_FAKE" fake-exit42 >/dev/null 2>&1; rc=$?
    assertEquals 'Case 3: passthrough exit code 42' 42 "$rc"
}

# Case 4: `--kebab-case` reaches the .ps1 as `-PascalCase`.
#
# The regression this locks down: with a zero-translation delegate `--project` bound by coincidence
# (one word, matches -Project) while `--remove-all` never bound -RemoveAll -- one flag worked, the
# next silently did not. The multi-word assertion is the one that matters; the rest guard the
# passthrough cases so translation cannot start eating things it should not.
test_kebab_to_pascal_translation() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-args.ps1" <<'PS1'
param(
    [string]$Project = '',
    [switch]$RemoveAll,
    [string]$RepoRoot = ''
)
[Console]::Out.WriteLine("P=[$Project] RA=[$RemoveAll] RR=[$RepoRoot]")
exit 0
PS1
    local out
    out="$("$DELEGATE_FAKE" fake-args --remove-all --project 'a b.csproj' --repo-root /c/tmp/x 2>&1)"
    case "$out" in
        *'RA=[True]'*) assertTrue 'Case 4: --remove-all bound -RemoveAll (the multi-word regression)' 0 ;;
        *) fail "Case 4: --remove-all did not bind, out='${out:0:200}'" ;;
    esac
    case "$out" in
        *'P=[a b.csproj]'*) assertTrue 'Case 4: value with a space survives untranslated' 0 ;;
        *) fail "Case 4: spaced value mangled, out='${out:0:200}'" ;;
    esac
    # The VALUE must arrive as a path, never rewritten into a flag. It is matched loosely on
    # purpose: MSYS rewrites a POSIX-looking argv path into Windows form (`/c/tmp/x` -> `C:/tmp/x`)
    # before it reaches powershell.exe. That happens outside this delegate, and it is the form
    # PowerShell wants, so pinning the exact spelling would be testing MSYS, not us.
    case "$out" in
        *'RR=['*'tmp/x]'*) assertTrue 'Case 4: the --repo-root VALUE stays a path (not flag-translated)' 0 ;;
        *) fail "Case 4: --repo-root value mangled, out='${out:0:200}'" ;;
    esac
}

# Already-PascalCase args must keep working unchanged: the .sh entry points are also called
# directly with .ps1-style flags in existing scripts and docs.
test_pascal_args_pass_through() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-args2.ps1" <<'PS1'
param(
    [string]$Project = '',
    [switch]$RemoveAll
)
[Console]::Out.WriteLine("P=[$Project] RA=[$RemoveAll]")
exit 0
PS1
    local out
    out="$("$DELEGATE_FAKE" fake-args2 -RemoveAll -Project x.csproj 2>&1)"
    case "$out" in
        *'RA=[True]'*'P=[x.csproj]'*|*'P=[x.csproj]'*'RA=[True]'*) assertTrue 'Case 4b: -PascalCase still binds' 0 ;;
        *) fail "Case 4b: PascalCase args broke, out='${out:0:200}'" ;;
    esac
}

# No args at all: `set -u` + an empty array is an unbound-variable error unless the expansion is
# guarded. This case exists because the translation loop introduced that array.
test_no_args_still_dispatches() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    cat > "$TMPDIR_RT/scripts/fake-noargs.ps1" <<'PS1'
[Console]::Out.WriteLine('SENTINEL_NOARGS_OK')
exit 0
PS1
    local out rc
    out="$("$DELEGATE_FAKE" fake-noargs 2>&1)"; rc=$?
    assertEquals "Case 4c: no-arg dispatch exit 0 (out=${out:0:200})" 0 "$rc"
    case "$out" in
        *SENTINEL_NOARGS_OK*) assertTrue 'Case 4c: sentinel observed' 0 ;;
        *) fail "Case 4c: sentinel missing, out='${out:0:200}'" ;;
    esac
}

# shellcheck disable=SC1090
. "$SHUNIT2"
