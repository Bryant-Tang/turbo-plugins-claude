[CmdletBinding()]
param(
    [string]$Branch = 'main',
    [int]$Limit = 5,
    [string]$Revision = '',
    [switch]$VerboseOutput,
    # Optional explicit repository root; omit to act on the current directory (see Resolve-GitRoot).
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    if ($Limit -lt 1) {
        throw "Limit must be a positive integer (got '$Limit')."
    }

    $mainWorktree = Get-MainWorktree -RepoRoot $RepoRoot
    $worktreesDir = Get-WorktreesDir -MainWorktree $mainWorktree

    $remote = Resolve-RemoteWorktree -BranchName $Branch -WorktreesDir $worktreesDir

    if (-not (Test-Path -LiteralPath $remote.Path -PathType Container)) {
        throw "Remote worktree '$($remote.Name)' not found at: $($remote.Path)"
    }

    # Always invoke `svn log --xml`: SVN emits UTF-8 XML regardless of console
    # codepage, which avoids Big5/CP950 mojibake (Chinese commit messages turning
    # into `?`) on zh-TW Windows. We parse the XML ourselves and format plain
    # text output below.
    #
    # SAFETY: every value is passed as its own array element to `& svn` -- never
    # string-concatenated into a single argument. This is the separate-arg
    # invariant required by F10 (svn-log security review): a string like
    # "--revision $Revision" would let a hostile $Revision smuggle additional
    # flags. With array splatting svn sees each `--revision` / value pair as
    # distinct argv entries, so the value is treated as data.
    $svnArgs = @('log', '--xml', '--limit', $Limit)
    if ($VerboseOutput) { $svnArgs += '-v' }
    if (-not [string]::IsNullOrWhiteSpace($Revision)) {
        $svnArgs += '--revision'
        $svnArgs += $Revision
    }
    $svnArgs += $remote.Path

    $xmlOutput = (& svn @svnArgs | Out-String)
    if ($LASTEXITCODE -ne 0) { throw "svn log failed (exit $LASTEXITCODE)" }

    # Use XmlDocument.LoadXml instead of [xml] cast: under PS 5.1 + StrictMode
    # + outer try, the cast can silently coerce to System.String. See
    # publish-web.ps1 line 75-77 for the same defensive pattern.
    $doc = New-Object System.Xml.XmlDocument
    if ([string]::IsNullOrWhiteSpace($xmlOutput)) {
        # svn returned no log entries (empty range / no permissions / etc).
        # Emit nothing and exit cleanly; no trailer because there is no min rev.
        return
    }
    $doc.LoadXml($xmlOutput)

    $logRoot = $doc.SelectSingleNode('/log')
    if ($null -eq $logRoot) { return }

    $entries = @($logRoot.SelectNodes('logentry'))
    if ($entries.Count -eq 0) { return }

    # Boxed report: each revision is wrapped by a 50-char '═' double rule (also the
    # separator between adjacent revisions) with a 49-char '─' single rule fencing the
    # header / message / 變更 sections so a multi-line commit message never bleeds into
    # them. Mirrors svn_log_format_xml (lib/common.sh).
    $minRev = $null
    $bound = [string]([char]0x2550) * 50   # ═ entry boundary (50)
    $fence = [string]([char]0x2500) * 49   # ─ inner section fence (49)
    $entryNum = 0
    foreach ($entry in $entries) {
        $revAttr = $entry.GetAttribute('revision')
        if ([string]::IsNullOrWhiteSpace($revAttr)) { continue }
        $rev = [int]$revAttr

        $authorNode = $entry.SelectSingleNode('author')
        $author = if ($null -ne $authorNode) { $authorNode.InnerText } else { '' }

        $dateNode = $entry.SelectSingleNode('date')
        $date = if ($null -ne $dateNode) { $dateNode.InnerText } else { '' }

        $msgNode = $entry.SelectSingleNode('msg')
        # InnerText preserves multi-line commit messages without injecting any
        # XML markup.
        $msg = if ($null -ne $msgNode) { $msgNode.InnerText } else { '' }

        Write-Output $bound
        $entryNum++
        Write-Output ("r{0} | {1} | {2}" -f $rev, $author, $date)
        Write-Output $fence
        Write-Output $msg

        if ($VerboseOutput) {
            $pathsNode = $entry.SelectSingleNode('paths')
            # Force array at BOTH use sites: `$x = if (...) { @(...) }` re-collects the
            # if-expression output and UNWRAPS a single-element array back to a scalar,
            # so `$pathNodes.Count` would throw under StrictMode when exactly one path
            # changed (five-taboo #5). @($pathNodes) restores array semantics.
            $pathNodes = if ($null -ne $pathsNode) { @($pathsNode.SelectNodes('path')) } else { @() }
            if (@($pathNodes).Count -gt 0) {
                Write-Output $fence
                Write-Output '變更:'
                foreach ($pathNode in @($pathNodes)) {
                    Write-Output ("{0}  {1}" -f $pathNode.GetAttribute('action'), $pathNode.InnerText)
                }
            }
        }

        if ($null -eq $minRev -or $rev -lt $minRev) { $minRev = $rev }
    }
    # Closing boundary after the last revision.
    if ($entryNum -gt 0) { Write-Output $bound }

    # Trailer for pagination: U11 SKILL parses this line from stdout to know
    # the oldest revision currently displayed, so the next page request is
    # `--revision <minRev-1>:1`. Keeping state in stdout (not chat memory)
    # survives conversation compaction (per F18).
    if ($null -ne $minRev) {
        Write-Output ("# LAST_SHOWN_REV={0}" -f $minRev)
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
