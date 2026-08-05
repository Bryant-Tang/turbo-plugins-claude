# Reset-Fixture.ps1
#
# Per-case fixture reset for turbo-plugin-dotnet-framework Script tests.
# Mirrors the base web-app fixture into the gitignored sandbox workspace before each
# Script test case, restoring a clean slate from base/.
#
# This plugin has NO SVN concern. The monolith's reset also rebuilt an SVN repo +
# checked out remote-svn worktrees; those steps (and the -SvnRepo / -DumpPath / -SkipSvn
# params) were dropped in the four-way split -- a .NET-only plugin never needs them.
#
# Idempotent: any prior workspace state (clean / dirty / partial) is restored to base.
# Written for PS 5.1; pure ASCII (no BOM needed).

[CmdletBinding()]
param(
    [string]$TestRoot,
    [string]$BaseDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# --- Paths -------------------------------------------------------------------
$scriptDir = $PSScriptRoot
# Reset-Fixture.ps1 lives at:
#   <repo>/plugins/turbo-plugin-dotnet-framework/tests/fixtures/reset/Reset-Fixture.ps1
$fixturesDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..'))
$testsDir    = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($scriptDir, '..', '..'))

# Default work root = repo-relative, gitignored tests/.sandbox/. Resolved LONG form via
# GetFullPath so 8.3 short-names never appear and a spaced parent path is tolerated.
$sandboxDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($testsDir, '.sandbox'))
if ([string]::IsNullOrWhiteSpace($TestRoot)) {
    $TestRoot = [System.IO.Path]::Combine($sandboxDir, 'test-turbo-plugin')
}
if ([string]::IsNullOrWhiteSpace($BaseDir)) {
    $BaseDir = [System.IO.Path]::Combine($fixturesDir, 'base')
}

# --- Sanity check ------------------------------------------------------------
if (-not [System.IO.Directory]::Exists($BaseDir)) {
    throw "Base fixture dir does not exist: $BaseDir"
}

# --- Step 1: robocopy /MIR (F-4 fix) -----------------------------------------
#
# robocopy exit code semantics (NOT ordinary unix exit):
#   0   = no files copied (already in sync)
#   1-7 = various copy/extra/mismatch combinations; ALL SUCCESS
#   >=8 = at least one failure
# Treat 0-7 as success; only throw on >=8. Then reset $LASTEXITCODE = 0 so a downstream
# `if ($LASTEXITCODE -ne 0)` check (repo-wide EAP=Stop) does not see a stale 1-7.

if (-not [System.IO.Directory]::Exists($TestRoot)) {
    $null = New-Item -ItemType Directory -Path $TestRoot -Force
}

Write-Output "Step 1: robocopy /MIR  $BaseDir  ->  $TestRoot"
# /MIR mirror (purge + copy); /NFL /NDL /NJH /NJS /NP quiet; /R:1 /W:1 retry once.
& robocopy.exe $BaseDir $TestRoot /MIR /NFL /NDL /NJH /NJS /NP /R:1 /W:1 | Out-Null
$rc = $LASTEXITCODE
if ($rc -ge 8) {
    throw "robocopy /MIR failed with exit code $rc (>=8 = real failure)."
}
$global:LASTEXITCODE = 0
Write-Output "  robocopy OK (exit=$rc treated as success)"

Write-Output ""
Write-Output "Fixture reset complete."
Write-Output "  Workspace: $TestRoot"

exit 0
