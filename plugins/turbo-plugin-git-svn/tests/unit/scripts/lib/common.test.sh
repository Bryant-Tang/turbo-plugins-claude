#!/usr/bin/env bash
# common.test.sh (shUnit2)
# Script under test: scripts/lib/common.sh
#
# Covers:
#   - probe_git_version            — happy (git on PATH >= 2.31)
#   - assert_svn_version           — pre-1.9 rejected / 1.9 boundary / unparseable fails loudly
#   - expand_unversioned_dir       — recursive listing / ignored children / metadata skip / non-dir
#   - get_normalized_absolute_path — /c/foo Git-Bash style, forward-slash, empty
#   - get_main_worktree            — fresh git init top-level + linked worktree + explicit root
#   - resolve_git_root             — omitted is '.', missing path fails loudly
#   - test_is_main_worktree        — explicit root judged instead of the cwd
#   - test_is_submodule            — fresh git init is NOT a submodule
#   - assert_trusted_svn_url       — boundary-safe SVN URL trust check (U1; SKIPs w/o svn)
#   - resolve_repo_path            — relative / ./relative / absolute / Git-Bash / empty
#   - resolve_remote_worktree      — main / test-<n> / unsupported
#   - get_worktrees_dir            — explicit main → nested container
#   - write_utf8_no_bom            — CJK no-BOM byte-equal to canonical UTF-8 (R6)
#   - read_turbo_plugin_config     — flat mode + section/key sentinel + top-level key
#   - resolve_config_value         — config merge chain + config.local.toml override

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
    git -C "$repo" merge -q --no-ff -m 'Merge branch side into main' side >/dev/null 2>&1
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
    git -C "$repo" merge -q --no-ff -m 'Merge main into feat/x' main >/dev/null 2>&1
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

# shellcheck disable=SC1090
. "$SHUNIT2"
