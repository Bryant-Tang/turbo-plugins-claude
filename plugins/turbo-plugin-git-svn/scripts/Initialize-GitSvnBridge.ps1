[CmdletBinding()]
param(
    [string]$SvnUrl = '',
    [string]$Branch = 'main',
    [string]$Granularity = '',
    [string]$Range = '',
    [switch]$AllowExistingRemote,
    [switch]$AllowNestedRepos,
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    # Load-bearing here more than anywhere else: this is the one script that can CREATE a repository,
    # so naming the target outright is the difference between bootstrapping the project the caller
    # meant and bootstrapping whatever checkout the process happened to be standing in.
    [string]$RepoRoot = ''
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

    # ---- step 3: wrong-repo guards, then git init -b main (idempotent; no identity needed). ----
    # `git init` MUST run before the identity check so a later `git config --local` has a repo to
    # write to. Only init when NOT already a repo: `git init -b main` on an existing repo prints
    # "warning: re-init: ignored --initial-branch" to STDERR, which throws under EAP=Stop (PS 5.1).
    # Skipping it on re-invoke / case (b) keeps the re-run clean and is still idempotent.
    #
    # When we ARE already in a repo, two guards run FIRST, before anything is mutated, so a refusal
    # leaves the repo byte-identical. Both exist because, absent -RepoRoot, this script resolves its
    # target from the AMBIENT cwd (git walks up from wherever it was invoked), so an invocation made
    # in the wrong directory silently bootstraps a bridge into a repo the caller never named. Passing
    # -RepoRoot removes that failure mode at the source; the guards stay because the ambient default
    # is still supported and still the common way this is called.
    $gitRoot = Resolve-GitRoot -RepoRoot $RepoRoot
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    & git -C $gitRoot rev-parse --git-dir 2>$null | Out-Null
    $alreadyRepo = ($LASTEXITCODE -eq 0)
    $ErrorActionPreference = $prevEAP
    if ($alreadyRepo) {
        # Guard 1 -- must be the MAIN worktree. From a linked worktree Get-MainWorktree resolves to
        # a DIFFERENT checkout, so we would create the bridge branch/worktree there and merge SVN
        # content into ITS current branch -- not the branch the caller is standing on. tp-setup
        # already routes peer worktrees to its "verify config only" case; this enforces the same
        # rule for callers that reach the script directly.
        if (-not (Test-IsMainWorktree -RepoRoot $RepoRoot)) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $here = (& git -C $gitRoot rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
            $ErrorActionPreference = $prevEAP
            if ([string]::IsNullOrWhiteSpace($here)) { $here = '<unknown>' }
            $msg = "Refusing to bootstrap an SVN bridge from a linked worktree.`n"
            $msg += "  you are in:    $here`n"
            $msg += "  would act on:  $(Get-MainWorktree -RepoRoot $RepoRoot)`n"
            $msg += 'Bootstrapping here would create the bridge branch and worktree in that OTHER checkout and merge SVN content into its current branch. Re-run from the main worktree instead.'
            throw $msg
        }

        # Guard 2 -- an existing git remote means this repo already has a git server, which is the
        # exact situation this plugin does NOT bridge (it exists for SVN-only teams). Far more often
        # than not it means the cwd was wrong. Not a hard refusal: emit a token so the agent can
        # confirm with the user in plain language and re-invoke with -AllowExistingRemote.
        if (-not $AllowExistingRemote) {
            $prevEAP = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $remoteNames = @(& git -C $gitRoot remote 2>$null)
            $ErrorActionPreference = $prevEAP
            $remoteNames = @($remoteNames | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($remoteNames.Count -gt 0) {
                $joined = ($remoteNames -join ' ')
                Write-Output "TP_TOKEN:EXISTING_GIT_REMOTE remotes=$joined"
                Write-Output "This repository already has git remote(s): $joined"
                Write-Output 'turbo-plugin bridges projects whose only shared server is SVN, so this is usually the wrong directory.'
                Write-Output 'Nothing was changed. Confirm with the user, then re-run with -AllowExistingRemote to proceed anyway.'
                exit 1
            }
        }
    } else {
        # Guard 3 -- not a repo HERE, but child directories are. That is the shape of a workspace
        # folder holding several independent projects side by side, and `git init` here would wrap
        # all of them into one repository: the wrong outcome, and one nothing later undoes. The two
        # guards above cannot catch it, because this directory genuinely has no git and `git
        # rev-parse` only searches UPWARD, never down. Not a hard refusal -- a real project can
        # legitimately contain a vendored sub-repo -- so emit a token and let the agent ask which
        # project was meant.
        if (-not $AllowNestedRepos) {
            $nested = @(Get-ChildItem -LiteralPath $gitRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { Test-Path -LiteralPath ([System.IO.Path]::Combine($_.FullName, '.git')) } |
                ForEach-Object { $_.Name })
            if ($nested.Count -gt 0) {
                $joined = ($nested -join ' ')
                Write-Output "TP_TOKEN:NESTED_GIT_REPOS dirs=$joined"
                Write-Output "This directory is not a git repository, but these subdirectories are: $joined"
                Write-Output 'Creating a repository here would wrap those separate projects into one.'
                Write-Output 'Nothing was changed. Switch to the project you meant, or re-run with -AllowNestedRepos if a repository really belongs here.'
                exit 1
            }
        }

        & git -C $gitRoot init -b main
        if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
    }

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot

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
    # Two failures hide behind one `svn info`, and they need opposite responses: the server being
    # unreachable is an environment problem, while the PATH not existing is normal and fixable right
    # here (nothing in this plugin ever ran `svn mkdir`, so a project's landing spot had to be
    # created by hand first -- even though case (a) of tp-setup advertises "brand new git + SVN").
    #
    # The old code collapsed both into "Is the URL reachable?" AND swallowed stderr, so pointing it
    # at a perfectly reachable repository with a typo'd path produced a message about reachability.
    # svn's own answer is precise -- `W170000: URL ... non-existent in revision N` -- it was just
    # discarded. So: keep svn's message, classify on it, and emit a token the SKILL can act on.
    # Both arms exit before anything is created, so a re-run after fixing is clean.
    $eaSvn = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    # Reading the message back off $Error is not paranoia -- it is the only thing that works here.
    # `svn` is a PowerShell FUNCTION (the --non-interactive shim in lib/Common.ps1), and on PS 5.1
    # a `2>&1` on a function call does NOT capture stderr produced by a native exe nested inside it:
    # the capture comes back empty and every failure then classifies as "unreachable" (measured).
    # $Error still receives the records, so diff it around the call. Newest-first, hence the reverse.
    $errBefore = $Error.Count
    & svn info $SvnUrl 2>$null | Out-Null
    $svnInfoRc = $LASTEXITCODE
    $svnInfoErr = ''
    if ($Error.Count -gt $errBefore) {
        $newErrors = @($Error[0..($Error.Count - $errBefore - 1)])
        [array]::Reverse($newErrors)
        $svnInfoErr = (($newErrors | ForEach-Object { $_.ToString() }) -join "`n")
    }
    $ErrorActionPreference = $eaSvn
    if ($svnInfoRc -ne 0) {
        if ($svnInfoErr -match 'non-existent in revision|W170000|E200009') {
            Write-Output "TP_TOKEN:SVN_PATH_MISSING url=$SvnUrl"
            [Console]::Error.WriteLine("Error: the repository is reachable, but '$SvnUrl' does not exist in it.")
        } else {
            Write-Output "TP_TOKEN:SVN_UNREACHABLE url=$SvnUrl"
            [Console]::Error.WriteLine("Error: could not reach the SVN repository for '$SvnUrl'.")
        }
        # svn's own words, verbatim -- they name the actual cause (auth, DNS, a typo'd path).
        [Console]::Error.WriteLine($svnInfoErr.Trim())
        exit 1
    }

    $eaSvn = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $headRevRaw = & svn info --show-item revision $SvnUrl 2>$null
    $svnInfoRc = $LASTEXITCODE
    $ErrorActionPreference = $eaSvn
    if ($svnInfoRc -ne 0) { throw "Could not read SVN revision from '$SvnUrl'." }
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
        # `git add -A` needs an ignore source that does not depend on whatever .gitignore SVN
        # happens to carry. info/exclude is repo-local, unversioned and idempotent -- and '.svn/'
        # should never be tracked in this repo anyway.
        Set-SvnGitExcluded -MainWorktree $mainWorktree

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

        # ---- step 10 (REMOVED): the bridge no longer invents a .gitignore. ----
        # It used to append '.svn/' to the bridge worktree's .gitignore here. That single line was
        # the sole cause of a guaranteed first-time conflict: the bridge branch and the project's
        # branch share no history, so `merge --allow-unrelated-histories` compares them with an
        # EMPTY base -- and git conflicts on add/add unless the two sides are byte-identical. A
        # project with any .gitignore at all (proj-2 had one line, `*.log`) therefore ALWAYS
        # conflicted, on a file whose only difference was the line this tool had just written.
        # Verified against git: identical content merges clean, a strict superset still conflicts.
        #
        # Nothing is lost by dropping it. '.svn/' must stay out of git for the import's
        # `git add -A`, and that is guaranteed independently by Set-SvnGitExcluded above
        # (info/exclude, which does not care what SVN carries); the project's own .gitignore gets
        # '.svn/' and '.turbo-plugin/worktrees/' appended by tp-setup right after this script
        # returns, and reaches SVN through the normal push. The bridge now mirrors exactly what SVN
        # has -- which is what a bridge is for.
        #
        # Keep the capture below: it is a fail-safe for anything the import left in the worktree,
        # not a consequence of the write that used to be here.
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
            $eaPre = $ErrorActionPreference
            $ErrorActionPreference = 'SilentlyContinue'
            $preAmendSha = (& git -C $remoteWorktreePath rev-parse --verify --quiet HEAD 2>$null | Out-String).Trim()
            $ErrorActionPreference = $eaPre
            & git -C $remoteWorktreePath add -A
            if ($LASTEXITCODE -ne 0) { throw 'git add of bridge .gitignore failed' }
            if (-not [string]::IsNullOrWhiteSpace($preAmendSha)) {
                & git -C $remoteWorktreePath -c commit.gpgsign=false commit --amend --no-edit
                if ($LASTEXITCODE -ne 0) { throw 'git commit of bridge .gitignore failed' }
                # The amend REWROTE that commit, so any refs/tp/svn/<N> still pointing at the
                # pre-amend SHA references an object no longer on the branch (it would read as an
                # unmarked, orphan-shaped commit). Move those markers onto the rewritten commit.
                $amendNewSha = (& git -C $remoteWorktreePath rev-parse HEAD 2>$null | Out-String).Trim()
                foreach ($m in (Get-SvnRevMarks -RepoDir $remoteWorktreePath)) {
                    if ($m.Sha -eq $preAmendSha) {
                        Set-SvnRevMark -RepoDir $remoteWorktreePath -Rev $m.Rev -Sha $amendNewSha
                    }
                }
            } else {
                & git -C $remoteWorktreePath -c commit.gpgsign=false commit -m "init: remote-svn/$Branch branch"
                if ($LASTEXITCODE -ne 0) { throw 'git commit of bridge .gitignore failed' }
            }
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
