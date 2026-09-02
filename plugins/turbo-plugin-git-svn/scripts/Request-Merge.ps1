[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Branch,
    [string]$Base = 'main',
    # Perform the merge. Omit for the read-only report.
    [switch]$Merge,
    # Proceed even though $Base has commits $Branch does not (see the `behind` gate below).
    [switch]$AllowBehind,
    # Delete the source branch once $Base provably contains it. Requires -Merge.
    [switch]$DeleteBranch,
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# The stand-in for a pull request in a repo that has no git remote.
# See the .sh sibling for the full rationale and the routing contract; the two are behaviourally
# identical. In short: without a remote there is no PR, so nothing supplies the "a human pressed
# Merge" guarantee that `ExitWorktree`'s `remove` relies on when it deletes the branch. This
# script supplies it -- a read-only report by default, the merge itself only under -Merge.
#
# Emits exactly ONE terminal token line prefixed 'TP_TOKEN:'. Precedence (a total order):
#   ERROR > BRANCH_IS_BASE > BRIDGE_BRANCH > BRANCH_NOT_FOUND > BASE_NOT_FOUND > SOURCE_DIRTY
#         > MAIN_DIRTY > MAIN_DETACHED > BASE_ELSEWHERE > NOTHING_TO_MERGE > BEHIND_BASE
#         > READY                                                       (report mode)
#         > MERGED | CONFLICT                                           (-Merge mode)
#
# THE `behind` GATE
#   BEHIND_BASE is what a PR host means by "this branch is out of date with the base branch".
#   It is a gate rather than a line of prose because the failure it catches is silent: the report
#   has always printed `behind : N`, and a merge went ahead regardless, so the merged work was
#   never once seen alongside the state of $Base it was landing on. Two sides that each build can
#   still fail together, and nothing here would have said so. -AllowBehind is the deliberate
#   override the SKILL passes once the user has been shown the count and said to merge anyway.
#
#   CONSEQUENCE, and it is not an accident: CONFLICT is now only reachable WITH -AllowBehind. A
#   merge can only conflict if $Base moved since the branch forked -- and if $Base moved, the
#   branch is behind, so the gate fires first. That is the right order: the advice on a conflict
#   was always "merge $Base into the branch and resolve it there", which is exactly where the
#   gate sends the user, one step earlier and without a failed merge in between.
#
# DELETING THE SOURCE BRANCH (-DeleteBranch, requires -Merge)
#   A PR host offers "Delete branch" once the merge lands. Without that step the branch ref simply
#   stays, looking exactly like the branches still being worked on -- so the cost is not one stale
#   ref, it is that after a while nobody can tell which refs mean anything. `ExitWorktree`'s
#   `remove` does not cover it either: it belongs to the harness rather than this plugin, and the
#   branch may well have no worktree at all. Never the default and never unasked -- some branches
#   are merged somewhere and still wanted. READY and NOTHING_TO_MERGE carry `worktree=yes|no`,
#   which is what tells the SKILL whether deleting the ref is even the right question.
#
# -Merge re-runs every check before acting, so the gate the user was shown and the gate that
# admits the merge are the same code and cannot drift apart.

$PREFIX = 'TP_TOKEN:'

# Flips to $true once the ref names have passed validation. It is what lets the terminal catch
# tell the two kinds of failure apart: BEFORE this point a failure must stay TOKENLESS (a
# malformed name must never earn a routing token -- anti-forge), AFTER it every failure owes the
# SKILL a token, because the SKILL routes on nothing else.
$script:Validated = $false

# Terminal ERROR token for a POST-validation failure, so such a failure is never a tokenless
# non-zero exit. Pre-validation rejection stays tokenless (anti-forge). Newlines are collapsed
# and any embedded TP_TOKEN: neutralized so the reason cannot forge a routing line.
function Write-ErrorToken {
    param([string]$Reason)
    $r = ($Reason -replace "`r", ' ') -replace "`n", ' '
    $r = $r -replace 'TP_TOKEN:', 'TP_TOKEN_'
    Write-Output "${PREFIX}ERROR reason=$r"
}

# Every read below goes through `Read-Git` from the shared Core.ps1 (dot-sourced via Common.ps1
# above): it returns .Text (stdout) and .Code (exit code), with stderr discarded, and it is what
# makes $LASTEXITCODE reachable under PS 5.1 + EAP=Stop instead of pre-empted by a stderr throw.
# The full rationale lives on the function.
#
# This script used to carry its own copy. It cannot: the moment Core.ps1 grew the same helper
# (issue #123), the local definition shadowed it for the WHOLE script -- including inside
# Core's own Probe-GitVersion, which calls Read-Git with no -Cwd while the local copy always
# passed `-C ''`. Every invocation then died on `git -C '' --version` and the script answered
# "git CLI not available on PATH." with git plainly on PATH. Two same-named helpers in one
# dot-source chain is not duplication that merely risks drift; it is a live collision.

# NOTE on stderr handling (PS 5.1): git writes progress to stderr even on success, and on a
# conflicted merge it writes "Automatic merge failed" there too. Under EAP=Stop, a native
# command whose stderr PowerShell CAPTURES is wrapped as a terminating NativeCommandError -- so
# capturing the merge's output would throw straight past the `merge --abort` below and leave a
# conflicted tree, which is the one thing this script promises never to do. State-changing git
# calls are therefore made BARE (stderr flows to the inherited handle) and gated purely on
# $LASTEXITCODE. Only calls whose output we must read are captured, and only `merge --abort`
# (a recovery path whose noise is unwanted) is silenced.

try {
    Probe-GitVersion

    # Report mode is read-only and stays that way. Refusing the combination outright, rather than
    # ignoring the flag, keeps that promise checkable instead of relying on the caller's memory.
    # Before $script:Validated, so this stays a hard, TOKENLESS usage error like every other one.
    if ($DeleteBranch -and -not $Merge) {
        throw '-DeleteBranch requires -Merge (report mode never writes).'
    }

    # Validate BEFORE emitting any token (anti-forge): a malformed ref name is a hard, tokenless
    # error and never earns a routing token. check-ref-format is git's own validator, so this
    # tracks git's rules rather than a hand-rolled pattern. Refnames cannot contain ':' at all,
    # which is independently why a branch name cannot forge a 'TP_TOKEN:' line.
    foreach ($n in @($Branch, $Base)) {
        if ([string]::IsNullOrWhiteSpace($n)) { throw "A branch name must not be empty." }
        # Read-Git rather than an inline call in a try/catch: that catch could not tell "git
        # rejected the name" from "git wrote a warning to stderr", so a warning rejected a
        # perfectly valid branch name -- and tokenlessly, which is the loudest failure this
        # script has. Same defect as issue #123, one layer earlier. No -Cwd: check-ref-format
        # is a pure string check and never opens a repository.
        if ((Read-Git -GitArgs @('check-ref-format', "refs/heads/$n")).Code -ne 0) {
            throw "'$n' is not a valid branch name."
        }
    }
    $script:Validated = $true

    # Post-validation: resolution failures route as TP_TOKEN:ERROR.
    try {
        $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
    } catch {
        Write-ErrorToken $_.Exception.Message
        exit 1
    }

    # ── Guards, in precedence order ───────────────────────────────────────────────────

    if ($Branch -eq $Base) {
        Write-Output "${PREFIX}BRANCH_IS_BASE branch=$Branch"
        exit 0
    }

    # `remote-svn/*` are the SVN bridge branches, and this script must not touch either end of
    # one:
    #   - as $Base, this would merge work INTO the bridge -- exactly what Merge-MainIntoBranches
    #     excludes, and it pollutes the tree that gets committed back to SVN.
    #   - as $Branch, merging the bridge into a work branch is a real operation, but it belongs
    #     to tp-pull-from-svn, which also maintains the revision bookkeeping. Doing it here
    #     would produce the same merge commit with none of that state updated.
    # Refused by NAME, before the existence checks: the answer must not depend on whether the
    # bridge happens to exist yet.
    foreach ($n in @($Branch, $Base)) {
        if ($n -like 'remote-svn/*') {
            Write-Output "${PREFIX}BRIDGE_BRANCH name=$n"
            exit 0
        }
    }

    if ((Read-Git -Cwd $mainWorktree -GitArgs @('rev-parse', '--verify', '--quiet', "refs/heads/$Branch")).Code -ne 0) {
        Write-Output "${PREFIX}BRANCH_NOT_FOUND branch=$Branch"
        exit 0
    }
    if ((Read-Git -Cwd $mainWorktree -GitArgs @('rev-parse', '--verify', '--quiet', "refs/heads/$Base")).Code -ne 0) {
        Write-Output "${PREFIX}BASE_NOT_FOUND base=$Base"
        exit 0
    }

    # Read the worktree list ONCE, with the failure checked. Letting a git failure fall through
    # would turn it into "no worktree has this branch", which reads exactly like the healthy
    # answer and would make the SOURCE_DIRTY guard below pass without looking at anything.
    $wt = Read-Git -Cwd $mainWorktree -GitArgs @('worktree', 'list', '--porcelain')
    if ($wt.Code -ne 0) {
        Write-ErrorToken "git worktree list failed (exit $($wt.Code)) in $mainWorktree"
        exit 1
    }
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

    # The work must be fully committed. This is the guard that matters most for the case this
    # script exists for: the caller is about to merge and then let `remove` delete the branch and
    # its worktree. Anything still uncommitted there is not in the merge and does not survive the
    # removal -- and nothing else in the sequence would have said so.
    $sourceWt = Get-WorktreeForBranch $Branch
    if ($sourceWt -ne '') {
        $src = Read-Git -Cwd $sourceWt -GitArgs @('status', '--porcelain')
        if ($src.Code -ne 0) {
            Write-ErrorToken "git status --porcelain failed (exit $($src.Code)) in $sourceWt"
            exit 1
        }
        $srcStatus = $src.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($srcStatus)) {
            Write-Output "${PREFIX}SOURCE_DIRTY path=$sourceWt"
            exit 0
        }
    }

    $mn = Read-Git -Cwd $mainWorktree -GitArgs @('status', '--porcelain')
    if ($mn.Code -ne 0) {
        Write-ErrorToken "git status --porcelain failed (exit $($mn.Code)) in $mainWorktree"
        exit 1
    }
    $mainStatus = $mn.Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($mainStatus)) {
        Write-Output "${PREFIX}MAIN_DIRTY path=$mainWorktree"
        exit 0
    }

    # A detached main worktree has no branch to come back to. Merging anyway would check out
    # $Base and leave it there, quietly moving the user off the commit they had parked on.
    $originalBranch = (Read-Git -Cwd $mainWorktree -GitArgs @('symbolic-ref', '-q', '--short', 'HEAD')).Text.Trim()
    if ([string]::IsNullOrWhiteSpace($originalBranch)) {
        Write-Output "${PREFIX}MAIN_DETACHED path=$mainWorktree"
        exit 0
    }

    # The merge happens on $Base in the main worktree, so $Base has to be checkout-able there.
    # git forbids the same branch in two worktrees at once, so if $Base lives in some other
    # worktree the checkout would fail partway through. Say so up front instead.
    $baseWt = Get-WorktreeForBranch $Base
    if ($baseWt -ne '' -and $baseWt -ne $mainWorktree) {
        Write-Output "${PREFIX}BASE_ELSEWHERE base=$Base path=$baseWt"
        exit 0
    }

    # Reported on READY / NOTHING_TO_MERGE so the SKILL knows which question to ask: a branch with
    # a worktree is `ExitWorktree`'s to remove (ref and worktree together), one without is a plain
    # ref the user may want deleted here.
    $hasWt = if ($sourceWt -ne '') { 'yes' } else { 'no' }

    # Delete the source branch -- only on proof that $Base really contains it. Returns 'yes' or
    # 'no <reason-slug>'.
    #
    # The proof is `merge-base --is-ancestor` against the base actually merged into, NOT `git
    # branch -d`'s own verdict: -d judges "already merged" relative to the CURRENT HEAD, and the
    # main worktree is not necessarily parked on $Base. A branch genuinely merged into $Base is
    # routinely refused as `not fully merged` when asked from some third branch.
    # So the -D below is not "-d said no, force it anyway": -d is tried first as an independent
    # second opinion, and -D only ever runs on an ancestry proof that -d had no access to.
    function Invoke-BranchDeletion {
        # git refuses to delete a branch any worktree has checked out -- including the main one,
        # when the run started there. Answered here rather than left to git so the reason survives.
        if ($sourceWt -ne '') { return 'no has-worktree' }
        if ((Read-Git -Cwd $mainWorktree -GitArgs @('merge-base', '--is-ancestor', $Branch, $Base)).Code -ne 0) {
            return 'no not-ancestor'
        }
        if ((Read-Git -Cwd $mainWorktree -GitArgs @('branch', '-d', $Branch)).Code -eq 0) { return 'yes' }
        if ((Read-Git -Cwd $mainWorktree -GitArgs @('branch', '-D', $Branch)).Code -eq 0) { return 'yes' }
        return 'no delete-failed'
    }

    # Fields appended to the two tokens that can report a deletion, plus the human-readable line
    # that explains a refusal. `reason=` is present only when nothing was deleted, so
    # `deleted=yes` needs no second field to be unambiguous.
    $script:Deleted   = 'no'
    $script:DelReason = 'not-requested'
    $script:DelFields = ''
    function Invoke-DeleteStep {
        if ($DeleteBranch) {
            $res   = Invoke-BranchDeletion
            $parts = @($res -split ' ')
            $script:Deleted = $parts[0]
            if ($script:Deleted -eq 'no') { $script:DelReason = $parts[1] }
        }
        $script:DelFields = "deleted=$($script:Deleted)"
        if ($script:Deleted -eq 'no') { $script:DelFields += " reason=$($script:DelReason)" }

        if ($script:Deleted -eq 'yes') {
            Write-Output "Deleted branch '$Branch' (verified merged into '$Base')."
        } elseif ($DeleteBranch) {
            switch ($script:DelReason) {
                'has-worktree' { Write-Output "Branch '$Branch' was NOT deleted: it is checked out at $sourceWt." }
                'not-ancestor' { Write-Output "Branch '$Branch' was NOT deleted: '$Base' does not contain it." }
                default        { Write-Output "Branch '$Branch' was NOT deleted: git refused to remove the ref." }
            }
        }
    }

    # ── The report ────────────────────────────────────────────────────────────────────

    $rl = Read-Git -Cwd $mainWorktree -GitArgs @('rev-list', '--left-right', '--count', "$Base...$Branch")
    if ($rl.Code -ne 0) {
        Write-ErrorToken "git rev-list failed (exit $($rl.Code)) for $Base...$Branch"
        exit 1
    }
    $parts  = @($rl.Text.Trim() -split '\s+' | Where-Object { $_ -ne '' })
    $behind = [int]$parts[0]
    $ahead  = [int]$parts[1]

    if ($ahead -eq 0) {
        # Already fully in $Base, so this is the other place a deletion belongs: the branch is
        # exactly as safe to remove as it is after a merge, and telling the user "you can clean
        # this up" while leaving them to do it by hand is the same gap one step over.
        Invoke-DeleteStep
        Write-Output "${PREFIX}NOTHING_TO_MERGE branch=$Branch base=$Base worktree=$hasWt $($script:DelFields)"
        exit 0
    }

    $lg = Read-Git -Cwd $mainWorktree -GitArgs @('log', '--no-merges', '--reverse', '--format=  %h %s', "$Base..$Branch")
    if ($lg.Code -ne 0) {
        Write-ErrorToken "git log failed (exit $($lg.Code)) for $Base..$Branch"
        exit 1
    }
    $subjects = @(
        $lg.Text -split "`n" |
            ForEach-Object { $_.TrimEnd() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )
    $df = Read-Git -Cwd $mainWorktree -GitArgs @('-c', 'core.quotePath=false', 'diff', '--stat', "$Base...$Branch")
    if ($df.Code -ne 0) {
        Write-ErrorToken "git diff --stat failed (exit $($df.Code)) for $Base...$Branch"
        exit 1
    }
    $diffstat = ($df.Text -replace "`r", '').TrimEnd()

    Write-Output '─── Merge request ───────────────────────────────────────────────────'
    Write-Output "  branch : $Branch"
    Write-Output "  base   : $Base"
    Write-Output "  repo   : $mainWorktree"
    Write-Output "  ahead  : $ahead commit(s) not in $Base"
    Write-Output "  behind : $behind commit(s) in $Base not in $Branch"
    Write-Output ''
    Write-Output 'Commits to be merged (oldest first):'
    foreach ($s in $subjects) { Write-Output $s }
    if ($ahead -gt $subjects.Count) {
        Write-Output ("  (+ " + ($ahead - $subjects.Count) + " merge commit(s) not listed)")
    }
    Write-Output ''
    Write-Output "Changes vs ${Base}:"
    if (-not [string]::IsNullOrWhiteSpace($diffstat)) { Write-Output $diffstat } else { Write-Output '  (no file changes)' }
    if ($behind -gt 0) {
        Write-Output ''
        Write-Output "  NOTE: $Base has $behind commit(s) that $Branch does not. This work has never"
        Write-Output '        been built or checked alongside them.'
    }
    Write-Output '─────────────────────────────────────────────────────────────────────'

    # The `behind` gate. Placed AFTER the report on purpose: the counts and the commit list are
    # what the user needs in order to answer, so they get printed either way, and only the
    # terminal token differs. See the header for why this refuses by default.
    if ($behind -gt 0 -and -not $AllowBehind) {
        Write-Output "${PREFIX}BEHIND_BASE branch=$Branch base=$Base ahead=$ahead behind=$behind main=$mainWorktree"
        exit 0
    }

    if (-not $Merge) {
        Write-Output "${PREFIX}READY branch=$Branch base=$Base ahead=$ahead behind=$behind worktree=$hasWt main=$mainWorktree"
        exit 0
    }

    # ── The merge ─────────────────────────────────────────────────────────────────────

    # $originalBranch is known non-empty here: a detached main worktree was refused above.
    function Restore-OriginalBranch {
        if ($originalBranch -ne $Base) {
            & git -C $mainWorktree checkout $originalBranch
        }
    }

    if ($originalBranch -ne $Base) {
        & git -C $mainWorktree checkout $Base
        if ($LASTEXITCODE -ne 0) {
            Write-ErrorToken "could not check out '$Base' in $mainWorktree (exit $LASTEXITCODE)"
            exit 1
        }
    }

    & git -C $mainWorktree merge --no-ff $Branch -m "Merge branch '$Branch' into $Base"
    if ($LASTEXITCODE -ne 0) {
        # Read-Git even though nothing reads the output: `2>$null | Out-Null` is a CAPTURE, so
        # under EAP=Stop any stderr from the abort throws -- and this is the recovery path, so
        # that throw would jump past Restore-OriginalBranch and leave the conflicted tree the
        # header promises never to leave behind. Read-Git tolerates the stderr; the abort is
        # unconditional either way, exactly as before.
        $null = Read-Git -Cwd $mainWorktree -GitArgs @('merge', '--abort')
        Restore-OriginalBranch
        Write-Output ''
        Write-Output "Merge conflicted; '$Base' was left exactly as it was (merge aborted)."
        Write-Output "${PREFIX}CONFLICT branch=$Branch base=$Base"
        exit 1
    }

    # Tolerant on purpose, and it is the one place in the script where that is right: the merge
    # has ALREADY been written to $Base. Throwing here over a failure to pretty-print its sha
    # would report "not merged" about a branch that is merged -- the worst answer available.
    $mergeSha = ''
    try {
        $mergeSha = (Read-Git -Cwd $mainWorktree -GitArgs @('rev-parse', '--short', "refs/heads/$Base")).Text.Trim()
    } catch { $mergeSha = '' }
    if ([string]::IsNullOrWhiteSpace($mergeSha)) { $mergeSha = '(unknown)' }
    Restore-OriginalBranch
    Write-Output ''
    Write-Output "Merged '$Branch' into '$Base' as $mergeSha."
    # After Restore-OriginalBranch, so the run is standing where it will finish before any ref is
    # removed, and after the merge, so the ancestry proof inside is about the state that now exists.
    Invoke-DeleteStep
    Write-Output "${PREFIX}MERGED branch=$Branch base=$Base commit=$mergeSha $($script:DelFields)"
    exit 0
}
catch {
    # Any post-validation throw still owes the SKILL a routing token. Under EAP=Stop a native
    # git call whose output PowerShell CAPTURES is wrapped as a terminating NativeCommandError
    # the moment git writes ANYTHING to stderr -- `detected dubious ownership` is the common
    # trigger, and it fires exactly where this script runs (CI images, agent containers, a repo
    # owned by another user). Without this the script would exit 1 emitting no token at all,
    # breaking its own "exactly one terminal token" contract. The worst case it closes is a
    # throw AFTER the merge has been written: the SKILL would otherwise never learn that $Base
    # had already moved.
    if ($script:Validated) { Write-ErrorToken $_.Exception.Message }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
