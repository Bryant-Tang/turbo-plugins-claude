#!/usr/bin/env bash
# turbo-plugin SVN concern helpers — source via:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"
# Core (universal helpers + UTF-8 locale bootstrap + `set -euo pipefail`) is sourced
# first; this concern lib must NOT weaken those (KTD2a).
source "$(dirname "${BASH_SOURCE[0]}")/core.sh"

# --- svn must NEVER prompt (single choke point) -------------------------------
# These scripts are driven by an agent / CI with no usable stdin. A prompting `svn`
# (conflict resolution, credential request, cert acceptance) does not fail -- it blocks
# FOREVER, which reads as "the script hung" and cannot be recovered or rolled back.
# Real incident: a bootstrap replay hit a tree conflict on `.gitignore` and sat in svn's
# interactive conflict prompt indefinitely.
#
# Shadowing `svn` here (rather than adding the flag at ~19 call sites) makes the invariant
# global and future-proof: every svn invocation in every script that sources this lib gets
# it, including ones added later. `command svn` bypasses this function, so no recursion.
# With --non-interactive svn returns a non-zero exit instead of prompting, so the existing
# `|| exit 1` / `$LASTEXITCODE` guards and rollback traps do their job.
# NOTE: credentials must therefore already be cached (or supplied in the URL) -- an
# uncached password now fails loudly rather than waiting on a prompt nobody can answer.
#
# Lives in the SVN CONCERN lib, not in universal core.sh: core.sh is the file copied
# byte-identical into every plugin (enforced by tools/verify-core-identical.sh), and an svn
# shim has no business in a plugin that never touches svn. Every script here that can invoke
# svn sources THIS file, so the choke point is unchanged. Same reasoning as the earlier move
# of get_worktrees_dir out of universal core.
# --- svn must be new enough to have --show-item (single choke point) -----------
# `svn info --show-item` arrived in Subversion 1.9 and is used across build-svn-commit,
# checkout-svn-branch, initialize-git-svn-bridge, new-remote-bridge and this lib. On an older
# client every one of those dies with `svn: invalid option: --show-item` -- a message that says
# nothing about the actual problem, leaving the user to work out whether their environment is
# broken or the plugin is. That diagnosis time is exactly what this gate exists to remove.
#
# Not hypothetical: chocolatey's `svn` package is win32svn, last released 2015 and pinned at
# 1.8.15. It is also the likely shape of the problem in the field -- this plugin exists because a
# team is stuck on SVN, and those environments are the most likely to be running an old client.
#
# Checked ONCE per process from inside the shim, so every caller is covered without each script
# having to remember a pre-check, and the cost is one `svn --version` per run.
TP_SVN_MIN_VERSION="1.9"
_tp_svn_version_checked=""

assert_svn_version() {
  local raw major minor
  raw="$(command svn --version --quiet 2>/dev/null)" || raw=""
  raw="$(printf '%s' "$raw" | tr -d '[:space:]')"

  if [[ -z "$raw" ]]; then
    echo "Error: could not determine the Subversion version (ran: svn --version --quiet). Subversion ${TP_SVN_MIN_VERSION} or newer is required." >&2
    return 1
  fi
  # grep -oE, never grep -P: PCRE mode refuses to run under the non-UTF-8 locales common on
  # zh-TW Git Bash installs.
  if [[ ! "$raw" =~ ^([0-9]+)\.([0-9]+) ]]; then
    echo "Error: could not parse the Subversion version from '$raw'. Subversion ${TP_SVN_MIN_VERSION} or newer is required." >&2
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"

  if (( major < 1 || ( major == 1 && minor < 9 ) )); then
    echo "Error: Subversion ${TP_SVN_MIN_VERSION} or newer is required, but this client is ${raw}." >&2
    echo "  Reason: turbo-plugin-git-svn uses 'svn info --show-item', which does not exist before 1.9;" >&2
    echo "  on this client it fails with \"svn: invalid option: --show-item\"." >&2
    echo "  Fix: install a current client -- SlikSVN or TortoiseSVN (with command line tools) on Windows." >&2
    echo "  Note: the chocolatey 'svn' package is win32svn and is pinned at 1.8.15, so it will not do." >&2
    return 1
  fi
}

# Second reason the flag is load-bearing, on the PowerShell side (issue #137): it is also what
# keeps the `& svn ... 2>$null` call sites safe under $ErrorActionPreference = 'Stop'. #128 fixed
# the git side, where `warning: detected dubious ownership` writes to stderr on a HEALTHY, exit-0
# call, and the `2>` redirection then turns that into a TERMINATING error. Measured for svn: the
# mechanism applies identically, but svn's only "stderr while otherwise healthy" behaviour is its
# INTERACTIVE PROMPTS -- which this flag removes. The same tree conflict that prompts exits 0 with
# an empty stderr once the flag is present. Full write-up next to the PowerShell twin in
# lib/Common.ps1; keep the two shims in step.
svn() {
  if [[ -z "$_tp_svn_version_checked" ]]; then
    assert_svn_version || return 1
    # Set only AFTER a passing check, so a failure is re-reported on the next call instead of
    # being silently swallowed by an "already checked" flag.
    _tp_svn_version_checked=1
  fi
  command svn --non-interactive "$@"
}

# Granularity gate threshold (KTD7/R2/R3): a pull or first import replays per-revision SILENTLY at
# or below this many new revisions; ABOVE it, the granularity choice is offered. One shared
# definition for the pull loop (sync-from-svn.sh) and the first-import bootstrap
# (initialize-git-svn-bridge.sh) so the two never drift. `:=` leaves an override in place.
: "${TP_GRANULARITY_THRESHOLD:=5}"

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

