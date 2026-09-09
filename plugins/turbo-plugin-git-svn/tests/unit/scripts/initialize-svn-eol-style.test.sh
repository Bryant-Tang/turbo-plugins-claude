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
    # true, not false: this is the Git for Windows SYSTEM default, so it is what an unpinned bridge
    # actually inherits on a real user's machine. Pinning the fixture to false would quietly make
    # "unpinned" mean "still expects raw bytes", and the migrate-then-pull case below would be
    # measuring a platform nobody has.
    git -C "$root" config core.autocrlf true || return 1
    echo init > "$root/init.txt"
    git -C "$root" add -A >/dev/null 2>&1 || return 1
    git -C "$root" -c commit.gpgsign=false commit -qm initial >/dev/null 2>&1 || return 1

    mkdir -p "$root/.turbo-plugin/worktrees" || return 1
    git -C "$root" worktree add -q --no-checkout "$bridge" -b 'remote-svn/main' >/dev/null 2>&1 || return 1

    # Pin BEFORE any content lands, which is what production does and what makes this fixture a
    # real pre-migration bridge. Pinning afterwards instead produces a state that cannot occur:
    # blobs normalised under autocrlf=true but read back raw, so the CRLF files mismatch their own
    # blobs. That mismatch is also RACY -- git's racily-clean rule re-hashes a file only when its
    # timestamp differs from the index, so a fixture built inside one second reports dirty
    # sometimes and clean other times. This test was flaky for exactly that reason.
    git -C "$root" config extensions.worktreeConfig true >/dev/null 2>&1 || return 1
    git -C "$bridge" config --worktree core.autocrlf false >/dev/null 2>&1 || return 1
    git -C "$bridge" config --worktree core.eol lf >/dev/null 2>&1 || return 1

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
        # Floor first: an empty read would satisfy "no CR" while proving nothing.
        total="$(svnlook cat "$svnrepo" trunk/wascrlf.txt | wc -c | tr -d ' ')"
        if [ "$total" -eq 0 ]; then
            echo "svnlook returned nothing for wascrlf.txt; the assertion below would be vacuous" >&2; exit 1
        fi
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

# The order that actually breaks people: migrate, then PULL -- without a push in between.
#
# The bridge's EOL mode is read from the SVN tree, so migrating changes what the right mode is. The
# push path refreshes it; for a while the pull path did not, and "migrate then pull" is a perfectly
# ordinary order (check the remote before sending anything). `svn update` would then write platform
# endings into a bridge whose git side was still pinned to LF and every file would read as modified.
#
# It drives the real chokepoint, `svn_position_wc_at_rev`, rather than calling the refresh directly:
# the defect was never in the refresh, it was in nothing calling it.
test_pull_after_migration_leaves_the_bridge_clean() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-pull-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"

        # The fixture already built this as a pre-migration bridge: pinned to LF from before any
        # content landed, which is the state a real upgrading user is in.
        pinned_before="$(git -C "$bridge" config --worktree core.eol 2>/dev/null || true)"
        if [ "$pinned_before" != 'lf' ]; then
            echo "fixture: expected a pinned bridge, core.eol='$pinned_before'" >&2; exit 1
        fi

        bash "$SUT" --repo-root "$root" >/dev/null 2>&1 || exit 97

        # Now do what a pull does. Sourcing the lib is the point: this is the chokepoint every
        # SVN-content write funnels through, and it is where the mode refresh lives.
        # shellcheck source=/dev/null
        . "$PLUGIN_ROOT/scripts/lib/common.sh"
        set +e +u +o pipefail
        rev="$(cd "$bridge" && svn --non-interactive info --show-item revision | tr -d '\r\n')"
        svn_position_wc_at_rev "$bridge" "$rev" >/dev/null 2>&1 || exit 96

        # Asserted on plain.txt, NOT on the whole tree, and the distinction is the point.
        # wascrlf.txt SHOULD show as modified afterwards: the migration really did rewrite it in
        # SVN, from CRLF to LF, and that is a genuine content change waiting to be synced into git.
        # A whole-tree "must be clean" assertion would call that correct behaviour a failure.
        # plain.txt's content nobody touched, so it may only appear if the MODE is wrong -- which
        # is exactly the defect, and pre-fix it took the entire tree with it.
        dirty="$(git -C "$bridge" status --porcelain -- plain.txt 2>/dev/null || true)"
        if [ -n "$dirty" ]; then
            echo "an untouched file reads as modified after migrate-then-pull: [$dirty]" >&2; exit 1
        fi
        # And the pin really is gone -- otherwise "clean" might just mean nothing was rewritten.
        pin="$(git -C "$bridge" config --worktree core.eol 2>/dev/null || true)"
        if [ -n "$pin" ]; then
            echo "the LF pin survived the migration: core.eol=$pin" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'migrating and then pulling unpins the bridge and leaves untouched files alone' 0 "$rc"
}

