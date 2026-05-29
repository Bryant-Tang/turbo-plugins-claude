#!/usr/bin/env bash
# Usage: get-svn-log.sh [--branch <main|test-<n>>] [--limit <n>] [--revision <spec>] [--verbose]
#
# Always invokes `svn log --xml`: SVN emits UTF-8 XML regardless of console
# codepage / locale, avoiding mojibake (e.g. zh-TW commit messages turning
# into `?`). XML is parsed via xmllint when present, with a grep+awk fallback
# for Git Bash on Windows where xmllint is typically absent.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

BRANCH='main'
LIMIT='5'
REVISION=''
VERBOSE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)   [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    --limit)    [[ $# -ge 2 ]] || { echo "Error: --limit requires a value" >&2; exit 1; }; LIMIT="$2"; shift 2 ;;
    --revision) [[ $# -ge 2 ]] || { echo "Error: --revision requires a value" >&2; exit 1; }; REVISION="$2"; shift 2 ;;
    --verbose)  VERBOSE=true; shift ;;
    *) echo "Error: unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

probe_git_version

if ! [[ "$LIMIT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Error: --limit must be a positive integer (got '$LIMIT')." >&2; exit 1
fi

MAIN_WORKTREE="$(get_main_worktree)"
PROJ_NAME="$(basename "$MAIN_WORKTREE")"
ROOT_DIR="$(dirname "$MAIN_WORKTREE")"
WORKTREES_DIR="$ROOT_DIR/$PROJ_NAME.worktrees"

REMOTE_SPEC="$(resolve_remote_worktree "$BRANCH" "$WORKTREES_DIR")"
REMOTE_NAME="${REMOTE_SPEC%%|*}"
REMOTE_PATH="${REMOTE_SPEC##*|}"

if [[ ! -d "$REMOTE_PATH" ]]; then
  echo "Error: remote worktree '$REMOTE_NAME' not found at: $REMOTE_PATH" >&2; exit 1
fi

# Build svn args. SAFETY: every value goes in its own array element (with
# double-quoted expansion below), never string-concatenated. This is the
# separate-arg invariant required by F10 -- see the matching PS comment.
SVN_ARGS=(log --xml --limit "$LIMIT")
[[ "$VERBOSE" == true ]] && SVN_ARGS+=(-v)
if [[ -n "$REVISION" ]]; then
  SVN_ARGS+=(--revision "$REVISION")
fi
SVN_ARGS+=("$REMOTE_PATH")

XML="$(svn "${SVN_ARGS[@]}")"

# Empty XML (no entries) -- exit cleanly without emitting a trailer.
if [[ -z "$XML" ]]; then
  exit 0
fi

format_entries_xmllint() {
  local xml="$1"
  local count rev author date msg min_rev=''
  count=$(xmllint --xpath "count(//logentry)" - <<<"$xml")
  if [[ -z "$count" || "$count" == "0" ]]; then
    return 0
  fi
  local i
  for (( i=1; i<=count; i++ )); do
    rev=$(xmllint --xpath "string(//logentry[$i]/@revision)" - <<<"$xml")
    author=$(xmllint --xpath "string(//logentry[$i]/author)" - <<<"$xml")
    date=$(xmllint --xpath "string(//logentry[$i]/date)" - <<<"$xml")
    msg=$(xmllint --xpath "string(//logentry[$i]/msg)" - <<<"$xml")
    printf 'r%s | %s | %s | %s\n' "$rev" "$author" "$date" "$msg"

    if [[ "$VERBOSE" == true ]]; then
      local pcount j path_action path_text
      pcount=$(xmllint --xpath "count(//logentry[$i]/paths/path)" - <<<"$xml")
      if [[ -n "$pcount" && "$pcount" != "0" ]]; then
        for (( j=1; j<=pcount; j++ )); do
          path_action=$(xmllint --xpath "string(//logentry[$i]/paths/path[$j]/@action)" - <<<"$xml")
          path_text=$(xmllint --xpath "string(//logentry[$i]/paths/path[$j])" - <<<"$xml")
          printf '   %s %s\n' "$path_action" "$path_text"
        done
      fi
    fi

    if [[ -n "$rev" ]]; then
      if [[ -z "$min_rev" || "$rev" -lt "$min_rev" ]]; then
        min_rev="$rev"
      fi
    fi
  done
  if [[ -n "$min_rev" ]]; then
    printf '# LAST_SHOWN_REV=%s\n' "$min_rev"
  fi
}

format_entries_fallback() {
  # grep+awk fallback for Git Bash where xmllint is typically absent.
  #
  # `svn log --xml` may emit the opening `<logentry` tag with its `revision`
  # attribute either on the same line OR split across two lines:
  #   Format A: <logentry revision="5">
  #   Format B: <logentry\n   revision="5">
  # The awk script below handles both: it enters entry mode on `<logentry`,
  # then captures `revision=` from either that line or any subsequent line
  # until `>` is seen.
  #
  # LIMITATIONS (documented):
  #   - Multi-line <msg>...</msg> content is joined with spaces; original
  #     line breaks are lost.
  #   - XML entity references (&amp; &lt; etc.) are NOT decoded.
  # Workaround: install xmllint (e.g. `pacman -S libxml2` in MSYS2). The
  # primary path above handles these correctly.
  local xml="$1"
  echo "$xml" | awk '
    BEGIN {
      in_entry=0; in_header=0
      rev=""; author=""; date=""; msg=""; in_msg=0; min_rev=""
    }
    /<logentry/ {
      in_entry=1; in_header=1
      rev=""; author=""; date=""; msg=""; in_msg=0
      if (match($0, /revision="[0-9]+"/)) {
        rev = substr($0, RSTART+10, RLENGTH-11)
      }
      if (index($0, ">") > 0) in_header=0
      next
    }
    in_header {
      if (match($0, /revision="[0-9]+"/)) {
        rev = substr($0, RSTART+10, RLENGTH-11)
      }
      if (index($0, ">") > 0) in_header=0
      next
    }
    in_entry && /<\/logentry>/ {
      printf "r%s | %s | %s | %s\n", rev, author, date, msg
      if (rev != "" && (min_rev == "" || rev+0 < min_rev+0)) min_rev = rev
      in_entry=0; in_msg=0
      next
    }
    in_entry && /<author>/ {
      line=$0; sub(/.*<author>/, "", line); sub(/<\/author>.*/, "", line); author=line; next
    }
    in_entry && /<date>/ {
      line=$0; sub(/.*<date>/, "", line); sub(/<\/date>.*/, "", line); date=line; next
    }
    in_entry && /<msg\/>/ { msg=""; next }
    in_entry && /<msg>/ && /<\/msg>/ {
      line=$0; sub(/.*<msg>/, "", line); sub(/<\/msg>.*/, "", line); msg=line; next
    }
    in_entry && /<msg>/ {
      line=$0; sub(/.*<msg>/, "", line); msg=line; in_msg=1; next
    }
    in_entry && in_msg && /<\/msg>/ {
      line=$0; sub(/<\/msg>.*/, "", line)
      if (line != "") msg = msg " " line
      in_msg=0; next
    }
    END {
      if (min_rev != "") printf "# LAST_SHOWN_REV=%s\n", min_rev
    }
  '
}

if command -v xmllint >/dev/null 2>&1; then
  format_entries_xmllint "$XML"
else
  format_entries_fallback "$XML"
fi
