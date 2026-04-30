#!/usr/bin/env bash
# Usage: tag-release.sh --branch <main|test-<n>>
set -euo pipefail

BRANCH=''

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch) [[ $# -ge 2 ]] || { echo "Error: --branch requires a value" >&2; exit 1; }; BRANCH="$2"; shift 2 ;;
    *) echo "Unknown argument: '$1'" >&2; exit 1 ;;
  esac
done

if [[ -z "$BRANCH" ]]; then echo "Error: --branch is required" >&2; exit 1; fi

if [[ "$BRANCH" == 'main' ]]; then
  REMOTE_BRANCH='remote/main'
elif [[ "$BRANCH" =~ ^test-([0-9]+)$ ]]; then
  REMOTE_BRANCH="remote/test-${BASH_REMATCH[1]}"
else
  echo "Error: unsupported branch '$BRANCH'. Only 'main' and 'test-<n>' are supported." >&2; exit 1
fi

PREFIX="${BRANCH}-release-$(date +%Y-%m-%d)"
EXISTING="$(git tag -l "${PREFIX}-[0-9][0-9][0-9]" | sort | tail -1)"

if [[ -z "$EXISTING" ]]; then
  SERIAL="001"
else
  LAST_NUM="${EXISTING##*-}"
  SERIAL="$(printf '%03d' $(( 10#$LAST_NUM + 1 )))"
fi

TAG_NAME="${PREFIX}-${SERIAL}"
git tag "$TAG_NAME" "$REMOTE_BRANCH"
echo "Created tag: $TAG_NAME"
