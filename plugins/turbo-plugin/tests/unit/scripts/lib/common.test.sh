#!/usr/bin/env bash
# common.test.sh
#
# Unit tests for plugins/turbo-plugin/scripts/lib/common.sh.
# Covers:
#   1. probe_git_version          — happy (git on PATH ≥ 2.31)
#   2. get_normalized_absolute_path — /c/foo Git-Bash style → C:/foo or lowercased drive
#   3. get_main_worktree          — inside a fresh git init reports the worktree's top-level
#   4. test_is_submodule          — fresh git init is NOT a submodule (returns non-zero)
#   - assert_trusted_svn_url      — boundary-safe SVN URL trust check (U1)
#   - U8 lib-helper depth coverage (mirrors U7 PS side; excludes the removed
#     get_project_identity_hash, see U3 N/A): get_normalized_absolute_path more
#     shapes, get_main_worktree linked-worktree, resolve_repo_path,
#     resolve_remote_worktree, write_utf8_no_bom (CJK no-BOM byte check, R6),
#     format_iis_express_site_name, read_turbo_plugin_config.
#
# Conventions:
#   - last non-empty line is "OK" (pass) or "FAIL: <reason>" (fail)
#   - exit 0 if all pass, 1 otherwise

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../../.." && pwd)"
COMMON_SH="$PLUGIN_ROOT/scripts/lib/common.sh"

passed=0
failed=0
fail_msgs=()

record_pass() { echo "  [PASS] $1"; passed=$((passed + 1)); }
record_fail() { echo "  [FAIL] $1: $2"; failed=$((failed + 1)); fail_msgs+=("$1: $2"); }

if [[ ! -f "$COMMON_SH" ]]; then
    echo "FAIL: common.sh not found at $COMMON_SH"
    exit 1
fi

# Source under a subshell where set -e is relaxed; common.sh's `set -euo pipefail` is OK in test.
# shellcheck source=/dev/null
source "$COMMON_SH"

# Case 1: probe_git_version — happy
if probe_git_version 2>/dev/null; then
    record_pass "probe_git_version succeeds when git is present and >= 2.31"
else
    record_fail "probe_git_version" "returned non-zero; git likely missing or < 2.31"
fi

# Case 2: get_normalized_absolute_path — Git Bash /c/foo → c:/foo (lowercased)
norm="$(get_normalized_absolute_path '/c/Turbo' 2>/dev/null || true)"
case "$norm" in
    c:/Turbo|c:/turbo)
        record_pass "get_normalized_absolute_path converts /c/Turbo to lowercased-drive form (got: $norm)"
        ;;
    *)
        # realpath -m may resolve /c/Turbo differently on some Git Bash builds; accept
        # any path that starts with the lowercased drive c:.
        if [[ "$norm" =~ ^c:.* ]]; then
            record_pass "get_normalized_absolute_path lowercases drive letter (got: $norm)"
        else
            record_fail "get_normalized_absolute_path" "expected c:/... form, got '$norm'"
        fi
        ;;
esac

# Case 3: get_main_worktree — inside a fresh git init dir, returns its top-level
TMPDIR_GMW="$(mktemp -d -t turbo-common-gmw-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" 2>/dev/null || true' EXIT
(
    cd "$TMPDIR_GMW" || exit 99
    git init -q -b main >/dev/null 2>&1
    git config user.email 'test@turbo-plugin'
    git config user.name 'turbo-plugin-test'
    git commit -q --allow-empty -m 'init' >/dev/null 2>&1

    mw="$(get_main_worktree 2>/dev/null || true)"
    # Match by basename — Windows 8.3 short name (mktemp via $TMPDIR /MELWU~1/) vs
    # git rev-parse --show-toplevel (long /Mel Wu/) make literal-equal comparison
    # unreliable. Verify mw is non-empty, starts with normalized drive, and contains
    # the unique tmpdir basename.
    tmpdir_basename="${TMPDIR_GMW##*/}"
    if [[ -n "$mw" && "$mw" =~ ^[a-z]:.* && "$mw" == *"$tmpdir_basename"* ]]; then
        echo "  [PASS] get_main_worktree returns normalized top-level inside git repo (got: $mw)"
        exit 0
    fi
    echo "  [FAIL] get_main_worktree: expected path containing '$tmpdir_basename' on lowercased drive, got '$mw'"
    exit 1
)
case3_rc=$?
if [[ "$case3_rc" -eq 0 ]]; then
    passed=$((passed + 1))
