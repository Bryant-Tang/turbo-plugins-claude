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
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = (Get-Location).Path
    $stateFile = Get-GitPath -RepoRoot $repoRoot -GitPathName 'testing-and-proof.applied-stash-ref'

    if (-not (Test-Path -LiteralPath $stateFile -PathType Leaf)) {
        Write-Output 'No applied local-test stash state file found. Skipping revert.'
        exit 0
    }

    $stashRef = (Get-Content -LiteralPath $stateFile -Raw).Trim()
    git stash show -p --include-untracked $stashRef | git apply -R

    if ($LASTEXITCODE -ne 0) {
        throw "git apply -R failed with exit code $LASTEXITCODE"
    }

    $statusOutput = (& git status --porcelain | Out-String).TrimEnd()

    if (-not [string]::IsNullOrWhiteSpace($statusOutput)) {
        Write-Output 'Working tree still contains changes after reverting local test stash.'
        $statusOutput -split "`r?`n" | ForEach-Object { Write-Output $_ }
        exit 1
    }

    Remove-Item -LiteralPath $stateFile -Force
    Write-Output "Reverted local test stash: $stashRef"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
