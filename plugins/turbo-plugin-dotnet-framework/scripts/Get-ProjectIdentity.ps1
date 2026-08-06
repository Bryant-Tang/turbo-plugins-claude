param(
    [string]$Project = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion
    # F-U(synth 19): anchor on the git toplevel rather than the cwd so csproj discovery works
    # regardless of which subfolder the user invoked the script from -- and, outside git, on the
    # project root itself so a non-git project still resolves (issue #29).
    # `-RepoRoot` names the project outright (multi-project workspace); omitted it is '.', i.e. the
    # ambient cwd, which is the historical behaviour. Resolved ONCE: discovery root and identity
    # anchor must be the same directory, or the relative path fed to the hash would not match the
    # one Resolve-IisSettings computes.
    $identityRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot
    $repoRoot = Resolve-IdentityAnchor -RepoRoot $identityRoot

    # Explicit target only (no auto-detect). run/stop family => section 'run' (falls back to
    # [build].project). A .sln is rejected (no -AllowSolution): identity is per-csproj.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path

    $topLevel = $repoRoot
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
