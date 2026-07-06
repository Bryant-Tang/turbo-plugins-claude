[CmdletBinding()]
param(
    [string]$SvnUrl = '',
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# U11 (tp-checkout-svn-branch): one-step READ-ONLY import of an EXISTING SVN branch into a
# git<->SVN bridge + a content-filled working branch. Modeled on New-RemoteBridge but it
# NEVER writes to SVN: no `svn copy`, no `svn:ignore` propset, no `svn commit`. It only reads
# (`svn checkout`) and writes the local git side, so a rejected URL or a mid-run failure leaves
# the target SVN branch with NO new revision. The working branch descends from the
# remote-svn/<branch> bridge ref (KTD5) so the first /tp-pull-from-svn merge is not "unrelated
# histories".

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required (the existing SVN branch URL to import)' }

    $mainWorktree = Get-MainWorktree
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree
    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        throw "Worktrees directory not found: $worktreesDir. Run git-svn /tp-setup first to bootstrap."
    }

    # -- Resolve the working-branch name: -Branch, else sanitized SVN leaf. --
    $derived = $false
    if ([string]::IsNullOrWhiteSpace($Branch)) {
        $leaf = $SvnUrl.TrimEnd('/')
        $slash = $leaf.LastIndexOf('/')
        if ($slash -ge 0) { $leaf = $leaf.Substring($slash + 1) }
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            throw "Could not derive a branch name from the SVN URL '$SvnUrl'. Pass -Branch <name> explicitly."
        }
        $Branch = $leaf
        $derived = $true
    }

    # Resolve + sanitize (allowlist + MAX_PATH). On a derived leaf that fails the allowlist,
    # tell the user to pass -Branch explicitly rather than leaking the raw resolver error.
    try {
        $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    } catch {
        if ($derived) {
            throw "Derived branch name '$Branch' (from the SVN URL leaf) is not valid: $($_.Exception.Message) Pass -Branch <name> explicitly."
        }
        throw
    }
    $remoteBranch       = $remote.Branch   # remote-svn/<branch>
    $remoteWorktreeName = $remote.Name     # remote-svn-<branch-dash>
    $remoteWorktreePath = $remote.Path

    # -- Collision + partial-state guards (BEFORE any mutation; zero side effects on reject). --
    $existingRemote = @(
        & git -C $mainWorktree branch --list 'remote-svn/*' |
        ForEach-Object { $_.TrimStart('*', ' ').Trim() } |
        Where-Object { $_ -like 'remote-svn/*' } |
        ForEach-Object { $_.Substring('remote-svn/'.Length) }
    )
    $collision = Find-RemoteWorktreeCollision -BranchName $Branch -ExistingBranches $existingRemote
    if ($null -ne $collision) {
        throw "Worktree name '$remoteWorktreeName' is already taken by branch '$collision' (maps to the same directory). Pass -Branch <name> with a different name."
    }

    $existingBridge = (& git -C $mainWorktree branch --list $remoteBranch | Out-String).Trim()
    $worktreeExists = Test-Path -LiteralPath $remoteWorktreePath
    if ($existingBridge -and -not $worktreeExists) {
        throw "Inconsistent bridge state: branch '$remoteBranch' exists but its worktree directory is missing ($remoteWorktreePath) -- likely a leftover from an interrupted run. To recover, run in the main worktree ($mainWorktree): 'git worktree prune', then 'git branch -D $remoteBranch'; then re-run."
    }
    if ($worktreeExists -and -not $existingBridge) {
        throw "Inconsistent bridge state: the worktree directory exists ($remoteWorktreePath) but branch '$remoteBranch' is missing -- likely a leftover from an interrupted run. To recover, delete that directory and run 'git worktree prune' in the main worktree ($mainWorktree); then re-run."
    }
    if ($existingBridge) { throw "Bridge branch '$remoteBranch' already exists. The SVN branch is already imported; use /tp-pull-from-svn --branch $Branch to sync." }
    if ($worktreeExists) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    # R20: refuse to clobber an existing local working branch of the same name (zero side effects).
    $eaWb = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    $workBranchExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $eaWb
    if ($workBranchExists) {
        throw "A local branch '$Branch' already exists. Refusing to overwrite it. Pass -Branch <name> with a different name, or delete/rename the existing branch first."
    }

    # -- Precondition: remote-svn-main must be a valid SVN working copy (the trust anchor). --
    # Distinguish "directory missing" from "present but not a working copy" and carry svn's own
    # reason. Placed after the cheap git-only guards so a name/collision problem surfaces without
    # needing svn; still BEFORE any mutation. tp-checkout-svn-branch imports into an EXISTING
    # bridge; it does NOT bootstrap the main bridge.
    $remotemainPath = [System.IO.Path]::Combine($worktreesDir, 'remote-svn-main')
    if (-not (Test-Path -LiteralPath $remotemainPath -PathType Container)) {
        throw "remote-svn-main worktree not found at: $remotemainPath. Run git-svn /tp-setup first to bootstrap the main bridge (this skill imports into an existing bridge; it does not create the main bridge)."
    }
    $tmpErr = [System.IO.Path]::GetTempFileName()
    try {
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & svn info $remotemainPath 2>$tmpErr | Out-Null
        $svnInfoOk = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prevEAP
        $svnReason = ''
        if (Test-Path -LiteralPath $tmpErr) {
            $svnReason = ((Get-Content -LiteralPath $tmpErr -Raw -ErrorAction SilentlyContinue) | Out-String).Trim()
        }
    } finally {
        if (Test-Path -LiteralPath $tmpErr) { Remove-Item -LiteralPath $tmpErr -Force -ErrorAction SilentlyContinue }
    }
    if (-not $svnInfoOk) {
        throw "remote-svn-main exists at $remotemainPath but is not a valid SVN working copy (svn info failed). Reason: $svnReason. Re-run git-svn /tp-setup to repair the main bridge."
    }

    # -- SECURITY (R18 / KTD-8): validate the URL under the trusted repos-root BEFORE any --
    # mutation. Trust base = remote-svn-main's repos-root-url. Outside the rollback try so a
    # rejected URL produces ZERO side effects.
    $null = Assert-TrustedSvnUrl -TrustedWorkingCopy $remotemainPath -CandidateUrl $SvnUrl

    # The SVN branch must already exist (read-only import never creates it).
    $eaInfo = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & svn info $SvnUrl 2>$null | Out-Null
    $svnUrlExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $eaInfo
    if (-not $svnUrlExists) {
        throw "SVN branch does not exist (or is unreachable): $SvnUrl. tp-checkout-svn-branch imports an EXISTING branch read-only; it does not create SVN paths. Check the URL, or use /tp-push-to-svn first-push to create a new branch."
    }

    # The imported branch is based on remote-svn/main (the trunk mirror) so it shares history with
    # this repo's main; require that anchor ref up-front (before any mutation).
    $eaAnchor = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree rev-parse --verify -q 'refs/heads/remote-svn/main' 2>$null | Out-Null
    $anchorOk = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $eaAnchor
    if (-not $anchorOk) {
        throw "Bridge anchor branch 'remote-svn/main' not found. Run git-svn /tp-setup first to bootstrap the main bridge."
    }

    Write-Output "Importing SVN branch '$SvnUrl' into bridge '$remoteBranch' and working branch '$Branch'..."

    $workBranchCreated = $false
    try {
        # Base the bridge branch on remote-svn/main's tip (the trunk mirror) so the imported branch
        # SHARES HISTORY with this repo's main: an svn-copied branch descends from trunk, and this
        # reconstructs that link (git merge-base with main is non-empty; a later merge-back is not
        # "unrelated histories" and diffs/rebases against main behave). NOT an orphan (that produced
        # a disconnected single-root branch the user could not merge back) and NOT `rev-list
        # --max-parents=0 HEAD` (multi-root repos returned a multi-line value that broke `git branch`).
        # remote-svn/main is a single commit and was verified to exist above.
        & git -C $mainWorktree branch $remoteBranch 'remote-svn/main'
        if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

        & git -C $mainWorktree worktree add $remoteWorktreePath $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

        # EMPTY the worktree (keep the .git pointer) so the plain `svn checkout` below yields the EXACT
        # SVN branch tree. `git add -A` then records precisely the branch's delta from trunk
        # (adds/mods/deletes) as ONE commit whose parent is remote-svn/main.
        $eaRmIdx = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & git -C $remoteWorktreePath rm -rf . 2>$null | Out-Null
        $ErrorActionPreference = $eaRmIdx
        & git -C $remoteWorktreePath clean -dffx
        if ($LASTEXITCODE -ne 0) { throw 'git clean -dffx failed in bridge worktree' }

        # READ the SVN content onto the (empty) bridge worktree. PLAIN svn checkout (no --force):
        # the worktree is empty except the .git pointer file.
        Write-Output "Running: svn checkout $SvnUrl $remoteWorktreePath"
        & svn checkout $SvnUrl $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

        # Untrack `.git` from the svn working copy (pure-local WC fix; tolerate "not tracked").
        # We never svn-commit, so this never reaches SVN - it just keeps the WC tidy.
        Push-Location $remoteWorktreePath
        try {
            if (Test-Path -LiteralPath (Join-Path $remoteWorktreePath '.git')) {
                $eaRm = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                & svn rm --keep-local '.git' 2>$null | Out-Null
                $ErrorActionPreference = $eaRm
            }
        } finally {
            Pop-Location
        }

        # Bridge worktrees ARE svn working copies; the import commit must NOT capture `.svn/`.
        # Seed the bridge .gitignore from main's (so bin/obj/.turbo-plugin/worktrees are ignored
        # too), then GUARANTEE `.svn/` is present regardless of main's content. This runs BEFORE
        # `git add -A` so `.svn/` never enters the import commit.
        $peerGitignore = Join-Path $remoteWorktreePath '.gitignore'
        $mainGitignore = Join-Path $mainWorktree '.gitignore'
        $ignoreLines = @()
        if (Test-Path -LiteralPath $mainGitignore -PathType Leaf) {
            $ignoreLines = @([System.IO.File]::ReadAllLines($mainGitignore))
        } elseif (Test-Path -LiteralPath $peerGitignore -PathType Leaf) {
            $ignoreLines = @([System.IO.File]::ReadAllLines($peerGitignore))
        }
        if (-not ($ignoreLines | Where-Object { $_.Trim() -eq '.svn/' })) {
            $ignoreLines += '.svn/'
        }
        [System.IO.File]::WriteAllLines($peerGitignore, $ignoreLines)

        # Commit the branch's delta onto the bridge branch (a commit whose parent is remote-svn/main).
        # The working branch then descends from this commit, so it carries the content, connects to
        # main, and the first pull shares history with the bridge. When the SVN branch is identical to
        # trunk (no delta), seed an --allow-empty commit so the working branch still has a HEAD.
        & git -C $remoteWorktreePath add -A
        if ($LASTEXITCODE -ne 0) { throw 'git add -A failed in bridge worktree' }
        & git -C $remoteWorktreePath diff --cached --quiet
        $hasStaged = ($LASTEXITCODE -ne 0)
        if ($hasStaged) {
            & git -C $remoteWorktreePath commit -m "import: svn branch $remoteWorktreeName"
            if ($LASTEXITCODE -ne 0) { throw 'git commit of imported SVN content failed' }
        } else {
            & git -C $remoteWorktreePath commit --allow-empty -m "import: svn branch $remoteWorktreeName (empty)"
            if ($LASTEXITCODE -ne 0) { throw 'git commit (empty import) failed' }
        }

        # Create the working branch descending from the bridge ref (KTD5). Last mutation step.
        & git -C $mainWorktree branch $Branch $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git branch $Branch failed" }
        $workBranchCreated = $true
    } catch {
        # Rollback the LOCAL git side only. SVN was never written (read-only import), so the
        # target SVN branch has no new revision to undo.
        Write-Output 'Import failed; rolling back local git state (SVN was not modified)...'
        if ($workBranchCreated) {
            & git -C $mainWorktree branch -D $Branch 2>$null | Out-Null
        }
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath 2>$null | Out-Null
        # Prune the registration in case `worktree remove` could not fully delete the dir (e.g. a held
        # .svn handle) -- a surviving registration would wedge a re-run into a false "already imported".
        & git -C $mainWorktree worktree prune 2>$null | Out-Null
        & git -C $mainWorktree branch -D $remoteBranch 2>$null | Out-Null
        throw
    }

    Write-Output ''
    Write-Output "Imported SVN branch into a new working branch."
    Write-Output "  Working branch : $Branch"
    Write-Output "  Bridge branch  : $remoteBranch"
    Write-Output "  SVN worktree   : $remoteWorktreePath"
    Write-Output "  Next           : git checkout $Branch, then /tp-pull-from-svn --branch $Branch to sync later SVN changes."
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