# A file `svn add` stamps as binary even though it is plain text.
#
# svn reads the first 1024 bytes (after skipping a UTF-8 BOM) and calls the file binary when fewer
# than ~15% of them are "text" bytes -- 0x07-0x0D or 0x20-0x7F. Every byte of UTF-8 CJK is outside
# that set, so a prose document in Chinese with few ASCII markers lands on the wrong side of the
# line. Measured against real svn: 153 text bytes is text, 152 is binary. This writes 152.
#
# The NAME matters. The candidate list is sorted, and `svn propset --targets` stops at the first
# file it cannot mark -- so a name sorting first would fail before anything else was staged, and
# the revert this test is about would have nothing to undo while the test still passed.
write_svn_binary_mime_file() {
    local path="$1"
    # shellcheck disable=SC2046
    printf 'a%.0s' $(seq 152) > "$path" || return 1
    # \200 is one byte, 0x80: high-bit, so svn counts it as non-text, and no NUL means git still
    # calls the file text -- which is exactly the disagreement that breaks the migration.
    # shellcheck disable=SC2046
    printf '\200%.0s' $(seq 872) >> "$path" || return 1
}

# issue #176: propset stops partway, and everything it staged before that point stayed staged.
# The message said "nothing was committed", which is true of SVN and quite wrong about the working
# copy -- the bridge was left holding thousands of pending property changes, the pre-flight then
# refused to rerun, and nothing on screen connected the two.
test_propset_failure_reverts_the_staged_property_changes() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-prev-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"

        write_svn_binary_mime_file "$bridge/zzbinmime.txt" || exit 98
        ( cd "$bridge" && svn --non-interactive add -q zzbinmime.txt ) || exit 98
        ( cd "$bridge" && svn --non-interactive commit -q -m 'a text file svn calls binary' ) || exit 98
        git -C "$bridge" add -A >/dev/null 2>&1 || exit 98
        git -C "$bridge" -c commit.gpgsign=false commit -qm 'binmime' >/dev/null 2>&1 || exit 98

        # Fixture guard. If svn did NOT stamp the file, propset succeeds and this test passes while
        # measuring nothing at all -- the exact shape of a false green.
        mt="$(cd "$bridge" && svn propget svn:mime-type zzbinmime.txt 2>/dev/null | tr -d '\r\n')"
        case "$mt" in
            application/octet-stream) : ;;
            *) echo "fixture: svn did not stamp the file binary (svn:mime-type=[$mt])" >&2; exit 98 ;;
        esac

        out="$(bash "$SUT" --repo-root "$root" 2>&1)" && { echo "the run should have failed: $out" >&2; exit 1; }

        case "$out" in *'propset failed'*) : ;; *) echo "no propset failure message: $out" >&2; exit 1 ;; esac

        # The point of the whole issue: the working copy is back to how it was found.
        st="$(cd "$bridge" && svn status | grep -v '^?' || true)"
        if [ -n "$st" ]; then
            echo "the failed run left staged changes behind: [$st]" >&2; exit 1
        fi
        # And specifically, no file kept a half-applied property.
        if [ -n "$(svn_eol_prop "$bridge/plain.txt")" ]; then
            echo "plain.txt kept the property from the failed run" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'a failed propset reverts what it staged and leaves the bridge clean' 0 "$rc"
}

