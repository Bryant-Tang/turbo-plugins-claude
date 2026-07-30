#!/usr/bin/env bash
# Usage: get-svn-log.sh [--branch <branch>] [--limit <n>] [--revision <spec>] [--verbose]
#
# Always invokes `svn log --xml`: SVN emits UTF-8 XML regardless of console
# codepage / locale, avoiding mojibake (e.g. zh-TW commit messages turning
# into `?`). The XML is formatted to plain text by svn_log_format_xml (lib/common.sh),
# a self-contained awk tokenizer -- no external XML tooling required (none is
# reliably present in Git Bash on Windows, the primary host).
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
LIMIT='5'
REVISION=''
VERBOSE=false
# Optional explicit repository root; omit to act on the current directory (see resolve_git_root).
REPO_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)    [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --limit)     [[ $# -ge 2 ]] || { echo "Error: --limit requires a value" >&2; exit 1; }; LIMIT="$2"; shift 2 ;;
    --revision)  [[ $# -ge 2 ]] || { echo "Error: --revision requires a value" >&2; exit 1; }; REVISION="$2"; shift 2 ;;
    --repo-root) [[ $# -ge 2 ]] || { echo "Error: --repo-root requires a value" >&2; exit 1; }; REPO_ROOT="$2"; shift 2 ;;
    --verbose)   VERBOSE=true; shift ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --limit must be a positive integer (got '$LIMIT')." >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree "$REPO_ROOT")"
WORKTREES_DIR="$(get_worktrees_dir "$MAIN_WORKTREE")"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

# Build svn args. SAFETY: every value goes in its own array element (with
# double-quoted expansion below), never string-concatenated. This is the
# separate-arg invariant required by F10 -- see the matching PS comment.
SVN_ARGS=(log --xml --limit "$LIMIT")
[[ "$VERBOSE" == true ]] && SVN_ARGS+=(-v)
if [[ -n "$REVISION" ]]; then
  SVN_ARGS+=(--revision "$REVISION")
fi
SVN_ARGS+=("$REMOTE_PATH")

XML="$(svn "${SVN_ARGS[@]}")"

# Empty XML (no entries) -- exit cleanly without emitting a trailer.
if [[ -z "$XML" ]]; then
  exit 0
fi

# svn_log_format_xml (lib/common.sh) parses the XML and emits the plain-text
# "r<rev> | author | date | msg" lines (+ verbose per-path lines + trailer).
printf '%s' "$XML" | svn_log_format_xml "$VERBOSE"
