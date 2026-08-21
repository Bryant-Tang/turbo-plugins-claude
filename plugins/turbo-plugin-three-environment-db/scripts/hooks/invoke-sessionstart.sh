#!/usr/bin/env bash
# turbo-plugin-three-environment-db SessionStart hook (advisory; dbhub branch only).
# On Windows / Git Bash: delegate to the native PowerShell implementation.
# On other platforms: run the slim native bash version.
#
# Behavior: warn only when db is in use (this project has .turbo-plugin/dbhub.example.toml, or the
# pre-rename .turbo-plugin/dbhub.example.local.toml)
# AND we are in a peer worktree AND .turbo-plugin/dbhub.local.toml is missing — i.e. the tp-dbhub
# MCP server would fail to start. Otherwise emit `{}` silently. Never blocks the session.
# Concern-neutral no-op when the db marker is absent (KTD9): a project that does not use db
# never sees this hook fire.
set -uo pipefail

# SessionStart hooks must never block Claude Code. Any unexpected non-zero exit falls
# through to emit empty JSON with exit 0 so the session always starts cleanly.
trap 'printf "{}"; exit 0' ERR

uname_s="$(uname -s 2>/dev/null || echo unknown)"

if [[ "$uname_s" =~ ^(MINGW|MSYS|CYGWIN) || "$uname_s" == "Windows_NT" ]]; then
  PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"
  PS1_PATH="${PLUGIN_ROOT}/scripts/hooks/Invoke-SessionStart.ps1"
  if [[ "$PS1_PATH" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    PS1_PATH="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
  fi
  # Wrap in if-test so the ERR trap doesn't fire on non-zero powershell exit
  # (commands in `if` conditions bypass ERR / set -e), letting the diagnostic
  # echo below run with the captured exit code.
  if powershell -NoProfile -ExecutionPolicy Bypass -File "$PS1_PATH"; then
    exit_code=0
  else
    exit_code=$?
  fi
  if [[ $exit_code -ne 0 ]]; then
    echo "turbo-plugin-three-environment-db invoke-sessionstart: powershell exited $exit_code" >&2
  fi
  exit 0
fi

# Non-Windows native bash impl.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/core.sh"

emit_json() {
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1"
  else
    printf '{}'
  fi
}

CWD="$(pwd)"
MARKER_DIR="${CWD}/.turbo-plugin"

# The db marker has TWO accepted names, and both have to stay. `dbhub.example.toml` is what
# tp-setup deploys now; `dbhub.example.local.toml` is what every project set up before the rename
# already has committed. Recognising only the new name would make this hook conclude those projects
# do not use a database and go silent -- which is exactly the failure shape the gate below exists to
# prevent, and the user would get no signal that anything changed. Drop the old name only once no
# project is still on it.
db_marker_in() {
  if [[ -f "${1}/.turbo-plugin/dbhub.example.toml" ]]; then return 0; fi
  if [[ -f "${1}/.turbo-plugin/dbhub.example.local.toml" ]]; then return 0; fi
  return 1
}

# db concern gate (KTD9): only act when db is actually in use. Otherwise a silent no-op.
#
# Look HERE first, then one level down -- the same resolution `start-dbhub.js` uses, and for the
# same reason: in a multi-project workspace the session root is not any of the projects, so the
# marker lives in a subdirectory. This gate used to look only at the cwd, and the whole hook used
# to bail even earlier on "not a git repository" -- and a multi-project workspace root is never a
# repo. Between them, the hook could not fire in exactly the shape the db plugin's multi-project
# support was built for: observed 2026-08-03, a session with no node on PATH said nothing at all
# and the user had to ask why the MCP server was red.
db_in_use=false
if db_marker_in "$CWD"; then
  db_in_use=true
else
  for _d in "$CWD"/*/; do
    [[ -d "$_d" ]] || continue
    if db_marker_in "${_d%/}"; then db_in_use=true; break; fi
  done
fi

if [[ "$db_in_use" != true ]]; then
  emit_json
  exit 0
fi

# Being inside a git work tree is NOT required to get this far -- only the peer-worktree branch
# below needs it. Resolve it once, quietly: git writes "fatal: not a git repository" to stderr,
# which used to surface to the user on a path that is meant to be a silent no-op.
IN_GIT_REPO=false
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if ! test_is_submodule; then IN_GIT_REPO=true; fi
fi

# Accumulated as a plain string, not an array: `${arr[@]}` on an empty array trips `set -u` on
# bash 3.2 (what macOS still ships), and this hook must never be the thing that breaks a session.
NOTES=''
add_note() { if [[ -n "$NOTES" ]]; then NOTES="$NOTES $1"; else NOTES="$1"; fi; }

# node gate. The launcher `.mcp.json` runs is a node script, so when node is missing NOTHING
# downstream can speak: the server dies before our code runs and the user gets a bare red cross in
# /mcp with the reason buried in a debug log. This hook is the only component still running in that
# case, so it is the one that has to say it. Gated on the db marker above, so a project that does
# not use a database never sees it.
if ! command -v node >/dev/null 2>&1; then
  add_note "turbo-plugin-three-environment-db:這個專案有用到資料庫,但這台機器的 PATH 上找不到 node。tp-dbhub MCP server 是用 node 啟動的,所以它不會起來(在 /mcp 只會看到一個紅叉,沒有其它說明)。裝好 Node.js 之後重開 session 就好。"
fi

# dbhub branch: peer worktree + missing dbhub.local.toml -> Pattern B warning. Only meaningful
# inside a repo -- "which worktree am I in" has no answer otherwise.
if [[ "$IN_GIT_REPO" == true ]] && ! test_is_main_worktree; then
  DBHUB_LOCAL="${MARKER_DIR}/dbhub.local.toml"
  if [[ ! -f "$DBHUB_LOCAL" ]]; then
    add_note "turbo-plugin-three-environment-db:偵測到 Pattern B 啟動於 peer worktree,但缺少 .turbo-plugin/dbhub.local.toml。tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 dbhub.local.toml,或結束 session 改到主 worktree 啟動(Pattern A)。Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 切到別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
  fi
fi

if [[ -n "$NOTES" ]]; then
  # Emit BOTH channels.
  #
  # `systemMessage` is Claude Code printing a warning to the user -- it is not the assistant
  # speaking, so it needs no user turn. But the docs do not pin down WHEN SessionStart's
  # systemMessage renders, so relying on it alone bets on undocumented behaviour.
  # `additionalContext` has the contract we actually need: inserted into Claude's context "at the
  # start of the conversation, before the first prompt". So whatever the user types first, the
  # assistant already knows why the database server cannot start and answers immediately, instead
  # of investigating from scratch -- which is what happened on 2026-08-03.
  ESC="$(printf '%s' "$NOTES" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s"}}' "$ESC" "$ESC"
  exit 0
fi

emit_json
exit 0
