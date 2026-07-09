# Tp-BranchProps.test.ps1 (Pester 5)
#
# Unit coverage for the U2 tp:* branch-metadata property helpers in scripts/lib/Common.ps1:
#   - Get-SvnCopyfromRevFromXml  pure parser: --stop-on-copy XML -> trunk copyfrom-rev
#   - Get-SvnBranchCopyfromRev   thin svn wrapper around the parser
#   - Get-TpBranchProp           `svn propget tp:<name> <target>` (absent -> '', never error)
#   - Set-TpBranchProp           propset + scoped `svn commit --depth empty` + `svn update`
#
# The PURE parser is fed synthetic XML strings and runs on EVERY host (no SKIP). The svn-touching
# cases build a real svn repo from the seed dump and self-SKIP (Pester -Skip) when svn.exe or the
# seed dump are unavailable. This file is intentionally pure ASCII (no BOM needed for PS 5.1).

# --- Discovery-time svn gate (evaluated BEFORE BeforeAll, so -Skip: sees a real value) ---
$script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))
$SvnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $SvnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $SvnAvailable = $false
}
$SvnReady = ($SvnAvailable -and [System.IO.File]::Exists($script:DumpPath))

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $script:PluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    . ([System.IO.Path]::Combine($script:PluginRoot, 'scripts', 'lib', 'Common.ps1'))
    $script:DumpPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

    # svn/svnadmin may warn on stderr; Common.ps1 pins EAP=Stop, so run fixture-building native
    # calls under a softened EAP and drive off $LASTEXITCODE (the helpers under test manage their
    # own EAP internally). Returns the trimmed stdout.
    function Invoke-SvnFixture {
        $a = $args
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $o = $null
        try { $o = & svn @a 2>$null } catch { $o = $null } finally { $ErrorActionPreference = $old }
        return ((@($o) -join "`n").Trim())
    }

    # Build a real svn repo from the seed dump under $Sandbox and return its file:// URI, or $null
    # on any svn failure. svnadmin load needs a real stdin redirect -> route through cmd.exe (same
    # technique as New-RemoteBridge.test.ps1).
    function New-SvnRepoFromDump {
        param([Parameter(Mandatory = $true)][string]$Sandbox)
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $svnRepo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')
            & svnadmin create $svnRepo 2>$null | Out-Null
            if ($LASTEXITCODE -ne 0) { return $null }
            $loadCmd = "svnadmin load `"$svnRepo`" < `"$($script:DumpPath)`""
            & cmd.exe /c $loadCmd > $null 2>$null
            if ($LASTEXITCODE -ne 0) { return $null }
            return 'file:///' + ($svnRepo -replace '\\', '/')
        } finally {
            $ErrorActionPreference = $old
        }
    }

    # Create branches/feature-x by copying trunk, check it out into $Sandbox\wc, and return a
    # hashtable { Uri; Wc; TrunkRev; BranchRev }, or $null on any failure.
    function New-CopiedBranchFixture {
        param([Parameter(Mandatory = $true)][string]$Sandbox)
        $uri = New-SvnRepoFromDump -Sandbox $Sandbox
        if ($null -eq $uri) { return $null }
        $trunkRev = Invoke-SvnFixture info --show-item revision "$uri/trunk"
        $copyOut = Invoke-SvnFixture copy "$uri/trunk" "$uri/branches/feature-x" -m 'create branch'
        if ($LASTEXITCODE -ne 0) { return $null }
        $wc = [System.IO.Path]::Combine($Sandbox, 'wc')
        Invoke-SvnFixture checkout "$uri/branches/feature-x" $wc | Out-Null
        if ($LASTEXITCODE -ne 0) { return $null }
        $branchRev = Invoke-SvnFixture info --show-item revision "$uri/branches/feature-x"
        return @{ Uri = $uri; Wc = $wc; TrunkRev = $trunkRev; BranchRev = $branchRev }
    }

    function New-SandboxDir {
        $d = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'turbo-tpprop-' + [Guid]::NewGuid().ToString('N').Substring(0, 10))
        $null = New-Item -ItemType Directory -Path $d
        return $d
    }

    # Synthetic --stop-on-copy XML: pretty-printed (multi-line) branch-root copy path. The copy is
    # r21; copyfrom-rev="20" is the TRUNK revision it was copied from.
    $script:MultilineXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry
   revision="21">
<author>alice</author>
<date>2026-07-09T01:00:00.000000Z</date>
<paths>
<path
   copyfrom-path="/trunk"
   copyfrom-rev="20"
   action="A"
   kind="dir">/branches/feature-x</path>
</paths>
<msg>create branch</msg>
</logentry>
</log>
'@

    # Two logentries: a later within-branch edit (r25, no copyfrom) + the oldest copy (r21). svn
    # emits descending, so the copy comes LAST; the parser must still return the copy's copyfrom-rev.
    $script:PostCopyXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<log>
