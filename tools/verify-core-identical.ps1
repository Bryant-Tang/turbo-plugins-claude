# verify-core-identical.ps1
#
# Repo-level cross-plugin consistency check (U8 / KTD3) -- PowerShell sibling of
# verify-core-identical.sh, for local Windows use. Same two checks:
#
#   1. Byte-identical shared copies: files copied verbatim into multiple test suites
#      (universal Core.{ps1,sh}, shared tp-setup base assets, and the vendored shUnit2
#      -- including the tools/ copy) must NOT drift. Compared byte-for-byte (incl BOM
#      and line endings) vs the canonical turbo-plugin-git-svn copy.
#   2. Marketplace installability: every plugin in marketplace.json points at a
#      real dir with .claude-plugin/plugin.json and a tests/ orchestrator entry.
#
# Pure ASCII (no BOM needed). JSON read via [IO.File]::ReadAllText UTF-8 (PS 5.1
# Get-Content mis-decodes UTF-8 as the system codepage on zh-TW Windows).
#
# Exit 0 = consistent; exit 1 = drift or an uninstallable marketplace entry.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $repoRoot

$failures = New-Object System.Collections.Generic.List[string]

function Test-FilesIdentical {
    param([string]$A, [string]$B)
    $ba = [System.IO.File]::ReadAllBytes($A)
    $bb = [System.IO.File]::ReadAllBytes($B)
    if ($ba.Length -ne $bb.Length) { return $false }
    for ($i = 0; $i -lt $ba.Length; $i++) {
        if ($ba[$i] -ne $bb[$i]) { return $false }
    }
    return $true
}

