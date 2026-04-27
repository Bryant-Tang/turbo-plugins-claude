param(
    # Path to the .pubxml publish profile. Falls back to PUBLISH_PUBXML_PATH env var.
    [string]$Profile = ''
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
    $repoRoot = (Get-Location).Path
    $projectPathRel = $env:BUILD_PROJECT_PATH
    $msbuildPath = $env:BUILD_MSBUILD_PATH

    $pubxmlPathRaw = if (-not [string]::IsNullOrWhiteSpace($Profile)) { $Profile }
                     elseif (-not [string]::IsNullOrWhiteSpace($env:PUBLISH_PUBXML_PATH)) { $env:PUBLISH_PUBXML_PATH }
                     else { '' }

    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        throw 'Missing BUILD_PROJECT_PATH environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($msbuildPath)) {
        throw 'Missing BUILD_MSBUILD_PATH environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($pubxmlPathRaw)) {
        throw 'No publish profile specified. Provide -Profile <path> or set PUBLISH_PUBXML_PATH environment variable'
    }

    $projectFile = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $projectPathRel
    $msbuildPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $msbuildPath
    $pubxmlAbsPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $pubxmlPathRaw

    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Configured project file does not exist: $projectFile"
    }

    if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
        throw "Configured MSBuild executable does not exist: $msbuildPath"
    }

    if (-not (Test-Path -LiteralPath $pubxmlAbsPath -PathType Leaf)) {
        throw "Publish profile does not exist: $pubxmlAbsPath"
    }

    Write-Output "Running MSBuild Publish for $projectPathRel"
    Write-Output "  Publish profile: $pubxmlAbsPath"

    & $msbuildPath $projectFile /t:Publish "/p:PublishProfile=$pubxmlAbsPath"

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