else
    failed=$((failed + 1))
    fail_msgs+=("get_main_worktree: see [FAIL] above")
fi

# Case 4: test_is_submodule — fresh git init is NOT a submodule (returns non-zero)
TMPDIR_TIS="$(mktemp -d -t turbo-common-tis-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" 2>/dev/null || true' EXIT
(
    cd "$TMPDIR_TIS" || exit 99
    git init -q -b main >/dev/null 2>&1
    if test_is_submodule; then
        echo "  [FAIL] test_is_submodule returned 0 (true) inside a non-submodule fresh git init"
        exit 1
    fi
    echo "  [PASS] test_is_submodule returns non-zero (not a submodule) in fresh git init"
    exit 0
)
case4_rc=$?
if [[ "$case4_rc" -eq 0 ]]; then
    passed=$((passed + 1))
else
    failed=$((failed + 1))
    fail_msgs+=("test_is_submodule: see [FAIL] above")
fi

# ─── assert_trusted_svn_url (U1) ─────────────────────────────────────────────
#
# Boundary-safe + case-normalized + traversal-reject trust check anchored on the
# trusted working copy's repos-root-url (NOT trunk url). Uses the seed SVN dump
# loaded into a throwaway repo; trunk/ + branches/test-1/ let us prove a legit
# sibling branch passes (= repos-root). Fail-closed uses an empty non-WC dir.

assert_trusted_ok() {
    # $1=name $2=wc $3=candidate ; expect exit 0
    local name="$1" wc="$2" cand="$3"
    # `set +e` locally so a failing helper never aborts the test under common.sh's set -e.
    set +e
    assert_trusted_svn_url "$wc" "$cand" >/dev/null 2>&1
    local rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        record_pass "$name"
    else
        record_fail "$name" "expected trusted (exit 0), got non-zero for '$cand'"
    fi
}
assert_trusted_reject() {
    # $1=name $2=wc $3=candidate $4=stderr-substr(optional) ; expect non-zero
    local name="$1" wc="$2" cand="$3" want="${4:-}"
    local err rc
    set +e
    err="$(assert_trusted_svn_url "$wc" "$cand" 2>&1 >/dev/null)"
    rc=$?
    set -e
    if [[ $rc -eq 0 ]]; then
        record_fail "$name" "expected reject (non-zero), got exit 0 for '$cand'"
    elif [[ -n "$want" && "$err" != *"$want"* ]]; then
        record_fail "$name" "rejected but stderr missing '$want': $err"
    else
        record_pass "$name"
    fi
}

if ! command -v svn >/dev/null 2>&1 || ! command -v svnadmin >/dev/null 2>&1; then
    echo "  [SKIP] svn/svnadmin not on PATH — assert_trusted_svn_url cases skipped."
