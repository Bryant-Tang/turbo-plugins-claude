#!/usr/bin/env bash
# turbo-plugin SessionStart hook.
# On Windows / Git Bash: delegate to the native PowerShell implementation
# (it has full IIS Express applicationhost.config consistency checks).
# On other platforms: run a slim native bash version that handles the
# non-IIS branches (Pattern B dbhub warning, marker-missing prompt).
set -uo pipefail

# SessionStart hooks must never block Claude Code. Any unexpected non-zero exit
# falls through to emit empty JSON with exit 0 so the session always starts cleanly.
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
    echo "turbo-plugin invoke-sessionstart: powershell exited $exit_code" >&2
  fi
  exit 0
fi

# Non-Windows native bash impl.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd -- "$SCRIPT_DIR/../lib" && pwd)"
# shellcheck disable=SC1091
source "$LIB_DIR/common.sh"

emit_json() {
  if [[ -n "${1:-}" ]]; then
    printf '%s' "$1"
  else
    printf '{}'
  fi
}

# pre-check (1)
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  emit_json
  exit 0
fi

# pre-check (2)
if test_is_submodule; then
  emit_json
  exit 0
fi

CWD="$(pwd)"
MARKER_DIR="${CWD}/.turbo-plugin"

if [[ -d "$MARKER_DIR" ]]; then
  # Branch (i) (applicationhost.config staleness check) is intentionally not implemented on
  # non-Windows — IIS Express is Windows-only. Silent exit through to Branch (ii)/(iii) is
  # the correct behavior here.

  # Branch (ii): peer worktree + missing dbhub.local.toml
  if ! test_is_main_worktree; then
    DBHUB_LOCAL="${MARKER_DIR}/dbhub.local.toml"
    if [[ ! -f "$DBHUB_LOCAL" ]]; then
      MSG="turbo-plugin: 偵測到 Pattern B 啟動於 peer worktree,但缺少 .turbo-plugin/dbhub.local.toml。tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 dbhub.local.toml,或結束 session 改到主 worktree 啟動(Pattern A)。Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 切到別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
      printf '{"systemMessage":"%s"}' "$(printf '%s' "$MSG" | sed 's/"/\\"/g')"
      exit 0
    fi
  fi
  emit_json
  exit 0
fi

# Marker missing
COMMON_DIR="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
TOP_LEVEL="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null || true)"
if [[ -z "$COMMON_DIR" || -z "$TOP_LEVEL" ]]; then
  emit_json
  exit 0
fi
MAIN_PATH="$(get_normalized_absolute_path "$(dirname "$COMMON_DIR")")"
CUR_PATH="$(get_normalized_absolute_path "$TOP_LEVEL")"

if [[ "$MAIN_PATH" == "$CUR_PATH" ]]; then
  MSG="turbo-plugin: 偵測到本 worktree 尚未 bootstrap。請執行 /tp-setup 完成設定。"
else
  MSG="turbo-plugin: 偵測到本 worktree 尚未 bootstrap,且這裡是 peer worktree。請到主 worktree (${MAIN_PATH}) 啟動 Claude 並執行 /tp-setup,完成 bootstrap 後再回此 worktree 工作。"
fi
printf '{"systemMessage":"%s"}' "$(printf '%s' "$MSG" | sed 's/"/\\"/g')"
exit 0
