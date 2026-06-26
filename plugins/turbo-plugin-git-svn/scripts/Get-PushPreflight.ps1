[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Pre-flight detection for tp-push-to-svn first-push bootstrap.
# Inspects git HEAD + bridge presence and emits exactly ONE terminal routing token,
# prefixed 'TP_TOKEN:' so the SKILL can trust it (raw branch text cannot forge it).
# Precedence: DETACHED_HEAD > BRANCH_MISMATCH_WARNING > BRIDGE_ABSENT > BRIDGE_PRESENT.
# The SKILL reads ONLY the TP_TOKEN: line and routes; it does NOT run git itself.
$PREFIX = 'TP_TOKEN:'

# Becomes $true only AFTER the branch name passes sanitization. A failure BEFORE this point
# (invalid / forged branch name) stays tokenless (anti-forge contract); a failure AFTER it
# (e.g. MAX_PATH from Resolve-RemoteWorktree) is a real error and earns a TP_TOKEN:ERROR.
$sanitized = $false

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <branch>'
    }

    # Reject the literal 'HEAD' as a requested branch up-front: in detached state
    # '--branch HEAD' would otherwise read as current == requested and slip past both
    # the detached and mismatch gates into bootstrapping a non-branch permanent path.
    if ($Branch -ceq 'HEAD') {
        Write-Output "${PREFIX}DETACHED_HEAD requested=HEAD"
        exit 0
    }

    # Sanitize the requested branch BEFORE emitting any token so embedded newlines /
    # control chars / leading dash cannot forge a TP_TOKEN: line. Invalid input is a
    # hard error (stderr + exit 1), never a token.
    Assert-ValidRemoteBranchName -BranchName $Branch
    $sanitized = $true

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    # Detached-HEAD detection via symbolic-ref (NOT "current == requested"):
    # symbolic-ref fails in detached state.
    $ea = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $current = (& git -C $mainWorktree symbolic-ref -q --short HEAD 2>$null | Out-String).Trim()
    $symRefOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $ea
    if (-not $symRefOk -or [string]::IsNullOrWhiteSpace($current)) {
        Write-Output "${PREFIX}DETACHED_HEAD requested=$Branch"
        exit 0
    }

    if ($current -ne $Branch) {
        Write-Output "${PREFIX}BRANCH_MISMATCH_WARNING current=$current requested=$Branch"
        exit 0
    }

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    if (Test-Path -LiteralPath $remote.Path -PathType Container) {
        Write-Output "${PREFIX}BRIDGE_PRESENT requested=$Branch"
    } else {
        Write-Output "${PREFIX}BRIDGE_ABSENT requested=$Branch target=$($remote.Path)"
    }
    exit 0
}
catch {
    # Only AFTER sanitization does a throw earn a token. A throw before it (forged/invalid
    # branch) stays tokenless per the anti-forge contract. A throw after it (e.g. MAX_PATH
    # from Resolve-RemoteWorktree) emits TP_TOKEN:ERROR so the SKILL -- which routes only by
    # TP_TOKEN: lines -- never sees an undocumented "exit 1 with no token". Collapse newlines
    # and neutralize any embedded TP_TOKEN: so the reason can never forge a second line.
    if ($sanitized) {
        $reason = (($_.Exception.Message -replace '[\r\n]+', ' ') -replace 'TP_TOKEN:', 'TP_TOKEN_').Trim()
        Write-Output "${PREFIX}ERROR reason=$reason"
    }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