# Which worktree, if any, has branch $1 checked out. Echoes the normalized absolute path of
# that worktree, or nothing. $2 is the output of `git worktree list --porcelain`.
#
# TWO SILENT-FAILURE DIRECTIONS THIS FUNCTION EXISTS TO CLOSE. Both of them produce "no
# worktree has this branch", which is byte-for-byte the healthy answer -- so neither one is
# visible at the call site:
#
#   1. PATH SPELLING. git reports Windows paths as `C:/...` while other sources hand back
#      `/c/...`, and comparing those two spellings is false every single time without saying
#      so. Hence get_normalized_absolute_path before the path is ever returned for comparison.
#   2. AN UNCHECKED WORKTREE LIST. The listing is taken as an argument rather than read here,
#      so each caller keeps the read-once-and-check-the-exit-code shape its own error reporting
#      needs (a TP_TOKEN:ERROR line in request-merge.sh, a plain stderr message in
#      merge-main-into-branches.sh). A healthy `--porcelain` listing always contains at least
#      the main worktree, so an empty $2 means the caller handed over a failed or unchecked
#      read -- refuse loudly rather than answer "nobody has it".
#
# Why here and not in core.sh: core.sh is copied byte-identical into every plugin (enforced by
# tools/verify-core-identical.sh), and no other plugin parses `git worktree list` at all. Same
# reasoning as the earlier move of get_worktrees_dir out of universal core.
worktree_for_branch() {
  local want="$1" wt_list="${2:-}" line cur=''
  if [[ -z "$wt_list" ]]; then
    echo "Error: worktree_for_branch: empty worktree list (a checked 'git worktree list --porcelain' always lists at least the main worktree)." >&2
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      'worktree '*) cur="${line#worktree }" ;;
      "branch refs/heads/$want")
        [[ -n "$cur" ]] && get_normalized_absolute_path "$cur"
        return 0
        ;;
    esac
  done <<< "$wt_list"
  return 0
}

