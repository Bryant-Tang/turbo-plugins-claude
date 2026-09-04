#!/usr/bin/env bash
# common.test.sh (shUnit2)
# Script under test: scripts/lib/common.sh
#
# Covers:
#   - probe_git_version            — happy (git on PATH >= 2.31)
#   - assert_svn_version           — pre-1.9 rejected / 1.9 boundary / unparseable fails loudly
#   - expand_unversioned_dir       — recursive listing / ignored children / metadata skip / non-dir
#   - svn_target                   — peg-revision escape for '@' filenames (unconditional)
#   - get_normalized_absolute_path — /c/foo Git-Bash style, forward-slash, empty
#   - get_main_worktree            — fresh git init top-level + linked worktree + explicit root
#   - resolve_git_root             — omitted is '.', missing path fails loudly
#   - test_is_main_worktree        — explicit root judged instead of the cwd
#   - test_is_submodule            — fresh git init is NOT a submodule
#   - assert_trusted_svn_url       — boundary-safe SVN URL trust check (U1; SKIPs w/o svn)
#   - resolve_repo_path            — relative / ./relative / absolute / Git-Bash / empty
#   - resolve_remote_worktree      — main / test-<n> / unsupported
#   - get_worktrees_dir            — explicit main → nested container
#   - worktree_for_branch          — main / linked worktree / not checked out / empty list refused
#   - write_utf8_no_bom            — CJK no-BOM byte-equal to canonical UTF-8 (R6)
#   - read_turbo_plugin_config     — flat mode + section/key sentinel + top-level key
#   - resolve_config_value         — config merge chain + config.local.toml override
#   - ensure_bridge_eol_faithful   — byte-faithful under `* text=auto` / scoped / idempotent (#164)

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
COMMON_SH="$PLUGIN_ROOT/scripts/lib/common.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    if [[ ! -f "$COMMON_SH" ]]; then
        fail "common.sh not found at $COMMON_SH"
        return 1
    fi
    # common.sh sets `set -euo pipefail`; sourcing it makes errexit active in the
    # test process. shUnit2's own test-runner machinery is not errexit-safe (it
    # triggers `pop_var_context` errors), so we relax -e/-u/pipefail after sourcing.
    # Helper calls in cases still defensively use `|| true` / `if !` wrapping.
    # shellcheck source=/dev/null
    source "$COMMON_SH"
    set +e +u +o pipefail

    HAS_SVN=0
    if command -v svn >/dev/null 2>&1 && command -v svnadmin >/dev/null 2>&1; then
        HAS_SVN=1
    fi
}

# Windows-only assertions live behind this. get_normalized_absolute_path / resolve_repo_path convert
# Git-Bash `/c/foo` into the drive form `c:/foo`, which only means anything where drive letters
# exist. On Linux there is no drive letter, and `realpath -m c:/foo` reasonably reads `c:/foo` as a
# RELATIVE path and prefixes the cwd -- so these cases were not finding a bug, they were asserting
# Windows semantics on a platform that has none. They stayed invisible because the .sh suite had
# only ever run on Git Bash.
need_windows() {
    case "$(uname -s 2>/dev/null)" in
        MINGW*|MSYS*|CYGWIN*) return 0 ;;
        *) startSkipping; return 1 ;;
    esac
}

# ─── probe_git_version ───────────────────────────────────────────────────────
test_probe_git_version_happy() {
    probe_git_version 2>/dev/null
    assertTrue 'probe_git_version succeeds when git present and >= 2.31' $?
}

# ─── get_normalized_absolute_path ────────────────────────────────────────────
test_normalize_git_bash_c() {
    need_windows || return 0
    local norm
    norm="$(get_normalized_absolute_path '/c/projdir' 2>/dev/null || true)"
    case "$norm" in
        c:*) assertTrue "lowercased drive c: (got: $norm)" 0 ;;
        *)   fail "expected c:/... form, got '$norm'" ;;
    esac
}

test_normalize_forward_slash_abs() {
    need_windows || return 0
    local norm
    norm="$(get_normalized_absolute_path 'C:/Some/Path' 2>/dev/null || true)"
    case "$norm" in
        c:/*) assertTrue "lowercased drive on forward-slash abs (got: $norm)" 0 ;;
        *)    fail "expected c:/... got '$norm'" ;;
    esac
}

test_normalize_git_bash_d() {
    need_windows || return 0
    local norm
    norm="$(get_normalized_absolute_path '/d/Projects/App' 2>/dev/null || true)"
    if [[ "$norm" =~ ^d:.*Projects.*App$ ]]; then
        assertTrue "/d/Projects/App → d:/... (got: $norm)" 0
    else
        fail "expected d:/...Projects...App got '$norm'"
    fi
}

test_normalize_empty_input_nonzero() {
    if ! get_normalized_absolute_path '' >/dev/null 2>&1; then
        assertTrue 'empty input returns non-zero' 0
    else
        fail 'expected non-zero exit on empty input, got exit 0'
    fi
}

# ─── get_main_worktree — fresh git init top-level ────────────────────────────
test_get_main_worktree_toplevel() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-gmw-XXXXXX)"
    (
        cd "$tmp" || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1

        mw="$(get_main_worktree 2>/dev/null || true)"
        # Match by basename — Windows 8.3 short name vs git long-name make a literal
        # comparison unreliable. Verify non-empty, lowercased drive, unique basename.
        tmpdir_basename="${tmp##*/}"
        # The drive-letter shape is a Windows-only expectation; the part worth asserting
        # everywhere is "resolved to this repo's top level".
        case "$(uname -s 2>/dev/null)" in
            MINGW*|MSYS*|CYGWIN*) drive_ok=$([[ "$mw" =~ ^[a-z]:.* ]] && echo 1 || echo 0) ;;
            *)                    drive_ok=1 ;;
        esac
        if [[ -n "$mw" && "$drive_ok" -eq 1 && "$mw" == *"$tmpdir_basename"* ]]; then
            exit 0
        fi
        echo "expected path containing '$tmpdir_basename' (lowercased drive on Windows), got '$mw'" >&2
        exit 1
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'get_main_worktree returns normalized top-level inside git repo' 0 "$rc"
}

# ─── get_main_worktree — linked worktree resolves to the SAME main path ───────
test_get_main_worktree_linked() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-lw-XXXXXX)"
    (
        cd "$tmp" || exit 99
        mkdir main
        cd main || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1

        main_mw="$(get_main_worktree 2>/dev/null || true)"

        git worktree add -q -b feat/lw ../linked >/dev/null 2>&1
        cd ../linked || exit 99
        linked_mw="$(get_main_worktree 2>/dev/null || true)"

        if [[ -z "$main_mw" || -z "$linked_mw" ]]; then
            echo "empty result (main='$main_mw' linked='$linked_mw')" >&2
            exit 1
        fi
        if [[ "$linked_mw" == "$main_mw" ]]; then
            exit 0
        fi
        echo "linked='$linked_mw' != main='$main_mw'" >&2
        exit 1
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'get_main_worktree from a linked worktree returns the main worktree path' 0 "$rc"
}

# ─── resolve_git_root — omitted is '.', a bad path fails loudly ───────────────
test_resolve_git_root_empty_is_dot() {
    local root
    root="$(resolve_git_root '' 2>/dev/null || true)"
    assertEquals "omitted repo root resolves to '.' so 'git -C .' stays a no-op" '.' "$root"
}

test_resolve_git_root_missing_fails() {
    local tmp err rc
    tmp="$(mktemp -d -t turbo-common-rgr-XXXXXX)"
    err="$(resolve_git_root "$tmp/definitely-not-here" 2>&1 >/dev/null)"
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    if [[ $rc -eq 0 ]]; then
        fail "expected non-zero for a repo root that does not exist"
        return
    fi
    case "$err" in
        *'repo root not found'*) assertTrue 'error names the missing repo root' 0 ;;
        *) fail "expected a 'repo root not found' message, got '$err'" ;;
    esac
}

# ─── get_main_worktree <root> — the named repo wins over the ambient cwd ──────
# Two sibling repos, cwd inside the FIRST one. Asking for the second by path must return the
# second. This is the whole point of --repo-root: which repository is acted on stops depending
# on where the process happens to be standing.
test_get_main_worktree_repo_root_overrides_cwd() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-rr-XXXXXX)"
    (
        cd "$tmp" || exit 99
        for name in alpha beta; do
            mkdir "$name"
            git -C "$name" init -q -b main >/dev/null 2>&1
            git -C "$name" config user.email 'test@turbo-plugin'
            git -C "$name" config user.name 'turbo-plugin-test'
            git -C "$name" commit -q --allow-empty -m 'init' >/dev/null 2>&1
        done

        cd alpha || exit 99
        here="$(get_main_worktree 2>/dev/null || true)"
        there="$(get_main_worktree "$tmp/beta" 2>/dev/null || true)"

        if [[ -z "$here" || -z "$there" ]]; then
            echo "empty result (cwd='$here' named='$there')" >&2
            exit 1
        fi
        if [[ "$here" == "$there" ]]; then
            echo "named root did not override cwd (both '$here')" >&2
            exit 1
        fi
        if [[ "$there" != *beta ]]; then
            echo "expected the beta repo, got '$there'" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'get_main_worktree <root> resolves the NAMED repo, not the one cwd is in' 0 "$rc"
}

