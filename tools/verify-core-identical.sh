#!/usr/bin/env bash
# verify-core-identical.sh
#
# Repo-level cross-plugin consistency check (U8 / KTD3). The per-plugin test
# orchestrators only see a single plugin, so they cannot enforce cross-plugin
# invariants. This script does two things:
#
#   1. Byte-identical shared copies: files that are deliberately copied verbatim
#      into multiple plugins (the universal Core.{ps1,sh} + the shared tp-setup
#      base assets) must NOT drift. Each is compared byte-for-byte (incl BOM and
#      line endings) against the canonical git-svn copy.
#   2. Marketplace installability: every plugin in .claude-plugin/marketplace.json
#      must point at a real dir that has .claude-plugin/plugin.json and a tests/
#      orchestrator entry.
#
# locale-safe by design: NO `grep -P` (PCRE refuses to run in non-UTF-8 locales
# such as the zh-TW Git Bash default). Byte comparison uses `cmp` (exact). Source
# extraction uses `grep -oE` (ERE) + `sed -E`.
#
# Exit 0 = all consistent; exit 1 = drift or an uninstallable marketplace entry.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

# ── 1. byte-identical shared copies ──────────────────────────────────────────
# Each relpath is compared across every plugin that contains it; canonical = the
# turbo-plugin-git-svn copy when present, else the first one found.
shared_relpaths=(
  "scripts/lib/Core.ps1"
  "scripts/lib/core.sh"
  "skills/tp-setup/assets/setup-base.md"
  "skills/tp-setup/assets/claudemd-base-snippet.md"
)

for rel in "${shared_relpaths[@]}"; do
  copies=()
  for d in plugins/*/; do
    [ -f "${d}${rel}" ] && copies+=("${d}${rel}")
  done
  if [ "${#copies[@]}" -lt 2 ]; then
    echo "skip (fewer than 2 copies): $rel"
    continue
  fi
  canon=""
  for c in "${copies[@]}"; do
    case "$c" in
      plugins/turbo-plugin-git-svn/*) canon="$c" ;;
    esac
  done
  [ -z "$canon" ] && canon="${copies[0]}"
  for c in "${copies[@]}"; do
    [ "$c" = "$canon" ] && continue
    if cmp -s "$canon" "$c"; then
      echo "OK identical: $c == $canon"
    else
      err "shared copy drifted: '$c' differs from canonical '$canon' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy (cp '$canon' '$c'), or if the change is intentional, sync ALL copies."
    fi
  done
done

# ── 2. marketplace installability ────────────────────────────────────────────
mp=".claude-plugin/marketplace.json"
if [ ! -f "$mp" ]; then
  err "marketplace.json not found at $mp"
else
  # Each entry has  "source": "./plugins/<dir>"  on its own line. ERE only.
  sources="$(grep -oE '"source"[[:space:]]*:[[:space:]]*"[^"]*"' "$mp" \
    | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/')"
  if [ -z "$sources" ]; then
    err "marketplace.json has no \"source\" entries"
  fi
  while IFS= read -r src; do
    [ -z "$src" ] && continue
    dir="${src#./}"
    if [ ! -d "$dir" ]; then
      err "marketplace source dir missing: $src"
      continue
    fi
    [ -f "$dir/.claude-plugin/plugin.json" ] \
      || err "marketplace source '$src' missing .claude-plugin/plugin.json"
    if [ ! -f "$dir/tests/Invoke-ScriptTests.ps1" ] && [ ! -f "$dir/tests/invoke-script-tests.sh" ]; then
      err "marketplace source '$src' missing tests/ orchestrator entry (Invoke-ScriptTests.ps1 / invoke-script-tests.sh)"
    fi
  done <<< "$sources"
fi

if [ "$fail" -ne 0 ]; then
  echo "verify-core-identical: FAILED" >&2
  exit 1
fi
echo "verify-core-identical: OK (shared copies identical; marketplace installable)"
exit 0
