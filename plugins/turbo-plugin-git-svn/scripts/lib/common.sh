#!/usr/bin/env bash
# turbo-plugin SVN concern helpers — source via:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
# Core (universal helpers + UTF-8 locale bootstrap + `set -euo pipefail`) is sourced
# first; this concern lib must NOT weaken those (KTD2a).
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# Echo the worktree container directory: <main_worktree>/.turbo-plugin/worktrees.
# git-svn concern (the SVN remote worktree container) -- the SVN scripts call this instead
# of each hardcoding a sibling path. Optional arg $1: a pre-resolved main worktree path;
# if omitted it is computed via get_main_worktree (defined in core.sh, sourced above).
get_worktrees_dir() {
  local main_worktree="${1:-}"
  if [[ -z "$main_worktree" ]]; then
    main_worktree="$(get_main_worktree)" || return 1
  fi
  echo "$main_worktree/.turbo-plugin/worktrees"
}

# Validate a branch name for remote-svn worktree mapping (allowlist).
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

# Map any branch to its remote-svn ref + worktree dir (generalized from
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

# Format `svn log --xml` (read on stdin) into a boxed plain-text report: every
# revision is wrapped by a fixed 50-char '═' double rule (which also separates
# adjacent revisions), and a 49-char '─' single rule fences the header / message
# / 變更 sections so a multi-line commit message never bleeds into them. Layout:
#   ═══…  (50 '═')
#   r<rev> | <author> | <date>
#   ───…  (49 '─')
#   <commit message, verbatim, may be multi-line>
#   ───…  (49 '─')        <- emitted only for a verbose run with >=1 changed path
#   變更:
#   <action>  <path>
#   ═══…  (next revision, or the closing rule after the last)
# then a `# LAST_SHOWN_REV=<oldest rev shown>` pagination trailer -- a MACHINE
# marker the tp-svn-log SKILL reads for paging and does NOT surface to the user.
# Arg $1: "true" to include the 變更 (changed-path) section, else omit it.
# Prints nothing (and no trailer) when the XML has no <logentry> (empty range).
#
# Why a self-contained awk tokenizer, not xmllint: xmllint is typically ABSENT in
# Git Bash on Windows (the primary host), so a former xmllint-preferred path meant
# the code that actually shipped to users was an untested fallback. This single awk
# path runs everywhere, so the tests exercise the real thing.
#
# How it stays correct without a real XML parser: `svn log --xml` escapes every
# literal '<' '>' '&' in text as &lt; &gt; &amp;, so those bytes only ever delimit
# tags -- never appear inside author/msg/path text. With RS="<" awk tokenizes into
# "TAGSPEC>CONTENT" records; a pretty-printed multi-line open tag (svn splits
# attributes across lines) is whitespace-collapsed back to one token, and CONTENT
# is the element's text node (a multi-line <msg> is preserved intact). We decode the
# five predefined XML entities ourselves; &amp; is decoded LAST so a literal "&lt;"
# in text is not double-decoded, and its gsub replacement is written "\\&" because a
# bare '&' in an awk replacement means the whole match (the same trap as the ${//}
# decode in svn_status_xml).
#
# Runs awk under LC_ALL=C so it processes bytes: UTF-8 never encodes '<' '>' '&' '"'
# as a trailing byte of a multibyte char, so ASCII-delimiter matching is safe and
# CJK (and even F-3 mojibake) bytes pass through untouched.
#
# Uses awk (not grep -oE like svn_status_xml): log XML is nested and ordered --
# author/date/msg/paths must associate with their parent <logentry>, and a commit
# may legitimately lack <author>, which a flat per-tag grep+zip would misalign.
svn_log_format_xml() {
  local verbose="${1:-false}"
  LC_ALL=C awk -v verbose="$verbose" '
    function decode(s) {
      gsub(/\r/, "", s)
      gsub(/&lt;/,   "<",    s)
      gsub(/&gt;/,   ">",    s)
      gsub(/&quot;/, "\"",   s)
      gsub(/&apos;/, "\047", s)
      gsub(/&amp;/,  "\\&",  s)
      return s
    }
    BEGIN {
      RS = "<"; in_entry = 0; np = 0; min_rev = ""; entry_num = 0
      bound = ""; fence = ""
      for (i = 0; i < 50; i++) bound = bound "═"     # entry boundary: 50 chars
      for (i = 0; i < 49; i++) fence = fence "─"     # inner section fence: 49 chars
    }
    {
      gt = index($0, ">")
      if (gt == 0) next
      tag = substr($0, 1, gt - 1)
      content = substr($0, gt + 1)
      gsub(/[[:space:]]+/, " ", tag)
      sub(/^ +/, "", tag); sub(/ +$/, "", tag)

      if (tag ~ /^logentry( |$)/) {
        in_entry = 1; author = ""; date = ""; msg = ""; np = 0; rev = ""
        if (match(tag, /revision="[0-9]+"/)) rev = substr(tag, RSTART + 10, RLENGTH - 11)
        next
      }
      if (tag == "/logentry") {
        print bound
        entry_num++
        printf "r%s | %s | %s\n", rev, author, date
        print fence
        printf "%s\n", msg
        if (verbose == "true" && np > 0) {
          print fence
          print "變更:"
          for (k = 1; k <= np; k++) printf "%s  %s\n", pact[k], ptext[k]
        }
        if (rev != "" && (min_rev == "" || rev + 0 < min_rev + 0)) min_rev = rev
        in_entry = 0; next
      }
      if (!in_entry) next
      if (tag == "author") { author = decode(content); next }
      if (tag == "date")   { date   = decode(content); next }
      if (tag == "msg")    { msg    = decode(content); next }
      if (tag == "msg/")   { msg = ""; next }
      if (tag ~ /^path( |$)/) {
        np++
        pact[np] = ""
        if (match(tag, /action="[^"]*"/)) pact[np] = substr(tag, RSTART + 8, RLENGTH - 9)
        ptext[np] = decode(content)
        next
      }
    }
    END {
      if (entry_num > 0) print bound
      if (min_rev != "") printf "# LAST_SHOWN_REV=%s\n", min_rev
    }
  '
}

# Build the LOCKED SVN commit body for a push range. The body is a deterministic, '- '-prefixed
# list of EVERY non-merge commit subject (oldest first), one per line — git itself applies the
# '- ' prefix and the ordering, so the same commit set always yields byte-identical output.
#
# Merge commits are excluded by parent count (--no-merges), NOT by a 'Merge ' subject-prefix
# match (KTD6/R11). There is NO commit-type filtering: docs/test/chore subjects all go in (R11).
# Subjects are emitted verbatim via git's own --pretty formatter, so backticks, '$', quotes, and
# a leading '- ' in a subject survive without any shell interpolation.
#
# Args: <repo_dir> <range>   (range e.g. "remote-svn/main..feat/x")
# Prints the body to stdout (empty output when the range has no non-merge commit). Returns the
# git exit code, so a genuine git failure propagates under `set -e`.
get_svn_push_body() {
  local repo_dir="$1" range="$2"
  git -C "$repo_dir" log "$range" --no-merges --reverse --pretty=format:'- %s'
}

# ─── Per-revision SVN replay primitives (U1) ─────────────────────────────────
# Shared building blocks for the per-revision pull replay (F1/KTD1-KTD3/KTD6). Three
# helpers, all pure git + XML text (NO `svn` invocation here — the caller pipes svn output
# in), so they run and test without svn. The PowerShell peers live in Common.ps1.

# Enumerate revisions from `svn log --xml` (read on stdin) as machine-readable records,
# one per revision in ASCENDING revision order. Each record is:
#     <rev><US><author><US><date><US><message><NUL>
# where <US> is 0x1F (unit separator) and <NUL> is 0x00. The message is emitted RAW
# (XML-entity-decoded, may span multiple lines / contain CJK); svn escapes every literal
# '<' '>' '&' in text, so the message can contain neither '<' nor US nor NUL — those
# delimiters are collision-free. Consume with:
#     while IFS=$'\037' read -r -d '' rev author date msg; do ...; done \
#         < <(svn log --xml -r "$lo:$hi" "$url" | svn_enumerate_revisions)
#
# Reuses the SAME RS="<" awk tokenizer + five-entity decode as svn_log_format_xml (see the
# long rationale there): under LC_ALL=C awk processes bytes, so ASCII-delimiter matching is
# safe and CJK bytes pass through untouched. `svn log -r lo:hi` already emits ascending, but
# we `sort -z` numerically so callers never depend on svn's ordering.
svn_enumerate_revisions() {
  LC_ALL=C awk '
    function decode(s) {
      gsub(/\r/, "", s)
      gsub(/&lt;/,   "<",    s)
      gsub(/&gt;/,   ">",    s)
      gsub(/&quot;/, "\"",   s)
      gsub(/&apos;/, "\047", s)
      gsub(/&amp;/,  "\\&",  s)
      return s
    }
    BEGIN { RS = "<"; in_entry = 0 }
    {
      gt = index($0, ">")
      if (gt == 0) next
      tag = substr($0, 1, gt - 1)
      content = substr($0, gt + 1)
      gsub(/[[:space:]]+/, " ", tag)
      sub(/^ +/, "", tag); sub(/ +$/, "", tag)

      if (tag ~ /^logentry( |$)/) {
        in_entry = 1; author = ""; date = ""; msg = ""; rev = ""
        if (match(tag, /revision="[0-9]+"/)) rev = substr(tag, RSTART + 10, RLENGTH - 11)
        next
      }
      if (tag == "/logentry") {
        printf "%s\037%s\037%s\037%s\000", rev, author, date, msg
        in_entry = 0; next
      }
      if (!in_entry) next
      if (tag == "author") { author = decode(content); next }
      if (tag == "date")   { date   = decode(content); next }
      if (tag == "msg")    { msg    = decode(content); next }
      if (tag == "msg/")   { msg = ""; next }
    }
  ' | sort -z -t $'\037' -k1,1n
}

# Replay one SVN revision as a git commit on the CURRENT HEAD of <repo_dir> (in production the
# remote-svn/<branch> worktree, already `svn update`d to this revision's tree).
#   - Idempotent (KTD4): if HEAD already carries a commit whose message has the exact
#     `svn-revision: <rev>` trailer line, print "SKIP:idempotent" and make NO commit — an
#     interrupted-then-rerun pull cannot mint a duplicate.
#   - Empty delta (KTD4): after `git add -A`, if the index is unchanged (tree identical to the
#     parent), print "SKIP:empty" and make NO commit (never a no-op commit).
#   - Otherwise commit and print "COMMIT:<sha>". Author = "<svn-username> <>" (raw username in
#     the name slot, empty <> email — git --author needs a `Name <email>` shape; KTD2). SVN date
#     becomes the git AUTHOR-date (committer-date stays the replay moment; KTD6). Message = the
#     SVN message + a blank line + the `svn-revision: <rev>` trailer (KTD3).
# Args: <repo_dir> <rev> <author> <date> <message>
# commit.cleanup is pinned to 'whitespace' so a message line starting with '#' survives (the
# default 'strip' would delete commentary) while the trailer paragraph is still recognized.
svn_replay_commit() {
  local repo_dir="$1" rev="$2" author="$3" date="$4" message="$5"

  # Idempotency: a commit with this revision's trailer already on HEAD → skip (no dup).
  local pat='^svn-revision: '"${rev}"'$'
  if [[ -n "$(git -C "$repo_dir" log HEAD -n 1 -E --grep="$pat" --format='%H' 2>/dev/null)" ]]; then
    echo "SKIP:idempotent"
    return 0
  fi

  git -C "$repo_dir" add -A

  # Empty index (tree identical to parent) → skip, never mint a no-op commit. The command sits
  # in the `if` condition, so `set -e` does not trip on its non-zero (=has-changes) exit.
  if git -C "$repo_dir" diff --cached --quiet; then
    echo "SKIP:empty"
    return 0
  fi

  # Normalize the SVN date to a git-friendly ISO form (drop fractional seconds: git's date
  # parser dislikes the .000000Z microseconds svn emits).
  local date_git
  date_git="$(printf '%s' "$date" | sed -E 's/\.[0-9]+Z$/Z/')"

  local -a author_arg=()
  if [[ -n "$author" ]]; then
    author_arg=(--author="$author <>")
  fi

  git -C "$repo_dir" -c commit.gpgsign=false commit --cleanup=whitespace \
    "${author_arg[@]}" --date="$date_git" \
    -m "$message" -m "svn-revision: $rev" >/dev/null

  local sha
  sha="$(git -C "$repo_dir" rev-parse HEAD)"
  echo "COMMIT:$sha"
}

# ── Shared per-revision replay loop (U3 pull + U7 first-import bootstrap) ──────
# One shared body so the steady-state pull (Sync-FromSvn) and the first-import bootstrap
# (Initialize-GitSvnBridge) mint IDENTICAL commit shapes (author / date / trailer). Both callers
# own their own >5 granularity GATE (the residue-free "needs choice" exit differs per caller); this
# code only MATERIALISES an already-chosen mode against a bridge worktree positioned at the resume
# baseline.

# Replay ONE svn revision as a git commit: svn update -r R in the bridge worktree, assert the WC is
# uniformly at R (KTD4 sparse guard -- an empty delta must mean "identical tree", never a partial
# update), then hand off to svn_replay_commit (empty-delta + idempotent skips live there).
# Args: <remote_path> <rev> <author> <date> <message>
svn_replay_one_revision() {
  local remote_path="$1" rev="$2" author="$3" date="$4" message="$5" wc
  ( cd "$remote_path" && svn update -r "$rev" ) || { echo "Error: svn update -r $rev failed" >&2; return 1; }
  wc="$(svn info --show-item revision "$remote_path" | tr -d '[:space:]')"
  if [[ "$wc" != "$rev" ]]; then
    echo "Error: remote worktree not uniformly at r$rev (got r$wc); refusing per-revision replay." >&2
    return 1
  fi
  svn_replay_commit "$remote_path" "$rev" "$author" "$date" "$message" >/dev/null || return 1
}

# Squash the current SVN HEAD-of-range into ONE boundary commit on the bridge worktree's HEAD.
# Subject stays `sync: svn r<rev>` (steady-state shape); a second -m appends the `svn-revision: <rev>`
# trailer so floor-lookup (U5) treats the squashed range as a single boundary. Skips when
# `git add -A` leaves the index unchanged (empty delta).
# Args: <remote_path> <rev>
svn_boundary_commit() {
  local remote_path="$1" rev="$2"
  git -C "$remote_path" add -A
  if git -C "$remote_path" diff --cached --quiet; then
    return 0
  fi
  git -C "$remote_path" -c commit.gpgsign=false commit -m "sync: svn r$rev" -m "svn-revision: $rev"
}

# Enumerate r(cur+1)..head_rev on the bridge worktree, then materialise commits per <mode>:
#   per-revision : one replay commit per revision (empty deltas skipped)
#   squash       : one boundary commit at head_rev
#   range        : per-revision inside <lo>:<hi> (from <range>), squash the leading + trailing rest
# Re-enumerates from the WC so the caller only has to hand over the decided mode (no array passing).
# Args: <remote_path> <remote_name> <cur> <head_rev> <mode> [<range>]
svn_replay_dispatch() {
  local remote_path="$1" remote_name="$2" cur="$3" head_rev="$4" mode="$5" range="${6:-}"

  # KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
  # uniform per-revision tree; assert once before touching anything.
  local depth
  depth="$(svn info --show-item depth "$remote_path" | tr -d '[:space:]')"
  if [[ "$depth" != "infinity" ]]; then
    echo "Error: remote worktree depth is '$depth', not 'infinity'; per-revision replay needs a full checkout." >&2
    return 1
  fi

  local -a REC_REV=() REC_AUTHOR=() REC_DATE=() REC_MSG=()
  if (( cur < head_rev )); then
    local log_xml
    log_xml="$(svn log --xml -r "$((cur + 1)):$head_rev" "$remote_path")" \
      || { echo "Error: svn log failed for r$((cur + 1)):r$head_rev" >&2; return 1; }
    while IFS=$'\037' read -r -d '' _rev _author _date _msg; do
      REC_REV+=("$_rev"); REC_AUTHOR+=("$_author"); REC_DATE+=("$_date"); REC_MSG+=("$_msg")
    done < <(printf '%s' "$log_xml" | svn_enumerate_revisions)
  fi

  local i r lo hi
  if [[ "$mode" == "per-revision" ]]; then
    echo "Replaying ${#REC_REV[@]} SVN revision(s) r$((cur + 1))..r$head_rev into $remote_name..."
    for i in "${!REC_REV[@]}"; do
      svn_replay_one_revision "$remote_path" "${REC_REV[$i]}" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}" || return 1
    done
  elif [[ "$mode" == "squash" ]]; then
    echo "Squashing SVN r$((cur + 1))..r$head_rev into one commit in $remote_name..."
    ( cd "$remote_path" && svn update ) || { echo "Error: svn update failed" >&2; return 1; }
    svn_boundary_commit "$remote_path" "$head_rev" || return 1
  elif [[ "$mode" == "range" ]]; then
    if [[ ! "$range" =~ ^[0-9]+:[0-9]+$ ]]; then
      echo "Error: granularity 'range' requires --range <lo>:<hi> (got '$range')" >&2; return 1
    fi
    lo="${range%%:*}"; hi="${range##*:}"
    if (( lo < cur + 1 )); then lo=$((cur + 1)); fi
    if (( hi > head_rev )); then hi=$head_rev; fi
    if (( lo > hi )); then
      echo "Error: granularity range does not overlap the pending r$((cur + 1)):r$head_rev." >&2; return 1
    fi
    echo "Replaying r$lo..r$hi per-revision, squashing the rest, into $remote_name..."
    # Leading squash: r(cur+1)..r(lo-1) -> one boundary commit at r(lo-1). Skipped when lo==cur+1.
    if (( lo - 1 >= cur + 1 )); then
      ( cd "$remote_path" && svn update -r "$((lo - 1))" ) || { echo "Error: svn update -r $((lo - 1)) failed" >&2; return 1; }
      svn_boundary_commit "$remote_path" "$((lo - 1))" || return 1
    fi
    # Per-revision inside [lo,hi].
    for i in "${!REC_REV[@]}"; do
      r="${REC_REV[$i]}"
      if (( r >= lo && r <= hi )); then
        svn_replay_one_revision "$remote_path" "$r" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}" || return 1
      fi
    done
    # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=head_rev.
    if (( hi < head_rev )); then
      ( cd "$remote_path" && svn update ) || { echo "Error: svn update failed" >&2; return 1; }
      svn_boundary_commit "$remote_path" "$head_rev" || return 1
    fi
  else
    echo "Error: unknown granularity '$mode' (expected per-revision | squash | range)" >&2; return 1
  fi
}

