#!/usr/bin/env bash
# turbo-plugin shared bash helpers — source via:
#   source "${CLAUDE_PLUGIN_ROOT}/scripts/lib/common.sh"

set -euo pipefail

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
    echo "Error: turbo-plugin requires Git >= 2.31 (for --path-format=absolute). Detected: $raw. Please upgrade." >&2
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

# Args: <branch_name> <worktrees_dir>
# Echoes "<name>|<branch>|<path>".
resolve_remote_worktree() {
  local branch_name="$1"
  local worktrees_dir="$2"
  if [[ "$branch_name" == 'main' ]]; then
    echo "remote-main|remote/main|$worktrees_dir/remote-main"
    return 0
  fi
  if [[ "$branch_name" =~ ^test-([0-9]+)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    echo "remote-test-$n|remote/test-$n|$worktrees_dir/remote-test-$n"
    return 0
  fi
  echo "Error: unsupported branch '$branch_name'. Only 'main' and 'test-<n>' branches can be synced from SVN." >&2
  return 1
}

# Write content to a file as UTF-8 without BOM. Args: <path> <content>
write_utf8_no_bom() {
  local path="$1"
  local content="$2"
  # printf does not emit a BOM; ensure LC_ALL doesn't insert encoding markers.
  LC_ALL=C.UTF-8 printf '%s' "$content" > "$path" 2>/dev/null || printf '%s' "$content" > "$path"
}

# v0.2.7+ F-U3.9 fix: Removed bash get_project_identity_hash() function. It was dead
# code (no caller in production — all SVN scripts are native bash; all IIS/build scripts
# are ps1-delegate so hash computation always happens on PS side via Get-ProjectIdentityHash).
# The bash version was producing DIFFERENT hashes than PS (due to get_normalized_absolute_path
# using forward slashes vs PS using backslashes in the sha256 input), which would cause
# subtle cross-language inconsistency if any future caller relied on this function. Better
# to remove than to maintain a divergent implementation. Restore + slash-normalize if a
# future bash caller needs project identity hashing.

# Compute IIS Express site name from csproj path and identity hash.
# Args: <csproj_path> <identity_hash>
format_iis_express_site_name() {
  local csproj="$1"
  local hash="$2"
  local stem
  stem="$(basename "$csproj" .csproj)"
  echo "${stem}-${hash}"
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
        # v0.2.7+ F-U3.11 fix: previously checked `-n "$filter_section" && -n "$filter_key"`
        # which meant schema_version (top-level, section="") never hit the sentinel branch,
        # so check_turbo_plugin_config_schema never emitted the schema_version warning on bash side.
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

# Module-scope guard so the schema_version mismatch warning is emitted only ONCE per process,
# regardless of how many resolve_config_value calls a single script makes.
_TP_SCHEMA_WARNED="${_TP_SCHEMA_WARNED:-false}"

# Emit a single stderr warning if the top-level `schema_version` key in config.toml is present
# and != 1. Absent schema_version is treated as v1 (no warning).
check_turbo_plugin_config_schema() {
  local config_path="$1"
  if [[ "$_TP_SCHEMA_WARNED" == "true" ]]; then return 0; fi
  [[ -f "$config_path" ]] || return 0
  # The top-level key is reported by read_turbo_plugin_config with an empty section name (".schema_version=...").
  local schema_line
  schema_line="$(read_turbo_plugin_config "$config_path" '' 'schema_version' 2>/dev/null || true)"
  if [[ "$schema_line" == __TP_FOUND__:* ]]; then
    local version="${schema_line#__TP_FOUND__:}"
    if [[ "$version" != "1" ]]; then
      echo "turbo-plugin: .turbo-plugin/config.toml schema_version=$version is not recognized (expected 1); some settings may be ignored." >&2
      _TP_SCHEMA_WARNED=true
      export _TP_SCHEMA_WARNED
    fi
  fi
}

# Lookup chain: CLI arg → config.toml → built-in default
# Args: <repo_root> <section> <key> <cli_value> <default>
# Echoes resolved value (empty string if nothing resolved).
# Uses sentinel __TP_FOUND__: so empty-string config values are distinguished from "not found".
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
  if [[ -f "$config_path" ]]; then
    check_turbo_plugin_config_schema "$config_path"
    local sentinel_line
    sentinel_line="$(read_turbo_plugin_config "$config_path" "$section" "$key")"
    if [[ "$sentinel_line" == __TP_FOUND__:* ]]; then
      # Strip the sentinel prefix; the remainder is the value (may be empty)
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
