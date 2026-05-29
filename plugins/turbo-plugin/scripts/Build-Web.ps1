param(
    [string]$Configuration = '',
    [string]$Platform = '',
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    $repoRoot = (Get-Location).Path

    # Project: CLI arg → config.toml [build].project → auto-detect single .csproj
    $projectFile = Find-SingleCsproj -RepoRoot $repoRoot -CliProjectValue $Project

    # MSBuild path: config.local.toml [tools] msbuild_path → standard VS install locations
    # (v1.0+ U2: strict cut, no env var fallback — throws with /tp-setup guidance if missing)
    $msbuildPath = Find-MSBuild -RepoRoot $repoRoot

    $buildConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'configuration' -CliValue $Configuration -Default 'Debug'
    $buildPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'platform' -CliValue $Platform -Default 'Any CPU'

    $solutionDir = $repoRoot.TrimEnd('\') + '\'

    Write-Output "Running MSBuild for $projectFile (Configuration: $buildConfiguration, Platform: $buildPlatform)"
    & $msbuildPath $projectFile /restore /t:Build "/p:SolutionDir=$solutionDir" /p:RestorePackagesConfig=true "/p:Configuration=$buildConfiguration" "/p:Platform=$buildPlatform"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Frontend pack is delegated to pack-content.ps1 (shipped alongside build-web.ps1);
    # pack-content exits 0 with a skip message when [frontend] isn't set, so no Test-Path guard needed.
    & ([System.IO.Path]::Combine($PSScriptRoot, 'pack-content.ps1'))
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