# ─── test_is_main_worktree <root> — judges the named path, not the cwd ────────
# Guard 1 of the bridge bootstrap depends on this: standing in the main worktree while naming a
# linked one must still report "linked".
test_is_main_worktree_repo_root() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-timw-XXXXXX)"
    (
        cd "$tmp" || exit 99
        mkdir main
        cd main || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1
        git worktree add -q -b feat/lw ../linked >/dev/null 2>&1

        # cwd is the MAIN worktree for both calls; only the argument differs.
        if ! test_is_main_worktree "$tmp/main"; then
            echo "named main worktree reported as linked" >&2
            exit 1
        fi
        if test_is_main_worktree "$tmp/linked"; then
            echo "named linked worktree reported as main" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'test_is_main_worktree <root> judges the named path, not the cwd' 0 "$rc"
}

# ─── test_is_submodule — fresh git init is NOT a submodule ────────────────────
test_test_is_submodule_false() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-tis-XXXXXX)"
    (
        cd "$tmp" || exit 99
        git init -q -b main >/dev/null 2>&1
        if test_is_submodule; then
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'test_is_submodule returns non-zero (not a submodule) in fresh git init' 0 "$rc"
}

# ─── assert_trusted_svn_url (U1) ─────────────────────────────────────────────
# Boundary-safe + case-normalized + traversal-reject trust check anchored on the
# trusted working copy's repos-root-url. Needs svn/svnadmin + seed dump → SKIP otherwise.
_assert_trusted_ok() {
    local name="$1" wc="$2" cand="$3" rc
    assert_trusted_svn_url "$wc" "$cand" >/dev/null 2>&1
    rc=$?
    assertEquals "$name" 0 "$rc"
}
_assert_trusted_reject() {
    local name="$1" wc="$2" cand="$3" want="${4:-}" err rc
    err="$(assert_trusted_svn_url "$wc" "$cand" 2>&1 >/dev/null)"
    rc=$?
    if [[ $rc -eq 0 ]]; then
        fail "$name: expected reject (non-zero), got exit 0 for '$cand'"
    elif [[ -n "$want" && "$err" != *"$want"* ]]; then
        fail "$name: rejected but stderr missing '$want': $err"
    else
        assertTrue "$name" 0
    fi
}

test_assert_trusted_svn_url() {
    [ "$HAS_SVN" -eq 1 ] || { startSkipping; return 0; }

    local dump
    dump="$PLUGIN_ROOT/tests/fixtures/seed/svn-repo-r1-r20.dump"
    if [[ ! -f "$dump" ]]; then
        startSkipping
        return 0
    fi

    local tmp svn_repo wc empty_nonwc load_ok=1
    tmp="$(mktemp -d -t turbo-common-trusturl-XXXXXX)"
    svn_repo="$tmp/repo"
    wc="$tmp/wc"
    empty_nonwc="$tmp/empty-non-wc"
    mkdir -p "$empty_nonwc"

    svnadmin create "$svn_repo" >/dev/null 2>&1 || load_ok=0
    if [[ $load_ok -eq 1 ]]; then
        svnadmin load "$svn_repo" < "$dump" >/dev/null 2>&1 || load_ok=0
    fi
    if [[ $load_ok -eq 0 ]]; then
        rm -rf "$tmp" 2>/dev/null || true
        startSkipping
        return 0
    fi

    local repo_for_uri="$svn_repo"
    if [[ "$repo_for_uri" =~ ^/([a-zA-Z])/(.*)$ ]]; then
        repo_for_uri="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
    fi
    local repo_uri="file:///$repo_for_uri"

    svn checkout "$repo_uri/trunk" "$wc" >/dev/null 2>&1 || true
    local repos_root
    repos_root="$(svn info --show-item repos-root-url "$wc" 2>/dev/null | tr -d '\r\n' || true)"
    if [[ -z "$repos_root" ]]; then
        rm -rf "$tmp" 2>/dev/null || true
        startSkipping
        return 0
    fi

    _assert_trusted_ok     "same-repo trunk URL is trusted"                        "$wc" "$repos_root/trunk"
    _assert_trusted_ok     "legit sibling branches/test-1 is trusted (repos-root)" "$wc" "$repos_root/branches/test-1"
    _assert_trusted_reject "prefix-confusion <root>-evil/trunk is rejected (R10)"  "$wc" "${repos_root}-evil/trunk"

    local upper_root="${repos_root/#file:\/\//FILE://}"
    _assert_trusted_ok     "uppercase scheme FILE:// normalizes and is trusted (R11)" "$wc" "$upper_root/trunk"
    _assert_trusted_ok     "trailing-slash candidate matches no-slash result"      "$wc" "$repos_root/branches/test-1/"

    _assert_trusted_reject "out-of-bounds file:///C:/Windows/... is rejected"       "$wc" "file:///C:/Windows/System32/"
    _assert_trusted_reject "different scheme/host http://attacker/... is rejected"  "$wc" "http://attacker.example/repo"
    _assert_trusted_reject "candidate with '..' traversal is rejected"             "$wc" "$repos_root/trunk/../../etc"
    _assert_trusted_reject "percent-encoded ..(%2e%2e) traversal rejected after decode" "$wc" "$repos_root/trunk/%2e%2e/%2e%2e/etc"
    _assert_trusted_reject "fail-closed: non-WC trusted reference rejects"          "$empty_nonwc" "$repos_root/trunk" "fail closed"

    rm -rf "$tmp" 2>/dev/null || true
}

# ─── resolve_repo_path ───────────────────────────────────────────────────────
test_resolve_repo_path_relative() {
    local out
    out="$(resolve_repo_path 'C:/repo/root' 'src/app' 2>/dev/null || true)"
    case "$out" in
        */repo/root/src/app) assertTrue "relative under repo_root (got: $out)" 0 ;;
        *) fail "expected .../repo/root/src/app, got '$out'" ;;
    esac
}

test_resolve_repo_path_dot_relative() {
    local out
    out="$(resolve_repo_path 'C:/repo/root' './bin/out' 2>/dev/null || true)"
    case "$out" in
        */repo/root/bin/out) assertTrue "strips leading ./ (got: $out)" 0 ;;
        *) fail "expected .../repo/root/bin/out, got '$out'" ;;
    esac
}

test_resolve_repo_path_absolute() {
    need_windows || return 0
    local out
    out="$(resolve_repo_path 'C:/repo/root' 'D:/elsewhere/app' 2>/dev/null || true)"
    if [[ "$out" == D:/elsewhere/app && "$out" != *repo/root* ]]; then
        assertTrue "absolute drive path kept standalone (got: $out)" 0
    else
        fail "expected D:/elsewhere/app standalone, got '$out'"
    fi
}

test_resolve_repo_path_git_bash() {
    need_windows || return 0
    local out
    out="$(resolve_repo_path 'C:/repo/root' '/c/Git/Bash/Path' 2>/dev/null || true)"
    if [[ "$out" == C:/Git/Bash/Path && "$out" != *repo/root* ]]; then
        assertTrue "/c Git-Bash → C:/ standalone (got: $out)" 0
    else
        fail "expected C:/Git/Bash/Path standalone, got '$out'"
    fi
}

test_resolve_repo_path_empty() {
    local out rc
    out="$(resolve_repo_path 'C:/repo/root' '')"
    rc=$?
    assertEquals 'empty path → exit 0' 0 "$rc"
    assertEquals 'empty path → empty output' '' "$out"
}

# ─── resolve_remote_worktree ─────────────────────────────────────────────────
test_resolve_remote_worktree_main() {
    local wt='C:/proj.worktrees' out
    out="$(resolve_remote_worktree 'main' "$wt" 2>/dev/null || true)"
    assertEquals 'main → remote-svn-main triple' \
        "remote-svn-main|remote-svn/main|$wt/remote-svn-main" "$out"
}

test_resolve_remote_worktree_test_n() {
    local wt='C:/proj.worktrees' out
    out="$(resolve_remote_worktree 'test-7' "$wt" 2>/dev/null || true)"
    assertEquals 'test-7 → remote-svn-test-7 triple' \
        "remote-svn-test-7|remote-svn/test-7|$wt/remote-svn-test-7" "$out"
}

