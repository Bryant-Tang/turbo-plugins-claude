#!/usr/bin/env bash
# Resolve which dbhub config to use, then exec the DBHub container.
#
#   start-dbhub.sh <session-root> [--print-command]
#
# This wrapper exists for two defects found on a real machine 2026-07-31.
#
# 1. `.mcp.json` used to hand `docker run -v` the path
#    `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml` directly. Docker CREATES a directory
#    when a bind-mount source does not exist, so every folder a session was ever opened in got a
#    stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY, not a file. That is worse than
#    untidy: it blocks its own fix (you can no longer create a file of that name), and what dbhub
#    receives is a directory rather than a config. So: this script NEVER passes a path to `-v`
#    without having confirmed it is an existing FILE.
#
# 2. `${CLAUDE_PROJECT_DIR}` is the session root. In a multi-project workspace (several sibling
#    repos under one folder) that root is not any of the projects, so the config -- which lives in
#    a project -- was never found. This script searches for it (D1, decided 2026-08-03):
#       a) <session-root>/.turbo-plugin/dbhub.local.toml, if present, always wins. That is how a
#          workspace says "use this database" when several projects could answer.
#       b) otherwise the IMMEDIATE subdirectories are scanned. Exactly one match is used.
#       c) several matches -> stop and list them, because guessing which database to connect to is
#          not a recoverable mistake. The message says how to settle it (put a config at the root).
#       d) no match -> stop and say where it looked.
#
# Every failure exits 0. This is an MCP server launcher: a non-zero exit is reported to the user as
# a crashed server, which is both alarming and unhelpful when the real answer is "this project has
# no database configured". The explanation goes to stderr, and stdout stays empty so nothing is
# mistaken for a protocol message.
#
# --print-command prints the docker argv that WOULD run, one per line, instead of executing it.
# Tests use it to assert the argv without starting a container.
set -uo pipefail

SESSION_ROOT="${1:-}"
PRINT_ONLY=false
if [[ "${2:-}" == "--print-command" ]]; then PRINT_ONLY=true; fi

CONFIG_REL='.turbo-plugin/dbhub.local.toml'
IMAGE='bytebase/dbhub:latest'

say() { echo "$*" >&2; }

if [[ -z "$SESSION_ROOT" ]]; then
  say "tp-dbhub: no session root was passed to start-dbhub.sh, so there is nothing to search."
  exit 0
fi

if [[ ! -d "$SESSION_ROOT" ]]; then
  say "tp-dbhub: '$SESSION_ROOT' is not a directory; cannot look for $CONFIG_REL."
  exit 0
fi

# (a) A config at the session root wins outright.
CONFIG=''
if [[ -f "$SESSION_ROOT/$CONFIG_REL" ]]; then
  CONFIG="$SESSION_ROOT/$CONFIG_REL"
else
  # (b) Scan the immediate subdirectories only. Deeper is not searched on purpose: the workspace
  # shape this supports is "sibling projects one level down", and an unbounded walk would make
  # which database you connect to depend on directory depth.
  MATCHES=()
  for d in "$SESSION_ROOT"/*/; do
    [[ -d "$d" ]] || continue
    if [[ -f "${d}${CONFIG_REL}" ]]; then MATCHES+=("${d}${CONFIG_REL}"); fi
  done

  case "${#MATCHES[@]}" in
    1) CONFIG="${MATCHES[0]}" ;;
    0)
      say "tp-dbhub: no database config found."
      say "  looked for: $SESSION_ROOT/$CONFIG_REL"
      say "  and in each project directly under: $SESSION_ROOT"
      say "Run /tp-setup in the project that has a database, then copy"
      say "  .turbo-plugin/dbhub.example.local.toml -> .turbo-plugin/dbhub.local.toml and fill it in."
      exit 0
      ;;
    *)
      say "tp-dbhub: several projects here have a database config, so which one to connect to is ambiguous:"
      for m in "${MATCHES[@]}"; do say "  $m"; done
      say "Pick one by putting a config at the workspace root ($SESSION_ROOT/$CONFIG_REL) --"
      say "copying the chosen project's file there is enough. A root config always wins."
      exit 0
      ;;
  esac
fi

# Docker wants a Windows-style path on Windows; Git Bash hands us /c/... Convert when cygpath is
# available (it is, under Git Bash) and leave the path alone everywhere else.
MOUNT_SRC="$CONFIG"
if command -v cygpath >/dev/null 2>&1; then
  MOUNT_SRC="$(cygpath -m "$CONFIG" 2>/dev/null || echo "$CONFIG")"
fi

DOCKER_ARGS=(run -i --rm --init -v "${MOUNT_SRC}:/dbhub.toml" "$IMAGE" --transport stdio --config /dbhub.toml)

if [[ "$PRINT_ONLY" == true ]]; then
  printf '%s\n' docker "${DOCKER_ARGS[@]}"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  say "tp-dbhub: docker was not found on PATH. The dbhub MCP server runs in a container;"
  say "install Docker Desktop (or start it) and reopen the session."
  exit 0
fi

exec docker "${DOCKER_ARGS[@]}"
