[CmdletBinding()]
param(
    # The workspace folder to inspect; omit to inspect the current directory.
    [string]$WorkspaceRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Core.ps1'))

# Read-only survey of a multi-repo workspace: a folder that is NOT itself a git repository but
# holds several independent projects side by side.
#
# Output contract (mirrors the git-svn scripts): zero or more plain `PROJECT ...` data lines,
# then EXACTLY ONE terminal line prefixed `TP_TOKEN:` that the SKILL routes on. `path=` is
# always the LAST field on a line so a path containing spaces needs no quoting or escaping.
#
#   PROJECT setup=<yes|no> main=<yes|no> path=<absolute>
#   TP_TOKEN:PROJECTS count=<N>            one or more projects found
#   TP_TOKEN:WORKSPACE_IS_REPO path=<abs>  the folder is itself a repo -> not a multi-repo workspace
#   TP_TOKEN:NO_PROJECTS path=<abs>        not a repo, and no direct child is one either
#   TP_TOKEN:ERROR reason=<text>           anything else
#
# `setup=` reports whether that project already has a `.turbo-plugin/` marker (so the SKILL can
# offer setup only where it is missing). `main=` reports whether the project directory is its own
# main worktree; a linked worktree of some other repo answers `no`, and git-svn's own setup would
# refuse it, so the SKILL must not offer setup there.
#
# ONLY direct children are scanned. That is deliberate and load-bearing: git-svn keeps its bridge
# worktrees at `<project>/.turbo-plugin/worktrees/remote-svn-*`, each of which carries a `.git`
# file. Those are grandchildren, so scanning one level deep never mistakes a bridge for a project.

# Collapse a value onto one line and neutralise any embedded token prefix, so a directory name
# cannot forge a routing line the SKILL would then trust.
function Format-TokenValue {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $flat = ($Value -replace '[\r\n]+', ' ')
    return ($flat -replace 'TP_TOKEN:', 'TP_TOKEN_')
}

try {
    Probe-GitVersion

    $root = if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) {
        (Get-Location).Path
    } else {
        $WorkspaceRoot
    }
    $root = Get-NormalizedAbsolutePath -Path $root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        throw "Workspace root not found (or not a directory): $WorkspaceRoot"
    }
    # Expand any 8.3 short-name segment (e.g. FIRSTL~1 from %TEMP%) to its long form. Resolve-Path,
    # which Get-NormalizedAbsolutePath uses, leaves short names alone, while Get-ChildItem below
    # reports long names -- so without this the token line and the PROJECT lines would disagree on
    # how the same directory is spelled, which reads as two different places.
    try { $root = (Get-Item -LiteralPath $root).FullName } catch { }
    $root = Get-NormalizedAbsolutePath -Path $root

    # Is the workspace folder itself a repository? `git rev-parse` searches UPWARD, so this also
    # catches "the folder sits inside a repo", which is equally not a multi-repo workspace.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $root rev-parse --git-dir 2>$null | Out-Null
    $rootIsRepo = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP

    if ($rootIsRepo) {
        Write-Output ('TP_TOKEN:WORKSPACE_IS_REPO path=' + (Format-TokenValue -Value $root))
        exit 0
    }

    $children = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Sort-Object -Property Name)

    $projects = @()
    foreach ($child in $children) {
        $dotGit = [System.IO.Path]::Combine($child.FullName, '.git')
        # `.git` is a directory in a normal clone and a FILE in a linked worktree; Test-Path
        # accepts both, which is what the git-svn nested-repo guard also keys on. Keeping the
        # two in agreement matters: this script decides what to offer setup for, and that guard
        # decides what setup refuses.
        if (-not (Test-Path -LiteralPath $dotGit)) { continue }

        $abs = Get-NormalizedAbsolutePath -Path $child.FullName
        $hasSetup = Test-Path -LiteralPath ([System.IO.Path]::Combine($child.FullName, '.turbo-plugin')) -PathType Container
        $isMain = Test-IsMainWorktree -RepoRoot $child.FullName

        $projects += [pscustomobject]@{
            Path     = $abs
            HasSetup = $hasSetup
            IsMain   = $isMain
        }
    }

    if ($projects.Count -eq 0) {
        Write-Output ('TP_TOKEN:NO_PROJECTS path=' + (Format-TokenValue -Value $root))
        exit 0
    }

    foreach ($p in $projects) {
        $setup = if ($p.HasSetup) { 'yes' } else { 'no' }
        $main = if ($p.IsMain) { 'yes' } else { 'no' }
        Write-Output ("PROJECT setup=$setup main=$main path=" + (Format-TokenValue -Value $p.Path))
    }
    Write-Output ("TP_TOKEN:PROJECTS count=$($projects.Count)")
    exit 0
} catch {
    Write-Output ('TP_TOKEN:ERROR reason=' + (Format-TokenValue -Value $_.Exception.Message))
    exit 1
}
