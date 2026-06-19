#!/usr/bin/env bash
# turbo-plugin SVN concern helpers — source via:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
# Core (universal helpers + UTF-8 locale bootstrap + `set -euo pipefail`) is sourced
# first; this concern lib must NOT weaken those (KTD2a).
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# Validate a branch name for remote-svn worktree mapping (v0.5.0 U7 allowlist).
# Returns 0 if OK, else prints the reason to stderr and returns 1. 'main' is the
# canonical trust anchor and always passes; other casings of 'main' are rejected so
# they cannot impersonate the anchor directory.
assert_valid_remote_branch_name() {
  local branch_name="$1"
  if [[ -z "$branch_name" ]]; then
    echo "Error: invalid branch name: empty." >&2; return 1
  fi
  if [[ "$branch_name" == 'main' ]]; then
    return 0
  fi
  if [[ "$branch_name" == *".."* ]]; then
    echo "Error: invalid branch name '$branch_name': must not contain '..'." >&2; return 1
  fi
  if [[ "$branch_name" == -* ]]; then
    echo "Error: invalid branch name '$branch_name': must not start with '-'." >&2; return 1
  fi
  if [[ "$branch_name" =~ [[:space:].]$ ]]; then
    echo "Error: invalid branch name '$branch_name': must not end with '.' or whitespace." >&2; return 1
  fi
  # Allowlist: letters, digits, '.', '_', '-', '/'. Rejects '\', ':', spaces,
  # control characters, and any other separator.
  if [[ ! "$branch_name" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    echo "Error: invalid branch name '$branch_name': only letters, digits, '.', '_', '-', and '/' are allowed." >&2; return 1
  fi
  # Reserved names (case-insensitive): the dash-form plus each '/'-separated segment.
  local seg lower dash="${branch_name//\//-}"
  local -a segments=("$dash")
  local -a _parts
  IFS='/' read -ra _parts <<< "$branch_name"
  segments+=("${_parts[@]}")
  for seg in "${segments[@]}"; do
    lower="$(printf '%s' "$seg" | tr '[:upper:]' '[:lower:]')"
    case "$lower" in
      main|con|prn|aux|nul|com1|com2|com3|com4|com5|com6|com7|com8|com9|lpt1|lpt2|lpt3|lpt4|lpt5|lpt6|lpt7|lpt8|lpt9)
        echo "Error: invalid branch name '$branch_name': '$seg' is a reserved name." >&2; return 1 ;;
    esac
  done
  return 0
}

# Echoes the existing remote-svn branch that collides with <branch_name> (same dir
# name, different ref), or nothing. Pure: caller passes existing branches as args
# (e.g. from `git branch --list 'remote-svn/*'` with the prefix stripped).
# Args: <branch_name> [existing_branch...]
find_remote_worktree_collision() {
  local branch_name="$1"; shift
  local existing dash="${branch_name//\//-}"
  for existing in "$@"; do
    [[ -z "$existing" ]] && continue
    [[ "$existing" == "$branch_name" ]] && continue
    if [[ "${existing//\//-}" == "$dash" ]]; then
      echo "$existing"
      return 0
    fi
  done
  return 0
}

# Map any branch to its remote-svn ref + worktree dir (v0.5.0 U7 — generalized from
# the old hard-coded main / test-<n>). Mapping:
#   name = remote-svn-<branch with '/' -> '-'>, ref = remote-svn/<branch>
# Args: <branch_name> <worktrees_dir>
# Echoes "<name>|<branch>|<path>" on success; prints error + returns 1 on invalid
# name or MAX_PATH violation.
resolve_remote_worktree() {
  local branch_name="$1"
  local worktrees_dir="$2"

  assert_valid_remote_branch_name "$branch_name" || return 1

  local dash="${branch_name//\//-}"
  local name="remote-svn-${dash}"
  local path="${worktrees_dir}/${name}"

  # MAX_PATH guard — parity with the PS side (Windows is the constrained host).
  # MAX_PATH (260) counts the terminating NUL, so usable length is 259 — reject at >= 260.
  if (( ${#path} >= 260 )); then
    echo "Error: worktree path exceeds the Windows MAX_PATH limit (260): '$path' is ${#path} chars. Shorten the clone path, or enable long-path support (git config core.longpaths true, or the \\\\?\\ prefix)." >&2
    return 1
  fi

  echo "${name}|remote-svn/${branch_name}|${path}"
}

# Percent-decode a string (RFC 3986 %XX). Pure-bash; no external deps.
_svn_percent_decode() {
  local s="$1"
  # Turn + into literal (we don't treat + as space for paths) and decode %XX.
  printf '%b' "${s//%/\\x}"
}

# Normalize an SVN URL for boundary-safe trust comparison:
#   - percent-decode
#   - lowercase scheme + authority (host[:port]); file:// also lowercases the
#     Windows drive letter after the leading slash(es)
#   - trim a single trailing slash
# Echoes the normalized string.
normalize_svn_url() {
  local url="$1"
  url="$(_svn_percent_decode "$url")"
  # Lowercase scheme + authority, preserve path case.
  if [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/]*)(/.*)?$ ]]; then
    local scheme="${BASH_REMATCH[1],,}"
    local authority="${BASH_REMATCH[2],,}"
    local rest="${BASH_REMATCH[3]}"
    url="${scheme}${authority}${rest}"
  elif [[ "$url" =~ ^([A-Za-z][A-Za-z0-9+.-]*:)(.*)$ ]]; then
    url="${BASH_REMATCH[1],,}${BASH_REMATCH[2]}"
  fi
  # file:// drive letter lowercase (file:///C:/... -> file:///c:/...)
  if [[ "$url" =~ ^(file://)(/*)([A-Za-z])(:.*)$ ]]; then
    url="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3],,}${BASH_REMATCH[4]}"
  fi
  # Trim a single trailing slash (keep a lone "/").
  if [[ ${#url} -gt 1 && "$url" == */ ]]; then
    url="${url%/}"
  fi
  printf '%s' "$url"
}

# Assert a caller-supplied SVN URL falls under the trusted repository root.
# Args: <trusted_working_copy> <candidate_url>
# Trust base is `svn info --show-item repos-root-url <wc>` (MUST be repos-root-url,
# not the trunk url) so legitimate sibling branches aren't falsely rejected.
# Fail closed: if repos-root-url can't be obtained, or candidate has `..` traversal,
# or candidate isn't (== base) / (startswith base + '/') after normalization,
# write to stderr and return non-zero. Echoes the normalized base on success.
assert_trusted_svn_url() {
  local trusted_wc="$1"
  local candidate="$2"

  if [[ -z "$candidate" ]]; then
    echo "Error: assert_trusted_svn_url: empty candidate URL." >&2
    return 1
  fi

  # Reject path traversal outright.
  if [[ "$candidate" == *"/../"* || "$candidate" == *"/.." || "$candidate" == "../"* || "$candidate" == *"\\..\\"* ]]; then
    echo "Error: untrusted SVN URL (path traversal '..' not allowed): $candidate" >&2
    return 1
  fi

  # Obtain trust base; fail closed on any error. Capture svn's real exit (don't
  # mask it with `|| true`, which would make rc always 0); guard errexit by testing
  # the command in the `if` condition.
  local base
  if ! base="$(svn info --show-item repos-root-url "$trusted_wc" 2>/dev/null)"; then
    base=""
  fi
  base="$(printf '%s' "$base" | tr -d '\r\n')"
  if [[ -z "$base" ]]; then
    echo "Error: assert_trusted_svn_url: could not determine trusted repos-root-url from '$trusted_wc' (path missing, not a working copy, or SVN unreachable). Refusing to proceed (fail closed). Run /tp-setup to bootstrap remote-svn-main." >&2
    return 1
  fi

  local norm_base norm_cand
  norm_base="$(normalize_svn_url "$base")"
  norm_cand="$(normalize_svn_url "$candidate")"

  # Re-check traversal AFTER percent-decoding (a %2e%2e candidate passes the raw
  # check above but decodes to `..` here).
  if [[ "$norm_cand" == *"/../"* || "$norm_cand" == *"/.." || "$norm_cand" == "../"* ]]; then
    echo "Error: untrusted SVN URL (encoded path traversal '..' not allowed): $candidate" >&2
    return 1
  fi

  # Boundary-safe: equal OR startswith (base + '/').
  if [[ "$norm_cand" == "$norm_base" || "$norm_cand" == "$norm_base"/* ]]; then
    printf '%s' "$norm_base"
    return 0
  fi
  echo "Error: untrusted SVN URL: '$candidate' is not under trusted repository root '$base'. Refusing to proceed." >&2
  return 1
}

# Parse `svn status --xml` for a working copy and emit one "<status_char>\t<relpath>" line per
# changed entry. Args: <working_copy_path>.
#
# Why --xml (not plain `svn status`): plain output prints non-ASCII filenames in the console/ANSI
# codepage (Big5 on zh-TW Windows); re-passing those captured bytes as argv through Git Bash/MSYS
# (which assumes UTF-8) mangles them -> "not under version control". `svn status --xml` always
# emits UTF-8 paths, and using XML also removes the CRLF/column-offset fragility of text parsing.
#
# Contract notes:
#  - Returns NON-ZERO (propagated) when `svn status --xml` itself fails (e.g. SVN server down), so
#    callers never treat an empty result as "no changes" (build/submit-svn-commit.sh rely on this).
#  - Attribute values are XML-entity-decoded (& < > "), so filenames containing those characters
#    round-trip correctly. (A name with a literal newline/tab is unsupported by this line-based
#    protocol and is out of scope.)
#  - Parsing uses `grep -oE` (ERE) + sed, NOT `grep -oP` (PCRE) — PCRE refuses to run in non-UTF-8
#    locales, which is exactly the zh-TW Git Bash default.
svn_status_xml() {
  local wc="$1"
  local raw
  raw="$(cd "$wc" && svn status --xml)" || return 1
  local xml
  xml="$(printf '%s' "$raw" | tr '\n' ' ')"
  local -a _paths _items
  # item="" is unique to <wc-status> in plain `svn status --xml`; <target>/<entry> both carry
  # path=, so anchor on <entry> to skip the <target path="."> node.
  mapfile -t _paths < <(printf '%s' "$xml" | grep -oE '<entry[[:space:]]+path="[^"]*"' | sed 's/^[^"]*"//; s/"$//')
  mapfile -t _items < <(printf '%s' "$xml" | grep -oE 'item="[^"]*"' | sed 's/^[^"]*"//; s/"$//')
  local idx sc p
  for idx in "${!_paths[@]}"; do
    case "${_items[$idx]}" in
      unversioned) sc='?' ;;
      missing)     sc='!' ;;
      modified)    sc='M' ;;
      added)       sc='A' ;;
      deleted)     sc='D' ;;
      *) continue ;;
    esac
    # Entity-decode; &amp; LAST so a literal "&lt;" in a name is not double-decoded. The `\&`
    # escape is required — in bash ${//} replacements an unescaped `&` means "the matched text".
    p="${_paths[$idx]}"
    p="${p//&lt;/<}"
    p="${p//&gt;/>}"
    p="${p//&quot;/\"}"
    p="${p//&amp;/\&}"
    printf '%s\t%s\n' "$sc" "$p"
  done
}

# v0.2.7+ F-U3.9 fix: Removed bash get_project_identity_hash() function. It was dead
# code (no caller in production — all SVN scripts are native bash; all IIS/build scripts
# are ps1-delegate so hash computation always happens on PS side via Get-ProjectIdentityHash).
# The bash version was producing DIFFERENT hashes than PS (due to get_normalized_absolute_path
# using forward slashes vs PS using backslashes in the sha256 input), which would cause
# subtle cross-language inconsistency if any future caller relied on this function. Better
# to remove than to maintain a divergent implementation. Restore + slash-normalize if a
# future bash caller needs project identity hashing.

# Compute IIS Express site name from csproj path and identity hash.
# Args: <csproj_path> <identity_hash>
format_iis_express_site_name() {
  local csproj="$1"
  local hash="$2"
  local stem
  stem="$(basename "$csproj" .csproj)"
  echo "${stem}-${hash}"
}

