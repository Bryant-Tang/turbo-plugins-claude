#!/usr/bin/env bash
# Sourced by other scripts. Exports: REPO_ROOT, PROJECT_FILE, IIS_URL,
# IIS_SCHEME, IIS_PORT, SITE_ROOT, IIS_EXPRESS_PATH,
# APPLICATIONHOST_CONFIG_FILE, IIS_CONFIG_SITE_NAME
#
# Requires GNU grep (grep -P / -oiP). Not portable to macOS or Alpine.
# On Git Bash for Windows this is provided by the bundled GNU grep.

resolve_repo_path() {
  local repo_root="$1"
  local path_value="$2"
  if [[ "$path_value" =~ ^[A-Za-z]: ]] || [[ "$path_value" = /* ]]; then
    cygpath -u "$path_value"
  else
    echo "$repo_root/${path_value#./}"
  fi
}

resolve_iis_settings() {
  local script_dir="${1:-$SCRIPT_DIR}"
  REPO_ROOT="$(pwd)"

  if [[ -z "${BUILD_PROJECT_PATH:-}" ]]; then
    echo "Missing BUILD_PROJECT_PATH environment variable" >&2
    return 1
  fi

  PROJECT_FILE="$(resolve_repo_path "$REPO_ROOT" "$BUILD_PROJECT_PATH")"

  if [[ ! -f "$PROJECT_FILE" ]]; then
    echo "Configured project file does not exist: $PROJECT_FILE" >&2
    return 1
  fi

  IIS_URL="$(grep -oiP '(?<=<IISUrl>)[^<]+' "$PROJECT_FILE" | head -1 | tr -d '[:space:]')"

  if [[ -z "$IIS_URL" ]]; then
    echo "Missing IISUrl in project file: $PROJECT_FILE" >&2
    return 1
  fi

  if [[ ! "$IIS_URL" =~ ^https?:// ]]; then
    echo "Invalid IISUrl format (expected http:// or https://): $IIS_URL" >&2
    return 1
  fi

  IIS_SCHEME="$(echo "$IIS_URL" | grep -oP '^[a-z]+')"
  IIS_PORT="$(echo "$IIS_URL" | grep -oP '(?<=:)\d+(?=/|$)' | head -1)"

  if [[ -z "$IIS_SCHEME" ]]; then
    echo "Unable to parse scheme from IISUrl: $IIS_URL" >&2
    return 1
  fi

  if [[ -z "$IIS_PORT" ]]; then
    echo "Unable to parse port from IISUrl: $IIS_URL" >&2
    return 1
  fi

  SITE_ROOT="$(dirname "$PROJECT_FILE")"
  IIS_EXPRESS_PATH=""
  if [[ -n "${RUN_IIS_EXPRESS_PATH:-}" ]]; then
    IIS_EXPRESS_PATH="$(resolve_repo_path "$REPO_ROOT" "$RUN_IIS_EXPRESS_PATH")"
  fi
  APPLICATIONHOST_CONFIG_FILE=""
  IIS_CONFIG_SITE_NAME=""

  if [[ -n "${RUN_IIS_APPLICATIONHOST_CONFIG_PATH:-}" ]]; then
    APPLICATIONHOST_CONFIG_FILE="$(resolve_repo_path "$REPO_ROOT" "$RUN_IIS_APPLICATIONHOST_CONFIG_PATH")"

    if [[ ! -f "$APPLICATIONHOST_CONFIG_FILE" ]]; then
      echo "Configured applicationhost.config does not exist: $APPLICATIONHOST_CONFIG_FILE" >&2
      return 1
    fi

    local project_dir_name
    project_dir_name="$(basename "$SITE_ROOT")"

    # Match site by project folder name first, then fall back to port binding
    IIS_CONFIG_SITE_NAME="$(awk '
      /<site / { match($0, /name="([^"]+)"/, arr); current = arr[1] }
      $0 ~ ("name=\"" project_dir "\"") { found = current }
      END { if (found) print found }
    ' project_dir="$project_dir_name" "$APPLICATIONHOST_CONFIG_FILE" || true)"

    if [[ -z "$IIS_CONFIG_SITE_NAME" ]]; then
      IIS_CONFIG_SITE_NAME="$(awk '
        /<site / { match($0, /name="([^"]+)"/, arr); current = arr[1] }
        /bindingInformation="[^"]*:'"$IIS_PORT"':/ { if (current) { print current; exit } }
      ' "$APPLICATIONHOST_CONFIG_FILE" || true)"
    fi

    if [[ -z "$IIS_CONFIG_SITE_NAME" ]]; then
      echo "Unable to find a matching IIS site in applicationhost.config: $APPLICATIONHOST_CONFIG_FILE" >&2
      return 1
    fi
  fi
}
