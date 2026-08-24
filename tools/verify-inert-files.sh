#!/usr/bin/env bash
# verify-inert-files.sh — prove, by experiment, that the "inert" files really are inert.
#
# `affected-plugins.sh` may answer `NONE` -- run no plugin suite at all -- when every changed path
# is on its inert list. That answer rests on one claim about this repository:
#
#     NOTHING that runs in CI depends on the CONTENT of those files.
#
# The script cannot check that claim about itself, and until now the only thing standing behind it
# was `test_no_test_reads_an_inert_file`: a grep over test SOURCE looking for "a line that both
# names an inert file and looks like it leaves its own directory". That heuristic is guessing how
# people usually write things, and it has two known blind spots -- computing a path on one line and
# opening it on the next, and only ever looking inside `plugins/*/tests/` and `tools/tests/`.
#
# This does not read code. It runs the experiment the claim describes:
#
#   1. replace the CONTENT of every inert file with garbage -- the files stay, only their bytes
#      change. "Content is irrelevant" is the property actually being relied on; release-please
#      rewrites these files on every Release PR, so "the file may be missing" was never the claim.
#   2. run the suites.
#   3. if the claim holds, nothing notices.
#
# Anything that reads one of them fails, whatever language it is written in and however it spells
# the read. That is the whole point: the grep guard asks "does this look like a read?", this asks
# "did it make a difference?".
#
# The inert list is NOT written down here. It is derived by asking `affected-plugins.sh` itself,
# one path at a time -- a path is inert exactly when the classifier answers `NONE` for it alone.
# A second copy of that list would drift, and the drift would be silent in the worst direction:
# someone adds an inert entry, this experiment never covers it, and the gap looks like a pass.
#
# Usage:
#   verify-inert-files.sh            run the experiment (this is what CI does)
#   verify-inert-files.sh --list     print what it would garble and what it would run, then stop
#
# `TP_INERT_SUITES` overrides the commands to run (newline-separated), for the tests only.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT" || exit 2

# Overridable so the tests can drive the "derived nothing" guard below; nothing in CI sets it.
CLASSIFIER="${TP_INERT_CLASSIFIER:-$REPO_ROOT/tools/affected-plugins.sh}"
GARBLE_TEXT='### replaced by tools/verify-inert-files.sh. If anything failed because of this line,
### that file is NOT inert and must come off the inert list in tools/affected-plugins.sh.'

note() { printf '%s\n' "verify-inert-files: $*" >&2; }

# --- the inert set, derived rather than declared -------------------------------------------------
list_inert() {
    # `TP_INERT_FILES` is a tests-only shortcut, like TP_INERT_SUITES. The derivation below spawns
    # the classifier once per tracked file -- cheap on a Linux runner (~1s for 329 files), but on
    # Windows process creation is slow enough that ten derivations turned the seven-second tools
    # suite into ten minutes. The suite derives once and reuses the answer; nothing in CI sets this.
    if [ -n "${TP_INERT_FILES:-}" ]; then
        printf '%s\n' "$TP_INERT_FILES"
        return 0
    fi
    local f ans
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        ans="$(printf '%s\n' "$f" | bash "$CLASSIFIER" 2>/dev/null)"
        [ "$ans" = 'NONE' ] && printf '%s\n' "$f"
    done < <(git ls-files)
    return 0
}

