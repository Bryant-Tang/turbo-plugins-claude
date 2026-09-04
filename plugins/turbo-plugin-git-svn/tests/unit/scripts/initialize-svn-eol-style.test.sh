#!/usr/bin/env bash
# initialize-svn-eol-style.test.sh (shUnit2)
# Script under test: scripts/initialize-svn-eol-style.sh
#
# The fixture is a REAL bridge -- one directory that is both a git worktree and an SVN working
# copy -- because that pairing is the whole subject. A fixture where the two are separate would
# exercise none of the interesting behaviour: the classifier reads git, the property writing goes
# through svn, and the failures live in the seam.
#
# Covers:
#   - --preview reports and leaves the working copy exactly as it found it
#   - binaries and mixed-ending files are excluded, and the mixed ones are NAMED
#   - the apply path marks text files, commits, and SVN then stores LF
#   - a dirty bridge is refused rather than swept into the property commit

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SUT="$PLUGIN_ROOT/scripts/initialize-svn-eol-style.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

svn_available() { command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; }

oneTimeSetUp() {
    HAS_SVN=0
    svn_available && HAS_SVN=1
}

# Build root + a bridge that is genuinely both things. Echoes the root; non-zero on failure.
#
# Order matters and mirrors the production bootstrap: `git worktree add --no-checkout` first so
# the directory is a git worktree, then `svn checkout --force` to overlay SVN's content and
# metadata, then a git checkout to bring the tracked files onto disk.
make_bridge_fixture() {
    local sandbox="$1"
    local root="$sandbox/repo"
    local svnrepo="$sandbox/svnrepo"
    local bridge="$root/.turbo-plugin/worktrees/remote-svn-main"

    svnadmin create "$svnrepo" >/dev/null 2>&1 || return 1
    local uri
    uri="file:///$(cygpath -m "$svnrepo" 2>/dev/null || echo "$svnrepo")"

    # Seed trunk through a throwaway working copy.
    local seed="$sandbox/seed"
    svn --non-interactive checkout -q "$uri" "$seed" >/dev/null 2>&1 || return 1
    mkdir -p "$seed/trunk" || return 1
    printf 'alpha\nbeta\n'      > "$seed/trunk/plain.txt"
    printf 'one\r\ntwo\n'       > "$seed/trunk/mixed.txt"
    printf 'x\0y\0'             > "$seed/trunk/blob.bin"
    # Stored as CRLF with no property -- the shape issue #164 left behind. The migration is
    # supposed to normalise this in the repository, which is the whole point of running it.
    printf 'red\r\ngreen\r\n'   > "$seed/trunk/wascrlf.txt"
    svn --non-interactive add -q "$seed/trunk" >/dev/null 2>&1 || return 1
    svn --non-interactive commit -q -m seed "$seed" >/dev/null 2>&1 || return 1

    mkdir -p "$root" || return 1
    git -C "$root" init -q -b main >/dev/null 2>&1 || return 1
    git -C "$root" config user.email 'test@turbo-plugin' || return 1
    git -C "$root" config user.name 'turbo-plugin-test' || return 1
    git -C "$root" config core.autocrlf false || return 1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1 || return 1
    git -C "$root" -c commit.gpgsign=false commit -qm initial >/dev/null 2>&1 || return 1

    mkdir -p "$root/.turbo-plugin/worktrees" || return 1
    git -C "$root" worktree add -q --no-checkout "$bridge" -b 'remote-svn/main' >/dev/null 2>&1 || return 1
    svn --non-interactive checkout -q --force "$uri/trunk" "$bridge" >/dev/null 2>&1 || return 1
    svn --non-interactive propset -q svn:ignore '.git' "$bridge" >/dev/null 2>&1 || return 1
    # Keep .svn out of git, as the production bootstrap does. It goes in the COMMON git dir's
    # info/exclude because git does not read a linked worktree's own. Without it the bridge is
    # permanently git-dirty -- svn rewrites .svn/wc.db constantly -- and every guard that asks
    # "is this worktree clean?" fires on metadata that was never meant to be tracked.
    mkdir -p "$root/.git/info" || return 1
    printf '.svn/\n' >> "$root/.git/info/exclude" || return 1
    # Take SVN's bytes as the git content, exactly as the production bootstrap does.
    git -C "$bridge" add -A >/dev/null 2>&1 || return 1
    git -C "$bridge" -c commit.gpgsign=false commit -qm 'svn content' >/dev/null 2>&1 || return 1
    svn --non-interactive commit -q -m 'svn:ignore' "$bridge" >/dev/null 2>&1 || return 1

    # Fixture guard: without a real worktree the classifier reads a different repository and every
    # assertion below would measure the wrong tree while still reporting green.
    [ -e "$bridge/.git" ] || return 1
    printf '%s' "$root"
}

