[CmdletBinding()]
param(
    [string]$Branch = '',
    [string]$SvnUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Internal helper: create the git<->SVN bridge for an EXISTING local branch
# on its first push. Generalized from the old New-RemoteTest (no test-<n> numbering;
# takes an explicit -Branch + -SvnUrl). It does NOT create a working branch -- the
# working branch is already the caller's current branch; this only creates the
# remote-svn/<branch> bridge branch + worktree + svn checkout.

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($Branch)) { throw '-Branch is required' }
    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required' }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        throw "Worktrees directory not found: $worktreesDir. Run /tp-setup first to bootstrap."
    }

    # Resolve + sanitize the branch: rejects unsafe names and computes the bridge
    # ref + worktree dir, with the MAX_PATH guard.
    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    $remoteBranch       = $remote.Branch   # remote-svn/<branch>
    $remoteWorktreeName = $remote.Name     # remote-svn-<branch-dash>
    $remoteWorktreePath = $remote.Path

    # Collision: reject if a DIFFERENT existing remote-svn branch maps to the same
    # worktree dir name (e.g. feat/login vs feat-login). Enumerate live bridges and
    # strip the 'remote-svn/' prefix to recover the original branch names.
    $existingRemote = @(
        & git -C $mainWorktree branch --list 'remote-svn/*' |
        ForEach-Object { $_.TrimStart('*', ' ').Trim() } |
        Where-Object { $_ -like 'remote-svn/*' } |
        ForEach-Object { $_.Substring('remote-svn/'.Length) }
    )
    $collision = Find-RemoteWorktreeCollision -BranchName $Branch -ExistingBranches $existingRemote
    if ($null -ne $collision) {
        throw "Worktree name '$remoteWorktreeName' is already taken by branch '$collision' (maps to the same directory). Rename your branch to avoid the collision."
    }

    # Bridge-only already-exists guard. No working-branch creation in the push-bootstrap
    # model -- the working branch IS the caller's current branch. Detect the inconsistent
    # partial states (ref XOR dir) left by an interrupted run and give explicit recovery
    # steps instead of a dead-end "already exists" that blocks the advertised re-run.
    # NOTE: the unit tests distinguish the two arms by their UNIQUE wording -- the ref-without-dir
    # arm says 'git branch -D', the dir-without-ref arm says 'delete that directory'. If you
    # reword these two throws, update New-RemoteBridge.test.ps1 / new-remote-bridge.test.sh to match.
    $existingBridge = (& git -C $mainWorktree branch --list $remoteBranch | Out-String).Trim()
    $worktreeExists = Test-Path -LiteralPath $remoteWorktreePath
    if ($existingBridge -and -not $worktreeExists) {
        throw "Inconsistent bridge state: branch '$remoteBranch' exists but its worktree directory is missing ($remoteWorktreePath) -- likely a leftover from an interrupted first push. To recover, run in the main worktree ($mainWorktree): 'git worktree prune', then 'git branch -D $remoteBranch'; then re-run the first push."
    }
    if ($worktreeExists -and -not $existingBridge) {
        throw "Inconsistent bridge state: the worktree directory exists ($remoteWorktreePath) but branch '$remoteBranch' is missing -- likely a leftover from an interrupted first push. To recover, delete that directory and run 'git worktree prune' in the main worktree ($mainWorktree); then re-run the first push."
    }
    if ($existingBridge) { throw "Bridge branch '$remoteBranch' already exists." }
    if ($worktreeExists) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    # SECURITY (KTD-8): validate $SvnUrl under the trusted repos-root BEFORE any git/svn
    # mutation. Trust base = remote-svn-main's repos-root-url. This MUST run outside
    # (before) the rollback try below so a rejected URL produces ZERO side effects.
    $remotemainPath = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-main')
    $null = Assert-TrustedSvnUrl -TrustedWorkingCopy $remotemainPath -CandidateUrl $SvnUrl

    Write-Output "Creating SVN bridge for branch '$Branch'..."

    # Base the new bridge branch on remote-svn/main's tip (the git mirror of trunk). The SVN feature
    # path below is `svn copy`d from trunk, so its git side must start from trunk's mirror -- this
    # keeps the post-checkout worktree content matching the branch tree (no untracked-overwrite on
    # the first push merge) and gives the merge-back a recent common ancestor.
    # NOT `rev-list --max-parents=0 HEAD`: once the repo has been through a bridge merge it has
    # MULTIPLE root commits (the empty native root + each `sync:` import root), so that returned a
    # multi-line value that broke `git branch` with "not a valid object name". remote-svn/main is
    # always a single commit and always exists here (it is the trust anchor validated above).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $baseRef = (& git -C $mainWorktree rev-parse --verify -q 'refs/heads/remote-svn/main' 2>$null | Out-String).Trim()
    $baseOk = ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($baseRef))
    $ErrorActionPreference = $prevEAP
    if (-not $baseOk) { throw "Bridge anchor branch 'remote-svn/main' not found. Run /tp-setup first to bootstrap the main bridge." }

    # Use the SANITIZED dash-form (not raw user input) for the svn copy commit message
    # so control characters can never enter SVN's permanent history.
    $svnMsgBranch = $remoteWorktreeName

    try {
        & git -C $mainWorktree branch $remoteBranch $baseRef
        if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

        & git -C $mainWorktree worktree add $remoteWorktreePath $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & svn info $SvnUrl 2>$null | Out-Null
        $svnExists = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEAP

        if (-not $svnExists) {
            $mainSvnUrl = (& svn info --show-item url $remotemainPath | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Could not get main SVN URL from remote-svn-main worktree." }
            Write-Output "SVN path '$SvnUrl' does not exist. Creating from '$mainSvnUrl'..."
            & svn copy $mainSvnUrl $SvnUrl -m "create $svnMsgBranch branch"
            if ($LASTEXITCODE -ne 0) { throw "svn copy failed" }
        } else {
            # Idempotent re-entry: a prior run's `svn copy` is permanent, so a re-run
            # finds the path already present and takes the checkout branch (no re-copy).
            Write-Output "SVN path exists, will checkout: $SvnUrl"
        }
        Write-Output "Running: svn checkout --force $SvnUrl $remoteWorktreePath"
        # --force: `git worktree add` already created `.git` (pointer file) + init-commit
        # content in the worktree path; svn would otherwise mark these "obstructed" and
        # refuse to commit. --force treats existing files as already-versioned.
        & svn checkout --force $SvnUrl $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

        # Untrack `.git` from the svn working copy BEFORE setting svn:ignore. `--force`
        # added `.git` to svn-managed state; leaving it would push `.git` (pointing at the
        # original committer's local path) into permanent SVN history. `--keep-local`
        # removes it from svn versioning but keeps the file on disk for git.
        Push-Location $remoteWorktreePath
        try {
            $gitFile = Join-Path $remoteWorktreePath '.git'
            if (Test-Path -LiteralPath $gitFile) {
                & svn rm --keep-local '.git' 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) { Write-Verbose 'svn rm .git: not tracked (ok)' }
            }
        } finally {
            Pop-Location
        }

        # svn:ignore is fixed to exactly `.git` -- the one must-exclude path that the push
        # scripts' git check-ignore filter cannot catch (`.git` is not git-ignored yet shows
        # as `?` in `svn status`). Everything else the bridge should exclude
        # (bin/obj/.turbo-plugin/worktrees/ ...) lives in .gitignore and is filtered by
        # git check-ignore. No inheritance from remote-svn-main: a single fixed value avoids
        # inheriting a stale set that may omit `.git`.
        $ignoreToApply = '.git'
        # Sync main's current .gitignore into the bridge BEFORE svn commit so the bridge's
        # .gitignore matches main git HEAD (prevents a first-push add/add conflict). This
        # .gitignore content sync is independent of any .svn handling and is retained.
        $mainGitignore = Join-Path $mainWorktree '.gitignore'
        $peerGitignore = Join-Path $remoteWorktreePath '.gitignore'
        if (Test-Path -LiteralPath $mainGitignore -PathType Leaf) {
            Copy-Item -LiteralPath $mainGitignore -Destination $peerGitignore -Force
            Write-Output "Synced main's .gitignore into $remoteWorktreeName for first-push consistency."
        }

        Push-Location $remoteWorktreePath
        try {
            & svn propset svn:ignore $ignoreToApply '.'
            if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
            & svn commit -m 'svn:ignore=.git; sync .gitignore from main; drop .git from svn'
            if ($LASTEXITCODE -ne 0) { throw 'svn commit svn:ignore failed' }
        } finally {
            Pop-Location
        }
    } catch {
        # Rollback covers ONLY the local git side (branch + worktree). An already-executed
        # `svn copy` writes SVN's PERMANENT history and is NOT rolled back -- it remains as
        # an orphan SVN path. Re-running first-push is idempotent: `svn info` detects the
        # existing path and takes the checkout branch instead of re-copying.
        Write-Output "Bridge setup failed; rolling back local git state (an already-created SVN path is permanent)..."
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath 2>$null | Out-Null
        & git -C $mainWorktree branch -D $remoteBranch 2>$null | Out-Null
        throw
    }

    Write-Output ""
    Write-Output "SVN bridge created for branch '$Branch'."
    Write-Output "  Bridge branch : $remoteBranch"
    Write-Output "  SVN worktree  : $remoteWorktreePath"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
