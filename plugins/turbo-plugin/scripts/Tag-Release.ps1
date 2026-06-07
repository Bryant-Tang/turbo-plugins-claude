[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Create a lightweight git tag pointing at the remote-svn worktree branch tip.
#
# Branch -> ref mapping (NEW remote-svn naming -- NOT the old remote/* scheme):
#   --branch <branch>  -> remote-svn/<branch>
# (resolved via the canonical Resolve-RemoteWorktree in lib/Common.ps1).
#
# Tag naming: <branch>-release-<yyyy-MM-dd>-<NNN> with an auto-incrementing 3-digit
# serial. We scan existing tags for the same <branch>-release-<date> prefix and pick
# the next serial, so multiple releases on the same day get -001, -002, ...
#
# The date is computed from the system clock at runtime (this is the runtime tool,
# not a plan) -- that is intentional and correct here.
try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) {
        throw 'Missing required argument: -Branch <branch>'
    }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree
    $resolved = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    $remoteBranch = $resolved.Branch

    # Confirm the remote-svn ref actually exists before tagging -- fail loudly otherwise
    # so we never create a tag pointing at an unknown revision.
    $null = & git -C $mainWorktree rev-parse --verify "$remoteBranch^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw "Remote-svn branch '$remoteBranch' not found. Run /tp-setup or /tp-create-remote-test first."
    }

    $prefix = "$Branch-release-$(Get-Date -Format 'yyyy-MM-dd')"

    $existing = @(& git -C $mainWorktree tag -l "$prefix-[0-9][0-9][0-9]" 2>$null |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object)
    if ($existing.Count -eq 0) {
        $serial = '001'
    } else {
        $last = $existing[$existing.Count - 1]
        $lastNum = [int]($last -split '-' | Select-Object -Last 1)
        $serial = '{0:D3}' -f ($lastNum + 1)
    }

    $tagName = "$prefix-$serial"
    & git -C $mainWorktree tag $tagName $remoteBranch
    if ($LASTEXITCODE -ne 0) { throw "git tag '$tagName' failed" }

    Write-Output "Created tag: $tagName"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
