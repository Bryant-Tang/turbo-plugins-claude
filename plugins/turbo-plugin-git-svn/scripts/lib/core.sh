#!/usr/bin/env bash
# turbo-plugin universal core helpers (config / path / worktree / git-version / UTF-8 write).
# Sourced first by concern libs (e.g. common.sh) and directly by scripts that need only core.
# Owns the UTF-8 locale bootstrap and `set -euo pipefail`; concern libs must NOT weaken these.

set -euo pipefail

# UTF-8 locale (R4/R5): svn / git need a UTF-8 locale to handle non-ASCII (Chinese)
# commit messages and filenames consistently. Portable + non-fatal: keep the current
# locale if it is already UTF-8; otherwise adopt the first available UTF-8 locale
# (prefer C.UTF-8 / en_US.UTF-8); if none is available, degrade silently rather than
# fail (R-2: C.UTF-8 is absent on some minimal images).
if ! printf '%s' "${LC_ALL:-${LANG:-}}" | grep -qiE 'utf-?8'; then
  _tp_loc="$(locale -a 2>/dev/null | grep -iE 'utf-?8' | grep -iE '(^|/)(C\.|en_US\.)' | head -n1 || true)"
  if [[ -z "$_tp_loc" ]]; then
    _tp_loc="$(locale -a 2>/dev/null | grep -iE 'utf-?8' | head -n1 || true)"
  fi
  if [[ -n "$_tp_loc" ]]; then
    export LC_ALL="$_tp_loc" LANG="$_tp_loc"
  fi
  unset _tp_loc
fi

probe_git_version() {
  local raw major minor
  raw="$(git --version 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    echo "Error: git CLI not available on PATH." >&2
    return 1
  fi
  if [[ ! "$raw" =~ git\ version\ ([0-9]+)\.([0-9]+) ]]; then
    echo "Error: unable to parse git version from '$raw'." >&2
    return 1
  fi
  major="${BASH_REMATCH[1]}"
  minor="${BASH_REMATCH[2]}"
  if (( major < 2 )) || (( major == 2 && minor < 31 )); then
    echo "Error: Git >= 2.31 is required (for --path-format=absolute). Detected: $raw. Please upgrade." >&2
    return 1
  fi
}

