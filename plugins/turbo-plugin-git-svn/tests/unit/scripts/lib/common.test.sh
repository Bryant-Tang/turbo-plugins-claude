#!/usr/bin/env bash
# common.test.sh (shUnit2)
# Script under test: scripts/lib/common.sh
#
# Covers:
#   - probe_git_version            — happy (git on PATH >= 2.31)
#   - get_normalized_absolute_path — /c/foo Git-Bash style, forward-slash, empty
#   - get_main_worktree            — fresh git init top-level + linked worktree
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

# ─── probe_git_version ───────────────────────────────────────────────────────
test_probe_git_version_happy() {
    probe_git_version 2>/dev/null
    assertTrue 'probe_git_version succeeds when git present and >= 2.31' $?
}

# ─── get_normalized_absolute_path ────────────────────────────────────────────
test_normalize_git_bash_c() {
    local norm
    norm="$(get_normalized_absolute_path '/c/projdir' 2>/dev/null || true)"
    case "$norm" in
        c:*) assertTrue "lowercased drive c: (got: $norm)" 0 ;;
        *)   fail "expected c:/... form, got '$norm'" ;;
    esac
}

test_normalize_forward_slash_abs() {
    local norm
    norm="$(get_normalized_absolute_path 'C:/Some/Path' 2>/dev/null || true)"
    case "$norm" in
        c:/*) assertTrue "lowercased drive on forward-slash abs (got: $norm)" 0 ;;
        *)    fail "expected c:/... got '$norm'" ;;
    esac
}

test_normalize_git_bash_d() {
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
        if [[ -n "$mw" && "$mw" =~ ^[a-z]:.* && "$mw" == *"$tmpdir_basename"* ]]; then
            exit 0
        fi
        echo "expected path containing '$tmpdir_basename' on lowercased drive, got '$mw'" >&2
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
    local out
    out="$(resolve_repo_path 'C:/repo/root' 'D:/elsewhere/app' 2>/dev/null || true)"
    if [[ "$out" == D:/elsewhere/app && "$out" != *repo/root* ]]; then
        assertTrue "absolute drive path kept standalone (got: $out)" 0
    else
        fail "expected D:/elsewhere/app standalone, got '$out'"
    fi
}

test_resolve_repo_path_git_bash() {
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

# shellcheck disable=SC1090
. "$SHUNIT2"