# Floor revision→commit lookup (KTD3 floor semantics, R8/R14). Over `main` (STRICTLY main,
# never HEAD), return the SHA of the newest commit whose `svn-revision:` trailer value is the
# GREATEST value <= <target_rev>. SVN revisions are repo-global/sparse, so an arbitrary target
# (e.g. a branch copyfrom-rev) usually has no exact match — floor, not exact.
#   - Prints exactly ONE SHA on success.
#   - Prints NOTHING (returns 0) when no commit carries a value <= target (the genuine
#     "predates earliest" case → checkout's R10 path).
#   - FAILS LOUD (stderr + return 1) when that greatest value <= target is carried by MORE
#     THAN ONE commit — the ambiguous multi-match that reproduced the `not a valid object name`
#     failure (6962db7 / 6f73114). Refuses to guess a base.
# Args: <repo_dir> <target_rev>
svn_floor_commit_for_rev() {
  local repo_dir="$1" target="$2"
  local best_rev="" best_sha="" best_count=0
  local record sha val
  # `git log main -z`: NUL-separated commits, each formatted "<sha>\n<raw-body>". Parse the
  # trailer straight out of the body (version-independent; also robust to the %(trailers)
  # newline quirks). NEVER pass HEAD — the scope is strictly main.
  while IFS= read -r -d '' record || [[ -n "$record" ]]; do
    [[ -z "$record" ]] && continue
    sha="${record%%$'\n'*}"
    val="$(printf '%s\n' "$record" | grep -oE '^svn-revision: [0-9]+' | tail -n1 | grep -oE '[0-9]+$' || true)"
    [[ -z "$val" ]] && continue
    if (( val <= target )); then
      if [[ -z "$best_rev" ]] || (( val > best_rev )); then
        best_rev="$val"; best_sha="$sha"; best_count=1
      elif (( val == best_rev )); then
        best_count=$(( best_count + 1 )); best_sha="$sha"
      fi
    fi
  done < <(git -C "$repo_dir" log main -z --format='%H%n%B' 2>/dev/null)

  if [[ -z "$best_rev" ]]; then
    return 0
  fi
  if (( best_count > 1 )); then
    echo "Error: svn_floor_commit_for_rev: revision r$best_rev is carried by $best_count commits on 'main' (ambiguous floor for r$target). Refusing to return a non-unique base." >&2
    return 1
  fi
  echo "$best_sha"
}

