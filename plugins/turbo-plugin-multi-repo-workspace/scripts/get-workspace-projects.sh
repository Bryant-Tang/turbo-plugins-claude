#!/usr/bin/env bash
# Usage: get-workspace-projects.sh [--workspace-root <path>]
#
# Read-only survey of a multi-repo workspace: a folder that is NOT itself a git repository but
# holds several independent projects side by side.
#
# Output contract (mirrors the git-svn scripts): zero or more plain `PROJECT ...` data lines,
# then EXACTLY ONE terminal line prefixed `TP_TOKEN:` that the SKILL routes on. `path=` is always
# the LAST field on a line so a path containing spaces needs no quoting or escaping.
#
#   PROJECT setup=<yes|no> main=<yes|no> path=<absolute>
#   TP_TOKEN:PROJECTS count=<N>            one or more projects found
#   TP_TOKEN:WORKSPACE_IS_REPO path=<abs>  the folder is itself a repo -> not a multi-repo workspace
#   TP_TOKEN:NO_PROJECTS path=<abs>        not a repo, and no direct child is one either
#   TP_TOKEN:ERROR reason=<text>           anything else
#
# `setup=` reports whether that project already has a `.turbo-plugin/` marker (so the SKILL can
# offer setup only where it is missing). `main=` reports whether the project directory is its own
# main worktree; a linked worktree of some other repo answers `no`, and git-svn's own setup would
# refuse it, so the SKILL must not offer setup there.
#
# ONLY direct children are scanned. That is deliberate and load-bearing: git-svn keeps its bridge
# worktrees at `<project>/.turbo-plugin/worktrees/remote-svn-*`, each of which carries a `.git`
# file. Those are grandchildren, so scanning one level deep never mistakes a bridge for a project.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/core.sh"

WORKSPACE_ROOT=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace-root) [[ $# -ge 2 ]] || { echo "Error: --workspace-root requires a value" >&2; exit 1; }; WORKSPACE_ROOT="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

# Collapse a value onto one line and neutralise any embedded token prefix, so a directory name
# cannot forge a routing line the SKILL would then trust.
_flatten() {
  printf '%s' "$1" | tr '\r\n' '  ' | sed 's/TP_TOKEN:/TP_TOKEN_/g'
}

# Terminal ERROR token on the SKILL's routing channel (parity with the .ps1 catch), so a failure
# is never a tokenless non-zero exit.
_die_token() {
  echo "TP_TOKEN:ERROR reason=$(_flatten "$1")"
  exit 1
}

if ! probe_git_version 2>/dev/null; then
  _die_token 'git CLI not available on PATH, or older than 2.31.'
fi

if [[ -z "$WORKSPACE_ROOT" ]]; then
  WORKSPACE_ROOT="$PWD"
fi
if ! ROOT="$(get_normalized_absolute_path "$WORKSPACE_ROOT" 2>&1)"; then
  _die_token "$ROOT"
fi
if [[ ! -d "$ROOT" ]]; then
  _die_token "Workspace root not found (or not a directory): $WORKSPACE_ROOT"
fi

# Is the workspace folder itself a repository? `git rev-parse` searches UPWARD, so this also
# catches "the folder sits inside a repo", which is equally not a multi-repo workspace.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  echo "TP_TOKEN:WORKSPACE_IS_REPO path=$(_flatten "$ROOT")"
  exit 0
fi

LINES=''
COUNT=0
for child in "$ROOT"/*/; do
  [[ -d "$child" ]] || continue
  # `.git` is a directory in a normal clone and a FILE in a linked worktree; -e accepts both,
  # which is what the git-svn nested-repo guard also keys on. Keeping the two in agreement
  # matters: this script decides what to offer setup for, and that guard decides what setup
  # refuses.
  [[ -e "${child}.git" ]] || continue

  child="${child%/}"
  if ! abs="$(get_normalized_absolute_path "$child" 2>&1)"; then
    _die_token "$abs"
  fi

  setup='no'
  [[ -d "${child}/.turbo-plugin" ]] && setup='yes'
  main='no'
  if test_is_main_worktree "$child"; then main='yes'; fi

  LINES="${LINES}PROJECT setup=${setup} main=${main} path=$(_flatten "$abs")"$'\n'
  COUNT=$((COUNT + 1))
done

if [[ "$COUNT" -eq 0 ]]; then
  echo "TP_TOKEN:NO_PROJECTS path=$(_flatten "$ROOT")"
  exit 0
fi

printf '%s' "$LINES"
echo "TP_TOKEN:PROJECTS count=$COUNT"
exit 0
