[CmdletBinding()]
param(
    [string[]]$Branch = @(),
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Merge the latest `main` into a set of local branches.
#
#   - Default (no -Branch given): target = EVERY local branch that is neither `main`
#     itself nor a `remote-svn/*` bridge branch.
#   - When -Branch is given: target = exactly those branches. Each is validated to exist
#     (git branch --list), and to be neither `main` nor `remote-svn/*`. A branch that is
#     missing or excluded is reported as `SKIP <b> (not found / excluded)` and skipped,
#     never aborting the whole run.
#
# NEW semantics vs the old tgs merge-main-into-all this was ported from:
#   - Exclude filter excludes `main` AND `remote-svn/*` only. The old `^archives/`
#     exclusion is DROPPED (turbo-plugin retired the dev-flow / archive worktrees).
#   - NO worktree-aware path (no Get-BranchWorktreeMap). turbo-plugin does not manage
#     dev/archive worktrees, so we operate purely in the main worktree: for each target
#     branch checkout -> merge main -> (abort on conflict) and restore the original
#     branch at the end.
#   - Conflict handling is per-branch: on conflict we `git merge --abort` THAT branch,
#     mark it CONFLICT in the output, and CONTINUE to the next branch (we never leave a
#     conflicted tree and never stop the whole run).
#
# A branch that some OTHER worktree has checked out is reported as its own state --
# `SKIP <b> (checked out at <path>)` -- and NOT as a conflict. git forbids the same branch in two
# worktrees at once, so the checkout simply cannot happen; calling that CONFLICT sent the reader
# looking for a content clash that does not exist, while the actual fix (go to that worktree and
# merge there, or remove it) was nowhere in the output. Under this plugin's own workflow --
# tp-request-merge exists precisely so that work happens in isolated worktrees -- an occupied
# branch is the ordinary case, not an edge one, so it does not fail the run either.
#
# Guard: if the main worktree is dirty at start we fail loudly before touching anything —
# merging into a dirty tree would be unsafe and the checkout dance would refuse anyway.
try {
    Probe-GitVersion

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot

    # Refuse to run from / against a dirty main worktree.
    # Read-Git, so the exit-code guard below is the PRIMARY path rather than a fallback. Written
    # inline as `2>$null | Out-String` this call throws on any stderr write under EAP=Stop, which
    # made the guard unreachable exactly when git had something to say -- and a git that merely
    # WARNS (dubious ownership) aborted the run outright (issue #128).
    $statusRes = Read-Git -Cwd $mainWorktree -GitArgs @('status', '--porcelain')
    # A non-zero exit with an EMPTY result would otherwise read as "clean" and bypass the dirty
    # check below, so the code is checked before the text is trusted.
    if ($statusRes.Code -ne 0) { throw "git status --porcelain failed (exit $($statusRes.Code)) in $mainWorktree" }
    $status = $statusRes.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($status)) {
        throw "Main worktree is dirty ($mainWorktree). Commit or stash changes before merging main into branches."
    }

    if ($Branch.Count -gt 0) {
        # Caller specified branches: validate each (exists, not main, not remote-svn/*).
        $targetBranches = @()
        foreach ($b in $Branch) {
            $name = ($b | Out-String).Trim()
            if ($name -eq '') { continue }

            if ($name -eq 'main' -or $name -match '^remote-svn/') {
                Write-Output "SKIP $name (not found / excluded)"
                continue
            }

            $exists = (Read-Git -Cwd $mainWorktree -GitArgs @('branch', '--list', $name)).Text.Trim()
            if ([string]::IsNullOrWhiteSpace($exists)) {
                Write-Output "SKIP $name (not found / excluded)"
                continue
            }

            $targetBranches += $name
        }
    } else {
        # Default: all local branches except 'main' and 'remote-svn/*'.
        $targetBranches = @(
            (Read-Git -Cwd $mainWorktree -GitArgs @('branch', '--format=%(refname:short)')).Text -split "`n" |
                ForEach-Object { $_.Trim() } |
                Where-Object { $_ -ne '' -and $_ -ne 'main' -and $_ -notmatch '^remote-svn/' }
        )
    }

    if ($targetBranches.Count -eq 0) {
        Write-Output 'No branches to merge into.'
        exit 0
    }

    $originalBranch = (Read-Git -Cwd $mainWorktree -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).Text.Trim()

    # Read the worktree list ONCE, with the failure checked. Letting a git failure fall through
    # would turn it into "no worktree has this branch", which reads exactly like the healthy
    # answer -- and the run would then walk into the very checkout failure this lookup exists to
    # report properly.
    $wt = Read-Git -Cwd $mainWorktree -GitArgs @('worktree', 'list', '--porcelain')
    if ($wt.Code -ne 0) { throw "git worktree list failed (exit $($wt.Code)) in $mainWorktree" }
    $wtLines = @($wt.Text -split "`n" | ForEach-Object { $_.Trim() })

    # Which worktree, if any, has a given branch checked out. Returns the normalized absolute
    # path, or ''. The path is normalized before it is ever compared: git reports Windows paths
    # as `C:/...` while other sources hand back `/c/...`, and comparing those two spellings is
    # false every single time without saying so.
    function Get-WorktreeForBranch {
        param([string]$Want)
        $cur = ''
        foreach ($line in $wtLines) {
            if ($line -like 'worktree *') {
                $cur = $line.Substring('worktree '.Length)
            } elseif ($line -eq "branch refs/heads/$Want") {
                if ($cur -ne '') { return (Get-NormalizedAbsolutePath $cur) }
                return ''
            }
        }
        return ''
    }

    $merged   = @()
    $conflict = @()
    $occupied = @()

    # NOTE on stderr handling (PS 5.1): git checkout/merge write progress to stderr even on
    # success (e.g. "Switched to branch 'x'"). Under EAP=Stop, redirecting that native stderr
    # with `2>$null` makes PS 5.1 wrap it as a terminating NativeCommandError. So we call git
    # BARE here (stderr flows to the inherited handle / parent's cmd redirect) and gate purely
    # on $LASTEXITCODE — matching Sync-FromSvn.ps1. `merge --abort` wants its noise swallowed,
    # and gets that from Read-Git, which discards stderr WITHOUT the `2>` redirect that causes
    # the throw (issue #128).
    foreach ($branch in $targetBranches) {
        # The main worktree holding it is fine -- that checkout is a no-op. Any OTHER worktree is
        # not: git refuses, and the refusal has nothing to do with the content.
        $branchWt = Get-WorktreeForBranch $branch
        if ($branchWt -ne '' -and $branchWt -ne $mainWorktree) {
            $occupied += $branch
            Write-Output "SKIP $branch (checked out at $branchWt)"
            continue
        }

        & git -C $mainWorktree checkout $branch
        if ($LASTEXITCODE -ne 0) {
            $conflict += $branch
            Write-Output "CONFLICT $branch (checkout failed)"
            continue
        }

        & git -C $mainWorktree merge main --no-ff -m "Merge branch 'main' into $branch"
        if ($LASTEXITCODE -ne 0) {
            # Read-Git, not `& git ... 2>$null | Out-Null` (issue #128): under EAP=Stop the `2>`
            # redirection turns git's stderr into a terminating error. This one sits INSIDE the
            # per-branch loop, so a throw here would leave the conflicted merge in progress, skip
            # every remaining branch, AND skip the "restore the branch we started on" step below.
            $null = Read-Git -Cwd $mainWorktree -GitArgs @('merge', '--abort')
            $conflict += $branch
            Write-Output "CONFLICT $branch (merge aborted)"
        } else {
            $merged += $branch
            Write-Output "OK $branch"
        }
    }

    # Restore the branch we started on.
    & git -C $mainWorktree checkout $originalBranch
    if ($LASTEXITCODE -ne 0) { throw "Could not switch back to original branch '$originalBranch'." }

    Write-Output ''
    Write-Output '─── Summary ─────────────────────────────────────────────────────────'
    Write-Output ("Merged cleanly: " + $(if ($merged.Count -gt 0) { $merged -join ', ' } else { '(none)' }))
    Write-Output ("CONFLICT (aborted): " + $(if ($conflict.Count -gt 0) { $conflict -join ', ' } else { '(none)' }))
    # Printed only when it happened, unlike the two lines above. Those two are the run's outcome
    # and are always worth stating; this one is an exceptional condition needing a different
    # action from the reader, and a permanent `(none)` would train them to stop reading the line.
    if ($occupied.Count -gt 0) {
        Write-Output ("Skipped (checked out elsewhere): " + ($occupied -join ', '))
    }

    # Only a real conflict fails the run. An occupied branch does not: see the header -- under
    # this plugin's workflow that is the ordinary state of every branch someone is working on,
    # and a run that fails whenever a linked worktree exists reports nothing anyone can act on.
    if ($conflict.Count -gt 0) { exit 1 }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