# Invalid branch names are rejected via assert_valid_remote_branch_name.
# (Path-style names like feature/foo are valid in the current allowlist, so the
# old "unsupported branch" expectation no longer applies — use a '..' name.)
test_resolve_remote_worktree_invalid_name() {
    local wt='C:/proj.worktrees' err rc
    err="$(resolve_remote_worktree 'bad..name' "$wt" 2>&1 >/dev/null)"
    rc=$?
    if [[ $rc -ne 0 && "$err" == *"invalid branch name"* ]]; then
        assertTrue 'rejects invalid branch name (non-zero + stderr)' 0
    else
        fail "expected non-zero + 'invalid branch name', got rc=$rc err='$err'"
    fi
}

# ─── get_worktrees_dir (U1) ──────────────────────────────────────────────────
test_get_worktrees_dir_explicit() {
    local main='C:/proj/main' out
    out="$(get_worktrees_dir "$main" 2>/dev/null || true)"
    assertEquals 'explicit main → <main>/.turbo-plugin/worktrees' \
        "$main/.turbo-plugin/worktrees" "$out"
}

# ─── worktree_for_branch — the lookup shared by request-merge / merge-main ────
#
# The oracle for the normalization step is deliberately ANOTHER function's output, never a
# second copy of the same string surgery: `git worktree list --porcelain` prints Windows paths
# as `C:/...` while get_main_worktree returns `c:/...`, and merge-main-into-branches.sh compares
# the two directly. Dropping the normalization makes that comparison false forever without a
# word of complaint, so asserting equality against get_main_worktree is what actually catches it.
test_worktree_for_branch_main_matches_get_main_worktree() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-wfb-XXXXXX)"
    (
        cd "$tmp" || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1

        wt_list="$(git worktree list --porcelain 2>/dev/null)"
        got="$(worktree_for_branch main "$wt_list" 2>/dev/null || true)"
        want="$(get_main_worktree 2>/dev/null || true)"

        if [[ -n "$want" && "$got" == "$want" ]]; then
            exit 0
        fi
        echo "worktree_for_branch='$got' get_main_worktree='$want'" >&2
        exit 1
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'the branch in the main worktree resolves to the same spelling get_main_worktree gives' 0 "$rc"
}

test_worktree_for_branch_linked_worktree() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-wfbl-XXXXXX)"
    (
        cd "$tmp" || exit 99
        mkdir main
        cd main || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1
        git worktree add -q -b feat/lw ../linked >/dev/null 2>&1

        wt_list="$(git worktree list --porcelain 2>/dev/null)"
        got="$(worktree_for_branch feat/lw "$wt_list" 2>/dev/null || true)"
        main_wt="$(get_main_worktree 2>/dev/null || true)"

        if [[ -z "$got" ]]; then
            echo "expected a path for feat/lw, got nothing" >&2
            exit 1
        fi
        # Must be a DIFFERENT worktree than main -- that inequality is the whole basis of the
        # "checked out elsewhere" decision -- and the path must really be that branch's checkout.
        if [[ "$got" == "$main_wt" ]]; then
            echo "feat/lw resolved to the main worktree '$main_wt'" >&2
            exit 1
        fi
        here="$(git -C "$got" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [[ "$here" != 'feat/lw' ]]; then
            echo "'$got' has '$here' checked out, expected feat/lw" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'a branch held by a linked worktree resolves to that worktree' 0 "$rc"
}

# The other direction. Without this, a lookup that answered "some worktree has it" for every
# branch would pass every case above.
test_worktree_for_branch_absent_is_empty() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-common-wfba-XXXXXX)"
    (
        cd "$tmp" || exit 99
        git init -q -b main >/dev/null 2>&1
        git config user.email 'test@turbo-plugin'
        git config user.name 'turbo-plugin-test'
        git commit -q --allow-empty -m 'init' >/dev/null 2>&1
        git branch feat/parked >/dev/null 2>&1

        wt_list="$(git worktree list --porcelain 2>/dev/null)"
        got="$(worktree_for_branch feat/parked "$wt_list" 2>/dev/null || true)"
        if [[ -z "$got" ]]; then
            exit 0
        fi
        echo "expected nothing for a branch with no worktree, got '$got'" >&2
        exit 1
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'a branch no worktree holds resolves to nothing' 0 "$rc"
}

# An empty listing can only mean the caller handed over a failed or unchecked read: a healthy
# `--porcelain` run always names at least the main worktree. Answering "nobody has it" there is
# indistinguishable from the healthy answer, which is the failure this refusal exists to prevent.
test_worktree_for_branch_empty_list_fails_loudly() {
    local out rc
    out="$(worktree_for_branch main '' 2>/dev/null)"
    rc=$?
    assertNotEquals 'an empty worktree list must not be answered' 0 "$rc"
    assertEquals 'and must not emit a path' '' "$out"
}

# ─── write_utf8_no_bom — CJK no-BOM byte-equal to canonical UTF-8 (R6) ────────
test_write_utf8_no_bom() {
    local tmp content file rc
    tmp="$(mktemp -d -t turbo-common-utf8-XXXXXX)"
    content='路徑/含中文 — 修正中文 commit 訊息亂碼'
    file="$tmp/cjk.txt"

    write_utf8_no_bom "$file" "$content"
    rc=$?
    if [[ $rc -ne 0 || ! -f "$file" ]]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "write_utf8_no_bom failed (rc=$rc) or file not written"
        return
    fi

    local first3
    first3="$(head -c 3 "$file" | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')"
    assertNotEquals 'first 3 bytes must NOT be the UTF-8 BOM' 'ef bb bf' "$first3"

    local canon file_hex canon_hex
    canon="$tmp/canon.txt"
    LC_ALL=C.UTF-8 printf '%s' "$content" > "$canon" 2>/dev/null || printf '%s' "$content" > "$canon"
    file_hex="$(od -An -tx1 "$file" | tr -d ' \n')"
    canon_hex="$(od -An -tx1 "$canon" | tr -d ' \n')"
    rm -rf "$tmp" 2>/dev/null || true

    assertTrue 'written bytes are non-empty' "$([[ -n "$file_hex" ]] && echo 0 || echo 1)"
    assertEquals 'written bytes equal canonical UTF-8' "$canon_hex" "$file_hex"
}

# ─── read_turbo_plugin_config — flat mode + section/key sentinel ──────────────
_write_cfg() {
    # $1 = file path. Writes a representative config (no schema_version — U5/U6).
    {
        echo 'note = "x"'
        echo ''
        echo '# a comment'
        echo '[svn]'
        echo 'url = "https://svn.example/repo"'
        echo 'empty_key = ""'
        echo '[iis]'
        echo 'port = 44300'
    } > "$1"
}

test_read_config_flat_mode() {
    local tmp cfg out
    tmp="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
    cfg="$tmp/config.toml"
    _write_cfg "$cfg"
    out="$(read_turbo_plugin_config "$cfg" 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    if [[ "$out" == *".note=x"* \
       && "$out" == *"svn.url=https://svn.example/repo"* \
       && "$out" == *"iis.port=44300"* ]]; then
        assertTrue 'flat mode dumps section.key=value lines' 0
    else
        fail "missing expected flat lines, got: $out"
    fi
}

test_read_config_targeted_found() {
    local tmp cfg out
    tmp="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
    cfg="$tmp/config.toml"
    _write_cfg "$cfg"
    out="$(read_turbo_plugin_config "$cfg" 'svn' 'url' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'targeted found → sentinel-prefixed value' \
        '__TP_FOUND__:https://svn.example/repo' "$out"
}

test_read_config_found_empty() {
    local tmp cfg out
    tmp="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
    cfg="$tmp/config.toml"
    _write_cfg "$cfg"
    out="$(read_turbo_plugin_config "$cfg" 'svn' 'empty_key' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'found-empty key → "__TP_FOUND__:" (distinct from not-found)' \
        '__TP_FOUND__:' "$out"
}

test_read_config_not_found() {
    local tmp cfg out
    tmp="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
    cfg="$tmp/config.toml"
    _write_cfg "$cfg"
    out="$(read_turbo_plugin_config "$cfg" 'svn' 'no_such_key' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'not-found key → empty output (no sentinel)' '' "$out"
}

# top-level key (empty section) targeted lookup → sentinel.
# Re-keyed from schema_version (removed U5/U6) to a generic top-level key `note`.
test_read_config_top_level_key() {
    local tmp cfg out
    tmp="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
    cfg="$tmp/config.toml"
    _write_cfg "$cfg"
    out="$(read_turbo_plugin_config "$cfg" '' 'note' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'top-level key (empty section) → sentinel' '__TP_FOUND__:x' "$out"
}

# ─── resolve_config_value — merge chain + config.local.toml override ──────────
# Carrier re-keyed from the removed [svn] force_bash to [iis] enabled (U5/U6):
# config.toml sets enabled=false; config.local.toml overrides enabled=true.
# resolve_config_value must return the local value (local precedence over canonical).
test_resolve_config_value_local_overrides() {
    local tmp rr out
    tmp="$(mktemp -d -t turbo-common-rcv-XXXXXX)"
    rr="$tmp/repo"
    mkdir -p "$rr/.turbo-plugin"
    {
        echo '[iis]'
        echo 'enabled = false'
    } > "$rr/.turbo-plugin/config.toml"
    {
        echo '[iis]'
        echo 'enabled = true'
    } > "$rr/.turbo-plugin/config.local.toml"

    out="$(resolve_config_value "$rr" 'iis' 'enabled' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'config.local.toml [iis] enabled overrides config.toml' 'true' "$out"
}