# Guarantee `.svn/` is excluded from git for THIS repository, independent of any .gitignore.
#
# Every bridge worktree is simultaneously a git worktree and an svn working copy, and every script
# that runs `git add -A` inside one depends on this. It is not a tidiness measure: with autocrlf on,
# `git add -A` pulls the binary files under `.svn/pristine/` through the CRLF filter, and the next
# `svn commit` then fails with "Working copy text base is corrupt" -- the working copy is destroyed,
# not merely dirty (reproduced 2026-08-03).
#
# Written to info/exclude rather than a .gitignore so it holds whatever content SVN carries, and to
# the COMMON git dir because git does not read a linked worktree's own info/exclude. Idempotent.
# $1: main worktree path.
ensure_svn_git_excluded() {
  local main_worktree="$1" common_dir
  common_dir="$(git -C "$main_worktree" rev-parse --git-common-dir)" || return 1
  case "$common_dir" in
    /*|[A-Za-z]:[/\\]*) : ;;
    *) common_dir="$main_worktree/$common_dir" ;;
  esac
  mkdir -p "$common_dir/info"
  if ! grep -qxF '.svn/' "$common_dir/info/exclude" 2>/dev/null; then
    printf '%s\n' '.svn/' >> "$common_dir/info/exclude"
  fi
}

# Let the bridge follow the platform, exactly like the main checkout and any ordinary worktree.
#
# THIS REPLACES A PIN THAT USED TO DO THE OPPOSITE, and the reversal is deliberate. Through 0.7.x
# the bridge was pinned to LF because SVN, with no svn:eol-style anywhere, stored whatever bytes it
# was handed: a bridge following the platform would have written CRLF into a repository whose other
# files were LF, invisibly, since afterwards git reports clean (it normalises on read) and svn
# reports clean (it committed exactly what was on disk). Issues #164 and #167 are that story.
#
# Now that the push path puts svn:eol-style=native on the text files it commits, the normalising
# happens on SVN's side -- so SVN holds LF and every working copy holds its own platform's endings,
# which is precisely the arrangement git already has with GitHub. Once SVN does that job, a bridge
# that behaves differently from every other working copy the user has is just a surprise with no
# remaining purpose.
#
# It UNSETS rather than merely not setting: a bridge created under 0.7.x still carries the old pin
# in its per-worktree config, and leaving it there would keep those bridges silently on the old
# behaviour forever while new ones moved on. Scoped to the bridge, so the user's own worktrees are
# untouched either way. Idempotent.
#
# $1: main worktree path. $2: bridge worktree path.
ensure_bridge_eol_platform_native() {
  local main_worktree="$1" bridge="$2"
  # Nothing to undo unless per-worktree config was ever enabled -- and if it was not, the pin
  # cannot exist. Checked rather than enabled, so a repository that never carried the pin is not
  # given a repo-wide extension it has no use for.
  local ext
  ext="$(git -C "$main_worktree" config --get extensions.worktreeConfig 2>/dev/null || true)"
  [ "$ext" = 'true' ] || return 0
  # `--unset` on a key that is not set exits 5. That is the ordinary case for a bridge created
  # after this change, so it must not be read as a failure.
  git -C "$bridge" config --worktree --unset core.autocrlf >/dev/null 2>&1 || true
  git -C "$bridge" config --worktree --unset core.eol >/dev/null 2>&1 || true
  return 0
}

# Which working-copy paths may carry svn:eol-style, decided by git's own EOL classification.
#
# `svn:eol-style=native` is what makes SVN behave the way GitHub does: the repository stores LF,
# and every working copy gets its platform's endings. Setting it on the wrong file is not a
# cosmetic mistake, so this picks the candidates rather than letting a caller guess:
#
#   - a BINARY file must never carry it -- svn would translate bytes that are not line endings
#   - a file with MIXED endings must never carry it -- svn refuses to commit such a file once
#     eol-style is set (E135000). A commit is atomic, so one overlooked mixed file fails the
#     whole batch; on a 20k-file tree that has to be known up front, not discovered halfway.
#
# `git ls-files --eol` answers both for the ENTIRE tree in one process, which is why it is used
# instead of a per-file content probe: on a tree this size, two spawned processes per file is the
# difference between seconds and tens of minutes on Windows. Its output is
# `i/<index> w/<worktree> attr/<attrs><TAB><path>`, where the eol values are `lf`, `crlf`,
# `mixed`, `none` (no line endings at all) and `-text` (binary by git's heuristic).
#
# The WORKING-COPY column is the one that decides: svn commits the bytes on disk, so that is what
# it will accept or reject. `none` is included -- a file with no line endings has nothing to
# translate, and excluding it would leave a permanent hole in the tree's coverage.
#
# $1: worktree path. Echoes `<bucket><TAB><path>` per tracked file, where bucket is one of
# `candidate`, `binary` or `mixed`. Non-zero only if git itself fails.
#
# The buckets are reported rather than silently dropped because the migration has to TELL the user
# which files it is leaving behind: a mixed-ending file is excluded permanently, and "we quietly
# skipped 30 files" is exactly the kind of thing that is discovered months later.
classify_svn_eol_paths() {
  local worktree="$1"
  # core.quotePath=false, as every other path-printing git call in this plugin does. With git's
  # default, a non-ASCII path comes back C-quoted and octal-escaped -- `"\346\226\207.txt"` as
  # LITERAL ASCII, not the filename. Nothing errors: that string flows on to `svn propset` as a
  # path that does not exist. On a plugin whose whole point is SVN on Windows with CJK filenames,
  # that is the common case, not an edge one.
  git -C "$worktree" -c core.quotePath=false ls-files --eol | awk -F'\t' '
    {
      # Field 1 is the fixed-width status block; pull the w/ value out of it.
      if (match($1, /w\/[^ ]+/)) {
        eol = substr($1, RSTART + 2, RLENGTH - 2)
        bucket = ""
        if (eol == "lf" || eol == "crlf" || eol == "none") { bucket = "candidate" }
        else if (eol == "-text") { bucket = "binary" }
        else if (eol == "mixed") { bucket = "mixed" }
        if (bucket != "") {
          # Everything after the first tab is the path -- paths may contain spaces.
          sub(/^[^\t]*\t/, "")
          print bucket "\t" $0
        }
      }
    }'
}

# The candidates alone, one repo-relative path per line. A thin filter over the classifier above
# so the rule for what may carry the property lives in exactly one place.
# $1: worktree path.
list_svn_eol_candidates() {
  classify_svn_eol_paths "$1" | awk -F'\t' '$1 == "candidate" { sub(/^[^\t]*\t/, ""); print }'
}

# Put svn:eol-style=native on the text files in a changeset that do not already carry it.
#
# This is what lets the bridge stop being pinned to LF. SVN normalises a file's line endings to LF
# when it stores it, but ONLY for files carrying svn:eol-style; without the property it stores the
# working-copy bytes verbatim. So a bridge that follows the platform -- CRLF on Windows, which is
# the whole point of the model -- would push CRLF into SVN for any file that has no property yet.
# Setting it here, BEFORE the commit, means svn does the normalising for us at commit time.
#
# Doing it per changeset rather than per tree is what makes a "have we migrated yet?" flag
# unnecessary: whatever this push touches is correct afterwards regardless of what the rest of the
# tree looks like, so an unmigrated repository degrades file by file instead of all at once.
#
# Setting a property to the value it already has is not a change as far as svn is concerned, so
# this is idempotent and adds nothing to the commit for files that are already correct.
#
# $1: bridge worktree path. Remaining args: changeset paths, relative to that worktree.
# Echoes how many files it set the property on. Non-zero on svn/git failure.
apply_svn_eol_style() {
  local bridge="$1"; shift
  [ "$#" -gt 0 ] || { echo 0; return 0; }

  local cand chg both rc=0
  cand="$(mktemp)"; chg="$(mktemp)"; both="$(mktemp)"

  # Both sides are normalised to forward slashes before they meet. svn reports Windows paths with
  # backslashes while git always reports forward ones, and a separator mismatch here would not
  # error -- every path would simply fail to match and the whole step would do nothing, silently.
  if ! list_svn_eol_candidates "$bridge" | tr '\\' '/' | LC_ALL=C sort -u > "$cand"; then
    rm -f "$cand" "$chg" "$both"; return 1
  fi
  printf '%s\n' "$@" | tr '\\' '/' | LC_ALL=C sort -u > "$chg"

  # LC_ALL=C on both sorts and on comm: comm silently produces garbage if its inputs were ordered
  # under a different collation than the one it compares with.
  LC_ALL=C comm -12 "$cand" "$chg" > "$both"

  local -a targets=()
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    # svn_target: a filename containing '@' is legal but makes svn read the tail as a peg revision.
    targets+=("$(svn_target "$p")")
  done < "$both"

  if [ "${#targets[@]}" -gt 0 ]; then
    local tf; tf="$(mktemp)"
    # write_svn_targets_file, not a plain redirect: it writes in the ANSI codepage svn reads paths
    # back in, which is what keeps non-ASCII filenames addressable (issue #35).
    if write_svn_targets_file "$tf" "${targets[@]}"; then
      ( cd "$bridge" && svn propset svn:eol-style native --quiet --targets "$tf" ) || rc=1
    else
      rc=1
    fi
    rm -f "$tf"
  fi

  echo "${#targets[@]}"
  rm -f "$cand" "$chg" "$both"
  return "$rc"
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
# Escape a path so svn accepts it as a TARGET argument.
#
# svn parses a trailing @<rev> on EVERY target as a peg revision, so a perfectly legal filename
# containing '@' -- `banner@2x.jpg`, the standard retina naming convention -- makes svn try to read
# "2x.jpg" as a revision and fail with:
#   svn: E200009: '<path>': a peg revision is not allowed here
# `--` does NOT prevent this: it terminates OPTION parsing, and peg parsing happens per-target
# afterwards (issue #34).
#
# The documented escape is to append one '@'. It is harmless for paths that contain no '@' at all
# (`foo.txt@` still resolves to `foo.txt`), so it is applied UNCONDITIONALLY -- a detect-then-escape
# branch would only add a way for our parsing to disagree with svn's.
#
# Use it for FILE targets. Do NOT wrap fixed targets like '.', which have their own meaning to svn.
svn_target() { printf '%s@' "$1"; }

# Echo the system ANSI codepage (CP_ACP) on Windows; empty elsewhere.
#
# NOT `chcp`: that reports the CONSOLE (OEM) codepage, which differs from CP_ACP on plenty of
# systems -- an en-US Windows is OEM 437 / ANSI 1252. svn reads a --targets file through CP_ACP, so
# the console codepage would be the wrong answer exactly where it matters.
#
# MSYS2_ARG_CONV_EXCL is required: without it MSYS mangles the `HKLM\...` argument into a path and
# reg.exe answers "invalid syntax".
_svn_ansi_codepage() {
  [[ "${OS:-}" == 'Windows_NT' ]] || return 0
  MSYS2_ARG_CONV_EXCL='*' reg.exe query 'HKLM\SYSTEM\CurrentControlSet\Control\Nls\CodePage' /v ACP 2>/dev/null \
    | tr -d '\r' | awk '/^[[:space:]]*ACP[[:space:]]/ { print $NF }' | tail -1
}

# Write a --targets file for svn: one path per line, in the encoding svn will read it back with.
#
# Why a targets file at all: passing each path as its own argv entry blows the command-line length
# limit once a push touches enough files ("Argument list too long" at ~2.9k targets; a first import
# of an existing project is usually far more than that, so that scenario simply could not work).
#
# Why the ANSI codepage and not UTF-8: verified against a local repository -- a UTF-8 targets file
# makes svn look for a mojibake path and fail with "is not under version control", while the same
# list written in CP_ACP commits correctly. This is the same channel the command line already went
# through (argv is CP_ACP too), so it is not a new limitation -- but it does mean a filename using
# characters outside the active codepage cannot be expressed here, exactly as it could not be
# expressed on the command line.
#
# Paths must ALREADY be escaped with svn_target: a targets file is peg-parsed line by line, just
# like argv (verified -- an unescaped `banner@2x.jpg` in a targets file still fails E200009).
# Args: <out_file> <path>...
write_svn_targets_file() {
  local out="$1"; shift
  local cp non_ascii=0
  cp="$(_svn_ansi_codepage)"

  # Does any path need an encoding that is not plain ASCII? ASCII is byte-identical in UTF-8 and in
  # every ANSI codepage, so when every path is ASCII the encoding question is moot and none of the
  # failure paths below apply. grep -E, never grep -P: PCRE mode refuses to run under the non-UTF-8
  # locales common on zh-TW Git Bash installs.
  if printf '%s\n' "$@" | LC_ALL=C grep -qE '[^ -~]'; then non_ascii=1; fi

  # No re-encoding needed: either not Windows (svn reads the locale encoding, i.e. UTF-8), or
  # CP_ACP already IS UTF-8. printf never emits a BOM -- and it must not, because svn would read
  # those bytes as part of the first path.
  if [[ "$cp" == '65001' ]] || [[ -z "$cp" && "${OS:-}" != 'Windows_NT' ]]; then
    printf '%s\n' "$@" > "$out"
    return 0
  fi

  # Windows, but the codepage lookup failed. Plain UTF-8 is right for ASCII and wrong for anything
  # else, so only the non-ASCII case is a problem -- fail there instead of silently writing bytes
  # svn will misread, which is exactly the mojibake this function exists to prevent.
  if [[ -z "$cp" ]]; then
    if (( non_ascii )); then
      echo "Error: could not determine this system's ANSI codepage, and a path in this commit is not plain ASCII." >&2
      echo "  Refusing to guess an encoding svn may misread. Run from a shell where reg.exe is available." >&2
      return 1
    fi
    printf '%s\n' "$@" > "$out"
    return 0
  fi

  if command -v iconv >/dev/null 2>&1; then
    if printf '%s\n' "$@" | iconv -f UTF-8 -t "CP$cp" > "$out" 2>/dev/null; then
      return 0
    fi
    # A path carries characters the ANSI codepage cannot represent. Say so plainly instead of
    # writing bytes svn will misread: the failure would otherwise surface as a confusing
    # "is not under version control" naming a mangled path.
    echo "Error: a path in this commit uses characters your system codepage (CP$cp) cannot represent," >&2
    echo "  so it cannot be passed to svn on this host. See the encoding notes in /tp-setup." >&2
    return 1
  fi

  # iconv missing (unusual in Git Bash, but possible): same reasoning as the unknown-codepage case.
  if (( non_ascii )); then
    echo "Error: 'iconv' is not available, so a non-ASCII path cannot be encoded for your system codepage (CP$cp)." >&2
    echo "  Refusing to write an encoding svn may misread." >&2
    return 1
  fi
  printf '%s\n' "$@" > "$out"
}

# Expand an unversioned DIRECTORY into one "A|<tracked|ignored>|<relpath>" line per file inside it.
#
# `svn status` reports a directory that is not yet under version control as a SINGLE '?' entry and
# never recurses into it -- svn's own behaviour, not a defect here. The commit step, however, runs
# `svn add --parents` (recursive), so every file inside IS committed. That gap made the
# consolidated confirmation list show 3 folders where 14 files were actually going to SVN
# (issue #24). The confirmation exists so the user sees the full scope BEFORE the commit rather
# than reading it back out of the commit output afterwards.
#
# Paths are emitted relative to the working copy, matching what `svn status` itself prints, so the
# SKILL's list never mixes two path shapes.
#
# Args: $1 = the bridge working copy; $2 = the unversioned dir, relative to it.
expand_unversioned_dir() {
  local remote_path="$1" rel_dir="$2"
  local abs_dir="$remote_path/$rel_dir"
  [[ -d "$abs_dir" ]] || return 0

  local child_abs child_rel
  # .git / .svn are metadata, never content to be pushed. A bridge worktree always has both.
  while IFS= read -r child_abs; do
    [[ -z "$child_abs" ]] && continue
    child_rel="${child_abs#"$remote_path/"}"
    if git -C "$remote_path" check-ignore -q "$child_rel" 2>/dev/null; then
      echo "A|ignored|$child_rel"
    else
      echo "A|tracked|$child_rel"
    fi
  done < <(find "$abs_dir" -type f -not -path '*/.git/*' -not -path '*/.svn/*' | LC_ALL=C sort)
}

# Read the SOURCE BRANCH off a merge commit's own subject. Prints the name, or returns 1 when
# the subject does not record one -- the caller must then NOT guess (see get_svn_push_body).
#
# Handles git's own default merge subjects (`Merge branch 'x'`, `... into y`, `Merge
# remote-tracking branch 'origin/x'`) and GitHub's (`Merge pull request #N from owner/x`);
# every plugin-generated merge uses the first form. The bridge-ref prefix is stripped so the
# internal `remote-svn/*` name never surfaces (a trunk-replay resolves to `main`).
merge_source_branch() {
  local subj="$1" name=""
  case "$subj" in
    "Merge "*) ;;
    *) return 1 ;;
  esac
  case "$subj" in
    "Merge pull request #"*" from "*)
      name="${subj#*" from "}"
      name="${name%% *}"        # owner/branch
      name="${name#*/}"         # drop the owner
      ;;
    *"branch '"*)
      name="${subj#*"branch '"}"
      name="${name%%"'"*}"
      ;;
    *) return 1 ;;
  esac
  [[ -z "$name" ]] && return 1
  # A real branch name has no whitespace, and must not be able to forge a group header.
  case "$name" in
    *[[:space:]]*|*'【'*|*'】'*) return 1 ;;
  esac
  name="${name#remote-svn/}"
  [[ -z "$name" ]] && return 1
  printf '%s' "$name"
}

