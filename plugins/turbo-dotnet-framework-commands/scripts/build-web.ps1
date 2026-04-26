param(
    # Pass 'release-build' to build with Configuration=Release. Defaults to Debug.
    [string]$BuildArgument = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoPath {
    param(
        [string]$RepoRoot,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    # Convert Git Bash Unix drive path: /c/foo/bar → C:\foo\bar
    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    $PathValue = $PathValue -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

try {
    $scriptDir = $PSScriptRoot
    $contentPackScript = Join-Path $scriptDir 'pack-content.ps1'
    $repoRoot = (Get-Location).Path
    $projectPathRel = $env:BUILD_PROJECT_PATH
    $msbuildPath = $env:BUILD_MSBUILD_PATH

    $buildConfiguration = 'Debug'
    if ($BuildArgument -eq 'release-build') {
        $buildConfiguration = 'Release'
    } elseif (-not [string]::IsNullOrWhiteSpace($BuildArgument)) {
        throw "Unknown build argument: '$BuildArgument'. Supported values: 'release-build'."
    }

    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        throw 'Missing BUILD_PROJECT_PATH environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($msbuildPath)) {
        throw 'Missing BUILD_MSBUILD_PATH environment variable'
    }

    $projectFile = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $projectPathRel
    $msbuildPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $msbuildPath

    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Configured project file does not exist: $projectFile"
    }

    if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
        throw "Configured MSBuild executable does not exist: $msbuildPath"
    }

    $solutionDir = $repoRoot.TrimEnd('\') + '\'

    Write-Output "Running MSBuild for $projectPathRel (Configuration: $buildConfiguration)"
    & $msbuildPath $projectFile /restore /t:Build "/p:SolutionDir=$solutionDir" /p:RestorePackagesConfig=true "/p:Configuration=$buildConfiguration" /p:Platform=AnyCPU

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    if (-not (Test-Path -LiteralPath $contentPackScript -PathType Leaf)) {
        Write-Warning "Content pack script not found. Skipping frontend packaging: $contentPackScript"
        exit 0
    }

    & $contentPackScript

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