# Highest replayed revision on `main` (KTD4 resume point; the checkout grading bound `cur`, U5).
# Scans the SAME `svn-revision:` trailer as svn_floor_commit_for_rev, STRICTLY on `main` (never
# HEAD). Echoes the GREATEST replayed revision value, or 0 when `main` carries no replayed revision.
# Used to grade a target R against cur BEFORE the floor lookup: R > cur means the aligned revision
# has not been replayed yet (pull first) rather than "predates earliest".
# Args: <repo_dir>
svn_highest_replayed_rev() {
  local repo_dir="$1" best=0 record val
  while IFS= read -r -d '' record || [[ -n "$record" ]]; do
    [[ -z "$record" ]] && continue
    val="$(printf '%s\n' "$record" | grep -oE '^svn-revision: [0-9]+' | tail -n1 | grep -oE '[0-9]+$' || true)"
    [[ -z "$val" ]] && continue
    if (( val > best )); then best="$val"; fi
  done < <(git -C "$repo_dir" log main -z --format='%H%n%B' 2>/dev/null)
  echo "$best"
}

# --- tp:* branch-metadata property helpers (U2) ------------------------------
# Read/write the two branch-metadata SVN properties the bridge cannot otherwise share
# (KTD5):  tp:branch-name (original git branch name, slashes preserved) and
# tp:last-aligned-rev (the trunk revision the branch is aligned to). Plus a dedicated
# reader for the trunk copyfrom-rev a branch was `svn copy`-ed from. The PowerShell peers
# live in Common.ps1. Property + commit-message strings are ASCII on purpose.