get_svn_push_body() {
  local repo_dir="$1" range="$2"
  local tip="${range##*..}"
  local own sha branch subj i found
  # The current branch's OWN commits = its first-parent mainline (non-merge). Everything else in
  # range arrived via a merge and is attributed to its SOURCE branch below. Deciding "own" by
  # topology keeps a commit that the current branch and a sibling share from being mis-attributed
  # to the sibling.
  own=" $(git -C "$repo_dir" rev-list --first-parent --no-merges "$range" 2>/dev/null | tr '\n' ' ') "

  # Attribute each merged-in commit to the merge that INTRODUCED it into the pushed branch, and
  # take the source-branch name from that merge commit's own subject.
  #
  # This used to ask `git name-rev` which branch describes the commit, and that answers a
  # different question: name-rev minimises (generation, distance) over ALL local heads, which has
  # no relation to how the commit entered the branch being pushed. Any branch that merely
  # DESCENDS from the commit is a candidate -- and `/tp-merge-main-into-branches` plus ordinary
  # stacked branches make that set large. Issue #67 hit exactly that: a commit that reached `main`
  # through one branch was labelled with another branch that had never been merged into `main`
  # at all, permanently, in an SVN log. Reading the merge commit instead uses the record git wrote
  # AT MERGE TIME, so a later branch rename, deletion or merge cannot change the answer.
  #
  # attr accumulates " <sha>|<branch> " (no `declare -A` -- macOS bash 3.2 has none). Branch names
  # are whitespace-free (merge_source_branch rejects anything else), so '%% *' extracts exactly one.
  local attr=" " unresolved=0 m src c rest parents
  local -a pp=()
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    parents="$(git -C "$repo_dir" rev-list --parents -n 1 "$m" 2>/dev/null)"
    pp=($parents)
    src=""
    # Only an ordinary two-parent merge has one unambiguous "other side" to name.
    if (( ${#pp[@]} == 3 )); then
      subj="$(git -C "$repo_dir" log -1 --format='%s' "$m" 2>/dev/null)"
      src="$(merge_source_branch "$subj" || true)"
    fi
    if [[ -z "$src" ]]; then unresolved=1; break; fi
    # Commits this merge brought in = reachable from the merged side but not from the mainline.
    # An earlier merge of the same branch already claimed its own commits, so `--not <first
    # parent>` keeps each commit with the merge that FIRST introduced it.
    while IFS= read -r c; do
      [[ -z "$c" ]] && continue
      case "$attr" in *" $c|"*) continue ;; esac
      attr="$attr$c|$src "
    done < <(git -C "$repo_dir" rev-list --no-merges "$m^2" --not "$m^1" 2>/dev/null)
  done < <(git -C "$repo_dir" rev-list --first-parent --merges "$range" 2>/dev/null)

  # Parallel arrays: g_name[i] -> source branch, g_body[i] -> its accumulated "- <subject>" block,
  # in first-appearance order. flat[] is the same subjects ungrouped, used when grouping is unsafe.
  local -a g_name=() g_body=() flat=()
  while IFS= read -r sha; do
    [[ -z "$sha" ]] && continue
    subj="$(git -C "$repo_dir" log -1 --format='%s' "$sha" 2>/dev/null)"
    flat+=("- $subj")
    if [[ "$own" == *" $sha "* ]]; then
      branch="$tip"
    else
      branch=""
      case "$attr" in
        *" $sha|"*) rest="${attr#*" $sha|"}"; branch="${rest%% *}" ;;
      esac
      # Reachable but attributable to no merge on the mainline: do not invent a source.
      if [[ -z "$branch" ]]; then unresolved=1; branch="$tip"; fi
    fi
    found=-1
    for ((i = 0; i < ${#g_name[@]}; i++)); do
      if [[ "${g_name[$i]}" == "$branch" ]]; then found=$i; break; fi
    done
    if (( found < 0 )); then
      g_name+=("$branch"); g_body+=("- $subj")
    else
      g_body[$found]="${g_body[$found]}"$'\n'"- $subj"
    fi
  done < <(git -C "$repo_dir" rev-list --no-merges --reverse "$range" 2>/dev/null)

  local n=${#g_name[@]}
  (( n == 0 )) && return 0
  # ONE source branch -> flat "- <subject>" list (backward compatible; no group header).
  # Anything unattributable -> flat as well: a wrong group is worse than no group, because the
  # SVN log is permanent and the agent may only write the title, never the body.
  if (( unresolved )) || (( n == 1 )); then
    local out_flat="" f first_f=1
    for f in "${flat[@]}"; do
      if (( first_f )); then first_f=0; out_flat="$f"; else out_flat="$out_flat"$'\n'"$f"; fi
    done
    printf '%s\n' "$out_flat"
    return 0
  fi
  # 2+ source branches -> group by branch, current branch first, others in first-appearance order.
  # Each group: 【<branch>】 header then its bullets. Groups joined by a single newline.
  local -a order=()
  for ((i = 0; i < n; i++)); do [[ "${g_name[$i]}" == "$tip" ]] && order+=("$i"); done
  for ((i = 0; i < n; i++)); do [[ "${g_name[$i]}" != "$tip" ]] && order+=("$i"); done
  local out="" first=1 idx
  for idx in "${order[@]}"; do
    if (( first )); then first=0; else out="$out"$'\n'; fi
    out="$out【${g_name[$idx]}】"$'\n'"${g_body[$idx]}"
  done
  printf '%s\n' "$out"
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

  # Idempotency: this revision is already marked AND that marker is on HEAD → nothing to do. A
  # marker left by a rolled-back attempt is not an ancestor of HEAD, so it does not block a re-run.
  local marked
  marked="$(svn_rev_mark_get "$repo_dir" "$rev")"
  if [[ -n "$marked" ]] && git -C "$repo_dir" merge-base --is-ancestor "$marked" HEAD 2>/dev/null; then
    echo "SKIP:idempotent"
    return 0
  fi

  git -C "$repo_dir" add -A

  # Empty index (tree identical to parent) → this revision changed nothing we track, so HEAD ALREADY
  # carries its content: mark HEAD and make no commit. Marking (rather than skipping outright) is
  # what lets a revision whose content arrived some other way -- notably one this repo pushed
  # itself -- still be resolvable by the floor lookup. The command sits in the `if` condition so
  # `set -e` does not trip on its non-zero (= has-changes) exit.
  if git -C "$repo_dir" diff --cached --quiet; then
    local head_sha
    head_sha="$(git -C "$repo_dir" rev-parse --verify --quiet HEAD || true)"
    if [[ -n "$head_sha" ]]; then
      svn_rev_mark_set "$repo_dir" "$rev" "$head_sha"
    fi
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

  # The SVN message is committed VERBATIM -- the revision number lives in refs/tp/svn/<rev>, so
  # nothing is appended to (or stripped from) what the author wrote.
  git -C "$repo_dir" -c commit.gpgsign=false commit --cleanup=whitespace \
    "${author_arg[@]}" --date="$date_git" \
    -m "$message" >/dev/null

  local sha
  sha="$(git -C "$repo_dir" rev-parse HEAD)"
  svn_rev_mark_set "$repo_dir" "$rev" "$sha"
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
# Echo the URL that <base_url> (pegged at <peg_rev>) had at <rev>. Empty output + non-zero when svn
# cannot answer, so callers never mistake "unknown" for "unchanged".
#
# The peg is what makes this work across renames. `svn info -r R URL@PEG` follows copy history
# BACKWARDS from the pegged path, so a path renamed at some revision still resolves to its older
# name for revisions before the rename. The reverse does NOT hold: asking where an OLD path lives
# at HEAD fails with E160013 once that path has been deleted (verified against a local repository
# reproducing issue #32) -- which is why every lookup here must peg at a revision where the path is
# known to exist, normally HEAD.
# Args: <base_url> <peg_rev> <rev>
svn_url_at_rev() {
  local base_url="$1" peg_rev="$2" rev="$3" url
  url="$(svn info --show-item url -r "$rev" "${base_url}@${peg_rev}" 2>/dev/null | tr -d '\r\n')" || return 1
  [[ -n "$url" ]] || return 1
  printf '%s' "$url"
}

# Position the bridge working copy at <rev>, following a path rename when one is in play.
#
# `svn update -r R` cannot cross a rename: the WC is bound to the path as it existed at its own
# revision, and updating to a revision where that path no longer exists fails with E160005. When the
# URL this path has at <rev> is known, switching to it (with an explicit peg) moves the WC to the
# right place instead. --ignore-ancestry because a rename IS a delete+copy: svn otherwise refuses
# the switch for having no common ancestry.
#
# Two ways in, and BOTH are needed:
#   - <target_url> non-empty: the caller already detected a rename across the range, so switch
#     straight away instead of failing first.
#   - <target_url> empty but <base_url> given: try the plain update, and if it fails, resolve this
#     revision's own URL and switch. This is what covers a rename the range-endpoint check cannot
#     see -- a path renamed A->B->A INSIDE one pending window looks unrenamed at both ends, yet the
#     revisions in the middle live at B. Paying for the lookup only after a failure keeps the
#     common (never-renamed) case at exactly one svn call, as before.
# Args: <remote_path> <rev> [<target_url>] [<base_url>] [<peg_rev>]
svn_position_wc_at_rev() {
  local remote_path="$1" rev="$2" target_url="${3:-}" base_url="${4:-}" peg_rev="${5:-}" wc_url recovered

  if [[ -n "$target_url" ]]; then
    wc_url="$(svn info --show-item url "$remote_path" 2>/dev/null | tr -d '\r\n')"
    if [[ "$wc_url" != "$target_url" ]]; then
      ( cd "$remote_path" && svn switch --ignore-ancestry -r "$rev" "${target_url}@${rev}" ) \
        || { echo "Error: svn switch to ${target_url}@${rev} failed" >&2; return 1; }
      return 0
    fi
  fi

  if ( cd "$remote_path" && svn update -r "$rev" ); then
    return 0
  fi

  # Update failed. If we can ask where this path lived at <rev>, a mid-range rename is the likely
  # cause; switching there is a recovery, not a guess -- the URL comes from svn's own copy history.
  if [[ -n "$base_url" && -n "$peg_rev" ]]; then
    recovered="$(svn_url_at_rev "$base_url" "$peg_rev" "$rev" || true)"
    if [[ -n "$recovered" ]]; then
      echo "Note: r$rev is not reachable at the current path; following the rename to $recovered" >&2
      ( cd "$remote_path" && svn switch --ignore-ancestry -r "$rev" "${recovered}@${rev}" ) \
        || { echo "Error: svn switch to ${recovered}@${rev} failed" >&2; return 1; }
      return 0
    fi
  fi

  echo "Error: svn update -r $rev failed" >&2
  return 1
}

svn_replay_one_revision() {
  local remote_path="$1" rev="$2" author="$3" date="$4" message="$5" target_url="${6:-}" base_url="${7:-}" peg_rev="${8:-}" wc
  svn_position_wc_at_rev "$remote_path" "$rev" "$target_url" "$base_url" "$peg_rev" || return 1
  wc="$(svn info --show-item revision "$remote_path" | tr -d '[:space:]')"
  if [[ "$wc" != "$rev" ]]; then
    echo "Error: remote worktree not uniformly at r$rev (got r$wc); refusing per-revision replay." >&2
    return 1
  fi
  svn_replay_commit "$remote_path" "$rev" "$author" "$date" "$message" >/dev/null || return 1
}

# Squash the current SVN HEAD-of-range into ONE boundary commit on the bridge worktree's HEAD.
# Subject stays `sync: svn r<rev>` (steady-state shape) and refs/tp/svn/<rev> marks it, so the floor
# lookup (U5) treats the squashed range as a single boundary. An empty delta mints no commit but
# still marks HEAD -- the revision is materialised there either way.
# Args: <remote_path> <rev>
svn_boundary_commit() {
  local remote_path="$1" rev="$2" sha
  git -C "$remote_path" add -A
  if git -C "$remote_path" diff --cached --quiet; then
    sha="$(git -C "$remote_path" rev-parse --verify --quiet HEAD || true)"
    if [[ -n "$sha" ]]; then
      svn_rev_mark_set "$remote_path" "$rev" "$sha"
    fi
    return 0
  fi
  git -C "$remote_path" -c commit.gpgsign=false commit -m "sync: svn r$rev"
  svn_rev_mark_set "$remote_path" "$rev" "$(git -C "$remote_path" rev-parse HEAD)"
}

# Enumerate r(cur+1)..head_rev on the bridge worktree, then materialise commits per <mode>:
#   per-revision : one replay commit per revision (empty deltas skipped)
#   squash       : one boundary commit at head_rev
#   range        : per-revision inside <lo>:<hi> (from <range>), squash the leading + trailing rest
# Re-enumerates from the WC so the caller only has to hand over the decided mode (no array passing).
# Args: <remote_path> <remote_name> <cur> <head_rev> <mode> [<range>]
svn_replay_dispatch() {
  local remote_path="$1" remote_name="$2" cur="$3" head_rev="$4" mode="$5" range="${6:-}" base_url="${7:-}"

  # KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
  # uniform per-revision tree; assert once before touching anything.
  local depth
  depth="$(svn info --show-item depth "$remote_path" | tr -d '[:space:]')"
  if [[ "$depth" != "infinity" ]]; then
    echo "Error: remote worktree depth is '$depth', not 'infinity'; per-revision replay needs a full checkout." >&2
    return 1
  fi

  # Enumerate against the URL pegged at head_rev, NOT against the working copy.
  #
  # A WC checked out at an older revision is bound to the path as it existed THEN. If any ancestor
  # was renamed since, `svn log <WC>` asks about a path that no longer exists at head and dies with
  # E160013 naming a path the user never typed (issue #32). The pegged URL follows copy history, so
  # the same range enumerates correctly whether or not a rename happened.
  if [[ -z "$base_url" ]]; then
    base_url="$(svn info --show-item url "$remote_path" 2>/dev/null | tr -d '\r\n')"
  fi

  local -a REC_REV=() REC_AUTHOR=() REC_DATE=() REC_MSG=()
  if (( cur < head_rev )); then
    local log_xml
    log_xml="$(svn log --xml -r "$((cur + 1)):$head_rev" "${base_url}@${head_rev}")" || {
      echo "Error: svn log failed for r$((cur + 1)):r$head_rev on ${base_url}@${head_rev}" >&2
      echo "  If this mentions a path you never entered, the path (or one of its parent folders) was renamed on SVN." >&2
      echo "  A bridge already built against the old path cannot find the new one on its own -- re-run /tp-setup with the current URL." >&2
      return 1
    }
    while IFS=$'\037' read -r -d '' _rev _author _date _msg; do
      REC_REV+=("$_rev"); REC_AUTHOR+=("$_author"); REC_DATE+=("$_date"); REC_MSG+=("$_msg")
    done < <(printf '%s' "$log_xml" | svn_enumerate_revisions)
  fi

  # Was this path renamed anywhere inside the pending range? Asked ONCE, by comparing where it
  # lived at the first pending revision with where it lives at head. Equal -- the overwhelmingly
  # common case -- means no per-revision URL lookups happen at all, so unrenamed repositories pay
  # nothing for this. Only when they differ does each replayed revision resolve its own URL.
  local renamed=0 url_first='' url_head=''
  if (( cur < head_rev )); then
    url_first="$(svn_url_at_rev "$base_url" "$head_rev" "$((cur + 1))" || true)"
    url_head="$(svn_url_at_rev "$base_url" "$head_rev" "$head_rev" || true)"
    if [[ -n "$url_first" && -n "$url_head" && "$url_first" != "$url_head" ]]; then
      renamed=1
      printf 'TP_TOKEN:SVN_PATH_RENAMED old=%s new=%s range=r%s:r%s\n' \
        "$url_first" "$url_head" "$((cur + 1))" "$head_rev"
      echo "Note: this SVN path was renamed within r$((cur + 1))..r$head_rev; the import will follow the rename."
    fi
  fi

  # Resolve the URL a given revision needs, or empty when nothing was renamed (plain update path).
  _replay_target_url() {
    (( renamed )) || return 0
    svn_url_at_rev "$base_url" "$head_rev" "$1" || true
  }

  local i r lo hi
  if [[ "$mode" == "per-revision" ]]; then
    echo "Replaying ${#REC_REV[@]} SVN revision(s) r$((cur + 1))..r$head_rev into $remote_name..."
    for i in "${!REC_REV[@]}"; do
      svn_replay_one_revision "$remote_path" "${REC_REV[$i]}" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}" \
        "$(_replay_target_url "${REC_REV[$i]}")" "$base_url" "$head_rev" || return 1
    done
  elif [[ "$mode" == "squash" ]]; then
    echo "Squashing SVN r$((cur + 1))..r$head_rev into one commit in $remote_name..."
    svn_position_wc_at_rev "$remote_path" "$head_rev" "$(_replay_target_url "$head_rev")" "$base_url" "$head_rev" || return 1
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
      svn_position_wc_at_rev "$remote_path" "$((lo - 1))" "$(_replay_target_url "$((lo - 1))")" "$base_url" "$head_rev" || return 1
      svn_boundary_commit "$remote_path" "$((lo - 1))" || return 1
    fi
    # Per-revision inside [lo,hi].
    for i in "${!REC_REV[@]}"; do
      r="${REC_REV[$i]}"
      if (( r >= lo && r <= hi )); then
        svn_replay_one_revision "$remote_path" "$r" "${REC_AUTHOR[$i]}" "${REC_DATE[$i]}" "${REC_MSG[$i]}" \
          "$(_replay_target_url "$r")" "$base_url" "$head_rev" || return 1
      fi
    done
    # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=head_rev.
    if (( hi < head_rev )); then
      svn_position_wc_at_rev "$remote_path" "$head_rev" "$(_replay_target_url "$head_rev")" "$base_url" "$head_rev" || return 1
      svn_boundary_commit "$remote_path" "$head_rev" || return 1
    fi
  else
    echo "Error: unknown granularity '$mode' (expected per-revision | squash | range)" >&2; return 1
  fi
}

# ── Revision markers: refs/tp/svn/<N> (R14) ───────────────────────────────────
# The revision→commit map lives in a dedicated ref namespace, NOT in commit messages.
#
# Invariant: for every TRUNK revision N this repo knows about there is exactly ONE ref
# `refs/tp/svn/<N>` pointing at the git commit whose tree is trunk@N. Both directions record it:
# a pull points the marker at the commit its replay just made (or, when the revision changed
# nothing, at the tip that already carries that content), and a `main` push points it at the commit
# it just pushed. That closes the hole the message-trailer design had -- a revision this repo
# CREATED by pushing never got a marker, so alignment and fork-point lookups silently saw stale
# state -- and it makes both paths use one mechanism.
#
# Why refs rather than a `svn-revision:` message trailer:
#   - the marker is written by us, never mixed into an SVN author's message (no spoofing surface,
#     no defanging, and replayed messages round-trip byte-exact);
#   - no marker commits, so `git log` and the locked SVN push body stay clean;
#   - lookup is O(markers) via for-each-ref instead of walking every commit body;
#   - `refs/tp/*` is outside `refs/tags/`, so it never pollutes `git tag` (this plugin's release
#     tags live there) or `git describe`.
# The tradeoff accepted: refs are not part of the commit object, so a user who deletes them loses
# the map. That fails LOUD (checkout stops, "cannot attach") and is rebuilt by a fresh re-import.
# Markers are per-repo by design -- history does not travel between engineers here; each repo
# replays from SVN itself and writes its own markers.

# Point refs/tp/svn/<rev> at <sha> (create or move). Args: <repo_dir> <rev> <sha>
svn_rev_mark_set() {
  git -C "$1" update-ref "refs/tp/svn/$2" "$3"
}

# Echo the SHA marked for <rev>, or nothing. Args: <repo_dir> <rev>
svn_rev_mark_get() {
  git -C "$1" rev-parse --verify --quiet "refs/tp/svn/$2^{commit}" 2>/dev/null || true
}

# Echo "<rev> <sha>" per marker, DESCENDING by revision (numeric). Args: <repo_dir>
svn_rev_marks() {
  git -C "$1" for-each-ref --format='%(refname:lstrip=3) %(objectname)' 'refs/tp/svn/*' 2>/dev/null \
    | awk 'NF==2 && $1 ~ /^[0-9]+$/' | sort -rn -k1,1
}

# Floor revision→commit lookup (KTD3 floor semantics, R8/R14): the marker with the GREATEST
# revision <= <target_rev> whose commit is REACHABLE FROM `main`. SVN revisions are repo-global and
# sparse, so an arbitrary target (a branch's copyfrom-rev, say) usually has no exact marker.
#   - Prints exactly ONE SHA on success.
#   - Prints NOTHING (returns 0) when no marker <= target is reachable from main (the genuine
#     "predates earliest" case → checkout's R10 path).
# Ambiguity is impossible by construction (a ref name holds one revision), so the old
# fail-loud-on-duplicate branch is gone; markers left behind by a rolled-back import are simply
# unreachable from main and skipped here.
#
# WHY `main` and not the bridge ref (remote-svn/main) -- load-bearing, not an oversight:
#   * The SHA returned here becomes the PARENT of the branch checkout is about to create. A later
#     `git merge-base main <branch>` can only resolve to it if it sits in main's OWN history; that
#     is the entire point of grading the fork point (U5).
#   * Commits the bridge has but main does not come in two flavours, and NEITHER is a usable base:
#     the `Merge branch 'main' into remote-svn/main` commits that push creates (the bridge tip is
#     verifiably NOT an ancestor of main), and commits pull has already replayed but whose merge
#     into main has not landed yet.
#   * So widening the scan to the bridge would not buy reachability -- merge-base still would not
#     land on the chosen base. It would only trade "stop with a clear error" for "silently attach
#     the branch to history that main may never acquire".
# Scope differs per caller BY DESIGN, which is why svn_max_rev_reachable takes a ref:
#   pull resume point -> remote-svn/main | push alignment -> the pushed branch |
#   checkout grading bound + this floor -> main.
# Args: <repo_dir> <target_rev>
svn_floor_commit_for_rev() {
  local repo_dir="$1" target="$2" rev sha
  while read -r rev sha; do
    [[ -z "$rev" ]] && continue
    (( rev > target )) && continue
    if git -C "$repo_dir" merge-base --is-ancestor "$sha" main 2>/dev/null; then
      echo "$sha"
      return 0
    fi
  done < <(svn_rev_marks "$repo_dir")
  return 0
}

# Greatest marked revision REACHABLE FROM <ref>; 0 when none. This is the single "where are we"
# answer shared by the pull resume point, the checkout grading bound and the push alignment
# advance, so those three can no longer disagree (they used to: the pull read the working-copy
# revision while checkout read message trailers, which deadlocked a checkout behind a pull that
# had nothing to do). Args: <repo_dir> <ref>
svn_max_rev_reachable() {
  local repo_dir="$1" ref="$2" rev sha
  while read -r rev sha; do
    [[ -z "$rev" ]] && continue
    if git -C "$repo_dir" merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
      echo "$rev"
      return 0
    fi
  done < <(svn_rev_marks "$repo_dir")
  echo 0
}

# The checkout grading bound `cur` = greatest marked revision reachable from `main`.
svn_highest_replayed_rev() {
  svn_max_rev_reachable "$1" main
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

# resolve_path_within_worktree <root> <relative-path>
#
# Echo the resolved absolute path, or fail (non-zero, message on stderr) if it escapes <root>.
#
# Why this is worth a guard even though the value is not attacker-supplied in practice: the caller
# (remove-svn-file.sh) uses the result for `svn delete` + `svn commit` against the SHARED
# repository, and that is irreversible -- deleting the wrong path costs everyone on the team a
# recovery, and SVN history keeps the mistake forever. The path arrives from an agent reading
# `git status` / `svn status` output, so a `..` segment means something upstream is already wrong;
# the point is to stop there rather than to discover it after the commit. Mirrors the fail-closed
# stance of the SVN URL trust check above, which rejects `..` outright rather than sanitizing it.
resolve_path_within_worktree() {
  local root="$1" rel="$2"

  if [[ -z "$rel" ]]; then
    echo "Error: refusing an empty path." >&2; return 1
  fi
  case "$rel" in
    /*|[A-Za-z]:[\\/]*)
      echo "Error: refusing an absolute path: '$rel'. Paths are relative to the worktree root." >&2
      return 1 ;;
  esac

  # Check SEGMENTS, not a substring: a filename may legitimately contain '..' (e.g. "a..b.txt").
  local normalized="${rel//\\//}"
  local IFS='/' seg
  for seg in $normalized; do
    if [[ "$seg" == '..' ]]; then
      echo "Error: refusing a path containing '..': '$rel'." >&2; return 1
    fi
  done
  unset IFS

  # Deliberately LEXICAL, like the PowerShell twin: with absolute paths and '..' segments already
  # rejected, a plain join cannot escape, and staying lexical means the check does not depend on the
  # target existing yet (the caller reports "not found" itself, with a better message). Canonicalise
  # the root via the shell rather than realpath, which is not on every Git-for-Windows install.
  local root_real
  root_real="$(cd -- "$root" 2>/dev/null && pwd -P)" || {
    echo "Error: worktree root not readable: $root" >&2; return 1; }

  printf '%s\n' "$root_real/$normalized"
}

