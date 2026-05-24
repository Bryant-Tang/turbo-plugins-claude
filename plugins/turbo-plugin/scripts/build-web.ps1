param(
    [string]$Configuration = '',
    [string]$Platform = '',
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion

    $repoRoot = (Get-Location).Path

    # Project: CLI arg → config.toml [build].project → auto-detect single .csproj
    $projectFile = Find-SingleCsproj -RepoRoot $repoRoot -CliProjectValue $Project

    # MSBuild path: TURBO_PLUGIN_MSBUILD_PATH env → standard VS install locations
    $msbuildPath = Find-MSBuild -RepoRoot $repoRoot

    $buildConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'configuration' -CliValue $Configuration -Default 'Debug'
    $buildPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'platform' -CliValue $Platform -Default 'Any CPU'

    $solutionDir = $repoRoot.TrimEnd('\') + '\'

    Write-Output "Running MSBuild for $projectFile (Configuration: $buildConfiguration, Platform: $buildPlatform)"
    & $msbuildPath $projectFile /restore /t:Build "/p:SolutionDir=$solutionDir" /p:RestorePackagesConfig=true "/p:Configuration=$buildConfiguration" "/p:Platform=$buildPlatform"
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Frontend pack is delegated to pack-content.ps1; build pipeline runs it idempotently when [frontend] is set.
    $packScript = Join-Path $PSScriptRoot 'pack-content.ps1'
    if (Test-Path -LiteralPath $packScript -PathType Leaf) {
        & $packScript
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