else
    DUMP_U1="$(cd -- "$PLUGIN_ROOT" && pwd)/tests/fixtures/seed/svn-repo-r1-r20.dump"
    if [[ ! -f "$DUMP_U1" ]]; then
        echo "  [SKIP] seed dump missing at $DUMP_U1 — run build-seed-repo.sh."
    else
        TMPDIR_U1="$(mktemp -d -t turbo-common-trusturl-XXXXXX)"
        trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" "$TMPDIR_U1" 2>/dev/null || true' EXIT
        SVN_REPO="$TMPDIR_U1/repo"
        WC_U1="$TMPDIR_U1/wc"
        EMPTY_NONWC="$TMPDIR_U1/empty-non-wc"
        mkdir -p "$EMPTY_NONWC"

        load_ok=1
        svnadmin create "$SVN_REPO" >/dev/null 2>&1 || load_ok=0
        # The dump is committed as binary (LF preserved — no CRLF mangle), so a native
        # bash stdin redirect loads cleanly without the cmd.exe / cygpath dance.
        if [[ $load_ok -eq 1 ]]; then
            svnadmin load "$SVN_REPO" < "$DUMP_U1" >/dev/null 2>&1 || load_ok=0
        fi

        if [[ $load_ok -eq 0 ]]; then
            echo "  [SKIP] svnadmin create/load failed (likely dump LF→CRLF mangle); cannot build trust fixture."
        else
            # Build a file:// URI with Windows drive form when under Git Bash.
            repo_for_uri="$SVN_REPO"
            if [[ "$repo_for_uri" =~ ^/([a-zA-Z])/(.*)$ ]]; then
                repo_for_uri="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
            fi
            REPO_URI="file:///$repo_for_uri"

            svn checkout "$REPO_URI/trunk" "$WC_U1" >/dev/null 2>&1 || true
            REPOS_ROOT="$(svn info --show-item repos-root-url "$WC_U1" 2>/dev/null | tr -d '\r\n' || true)"

            if [[ -z "$REPOS_ROOT" ]]; then
                echo "  [SKIP] svn checkout of trusted WC failed; cannot build trust fixture."
            else
                echo "  (trusted repos-root-url = $REPOS_ROOT)"

                # Confirm the helper queries repos-root-url (not url): a legit sibling
                # branch under branches/ must be accepted — only repos-root makes that true.
                assert_trusted_ok     "same-repo trunk URL is trusted"                       "$WC_U1" "$REPOS_ROOT/trunk"
                assert_trusted_ok     "legit sibling branches/test-1 is trusted (repos-root)" "$WC_U1" "$REPOS_ROOT/branches/test-1"
                assert_trusted_reject "prefix-confusion <root>-evil/trunk is rejected (R10)"  "$WC_U1" "${REPOS_ROOT}-evil/trunk"

                # Uppercase scheme → normalized, still trusted (R11)
                UPPER_ROOT="${REPOS_ROOT/#file:\/\//FILE://}"
                assert_trusted_ok     "uppercase scheme FILE:// normalizes and is trusted (R11)" "$WC_U1" "$UPPER_ROOT/trunk"

                # Trailing-slash candidate variant → same as no slash
                assert_trusted_ok     "trailing-slash candidate matches no-slash result"     "$WC_U1" "$REPOS_ROOT/branches/test-1/"

                # Out-of-bounds + different scheme/host → reject
                assert_trusted_reject "out-of-bounds file:///C:/Windows/... is rejected"      "$WC_U1" "file:///C:/Windows/System32/"
                assert_trusted_reject "different scheme/host http://attacker/... is rejected" "$WC_U1" "http://attacker.example/repo"

                # Path traversal → reject
                assert_trusted_reject "candidate with '..' traversal is rejected"             "$WC_U1" "$REPOS_ROOT/trunk/../../etc"
                assert_trusted_reject "percent-encoded ..(%2e%2e) traversal rejected after decode" "$WC_U1" "$REPOS_ROOT/trunk/%2e%2e/%2e%2e/etc"

                # Fail-closed: empty non-WC reference → reject, with explanatory stderr
                assert_trusted_reject "fail-closed: non-WC trusted reference rejects"         "$EMPTY_NONWC" "$REPOS_ROOT/trunk" "fail closed"
            fi
        fi
    fi
fi

# ─── U8: lib helper depth coverage ───────────────────────────────────────────
#
# Direct unit tests for common.sh helpers that mirror U7's PS-side coverage,
# EXCLUDING get_project_identity_hash (removed v0.2.7+, see U3 N/A note). Helpers
# that return non-zero are wrapped in `if !` or local `set +e`/`set -e` blocks so
# common.sh's `set -euo pipefail` (active after sourcing) never aborts the test.

