param(
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

function Find-CommandPath {
    param([string]$CommandName)
    $command = Get-Command $CommandName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) { return $null }
    return $command.Source
}

try {
    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot

    # Resolve-FrontendPackDir, not a direct [frontend] dir read: Build-Web / Publish-Web fill the
    # result template's Frontend line from the SAME function, so what the template states and what
    # this script does cannot drift apart (issue #30). It also honours [frontend] enabled = false.
    $frontendDirRel = Resolve-FrontendPackDir -RepoRoot $repoRoot
    if ([string]::IsNullOrWhiteSpace($frontendDirRel)) {
        Write-Output '[frontend] not configured (or disabled) in .turbo-plugin/config.toml. Skipping frontend pack.'
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

    # F22: trust prompt — verify install_command + build_command haven't changed since last approval.
    # Uses "VS Code workspace trust" pattern: hash is stored in a gitignored local file.
    # If commands match the approved hash, proceed silently. If not, emit a TRUST_REQUIRED token
    # and exit non-zero so the invoking SKILL can prompt the user for confirmation.
    $trustInput = "$installCmd|$buildCmd"
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($trustInput))
    } finally {
        $sha256.Dispose()
    }
    $commandHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''
    $trustFile = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    $trustApproved = $false
    if (Test-Path -LiteralPath $trustFile -PathType Leaf) {
        $trustContent = (Get-Content -LiteralPath $trustFile -Raw -Encoding UTF8)
        if ($trustContent -match 'approved_hash\s*=\s*"([^"]+)"') {
            $trustApproved = ($Matches[1] -eq $commandHash)
        }
    }
    if (-not $trustApproved) {
        $installDisplay = if ([string]::IsNullOrWhiteSpace($installCmd)) { '(not set)' } else { $installCmd }
        $buildDisplay = if ([string]::IsNullOrWhiteSpace($buildCmd)) { '(not set)' } else { $buildCmd }
        Write-Output "TRUST_REQUIRED hash=$commandHash install_command=$installDisplay build_command=$buildDisplay"
        throw "pack-content: commands not approved. Re-invoke via /tp-build or /tp-publish skill — the skill will prompt for confirmation and record approval."
    }

    if (-not [string]::IsNullOrWhiteSpace($requiredNodeVersion)) {
        $nodeCommand = Find-CommandPath -CommandName 'node'
        if ([string]::IsNullOrWhiteSpace($nodeCommand)) { $nodeCommand = Find-CommandPath -CommandName 'node.exe' }
        if ([string]::IsNullOrWhiteSpace($nodeCommand)) { throw 'Missing node command in PATH' }
        $eaNodeVer = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $nodeCurrentOutput = (& $nodeCommand -v 2>$null | Out-String).Trim()
        $ErrorActionPreference = $eaNodeVer
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