# issue #177: the migration is one commit over every text file in the tree, so on a big repository
# it times out in `Committing transaction` -- after the data transmitted. A timeout means no answer
# came back, NOT that nothing happened, so the message has to say how to find out which.
#
# The failure is forced with a pre-commit hook rather than a real timeout: what is under test is
# the message and the fact that the pending changes are KEPT, which is the same on any commit
# failure. (In PowerShell this path is also where EAP=Stop would otherwise throw past the guidance.)
test_commit_failure_keeps_the_work_and_says_how_to_check() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-prev-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"
        svnrepo="$tmp/svnrepo"

        # Both spellings: svn runs `pre-commit` on POSIX and `pre-commit.bat` on Windows.
        printf '#!/bin/sh\nexit 1\n' > "$svnrepo/hooks/pre-commit" || exit 98
        chmod +x "$svnrepo/hooks/pre-commit" 2>/dev/null || true
        printf '@echo off\r\nexit 1\r\n' > "$svnrepo/hooks/pre-commit.bat" || exit 98

        out="$(bash "$SUT" --repo-root "$root" 2>&1)" && { echo "the commit should have failed: $out" >&2; exit 1; }

        case "$out" in *'svn log --limit 1'*) : ;;
            *) echo "no way to check whether it landed: $out" >&2; exit 1 ;; esac
        # Path-scoped, not repository-scoped. SVN revision numbers are shared by the whole
        # repository, so "did the HEAD move?" answers yes when someone else committed to an
        # unrelated path -- and reading that as success is the direction that loses the migration
        # silently. Asserting the path-scoped question is what keeps the guidance from sliding
        # back to the repository one.
        case "$out" in *'THIS BRANCH PATH'*) : ;;
            *) echo "the check is not scoped to this branch path: $out" >&2; exit 1 ;; esac
        # And the guidance has to say "wait" before it says "check". A large transaction can finish
        # on the server minutes after it stopped answering -- reported in the wild, two hours later,
        # after the user had already concluded it failed and reverted. Telling someone how to check
        # without telling them not to check YET is the part that produced the wrong answer.
        case "$out" in *'WAIT a few minutes'*) : ;;
            *) echo "the guidance does not say to wait before concluding: $out" >&2; exit 1 ;; esac
        case "$out" in *'Do NOT `svn revert`'*) : ;;
            *) echo "the guidance does not warn against reverting too early: $out" >&2; exit 1 ;; esac
        # The locks an interrupted commit leaves behind block every later svn operation, and the
        # old message never mentioned them -- which is what made that state undiagnosable.
        case "$out" in *'svn cleanup'*) : ;;
            *) echo "the guidance does not mention the working-copy locks: $out" >&2; exit 1 ;; esac
        case "$out" in *'does NOT have to be repeated'*) : ;;
            *) echo "did not say the propset survives: $out" >&2; exit 1 ;; esac

        # The opposite of the propset case: here the staged work is deliberately KEPT, because the
        # commit is what failed and rerunning it is the cheap fix.
        st="$(cd "$bridge" && svn status | grep -v '^?' || true)"
        if [ -z "$st" ]; then
            echo "the property changes were discarded; the message promises they are still there" >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'a failed commit keeps the staged properties and explains how to check SVN' 0 "$rc"
}

# issue #177: the migration is one pass over every text file in the tree, so on a big repository the
# single transaction times out on the server. It commits in batches instead.
#
# --batch-size 1 on the fixture's two candidates gives three revisions: the declaring one plus one
# per file. Three separate assertions matter, and each pins a different thing that went wrong or
# could go wrong.
test_migration_commits_in_batches() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolinit-batch-XXXXXX)"
    (
        root="$(make_bridge_fixture "$tmp")" || exit 98
        bridge="$root/.turbo-plugin/worktrees/remote-svn-main"
        svnrepo="$tmp/svnrepo"

        before="$(svnlook youngest "$svnrepo" | tr -d '[:space:]')"
        bash "$SUT" --repo-root "$root" --batch-size 1 >/dev/null 2>&1 || exit 97
        after="$(svnlook youngest "$svnrepo" | tr -d '[:space:]')"

        # More than one revision is the whole point -- a single one means the batching did nothing.
        if [ "$((after - before))" -lt 3 ]; then
            echo "expected at least 3 revisions from batching, got $((after - before))" >&2; exit 1
        fi

        # The DECLARING revision must be first. svn:auto-props on the root is the signal the bridge
        # reads to decide whether to pin git to LF; declared last, an interrupted run would leave
        # thousands of files carrying svn:eol-style while the bridge is still pinned, and every one
        # of them would read as modified after the next update.
        ap="$(svnlook propget "$svnrepo" svn:auto-props trunk -r "$((before + 1))" 2>/dev/null || true)"
        case "$ap" in *'svn:eol-style'*) : ;;
            *) echo "the first new revision r$((before + 1)) did not declare the tree: [$ap]" >&2; exit 1 ;; esac

        # Committing more than once leaves a MIXED-REVISION working copy unless something makes it
        # uniform again, and the pull path reads "the" revision of the copy -- it would position
        # everything back at the root's older one and undo the property changes on disk. svnversion
        # prints `N:M` for a mixed copy and a single number for a uniform one.
        ver="$(cd "$bridge" && svnversion . 2>/dev/null | tr -d '[:space:]')"
        case "$ver" in *:*) echo "the working copy is left at mixed revisions: $ver" >&2; exit 1 ;; esac

        # And the point of the exercise still holds: every candidate ended up marked.
        if [ "$(svn_eol_prop "$bridge/plain.txt")" != 'native' ]; then
            echo 'plain.txt did not get the property' >&2; exit 1
        fi
        if [ "$(svn_eol_prop "$bridge/wascrlf.txt")" != 'native' ]; then
            echo 'wascrlf.txt did not get the property' >&2; exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    [ "$rc" -eq 98 ] && { startSkipping; return 0; }
    assertEquals 'the migration commits in batches, declares first, and leaves one revision' 0 "$rc"
}

test_batch_size_must_be_a_positive_integer() {
    local rc
    bash "$SUT" --batch-size 0 >/dev/null 2>&1
    rc=$?
    assertNotEquals 'a batch size of 0 is refused' 0 "$rc"
    bash "$SUT" --batch-size abc >/dev/null 2>&1
    rc=$?
    assertNotEquals 'a non-numeric batch size is refused' 0 "$rc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
