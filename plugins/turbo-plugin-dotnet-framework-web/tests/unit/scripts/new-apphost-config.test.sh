#!/usr/bin/env bash
# new-apphost-config.test.sh (shUnit2)
#
# new-apphost-config.sh is a thin delegate to New-ApphostConfig.ps1 (lib/ps1-delegate.sh).
# Bash coverage focuses on:
#   1. delegate dispatch: script exists and is a delegate to the expected .ps1.
#   2. end-to-end generation through the bash entry: a hand-written csproj in a throwaway git repo
#      produces .turbo-plugin/applicationhost.config whose site carries the PLAIN project name and
#      a physicalPath placeholder -- the canonical shape Start-Iis looks up and the shape that is
#      safe to commit (the identity-hashed name belongs to the per-launch temp copy only).
#
# The exhaustive matrix (https binding, classic pipeline, existing-file skip, missing IIS settings)
# lives in New-ApphostConfig.test.ps1; re-running all of it through the delegate would double the
# runtime without adding signal.
#
# ps1-delegate needs PowerShell; on a runner without it the per-test gate SKIPs.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
NAC="$PLUGIN_ROOT/scripts/new-apphost-config.sh"
SHUNIT2="$PLUGIN_ROOT/tests/lib/shunit2"

oneTimeSetUp() {
    HAS_PS=0
    if command -v powershell >/dev/null 2>&1 || command -v pwsh >/dev/null 2>&1; then HAS_PS=1; fi
}

setUp() {
    TMPDIR_CASE="$(mktemp -d -t turbo-new-apphost-XXXXXX)"
}
tearDown() {
    [ -n "${TMPDIR_CASE:-}" ] && rm -rf "$TMPDIR_CASE" 2>/dev/null || true
}

# Case 1: the delegate exists and points at the matching .ps1 (no PowerShell needed).
test_script_exists() {
    assertTrue "new-apphost-config.sh exists at $NAC" "[ -f '$NAC' ]"
    if grep -q 'New-ApphostConfig' "$NAC"; then
        assertTrue 'delegates to New-ApphostConfig' 0
    else
        fail "delegate does not reference New-ApphostConfig: $(cat "$NAC")"
    fi
}

# Case 2: generation through the bash entry produces a canonical-shaped site.
test_generates_canonical_shaped_site() {
    if [ "$HAS_PS" -ne 1 ]; then startSkipping; return 0; fi
    local root out rc cfg
    root="$TMPDIR_CASE/proj"
    mkdir -p "$root"
    cat > "$root/HelloApp.csproj" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <AssemblyName>HelloApp</AssemblyName>
    <UseIISExpress>true</UseIISExpress>
    <IISUrl>http://localhost:5000/</IISUrl>
  </PropertyGroup>
</Project>
EOF
    git -C "$root" init -q >/dev/null 2>&1 || { startSkipping; return 0; }
    git -C "$root" config user.email 'test@example.invalid' >/dev/null 2>&1
    git -C "$root" config user.name 'Test' >/dev/null 2>&1
    git -C "$root" add -A >/dev/null 2>&1
    git -C "$root" -c commit.gpgsign=false commit -q -m fixture >/dev/null 2>&1

    out="$(cd "$root" && bash "$NAC" -Project HelloApp.csproj 2>&1)"; rc=$?
    assertEquals "generation exits 0 (out: $out)" 0 "$rc"

    cfg="$root/.turbo-plugin/applicationhost.config"
    assertTrue 'canonical applicationhost.config created' "[ -f '$cfg' ]"
    # Plain project name, NOT the identity-hashed runtime name.
    if grep -q 'site name="HelloApp"' "$cfg"; then
        assertTrue 'site uses the plain project name' 0
    else
        fail "site not named after the project: $(grep -o 'site name=\"[^\"]*\"' "$cfg" | head -3)"
    fi
    if grep -q '__TURBO_PLUGIN_PHYSICAL_PATH__' "$cfg"; then
        assertTrue 'physicalPath is a placeholder (no machine path committed)' 0
    else
        fail 'physicalPath placeholder missing'
    fi
    if grep -q 'bindingInformation="\*:5000:localhost"' "$cfg"; then
        assertTrue 'http binding taken from <IISUrl>' 0
    else
        fail "binding not derived from IISUrl: $(grep -o 'bindingInformation=\"[^\"]*\"' "$cfg" | head -3)"
    fi
}

# shellcheck disable=SC1090
. "$SHUNIT2"
