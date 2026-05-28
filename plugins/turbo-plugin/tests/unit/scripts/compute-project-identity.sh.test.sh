#!/usr/bin/env bash
# Phase 1 — bash sibling for compute-project-identity.sh
# 1-line delegate to .ps1, so cross-shell parity is essentially "does the bash entry
# launch the ps1?". We exercise the .sh script directly under a sandboxed workspace.

set -uo pipefail  # not -e: we capture exit codes ourselves

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd)"
SCRIPT_UNDER_TEST="$PLUGIN_ROOT/scripts/compute-project-identity.sh"

passed=0
failed=0

new_sandbox() {
    local purpose="$1"
    local guid
    guid="$(uuidgen 2>/dev/null || powershell -NoProfile -Command '[guid]::NewGuid().ToString("N").Substring(0,12)' | tr -d '\r')"
    local dir="/c/Turbo/turbo-plugin-test-${purpose}-${guid}"
    mkdir -p "$dir"
    echo "$dir"
}

remove_sandbox() {
    local dir="$1"
    [[ -z "$dir" ]] && return
    [[ -d "$dir" ]] || return
    # clear ReadOnly via attrib (may fail silently — best effort)
    powershell -NoProfile -Command "
        Get-ChildItem -LiteralPath '$dir' -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { \$_.Attributes = 'Normal' } catch { }
        }
        Remove-Item -LiteralPath '$dir' -Recurse -Force -ErrorAction SilentlyContinue
    " >/dev/null 2>&1 || true
}

write_csproj() {
    local dir="$1"
    cat > "$dir/HelloApp.csproj" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<Project ToolsVersion="15.0" DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <PropertyGroup>
    <ProjectGuid>{00000000-1111-2222-3333-444444444444}</ProjectGuid>
    <OutputType>Library</OutputType>
    <RootNamespace>HelloApp</RootNamespace>
    <AssemblyName>HelloApp</AssemblyName>
    <TargetFrameworkVersion>v4.7.2</TargetFrameworkVersion>
  </PropertyGroup>
  <ProjectExtensions>
    <VisualStudio>
      <FlavorProperties GUID="{349c5851-65df-11da-9384-00065b846f21}">
        <WebProjectProperties>
          <IISUrl>http://localhost:5000/</IISUrl>
        </WebProjectProperties>
      </FlavorProperties>
    </VisualStudio>
  </ProjectExtensions>
</Project>
EOF
}

init_git_repo() {
    local dir="$1"
    (
        cd "$dir" && \
        git init -q && \
        git config user.email 'test@example.invalid' && \
        git config user.name 'Test' && \
        git add -A && \
        git -c commit.gpgsign=false commit -q -m 'fixture init'
    ) >/dev/null 2>&1
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  [PASS] $name"
        ((passed++))
    else
        echo "  [FAIL] $name (expected='$expected' actual='$actual')"
        ((failed++))
    fi
}

assert_match() {
    local name="$1" pattern="$2" text="$3"
    if echo "$text" | grep -Eq "$pattern"; then
        echo "  [PASS] $name"
        ((passed++))
    else
        echo "  [FAIL] $name (pattern='$pattern' text-head='${text:0:200}')"
        ((failed++))
    fi
}

# ─── Case 1: happy path ─────────────────────────────────────────────────────
sb1="$(new_sandbox 'cpi-sh-happy')"
write_csproj "$sb1"
init_git_repo "$sb1"
cd "$sb1"
r1_out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
r1_exit=$?
cd "$PLUGIN_ROOT"
assert_eq 'case1: exit 0' '0' "$r1_exit"
assert_match 'case1: stdout has PROJECT' 'PROJECT=' "$r1_out"
assert_match 'case1: IDENTITY_HASH 8-hex' 'IDENTITY_HASH=[0-9a-f]{8}' "$r1_out"
assert_match 'case1: SITE_NAME shape' 'SITE_NAME=HelloApp-[0-9a-f]{8}' "$r1_out"

hash1=$(echo "$r1_out" | grep -Eo 'IDENTITY_HASH=[0-9a-f]{8}' | head -1 | sed 's/IDENTITY_HASH=//')

# ─── Case 2: SKILL-entry consistency (re-invoke same dir) ───────────────────
cd "$sb1"
r2_out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
r2_exit=$?
cd "$PLUGIN_ROOT"
hash2=$(echo "$r2_out" | grep -Eo 'IDENTITY_HASH=[0-9a-f]{8}' | head -1 | sed 's/IDENTITY_HASH=//')
assert_eq 'case2: SKILL-entry exit 0' '0' "$r2_exit"
assert_eq 'case2: hash deterministic' "$hash1" "$hash2"

# ─── Case 3: 中文 path ──────────────────────────────────────────────────────
sb2="$(new_sandbox 'cpi-sh-zh')"
zh_sub="$sb2/中文資料夾"
mkdir -p "$zh_sub"
write_csproj "$zh_sub"
init_git_repo "$zh_sub"
cd "$zh_sub"
r3_out="$(bash "$SCRIPT_UNDER_TEST" 2>/dev/null)"
r3_exit=$?
cd "$PLUGIN_ROOT"
assert_eq 'case3: 中文 path exit 0' '0' "$r3_exit"
assert_match 'case3: 中文 path IDENTITY_HASH 8-hex' 'IDENTITY_HASH=[0-9a-f]{8}' "$r3_out"
hash3=$(echo "$r3_out" | grep -Eo 'IDENTITY_HASH=[0-9a-f]{8}' | head -1 | sed 's/IDENTITY_HASH=//')
if [[ -n "$hash3" && "$hash3" != "$hash1" ]]; then
    echo "  [PASS] case3: 中文 path hash differs from ASCII"
    ((passed++))
else
    echo "  [FAIL] case3: 中文 path hash should differ (got '$hash3' vs '$hash1')"
    ((failed++))
fi

remove_sandbox "$sb1"
remove_sandbox "$sb2"

echo ""
echo "compute-project-identity.sh.test: passed=$passed failed=$failed"
if (( failed > 0 )); then
    echo "FAIL: see above"
    exit 1
fi
echo "OK: all bash cases pass"
exit 0
