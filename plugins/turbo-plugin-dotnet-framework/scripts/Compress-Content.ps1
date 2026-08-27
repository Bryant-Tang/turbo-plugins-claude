param(
    [string]$RepoRoot = '',
    # The resolved project/solution this pack belongs to. Build-Web / Publish-Web forward what
    # they resolved, so the group chosen here is the same one their result template reported.
    # Omitted means "no target in view": only the bare [frontend] can apply (issue #125).
    [string]$Project = ''
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

    # Resolve-FrontendGroup, not a direct [frontend] dir read: Build-Web / Publish-Web fill the
    # result template's Frontend line from the SAME function, so what the template states and what
    # this script does cannot drift apart (issue #30). It also honours enabled = false, and picks
    # the group belonging to $Project when the repo carries several (issue #125).
    $group = Resolve-FrontendGroup -RepoRoot $repoRoot -TargetProject $Project
    $frontendDirRel = $group.Dir
    if ([string]::IsNullOrWhiteSpace($frontendDirRel)) {
        # Say WHICH of the non-running outcomes this is. "no group names this project" means
        # someone configured frontend for this repo and this project fell through the gap; that is
        # a different thing from "this repo does no frontend work" and must not read the same.
        switch ($group.Status) {
            'disabled'  { Write-Output '[frontend] enabled = false in .turbo-plugin/config.toml. Skipping frontend pack.' }
            'unmatched' { Write-Output "[frontend] groups exist in .turbo-plugin/config.toml but none names '$Project'. Skipping frontend pack." }
            default     { Write-Output '[frontend] not configured in .turbo-plugin/config.toml. Skipping frontend pack.' }
        }
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

    # $group.Section, never a literal 'frontend': the commands must come from the SAME group whose
    # dir was just resolved. Reading dir from one group and commands from another is the multi-
    # project version of the bug this whole path exists to stop.
    $installCmd = Resolve-ConfigValue -RepoRoot $repoRoot -Section $group.Section -Key 'install_command' -CliValue $null -Default $null
    $buildCmd = Resolve-ConfigValue -RepoRoot $repoRoot -Section $group.Section -Key 'build_command' -CliValue $null -Default $null
    $requiredNodeVersion = Resolve-ConfigValue -RepoRoot $repoRoot -Section $group.Section -Key 'node_version' -CliValue $null -Default $null

    # F22: trust prompt — verify install_command + build_command haven't changed since last approval.
    # Uses "VS Code workspace trust" pattern: hash is stored in a gitignored local file.
    # If commands match the approved hash, proceed silently. If not, emit a TRUST_REQUIRED token
    # and exit non-zero so the invoking SKILL can prompt the user for confirmation.
    # The group key is part of the hash, so approving one project's commands never authorises
    # another project's -- even when the second project is added later. The BARE group keeps the
    # historical input verbatim (no separator, no key) so approvals granted before groups existed
    # still match and nobody is asked to re-approve commands they already approved.
    $trustInput = if ([string]::IsNullOrWhiteSpace($group.Key)) {
        "$installCmd|$buildCmd"
    } else {
        "$($group.Key)|$installCmd|$buildCmd"
    }
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($trustInput))
    } finally {
        $sha256.Dispose()
    }
    $commandHash = ($hashBytes | ForEach-Object { $_.ToString('x2') }) -join ''

    # The approval covers install_command + build_command, and BOTH come from the
    # version-controlled config.toml -- so every worktree of a repo hashes to the same value and a
    # per-worktree approval buys no extra safety. It only made the user re-approve identical
    # commands in each new worktree, because the record is gitignored and therefore absent from a
    # fresh one (issue #61). The record is kept in the main worktree; this worktree's own file is
    # still honoured so approvals granted before this change keep working.
    $mainRoot = $repoRoot
    try { $mainRoot = Get-MainWorktree -RepoRoot $repoRoot } catch { $mainRoot = $repoRoot }
    $trustFile = [System.IO.Path]::Combine($mainRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    $localTrustFile = [System.IO.Path]::Combine($repoRoot, '.turbo-plugin', 'pack-content-trust.local.toml')
    # ALL occurrences, not the first: with one group per project the file holds one entry per
    # approved command set. `-match` stops at the first hit, so it would have answered about
    # whichever entry happened to be at the top -- approving project A and then building project B
    # would have compared B's hash against A's entry and re-prompted forever.
    $trustApproved = $false
    foreach ($candidate in @($trustFile, $localTrustFile)) {
        if ($trustApproved) { break }
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        $trustContent = (Get-Content -LiteralPath $candidate -Raw -Encoding UTF8)
        foreach ($m in [regex]::Matches($trustContent, 'approved_hash\s*=\s*"([^"]+)"')) {
            if ($m.Groups[1].Value -eq $commandHash) { $trustApproved = $true; break }
        }
    }
    if (-not $trustApproved) {
        $installDisplay = if ([string]::IsNullOrWhiteSpace($installCmd)) { '(not set)' } else { $installCmd }
        $buildDisplay = if ([string]::IsNullOrWhiteSpace($buildCmd)) { '(not set)' } else { $buildCmd }
        Write-Output "TRUST_REQUIRED hash=$commandHash install_command=$installDisplay build_command=$buildDisplay"
        # Own line: the path may contain spaces, and the TRUST_REQUIRED fields are already
        # free-form, so appending another key= there would make both ambiguous to parse.
        Write-Output "TRUST_FILE $trustFile"
        # Which group is being approved. Empty for the bare [frontend]; the SKILL writes it into
        # the recorded entry so a human reading the trust file later can tell the entries apart.
        Write-Output "TRUST_GROUP $($group.Key)"
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
        # Test-NodeVersionSatisfied understands both the historical bare-major form and comparison
        # operators; see its comment in lib/Common.ps1 for the accepted grammar. The wording below
        # deliberately says "does not satisfy" rather than the old "Unexpected Node version /
        # Required major", which read as "you are on the wrong Node" even when the requirement was
        # the unparseable half of the problem (issue #49).
        if (-not (Test-NodeVersionSatisfied -CurrentVersion $nodeCurrentOutput -Requirement $requiredNodeVersion.ToString())) {
            throw "Node version does not satisfy [frontend] node_version. Current: $nodeCurrentOutput, required: $requiredNodeVersion"
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
