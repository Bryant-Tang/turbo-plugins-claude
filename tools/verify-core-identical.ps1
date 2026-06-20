# verify-core-identical.ps1
#
# Repo-level cross-plugin consistency check (U8 / KTD3) -- PowerShell sibling of
# verify-core-identical.sh, for local Windows use. Same two checks:
#
#   1. Byte-identical shared copies: files copied verbatim into multiple plugins
#      (universal Core.{ps1,sh} + shared tp-setup base assets) must NOT drift.
#      Compared byte-for-byte (incl BOM and line endings) vs the canonical
#      turbo-plugin-git-svn copy.
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
$sharedRelpaths = @(
    'scripts/lib/Core.ps1',
    'scripts/lib/core.sh',
    'skills/tp-setup/assets/setup-base.md',
    'skills/tp-setup/assets/claudemd-base-snippet.md'
)

$pluginDirs = @(Get-ChildItem -LiteralPath 'plugins' -Directory)

foreach ($rel in $sharedRelpaths) {
    $relNative = $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $copies = @($pluginDirs | ForEach-Object {
        $p = [System.IO.Path]::Combine($_.FullName, $relNative)
        if (Test-Path -LiteralPath $p -PathType Leaf) { $p }
    })
    if ($copies.Count -lt 2) {
        Write-Output "skip (fewer than 2 copies): $rel"
        continue
    }
    $canon = @($copies | Where-Object { $_ -match 'turbo-plugin-git-svn' } | Select-Object -First 1)
    if ($canon.Count -gt 0 -and -not [string]::IsNullOrEmpty($canon[0])) {
        $canonPath = $canon[0]
    } else {
        $canonPath = $copies[0]
    }
    foreach ($c in $copies) {
        if ($c -eq $canonPath) { continue }
        if (Test-FilesIdentical -A $canonPath -B $c) {
            Write-Output "OK identical: $c == $canonPath"
        } else {
            $failures.Add("shared copy drifted: '$c' differs from canonical '$canonPath' (byte-for-byte incl BOM/newlines). Fix: overwrite with the canonical copy (Copy-Item '$canonPath' '$c'), or if intentional, sync ALL copies.")
        }
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