# --- 1. byte-identical shared copies -----------------------------------------
# Each spec pins the EXPECTED plugin set carrying the file. Pinning (vs a plain
# ">=2 copies present" check) catches a copy DELETED from all-but-one plugin --
# otherwise the lone survivor would silently pass. Canonical = turbo-plugin-git-svn.
# Adding a plugin that should carry a shared file means adding it here.
# dotnet-framework is absent from the tp-setup asset specs on purpose: its tp-setup was
# removed (setup is no longer a step for that plugin), so it carries no copy of those assets.
# Keep this list byte-for-byte in sync with the sh sibling's shared_specs.
#
# The vendored shUnit2 is here for the same reason as the rest: every test suite carries its own
# copy so it stays self-contained, and nothing else was checking that the copies agree. A suite
# quietly running a different shUnit2 build from its neighbours is exactly the kind of drift that
# shows up as a test behaving differently in one plugin for no visible reason.
$sharedSpecs = @(
    @{ Rel = 'scripts/lib/Core.ps1';                            Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-dotnet-framework', 'turbo-plugin-three-environment-db', 'turbo-plugin-multi-repo-workspace') },
    @{ Rel = 'scripts/lib/core.sh';                             Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-three-environment-db', 'turbo-plugin-multi-repo-workspace') },
    @{ Rel = 'scripts/lib/ps1-delegate.sh';                     Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-dotnet-framework') },
    @{ Rel = 'skills/tp-setup/assets/setup-base.md';            Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-three-environment-db') },
    @{ Rel = 'skills/tp-setup/assets/claudemd-base-snippet.md'; Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-three-environment-db') },
    @{ Rel = 'tests/lib/shunit2';                               Plugins = @('turbo-plugin-git-svn', 'turbo-plugin-dotnet-framework', 'turbo-plugin-code-comment', 'turbo-plugin-three-environment-db', 'turbo-plugin-multi-repo-workspace') }
)

# Copies that do NOT live under plugins/<name>/, which the spec format above cannot express.
# Keep in sync with the sh sibling's extra_copy_specs.
$extraCopySpecs = @(
    @{ Copy = 'tools/tests/lib/shunit2'; Canonical = 'plugins/turbo-plugin-git-svn/tests/lib/shunit2' }
)

foreach ($spec in $sharedSpecs) {
    $rel = $spec.Rel
    $relNative = $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $canonPath = [System.IO.Path]::Combine($repoRoot, 'plugins', 'turbo-plugin-git-svn', $relNative)
    if (-not (Test-Path -LiteralPath $canonPath -PathType Leaf)) {
        $failures.Add("canonical shared copy missing: 'plugins/turbo-plugin-git-svn/$rel'")
        continue
    }
    foreach ($plug in $spec.Plugins) {
        $p = [System.IO.Path]::Combine($repoRoot, 'plugins', $plug, $relNative)
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) {
            $failures.Add("expected shared copy missing: 'plugins/$plug/$rel' (pinned in sharedSpecs)")
            continue
        }
        if ($p -eq $canonPath) { continue }
        if (Test-FilesIdentical -A $canonPath -B $p) {
            Write-Output "OK identical: plugins/$plug/$rel == plugins/turbo-plugin-git-svn/$rel"
        } else {
            $failures.Add("shared copy drifted: 'plugins/$plug/$rel' differs from canonical 'plugins/turbo-plugin-git-svn/$rel' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy, or if intentional, sync ALL copies.")
        }
    }
}

foreach ($spec in $extraCopySpecs) {
    $copyRel = $spec.Copy
    $canonRel = $spec.Canonical
    $copyPath = [System.IO.Path]::Combine($repoRoot, ($copyRel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    $canonPath = [System.IO.Path]::Combine($repoRoot, ($canonRel -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    if (-not (Test-Path -LiteralPath $canonPath -PathType Leaf)) {
        $failures.Add("canonical shared copy missing: '$canonRel'")
        continue
    }
    if (-not (Test-Path -LiteralPath $copyPath -PathType Leaf)) {
        $failures.Add("expected shared copy missing: '$copyRel' (pinned in extraCopySpecs)")
        continue
    }
    if (Test-FilesIdentical -A $canonPath -B $copyPath) {
        Write-Output "OK identical: $copyRel == $canonRel"
    } else {
        $failures.Add("shared copy drifted: '$copyRel' differs from canonical '$canonRel' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy, or if intentional, sync ALL copies.")
    }
}

# --- 2. marketplace installability -------------------------------------------
$mp = '.claude-plugin/marketplace.json'
if (-not (Test-Path -LiteralPath $mp -PathType Leaf)) {
    $failures.Add("marketplace.json not found at $mp")
} else {
    $parsed = $null
    try {
        $parsed = [System.IO.File]::ReadAllText((Join-Path $repoRoot $mp), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    } catch {
        $failures.Add("marketplace.json is not valid JSON: $($_.Exception.Message)")
    }
    if ($null -ne $parsed) {
        $plugins = @()
        if ($parsed.PSObject.Properties.Name -contains 'plugins') { $plugins = @($parsed.plugins) }
        if ($plugins.Count -eq 0) {
            $failures.Add("marketplace.json has no plugins array (or it is empty)")
        }
        foreach ($entry in $plugins) {
            $src = [string]$entry.source
            $dir = $src -replace '^\./', ''
            if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
                $failures.Add("marketplace source dir missing: $src")
                continue
            }
            if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, '.claude-plugin', 'plugin.json')) -PathType Leaf)) {
                $failures.Add("marketplace source '$src' missing .claude-plugin/plugin.json")
            }
            $hasPs = Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'tests', 'Invoke-ScriptTests.ps1')) -PathType Leaf
            $hasSh = Test-Path -LiteralPath ([System.IO.Path]::Combine($dir, 'tests', 'invoke-script-tests.sh')) -PathType Leaf
            if (-not $hasPs -and -not $hasSh) {
                $failures.Add("marketplace source '$src' missing tests/ orchestrator entry (Invoke-ScriptTests.ps1 / invoke-script-tests.sh)")
            }
        }
    }
}

if ($failures.Count -gt 0) {
    foreach ($f in $failures) { Write-Output "FAIL: $f" }
    Write-Output "verify-core-identical: FAILED"
    exit 1
}
Write-Output "verify-core-identical: OK (shared copies identical; marketplace installable)"
exit 0
