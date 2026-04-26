Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-GitPath {
    param(
        [string]$RepoRoot,
        [string]$GitPathName
    )

    $gitPath = (& git rev-parse --git-path $GitPathName | Out-String).Trim()

    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to resolve git state path.'
    }

    if ([System.IO.Path]::IsPathRooted($gitPath)) {
        return [System.IO.Path]::GetFullPath($gitPath)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $gitPath))
}

try {
    $repoRoot = (Get-Location).Path
    $stateFile = Get-GitPath -RepoRoot $repoRoot -GitPathName 'testing-and-proof.applied-stash-ref'
    $stashSha = $env:TEST_LOCAL_STASH_SHA

    if (Test-Path -LiteralPath $stateFile -PathType Leaf) {
        Write-Output "Found previous applied-stash state file: $stateFile"
        Write-Output 'Run revert-local-test-stash.ps1 before applying again.'
        exit 1
    }

    $statusOutput = (& git status --porcelain | Out-String).TrimEnd()

    if (-not [string]::IsNullOrWhiteSpace($statusOutput)) {
        Write-Output 'Working tree is not clean. Refusing to apply local test stash.'
        $statusOutput -split "`r?`n" | ForEach-Object { Write-Output $_ }
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace($stashSha)) {
        Write-Output 'TEST_LOCAL_STASH_SHA is not configured. Skipping local test stash apply.'
        exit 0
    }

    & git rev-parse --verify "$($stashSha)^{commit}" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Output "Configured stash SHA not found: $stashSha"
        & git stash list --format='%H %gd %gs'
        exit 1
    }

    & git stash show -p --include-untracked "$stashSha" | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Output "Configured stash SHA is not a valid stash entry: $stashSha"
        exit 1
    }

    $stateDir = Split-Path -Parent $stateFile

    if (-not (Test-Path -LiteralPath $stateDir -PathType Container)) {
        New-Item -ItemType Directory -Path $stateDir | Out-Null
    }

    & git stash apply $stashSha

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Set-Content -LiteralPath $stateFile -Value $stashSha
    Write-Output "Applied local test stash: $stashSha"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