<logentry revision="25">
<paths>
<path action="M" kind="file">/branches/feature-x/README.txt</path>
</paths>
<msg>later edit</msg>
</logentry>
<logentry revision="21">
<paths>
<path copyfrom-path="/trunk" copyfrom-rev="20" action="A" kind="dir">/branches/feature-x</path>
</paths>
<msg>create branch</msg>
</logentry>
</log>
'@

    $script:NoCopyXml = '<?xml version="1.0"?><log><logentry revision="5"><paths><path action="M" kind="file">/trunk/a.txt</path></paths><msg>edit</msg></logentry></log>'
}

Describe 'Get-SvnCopyfromRevFromXml (pure parser)' {
    It 'extracts the trunk copyfrom-rev from a pretty-printed multi-line copy path' {
        Get-SvnCopyfromRevFromXml -Xml $script:MultilineXml | Should -Be '20'
    }
    It 'returns the copyfrom-rev of the oldest (copy) entry, not a later within-branch commit' {
        Get-SvnCopyfromRevFromXml -Xml $script:PostCopyXml | Should -Be '20'
    }
    It 'returns empty when no path carries a copyfrom-rev (not a copied branch)' {
        Get-SvnCopyfromRevFromXml -Xml $script:NoCopyXml | Should -Be ''
    }
    It 'returns empty for an empty/whitespace document' {
        Get-SvnCopyfromRevFromXml -Xml '' | Should -Be ''
    }
}

Describe 'Get-SvnBranchCopyfromRev (svn)' {
    It 'returns the TRUNK copyfrom-rev, not the branch creation revision' -Skip:(-not $SvnReady) {
        $sb = New-SandboxDir
        try {
            $fx = New-CopiedBranchFixture -Sandbox $sb
            if ($null -eq $fx) { Set-ItResult -Skipped -Because 'svn fixture build failed'; return }
            $got = Get-SvnBranchCopyfromRev -BranchUrl "$($fx.Uri)/branches/feature-x"
            $got | Should -Be $fx.TrunkRev
            $got | Should -Not -Be $fx.BranchRev
        } finally {
            Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Set-TpBranchProp / Get-TpBranchProp (svn)' {
    It 'round-trips a slash-bearing tp:branch-name exactly' -Skip:(-not $SvnReady) {
        $sb = New-SandboxDir
        try {
            $fx = New-CopiedBranchFixture -Sandbox $sb
            if ($null -eq $fx) { Set-ItResult -Skipped -Because 'svn fixture build failed'; return }
            Set-TpBranchProp -Name 'branch-name' -Value 'feature/test-3-feature' -WorkingCopy $fx.Wc
            (Get-TpBranchProp -Name 'branch-name' -Target $fx.Wc) | Should -Be 'feature/test-3-feature'
        } finally {
            Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'round-trips a numeric tp:last-aligned-rev' -Skip:(-not $SvnReady) {
        $sb = New-SandboxDir
        try {
            $fx = New-CopiedBranchFixture -Sandbox $sb
            if ($null -eq $fx) { Set-ItResult -Skipped -Because 'svn fixture build failed'; return }
            Set-TpBranchProp -Name 'last-aligned-rev' -Value '20' -WorkingCopy $fx.Wc
            (Get-TpBranchProp -Name 'last-aligned-rev' -Target $fx.Wc) | Should -Be '20'
        } finally {
            Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'commits ONLY the property (no file drift swept in)' -Skip:(-not $SvnReady) {
        $sb = New-SandboxDir
        try {
            $fx = New-CopiedBranchFixture -Sandbox $sb
            if ($null -eq $fx) { Set-ItResult -Skipped -Because 'svn fixture build failed'; return }
            Set-TpBranchProp -Name 'branch-name' -Value 'feature/x' -WorkingCopy $fx.Wc
            $head = Invoke-SvnFixture info --show-item revision "$($fx.Uri)/branches/feature-x"
            $log = Invoke-SvnFixture log -v -r $head --xml "$($fx.Uri)/branches/feature-x"
            # </path> does NOT match the </paths> container tag, so this is an exact element count.
            ([regex]::Matches($log, '</path>')).Count | Should -Be 1
            ([regex]::Matches($log, '>/branches/feature-x<')).Count | Should -Be 1
        } finally {
            Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    It 'returns empty (not an error) for an absent property' -Skip:(-not $SvnReady) {
        $sb = New-SandboxDir
        try {
            $fx = New-CopiedBranchFixture -Sandbox $sb
            if ($null -eq $fx) { Set-ItResult -Skipped -Because 'svn fixture build failed'; return }
            # tp:branch-name has never been set on this fresh branch WC.
            { Get-TpBranchProp -Name 'branch-name' -Target $fx.Wc } | Should -Not -Throw
            (Get-TpBranchProp -Name 'branch-name' -Target $fx.Wc) | Should -Be ''
        } finally {
            Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
