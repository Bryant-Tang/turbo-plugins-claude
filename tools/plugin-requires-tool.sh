#!/usr/bin/env bash
# plugin-requires-tool.sh
#
# Answer "does this plugin's test suite need <tool> installed on the runner?"
#
#   usage  : plugin-requires-tool.sh <plugin-path> <tool>
#   stdout : `true` or `false` -- shaped for `$GITHUB_OUTPUT`, so a workflow `if:` can read it
#   exit   : 0 on an answer; 2 on usage error
#
# WHY THIS EXISTS. The `Install Subversion` step used to run for EVERY plugin, gated only on "was
# this plugin touched by the change". Only turbo-plugin-git-svn has ever needed svn; the other
# suites paid an apt/choco install to reach tests that then self-SKIP. On 2026-08-18 that unused
# dependency cost 49 minutes: apt wedged on the ubuntu runner and the whole job sat there, while
# the very same commit's other run passed. A dependency nothing uses can still take the job down.
#
# WHY A DECLARATION FILE AND NOT `if matrix.plugin == git-svn`. Hard-coding the name in the
# workflow breaks the property that makes this repo's CI maintainable: add a plugin, edit no
# workflow. A plugin that starts needing svn should say so IN ITSELF, next to the tests that need
# it, rather than in a file its author has no reason to open.
#
# WHY A SCRIPT AND NOT AN INLINE `run:` BLOCK. CLAUDE.md: logic inside a `run:` block can only be
# verified by pushing, and the way it breaks is "some tests silently never ran, screen still
# green". This is a plain function with tests.
#
# THE DECLARATION
#   plugins/<name>/tests/required-tools -- one tool name per line, `#` comments and blanks ignored.
#   ABSENCE MEANS "needs nothing". That has to be the default: five of six plugins need nothing,
#   and a convention that requires every plugin to carry an empty file is a convention people
#   forget, in the direction that installs everything again.
#
# FAILURE DIRECTION. Unreadable input answers `true` (install it). The two directions are not
# symmetric: installing something unnecessary costs runner minutes, while NOT installing something
# needed makes its tests self-SKIP -- and a SKIP counts as green here, so the suite would look
# fine while testing nothing. Every uncertain case therefore errs toward installing.
set -uo pipefail

PLUGIN="${1-}"
TOOL="${2-}"

if [[ -z "$PLUGIN" || -z "$TOOL" ]]; then
  printf 'usage: %s <plugin-path> <tool>\n' "${0##*/}" >&2
  exit 2
fi

# A path we cannot inspect is the uncertain case, not the "needs nothing" case.
if [[ ! -d "$PLUGIN" ]]; then
  printf 'plugin-requires-tool: no such directory: %s -- answering true\n' "$PLUGIN" >&2
  printf 'true\n'
  exit 0
fi

SPEC="$PLUGIN/tests/required-tools"

# No declaration is a definite answer ("needs nothing"), NOT an uncertain one.
if [[ ! -f "$SPEC" ]]; then
  printf 'false\n'
  exit 0
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%%#*}"                       # strip comments
  line="${line#"${line%%[![:space:]]*}"}"  # ltrim
  line="${line%"${line##*[![:space:]]}"}"  # rtrim
  [[ -n "$line" ]] || continue
  if [[ "$line" == "$TOOL" ]]; then
    printf 'true\n'
    exit 0
  fi
done < "$SPEC"

printf 'false\n'
exit 0
