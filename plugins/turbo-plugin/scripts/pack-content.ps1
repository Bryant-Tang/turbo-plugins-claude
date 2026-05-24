Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

function Find-CommandPath {
    param([string]$CommandName)
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

try {
    $repoRoot = (Get-Location).Path

    $frontendDirRel = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'frontend' -Key 'dir' -CliValue $null -Default $null
    if ([string]::IsNullOrWhiteSpace($frontendDirRel)) {
        Write-Output '[frontend] dir not configured in .turbo-plugin/config.toml. Skipping frontend pack.'
        exit 0
    }

    $frontendDir = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $frontendDirRel
    if (-not (Test-Path -LiteralPath $frontendDir -PathType Container)) {
        throw "Configured frontend directory does not exist: $frontendDir"
    }
    $packageJsonFile = Join-Path $frontendDir 'package.json'
    if (-not (Test-Path -LiteralPath $packageJsonFile -PathType Leaf)) {
        throw "Missing package.json in frontend directory: $packageJsonFile"
    }

    $installCmd = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'frontend' -Key 'install_command' -CliValue $null -Default $null
    $buildCmd = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'frontend' -Key 'build_command' -CliValue $null -Default $null
    $requiredNodeVersion = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'frontend' -Key 'node_version' -CliValue $null -Default $null

    if (-not [string]::IsNullOrWhiteSpace($requiredNodeVersion)) {
        $nodeCommand = Find-CommandPath -CommandName 'node'
        if ([string]::IsNullOrWhiteSpace($nodeCommand)) { $nodeCommand = Find-CommandPath -CommandName 'node.exe' }
        if ([string]::IsNullOrWhiteSpace($nodeCommand)) { throw 'Missing node command in PATH' }
        $nodeCurrentOutput = (& $nodeCommand -v 2>&1 | Out-String).Trim()
        Write-Output "Active Node version: $nodeCurrentOutput"
        $currentMajor = ($nodeCurrentOutput -replace '^v', '').Split('.')[0]
        $requiredMajor = ($requiredNodeVersion.ToString() -replace '^v', '').Split('.')[0]
        if ($currentMajor -ne $requiredMajor) {
            throw "Unexpected Node version. Current: $nodeCurrentOutput, Required major: $requiredNodeVersion"
        }
    }

    $frontendDirName = Split-Path -Leaf $frontendDir
    Push-Location $frontendDir
    try {
        if (-not [string]::IsNullOrWhiteSpace($installCmd)) {
            Write-Output "Running frontend install command in ${frontendDirName}: $installCmd"
            # Tokenized invocation (no Invoke-Expression): shell metachars (;, |, &&) do not
            # trigger shell composition. For multi-step builds use a wrapper script instead.
            $tokens = $installCmd -split '\s+' | Where-Object { $_ }
            if ($tokens.Count -gt 0) {
                # @(... | Select-Object -Skip 1) safely produces an empty array when only
                # one token exists, avoiding the reversed-range bug of $tokens[1..-1].
                $tokenArgs = @($tokens | Select-Object -Skip 1)
                & $tokens[0] @tokenArgs
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
        } else {
            Write-Output '[frontend] install_command not set. Skipping install.'
        }
        if (-not [string]::IsNullOrWhiteSpace($buildCmd)) {
            Write-Output "Running frontend build command in ${frontendDirName}: $buildCmd"
            # Tokenized invocation (no Invoke-Expression): shell metachars (;, |, &&) do not
            # trigger shell composition. For multi-step builds use a wrapper script instead.
            $tokens = $buildCmd -split '\s+' | Where-Object { $_ }
            if ($tokens.Count -gt 0) {
                $tokenArgs = @($tokens | Select-Object -Skip 1)
                & $tokens[0] @tokenArgs
                if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
            }
        } else {
            Write-Output '[frontend] build_command not set. Skipping build.'
        }
    } finally {
        Pop-Location
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