# Without a local override, the canonical config.toml value is resolved.
test_resolve_config_value_canonical_fallback() {
    local tmp rr out
    tmp="$(mktemp -d -t turbo-common-rcv-XXXXXX)"
    rr="$tmp/repo"
    mkdir -p "$rr/.turbo-plugin"
    {
        echo '[iis]'
        echo 'enabled = false'
    } > "$rr/.turbo-plugin/config.toml"

    out="$(resolve_config_value "$rr" 'iis' 'enabled' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'falls back to config.toml when no local override' 'false' "$out"
}

# ─── U6 marker scaffolding: reader tolerates # marker lines + unknown section ──
test_read_config_tolerates_markers() {
    local tmp rr svn iis unknown
    tmp="$(mktemp -d -t turbo-common-mark-XXXXXX)"
    rr="$tmp/repo"
    mkdir -p "$rr/.turbo-plugin"
    {
        echo '# turbo-plugin config.toml'
        echo '# >>> turbo-plugin:git-svn >>>'
        echo '[svn]'
        echo 'url = "https://svn.example/repo"'
        echo '# <<< turbo-plugin:git-svn <<<'
        echo '# >>> turbo-plugin:dotnet >>>'
        echo '[iis]'
        echo 'enabled = true'
        echo '# <<< turbo-plugin:dotnet <<<'
        echo '[future-unknown-concern]'
        echo 'key = "v"'
    } > "$rr/.turbo-plugin/config.toml"

    svn="$(resolve_config_value "$rr" 'svn' 'url' '' '' 2>/dev/null || true)"
    iis="$(resolve_config_value "$rr" 'iis' 'enabled' '' '' 2>/dev/null || true)"
    unknown="$(resolve_config_value "$rr" 'future-unknown-concern' 'key' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true

    # '#' marker lines skipped; bracketed sections parse; unknown/foreign section tolerated (no throw).
    assertEquals 'svn.url parsed past markers'        'https://svn.example/repo' "$svn"
    assertEquals 'iis.enabled parsed past markers'    'true'                     "$iis"
    assertEquals 'unknown section tolerated'          'v'                        "$unknown"
}

# Issue #61: config.local.toml describes THIS MACHINE, so it has no per-worktree meaning -- but
# being gitignored is exactly what keeps it out of a newly created worktree, so every new worktree
# started from defaults and the user re-entered settings already given.
#
# The sentinel values are what makes this discriminating: FROM-MAIN-LOCAL exists ONLY in the main
# worktree's local file, so reading it back from the linked worktree cannot happen any other way.
_build_worktree_inherit_repo() {
    local tmp main
    tmp="$(mktemp -d -t turbo-common-wtinherit-XXXXXX)"
    main="$tmp/main"
    mkdir -p "$main/.turbo-plugin"
    git -C "$main" init -q -b main >/dev/null 2>&1 || git init -q -b main "$main" >/dev/null 2>&1
    git -C "$main" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$main" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    printf '[tools]\nmsbuild_path = "FROM-CONFIG-TOML"\n' > "$main/.turbo-plugin/config.toml"
    git -C "$main" add -A >/dev/null 2>&1
    git -C "$main" -c commit.gpgsign=false commit -q -m init >/dev/null 2>&1
    printf '[tools]\nmsbuild_path = "FROM-MAIN-LOCAL"\niis_express_path = "MAIN-IIS"\n' \
        > "$main/.turbo-plugin/config.local.toml"
    git -C "$main" worktree add -q -b feat "$tmp/wt" >/dev/null 2>&1
    printf '%s' "$tmp"
}

test_resolve_config_value_linked_worktree_inherits_main_local() {
    local tmp msbuild iis
    tmp="$(_build_worktree_inherit_repo)"
    msbuild="$(resolve_config_value "$tmp/wt" 'tools' 'msbuild_path' '' '' 2>/dev/null || true)"
    iis="$(resolve_config_value "$tmp/wt" 'tools' 'iis_express_path' '' '' 2>/dev/null || true)"
    git -C "$tmp/main" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'linked worktree inherits the main local value' 'FROM-MAIN-LOCAL' "$msbuild"
    assertEquals 'and every other inherited key'                 'MAIN-IIS'        "$iis"
}

test_resolve_config_value_worktree_own_local_still_wins() {
    local tmp msbuild iis
    tmp="$(_build_worktree_inherit_repo)"
    mkdir -p "$tmp/wt/.turbo-plugin"
    printf '[tools]\nmsbuild_path = "FROM-WORKTREE-LOCAL"\n' > "$tmp/wt/.turbo-plugin/config.local.toml"
    msbuild="$(resolve_config_value "$tmp/wt" 'tools' 'msbuild_path' '' '' 2>/dev/null || true)"
    iis="$(resolve_config_value "$tmp/wt" 'tools' 'iis_express_path' '' '' 2>/dev/null || true)"
    git -C "$tmp/main" worktree remove --force "$tmp/wt" >/dev/null 2>&1 || true
    rm -rf "$tmp" 2>/dev/null || true
    # A deliberate per-worktree override keeps working: the inherited layer sits BELOW it...
    assertEquals 'own local file wins for the key it sets' 'FROM-WORKTREE-LOCAL' "$msbuild"
    # ...and a key it does not set is inherited rather than lost.
    assertEquals 'unset keys still inherited'              'MAIN-IIS'            "$iis"
}

# A plain directory is a legitimate caller (tests, a project not under git yet). Looking up the
# main worktree must not turn that into a failure.
test_resolve_config_value_tolerates_non_git_directory() {
    local tmp out
    tmp="$(mktemp -d -t turbo-common-nongit-XXXXXX)"
    mkdir -p "$tmp/.turbo-plugin"
    printf '[tools]\nmsbuild_path = "PLAIN"\n' > "$tmp/.turbo-plugin/config.toml"
    out="$(resolve_config_value "$tmp" 'tools' 'msbuild_path' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'non-git directory resolves normally' 'PLAIN' "$out"
}

# Issue #60: both constructs below are legal TOML that the reader used to drop without a word --
# the same silent-fallback symptom as the encoding bug, a different cause.
test_read_config_inline_comments_do_not_swallow_section_or_value() {
    local tmp rr msbuild note sharp
    tmp="$(mktemp -d -t turbo-common-inline-XXXXXX)"
    rr="$tmp/repo"
    mkdir -p "$rr/.turbo-plugin"
    {
        echo '[tools] # machine-specific tool paths'
        echo 'msbuild_path = "C:/MSBuild.exe" # pinned for this machine'
        echo 'note = "sharp # inside"'
    } > "$rr/.turbo-plugin/config.toml"

    msbuild="$(resolve_config_value "$rr" 'tools' 'msbuild_path' '' '' 2>/dev/null || true)"
    note="$(resolve_config_value "$rr" 'tools' 'note' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true

    # Header had to END at ']', so no section was opened and every key under it vanished.
    # Quoted values skipped comment-stripping AND failed the unquote (line does not end at the
    # quote), so the value kept both its quotes and the comment.
    assertEquals 'section survives a trailing comment on its header' 'C:/MSBuild.exe' "$msbuild"
    assertEquals 'a # inside quotes is part of the value'            'sharp # inside' "$note"
}

# A backslash inside a POSIX bracket expression is LITERAL, so a [^\"] class would also exclude
# '\' and stop matching every Windows path. Bidirectional guard on the regex form.
test_read_config_preserves_backslash_windows_paths() {
    local tmp rr msbuild iis
    tmp="$(mktemp -d -t turbo-common-bslash-XXXXXX)"
    rr="$tmp/repo"
    mkdir -p "$rr/.turbo-plugin"
    {
        echo '[tools]'
        echo 'msbuild_path = "C:\Program Files\MSBuild\MSBuild.exe"'
        echo 'iis_express_path = "C:\Program Files\IIS Express\iisexpress.exe" # 64-bit'
    } > "$rr/.turbo-plugin/config.toml"

    msbuild="$(resolve_config_value "$rr" 'tools' 'msbuild_path' '' '' 2>/dev/null || true)"
    iis="$(resolve_config_value "$rr" 'tools' 'iis_express_path' '' '' 2>/dev/null || true)"
    rm -rf "$tmp" 2>/dev/null || true

    assertEquals 'backslash path preserved'                'C:\Program Files\MSBuild\MSBuild.exe'        "$msbuild"
    assertEquals 'backslash path preserved past a comment' 'C:\Program Files\IIS Express\iisexpress.exe' "$iis"
}

