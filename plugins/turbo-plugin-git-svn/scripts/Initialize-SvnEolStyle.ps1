[CmdletBinding()]
param(
    [string]$Branch = 'main',
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = '',
    [switch]$Preview
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
# This makes ONE SVN commit that has no git counterpart. That is safe: the pull path's replay marks
# a revision whose tree matches its parent and makes no git commit (Invoke-SvnReplayCommit's
# SKIP:empty), and tp:last-aligned-rev tracks branch-to-trunk alignment, not git-to-SVN pairing.

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
# The bridge must be clean on BOTH sides. This commit is meant to contain property changes and
# nothing else; pending work here would be swept into it, and a property-only revision is exactly
# the kind the pull path skips -- so anything that rode along would reach SVN and never come back
# into git.
$gitDirty = (Read-Git -Cwd $bridge -GitArgs @('status', '--porcelain')).Text.Trim()
if (-not [string]::IsNullOrWhiteSpace($gitDirty)) {
    throw "The bridge worktree has uncommitted git changes; resolve them first:`n$gitDirty"
}

Push-Location -LiteralPath $bridge
try {
    $svnDirty = @(& svn status | Where-Object { $_ -and ($_ -notmatch '^\?') })
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
        Push-Location -LiteralPath $bridge
        try {
            & svn propset svn:eol-style native --quiet --targets $targetsFile
            if ($LASTEXITCODE -ne 0) { throw 'svn propset failed; nothing was committed.' }
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
        $extensions = @($candidates |
            ForEach-Object { [System.IO.Path]::GetExtension($_) } |
            Where-Object { $_ } |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object -Unique)
        Push-Location -LiteralPath $bridge
        try {
            if ($extensions.Count -gt 0) {
                $autoProps = ($extensions | ForEach-Object { "*$_ = svn:eol-style=native" }) -join "`n"
                & svn propset svn:auto-props $autoProps --quiet '.'
                if ($LASTEXITCODE -ne 0) { throw 'Could not set svn:auto-props on the branch root.' }
                Write-Output 'Set svn:auto-props on the branch root so new files inherit the property.'
            }

            Write-Utf8NoBom -Path $msgFile -Content @"
Set svn:eol-style=native on $setCount text file(s)

Line endings are now normalised by SVN on commit, so the repository stores LF
and each working copy gets its own platform's endings.
"@
            Write-Output 'Committing the property change to SVN...'
            & svn commit --file $msgFile --encoding UTF-8
            if ($LASTEXITCODE -ne 0) {
                throw 'svn commit failed. The property changes are still pending in the bridge worktree.'
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