# ─── get_normalized_absolute_path — more shapes (forward-slash / /c Git-Bash / empty) ─
# Forward-slash absolute (already a Windows drive) → lowercased drive, preserved.
norm_fs="$(get_normalized_absolute_path 'C:/Some/Path' 2>/dev/null || true)"
if [[ "$norm_fs" =~ ^c:/ ]]; then
    record_pass "get_normalized_absolute_path lowercases drive on forward-slash abs path (got: $norm_fs)"
else
    record_fail "get_normalized_absolute_path forward-slash" "expected c:/... got '$norm_fs'"
fi
# /c/... Git-Bash style (distinct sample from the existing Case 2).
norm_gb="$(get_normalized_absolute_path '/d/Projects/App' 2>/dev/null || true)"
if [[ "$norm_gb" =~ ^d:.*Projects.*App$ ]]; then
    record_pass "get_normalized_absolute_path converts /d/Projects/App to d:/... (got: $norm_gb)"
else
    record_fail "get_normalized_absolute_path /d Git-Bash" "expected d:/...Projects...App got '$norm_gb'"
fi
# Empty input → non-zero (errexit-safe via `if !`).
if ! get_normalized_absolute_path '' >/dev/null 2>&1; then
    record_pass "get_normalized_absolute_path on empty input returns non-zero"
else
    record_fail "get_normalized_absolute_path empty" "expected non-zero exit on empty input, got exit 0"
fi

# ─── get_main_worktree — peer/linked worktree resolves to the SAME main path ──
# Existing Case 3 covers a single top-level repo. Here add a real linked worktree
# (git worktree add) and assert get_main_worktree from inside the linked worktree
# returns the MAIN worktree's top-level, not the linked one.
TMPDIR_LW="$(mktemp -d -t turbo-common-lw-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" "$TMPDIR_U1" "$TMPDIR_LW" 2>/dev/null || true' EXIT
(
    cd "$TMPDIR_LW" || exit 99
    mkdir main
    cd main || exit 99
    git init -q -b main >/dev/null 2>&1
    git config user.email 'test@turbo-plugin'
    git config user.name 'turbo-plugin-test'
    git commit -q --allow-empty -m 'init' >/dev/null 2>&1

    main_mw="$(get_main_worktree 2>/dev/null || true)"

    # Create a linked worktree on a new branch, cd into it, query again.
    git worktree add -q -b feat/lw ../linked >/dev/null 2>&1
    cd ../linked || exit 99
    linked_mw="$(get_main_worktree 2>/dev/null || true)"

    if [[ -z "$main_mw" || -z "$linked_mw" ]]; then
        echo "  [FAIL] get_main_worktree (linked): empty result (main='$main_mw' linked='$linked_mw')"
        exit 1
    fi
    # Linked worktree must report the SAME main path as the main worktree.
    if [[ "$linked_mw" == "$main_mw" ]]; then
        echo "  [PASS] get_main_worktree from a linked worktree returns the main worktree path (got: $linked_mw)"
        exit 0
    fi
    echo "  [FAIL] get_main_worktree (linked): linked='$linked_mw' != main='$main_mw'"
    exit 1
)
lw_rc=$?
if [[ "$lw_rc" -eq 0 ]]; then
    passed=$((passed + 1))
else
    failed=$((failed + 1))
    fail_msgs+=("get_main_worktree (linked worktree): see [FAIL] above")
fi

# ─── resolve_repo_path — relative / absolute / Git-Bash style ─────────────────
REPO_ROOT_RP='C:/repo/root'
# Relative path → resolved under repo_root.
rp_rel="$(resolve_repo_path "$REPO_ROOT_RP" 'src/app' 2>/dev/null || true)"
if [[ "$rp_rel" == *repo/root/src/app ]]; then
    record_pass "resolve_repo_path resolves relative path under repo_root (got: $rp_rel)"
else
    record_fail "resolve_repo_path relative" "expected .../repo/root/src/app, got '$rp_rel'"