svn_eol_prop() {
    svn --non-interactive propget svn:eol-style "$1" 2>/dev/null | tr -d '\r\n'
}

test_script_exists() {
    assertTrue "script under test is missing at $SUT" "[ -f '$SUT' ]"
}

test_preview_reports_and_changes_nothing() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-prev-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"

        out="$(bash "$SUT" --repo-root "$root" --preview 2>&1)" || exit 97

        case "$out" in *'Preview only'*) : ;; *) echo "no preview banner: $out" >&2; exit 1 ;; esac
        # The mixed file must be NAMED, not just counted: it is excluded permanently and nothing
        # afterwards says why.
        case "$out" in *'mixed.txt'*) : ;; *) echo "mixed.txt was not named: $out" >&2; exit 1 ;; esac

        # Nothing may be left staged. `svn status` minus unversioned entries must be empty.
        st="$(cd "$bridge" && svn status | grep -v '^?' || true)"
        if [ -n "$st" ]; then
            echo "preview left the working copy dirty: [$st]" >&2; exit 1
        fi
        if [ -n "$(svn_eol_prop "$bridge/plain.txt")" ]; then
            echo "preview actually set the property" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'preview reports, names the mixed file, and leaves the tree untouched' 0 "$rc"
}

test_apply_marks_text_only_and_commits() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-app-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"
        svnrepo="$tmp/svnrepo"

        bash "$SUT" --repo-root "$root" >/dev/null 2>&1 || exit 97

        if [ "$(svn_eol_prop "$bridge/plain.txt")" != 'native' ]; then
            echo "plain.txt did not get the property" >&2; exit 1
        fi
        # A binary carrying svn:eol-style comes back corrupted; a mixed-ending file makes commit
        # fail atomically. Neither may be touched.
        if [ -n "$(svn_eol_prop "$bridge/mixed.txt")" ]; then
            echo "mixed.txt must stay unset" >&2; exit 1
        fi
        if [ -n "$(svn_eol_prop "$bridge/blob.bin")" ]; then
            echo "blob.bin must stay unset" >&2; exit 1
        fi
        # Committed, not merely staged.
        st="$(cd "$bridge" && svn status | grep -v '^?' || true)"
        if [ -n "$st" ]; then
            echo "changes were not committed: [$st]" >&2; exit 1
        fi

        # The payoff: a file the repository was storing as CRLF is now stored as LF. Reading it
        # back through svnlook rather than through a working copy is deliberate -- a working copy
        # applies the very translation under test, so it would report LF either way.
        cr="$(svnlook cat "$svnrepo" trunk/wascrlf.txt | tr -dc '\r' | wc -c | tr -d ' ')"
        if [ "$cr" -ne 0 ]; then
            echo "SVN still stores CRLF for wascrlf.txt ($cr CR bytes)" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'apply marks text files, skips binary and mixed, and commits' 0 "$rc"
}

test_dirty_bridge_is_refused() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-dirty-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"

        # A pending SVN change must stop the run: the property commit would otherwise sweep it up,
        # and the pull path skips property-only revisions -- so it would reach SVN and never come
        # back into git.
        printf 'alpha\nbeta\ngamma\n' > "$bridge/plain.txt"

        if bash "$SUT" --repo-root "$root" >/dev/null 2>&1; then
            echo "a dirty bridge was accepted" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'a bridge with pending changes is refused' 0 "$rc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
