#!/usr/bin/env bash
# verify-core-identical.sh
#
# Repo-level cross-plugin consistency check (U8 / KTD3). The per-plugin test
# orchestrators only see a single plugin, so they cannot enforce cross-plugin
# invariants. This script does two things:
#
#   1. Byte-identical shared copies: files that are deliberately copied verbatim
#      into multiple test suites (the universal Core.{ps1,sh}, the shared tp-setup
#      base assets, and the vendored shUnit2 -- including the tools/ copy) must NOT
#      drift. Each is compared byte-for-byte (incl BOM and line endings) against the
#      canonical git-svn copy.
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
# Each spec pins the EXPECTED plugin set carrying the file. Pinning (vs a plain
# ">=2 copies present" check) catches a copy DELETED from all-but-one plugin --
# otherwise the lone survivor would silently pass. canonical = turbo-plugin-git-svn.
# Adding a plugin that should carry a shared file means adding it to the spec.
#
# NOTE on what belongs in the universal Core: only helpers every plugin could need
# (config / path / worktree / git-version / UTF-8 write). Anything concern-specific goes in that
# plugin's own concern lib instead -- git-svn's `svn` non-interactive shim lives in
# Common.ps1 / common.sh, and get_worktrees_dir was moved out of Core for the same reason.
# Putting a concern helper in Core forces every other plugin to carry code it never calls, and
# the only way to satisfy this check would be to ship it there.
#
# dotnet-framework is absent from the tp-setup asset specs on purpose: its tp-setup was
# removed (setup is no longer a step for that plugin), so it carries no copy of those assets.
#
# The vendored shUnit2 is here for the same reason as the rest: every test suite carries its own
# copy so it stays self-contained, and nothing else was checking that the copies agree. A suite
# quietly running a different shUnit2 build from its neighbours is exactly the kind of drift that
# shows up as a test behaving differently in one plugin for no visible reason.
shared_specs=(
  "scripts/lib/Core.ps1|turbo-plugin-git-svn turbo-plugin-dotnet-framework turbo-plugin-three-environment-db turbo-plugin-multi-repo-workspace"
  "scripts/lib/core.sh|turbo-plugin-git-svn turbo-plugin-three-environment-db turbo-plugin-multi-repo-workspace"
  "scripts/lib/ps1-delegate.sh|turbo-plugin-git-svn turbo-plugin-dotnet-framework"
  "skills/tp-setup/assets/setup-base.md|turbo-plugin-git-svn turbo-plugin-three-environment-db"
  "skills/tp-setup/assets/claudemd-base-snippet.md|turbo-plugin-git-svn turbo-plugin-three-environment-db"
  "tests/lib/shunit2|turbo-plugin-git-svn turbo-plugin-dotnet-framework turbo-plugin-code-comment turbo-plugin-three-environment-db turbo-plugin-multi-repo-workspace"
)

# Copies that do NOT live under plugins/<name>/, which the spec format above cannot express.
# Format: <path from repo root>|<canonical path from repo root>
extra_copy_specs=(
  "tools/tests/lib/shunit2|plugins/turbo-plugin-git-svn/tests/lib/shunit2"
)

for spec in "${shared_specs[@]}"; do
  rel="${spec%%|*}"
  expected="${spec#*|}"
  canon="plugins/turbo-plugin-git-svn/${rel}"
  if [ ! -f "$canon" ]; then
    err "canonical shared copy missing: '$canon'"
    continue
  fi
  for plug in $expected; do
    c="plugins/${plug}/${rel}"
    if [ ! -f "$c" ]; then
      err "expected shared copy missing: '$c' (pinned in shared_specs)"
      continue
    fi
    [ "$c" = "$canon" ] && continue
    if cmp -s "$canon" "$c"; then
      echo "OK identical: $c == $canon"
    else
      err "shared copy drifted: '$c' differs from canonical '$canon' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy (cp '$canon' '$c'), or if the change is intentional, sync ALL copies."
    fi
  done
done

for spec in "${extra_copy_specs[@]}"; do
  c="${spec%%|*}"
  canon="${spec#*|}"
  if [ ! -f "$canon" ]; then
    err "canonical shared copy missing: '$canon'"
    continue
  fi
  if [ ! -f "$c" ]; then
    err "expected shared copy missing: '$c' (pinned in extra_copy_specs)"
    continue
  fi
  if cmp -s "$canon" "$c"; then
    echo "OK identical: $c == $canon"
  else
    err "shared copy drifted: '$c' differs from canonical '$canon' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy (cp '$canon' '$c'), or if the change is intentional, sync ALL copies."
  fi
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