# --- the suites, globbed rather than declared ----------------------------------------------------
#
# Globbed for the same reason the matrix in tests.yml is generated: "add a plugin, edit no
# workflow". A hardcoded list would leave a new plugin out of this experiment silently.
list_suites() {
    if [ -n "${TP_INERT_SUITES:-}" ]; then
        printf '%s\n' "$TP_INERT_SUITES"
        return 0
    fi
    printf '%s\n' "bash tools/tests/invoke-script-tests.sh"
    local s
    for s in plugins/*/tests/invoke-script-tests.sh; do
        [ -f "$s" ] && printf '%s\n' "bash $s"
    done
    return 0
}

# The suites this runs include tools/, and tools/ has a suite FOR this script -- so without this
# guard the experiment re-enters itself. That is not merely wasteful: the inner run would restore
# the files it found garbled, un-garbling them for everything the outer run had left to do, and the
# outer run would then be testing nothing while reporting success.
if [ -n "${TP_INERT_RUNNING:-}" ] && [ "${1:-}" != '--list' ]; then
    note '::error::refusing to run inside another verify-inert-files run (it would un-garble the'
    note '           files mid-experiment). The suite that reached here should skip when'
    note '           TP_INERT_RUNNING is set.'
    exit 2
fi

if [ "${1:-}" = '--list' ]; then
    printf 'inert files:\n'
    list_inert | sed 's/^/  /'
    printf 'suites:\n'
    list_suites | sed 's/^/  /'
    exit 0
fi
if [ "$#" -gt 0 ]; then
    note "usage: verify-inert-files.sh [--list]"
    exit 2
fi

INERT="$(list_inert)"

# Drop whitespace-only lines before anything treats them as paths. A line of spaces is not blank to
# `[ -n ]`, so it reaches the garble loop as a filename and `> "$f"` CREATES a file called "   " in
# the repo root -- observed while testing this. Filtering here also means the emptiness check below
# sees "nothing usable" rather than "one unusable thing".
INERT="$(printf '%s\n' "$INERT" | grep -E '[^[:space:]]')" || INERT=''

if [ -z "$INERT" ]; then
    # Deriving nothing means the classifier changed shape or could not be run. Treating that as
    # "nothing to check, all good" would retire this experiment without anyone noticing.
    note '::error::derived an EMPTY inert list; the classifier is not answering NONE for anything'
    exit 1
fi

# Restoring is `git checkout --`, which discards working-tree changes. On a developer's machine
# that would silently destroy uncommitted edits to one of these files, so refuse up front rather
# than find out afterwards.
DIRTY="$(printf '%s\n' "$INERT" | tr '\n' '\0' | xargs -0 -r git status --porcelain -- 2>/dev/null)"
if [ -n "$DIRTY" ]; then
    note '::error::refusing to run: some inert files have uncommitted changes, and this'
    note '           experiment restores them with `git checkout --`, which would discard those:'
    printf '%s\n' "$DIRTY" | sed 's/^/             /' >&2
    exit 2
fi

restore() {
    printf '%s\n' "$INERT" | tr '\n' '\0' | xargs -0 -r git checkout -- 2>/dev/null
}
trap restore EXIT INT TERM

count=0
while IFS= read -r f; do
    [ -n "$f" ] || continue
    printf '%s\n' "$GARBLE_TEXT" > "$f"
    count=$(( count + 1 ))
done <<< "$INERT"
if [ "$count" -eq 0 ]; then
    # Separate from the empty-list check above, and not redundant with it: a list of nothing but
    # blank lines survives that one and lands here having garbled nothing at all. The suites would
    # then run against pristine files and pass, which is the experiment reporting success for
    # having done nothing -- the precise failure it exists to make impossible.
    note '::error::garbled 0 files; the derived list contained no usable paths'
    exit 1
fi
note "replaced the contents of $count inert file(s); running the suites"

# Resolve the suite list BEFORE clearing the override: the `done <<< "$(...)"` form would expand
# after the unset and quietly fall back to the globbed list, so the tests' own override would stop
# working with nothing to show for it.
SUITES="$(list_suites)"

export TP_INERT_RUNNING=1
# Not inherited by the suites: a nested `--list` would otherwise echo this override instead of the
# real globbed list, which is exactly what one of those suites asserts about.
unset TP_INERT_SUITES TP_INERT_FILES

rc=0
while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    note "--- $cmd"
    if ! eval "$cmd"; then
        note "::error::'$cmd' failed while the inert files held garbage."
        note "          Something depends on the CONTENT of a file the classifier treats as inert,"
        note "          so a Release-PR-shaped diff would skip a suite that actually needed to run."
        rc=1
    fi
done <<< "$SUITES"

if [ "$rc" -eq 0 ]; then
    note "all suites passed with $count inert file(s) garbled; the inert list holds"
fi
exit "$rc"
