#!/usr/bin/env bash
# reset-fixture.sh
#
# Bash equivalent of Reset-Fixture.ps1 for turbo-plugin-dotnet-framework Script tests.
# Mirrors the base web-app fixture into the gitignored sandbox workspace (rsync, or a
# rm+cp fallback when rsync is unavailable, e.g. Git Bash on Windows).
#
# This plugin has NO SVN concern. The monolith's reset also rebuilt an SVN repo + checked
# out remote-svn worktrees; those steps (and --svn-repo / --dump-path / --skip-svn) were
# dropped in the four-way split -- a .NET-only plugin never needs them.
#
# Default work root is repo-relative, gitignored tests/.sandbox/ (override with --test-root):
#   --test-root  <tests>/.sandbox/test-turbo-plugin
#   --base-dir   <fixtures>/base
#
# Idempotent: any prior state restored to base.

set -euo pipefail

TEST_ROOT=""
BASE_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --test-root)    TEST_ROOT="$2"; shift 2 ;;
        --base-dir)     BASE_DIR="$2"; shift 2 ;;
        *)              echo "Unknown arg: $1" >&2; exit 2 ;;
    esac
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fixtures_dir="$(cd "$script_dir/.." && pwd)"
tests_dir="$(cd "$script_dir/../.." && pwd)"

# Default work root = repo-relative, gitignored tests/.sandbox/.
sandbox_dir="$tests_dir/.sandbox"
[[ -z "$TEST_ROOT" ]] && TEST_ROOT="$sandbox_dir/test-turbo-plugin"
[[ -z "$BASE_DIR" ]] && BASE_DIR="$fixtures_dir/base"

if [[ ! -d "$BASE_DIR" ]]; then
    echo "Base fixture dir does not exist: $BASE_DIR" >&2
    exit 1
fi

# --- Step 1: mirror copy from base (bash equivalent of robocopy /MIR) ---------

mkdir -p "$TEST_ROOT"

if command -v rsync >/dev/null 2>&1; then
    echo "Step 1: rsync -a --delete  $BASE_DIR/  ->  $TEST_ROOT/"
    # Trailing slash on source: copy CONTENTS of base/, not base/ itself.
    rsync -a --delete "$BASE_DIR/" "$TEST_ROOT/"
    echo "  rsync OK"
else
    # Fallback without rsync (e.g. Git Bash on Windows): nuke + recopy = same mirror end state.
    echo "Step 1: rm -rf + cp -a (rsync not available)  $BASE_DIR/  ->  $TEST_ROOT/"
    rm -rf "$TEST_ROOT"
    mkdir -p "$TEST_ROOT"
    cp -a "$BASE_DIR/." "$TEST_ROOT/"
    echo "  cp -a OK"
fi

echo ""
echo "Fixture reset complete."
echo "  Workspace: $TEST_ROOT"