# ─── get_svn_push_body (U9) ──────────────────────────────────────────────────
# Builds a repo with a 'svnbase' marker at the base commit, feat/fix on main, refactor on a
# side branch, then a --no-ff merge of side into main. The range svnbase..main therefore holds
# 3 non-merge subjects + 1 merge commit. Echoes the repo dir.
_build_push_body_repo() {
    local repo
    repo="$(mktemp -d -t turbo-common-pushbody-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: add A' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'fix: fix B' >/dev/null 2>&1
    git -C "$repo" checkout -q -b side >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'refactor: tidy C' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    # Spelled the way git itself writes a merge subject -- grouping reads the source branch off
    # this line, so a fixture with an ad-hoc message would not exercise the real path.
    git -C "$repo" merge -q --no-ff -m "Merge branch 'side' into main" side >/dev/null 2>&1
    printf '%s' "$repo"
}

test_get_svn_push_body_excludes_merge_and_prefixes() {
    local repo body line_count
    repo="$(_build_push_body_repo)"
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    line_count="$(printf '%s\n' "$body" | grep -c '^- ')"
    assertEquals 'body has exactly 3 "- " bullet lines (merge excluded)' '3' "$line_count"
    # Two source branches (main's own + merged-in `side`) -> grouped under 【main】/【side】 (#4).
    case "$body" in
        *"【main】"*) assertTrue '【main】 group header present' 0 ;;
        *) fail "【main】 header missing: $body" ;;
    esac
    case "$body" in
        *"【side】"*) assertTrue '【side】 group header present' 0 ;;
        *) fail "【side】 header missing: $body" ;;
    esac
    case "$body" in
        *"- feat: add A"*) assertTrue 'feat subject present' 0 ;;
        *) fail "feat missing: $body" ;;
    esac
    case "$body" in
        *"- fix: fix B"*) assertTrue 'fix subject present' 0 ;;
        *) fail "fix missing: $body" ;;
    esac
    case "$body" in
        *"- refactor: tidy C"*) assertTrue 'refactor subject present' 0 ;;
        *) fail "refactor missing: $body" ;;
    esac
    case "$body" in
        *"Merge branch"*) fail "merge commit leaked into body: $body" ;;
        *) assertTrue 'merge commit excluded' 0 ;;
    esac
}

# AE2: no commit-type filtering — docs/test/chore subjects all appear in the body.
test_get_svn_push_body_no_type_filter() {
    local repo body
    repo="$(mktemp -d -t turbo-common-notype-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'docs: update README' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'chore: bump version' >/dev/null 2>&1
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    case "$body" in
        *"- docs: update README"*) assertTrue 'docs in body (no type filter)' 0 ;;
        *) fail "docs filtered out: $body" ;;
    esac
    case "$body" in
        *"- chore: bump version"*) assertTrue 'chore in body (no type filter)' 0 ;;
        *) fail "chore filtered out: $body" ;;
    esac
}

# Same commit set → byte-identical body (Execution note: determinism guard).
test_get_svn_push_body_deterministic() {
    local repo b1 b2 h1 h2
    repo="$(_build_push_body_repo)"
    b1="$(get_svn_push_body "$repo" 'svnbase..main')"
    b2="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    h1="$(printf '%s' "$b1" | od -An -tx1 | tr -d ' \n')"
    h2="$(printf '%s' "$b2" | od -An -tx1 | tr -d ' \n')"
    assertEquals 'two runs on the same commit set are byte-identical' "$h1" "$h2"
}

# Special characters in a subject survive verbatim (delivered via git formatter + temp file,
# never shell-interpolated). Leading '- ' + backtick + $ + quotes in one subject.
test_get_svn_push_body_special_chars() {
    local repo body special
    repo="$(mktemp -d -t turbo-common-special-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    special='- fix: weird `code` $x "q"'
    git -C "$repo" commit -q --allow-empty -m "$special" >/dev/null 2>&1
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    assertEquals 'special-char subject preserved verbatim under "- " prefix' "- $special" "$body"
}

# Range with ONLY a merge commit → empty body (Build hard-stops on this; helper just yields '').
test_get_svn_push_body_only_merge_empty() {
    local repo y_sha body
    repo="$(mktemp -d -t turbo-common-onlymerge-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" checkout -q -b feature >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: X' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: Y' >/dev/null 2>&1
    y_sha="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
    git -C "$repo" merge -q --no-ff -m 'Merge feature (main)' feature >/dev/null 2>&1
    # startref = independent merge of the same two parents → contains X and Y but not main's merge.
    git -C "$repo" checkout -q -b startref "$y_sha" >/dev/null 2>&1
    git -C "$repo" merge -q --no-ff -m 'Merge feature (startref)' feature >/dev/null 2>&1
    body="$(get_svn_push_body "$repo" 'startref..main')"
    rm -rf "$repo" 2>/dev/null || true
    assertEquals 'only-merge range yields empty body' '' "$body"
}

# #4: a feature push that merged main groups the branch's OWN commits under 【<branch>】 and the
# merged-in trunk commits under 【main】, current branch first (was: one flat list mixing both).
test_get_svn_push_body_groups_merged_main() {
    local repo body before_main
    repo="$(mktemp -d -t turbo-common-group-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1                       # bridge tip = feature start
    git -C "$repo" checkout -q -b 'feat/x' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: feature one' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: feature two' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'chore: main one' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'chore: main two' >/dev/null 2>&1
    git -C "$repo" checkout -q 'feat/x' >/dev/null 2>&1
    git -C "$repo" merge -q --no-ff -m "Merge branch 'main' into feat/x" main >/dev/null 2>&1
    body="$(get_svn_push_body "$repo" 'svnbase..feat/x')"
    rm -rf "$repo" 2>/dev/null || true
    case "$body" in *"【feat/x】"*) assertTrue '【feat/x】 header present' 0 ;; *) fail "feat/x header missing: $body" ;; esac
    case "$body" in *"【main】"*) assertTrue '【main】 header present' 0 ;; *) fail "main header missing: $body" ;; esac
    # current-branch group precedes the merged-in main group (byte-safe prefix check, no grep)
    before_main="${body%%【main】*}"
    case "$before_main" in
        *"【feat/x】"*) assertTrue 'current-branch group precedes merged-in main group' 0 ;;
        *) fail "ordering wrong (feat/x should precede main): $body" ;;
    esac
    case "$body" in *"- feat: feature one"*) assertTrue 'own commit present' 0 ;; *) fail "f1 missing: $body" ;; esac
    case "$body" in *"- chore: main two"*) assertTrue 'merged-in trunk commit present' 0 ;; *) fail "m2 missing: $body" ;; esac
}

# ── #67: attribution must follow how the commit ENTERED the pushed branch ────
#
# X reached main through the merge of feat/a. feat/b was branched off X, never merged into main,
# and feat/a was deleted afterwards -- an entirely ordinary sequence. `git name-rev` answers
# "feat/b" here (it minimises generation-then-distance over all local heads, and main can only
# reach X across a second parent, which costs MERGE_TRAVERSAL_WEIGHT). Naming feat/b would put a
# claim in the SVN log -- permanently -- that a branch which shipped nothing was the source.
_build_issue67_repo() {
    local repo x
    repo="$(mktemp -d -t turbo-common-issue67-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    git -C "$repo" checkout -q -b 'feat/a' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'fix: the real fix' >/dev/null 2>&1
    x="$(git -C "$repo" rev-parse HEAD 2>/dev/null)"
    git -C "$repo" commit -q --allow-empty -m 'test: cover the fix' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'chore: main work' >/dev/null 2>&1
    git -C "$repo" merge -q --no-ff -m "Merge branch 'feat/a' into main" 'feat/a' >/dev/null 2>&1
    git -C "$repo" checkout -q -b 'feat/b' "$x" >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'wip: never merged anywhere' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" branch -q -D 'feat/a' >/dev/null 2>&1
    printf '%s' "$repo"
}

# The fixture only proves anything while it still reproduces the misattribution. If a future git
# changes name-rev's tie-breaking, this fails loudly rather than passing for the wrong reason.
test_issue67_fixture_still_reproduces() {
    local repo x named contained
    repo="$(_build_issue67_repo)"
    x="$(git -C "$repo" rev-list --no-merges --grep='fix: the real fix' 'svnbase..main')"
    named="$(git -C "$repo" name-rev --name-only --refs='refs/heads/*' "$x" 2>/dev/null)"
    if git -C "$repo" merge-base --is-ancestor 'feat/b' main 2>/dev/null; then contained=yes; else contained=no; fi
    rm -rf "$repo" 2>/dev/null || true
    assertEquals 'name-rev still names the never-merged branch (fixture reproduces #67)' 'feat/b~1' "$named"
    assertEquals 'feat/b is genuinely not merged into main' 'no' "$contained"
}

