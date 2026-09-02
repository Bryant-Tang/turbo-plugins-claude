#!/usr/bin/env bash
# turbo-plugin-three-environment-db: rename ONE database environment.
#
#   rename-db-environment.sh <from> <to> [--apply] [--sql-root <path>] [--root <path>]
#
# Renames <sql_root>/<from>/ to <sql_root>/<to>/ AND rewrites the environment name inside every
# .sql file under it -- the header fields ("目標環境", "基線來源環境", "檔案落點", and the
# per-environment path list) carry the name as text, so renaming only the directory leaves every
# file claiming it belongs somewhere it no longer is. Those headers are what tells a reader which
# environment a baseline came from, so a half-done rename is worse than none.
#
# DRY RUN BY DEFAULT. Nothing is touched until --apply. A real project has hundreds of these files
# and the damage from a wrong match is silent, so the default has to be the harmless one.
#
# The .ps1 peer (Rename-DbEnvironment.ps1) is a separate native implementation with the same
# behaviour; both are driven by their own test suite.
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/core.sh
. "${SCRIPT_DIR}/lib/core.sh"

FROM=''
TO=''
APPLY=0
SQL_ROOT_OPT=''
ROOT=''

die() { echo "rename-db-environment: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'USAGE'
usage: rename-db-environment.sh <from> <to> [--apply] [--sql-root <path>] [--root <path>]

  <from>        current environment folder name (e.g. local-db)
  <to>          new environment folder name (e.g. dev-db)
  --apply       actually make the changes (default: dry run, print only)
  --sql-root    override the SQL root instead of reading [db] sql_root
  --root        workspace root (default: current directory)
USAGE
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --sql-root) [[ $# -ge 2 ]] || die "--sql-root needs a value"; SQL_ROOT_OPT="$2"; shift 2 ;;
    --root) [[ $# -ge 2 ]] || die "--root needs a value"; ROOT="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*) die "unknown option: $1" ;;
    *)
      if [[ -z "$FROM" ]]; then FROM="$1"
      elif [[ -z "$TO" ]]; then TO="$1"
      else die "unexpected argument: $1"
      fi
      shift ;;
  esac
done

[[ -n "$FROM" && -n "$TO" ]] || usage

# Restrict both names to what a folder name may safely be. This is not only hygiene: the names go
# into a regex and into a sed replacement, where '&', '\' and '.' all mean something other than
# themselves. Refusing the characters outright is simpler than escaping them everywhere, and a
# database environment has no reason to need them.
for n in "$FROM" "$TO"; do
  [[ "$n" =~ ^[A-Za-z0-9._-]+$ ]] || die "environment name may only contain letters, digits, '.', '_' and '-': '$n'"
  [[ "$n" == .* || "$n" == *. ]] && die "environment name must not start or end with '.': '$n'"
done
[[ "$FROM" != "$TO" ]] || die "<from> and <to> are the same: '$FROM'"

if [[ -z "$ROOT" ]]; then ROOT="$(pwd)"; fi
[[ -d "$ROOT" ]] || die "workspace root is not a directory: $ROOT"
ROOT="$(cd -- "$ROOT" && pwd)"

CONFIG_PATH="${ROOT}/.turbo-plugin/config.toml"

# Resolve <sql_root> the same way the skill does: [db] sql_root, else the default.
if [[ -n "$SQL_ROOT_OPT" ]]; then
  SQL_ROOT_REL="$SQL_ROOT_OPT"
else
  SQL_ROOT_REL=''
  if [[ -f "$CONFIG_PATH" ]]; then
    found="$(read_turbo_plugin_config "$CONFIG_PATH" 'db' 'sql_root')"
    if [[ "$found" == __TP_FOUND__:* ]]; then
      SQL_ROOT_REL="${found#__TP_FOUND__:}"
    fi
  fi
  [[ -n "$SQL_ROOT_REL" ]] || SQL_ROOT_REL='.turbo-plugin/sql'
fi
SQL_ROOT_REL="${SQL_ROOT_REL%/}"

SQL_ROOT="${ROOT}/${SQL_ROOT_REL}"
OLD_DIR="${SQL_ROOT}/${FROM}"
NEW_DIR="${SQL_ROOT}/${TO}"

[[ -d "$SQL_ROOT" ]] || die "SQL root does not exist: $SQL_ROOT"
[[ -d "$OLD_DIR" ]]  || die "no such environment folder: $OLD_DIR"
[[ -e "$NEW_DIR" ]]  && die "target already exists, refusing to merge two environments: $NEW_DIR"

# Word boundaries so a rename like test -> test-db cannot turn an existing 'test-db' into
# 'test-db-db'. The name charset above is exactly what counts as "inside a word" here.
BOUND_L='(^|[^A-Za-z0-9._-])'
BOUND_R='([^A-Za-z0-9._-]|$)'
FROM_RE="${FROM//./\\.}"
MATCH_RE="${BOUND_L}${FROM_RE}${BOUND_R}"

mapfile -t SQL_FILES < <(find "$OLD_DIR" -type f -name '*.sql' | LC_ALL=C sort)

hit_files=0
hit_lines=0
declare -a HIT_REPORT=()
for f in "${SQL_FILES[@]:-}"; do
  [[ -n "$f" ]] || continue
  n="$(grep -cE "$MATCH_RE" "$f" 2>/dev/null || true)"
  [[ -n "$n" ]] || n=0
  if [[ "$n" -gt 0 ]]; then
    hit_files=$((hit_files + 1))
    hit_lines=$((hit_lines + n))
    HIT_REPORT+=("    ${f#$ROOT/}  (${n} 行)")
  fi
done

# The environments line in config.toml, if there is an uncommented one that mentions <from>.
config_line=''
if [[ -f "$CONFIG_PATH" ]]; then
  config_line="$(grep -nE "^[[:space:]]*environments[[:space:]]*=" "$CONFIG_PATH" 2>/dev/null | head -1 || true)"
fi
config_needs_update=0
if [[ -n "$config_line" ]] && echo "$config_line" | grep -qE "$MATCH_RE"; then
  config_needs_update=1
fi

echo "rename-db-environment: ${FROM} -> ${TO}"
echo "  工作區根 : ${ROOT}"
echo "  SQL root : ${SQL_ROOT_REL}"
echo
echo "  [1] 目錄改名"
echo "      ${OLD_DIR#$ROOT/}  ->  ${NEW_DIR#$ROOT/}"
echo "  [2] .sql 檔頭改寫: ${hit_files} 個檔 / ${hit_lines} 行 (掃過 ${#SQL_FILES[@]} 個 .sql)"
for line in "${HIT_REPORT[@]:-}"; do
  [[ -n "$line" ]] && echo "$line"
done
echo "  [3] config.toml 的 environments"
if [[ "$config_needs_update" -eq 1 ]]; then
  echo "      會把那一行裡的 ${FROM} 換成 ${TO}"
elif [[ -n "$config_line" ]]; then
  echo "      有 environments 但沒提到 ${FROM} — 不動它"
else
  echo "      沒有未註解的 environments —— 改完請自己加一行,否則 tp-db-management 會看到"
  echo "      「磁碟上有、清單裡沒有」而停下來:"
  echo "        environments = [\"${TO}\", ...]"
fi

if [[ "$APPLY" -ne 1 ]]; then
  echo
  echo "  這是 dry run,什麼都沒有改。確認無誤後加 --apply。"
  exit 0
fi

echo
echo "  套用中..."

# Content first, directory second: rewriting after the move would mean recomputing every path.
for f in "${SQL_FILES[@]:-}"; do
  [[ -n "$f" ]] || continue
  grep -qE "$MATCH_RE" "$f" 2>/dev/null || continue
  tmp="${f}.tp-rename-tmp"
  # Twice: a single pass consumes the boundary character, so two matches sharing one separator
  # (".../local-db/local-db/...") would leave the second behind. The second pass is a no-op
  # whenever the first was enough.
  sed -E "s/${MATCH_RE}/\1${TO}\2/g" "$f" > "$tmp" || die "failed to rewrite $f"
  sed -E "s/${MATCH_RE}/\1${TO}\2/g" "$tmp" > "${tmp}.2" || die "failed to rewrite $f"
  mv -f "${tmp}.2" "$f" || die "failed to replace $f"
  rm -f "$tmp"
done

moved_with_git=0
if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if git -C "$ROOT" mv "$OLD_DIR" "$NEW_DIR" >/dev/null 2>&1; then
    moved_with_git=1
  fi
fi
if [[ "$moved_with_git" -ne 1 ]]; then
  mv "$OLD_DIR" "$NEW_DIR" || die "failed to rename $OLD_DIR"
fi

if [[ "$config_needs_update" -eq 1 ]]; then
  tmp="${CONFIG_PATH}.tp-rename-tmp"
  # Twice, for the same reason as the content rewrite above: two adjacent matches sharing one
  # boundary character survive a single pass. In an environments array that is `["x","x"]` with
  # no space after the comma. The .ps1 peer does the same, and "the two behave identically" is
  # the whole point of shipping a pair.
  sed -E "/^[[:space:]]*environments[[:space:]]*=/ s/${MATCH_RE}/\1${TO}\2/g" "$CONFIG_PATH" > "$tmp" \
    || die "failed to update $CONFIG_PATH"
  sed -E "/^[[:space:]]*environments[[:space:]]*=/ s/${MATCH_RE}/\1${TO}\2/g" "$tmp" > "${tmp}.2" \
    || die "failed to update $CONFIG_PATH"
  mv -f "${tmp}.2" "$CONFIG_PATH" || die "failed to replace $CONFIG_PATH"
  rm -f "$tmp"
fi

echo "  完成。"
echo "    目錄改名  : 是$([[ "$moved_with_git" -eq 1 ]] && echo '(git mv)' || echo '(檔案系統)')"
echo "    檔案改寫  : ${hit_files} 個"
echo "    config    : $([[ "$config_needs_update" -eq 1 ]] && echo '已更新' || echo '未動')"
echo
echo "  接下來:檢查 git diff 再 commit。基線檔頭是判斷「這份基線來自哪個環境」的唯一線索,"
echo "  值得看過一遍。"
exit 0