# Extract the trunk copyfrom-rev of a branch from an `svn log -v --stop-on-copy --xml`
# document read on stdin. Under --stop-on-copy the OLDEST logentry (smallest revision) IS
# the copy, whose branch-root <path> carries copyfrom-rev="N" (the TRUNK revision the branch
# was copied from) -- NOT the branch's own creation revision (the logentry's revision=, which
# never touched trunk and carries no svn-revision: trailer). Prints just the integer, or
# nothing when the XML has no copyfrom path (not a copied branch).
#
# Reuses the RS="<" awk tokenizer of svn_log_format_xml / svn_enumerate_revisions: svn escapes
# every literal '<' '>' '&' in text, so those bytes only delimit tags. Under LC_ALL=C awk works
# on bytes (safe for CJK). The copyfrom-rev lives as an attribute inside the pretty-printed
# multi-line <path ...> open tag; whitespace-collapsing the tag lets one match find it, exactly
# like action="[^"]*" in svn_log_format_xml. Offsets verified against the shipped precedents:
#   revision="       is 10 chars -> RSTART+10 / RLENGTH-11   (svn_log_format_xml line 313)
#   copyfrom-rev="   is 14 chars -> RSTART+14 / RLENGTH-15
# The closing `}` sits at column 0 so the test harness sed-extract captures the whole function.
svn_copyfrom_rev_xml() {
  LC_ALL=C awk '
    BEGIN { RS = "<"; min_rev = ""; out = "" }
    {
      gt = index($0, ">")
      if (gt == 0) next
      tag = substr($0, 1, gt - 1)
      gsub(/[[:space:]]+/, " ", tag)
      sub(/^ +/, "", tag); sub(/ +$/, "", tag)

      if (tag ~ /^logentry( |$)/) {
        cur_rev = ""
        if (match(tag, /revision="[0-9]+"/)) cur_rev = substr(tag, RSTART + 10, RLENGTH - 11)
        next
      }
      if (tag ~ /^path( |$)/) {
        if (match(tag, /copyfrom-rev="[0-9]+"/)) {
          cfr = substr(tag, RSTART + 14, RLENGTH - 15)
          # Keep the copyfrom-rev of the SMALLEST-revision entry that carries one -- under
          # --stop-on-copy that is the branch-root copy, even if later within-branch copies exist.
          if (min_rev == "" || cur_rev + 0 < min_rev + 0) { min_rev = cur_rev; out = cfr }
        }
        next
      }
    }
    END { if (out != "") print out }
  '
}