test_get_svn_push_body_attributes_via_the_merge_not_name_rev() {
    local repo body
    repo="$(_build_issue67_repo)"
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    # The never-merged branch must not appear at all -- not as a header, not anywhere.
    case "$body" in
        *'feat/b'*) fail "never-merged branch named in body: $body" ;;
        *) assertTrue 'never-merged branch absent' 0 ;;
    esac
    # The branch that WAS merged is named, even though it has since been deleted: the name comes
    # from the merge commit, which still records it.
    case "$body" in
        *"【feat/a】"*) assertTrue 'deleted-but-merged source branch named' 0 ;;
        *) fail "feat/a header missing: $body" ;;
    esac
    # Both of feat/a's commits belong to the same group; name-rev used to split them.
    case "$body" in
        *"【feat/a】"$'\n'"- fix: the real fix"$'\n'"- test: cover the fix"*)
            assertTrue 'both source-branch commits in one group' 0 ;;
        *) fail "feat/a group is not intact: $body" ;;
    esac
    case "$body" in
        *"【main】"$'\n'"- chore: main work"*) assertTrue 'main keeps only its own commit' 0 ;;
        *) fail "main group wrong: $body" ;;
    esac
}

# A merge subject that records no source branch -> no grouping at all. A wrong group is worse than
# no group: the body is locked, so the agent cannot correct it in the SVN log afterwards.
test_get_svn_push_body_flat_when_merge_subject_records_no_branch() {
    local repo body
    repo="$(mktemp -d -t turbo-common-nosrc-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    git -C "$repo" checkout -q -b side >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'refactor: tidy C' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: add A' >/dev/null 2>&1
    git -C "$repo" merge -q --no-ff -m 'hand-written message with no branch name' side >/dev/null 2>&1
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    case "$body" in
        *"【"*) fail "grouped despite an unattributable merge: $body" ;;
        *) assertTrue 'falls back to a flat list' 0 ;;
    esac
    case "$body" in
        *"- feat: add A"*) assertTrue 'own subject still present' 0 ;;
        *) fail "own subject dropped: $body" ;;
    esac
    case "$body" in
        *"- refactor: tidy C"*) assertTrue 'merged-in subject still present' 0 ;;
        *) fail "merged-in subject dropped: $body" ;;
    esac
}

# An octopus merge has more than one "other side", so no single source branch can be named for the
# commits it brought in. Same rule as an unreadable subject: flatten rather than pick one.
#
# The subject here is deliberately one that DOES parse (`Merge branch 'sideA' into main`). git's
# own octopus subject is "Merge branches 'a' and 'b'", which merge_source_branch already rejects
# on wording alone -- using it would leave the parent-count guard untested while the case still
# went green.
test_get_svn_push_body_flat_on_octopus_merge() {
    local repo body parents
    repo="$(mktemp -d -t turbo-common-octopus-XXXXXX)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    git -C "$repo" config user.email 'test@turbo-plugin' >/dev/null 2>&1
    git -C "$repo" config user.name 'turbo-plugin-test' >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'base' >/dev/null 2>&1
    git -C "$repo" branch svnbase >/dev/null 2>&1
    git -C "$repo" checkout -q -b sideA >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: from A' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" checkout -q -b sideB >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'feat: from B' >/dev/null 2>&1
    git -C "$repo" checkout -q main >/dev/null 2>&1
    git -C "$repo" commit -q --allow-empty -m 'chore: on main' >/dev/null 2>&1
    git -C "$repo" merge -q --no-ff -m "Merge branch 'sideA' into main" sideA sideB >/dev/null 2>&1
    parents="$(git -C "$repo" rev-list --parents -n 1 main 2>/dev/null | wc -w)"
    body="$(get_svn_push_body "$repo" 'svnbase..main')"
    rm -rf "$repo" 2>/dev/null || true
    # Guard the fixture: without three parents this would be testing an ordinary merge.
    assertEquals 'fixture really produced an octopus merge (sha + 3 parents)' '4' "$(echo "$parents" | tr -d ' ')"
    case "$body" in
        *"【"*) fail "grouped despite an octopus merge: $body" ;;
        *) assertTrue 'octopus merge falls back to a flat list' 0 ;;
    esac
    # Nothing may be dropped on the way to the fallback.
    case "$body" in *"- feat: from A"*) assertTrue 'A subject kept' 0 ;; *) fail "A missing: $body" ;; esac
    case "$body" in *"- feat: from B"*) assertTrue 'B subject kept' 0 ;; *) fail "B missing: $body" ;; esac
    case "$body" in *"- chore: on main"*) assertTrue 'main subject kept' 0 ;; *) fail "main missing: $body" ;; esac
}

# ── merge_source_branch ──────────────────────────────────────────────────────

test_merge_source_branch_reads_git_default_subjects() {
    assertEquals 'with into-clause'   'feat/a' "$(merge_source_branch "Merge branch 'feat/a' into main")"
    assertEquals 'without into-clause' 'feat/a' "$(merge_source_branch "Merge branch 'feat/a'")"
    assertEquals 'remote-tracking'  'origin/feat/a' "$(merge_source_branch "Merge remote-tracking branch 'origin/feat/a'")"
    assertEquals 'github pull request' 'feat/a' "$(merge_source_branch 'Merge pull request #12 from someone/feat/a')"
}

# The bridge ref is an implementation detail; a trunk replay must read as `main` to the user.
test_merge_source_branch_strips_bridge_prefix() {
    assertEquals 'remote-svn/ stripped' 'main' "$(merge_source_branch "Merge branch 'remote-svn/main' into feat/x")"
}

test_merge_source_branch_rejects_what_it_cannot_read() {
    local out
    out="$(merge_source_branch 'Merge two things together' || true)"
    assertEquals 'unquoted prose yields nothing' '' "$out"
    out="$(merge_source_branch 'feat: not a merge at all' || true)"
    assertEquals 'non-merge subject yields nothing' '' "$out"
    out="$(merge_source_branch "Merge branch 'has a space' into main" || true)"
    assertEquals 'whitespace is not a branch name' '' "$out"
    out="$(merge_source_branch "Merge branch '' into main" || true)"
    assertEquals 'empty quotes yield nothing' '' "$out"
    # A crafted name must not be able to forge a group header inside the locked body.
    out="$(merge_source_branch "Merge branch 'x】fake【y' into main" || true)"
    assertEquals 'group-header brackets rejected' '' "$out"
}

# ── resolve_path_within_worktree ─────────────────────────────────────────────
#
# Guards an IRREVERSIBLE operation: remove-svn-file.sh feeds the result to `svn delete` +
# `svn commit` against the shared repository. A path that escapes the bridge worktree has to stop
# before that, not be discovered in the history afterwards.

test_resolve_path_within_worktree_accepts_ordinary_relative() {
    local root out
    root="$(mktemp -d)"
    out="$(resolve_path_within_worktree "$root" 'docs/a.txt')" || fail 'ordinary relative path rejected'
    case "$out" in
        */docs/a.txt) assertTrue 'resolves under the root' 0 ;;
        *) fail "unexpected resolution: $out" ;;
    esac
    rm -rf "$root"
}

test_resolve_path_within_worktree_refuses_dotdot() {
    local root
    root="$(mktemp -d)"
    if resolve_path_within_worktree "$root" '../outside.txt' >/dev/null 2>&1; then
        fail 'a leading .. was accepted'
    fi
    if resolve_path_within_worktree "$root" 'docs/../../outside.txt' >/dev/null 2>&1; then
        fail 'a buried .. was accepted'
    fi
    if resolve_path_within_worktree "$root" '..\outside.txt' >/dev/null 2>&1; then
        fail 'a backslash-separated .. was accepted'
    fi
    rm -rf "$root"
}

test_resolve_path_within_worktree_refuses_absolute_and_empty() {
    local root
    root="$(mktemp -d)"
    if resolve_path_within_worktree "$root" '/etc/passwd' >/dev/null 2>&1; then
        fail 'a POSIX absolute path was accepted'
    fi
    if resolve_path_within_worktree "$root" 'C:\Windows\notepad.exe' >/dev/null 2>&1; then
        fail 'a Windows absolute path was accepted'
    fi
    if resolve_path_within_worktree "$root" '' >/dev/null 2>&1; then
        fail 'an empty path was accepted'
    fi
    rm -rf "$root"
}

# '..' inside a FILENAME is legal. Checking for the substring instead of the path segments would
# reject real files like "notes..bak" -- a guard that breaks valid input is its own bug.
test_resolve_path_within_worktree_allows_dotdot_inside_filename() {
    local root out
    root="$(mktemp -d)"
    out="$(resolve_path_within_worktree "$root" 'notes..bak')" || fail 'notes..bak was rejected'
    case "$out" in
        */notes..bak) assertTrue 'filename containing .. is allowed' 0 ;;
        *) fail "unexpected resolution: $out" ;;
    esac
    rm -rf "$root"
}

# --- assert_svn_version (issue #26) -------------------------------------------
# A stub `svn` is injected via PATH: assert_svn_version calls `command svn`, which bypasses the
# shim function and resolves from PATH, so the stub is what gets run.

