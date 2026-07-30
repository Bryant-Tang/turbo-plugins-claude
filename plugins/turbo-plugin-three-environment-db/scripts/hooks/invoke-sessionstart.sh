#!/usr/bin/env bash
# turbo-plugin-three-environment-db SessionStart hook (advisory; dbhub branch only).
# On Windows / Git Bash: delegate to the native PowerShell implementation.
# On other platforms: run the slim native bash version.
#
# Behavior: warn only when db is in use (this project has .turbo-plugin/dbhub.example.local.toml)
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

# pre-check (1): inside a git work tree?
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_json
  exit 0
fi

# pre-check (2): inside a submodule? silent exit if so
if test_is_submodule; then
  emit_json
  exit 0
fi

CWD="$(pwd)"
MARKER_DIR="${CWD}/.turbo-plugin"

# db concern gate (KTD9): only act when this project uses db (the committed
# dbhub.example.local.toml template is present). Otherwise no-op.
if [[ ! -f "${MARKER_DIR}/dbhub.example.local.toml" ]]; then
  emit_json
  exit 0
fi

# dbhub branch: peer worktree + missing dbhub.local.toml -> Pattern B warning.
if ! test_is_main_worktree; then
  DBHUB_LOCAL="${MARKER_DIR}/dbhub.local.toml"
  if [[ ! -f "$DBHUB_LOCAL" ]]; then
    MSG="turbo-plugin-three-environment-db: 偵測到 Pattern B 啟動於 peer worktree,但缺少 .turbo-plugin/dbhub.local.toml。tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 dbhub.local.toml,或結束 session 改到主 worktree 啟動(Pattern A)。Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 切到別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
    printf '{"systemMessage":"%s"}' "$(printf '%s' "$MSG" | sed 's/"/\\"/g')"
    exit 0
  fi
fi

emit_json
exit 0
