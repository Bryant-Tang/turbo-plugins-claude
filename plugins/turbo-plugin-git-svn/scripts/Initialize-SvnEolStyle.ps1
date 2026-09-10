[CmdletBinding()]
param(
    [string]$Branch = 'main',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = '',
    [switch]$Preview,
    # How many files go into each SVN commit. The whole point of this command is one pass over every
    # text file in the tree, so on a big repository the transaction is enormous and the server times
    # out in `Committing transaction` -- AFTER the data has transmitted, which is the worst place for
    # it because a timeout means "no answer", not "no commit" (issue #177). Smaller transactions
    # finish quickly, and the window in which nobody knows what happened shrinks with them.
    [int]$BatchSize = 1000,
    # Clear stale working-copy locks left behind by an interrupted commit. Off by default: it is a
    # local-only repair, but it is still a change the user did not ask for, so the SKILL asks first.
    [switch]$CleanupLocks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# One-time migration: put svn:eol-style=native on every text file already in SVN, so the repository
# stores LF and each working copy gets its own platform's line endings -- the arrangement git
# already has with GitHub. Until this runs, files that predate the change carry no property and SVN
# stores whatever bytes it was handed, which is how a repository ends up holding both LF and CRLF
# versions of the same kind of file (issues #164, #167).
#
# The push path sets the property on whatever it commits, so an unmigrated repository converges
# file by file on its own. This command is for the rest of the tree -- the files nobody has touched.
#
# -Preview reports what would change and exits without leaving anything behind. Use it first: the
# mixed line-ending list it prints is the part that needs a human, since those files are excluded
# permanently and the reason is invisible afterwards.
#
# The SVN commits it makes have no git counterpart. That is safe because they are PROPERTY-ONLY:
# the pull path's replay marks a revision whose tree matches its parent and makes no git commit
# (Invoke-SvnReplayCommit's SKIP:empty), and tp:last-aligned-rev tracks branch-to-trunk alignment,
# not git-to-SVN pairing. Content must never ride along here -- that is what would reach SVN and
# never come back into git.
#
# It commits in BATCHES (-BatchSize, default 1000) rather than one transaction over the whole tree.
# The file count is the size of the repository by design, and a transaction that large times out on
# the server during `Committing transaction` -- after the data has transmitted, which is the worst
# place for it: a timeout means "no answer", not "no commit" (issue #177). Smaller transactions
# finish quickly, a failure costs only the batch it happened in, and the batches already committed
# stay committed -- rerunning does what is left.

Probe-GitVersion

if ([string]::IsNullOrWhiteSpace($Branch)) { $Branch = 'main' }

$mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
$worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree
$remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir
$bridge = $remote.Path

if (-not (Test-Path -LiteralPath $bridge -PathType Container)) {
    throw "Remote worktree '$($remote.Name)' not found at: $bridge. Run /tp-setup to bootstrap the bridge."
}

# ---- pre-flight -------------------------------------------------------------
# Put the bridge in the EOL mode the tree actually calls for BEFORE asking whether it is clean.
# "Is this bridge dirty?" has no answer until the mode is right: git reading platform endings while
# pinned to LF reports every marked file as modified, and that is indistinguishable here from real
# pending work. Versions up to 0.8.0 left exactly that state behind -- see the closing refresh at
# the end of this script -- and the guard below then refused to run, so the command that creates
# the state could not be used to clear it either.
Set-BridgeEolModeOnce -Bridge $bridge

# The bridge must be clean on BOTH sides. This commit is meant to contain property changes and
# nothing else; pending work here would be swept into it, and a property-only revision is exactly
# the kind the pull path skips -- so anything that rode along would reach SVN and never come back
# into git.
$gitDirty = (Read-Git -Cwd $bridge -GitArgs @('status', '--porcelain')).Text.Trim()
if (-not [string]::IsNullOrWhiteSpace($gitDirty)) {
    throw "The bridge worktree has uncommitted git changes; resolve them first:`n$gitDirty"
}

if ($BatchSize -lt 1) { throw "-BatchSize must be at least 1, got $BatchSize" }

Push-Location -LiteralPath $bridge
try {
    $rawStatus = @(& svn status)

    # Locks first, and reported as their own thing. An interrupted commit leaves the working copy
    # locked -- column 3 of `svn status` is `L`, and a big interrupted commit leaves THOUSANDS of
    # them (1373 directories in the report behind issue #177). Every later svn operation is refused
    # until `svn cleanup` clears them. Folding that into "the bridge has pending SVN changes" is
    # what made this undiagnosable: the message named the wrong problem, and the fix it implied
    # does not work.
    $locked = @($rawStatus | Where-Object { $_ -and $_.Length -ge 3 -and $_.Substring(2, 1) -eq 'L' })
    if ($locked.Count -gt 0) {
        if ($CleanupLocks) {
            Write-Output "Clearing $($locked.Count) stale working-copy lock(s) left by an interrupted commit..."
            & svn cleanup
            if ($LASTEXITCODE -ne 0) { throw 'svn cleanup failed. Run `svn cleanup` in the bridge worktree by hand.' }
            $rawStatus = @(& svn status)
        } else {
            throw @"
The bridge worktree holds $($locked.Count) stale working-copy lock(s).
An interrupted svn commit leaves these behind, and every svn operation is refused until
they are cleared. This is a LOCAL repair -- it does not touch SVN:
  svn cleanup   (run in $bridge)
Or rerun this command with -CleanupLocks to have it done for you.
"@
        }
    }

    $svnDirty = @($rawStatus | Where-Object { $_ -and ($_ -notmatch '^\?') })
    if ($svnDirty.Count -gt 0) {
        throw "The bridge worktree has pending SVN changes; resolve them first:`n$($svnDirty -join "`n")"
    }

    Write-Output 'Updating the bridge to the latest SVN revision...'
    & svn update --quiet
    if ($LASTEXITCODE -ne 0) { throw 'svn update failed.' }
} finally {
    Pop-Location
}

# ---- classify ---------------------------------------------------------------
$classified = @(Get-SvnEolClassification -Worktree $bridge)
$candidates = @($classified | Where-Object { $_.Bucket -eq 'candidate' } | ForEach-Object { $_.Path })
$binaryCount = @($classified | Where-Object { $_.Bucket -eq 'binary' }).Count
$mixedPaths = @($classified | Where-Object { $_.Bucket -eq 'mixed' } | ForEach-Object { $_.Path })

$setCount = 0
$targetsFile = $null
try {
    # How many will actually CHANGE is answered by doing it and asking svn, not by comparing this
    # path list against `svn propget -R`. That comparison looks obvious and is a trap: propget
    # prints ABSOLUTE paths (even when given '.') while git prints repo-relative ones, the drive
    # letter's case differs between the two, and on Windows one side can hand back an 8.3 short
    # name -- `melwu~1` against `Mel Wu` -- so the prefix strip silently matches nothing and every
    # file reads as "not yet marked". Setting a property to the value it already holds is a no-op
    # to svn, so the honest way to count is to set them all and let svn say which ones moved.
    if ($candidates.Count -gt 0) {
        $targetsFile = [System.IO.Path]::GetTempFileName()
        $targets = @($candidates | ForEach-Object { ConvertTo-SvnTarget -Path $_ })
        Write-SvnTargetsFile -Path $targetsFile -Targets $targets
        # `svn propset --targets` stops at the first file it cannot mark and leaves every file
        # BEFORE it staged -- on a large tree that is tens of thousands of pending property
        # changes. Saying only "nothing was committed" is true of SVN and quite wrong about the
        # working copy: the bridge is left dirty, the pre-flight then refuses to run again, and
        # the reason is not discoverable from anything the user can see.
        #
        # Reverting is safe here for exactly the reason it is safe on the -Preview path below: the
        # pre-flight refused to start on a bridge carrying any pending SVN change, so the only
        # thing there is to revert is what this script staged seconds ago. Unlike a failed COMMIT
        # there is nothing worth keeping for a retry -- the propset is cheap to redo and the
        # commit never happened.
        Push-Location -LiteralPath $bridge
        try {
            $propsetOk = $false
            try {
                & svn propset svn:eol-style native --quiet --targets $targetsFile
                $propsetOk = ($LASTEXITCODE -eq 0)
            } catch {
                # PS 5.1 with $ErrorActionPreference = 'Stop' turns anything a native exe writes to
                # stderr into a terminating NativeCommandError, so the exit-code test above never
                # runs for the failure that actually happens here -- the one that prints E200009.
                # Without this catch the revert below is unreachable, which is the entire bug.
                $propsetOk = $false
            }
            if (-not $propsetOk) {
                $reverted = $false
                try {
                    & svn revert -R --quiet '.'
                    $reverted = ($LASTEXITCODE -eq 0)
                } catch {
                    $reverted = $false
                }
                if ($reverted) {
                    throw 'svn propset failed; nothing was committed. The property changes this run had already staged were reverted, so the bridge worktree is back to the state it was in before this run.'
                }
                throw 'svn propset failed; nothing was committed. The revert failed as well, so the bridge worktree still holds staged property changes -- clear them by running `svn revert -R .` there before rerunning.'
            }
        } finally {
            Pop-Location
        }
    }

    # Column 2 of `svn status` is the property status. Counting characters rather than parsing
    # paths keeps this immune to the console codepage.
    Push-Location -LiteralPath $bridge
    try {
        $setCount = @(& svn status | Where-Object { $_.Length -ge 2 -and $_.Substring(1, 1) -eq 'M' }).Count
    } finally {
        Pop-Location
    }

    Write-Output ''
    Write-Output "Branch:            $Branch  ($bridge)"
    Write-Output "Text files:        $($candidates.Count)"
    Write-Output "  already marked:  $($candidates.Count - $setCount)"
    Write-Output "  to mark:         $setCount"
    Write-Output "Skipped, binary:   $binaryCount"
    Write-Output "Skipped, mixed:    $($mixedPaths.Count)"
    if ($mixedPaths.Count -gt 0) {
        Write-Output ''
        Write-Output 'These files have BOTH LF and CRLF line endings. svn refuses to commit such a file once'
        Write-Output 'svn:eol-style is set, so they are excluded and will keep whatever endings they have.'
        Write-Output 'Normalise them in git first if you want them covered:'
        foreach ($m in $mixedPaths) { Write-Output "  $m" }
    }

    # The property changes are already staged at this point -- that is how the count above was
    # obtained. Preview therefore has to put the tree back exactly as it found it. `svn revert -R`
    # is safe here and only here: the pre-flight refused to run on a bridge with any pending SVN
    # change, so the only thing to revert is what this script just staged.
    if ($Preview) {
        Push-Location -LiteralPath $bridge
        try {
            & svn revert -R --quiet '.'
            if ($LASTEXITCODE -ne 0) {
                throw 'Could not revert the staged property changes. Run `svn revert -R .` in the bridge worktree.'
            }
        } finally {
            Pop-Location
        }
        Write-Output ''
        Write-Output 'Preview only -- the staged property changes were reverted, nothing was changed.'
        return
    }

    if ($setCount -eq 0) {
        Write-Output ''
        Write-Output 'Every text file already carries svn:eol-style=native. Nothing to do.'
        return
    }

    # ---- apply --------------------------------------------------------------
    $msgFile = [System.IO.Path]::GetTempFileName()
    try {
        # svn:auto-props on this tree's root so files added later by ANY client -- not just through
        # this plugin -- get the property too. It is SVN's counterpart to committing a
        # .gitattributes: shared, versioned, and applied at `svn add` time. Derived from the
        # extensions actually present, because SVN matches auto-props by filename pattern and has
        # no content heuristic to fall back on.
        $autoProps = Get-SvnAutoPropsValue -Path $candidates
        Push-Location -LiteralPath $bridge
        try {
            if ($autoProps) {
                & svn propset svn:auto-props $autoProps --quiet '.'
                if ($LASTEXITCODE -ne 0) { throw 'Could not set svn:auto-props on the branch root.' }
            }

            $svnHttpTimeout = 3600
            $chunkFile = [System.IO.Path]::GetTempFileName()
            $batchIndex = 0
            $totalBatches = [int][math]::Ceiling($candidates.Count / [double]$BatchSize)
            $totalCommits = $totalBatches
            if ($autoProps) { $totalCommits = $totalBatches + 1 }

            # What to say when a commit does not answer. Everything here is downstream of one fact:
            # a timeout means "no reply", not "no commit" -- and the server can finish the
            # transaction LONG after it gave up talking. Reported in the wild: the script said the
            # commit failed, an immediate check of the path showed nothing had changed, and two
            # hours later that same path carried this script's own commit message. The commit had
            # succeeded all along. So the guidance is deliberately NOT "here is how to check" --
            # it is "do not check yet".
            function Get-CommitFailureText {
                param([int]$Batch, [int]$Total, [string]$Url)
                $target = if ($Url) { """$Url""" } else { '<the branch URL>' }
                $done = ''
                if ($Batch -gt 1) {
                    $done = @"

Batches 1 to $($Batch - 1) are already committed and are not affected. Only this one is in
doubt, and rerunning this command will redo just what is left.
"@
                }
                return @"
svn commit failed on batch $Batch of $Total.
$done
THIS IS AN UNDETERMINED STATE. The commit may have succeeded or failed, and you cannot tell
right now -- that is what a timeout [E175012] means. A large transaction can finish on the
server minutes after it stopped answering, so anything you check at this moment only
describes this moment.

Do this instead:
  1. WAIT a few minutes. Do not conclude anything yet.
  2. Then look at the newest log entry for THIS BRANCH PATH -- not at the repository.
     Revision numbers are shared repository-wide, so an unrelated commit by someone else
     moves the HEAD without your commit having landed:
       svn log --limit 1 $target
     If its message starts with "Set svn:eol-style=native", it is this command and the
     commit landed. That message is the identifier -- nothing else writes it.
  3. Landed  -> run ``svn update`` in the bridge and rerun this command for the rest.
     Did not -> rerun this command; the staged property changes are still there and the
                propset step does NOT have to be repeated.

Do NOT ``svn revert`` before you know which of the two it was: that throws away a pending
set you may still need, and redoing it means propsetting every file again.

An interrupted commit also leaves working-copy locks behind, and every later svn operation
is refused until they are cleared. That repair is local only and does not touch SVN:
``svn cleanup`` in the bridge, or rerun this command with -CleanupLocks.
"@
            }

            # Commit one batch. The message's first line is a fixed, recognisable string on
            # purpose: after a timeout it is the only thing that tells a user whether the revision
            # on the server is theirs.
            function Invoke-BatchCommit {
                param([string]$Label, [string[]]$Targets, [string]$MsgPath, [string]$ChunkPath, [int]$Timeout)
                Write-SvnTargetsFile -Path $ChunkPath -Targets $Targets
                Write-Utf8NoBom -Path $MsgPath -Content @"
Set svn:eol-style=native on $Label

Line endings are now normalised by SVN on commit, so the repository stores LF
and each working copy gets its own platform's endings.
"@
                try {
                    # --depth empty keeps the root target from recursing; explicit file targets
                    # still commit.
                    #
                    # `| Out-Host` is load-bearing, not cosmetic. A PowerShell function returns
                    # EVERYTHING left on its output stream, so an unpiped `& svn` puts svn's own
                    # "Committing transaction... Committed revision N." lines into the return
                    # value. The caller's `if (-not (Invoke-BatchCommit ...))` then tests an array
                    # rather than the boolean -- a non-empty array is truthy, so `-not` is always
                    # false and the failure branch is UNREACHABLE. CI caught exactly that: the
                    # pre-commit hook rejected the commit and the script still exited 0. Out-Host
                    # keeps the progress visible while leaving the stream clean.
                    & svn commit --file $MsgPath --encoding UTF-8 --depth empty `
                        --targets $ChunkPath --config-option "servers:global:http-timeout=$Timeout" | Out-Host
                    return ($LASTEXITCODE -eq 0)
                } catch {
                    return $false
                }
            }

            try {
                # The declaring revision goes out FIRST, on its own, before a single file batch.
                # That ordering is load-bearing once the run can be interrupted between batches:
                # svn:auto-props on the root IS the signal the bridge reads to decide whether to
                # pin git to LF. Declared first, an interrupted run leaves the bridge following
                # the platform, consistent with the files already marked and harmless for the rest.
                # Declared last, it would leave thousands of files carrying svn:eol-style while the
                # bridge is still pinned to LF -- and the next update makes every one of them read
                # as modified.
                if ($autoProps) {
                    $batchIndex = 1
                    Write-Output 'Declaring the tree: svn:auto-props on the branch root, so new files inherit the property.'
                    if (-not (Invoke-BatchCommit -Label 'the branch root [declaring the tree]' -Targets @('.') -MsgPath $msgFile -ChunkPath $chunkFile -Timeout $svnHttpTimeout)) {
                        $u = ''
                        try { $u = (& svn info --show-item url 2>$null | Out-String).Trim() } catch { $u = '' }
                        throw (Get-CommitFailureText -Batch 1 -Total $totalCommits -Url $u)
                    }
                }

                Write-Output "Committing the property changes in batches of $BatchSize..."
                $chunk = New-Object System.Collections.Generic.List[string]
                foreach ($c in $candidates) {
                    $chunk.Add((ConvertTo-SvnTarget -Path $c))
                    if ($chunk.Count -ge $BatchSize) {
                        $batchIndex++
                        Write-Output "  batch $batchIndex of ${totalCommits}: $($chunk.Count) file(s)"
                        if (-not (Invoke-BatchCommit -Label "$($chunk.Count) text file(s) [batch $batchIndex of $totalCommits]" -Targets $chunk.ToArray() -MsgPath $msgFile -ChunkPath $chunkFile -Timeout $svnHttpTimeout)) {
                            $u = ''
                            try { $u = (& svn info --show-item url 2>$null | Out-String).Trim() } catch { $u = '' }
                            throw (Get-CommitFailureText -Batch $batchIndex -Total $totalCommits -Url $u)
                        }
                        $chunk.Clear()
                    }
                }
                if ($chunk.Count -gt 0) {
                    $batchIndex++
                    Write-Output "  batch $batchIndex of ${totalCommits}: $($chunk.Count) file(s)"
                    if (-not (Invoke-BatchCommit -Label "$($chunk.Count) text file(s) [batch $batchIndex of $totalCommits]" -Targets $chunk.ToArray() -MsgPath $msgFile -ChunkPath $chunkFile -Timeout $svnHttpTimeout)) {
                        $u = ''
                        try { $u = (& svn info --show-item url 2>$null | Out-String).Trim() } catch { $u = '' }
                        throw (Get-CommitFailureText -Batch $batchIndex -Total $totalCommits -Url $u)
                    }
                }

                # More than one commit leaves a MIXED-REVISION working copy: `svn commit` only
                # bumps what it committed, so the root sits at the declaring revision while the
                # files sit at later ones. Anything that then asks "what revision is this working
                # copy at?" gets the root's answer -- the pull path does exactly that, and it would
                # position the whole copy back at that older revision, undoing the property changes
                # on disk and leaving every file reading as modified. One update makes it uniform.
                try {
                    & svn update --quiet
                    if ($LASTEXITCODE -ne 0) {
                        Write-Warning 'svn update after the migration failed; run it in the bridge worktree so the working copy is at a single revision.'
                    }
                } catch {
                    Write-Warning 'svn update after the migration failed; run it in the bridge worktree so the working copy is at a single revision.'
                }

                # The tree now DECLARES svn:eol-style, which is the one thing that flips the
                # bridge's EOL mode -- and this is the only command that can flip it. The update
                # above just wrote platform endings [CRLF on Windows] for every file it marked,
                # while the bridge is still pinned to LF, so git reads the whole tree as modified.
                # Every guard that asks "is this bridge clean?" then fires at once: measured on
                # 0.8.0, a successful migration left /tp-pull-from-svn, /tp-push-to-svn AND a rerun
                # of this command all refusing, each naming changes the user never made.
                #
                # It has to be re-read here rather than left to the next command, for the same
                # reason the bootstrap re-reads it after declaring: the mode is a fact about the
                # tree, and this script is what changed the tree.
                try {
                    Set-BridgeEolMode -MainWorktree $mainWorktree -Bridge $bridge
                } catch {
                    Write-Warning 'Could not re-read the bridge line-ending mode. Run /tp-pull-from-svn to have it done.'
                }
            } finally {
                Remove-Item -LiteralPath $chunkFile -Force -ErrorAction SilentlyContinue
            }
        } finally {
            Pop-Location
        }
    } finally {
        Remove-Item -LiteralPath $msgFile -Force -ErrorAction SilentlyContinue
    }

    Write-Output ''
    Write-Output "Done. $setCount file(s) now carry svn:eol-style=native."
    if ($mixedPaths.Count -gt 0) {
        Write-Output "$($mixedPaths.Count) file(s) were left out because their line endings are mixed (listed above)."
    }
} finally {
    if ($targetsFile) { Remove-Item -LiteralPath $targetsFile -Force -ErrorAction SilentlyContinue }
}