_make_svn_stub() {
    # $1 = sandbox dir, $2 = version string the stub reports
    local dir="$1" version="$2"
    printf '#!/usr/bin/env bash\necho "%s"\n' "$version" > "$dir/svn"
    chmod +x "$dir/svn"
}

test_assert_svn_version_rejects_pre_1_9() {
    local sandbox out rc
    sandbox="$(mktemp -d)"
    # 1.8.15 is exactly what chocolatey's win32svn package pins to -- the realistic way a user
    # ends up here.
    _make_svn_stub "$sandbox" '1.8.15'

    out="$(PATH="$sandbox:$PATH" assert_svn_version 2>&1)" && rc=0 || rc=$?
    assertNotEquals 'pre-1.9 client must be rejected' '0' "$rc"
    case "$out" in
        *--show-item*) assertTrue 'message names --show-item' 0 ;;
        *) fail "message does not explain the cause: $out" ;;
    esac
    rm -rf "$sandbox"
}

test_assert_svn_version_accepts_1_9_and_newer() {
    local sandbox rc
    sandbox="$(mktemp -d)"
    _make_svn_stub "$sandbox" '1.14.2'
    PATH="$sandbox:$PATH" assert_svn_version >/dev/null 2>&1 && rc=0 || rc=$?
    assertEquals '1.14.2 must be accepted' '0' "$rc"

    # Boundary: exactly 1.9 is the first version that has --show-item.
    _make_svn_stub "$sandbox" '1.9.0'
    PATH="$sandbox:$PATH" assert_svn_version >/dev/null 2>&1 && rc=0 || rc=$?
    assertEquals '1.9.0 must be accepted' '0' "$rc"
    rm -rf "$sandbox"
}

test_assert_svn_version_fails_loudly_on_unparseable_output() {
    local sandbox rc
    sandbox="$(mktemp -d)"
    _make_svn_stub "$sandbox" 'not-a-version'
    PATH="$sandbox:$PATH" assert_svn_version >/dev/null 2>&1 && rc=0 || rc=$?
    assertNotEquals 'unparseable version must not silently pass' '0' "$rc"
    rm -rf "$sandbox"
}

# --- svn_target (issue #34) ---------------------------------------------------
# svn parses a trailing @<rev> on every TARGET argument, so a legal filename containing '@' made
# the whole commit fail with E200009. The escape is one appended '@'.

test_svn_target_escapes_at_sign() {
    assertEquals 'retina filename gets the peg escape' \
        'Content/img/banner@2x.jpg@' "$(svn_target 'Content/img/banner@2x.jpg')"
}

test_svn_target_is_unconditional() {
    # Applied to every path rather than only those containing '@': a detect-then-escape branch is
    # one more place for our parsing to disagree with svn's, and `foo.txt@` resolves to `foo.txt`.
    assertEquals 'plain filename still gets the escape' 'src/app.txt@' "$(svn_target 'src/app.txt')"
}

test_svn_target_handles_trailing_at() {
    assertEquals 'a path already ending in @ still gets one more' 'weird@@' "$(svn_target 'weird@')"
}

# --- write_svn_targets_file (issue #35) ---------------------------------------
# svn reads a --targets file through CP_ACP on Windows, NOT UTF-8: a UTF-8 file makes svn look for
# a mojibake path and report "is not under version control". These lock the line-per-path shape and
# the ASCII round-trip; the encoding itself is covered end-to-end by the push test.

test_write_svn_targets_file_one_path_per_line() {
    local out
    out="$(mktemp)"
    write_svn_targets_file "$out" 'Content/one.txt@' 'Content/two.txt@'
    assertEquals 'two lines written' '2' "$(grep -c . "$out" || true)"
    assertEquals 'first line intact'  'Content/one.txt@' "$(sed -n '1p' "$out" | tr -d '\r')"
    assertEquals 'second line intact' 'Content/two.txt@' "$(sed -n '2p' "$out" | tr -d '\r')"
    rm -f "$out"
}

test_write_svn_targets_file_handles_many_paths() {
    local out n args=()
    out="$(mktemp)"
    for (( n = 1; n <= 3000; n++ )); do args+=("bulk/file$n.txt@"); done
    write_svn_targets_file "$out" "${args[@]}"
    assertEquals '3000 lines written' '3000' "$(grep -c . "$out" || true)"
    rm -f "$out"
}

# The refusal. A path the ANSI codepage cannot represent (CJK on a CP1252 host, which is what the
# CI Windows runner is) must fail HERE, naming the codepage -- not be written as question marks and
# left for svn to report as "E200009 ... targets don't exist", which names neither the file nor the
# cause. The behaviour has been in place since #35; it had no test, and the PowerShell twin was
# silently substituting '?' until that was noticed.
test_write_svn_targets_file_refuses_an_unrepresentable_path() {
    local out unrep err rc cp
    # An emoji, not a CJK name: CP950 CARRIES CJK, so a CJK name would make this case skip on the
    # very machines most likely to run it by hand, and only ever execute on the CI runner. No
    # legacy ANSI codepage can represent an astral character, so this exercises the refusal on
    # every non-UTF-8 host.
    unrep="$(printf 'Content/\xF0\x9F\x98\x80.txt')"
    cp="$(_svn_ansi_codepage 2>/dev/null || true)"
    # Nothing to refuse where every path is representable: off Windows, on a UTF-8 ACP, or when the
    # codepage lookup itself failed (that path has its own, separate error).
    if [ -z "$cp" ] || [ "$cp" = '65001' ]; then
        startSkipping
        return 0
    fi
    out="$(mktemp)"
    err="$(write_svn_targets_file "$out" "$unrep" 2>&1)"; rc=$?
    assertNotEquals 'writing an unrepresentable path fails' 0 "$rc"
    case "$err" in
        *'cannot represent'*) assertTrue 'the message says the codepage cannot represent it' 0 ;;
        *) fail "expected a 'cannot represent' message, got: $err" ;;
    esac
    case "$err" in
        *"CP$cp"*) assertTrue 'the message names the codepage' 0 ;;
        *) fail "expected the message to name CP$cp, got: $err" ;;
    esac
    rm -f "$out"
}

# --- expand_unversioned_dir (issue #24) ---------------------------------------
# svn status collapses an unversioned directory into a single '?' line; the commit step adds it
# recursively. These cover the expansion that closes that gap in the confirmation list.

test_expand_unversioned_dir_lists_files_recursively() {
    local repo out count
    repo="$(mktemp -d)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    mkdir -p "$repo/NewFolder/sub"
    echo 'a' > "$repo/NewFolder/a.txt"
    echo 'b' > "$repo/NewFolder/sub/b.txt"

    out="$(expand_unversioned_dir "$repo" 'NewFolder')"
    count="$(printf '%s\n' "$out" | grep -c '^A|' || true)"
    assertEquals 'both files are expanded' '2' "$count"
    case "$out" in
        *'A|tracked|NewFolder/a.txt'*) assertTrue 'top-level file listed' 0 ;;
        *) fail "top-level file missing: $out" ;;
    esac
    case "$out" in
        *'A|tracked|NewFolder/sub/b.txt'*) assertTrue 'nested file listed' 0 ;;
        *) fail "nested file missing: $out" ;;
    esac
    rm -rf "$repo"
}

test_expand_unversioned_dir_marks_ignored_children() {
    local repo out
    repo="$(mktemp -d)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    echo 'NewFolder/skip/' > "$repo/.gitignore"
    mkdir -p "$repo/NewFolder/skip"
    echo 'k' > "$repo/NewFolder/keep.txt"
    echo 'j' > "$repo/NewFolder/skip/junk.txt"

    out="$(expand_unversioned_dir "$repo" 'NewFolder')"
    case "$out" in
        *'A|tracked|NewFolder/keep.txt'*) assertTrue 'kept file is tracked' 0 ;;
        *) fail "kept file missing or mislabelled: $out" ;;
    esac
    case "$out" in
        *'A|ignored|NewFolder/skip/junk.txt'*) assertTrue 'ignored file is labelled ignored' 0 ;;
        *) fail "ignored file missing or mislabelled: $out" ;;
    esac
    rm -rf "$repo"
}

test_expand_unversioned_dir_skips_metadata_dirs() {
    local repo out count
    repo="$(mktemp -d)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    mkdir -p "$repo/NewFolder/.svn"
    echo 'r' > "$repo/NewFolder/real.txt"
    echo 'x' > "$repo/NewFolder/.svn/entries"

    out="$(expand_unversioned_dir "$repo" 'NewFolder')"
    count="$(printf '%s\n' "$out" | grep -c '^A|' || true)"
    assertEquals 'only the real file is listed' '1' "$count"
    rm -rf "$repo"
}

