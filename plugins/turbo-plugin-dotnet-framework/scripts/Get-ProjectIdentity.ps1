param(
    [string]$Project = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion
    # F-U(synth 19): use git toplevel as repoRoot (not cwd) so csproj discovery works
    # regardless of which subfolder the user invoked the script from. Mirrors line 16
    # which already uses --show-toplevel for the identity hash path.
    # `git -C <root>`: -RepoRoot names the project outright (multi-project workspace); omitted it is
    # '.', i.e. the ambient cwd, which is the historical behaviour.
    $identityRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot
    $repoRoot = (& git -C $identityRoot rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) { throw 'Not inside a git repository.' }
    $repoRoot = Get-NormalizedAbsolutePath -Path $repoRoot

    # Explicit target only (no auto-detect). run/stop family => section 'run' (falls back to
    # [build].project). A .sln is rejected (no -AllowSolution): identity is per-csproj.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path

    $topLevel = (& git -C $identityRoot rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
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
