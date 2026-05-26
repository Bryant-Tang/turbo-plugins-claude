# Lint .ps1 files for Windows PowerShell 5.1 incompatibilities.
#
# Checks (see CLAUDE.md "Windows PowerShell 5.1 相容性" section for rationale):
#   1. 3+ arg `Join-Path` (PS 7+ only)
#   2. `[System.IO.Path]::GetRelativePath` (.NET Core / .NET 5+ only)
#   3. .ps1 with non-ASCII bytes but no UTF-8 BOM
#   4. `2>&1` on native exe (NativeCommandError pollutes $LASTEXITCODE under EAP=Stop)
#   5. `(... | ...).Count` without @() wrap (single-element pipeline reads wrong .Count)
#
# Exit code 0 = clean, 1 = found violations. Suitable for pre-commit hook or
# manual `pwsh tools/lint-ps-compat.ps1` from repo root.

[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Path)) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        Write-Error 'Not inside a git repository and no -Path given.'
        exit 1
    }
    $Path = $repoRoot
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    exit 1
}

$violations = @()

# Detector regexes
$pat3argJoinPath = [regex]"Join-Path\s+\`$[A-Za-z_][A-Za-z0-9_]*\s+'[^']+'\s+'"
$patGetRelative  = [regex][regex]::Escape('[System.IO.Path]::GetRelativePath')
# Rule 4: 2>&1 used after a native-exe call operator `& ...`. Catches `& git ... 2>&1`,
# `& svn ... 2>&1`, `& $cmd ... 2>&1` etc. Requires whitespace before `2>&1` so it doesn't
# trip on string literals like the rule description itself.
$patNativeExe2to1 = [regex]'&\s+\S.+\s2>&1\b'
# Rule 5: pipeline result .Count without @() wrap. Negative lookbehind excludes @(.
# Pipeline detected by `|` inside the parens. Heuristic — keeps false positives low.
$patPipeCount    = [regex]'(?<!@)\([^()@]*\|[^()]*\)\.Count\b'

Get-ChildItem -Path $Path -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_.FullName
    # Skip the lint script itself: it contains literal regex patterns matching
    # the rules it enforces (e.g. the string 'GetRelativePath'), which would
    # be reported as false positives.
    if ($file -match '\\tools\\lint-ps-compat\.ps1$') { return }
    $bytes = [System.IO.File]::ReadAllBytes($file)
    if ($bytes.Length -eq 0) { return }

    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $hasNonAscii = $false
    foreach ($b in $bytes) {
        if ($b -gt 127) { $hasNonAscii = $true; break }
    }

    # Check 3: non-ASCII without BOM
    if ($hasNonAscii -and -not $hasBom) {
        $violations += [pscustomobject]@{
            File   = $file
            Rule   = '3-no-bom'
            Line   = 0
            Detail = '.ps1 contains non-ASCII bytes but no UTF-8 BOM — PS 5.1 will read as system codepage and mojibake'
        }
    }

    # For text-based checks, decode UTF-8 (skip BOM if present)
    $offset = if ($hasBom) { 3 } else { 0 }
    $text = [System.Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
    $lines = $text -split "`r?`n"

    for ($i = 0; $i -lt $lines.Length; $i++) {
        $ln = $lines[$i]
        $lineNo = $i + 1

        # Check 1: 3+ arg Join-Path
        if ($pat3argJoinPath.IsMatch($ln)) {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = '1-joinpath-3arg'
                Line   = $lineNo
                Detail = $ln.Trim()
            }
        }

        # Check 2: GetRelativePath (skip comment-only lines)
        $trimmed = $ln.TrimStart()
        if (-not $trimmed.StartsWith('#') -and $patGetRelative.IsMatch($ln)) {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = '2-getrelativepath'
                Line   = $lineNo
                Detail = $ln.Trim()
            }
        }

        # Check 4: 2>&1 on native exe (skip comment-only lines)
        if (-not $trimmed.StartsWith('#') -and $patNativeExe2to1.IsMatch($ln)) {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = '4-redir-native-2to1'
                Line   = $lineNo
                Detail = $ln.Trim()
            }
        }

        # Check 5: pipeline .Count without @() wrap (skip comment-only lines)
        if (-not $trimmed.StartsWith('#') -and $patPipeCount.IsMatch($ln)) {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = '5-pipe-count'
                Line   = $lineNo
                Detail = $ln.Trim()
            }
        }
    }
}

if ($violations.Count -eq 0) {
    Write-Output "lint-ps-compat: 0 violations across $((Get-ChildItem -Path $Path -Recurse -Filter '*.ps1' | Measure-Object).Count) .ps1 files."
    exit 0
}

Write-Output "lint-ps-compat: $($violations.Count) violation(s) found:"
Write-Output ''
$violations | Group-Object Rule | ForEach-Object {
    $ruleName = switch ($_.Name) {
        '1-joinpath-3arg'      { 'Join-Path 3+ arg (PS 7+ only) — use [System.IO.Path]::Combine' }
        '2-getrelativepath'    { 'GetRelativePath (.NET Core+ only) — use Get-RelativePathSafe' }
        '3-no-bom'             { 'non-ASCII without UTF-8 BOM — re-save with BOM' }
        '4-redir-native-2to1'  { '2>&1 on native exe (PS 5.1 NativeCommandError pollutes $LASTEXITCODE under EAP=Stop) — use 2>$null + EAP guard' }
        '5-pipe-count'         { 'pipeline .Count without @() wrap — single-element pipeline reads object''s own Count, not array length' }
        default                { $_.Name }
    }
    Write-Output "[$($_.Name)] $ruleName"
    $_.Group | ForEach-Object {
        $rel = $_.File
        if ($_.Line -gt 0) {
            Write-Output ("  " + $rel + ":" + $_.Line + ": " + $_.Detail)
        } else {
            Write-Output ("  " + $rel + ": " + $_.Detail)
        }
    }
    Write-Output ''
}
exit 1