test_expand_unversioned_dir_ignores_non_directories() {
    local repo out
    repo="$(mktemp -d)"
    git -C "$repo" init -q -b main >/dev/null 2>&1
    echo 'p' > "$repo/plain.txt"

    out="$(expand_unversioned_dir "$repo" 'plain.txt')"
    assertEquals 'a file target yields nothing' '' "$out"
    out="$(expand_unversioned_dir "$repo" 'DoesNotExist')"
    assertEquals 'a missing target yields nothing' '' "$out"
    rm -rf "$repo"
}

# --- the --non-interactive shim (issue #137) ----------------------------------------------------
#
# Everything that makes the `& svn ... 2>$null` call sites safe rests on ONE property: every svn
# invocation carries --non-interactive. Without it svn can PROMPT, and a prompt is written to
# stderr on an otherwise healthy call -- which is exactly the #128 shape (under EAP=Stop the `2>`
# redirection turns that into a terminating error and the $LASTEXITCODE guard below it becomes
# unreachable). It has already cost one real incident: a bootstrap replay sat in svn's interactive
# conflict prompt indefinitely.
#
# That property had no test at all. Both checks below fail LOUDLY if it is broken, because the
# breakage itself is silent: svn simply starts prompting again.

# A fake `svn` on PATH: answers the version gate, and records the argv of every other call.
_tp_make_fake_svn() {
    local dir="$1"
    cat > "$dir/svn" <<'FAKE'
#!/usr/bin/env bash
if [ "$1" = "--version" ]; then printf '1.14.5\n'; exit 0; fi
printf '%s\n' "$@" > "$TP_FAKE_SVN_ARGV"
exit 0
FAKE
    chmod +x "$dir/svn"
}

test_svn_shim_injects_non_interactive() {
    local tmp
    tmp="$(mktemp -d -t turbo-common-shim-XXXXXX)"
    _tp_make_fake_svn "$tmp"

    local saved_path="$PATH" saved_checked="${_tp_svn_version_checked:-}"
    PATH="$tmp:$PATH"
    _tp_svn_version_checked=''
    TP_FAKE_SVN_ARGV="$tmp/argv"
    export TP_FAKE_SVN_ARGV

    svn info 'http://example.invalid/repo' >/dev/null 2>&1

    PATH="$saved_path"
    _tp_svn_version_checked="$saved_checked"

    assertTrue 'the shim invoked svn at all' "[ -f '$tmp/argv' ]"
    grep -qx -- '--non-interactive' "$tmp/argv"
    assertTrue 'the svn shim injects --non-interactive' $?
    # It must be injected, not replace the caller's own arguments.
    grep -qx -- 'info' "$tmp/argv"
    assertTrue 'the caller arguments survive the shim' $?
    rm -rf "$tmp"
}

# Repo-level: the shim only applies to scripts that SOURCE the lib defining it. A script that
# invokes svn without sourcing it gets the bare exe, no --non-interactive, and the prompt class
# comes straight back -- with nothing to warn anyone. Checked for both language halves.
test_every_svn_calling_script_sources_the_shim() {
    local scripts_dir="$PLUGIN_ROOT/scripts"
    local scanned=0 invoking=0 f
    local svn_verbs='add|info|update|commit|log|status|propget|propset|propdel|rm|mkdir|checkout|copy|revert|cleanup|cat|list|delete|move|import|export|resolve|switch'

    for f in "$scripts_dir"/*.sh; do
        [ -e "$f" ] || continue
        [ "$(basename "$f")" = 'common.sh' ] && continue
        scanned=$((scanned + 1))
        if grep -qE "(^|[^[:alnum:]_.-])svn[[:space:]]+($svn_verbs)([[:space:]]|\$)" "$f"; then
            invoking=$((invoking + 1))
            if ! grep -qE 'common\.sh' "$f"; then
                fail "$(basename "$f") invokes svn but does not source common.sh (no --non-interactive)"
            fi
        fi
    done

    for f in "$scripts_dir"/*.ps1; do
        [ -e "$f" ] || continue
        scanned=$((scanned + 1))
        if grep -qE '& *svn[[:space:]]' "$f"; then
            invoking=$((invoking + 1))
            if ! grep -qE 'Common\.ps1' "$f"; then
                fail "$(basename "$f") invokes svn but does not source Common.ps1 (no --non-interactive)"
            fi
        fi
    done

    # Floors: a pattern that silently stops matching would turn this test into a no-op that still
    # reports green -- the exact failure mode it exists to prevent.
    assertTrue "expected to scan many scripts, scanned $scanned" "[ '$scanned' -ge 20 ]"
    assertTrue "expected several svn-invoking scripts, found $invoking" "[ '$invoking' -ge 6 ]"
}

# ─── ensure_bridge_eol_faithful — the pin must survive `.gitattributes` (issue #164) ─────────
# Build a repo whose blobs are LF, whose attributes mark everything text, and whose checkout is
# configured to write CRLF. `core.eol` is pinned to `crlf` rather than left at its `native`
# default on purpose: `native` is CRLF only on Windows, so leaving it would make this case pass
# for free on Linux -- reporting green on the half of CI that never exercised the bug.
# Echoes $1 = repo root of a fixture ready for ensure_bridge_eol_faithful; non-zero on failure.
make_eol_fixture() {
    local root="$1"
    git -C "$root" init -q -b main >/dev/null 2>&1 || return 1
    git -C "$root" config user.email 'test@turbo-plugin' || return 1
    git -C "$root" config user.name 'turbo-plugin-test' || return 1
    printf '* text=auto\n' > "$root/.gitattributes" || return 1
    printf 'a\nb\nc\n' > "$root/f.txt" || return 1
    git -C "$root" add -A >/dev/null 2>&1 || return 1
    git -C "$root" commit -qm 'seed' >/dev/null 2>&1 || return 1
    git -C "$root" config core.autocrlf false || return 1
    git -C "$root" config core.eol crlf || return 1
    # Fixture guard: a worktree that silently failed to be created would leave a plain directory
    # behind, and every assertion below would then measure the wrong tree while still passing.
    git -C "$root" worktree add -q "$root/bridge" -b bridge >/dev/null 2>&1 || return 1
    [ -e "$root/bridge/.git" ] || return 1
}

# Count CR BYTES, not lines. `grep -c $'\r'` answers the same number for a CRLF file and an LF
# file of equal length, so asserting on it is an identity, not a test.
count_cr_bytes() {
    tr -dc '\r' < "$1" | wc -c | tr -d ' '
}

test_bridge_eol_faithful_defeats_text_auto() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolpin-XXXXXX)"
    (
        make_eol_fixture "$tmp" || exit 98
        ensure_bridge_eol_faithful "$tmp" "$tmp/bridge" || exit 97

        # The pin only bites when git next writes the file, so force a fresh checkout.
        rm -f "$tmp/bridge/f.txt"
        git -C "$tmp/bridge" checkout -- f.txt >/dev/null 2>&1 || exit 96

        cr="$(count_cr_bytes "$tmp/bridge/f.txt")"
        if [ "$cr" -ne 0 ]; then
            echo "bridge checkout wrote $cr CR bytes but the blob is pure LF" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'bridge checkout is byte-faithful to the blob even under `* text=auto`' 0 "$rc"
}

# The docstring promises the pin is scoped to the bridge. If it ever leaked to the shared config
# it would silently rewrite the user's own working copy, which is not this function's business.
test_bridge_eol_faithful_leaves_main_worktree_alone() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolscope-XXXXXX)"
    (
        make_eol_fixture "$tmp" || exit 98
        ensure_bridge_eol_faithful "$tmp" "$tmp/bridge" || exit 97

        rm -f "$tmp/f.txt"
        git -C "$tmp" checkout -- f.txt >/dev/null 2>&1 || exit 96

        cr="$(count_cr_bytes "$tmp/f.txt")"
        # 3 lines of CRLF -- the main worktree keeps whatever the user configured.
        if [ "$cr" -ne 3 ]; then
            echo "main worktree wrote $cr CR bytes; expected 3 (its own core.eol=crlf)" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'the pin does not reach outside the bridge worktree' 0 "$rc"
}

test_bridge_eol_faithful_is_idempotent() {
    local tmp rc
    tmp="$(mktemp -d -t turbo-eolidem-XXXXXX)"
    (
        make_eol_fixture "$tmp" || exit 98
        ensure_bridge_eol_faithful "$tmp" "$tmp/bridge" || exit 97
        ensure_bridge_eol_faithful "$tmp" "$tmp/bridge" || exit 95
        eol="$(git -C "$tmp/bridge" config --worktree core.eol 2>/dev/null || true)"
        if [ "$eol" != 'lf' ]; then
            echo "expected core.eol=lf on the bridge worktree, got '$eol'" >&2
            exit 1
        fi
        exit 0
    )
    rc=$?
    rm -rf "$tmp" 2>/dev/null || true
    assertEquals 'calling the pin twice succeeds and leaves core.eol=lf' 0 "$rc"
}

# shellcheck disable=SC1090
. "$SHUNIT2"
