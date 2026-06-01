#!/usr/bin/env bash
# reset-fixture.sh
#
# Bash equivalent of Reset-Fixture.ps1. Uses rsync -a --delete instead of robocopy.
#
# On Windows this is exercised via Git Bash (the .sh phase 1 test path). On Linux/macOS
# native it works the same modulo the svnadmin dump format compatibility (out of scope
# for v1.0 — see plan K-Decision).
#
# Defaults match the PS version:
#   --test-root C:\Turbo\test-turbo-plugin\test-turbo-plugin       (override with --test-root <path>)
#   --svn-repo  C:\Turbo\test-turbo-plugin\svn-repo
#
# Idempotent: any prior state restored to base.

set -euo pipefail

TEST_ROOT="C:/Turbo/test-turbo-plugin/test-turbo-plugin"
SVN_REPO="C:/Turbo/test-turbo-plugin/svn-repo"
BASE_DIR=""
DUMP_PATH=""
SKIP_SVN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-root)    TEST_ROOT="$2"; shift 2 ;;
        --svn-repo)     SVN_REPO="$2"; shift 2 ;;
        --base-dir)     BASE_DIR="$2"; shift 2 ;;
        --dump-path)    DUMP_PATH="$2"; shift 2 ;;
        --skip-svn)     SKIP_SVN=1; shift ;;
        *)              echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_dir="$(cd "$script_dir/.." && pwd)"

[[ -z "$BASE_DIR" ]] && BASE_DIR="$fixtures_dir/base"
[[ -z "$DUMP_PATH" ]] && DUMP_PATH="$fixtures_dir/seed/svn-repo-r1-r20.dump"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Base fixture dir does not exist: $BASE_DIR" >&2
    exit 1
fi
if [[ $SKIP_SVN -eq 0 ]] && [[ ! -f "$DUMP_PATH" ]]; then
    echo "SVN seed dump does not exist: $DUMP_PATH" >&2
    echo "Run plugins/turbo-plugin/tests/fixtures/seed/build-seed-repo.sh first (or pass --skip-svn)." >&2
    exit 1
fi

# ─── Step 1: mirror copy from base (bash equivalent of robocopy /MIR) ────────

mkdir -p "$TEST_ROOT"

if command -v rsync >/dev/null 2>&1; then
    echo "Step 1: rsync -a --delete  $BASE_DIR/  ->  $TEST_ROOT/"
    # Note trailing slash on source: copy CONTENTS of base/, not base/ itself.
    rsync -a --delete "$BASE_DIR/" "$TEST_ROOT/"
    echo "  rsync OK"
else
    # Fallback for environments without rsync (e.g., Git Bash on Windows).
    # Nuke + recopy achieves the same end state (mirror) as rsync --delete
    # since this is a fixture reset — we want clean state from base.
    echo "Step 1: rm -rf + cp -a (rsync not available)  $BASE_DIR/  ->  $TEST_ROOT/"
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
    cp -a "$BASE_DIR/." "$TEST_ROOT/"
    echo "  cp -a OK"
fi

# ─── Step 2: SVN repo reset ───────────────────────────────────────────────────

if [[ $SKIP_SVN -eq 0 ]]; then
    echo "Step 2: rebuild SVN repo at $SVN_REPO from $DUMP_PATH"

    if [[ -d "$SVN_REPO" ]]; then
        rm -rf "$SVN_REPO"
    fi
    mkdir -p "$(dirname "$SVN_REPO")"

    svnadmin create "$SVN_REPO"
    svnadmin load "$SVN_REPO" < "$DUMP_PATH" > /dev/null
    echo "  svnadmin load OK"

    # ─── Step 3: svn checkout remote-main / remote-test-1 ─────────────────────
    #
    # Sibling layout (tgs convention): <TEST_ROOT>.worktrees/ 與 <TEST_ROOT>/ 同層,
    # 中間用 '.' 分隔。所有 turbo-plugin script 都讀 sibling 路徑,**不**用 nested
    # <TEST_ROOT>/.worktrees/。

    worktrees_dir="${TEST_ROOT}.worktrees"
    remote_main_dir="$worktrees_dir/remote-main"
    remote_test1_dir="$worktrees_dir/remote-test-1"

    # Wipe entire sibling worktrees container for per-case clean slate
    [[ -d "$worktrees_dir" ]] && rm -rf "$worktrees_dir"
    mkdir -p "$worktrees_dir"

    # Build file:/// URI; on Windows convert backslashes.
    repo_uri="file:///${SVN_REPO//\\//}"

    echo "Step 3a: svn checkout trunk -> $remote_main_dir"
    svn checkout "$repo_uri/trunk" "$remote_main_dir" > /dev/null

    echo "Step 3b: svn checkout branches/test-1 -> $remote_test1_dir"
    svn checkout "$repo_uri/branches/test-1" "$remote_test1_dir" > /dev/null
fi

echo ""
echo "✔ Fixture reset complete."
echo "  Workspace: $TEST_ROOT"
if [[ $SKIP_SVN -eq 0 ]]; then
    echo "  SVN repo:  $SVN_REPO (loaded from $DUMP_PATH)"
    echo "  Remote-*:  ${TEST_ROOT}.worktrees/{remote-main, remote-test-1}"
else
    echo "  (SVN reset skipped)"
fi
