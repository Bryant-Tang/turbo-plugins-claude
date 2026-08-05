#!/usr/bin/env bash
# Delegate to a PowerShell .ps1 sibling.
# Args: <script-name-without-ext> <forwarded-args...>
# Example: ps1-delegate.sh build-web --configuration Release
set -euo pipefail

SCRIPT_NAME="$1"; shift
SCRIPTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PS1_PATH="${SCRIPTS_DIR}/${SCRIPT_NAME}.ps1"

# Convert Git Bash /c/foo → C:/foo so PowerShell can resolve the path.
if [[ "$PS1_PATH" =~ ^/([a-zA-Z])/(.*)$ ]]; then
  PS1_PATH="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
fi

# Translate `--kebab-case` flags to the `-PascalCase` names PowerShell's -File mode binds.
#
# Without this the delegate is a zero-translation shell, and the result is worse than no support at
# all: a single-word flag works by coincidence (`--project` happens to bind to `-Project`) while a
# multi-word one silently does not (`--remove-all` never binds `-RemoveAll`). One works, the next
# does not, and nothing says why -- observed on a real machine 2026-07-31. Translating makes these
# .sh entry points behave like the hand-written bash scripts in the sibling plugins.
#
# Only a token that is ENTIRELY `--lowercase-with-dashes` is rewritten; values, `-AlreadyPascal`,
# bare words and paths pass through byte-for-byte. A VALUE that itself looks like a flag would be
# rewritten too -- same ambiguity every `--flag value` parser has, and no caller passes one.
TP_ARGS=()
for tp_arg in "$@"; do
  if [[ "$tp_arg" =~ ^--[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    tp_pascal=''
    IFS='-' read -r -a tp_parts <<< "${tp_arg#--}"
    for tp_part in "${tp_parts[@]}"; do
      tp_pascal+="${tp_part^}"
    done
    TP_ARGS+=("-$tp_pascal")
  else
    TP_ARGS+=("$tp_arg")
  fi
done

# ${TP_ARGS[@]+"..."} — an empty array under `set -u` is an unbound-variable error on bash 4.x.
exec powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_PATH" ${TP_ARGS[@]+"${TP_ARGS[@]}"}
