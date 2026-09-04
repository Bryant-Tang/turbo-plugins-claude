[CmdletBinding()]
param(
    [string]$SvnUrl = '',
    [string]$Branch = '',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
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

# Collision + partial-state guards for a resolved branch name (BEFORE any mutation; zero side
# effects on reject). Factored so it can run twice: once on the SVN-leaf-derived name (git-only
# early reject, no svn needed) and again after R7 adopts the stored original branch name in the
# graded-resolution block below. $Remote is the Resolve-RemoteWorktree hashtable (.Name/.Branch/.Path).
function Assert-CheckoutNameFree {
    param(
        [Parameter(Mandatory = $true)][string]$MainWorktree,
        [Parameter(Mandatory = $true)][string]$Branch,
        [Parameter(Mandatory = $true)]$Remote
    )
    $existingRemote = @(
        & git -C $MainWorktree branch --list 'remote-svn/*' |
        ForEach-Object { $_.TrimStart('*', ' ').Trim() } |
        Where-Object { $_ -like 'remote-svn/*' } |
        ForEach-Object { $_.Substring('remote-svn/'.Length) }
    )
    $collision = Find-RemoteWorktreeCollision -BranchName $Branch -ExistingBranches $existingRemote
    if ($null -ne $collision) {
        throw "Worktree name '$($Remote.Name)' is already taken by branch '$collision' (maps to the same directory). Pass -Branch <name> with a different name."
    }

    $existingBridge = (& git -C $MainWorktree branch --list $Remote.Branch | Out-String).Trim()
    $worktreeExists = Test-Path -LiteralPath $Remote.Path
    if ($existingBridge -and -not $worktreeExists) {
        throw "Inconsistent bridge state: branch '$($Remote.Branch)' exists but its worktree directory is missing ($($Remote.Path)) -- likely a leftover from an interrupted run. To recover, run in the main worktree ($MainWorktree): 'git worktree prune', then 'git branch -D $($Remote.Branch)'; then re-run."
    }
    if ($worktreeExists -and -not $existingBridge) {
        throw "Inconsistent bridge state: the worktree directory exists ($($Remote.Path)) but branch '$($Remote.Branch)' is missing -- likely a leftover from an interrupted run. To recover, delete that directory and run 'git worktree prune' in the main worktree ($MainWorktree); then re-run."
    }
    if ($existingBridge) { throw "Bridge branch '$($Remote.Branch)' already exists. The SVN branch is already imported; use /tp-pull-from-svn --branch $Branch to sync." }
    if ($worktreeExists) { throw "Worktree '$($Remote.Name)' already exists at: $($Remote.Path)" }

    # R20: refuse to clobber an existing local working branch of the same name (zero side effects).
    $eaWb = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $MainWorktree rev-parse --verify --quiet "refs/heads/$Branch" 2>$null | Out-Null
    $workBranchExists = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $eaWb
    if ($workBranchExists) {
        throw "A local branch '$Branch' already exists. Refusing to overwrite it. Pass -Branch <name> with a different name, or delete/rename the existing branch first."
    }
}

try {
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required (the existing SVN branch URL to import)' }

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
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
    # First pass on the leaf-derived tentative name so the git-only rejects surface without svn.
    Assert-CheckoutNameFree -MainWorktree $mainWorktree -Branch $Branch -Remote $remote

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
        # .NET, not Remove-Item: -LiteralPath mangles a temp path whose user-profile segment is an
        # 8.3 short alias, and -ErrorAction cannot suppress it. See Submit-SvnCommit.ps1's cleanup.
        if (Test-Path -LiteralPath $tmpErr) { try { [System.IO.File]::Delete($tmpErr) } catch { } }
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

    # -- Graded fork-point resolution (U5, READ-ONLY: svn propget / svn log / git log). --
    # Rewire the import base from "remote-svn/main tip" to the git commit that replays the branch's
    # TRUE fork revision (R8-R11), so a later merge-back is not spurious-conflict-ridden. Everything
    # here is side-effect-free; every stop is a clean pre-mutation exit (outer catch -> exit 1) that
    # leaves NO bridge/worktree. remote-svn/main stays the trust anchor + SVN working copy; it is
    # just no longer the import base.

    # (a) Branch metadata (U2). Absent props read back empty (never an error).
    $storedName  = Get-TpBranchProp -Name 'branch-name'      -Target $SvnUrl
    $storedRev   = Get-TpBranchProp -Name 'last-aligned-rev' -Target $SvnUrl
    $copyfromRaw = Get-SvnBranchCopyfromRev -BranchUrl $SvnUrl   # '' when not a copied branch
    $copyfromRev = 0
    if ($copyfromRaw -match '^[0-9]+$') { $copyfromRev = [int]$copyfromRaw }

    # (b) R7: when -Branch was not passed, prefer the stored ORIGINAL git branch name (slashes
    # preserved) over the dash-form SVN leaf. Re-resolve + re-run the name guards against the FINAL
    # name (still pre-mutation, zero side effects).
    if ($derived -and -not [string]::IsNullOrWhiteSpace($storedName) -and $storedName -ne $Branch) {
        $Branch = $storedName
        $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
        $remoteBranch       = $remote.Branch
        $remoteWorktreeName = $remote.Name
        $remoteWorktreePath = $remote.Path
        Assert-CheckoutNameFree -MainWorktree $mainWorktree -Branch $Branch -Remote $remote
    }

    # (c) Target revision R + stale cross-check (R11 "stale-but-present"). tp:last-aligned-rev is
    # initialized to the branch's trunk copyfrom-rev and only advances, so a stored value BELOW the
    # copyfrom-rev is a provable contradiction -> refuse (never attach to a stale/contradicted base).
    if (-not [string]::IsNullOrWhiteSpace($storedRev)) {
        if ($storedRev -notmatch '^[0-9]+$') {
            throw "Branch metadata tp:last-aligned-rev on $SvnUrl is not a revision number ('$storedRev'). Refusing to guess a base; have the branch author repair it, then re-run this checkout."
        }
        $R = [int]$storedRev
        if ($R -lt $copyfromRev) {
            throw "Cannot attach: stored alignment r$R is older than the branch's fork revision r$copyfromRev, so the branch metadata looks stale/contradictory. Ask the branch author to refresh it (merge main into the branch and push), then re-run this checkout."
        }
    } else {
        # Pre-feature branch (metadata backfill is a deferred follow-up): fall back to the trunk
        # copyfrom-rev as the fork revision.
        $R = $copyfromRev
    }

    # (d) Grade R against cur (highest replayed revision on main) FIRST, then floor-resolve inside
    # the R<=cur region. Grading before the floor is load-bearing: under pure floor semantics an
    # R>cur target would silently floor onto the STALE cur commit and hide un-replayed trunk
    # revisions that may hold the true nearer fork (would regress AE3/R9).
    #
    # BUT grade on the EFFECTIVE revision, not on R itself. SVN revision numbers are
    # repository-global: r(cur+1)..R may consist entirely of commits to OTHER paths, in which case
    # trunk@R is byte-identical to trunk@cur and there is nothing to pull. Comparing R directly then
    # produced an UNBREAKABLE deadlock -- checkout demanded a pull, and the pull correctly reported
    # "already up to date" because trunk had no new revision, so every retry failed identically.
    # Real case: a branch copied from main@r52 while main's last actual change was r46.
    # $rEff = the newest revision <= R in which the trunk path ITSELF changed (`svn info` on a pegged
    # URL; read-only, one call). $rEff -gt $cur is then the genuine "trunk really has un-replayed
    # revisions" case AE3/R9 is about, and $rEff -le $cur correctly falls through to the floor
    # lookup. Fail-safe: if the probe cannot be resolved, fall back to R (previous behavior).
    $cur = Get-SvnHighestReplayedRev -RepoDir $mainWorktree
    $rEff = $R
    $prevEAPprobe = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $mainSvnUrl = (& svn info --show-item url $remotemainPath 2>$null | Out-String).Trim()
    if (-not [string]::IsNullOrWhiteSpace($mainSvnUrl)) {
        $probe = (& svn info --show-item last-changed-revision "$mainSvnUrl@$R" 2>$null | Out-String).Trim()
        if ($probe -match '^[0-9]+$') { $rEff = [int]$probe }
    }
    $ErrorActionPreference = $prevEAPprobe
    if ($rEff -gt $cur) {
        throw "Cannot attach: the branch's aligned trunk revision r$R is newer than the newest replayed revision on local main (r$cur). Pull trunk first: run /tp-pull-from-svn --branch main, then re-run this checkout."
    }
    $forkCommit = Get-SvnFloorCommit -RepoDir $mainWorktree -TargetRev $R
    if ([string]::IsNullOrWhiteSpace($forkCommit)) {
        throw "Cannot attach: the branch's aligned trunk revision r$R has no replayed commit on local main and cannot be pulled (it predates the earliest replayed revision, or its range was squashed away). Ask the branch author to merge main into the branch and push, then re-run this checkout."
    }
    # $forkCommit is the base ref for the bridge branch (replaces 'remote-svn/main' below): a real
    # ancestor on main carrying svn-revision <= R. The import machinery keeps the SVN branch tree;
    # only the import commit's PARENT moves to $forkCommit.

    Write-Output "Importing SVN branch '$SvnUrl' into bridge '$remoteBranch' and working branch '$Branch'..."

    $workBranchCreated = $false
    try {
        # Base the bridge branch on the FORK COMMIT resolved above (the replayed-trunk commit at the
        # branch's true fork revision, U5) so the imported branch shares history with this repo's main
        # AT the fork-point: a later merge-back is not spurious-conflict-ridden, and `git merge-base
        # main <branch>` resolves to $forkCommit. This is a base-ref SWAP only -- the import machinery
        # below (empty worktree -> svn checkout -> git add -A -> commit) captures the EXACT SVN branch
        # tree regardless of the base, so only the import commit's PARENT moves; a naive
        # `git branch <name> <forkCommit>` (trunk-at-fork content, no import commit) would be wrong.
        # $forkCommit is an ancestor on main and was verified non-empty above.
        & git -C $mainWorktree branch $remoteBranch $forkCommit
        if ($LASTEXITCODE -ne 0) { throw "git branch $remoteBranch failed" }

        & git -C $mainWorktree worktree add --no-checkout $remoteWorktreePath $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }
        # Pin the bridge to byte-faithful checkouts BEFORE anything materialises files. Order
        # matters: with core.autocrlf still true, the checkout writes CRLF and the files on disk
        # no longer match their blobs -- and for a bridge whose SVN side does not carry them yet,
        # that turns a harmless "phantom M" into a real diff the drift check would report.
        Set-BridgeEolPlatformNative -MainWorktree $mainWorktree -Bridge $remoteWorktreePath
        # --no-checkout leaves the index EMPTY, so populate explicitly; now the bytes on disk
        # are the bytes git stores.
        & git -C $remoteWorktreePath reset --hard --quiet
        if ($LASTEXITCODE -ne 0) { throw "git reset --hard in $remoteWorktreeName failed" }

        # EMPTY the worktree (keep the .git pointer) so the plain `svn checkout` below yields the EXACT
        # SVN branch tree. `git add -A` then records precisely the branch's delta from trunk
        # (adds/mods/deletes) as ONE commit whose parent is remote-svn/main.
        # The EAP softening is DELIBERATE and must stay (issue #128 classed this as "do not
        # convert"): `rm -rf .` legitimately writes "pathspec '.' did not match" when the index is
        # already empty, and under EAP=Stop the `2>` redirect would turn that into a terminating
        # error. Softening keeps it tolerated here while `git clean -dffx` below stays the loud
        # gate. Do not "tidy" this into Read-Git -- the point is that this one is allowed to fail.
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
        # Every step goes through Read-Git rather than `& git ... 2>$null | Out-Null` (issue #128):
        # under EAP=Stop a `2>` redirection turns whatever git writes to stderr into a TERMINATING
        # error, and `2>$null` does not prevent it. In a catch block that is doubly bad -- the
        # remaining rollback steps are skipped, AND the bare `throw` below never runs, so the user
        # is shown a NativeCommandError about a git warning instead of the import failure that
        # actually happened.
        if ($workBranchCreated) {
            $null = Read-Git -Cwd $mainWorktree -GitArgs @('branch', '-D', $Branch)
        }
        $null = Read-Git -Cwd $mainWorktree -GitArgs @('worktree', 'remove', '--force', $remoteWorktreePath)
        # Prune the registration in case `worktree remove` could not fully delete the dir (e.g. a held
        # .svn handle) -- a surviving registration would wedge a re-run into a false "already imported".
        $null = Read-Git -Cwd $mainWorktree -GitArgs @('worktree', 'prune')
        $null = Read-Git -Cwd $mainWorktree -GitArgs @('branch', '-D', $remoteBranch)
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