fi
# Leading ./ relative → ./ stripped, resolved under repo_root.
rp_dot="$(resolve_repo_path "$REPO_ROOT_RP" './bin/out' 2>/dev/null || true)"
if [[ "$rp_dot" == *repo/root/bin/out ]]; then
    record_pass "resolve_repo_path strips leading ./ on relative path (got: $rp_dot)"
else
    record_fail "resolve_repo_path ./relative" "expected .../repo/root/bin/out, got '$rp_dot'"
fi
# Absolute Windows-drive path → returned standalone (NOT joined to repo_root).
rp_abs="$(resolve_repo_path "$REPO_ROOT_RP" 'D:/elsewhere/app' 2>/dev/null || true)"
if [[ "$rp_abs" == D:/elsewhere/app && "$rp_abs" != *repo/root* ]]; then
    record_pass "resolve_repo_path keeps absolute drive path standalone (got: $rp_abs)"
else
    record_fail "resolve_repo_path absolute" "expected D:/elsewhere/app standalone, got '$rp_abs'"
fi
# Git-Bash /c/... style → uppercased drive, resolved standalone.
rp_gb="$(resolve_repo_path "$REPO_ROOT_RP" '/c/Git/Bash/Path' 2>/dev/null || true)"
if [[ "$rp_gb" == C:/Git/Bash/Path && "$rp_gb" != *repo/root* ]]; then
    record_pass "resolve_repo_path converts /c Git-Bash style to C:/ standalone (got: $rp_gb)"
else
    record_fail "resolve_repo_path Git-Bash" "expected C:/Git/Bash/Path standalone, got '$rp_gb'"
fi
# Empty path → empty output, exit 0.
set +e
rp_empty="$(resolve_repo_path "$REPO_ROOT_RP" '')"
rp_empty_rc=$?
set -e
if [[ $rp_empty_rc -eq 0 && -z "$rp_empty" ]]; then
    record_pass "resolve_repo_path returns empty (exit 0) for empty path"
else
    record_fail "resolve_repo_path empty" "expected empty/exit-0, got rc=$rp_empty_rc out='$rp_empty'"
fi

# ─── resolve_remote_worktree — main / test-<n> / unsupported ──────────────────
WT_DIR='C:/proj.worktrees'
rrw_main="$(resolve_remote_worktree 'main' "$WT_DIR" 2>/dev/null || true)"
if [[ "$rrw_main" == "remote-svn-main|remote-svn/main|$WT_DIR/remote-svn-main" ]]; then
    record_pass "resolve_remote_worktree main → remote-svn-main triple (got: $rrw_main)"
else
    record_fail "resolve_remote_worktree main" "expected remote-svn-main triple, got '$rrw_main'"
fi
rrw_test="$(resolve_remote_worktree 'test-7' "$WT_DIR" 2>/dev/null || true)"
if [[ "$rrw_test" == "remote-svn-test-7|remote-svn/test-7|$WT_DIR/remote-svn-test-7" ]]; then
    record_pass "resolve_remote_worktree test-7 → remote-svn-test-7 triple (got: $rrw_test)"
else
    record_fail "resolve_remote_worktree test-7" "expected remote-svn-test-7 triple, got '$rrw_test'"
fi
# Unsupported branch → non-zero + stderr.
set +e
rrw_bad_err="$(resolve_remote_worktree 'feature/foo' "$WT_DIR" 2>&1 >/dev/null)"
rrw_bad_rc=$?
set -e
if [[ $rrw_bad_rc -ne 0 && "$rrw_bad_err" == *"unsupported branch"* ]]; then
    record_pass "resolve_remote_worktree rejects unsupported branch (non-zero + stderr)"
else
    record_fail "resolve_remote_worktree unsupported" "expected non-zero + 'unsupported branch', got rc=$rrw_bad_rc err='$rrw_bad_err'"
fi

# ─── get_worktrees_dir (U1) ──────────────────────────────────────────────────
# happy: given an explicit main worktree arg, echoes <main>/.turbo-plugin/worktrees
# (the v1.0 nested container location).
gwd_main='C:/proj/main'
gwd_out="$(get_worktrees_dir "$gwd_main" 2>/dev/null || true)"
if [[ "$gwd_out" == "$gwd_main/.turbo-plugin/worktrees" ]]; then
    record_pass "get_worktrees_dir explicit main → <main>/.turbo-plugin/worktrees (got: $gwd_out)"
