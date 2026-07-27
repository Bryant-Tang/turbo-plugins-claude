[CmdletBinding()]
param(
    [string]$SvnUrl = '',
    [string]$Branch = 'main',
    [string]$Granularity = '',
    [string]$Range = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# First-bridge bootstrap for tp-setup case (a) "new git+SVN bridge" and case (b) "take over an
# existing git+SVN repo". A single re-invocable script that bridges the CURRENT repo to a given
# SVN URL and merges the SVN content into the current branch.
#
# This is the FIRST bridge, so there is NO trust anchor to compare against (KTD7): we do NOT call
# Assert-TrustedSvnUrl. Instead the URL is validated against an anchored scheme allowlist
# (http(s)/svn/file) which both rejects malformed URLs and blocks svn-arg injection.
#
# DIFFERS from New-RemoteBridge: git init + empty-main-first + orphan/clean of the bridge worktree
# + PLAIN svn checkout (no --force) + merge --allow-unrelated-histories. There is no svn copy here
# (the SVN URL already exists or is created out of band) and no branch-from-init.
#
# Re-invocability: the identity throw (step 4) leaves only a bare empty .git from `git init` (no
# commit); a re-run is a clean re-run. Mid-run failures after the bridge worktree/branch creation
# roll the LOCAL git side back; an already-executed `svn commit` (svn:ignore) is permanent and a
# re-run absorbs it. A MERGE_CONFLICT (step 13) is NOT rolled back -- the agent resolves it.

try {
    # ---- step 1: git available + new enough. ----
    Probe-GitVersion

    if ([string]::IsNullOrWhiteSpace($SvnUrl)) { throw '-SvnUrl is required' }
    if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = 'main' }

    # ---- step 2: URL format validation (anchored scheme allowlist; NO trust anchor exists). ----
    # Anchoring (^) + the scheme allowlist rejects malformed URLs AND blocks svn-arg injection
    # (e.g. a leading '-' or a non-URL token). This is intentionally NOT Assert-TrustedSvnUrl:
    # there is no trusted remote-svn-main yet to derive a repos-root from (KTD7).
    if ($SvnUrl -notmatch '^(https?|svn|file)://') {
        throw "Invalid SVN URL '$SvnUrl': only http(s)://, svn://, or file:// URLs are accepted."
    }

    # ---- step 3: git init -b main (idempotent; no identity needed). ----
    # MUST run before the identity check so a later `git config --local` has a repo to write to.
    # Only init when NOT already a repo: `git init -b main` on an existing repo prints
    # "warning: re-init: ignored --initial-branch" to STDERR, which throws under EAP=Stop (PS 5.1).
    # Skipping it on re-invoke / case (b) keeps the re-run clean and is still idempotent.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git rev-parse --git-dir 2>$null | Out-Null
    $alreadyRepo = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP
    if (-not $alreadyRepo) {
        & git init -b main
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    }

    $mainWorktree = Get-MainWorktree

    # ---- step 4: git identity check (merged local+global; plain reads, NOT --local). ----
    # `git commit` needs an identity. If EITHER name or email is empty, emit the token on stdout so
    # the agent can set identity and re-invoke; the bare .git from step 3 makes the re-run clean.
    $gitName = ''
    $gitEmail = ''
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $gitName = (& git -C $mainWorktree config user.name 2>$null | Out-String).Trim()
    $gitEmail = (& git -C $mainWorktree config user.email 2>$null | Out-String).Trim()
    $ErrorActionPreference = $prevEAP
    if ([string]::IsNullOrWhiteSpace($gitName) -or [string]::IsNullOrWhiteSpace($gitEmail)) {
        Write-Output 'TP_TOKEN:IDENTITY_REQUIRED'
        Write-Output 'git identity is not configured (user.name and/or user.email). Set them with:'
        Write-Output '  git config user.name "<your name>"'
        Write-Output '  git config user.email "<you@example.com>"'
        Write-Output 'then re-run.'
        exit 1
    }

    # ---- step 5: case split on "has root commit" (NOT ".git exists"). ----
    # EAP-safe HEAD probe: no HEAD is the NORMAL case (a) state, not a hard failure.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $mainWorktree rev-parse --verify HEAD 2>$null | Out-Null
    $hasRoot = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP
    if (-not $hasRoot) {
        # case (a): seed an empty root commit so the current branch ('main') has a HEAD to merge into.
        & git -C $mainWorktree commit --allow-empty -m 'chore: initial commit (turbo-plugin setup)'
        if ($LASTEXITCODE -ne 0) { throw 'git commit (initial empty commit) failed' }
    }
    # case (b) (has root commit): use the current branch as-is, no commit.

    # ---- step 6: resolve the bridge ref + worktree dir, with collision + partial-state guards. ----
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
    $remoteBranch       = $remote.Branch   # remote-svn/<branch>
    $remoteWorktreeName = $remote.Name     # remote-svn-<branch-dash>
    $remoteWorktreePath = $remote.Path

    # Collision: a DIFFERENT existing remote-svn branch mapping to the same worktree dir name.
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

    # Bridge already-exists / inconsistent partial-state (ref XOR dir) guards. SAME wording as
    # New-RemoteBridge -- the unit tests distinguish the two arms by their UNIQUE wording (the
    # ref-without-dir arm says 'git branch -D'; the dir-without-ref arm says 'delete that directory').
    $existingBridge = (& git -C $mainWorktree branch --list $remoteBranch | Out-String).Trim()
    $worktreeExists = Test-Path -LiteralPath $remoteWorktreePath
    if ($existingBridge -and -not $worktreeExists) {
        throw "Inconsistent bridge state: branch '$remoteBranch' exists but its worktree directory is missing ($remoteWorktreePath) -- likely a leftover from an interrupted bootstrap. To recover, run in the main worktree ($mainWorktree): 'git worktree prune', then 'git branch -D $remoteBranch'; then re-run /tp-setup."
    }
    if ($worktreeExists -and -not $existingBridge) {
        throw "Inconsistent bridge state: the worktree directory exists ($remoteWorktreePath) but branch '$remoteBranch' is missing -- likely a leftover from an interrupted bootstrap. To recover, delete that directory and run 'git worktree prune' in the main worktree ($mainWorktree); then re-run /tp-setup."
    }
    if ($existingBridge) { throw "Bridge branch '$remoteBranch' already exists." }
    if ($worktreeExists) { throw "Worktree '$remoteWorktreeName' already exists at: $remoteWorktreePath" }

    # ---- step 6.5 (U7): decide the first-import granularity from the URL's history, BEFORE creating
    # the bridge worktree, so a ">5 needs choice" exit leaves ZERO residue (a clean re-run). ----
    # headRev=0 (empty repo) or an empty log => LEGACY single import commit (today's shape). <=5
    # revisions => per-revision (silent). >5 => needs a granularity choice; absent one, emit the
    # structured token + exit 0 with nothing created (so the SKILL can prompt, then re-invoke).
    $eaSvn = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $headRevRaw = & svn info --show-item revision $SvnUrl 2>$null
    $svnInfoRc = $LASTEXITCODE
    $ErrorActionPreference = $eaSvn
    if ($svnInfoRc -ne 0) { throw "Could not read SVN revision from '$SvnUrl'. Is the URL reachable?" }
    $headRev = [int](($headRevRaw | Out-String).Trim())

    $firstRev = 0
    $importCount = 0
    if ($headRev -gt 0) {
        $eaSvn = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $importLogXml = (& svn log --xml -r "1:$headRev" $SvnUrl 2>$null | Out-String)
        $svnLogRc = $LASTEXITCODE
        $ErrorActionPreference = $eaSvn
        if ($svnLogRc -ne 0) { throw "Could not read SVN history from '$SvnUrl'." }
        $importRecs = @(Get-SvnRevisions -LogXml $importLogXml)
        $importCount = @($importRecs).Count
        if ($importCount -gt 0) { $firstRev = [int]$importRecs[0].Rev }
    }

    $mode = 'per-revision'
    if ($importCount -eq 0) {
        $mode = 'legacy-empty'
    }
    elseif ($importCount -gt $TpGranularityThreshold) {
        if ([string]::IsNullOrWhiteSpace($Granularity)) {
            Write-Output "TP_TOKEN:GRANULARITY_REQUIRED count=$importCount range=r$firstRev:r$headRev"
            exit 0
        }
        $mode = $Granularity
    }

    # The worktrees container does not exist yet on a first bootstrap; create it so `git worktree
    # add` has a parent. New-RemoteBridge can assume it exists (it runs post-setup); this script IS
    # the setup, so it must create it.
    if (-not (Test-Path -LiteralPath $worktreesDir)) {
        $null = New-Item -ItemType Directory -Path $worktreesDir -Force
    }

    Write-Output "Connecting current repo to SVN bridge '$remoteBranch'..."

    $svnRev = ''
    try {
        # ---- step 7: build the EMPTY bridge worktree (orphan branch, empty index + working tree). ----
        & git -C $mainWorktree worktree add --detach --no-checkout $remoteWorktreePath
        if ($LASTEXITCODE -ne 0) { throw "git worktree add $remoteWorktreeName failed" }

        & git -C $remoteWorktreePath checkout --orphan $remoteBranch
        if ($LASTEXITCODE -ne 0) { throw "git checkout --orphan $remoteBranch failed" }

        # Clear the index. Tolerate "pathspec '.' did not match" when the index is already empty
        # (EAP-safe: soften before the 2>$null redirect so a stderr write cannot throw).
        $eaRm = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & git -C $remoteWorktreePath rm -rf --cached . 2>$null | Out-Null
        $ErrorActionPreference = $eaRm

        & git -C $remoteWorktreePath clean -dffx
        if ($LASTEXITCODE -ne 0) { throw 'git clean -dffx failed in bridge worktree' }

        # ---- step 8 (U7): svn checkout (no --force; worktree empty except the .git pointer).
        # per-revision/range replay forward from the FIRST revision; squash/legacy start at HEAD. ----
        if ($mode -eq 'per-revision' -or $mode -eq 'range') {
            Write-Output "Running: svn checkout -r $firstRev $SvnUrl $remoteWorktreePath"
            & svn checkout -r $firstRev $SvnUrl $remoteWorktreePath
        } else {
            Write-Output "Running: svn checkout $SvnUrl $remoteWorktreePath"
            & svn checkout $SvnUrl $remoteWorktreePath
        }
        if ($LASTEXITCODE -ne 0) { throw 'svn checkout failed' }

        # ---- step 9b: keep svn metadata out of git for the WHOLE import, independent of .gitignore.
        # The bridge .gitignore can only be written AFTER the import (step 10 below explains why), so
        # `git add -A` needs a different ignore source while the replay runs. info/exclude is
        # repo-local, unversioned and idempotent -- and '.svn/' should never be tracked in this repo
        # anyway. Must be the repo's COMMON git dir: git reads info/exclude from there, not from a
        # linked worktree's own gitdir.
        $gitCommonDir = (& git -C $mainWorktree rev-parse --git-common-dir 2>$null | Out-String).Trim()
        if (-not [System.IO.Path]::IsPathRooted($gitCommonDir)) {
            $gitCommonDir = [System.IO.Path]::Combine($mainWorktree, $gitCommonDir)
        }
        $excludeDir = [System.IO.Path]::Combine($gitCommonDir, 'info')
        if (-not (Test-Path -LiteralPath $excludeDir -PathType Container)) {
            New-Item -ItemType Directory -Path $excludeDir -Force | Out-Null
        }
        $excludeFile = [System.IO.Path]::Combine($excludeDir, 'exclude')
        $excludeLines = @()
        if (Test-Path -LiteralPath $excludeFile -PathType Leaf) {
            $excludeLines = @([System.IO.File]::ReadAllLines($excludeFile))
        }
        if (-not ($excludeLines | Where-Object { $_.Trim() -eq '.svn/' })) {
            $excludeLines += '.svn/'
            [System.IO.File]::WriteAllLines($excludeFile, $excludeLines)
        }

        # ---- step 9: untrack .git from the svn working copy (tolerate "not tracked"). ----
        Push-Location $remoteWorktreePath
        try {
            if (Test-Path -LiteralPath (Join-Path $remoteWorktreePath '.git')) {
                $eaSvnRm = $ErrorActionPreference
                $ErrorActionPreference = 'SilentlyContinue'
                & svn rm --keep-local '.git' 2>$null | Out-Null
                $ErrorActionPreference = $eaSvnRm
            }
        } finally {
            Pop-Location
        }

        # ---- step 11 (U7): materialise the import commit(s) onto the orphan bridge branch. ----
        # legacy-empty (empty / no-content URL): today's single import commit. Otherwise reuse the
        # shared U3 enumerate+replay dispatch so the bootstrap and the steady-state pull mint
        # IDENTICAL commit shapes (author / date / trailer). cur = firstRev-1 so the loop starts at
        # firstRev.
        if ($mode -eq 'legacy-empty') {
            & git -C $remoteWorktreePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'git add -A failed in bridge worktree' }

            $eaInfo = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $svnRev = (& svn info --show-item revision $remoteWorktreePath 2>$null | Out-String).Trim()
            $ErrorActionPreference = $eaInfo

            & git -C $remoteWorktreePath diff --cached --quiet
            $hasStaged = ($LASTEXITCODE -ne 0)
            if ($hasStaged) {
                & git -C $remoteWorktreePath commit -m "sync: svn r$svnRev"
                if ($LASTEXITCODE -ne 0) { throw 'git commit of svn content failed' }
            } else {
                & git -C $remoteWorktreePath commit --allow-empty -m "init: remote-svn/$Branch branch"
                if ($LASTEXITCODE -ne 0) { throw 'git commit (empty bridge init) failed' }
            }
        } else {
            Invoke-SvnReplayDispatch -RemotePath $remoteWorktreePath -RemoteName $remoteWorktreeName -Cur ($firstRev - 1) -HeadRev $headRev -Mode $mode -Range $Range
        }

        # ---- step 10 (was BEFORE the import; moved AFTER it): ensure '.svn/' is in the bridge
        # .gitignore. Ordering is load-bearing. Writing this file while the WC sat at the OLDEST
        # revision created an UNVERSIONED .gitignore, and the replay then hit a tree conflict the
        # moment a later revision added its own ("An unversioned file was found in the working
        # copy") -- which used to HANG on svn's interactive conflict prompt. Done here the WC is
        # already at HEAD, so this is a plain modification (or a create SVN will never collide
        # with). Keeping '.svn/' out of the import commits no longer depends on this file -- the
        # replay helpers exclude it at `git add` time.
        $peerGitignore = Join-Path $remoteWorktreePath '.gitignore'
        $ignoreLines = @()
        if (Test-Path -LiteralPath $peerGitignore -PathType Leaf) {
            $ignoreLines = @([System.IO.File]::ReadAllLines($peerGitignore))
        }
        if (-not ($ignoreLines | Where-Object { $_.Trim() -eq '.svn/' })) {
            $ignoreLines += '.svn/'
            [System.IO.File]::WriteAllLines($peerGitignore, $ignoreLines)
        }
        # Fold it into the LAST import commit rather than adding one of its own: an extra non-merge
        # bridge commit with no 'svn-revision:' trailer is exactly the shape the pull path treats as
        # an orphaned sync, and a second commit carrying the HEAD trailer would break the floor
        # lookup's fail-loud-on-duplicate rule. Amending keeps message (trailer), author and date, so
        # the end state matches the squash path: the import commit at HEAD carries the .gitignore.
        $eaStatus = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $dirty = (& git -C $remoteWorktreePath status --porcelain 2>$null | Out-String).Trim()
        $ErrorActionPreference = $eaStatus
        if (-not [string]::IsNullOrWhiteSpace($dirty)) {
            & git -C $remoteWorktreePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'git add of bridge .gitignore failed' }
            & git -C $remoteWorktreePath rev-parse --verify --quiet HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & git -C $remoteWorktreePath -c commit.gpgsign=false commit --amend --no-edit
            } else {
                & git -C $remoteWorktreePath -c commit.gpgsign=false commit -m "init: remote-svn/$Branch branch"
            }
            if ($LASTEXITCODE -ne 0) { throw 'git commit of bridge .gitignore failed' }
        }

        # ---- step 12: pin svn:ignore=.git on the SVN side and commit it (permanent; re-run absorbs),
        # then `svn update` so the whole WC sits uniformly at SVN HEAD -- a subsequent
        # tp-pull-from-svn then resolves cur=HEAD and imports nothing (no double-import). ----
        Push-Location $remoteWorktreePath
        try {
            & svn propset svn:ignore '.git' '.'
            if ($LASTEXITCODE -ne 0) { throw 'svn propset svn:ignore failed' }
            & svn commit -m 'svn:ignore=.git (turbo-plugin bridge)'
            if ($LASTEXITCODE -ne 0) { throw 'svn commit (svn:ignore) failed' }
            & svn update
            if ($LASTEXITCODE -ne 0) { throw 'svn update (normalize to HEAD) failed' }
        } finally {
            Pop-Location
        }
        $eaFinal = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $svnRev = (& svn info --show-item revision $remoteWorktreePath 2>$null | Out-String).Trim()
        $ErrorActionPreference = $eaFinal
    } catch {
        # Rollback the LOCAL git side only. An already-executed `svn commit` is permanent and is NOT
        # rolled back (a re-run absorbs it). FIRST clear the ReadOnly attribute recursively on the
        # bridge dir -- SVN's .svn/pristine files are ReadOnly and otherwise block
        # `git worktree remove --force` with "Permission denied". Prune as a fallback in case the
        # dir could not be fully deleted (a held .svn handle), so a re-run isn't wedged into a false
        # "already exists".
        Write-Output 'Bridge setup failed; rolling back local git state (an already-executed svn commit is permanent)...'
        if (Test-Path -LiteralPath $remoteWorktreePath) {
            Get-ChildItem -LiteralPath $remoteWorktreePath -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $fa = [System.IO.File]::GetAttributes($_.FullName)
                    if ($fa -band [System.IO.FileAttributes]::ReadOnly) {
                        [System.IO.File]::SetAttributes($_.FullName, $fa -band (-bnot [System.IO.FileAttributes]::ReadOnly))
                    }
                } catch { }
            }
        }
        & git -C $mainWorktree worktree remove --force $remoteWorktreePath 2>$null | Out-Null
        & git -C $mainWorktree worktree prune 2>$null | Out-Null
        & git -C $mainWorktree branch -D $remoteBranch 2>$null | Out-Null
        throw
    }

    # ---- step 13: merge the bridge content into the current branch (OUTSIDE the rollback scope). ----
    # --allow-unrelated-histories because the orphan bridge branch shares no history with the
    # current branch. A conflict only happens in case (b) with overlapping files: emit the token
    # (conflicted files, space-separated) and leave the conflict in place for the agent/user --
    # do NOT `git merge --abort` and do NOT roll back.
    & git -C $mainWorktree merge --allow-unrelated-histories -m 'chore: connect SVN bridge via turbo-plugin' $remoteBranch
    $mergeRc = $LASTEXITCODE
    if ($mergeRc -ne 0) {
        $conflicts = (& git -C $mainWorktree diff --name-only --diff-filter=U | Out-String)
        $conflictList = (@($conflicts -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) -join ' ')
        Write-Output "TP_TOKEN:MERGE_CONFLICT $conflictList"
        exit 1
    }

    # ---- step 14: success summary. ----
    Write-Output ''
    Write-Output 'SVN bridge connected.'
    Write-Output "  Bridge branch : $remoteBranch"
    Write-Output "  SVN worktree  : $remoteWorktreePath"
    Write-Output "  SVN revision  : r$svnRev"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
