[CmdletBinding()]
param(
    [string]$N = '',
    [string]$SvnUrl = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required' }

    $mainWorktree = Get-MainWorktree
    $projName = [System.IO.Path]::GetFileName($mainWorktree)
    $worktreesDir = Join-Path ([System.IO.Path]::GetDirectoryName($mainWorktree)) "$projName.worktrees"

    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        throw "Worktrees directory not found: $worktreesDir. Run /tp-setup first to bootstrap."
    }

    if ([string]::IsNullOrWhiteSpace($N)) {
        $maxN = 0
        Get-ChildItem -LiteralPath $worktreesDir -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^remote-test-(\d+)$' } | ForEach-Object {
            $num = [int]$Matches[1]
            if ($num -gt $maxN) { $maxN = $num }
        }
        $idx = $maxN + 1
    } else {
        if ($N -notmatch '^\d+$') { throw "Invalid value for -N: '$N'. Must be a positive integer." }
        $idx = [int]$N
    }

    $testBranch = "test-$idx"
    $remoteBranch = "remote/test-$idx"
    $remoteWorktreeName = "remote-test-$idx"
    $remoteWorktreePath = Join-Path $worktreesDir $remoteWorktreeName

    $existingBranches = (& git -C $mainWorktree branch --list $testBranch | Out-String).Trim()
    if ($existingBranches) { throw "Branch '$testBranch' already exists." }
    if (Test-Path -LiteralPath $remoteWorktreePath) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    Write-Output "Creating test environment $idx..."

    $initCommit = (& git -C $mainWorktree rev-list --max-parents=0 HEAD | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "git rev-list failed" }

    # v0.2.7+ fix: git mutations 移進 rollback try 內,讓 trap 覆蓋 git branch + worktree add
    # 失敗的情況。原本在 try 外,若 git branch $testBranch 失敗 → outer catch 只 emit
    # stderr + exit 1,留下半建好的 $remoteBranch orphan,下次撞名失敗。
    try {
        & git -C $mainWorktree branch $remoteBranch $initCommit
        if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

        & git -C $mainWorktree branch $testBranch 'main'
        if ($LASTEXITCODE -ne 0) { throw "git branch $testBranch failed" }

        & git -C $mainWorktree worktree add $remoteWorktreePath $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & svn info $SvnUrl 2>$null | Out-Null
        $svnExists = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEAP

        if (-not $svnExists) {
            $remotemainPath = Join-Path $worktreesDir 'remote-main'
            $mainSvnUrl = (& svn info --show-item url $remotemainPath | Out-String).Trim()
            if ($LASTEXITCODE -ne 0) { throw "Could not get main SVN URL from remote-main worktree." }
            Write-Output "SVN path '$SvnUrl' does not exist. Creating from '$mainSvnUrl'..."
            & svn copy $mainSvnUrl $SvnUrl -m "create $testBranch branch"
            if ($LASTEXITCODE -ne 0) { throw "svn copy failed" }
        } else {
            Write-Output "SVN path exists, will checkout: $SvnUrl"
        }
        Write-Output "Running: svn checkout --force $SvnUrl $remoteWorktreePath"
        # --force: `git worktree add` already created `.git` (pointer file) + init-commit content
        # (init.txt) in the worktree path; svn would otherwise mark these as "obstructed/conflict"
        # and svn commit would refuse. --force treats existing files as already-versioned.
        & svn checkout --force $SvnUrl $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

        # CRITICAL: untrack `.git` from svn working copy BEFORE setting svn:ignore.
        # `--force` checkout added `.git` (git pointer file) to svn-managed state; if we leave it,
        # the next svn commit will push `.git` to permanent SVN history, polluting test branches for
        # everyone who checks out (with a `.git` pointing to the original committer's local path).
        # `--keep-local` removes it from svn versioning but keeps the file on disk (git still uses it).
        Push-Location $remoteWorktreePath
        try {
            $gitFile = Join-Path $remoteWorktreePath '.git'
            if (Test-Path -LiteralPath $gitFile) {
                & svn rm --keep-local '.git' 2>$null | Out-Null
                if ($LASTEXITCODE -ne 0) {
                    # If .git wasn't tracked yet (e.g., --force didn't add it), svn rm fails harmlessly
                    Write-Verbose 'svn rm .git: not tracked (ok)'
                }
            }
        } finally {
            Pop-Location
        }

        $remotemainPath = Join-Path $worktreesDir 'remote-main'
        $ignoreToApply = '.git' + [System.Environment]::NewLine + '.gitignore'
        if (Test-Path -LiteralPath $remotemainPath -PathType Container) {
            # v0.2.6 fix: `2>$null` alone does NOT prevent PS 5.1 + StrictMode + EAP=Stop from
            # treating native exe stderr (svn W200017 warning) as a terminating NativeCommandError.
            # Wrap in nested try/catch so the "Property 'svn:ignore' not found" warning is
            # swallowed at the call site rather than bubbling to the outer rollback catch.
            $inherited = ''
            try {
                $inherited = (& svn propget svn:ignore $remotemainPath 2>$null | Out-String).Trim()
            } catch {
                # W200017 ("Property 'svn:ignore' not found") is normal for a clean remote-main;
                # keep $inherited as empty so default $ignoreToApply is used below.
                $inherited = ''
            }
            if (-not [string]::IsNullOrWhiteSpace($inherited)) {
                $ignoreToApply = $inherited
            }
        }
        # v0.2.7+ F-U16.bridge fix: sync main's current .gitignore into remote-test-N BEFORE
        # svn commit. SVN's test-N was svn-copied from main SVN whose .gitignore may be older
        # than main git's current .gitignore. Without this sync, test-N (= main HEAD .gitignore vN)
        # and remote/test-N (svn checkout .gitignore vN-k) diverge → first tp-push-to-svn必撞
        # add/add merge conflict on .gitignore + .svn/wc.db(後者因 .gitignore 沒含 .svn/* rule)。
        $mainGitignore = Join-Path $mainWorktree '.gitignore'
        $peerGitignore = Join-Path $remoteWorktreePath '.gitignore'
        if (Test-Path -LiteralPath $mainGitignore -PathType Leaf) {
            Copy-Item -LiteralPath $mainGitignore -Destination $peerGitignore -Force
            Write-Output "Synced main's .gitignore into remote-test-$idx for first-push consistency."
        }

        Push-Location $remoteWorktreePath
        try {
            & svn propset svn:ignore $ignoreToApply '.'
            if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
            # svn commit picks up both the propset and the .gitignore content sync (if main differs).
            & svn commit -m 'svn:ignore: copy from remote-main; sync .gitignore from main'
            if ($LASTEXITCODE -ne 0) { throw 'svn commit svn:ignore failed' }
        } finally {
            Pop-Location
        }
    } catch {
        # Rollback: best-effort cleanup of any partial git+svn state, then rethrow.
        # Inner try covers git branch + worktree add + svn copy/checkout/propset/commit;
        # any of these failing triggers full rollback. Each `git worktree remove` /
        # `branch -D` silently skips if the target didn't exist (e.g., first git branch failed).
        Write-Output "Setup failed; rolling back partial git+svn state..."
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath 2>$null | Out-Null
        & git -C $mainWorktree branch -D $remoteBranch 2>$null | Out-Null
        & git -C $mainWorktree branch -D $testBranch 2>$null | Out-Null
        throw
    }

    Write-Output ""
    Write-Output "Test environment $idx created."
    Write-Output "  Branch        : $testBranch  (use 'git checkout $testBranch' in main worktree)"
    Write-Output "  SVN worktree  : $remoteWorktreePath"
    Write-Output ""
    Write-Output "Next step: run '/tp-pull-from-svn --branch $testBranch' to complete the initial SVN sync."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