else
    record_fail "get_worktrees_dir explicit" "expected $gwd_main/.turbo-plugin/worktrees, got '$gwd_out'"
fi

# ─── write_utf8_no_bom — CJK content, no BOM, byte-equal to canonical UTF-8 ────
# CJK sample from schema dict (single source of truth): path #1.1 + commit msg #3.1.
# Canonical UTF-8 bytes are produced by the same printf path the helper uses, then
# we verify (a) the first 3 bytes are NOT the UTF-8 BOM ef bb bf, and (b) the full
# file bytes equal the canonical UTF-8 encoding of the content.
TMPDIR_UTF8="$(mktemp -d -t turbo-common-utf8-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" "$TMPDIR_U1" "$TMPDIR_LW" "$TMPDIR_UTF8" 2>/dev/null || true' EXIT
CJK_CONTENT='路徑/含中文 — 修正中文 commit 訊息亂碼'
UTF8_FILE="$TMPDIR_UTF8/cjk.txt"
set +e
write_utf8_no_bom "$UTF8_FILE" "$CJK_CONTENT"
utf8_rc=$?
set -e
if [[ $utf8_rc -ne 0 || ! -f "$UTF8_FILE" ]]; then
    record_fail "write_utf8_no_bom" "helper failed (rc=$utf8_rc) or file not written"
else
    # (a) first 3 bytes must NOT be the BOM.
    first3="$(head -c 3 "$UTF8_FILE" | od -An -tx1 | tr -s ' ' | sed 's/^ //;s/ $//')"
    if [[ "$first3" == "ef bb bf" ]]; then
        record_fail "write_utf8_no_bom BOM" "file starts with UTF-8 BOM (ef bb bf) — must be no-BOM"
    else
        record_pass "write_utf8_no_bom writes no UTF-8 BOM (first 3 bytes: $first3)"
    fi
    # (b) full bytes equal canonical UTF-8 of the content.
    # Build canonical bytes via the C.UTF-8 printf path independently for comparison.
    CANON_FILE="$TMPDIR_UTF8/canon.txt"
    LC_ALL=C.UTF-8 printf '%s' "$CJK_CONTENT" > "$CANON_FILE" 2>/dev/null || printf '%s' "$CJK_CONTENT" > "$CANON_FILE"
    file_hex="$(od -An -tx1 "$UTF8_FILE" | tr -d ' \n')"
    canon_hex="$(od -An -tx1 "$CANON_FILE" | tr -d ' \n')"
    if [[ "$file_hex" == "$canon_hex" && -n "$file_hex" ]]; then
        record_pass "write_utf8_no_bom bytes equal canonical UTF-8 (len=${#file_hex} hex chars)"
    else
        record_fail "write_utf8_no_bom bytes" "written bytes != canonical UTF-8 (file='$file_hex' canon='$canon_hex')"
    fi
fi

# ─── format_iis_express_site_name — <stem>-<hash> (ASCII + CJK stem) ──────────
sn_ascii="$(format_iis_express_site_name '/path/to/HelloApp.csproj' 'deadbeef' 2>/dev/null || true)"
if [[ "$sn_ascii" == "HelloApp-deadbeef" ]]; then
    record_pass "format_iis_express_site_name ASCII stem → HelloApp-deadbeef (got: $sn_ascii)"
else
    record_fail "format_iis_express_site_name ASCII" "expected HelloApp-deadbeef, got '$sn_ascii'"
fi
# CJK stem (schema-style 中文 project name).
sn_cjk="$(format_iis_express_site_name '/path/中文專案.csproj' 'cafe1234' 2>/dev/null || true)"
if [[ "$sn_cjk" == "中文專案-cafe1234" ]]; then
    record_pass "format_iis_express_site_name CJK stem → 中文專案-cafe1234 (got: $sn_cjk)"
