param(
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion
    $repoRoot = (Get-Location).Path

    $projectFile = Find-SingleCsproj -RepoRoot $repoRoot -CliProjectValue $Project

    $topLevel = (& git rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($topLevel)) { throw 'Not inside a git repository.' }
    $topLevel = Get-NormalizedAbsolutePath -Path $topLevel
    $projectAbs = Get-NormalizedAbsolutePath -Path $projectFile
    $relPath = Get-RelativePathSafe -From $topLevel -To $projectAbs
    $relPath = $relPath -replace '\\', '/'

    $hash = Get-ProjectIdentityHash -RepoPath $topLevel -CsprojRelPath $relPath
    $siteName = Format-IisExpressSiteName -CsprojPath $projectFile -IdentityHash $hash

    Write-Output "PROJECT=$projectFile"
    Write-Output "IDENTITY_HASH=$hash"
    Write-Output "SITE_NAME=$siteName"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