# Lowercase drive letter + canonicalize (uses realpath when available).
get_normalized_absolute_path() {
  local p="$1"
  if [[ -z "$p" ]]; then
    echo "Error: get_normalized_absolute_path: empty path." >&2
    return 1
  fi
  # Convert Git Bash /c/foo → C:/foo (still POSIX form for bash handling).
  if [[ "$p" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    p="${BASH_REMATCH[1]}:/${BASH_REMATCH[2]}"
  fi
  local resolved
  if command -v realpath >/dev/null 2>&1; then
    resolved="$(realpath -m "$p" 2>/dev/null || echo "$p")"
  else
    resolved="$p"
  fi
  # Lowercase drive letter for case-insensitive matching on Windows.
  if [[ "$resolved" =~ ^([a-zA-Z])(:.*)$ ]]; then
    local drive="${BASH_REMATCH[1],,}"
    resolved="${drive}${BASH_REMATCH[2]}"
  fi
  echo "$resolved"
}

get_main_worktree() {
  local common_dir
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [[ -z "$common_dir" ]]; then
    echo "Error: not inside a git repository." >&2
    return 1
  fi
  get_normalized_absolute_path "$(dirname "$common_dir")"
}

# Echo the worktree container directory: <main_worktree>/.turbo-plugin/worktrees.
# Single source of truth for the SVN remote worktree container — the 7 SVN scripts
# call this instead of each hardcoding "$ROOT_DIR/$PROJ_NAME.worktrees".
# Optional arg $1: a pre-resolved main worktree path; if omitted it is computed via
# get_main_worktree (which locates the main worktree from any linked worktree).
get_worktrees_dir() {
  local main_worktree="${1:-}"
  if [[ -z "$main_worktree" ]]; then
    main_worktree="$(get_main_worktree)" || return 1
  fi
  echo "$main_worktree/.turbo-plugin/worktrees"
}

test_is_main_worktree() {
  local common_dir top_level parent top
  common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  top_level="$(git rev-parse --path-format=absolute --show-toplevel 2>/dev/null || true)"
  if [[ -z "$common_dir" || -z "$top_level" ]]; then
    return 1
  fi
  parent="$(get_normalized_absolute_path "$(dirname "$common_dir")")"
  top="$(get_normalized_absolute_path "$top_level")"
  [[ "$parent" == "$top" ]]
}

test_is_submodule() {
  local super
  super="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
  [[ -n "$super" ]]
}

# Convert a path (possibly Git Bash /c/foo) to a repo-rooted absolute path.
# Args: <repo_root> <path_value>
resolve_repo_path() {
  local repo_root="$1"
  local path_value="$2"
  if [[ -z "$path_value" ]]; then
    return 0
  fi
  if [[ "$path_value" =~ ^/([a-zA-Z])/(.*)$ ]]; then
    path_value="${BASH_REMATCH[1]^^}:/${BASH_REMATCH[2]}"
  fi
  if [[ "$path_value" =~ ^/ || "$path_value" =~ ^[a-zA-Z]: ]]; then
    if command -v realpath >/dev/null 2>&1; then
      realpath -m "$path_value"
    else
      echo "$path_value"
    fi
    return 0
  fi
  path_value="${path_value#./}"
  if command -v realpath >/dev/null 2>&1; then
    realpath -m "$repo_root/$path_value"
  else
    echo "$repo_root/$path_value"
  fi
}

# Write content to a file as UTF-8 without BOM. Args: <path> <content>
write_utf8_no_bom() {
  local path="$1"
  local content="$2"
  # printf does not emit a BOM; ensure LC_ALL doesn't insert encoding markers.
  LC_ALL=C.UTF-8 printf '%s' "$content" > "$path" 2>/dev/null || printf '%s' "$content" > "$path"
}

# Minimal TOML reader.
# When called with <config_path> only: prints "section.key=value" lines (legacy flat-text output).
# When called with <config_path> <section> <key>: echoes the raw value for that key only,
#   prefixed with __TP_FOUND__: if the key was present (even if empty). Emits nothing if not found.
# Supports [section] headers, key = "string", key = 'string', key = <bool|int|float>,
# # comments, blank lines. Multi-line values / arrays / nested tables are not handled.
read_turbo_plugin_config() {
  local config_path="$1"
  local filter_section="${2:-}"
  local filter_key="${3:-}"
  [[ -f "$config_path" ]] || return 0
  local section=''
  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "${line:0:1}" == '#' ]] && continue
    if [[ "$line" =~ ^\[([^\]]+)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      section="${section#"${section%%[![:space:]]*}"}"
      section="${section%"${section##*[![:space:]]}"}"
      continue
    fi
    if [[ "$line" =~ ^([A-Za-z0-9_-]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      val="${BASH_REMATCH[2]}"
      # strip trailing inline comment if value isn't a quoted string
      if [[ ! "$val" =~ ^[\"\'] ]] && [[ "$val" =~ ^([^#]+)[[:space:]]+\#.* ]]; then
        val="${BASH_REMATCH[1]}"
        val="${val%"${val##*[![:space:]]}"}"
      fi
      if [[ "$val" =~ ^\"(.*)\"$ ]]; then val="${BASH_REMATCH[1]}"
      elif [[ "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"
      fi
      if [[ -n "$filter_key" ]]; then
        # Targeted lookup: emit sentinel-prefixed value when section+key match.
        # Use $filter_key (not section) as the sentinel for "targeted mode" because
        # top-level keys have an empty section name and `-n ""` is false.
        if [[ "$section" == "$filter_section" && "$key" == "$filter_key" ]]; then
          echo "__TP_FOUND__:${val}"
          return 0
        fi
      else
        # Legacy flat-text output (no filter_key passed → dump all)
        echo "${section}.${key}=${val}"
      fi
    fi
  done < "$config_path"
}

# Lookup chain: CLI arg → config.local.toml → config.toml → built-in default
# Args: <repo_root> <section> <key> <cli_value> <default>
# Echoes resolved value (empty string if nothing resolved).
# Uses sentinel __TP_FOUND__: so empty-string config values are distinguished from "not found".
#
# v1.0+ U1: config.local.toml (gitignored, machine-specific) is consulted BEFORE
# config.toml so its key-level values override the canonical version-controlled file.
# This is the bash equivalent of Core.ps1's "read config.toml then merge local on top"
# — semantically identical for the get-one-key API surface.
resolve_config_value() {
  local repo_root="$1"
  local section="$2"
  local key="$3"
  local cli_value="$4"
  local default_value="$5"

  if [[ -n "$cli_value" ]]; then
    echo "$cli_value"
    return 0
  fi
  local config_path="$repo_root/.turbo-plugin/config.toml"
  local config_local_path="$repo_root/.turbo-plugin/config.local.toml"
  local sentinel_line

  # 1. config.local.toml first (highest precedence after CLI arg)
  if [[ -f "$config_local_path" ]]; then
    sentinel_line="$(read_turbo_plugin_config "$config_local_path" "$section" "$key")"
    if [[ "$sentinel_line" == __TP_FOUND__:* ]]; then
      echo "${sentinel_line#__TP_FOUND__:}"
      return 0
    fi
  fi
  # 2. config.toml next (canonical version-controlled file)
  if [[ -f "$config_path" ]]; then
    sentinel_line="$(read_turbo_plugin_config "$config_path" "$section" "$key")"
    if [[ "$sentinel_line" == __TP_FOUND__:* ]]; then
      echo "${sentinel_line#__TP_FOUND__:}"
      return 0
    fi
  fi
  if [[ -n "$default_value" ]]; then
    echo "$default_value"
    return 0
  fi
  echo ''
}