else
    record_fail "format_iis_express_site_name CJK" "expected 中文專案-cafe1234, got '$sn_cjk'"
fi

# ─── read_turbo_plugin_config — flat mode + section/key sentinel ──────────────
TMPDIR_CFG="$(mktemp -d -t turbo-common-cfg-XXXXXX)"
trap 'rm -rf "$TMPDIR_GMW" "$TMPDIR_TIS" "$TMPDIR_U1" "$TMPDIR_LW" "$TMPDIR_UTF8" "$TMPDIR_CFG" 2>/dev/null || true' EXIT
CFG_FILE="$TMPDIR_CFG/config.toml"
{
    echo 'schema_version = 1'
    echo ''
    echo '# a comment'
    echo '[svn]'
    echo 'url = "https://svn.example/repo"'
    echo 'empty_key = ""'
    echo '[iis]'
    echo 'port = 44300'
} > "$CFG_FILE"

# Flat mode (no filter) → "section.key=value" lines for all keys.
flat_out="$(read_turbo_plugin_config "$CFG_FILE" 2>/dev/null || true)"
if [[ "$flat_out" == *".schema_version=1"* \
   && "$flat_out" == *"svn.url=https://svn.example/repo"* \
   && "$flat_out" == *"iis.port=44300"* ]]; then
    record_pass "read_turbo_plugin_config flat mode dumps section.key=value lines"
else
    record_fail "read_turbo_plugin_config flat" "missing expected flat lines, got: $flat_out"
fi

# Targeted: section+key present → __TP_FOUND__:<value>.
tk_found="$(read_turbo_plugin_config "$CFG_FILE" 'svn' 'url' 2>/dev/null || true)"
if [[ "$tk_found" == "__TP_FOUND__:https://svn.example/repo" ]]; then
    record_pass "read_turbo_plugin_config targeted found → sentinel-prefixed value (got: $tk_found)"
else
    record_fail "read_turbo_plugin_config targeted found" "expected __TP_FOUND__:https://svn.example/repo, got '$tk_found'"
fi

# found-empty vs not-found: present-but-empty key emits sentinel with empty value.
tk_empty="$(read_turbo_plugin_config "$CFG_FILE" 'svn' 'empty_key' 2>/dev/null || true)"
if [[ "$tk_empty" == "__TP_FOUND__:" ]]; then
    record_pass "read_turbo_plugin_config found-empty key → '__TP_FOUND__:' (distinct from not-found)"
else
    record_fail "read_turbo_plugin_config found-empty" "expected '__TP_FOUND__:' for empty value, got '$tk_empty'"
fi

# not-found key → no output at all (distinguished from found-empty above).
tk_missing="$(read_turbo_plugin_config "$CFG_FILE" 'svn' 'no_such_key' 2>/dev/null || true)"
if [[ -z "$tk_missing" ]]; then
    record_pass "read_turbo_plugin_config not-found key → empty output (no sentinel)"
else
    record_fail "read_turbo_plugin_config not-found" "expected empty for missing key, got '$tk_missing'"
fi

# top-level key (empty section) targeted lookup → sentinel (F-U3.11 regression).
tk_toplevel="$(read_turbo_plugin_config "$CFG_FILE" '' 'schema_version' 2>/dev/null || true)"
if [[ "$tk_toplevel" == "__TP_FOUND__:1" ]]; then
    record_pass "read_turbo_plugin_config top-level key (empty section) → sentinel (got: $tk_toplevel)"
else
    record_fail "read_turbo_plugin_config top-level" "expected __TP_FOUND__:1, got '$tk_toplevel'"
fi

echo ''
echo '────────────────────────────────────────────────────────────────────────'
echo "common.test: passed=$passed failed=$failed"

if [[ $failed -gt 0 ]]; then
    for m in "${fail_msgs[@]}"; do echo "  - $m"; done
    echo "FAIL: $failed assertion(s) failed"
    exit 1
fi
echo "OK"
exit 0
