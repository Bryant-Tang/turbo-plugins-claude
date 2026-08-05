#!/usr/bin/env bash
# Create a project's landing path in the SVN repository, on explicit user confirmation.
#
#   new-svn-path.sh --svn-url <url> [--standard-layout] [--dry-run]
#
# Why this exists: no other production script in this plugin runs `svn mkdir`, so a project's path
# had to be created by hand before /tp-setup could do anything -- while case (a) of tp-setup
# advertises "brand new git + SVN" and only ever delivered the git half. Creating a path is a
# PERMANENT write to a shared server (SVN has no delete-for-real), so this is a separate,
# explicitly-invoked script: nothing calls it implicitly, and the SKILL must show the full URL and
# get a yes first.
#
# --standard-layout is only offered when the URL ends with /trunk, which is the layout it means:
# it additionally creates the sibling branches/ and tags/. Without that suffix the layout has no
# unambiguous reading, so only the given path is created.
#
# --dry-run prints the URLs that WOULD be created and exits 0 without touching the server.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

SVN_URL=''
STANDARD_LAYOUT=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --svn-url)         [[ $# -ge 2 ]] || { echo "Error: --svn-url requires a value" >&2; exit 1; }; SVN_URL="$2"; shift 2 ;;
    --standard-layout) STANDARD_LAYOUT=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$SVN_URL" ]]; then echo "Error: --svn-url is required" >&2; exit 1; fi

# Strip a trailing slash so dirname/suffix logic below is not fooled by '.../trunk/'.
SVN_URL="${SVN_URL%/}"

case "$SVN_URL" in
  http://*|https://*|svn://*|svn+ssh://*|file:///*) : ;;
  *) echo "Error: --svn-url must be an SVN URL (http/https/svn/svn+ssh/file), got: $SVN_URL" >&2; exit 1 ;;
esac

# Already there? Say so and stop -- creating is not idempotent in a useful way (a second mkdir
# fails), and a caller that reaches here with an existing path has misread its own preflight.
if svn info "$SVN_URL" >/dev/null 2>&1; then
  echo "Error: that path already exists in the repository: $SVN_URL" >&2
  exit 1
fi

TARGETS=("$SVN_URL")
if [[ "$STANDARD_LAYOUT" == true ]]; then
  case "$SVN_URL" in
    */trunk)
      BASE="${SVN_URL%/trunk}"
      TARGETS+=("$BASE/branches" "$BASE/tags")
      ;;
    *)
      echo "Error: --standard-layout needs a URL ending in /trunk (it creates the sibling branches/ and tags/). Got: $SVN_URL" >&2
      exit 1
      ;;
  esac
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "Would create:"
  for t in "${TARGETS[@]}"; do echo "  $t"; done
  exit 0
fi

echo "Creating in the repository:"
for t in "${TARGETS[@]}"; do echo "  $t"; done

# --parents so an absent intermediate directory (the project folder itself) is created too; all
# targets go in ONE revision so a half-created layout is not possible.
svn mkdir --parents --encoding UTF-8 -m 'create project path (turbo-plugin)' "${TARGETS[@]}"

echo ""
echo "Created. SVN paths are permanent -- there is no undo."
