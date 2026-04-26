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

function Find-CommandPath {
    param([string]$CommandName)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $command) {
        return $null
    }

    return $command.Source
}

try {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $repoRoot = (Get-Location).Path
    $frontendPathRel = $env:BUILD_FRONTEND_DIR_PATH

    if ([string]::IsNullOrWhiteSpace($frontendPathRel)) {
        Write-Output 'BUILD_FRONTEND_DIR_PATH is not configured. Skipping frontend packaging.'
        exit 0
    }

    $frontendDir = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $frontendPathRel

    if (-not (Test-Path -LiteralPath $frontendDir -PathType Container)) {
        throw "Configured frontend directory does not exist: $frontendDir"
    }

    $packageJsonFile = Join-Path $frontendDir 'package.json'

    if (-not (Test-Path -LiteralPath $packageJsonFile -PathType Leaf)) {
        throw "Missing package.json in frontend directory: $packageJsonFile"
    }

    $requiredNodeVersion = $env:BUILD_NODE_VERSION
    $installCmd = $env:BUILD_FRONTEND_INSTALL_COMMAND
    $buildCmd = $env:BUILD_FRONTEND_BUILD_COMMAND

    if (-not [string]::IsNullOrWhiteSpace($requiredNodeVersion)) {
        $nodeCommand = Find-CommandPath -CommandName 'node'

        if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
            $nodeCommand = Find-CommandPath -CommandName 'node.exe'
        }

        if ([string]::IsNullOrWhiteSpace($nodeCommand)) {
            throw 'Missing node command in PATH'
        }

        $nodeCurrentOutput = (& $nodeCommand -v 2>&1 | Out-String).Trim()
        Write-Output "Active Node version: $nodeCurrentOutput"

        $currentMajor = ($nodeCurrentOutput -replace '^v', '').Split('.')[0]
        $requiredMajor = ($requiredNodeVersion -replace '^v', '').Split('.')[0]
        if ($currentMajor -ne $requiredMajor) {
            throw "Unexpected Node version. Current: $nodeCurrentOutput, Required major: $requiredNodeVersion"
        }
    }

    $frontendDirName = Split-Path -Leaf $frontendDir

    Push-Location $frontendDir

    try {
        if (-not [string]::IsNullOrWhiteSpace($installCmd)) {
            Write-Output "Running frontend install command in ${frontendDirName}: $installCmd"
            # Invoke-Expression is intentional: BUILD_FRONTEND_INSTALL_COMMAND may be a
            # compound command (e.g. "npm ci --prefer-offline") set by the project owner
            # in settings.local.json. Treat that value as trusted configuration.
            Invoke-Expression $installCmd

            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
        } else {
            Write-Output 'BUILD_FRONTEND_INSTALL_COMMAND is not set. Skipping install.'
        }

        if (-not [string]::IsNullOrWhiteSpace($buildCmd)) {
            Write-Output "Running frontend build command in ${frontendDirName}: $buildCmd"
            # Invoke-Expression is intentional: BUILD_FRONTEND_BUILD_COMMAND may be a
            # compound command set by the project owner in settings.local.json.
            Invoke-Expression $buildCmd

            if ($LASTEXITCODE -ne 0) {
                exit $LASTEXITCODE
            }
        } else {
            Write-Output 'BUILD_FRONTEND_BUILD_COMMAND is not set. Skipping build.'
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