# Thin wrapper: run svn for a branch URL, pipe its XML into the pure parser. Returns non-zero
# (propagated) when the svn log itself fails, so callers never treat empty as "not a copy".
# Args: <branch_url>
get_svn_branch_copyfrom_rev() {
  local branch_url="$1" xml
  xml="$(svn log -v --stop-on-copy --xml "$branch_url")" || return 1
  printf '%s' "$xml" | svn_copyfrom_rev_xml
}

# Getter: echo the value of tp:<name> on <target> (a branch URL or a working-copy path), or
# nothing when the property is absent. `svn propget` on a missing custom property exits NON-ZERO
# with empty output (observed rc=1 on 1.14), so we tolerate the exit code and never treat absence
# as an error. Command substitution already strips trailing newlines; the ${val%...} is a belt.
# Args: <name> <target>   (name in {branch-name, last-aligned-rev})
get_tp_branch_prop() {
  local name="$1" target="$2" val
  val="$(svn propget "tp:$name" "$target" 2>/dev/null || true)"
  printf '%s' "${val%$'\n'}"
}

# Setter: in the branch working copy set tp:<name>=<value>, then a SCOPED property commit and an
# `svn update`. `--depth empty` + the explicit '.' target is load-bearing -- it is the fb42a63 fix
# that stops `svn checkout --force` overlay drift being swept into the commit; the trailing
# `svn update` clears the mixed-revision lag so the next build-svn-commit does not falsely demand a
# pull. Mirrors the svn:ignore=.git bootstrap shape in new-remote-bridge.sh. Fixed ASCII message.
# Args: <name> <value> <working_copy>
set_tp_branch_prop() {
  local name="$1" value="$2" wc="$3"
  (
    cd "$wc" || exit 1
    svn propset "tp:$name" "$value" '.' || exit 1
    svn commit --depth empty -m "set tp:$name (turbo-plugin metadata)" '.' || exit 1
    svn update >/dev/null || exit 1
  )
}

