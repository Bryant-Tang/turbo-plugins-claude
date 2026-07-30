#!/usr/bin/env bash
# Shared test helper: build a file:// URI for a local svn repo path.
#
# ONE definition on purpose. This existed as four near-copies across the test files, and the fourth
# one was subtly wrong: it did `uri="file:///$winpath"` with no cygpath fallback, so on Linux --
# where `cygpath` does not exist and the path already starts with `/` -- it produced
# `file:////tmp/...` with FOUR slashes. svn then read a different repository root than the one the
# trust check had recorded, and the bridge tests failed with "untrusted SVN URL". Nobody saw it
# because the .sh suite had only ever run on Git Bash, where cygpath is present.
#
# The slash count is the whole subtlety: a Windows drive path (`C:/repo`) needs `file:///` + path,
# while a POSIX path (`/tmp/repo`) already supplies its own leading slash and needs `file://` + path.

# Echo a file:// URI for an svn repo path. Args: <repo_path>
svn_uri() {
    local repo="$1" win
    if command -v cygpath >/dev/null 2>&1; then
        # Windows / Git Bash: -m gives the drive form with forward slashes (C:/repo).
        win="$(cygpath -m "$repo")"
        printf 'file:///%s' "$win"
    else
        # POSIX: the path already begins with '/', so only two slashes belong to the scheme.
        printf 'file://%s' "$repo"
    fi
}
