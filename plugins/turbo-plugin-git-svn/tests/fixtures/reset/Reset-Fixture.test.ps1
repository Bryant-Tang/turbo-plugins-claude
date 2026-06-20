# Reset-Fixture.test.ps1 (Pester 5)
#
# Script under test: Reset-Fixture.ps1 (sibling fixture builder).
# Migrated from hand-rolled Assert-* / counters to Pester 5 (Describe/Context/It + Should).
#
# Scenarios (aligned with U1 Test scenarios):
#   1. Happy reset:          fresh base -> reset -> diff = empty
#   2. Dirty reset:          extras/garbage.txt -> reset -> garbage.txt vanishes
#   3. CJK path reset:       測試/含中文/subdir + 中文檔案.txt -> reset fully restores base
#   4. CJK commit msg seed:  r5 svn:log round-trip text == 字典 #3 第 1 條 (needs seed dump + svnlook)
#   5. Idempotency:          2 consecutive resets -> diff = empty

BeforeDiscovery {
    # Skip gate for Scenario 4 must be resolved during discovery, not BeforeAll.
    $dumpPathDisco = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'seed', 'svn-repo-r1-r20.dump'))
    $script:DumpExists = Test-Path -LiteralPath $dumpPathDisco -PathType Leaf
    $script:SvnlookAvailable = $null -ne (Get-Command svnlook -ErrorAction SilentlyContinue)
    $script:Scenario4Runnable = $script:DumpExists -and $script:SvnlookAvailable
}

BeforeAll {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.Encoding]::UTF8

    # <repo>/plugins/turbo-plugin-git-svn/tests/fixtures/reset/Reset-Fixture.test.ps1
    #   -> ./Reset-Fixture.ps1            (system under test)
    #   -> ../base                        (base fixture dir)
    #   -> ../seed/svn-repo-r1-r20.dump   (seed dump)
    $script:ResetScript = [System.IO.Path]::Combine($PSScriptRoot, 'Reset-Fixture.ps1')
    $script:BaseDir     = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'base'))
    $script:DumpPath    = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', 'seed', 'svn-repo-r1-r20.dump'))

    if (-not (Test-Path -LiteralPath $script:ResetScript -PathType Leaf)) {
        throw "Reset-Fixture.ps1 not found at: $script:ResetScript"
    }
    if (-not [System.IO.Directory]::Exists($script:BaseDir)) {
        throw "base fixture dir not found at: $script:BaseDir"
    }

    # NOTE: $script:Scenario4Runnable from BeforeDiscovery is only visible to the
    # discovery-phase -Skip: expressions; it does NOT carry into the run phase.
    # Recompute the same gate here so the run-phase BeforeAll setup logic agrees
    # with the It -Skip: decisions.
    $script:Scenario4Runnable = (Test-Path -LiteralPath $script:DumpPath -PathType Leaf) -and
        ($null -ne (Get-Command svnlook -ErrorAction SilentlyContinue))

    function New-IsolatedFixtureRoot {
        $tempDir = $env:TEMP
        try {
            $tempDir = (Get-Item -LiteralPath $tempDir).FullName
        } catch {
            # leave as-is
        }
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $sandbox = [System.IO.Path]::Combine($tempDir, "turbo-plugin-reset-test-$stamp")
        $null = New-Item -ItemType Directory -Path $sandbox -Force
        return $sandbox
    }

    function Remove-IsolatedFixtureRoot {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try {
            if ([System.IO.Directory]::Exists($Dir)) {
                # Use raw .NET API to sidestep PS 5.1 LiteralPath short-name bug.
                [System.IO.Directory]::Delete($Dir, $true)
            }
        } catch {
            # best-effort
        }
    }

    # Relative path helper that works under PS 5.1 (no [System.IO.Path]::GetRelativePath).
    function Get-RelativePath {
        param(
            [Parameter(Mandatory = $true)][string]$From,
            [Parameter(Mandatory = $true)][string]$To
        )
        $fromTrim = $From.TrimEnd('\','/')
        $toTrim   = $To
        if ($toTrim.StartsWith($fromTrim, [System.StringComparison]::OrdinalIgnoreCase)) {
            $rel = $toTrim.Substring($fromTrim.Length).TrimStart('\','/')
            return $rel
        }
        $fromUri = New-Object System.Uri(($fromTrim + [System.IO.Path]::DirectorySeparatorChar))
        $toUri   = New-Object System.Uri($To)
        return [System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()) -replace '/', '\'
    }

    # Compare 2 directory trees: $true if exact contents match (files / dirs / file bytes).
    function Test-DirsEqual {
        param(
            [Parameter(Mandatory = $true)][string]$A,
            [Parameter(Mandatory = $true)][string]$B
        )
        if (-not [System.IO.Directory]::Exists($A) -or -not [System.IO.Directory]::Exists($B)) {
            return $false
        }
        $filesA = @(Get-ChildItem -LiteralPath $A -Recurse -File -Force | ForEach-Object {
            $rel = Get-RelativePath -From $A -To $_.FullName
            [PSCustomObject]@{ Rel = $rel; Path = $_.FullName; Length = $_.Length }
        })
        $filesB = @(Get-ChildItem -LiteralPath $B -Recurse -File -Force | ForEach-Object {
            $rel = Get-RelativePath -From $B -To $_.FullName
            [PSCustomObject]@{ Rel = $rel; Path = $_.FullName; Length = $_.Length }
        })
        if ($filesA.Count -ne $filesB.Count) { return $false }

        $mapB = @{}
        foreach ($f in $filesB) { $mapB[$f.Rel.ToLower()] = $f }

        foreach ($fa in $filesA) {
            $key = $fa.Rel.ToLower()
            if (-not $mapB.ContainsKey($key)) { return $false }
            $fb = $mapB[$key]
            if ($fa.Length -ne $fb.Length) { return $false }
            $bytesA = [System.IO.File]::ReadAllBytes($fa.Path)
            $bytesB = [System.IO.File]::ReadAllBytes($fb.Path)
            if ($bytesA.Length -ne $bytesB.Length) { return $false }
            for ($i = 0; $i -lt $bytesA.Length; $i++) {
                if ($bytesA[$i] -ne $bytesB[$i]) { return $false }
            }
        }
        return $true
    }

    function Invoke-Reset {
        param(
            [string]$TestRoot,
            [string]$SvnRepo,
            [switch]$SkipSvn
        )
        $extra = @()
        if ($SkipSvn) { $extra += '-SkipSvn' }

        # Capture stdout so it does not leak into the return stream; only the
        # exit code matters to the assertions.
        $resetOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ResetScript `
            -TestRoot $TestRoot -SvnRepo $SvnRepo @extra
        $null = $resetOutput
        return $LASTEXITCODE
    }
}

Describe 'Reset-Fixture' {

    Context 'Scenario 1: Happy reset (fresh base diff empty)' {
        BeforeAll {
            $script:sb1 = New-IsolatedFixtureRoot
            $script:s1_testRoot = [System.IO.Path]::Combine($script:sb1, 'test-turbo-plugin')
            $s1_svnRepo  = [System.IO.Path]::Combine($script:sb1, 'test-turbo-plugin-svn-repo')
            $script:s1_rc = Invoke-Reset -TestRoot $script:s1_testRoot -SvnRepo $s1_svnRepo -SkipSvn
        }
        AfterAll { Remove-IsolatedFixtureRoot -Dir $script:sb1 }

        It 'reset exits 0' { $script:s1_rc | Should -Be 0 }
        It 'testRoot mirrors base contents' { (Test-DirsEqual -A $script:BaseDir -B $script:s1_testRoot) | Should -BeTrue }
        It 'HelloApp.csproj exists in test root' {
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($script:s1_testRoot, 'HelloApp.csproj')) -PathType Leaf) | Should -BeTrue
        }
        It 'config.toml exists in test root' {
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($script:s1_testRoot, '.turbo-plugin', 'config.toml')) -PathType Leaf) | Should -BeTrue
        }
    }

    Context 'Scenario 2: Dirty reset (extras garbage vanishes)' {
        BeforeAll {
            $script:sb2 = New-IsolatedFixtureRoot
            $script:s2_testRoot = [System.IO.Path]::Combine($script:sb2, 'test-turbo-plugin')
            $s2_svnRepo  = [System.IO.Path]::Combine($script:sb2, 'test-turbo-plugin-svn-repo')

            $script:s2_extrasDir   = [System.IO.Path]::Combine($script:s2_testRoot, 'extras')
            $script:s2_garbageFile = [System.IO.Path]::Combine($script:s2_extrasDir, 'garbage.txt')
            $null = New-Item -ItemType Directory -Path $script:s2_extrasDir -Force
            [System.IO.File]::WriteAllText($script:s2_garbageFile, 'this should disappear after reset')

            $script:s2_rc = Invoke-Reset -TestRoot $script:s2_testRoot -SvnRepo $s2_svnRepo -SkipSvn
        }
        AfterAll { Remove-IsolatedFixtureRoot -Dir $script:sb2 }

        It 'reset exits 0' { $script:s2_rc | Should -Be 0 }
        It 'extras garbage.txt removed' { (Test-Path -LiteralPath $script:s2_garbageFile) | Should -BeFalse }
        It 'extras dir removed' { (Test-Path -LiteralPath $script:s2_extrasDir) | Should -BeFalse }
        It 'testRoot still matches base after dirty reset' { (Test-DirsEqual -A $script:BaseDir -B $script:s2_testRoot) | Should -BeTrue }
    }

    Context 'Scenario 3: CJK path reset' {
        BeforeAll {
            $script:sb3 = New-IsolatedFixtureRoot
            $script:s3_testRoot = [System.IO.Path]::Combine($script:sb3, 'test-turbo-plugin')
            $s3_svnRepo  = [System.IO.Path]::Combine($script:sb3, 'test-turbo-plugin-svn-repo')

            $cjkDir  = [System.IO.Path]::Combine($script:s3_testRoot, '測試', '含中文', 'subdir')
            $script:s3_cjkFile = [System.IO.Path]::Combine($cjkDir, '中文檔案.txt')
            $null = New-Item -ItemType Directory -Path $cjkDir -Force
            $utf8WithBom = New-Object System.Text.UTF8Encoding($true)
            [System.IO.File]::WriteAllText($script:s3_cjkFile, '中文 fixture body — should disappear', $utf8WithBom)

            $script:s3_rc = Invoke-Reset -TestRoot $script:s3_testRoot -SvnRepo $s3_svnRepo -SkipSvn
        }
        AfterAll { Remove-IsolatedFixtureRoot -Dir $script:sb3 }

        It 'reset exits 0' { $script:s3_rc | Should -Be 0 }
        It 'CJK file removed' { (Test-Path -LiteralPath $script:s3_cjkFile) | Should -BeFalse }
        It 'CJK top dir removed' {
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($script:s3_testRoot, '測試'))) | Should -BeFalse
        }
        It 'testRoot still matches base after CJK reset' { (Test-DirsEqual -A $script:BaseDir -B $script:s3_testRoot) | Should -BeTrue }
    }

    Context 'Scenario 4: SVN seed CJK commit msg r5 round-trip' {
        BeforeAll {
            if ($script:Scenario4Runnable) {
                $script:sb4 = New-IsolatedFixtureRoot
                $script:s4_testRoot = [System.IO.Path]::Combine($script:sb4, 'test-turbo-plugin')
                $script:s4_svnRepo  = [System.IO.Path]::Combine($script:sb4, 'test-turbo-plugin-svn-repo')
                $script:s4_rc = Invoke-Reset -TestRoot $script:s4_testRoot -SvnRepo $script:s4_svnRepo
                $script:s4_worktreesDir = [System.IO.Path]::Combine($script:s4_testRoot, '.turbo-plugin', 'worktrees')

                # r5 svn:log content check — round-trip via console codepage (brainstorm F-3).
                # Windows + TortoiseSVN stores CJK commit msgs as cp1252->UTF-8 mojibake, so a
                # byte-equal compare fails. Recover canonical CJK with the 2-step cp1252 decode.
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName  = 'svnlook'
                $psi.Arguments = "propget --revprop -r 5 `"$script:s4_svnRepo`" svn:log"
                $psi.UseShellExecute = $false
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError  = $true
                $proc = [System.Diagnostics.Process]::Start($psi)
                $rawMem = New-Object System.IO.MemoryStream
                $proc.StandardOutput.BaseStream.CopyTo($rawMem)
                $proc.WaitForExit()
                $rawAll = $rawMem.ToArray()
                $rawBytes = $rawAll
                if ($rawAll.Length -gt 0 -and $rawAll[$rawAll.Length - 1] -eq 0x0A) {
                    $rawBytes = $rawAll[0..($rawAll.Length - 2)]
                }

                $expectedMsg = '修正中文 commit 訊息亂碼'
                $cp1252Enc = [System.Text.Encoding]::GetEncoding(1252)
                $mojibakeText = [System.Text.Encoding]::UTF8.GetString($rawBytes)
                $recoveredBytes = $cp1252Enc.GetBytes($mojibakeText)
                $script:s4_recoveredText = [System.Text.Encoding]::UTF8.GetString($recoveredBytes)
                $script:s4_expectedMsg = $expectedMsg
            }
        }
        AfterAll {
            if ($script:Scenario4Runnable) { Remove-IsolatedFixtureRoot -Dir $script:sb4 }
        }

        It 'reset exits 0 (with SVN)' -Skip:(-not $script:Scenario4Runnable) {
            $script:s4_rc | Should -Be 0
        }
        It 'SVN repo dir exists' -Skip:(-not $script:Scenario4Runnable) {
            ([System.IO.Directory]::Exists($script:s4_svnRepo)) | Should -BeTrue
        }
        It 'remote-svn-main worktree checked out' -Skip:(-not $script:Scenario4Runnable) {
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($script:s4_worktreesDir, 'remote-svn-main', '.svn'))) | Should -BeTrue
        }
        It 'remote-svn-test-1 worktree checked out' -Skip:(-not $script:Scenario4Runnable) {
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($script:s4_worktreesDir, 'remote-svn-test-1', '.svn'))) | Should -BeTrue
        }
        It 'r5 svn:log round-trip text == 字典 #3 第 1 條 (F-3 cp1252 to UTF-8 recovery)' -Skip:(-not $script:Scenario4Runnable) {
            $script:s4_recoveredText | Should -Be $script:s4_expectedMsg
        }
    }

    Context 'Scenario 5: Idempotency (2 consecutive resets diff empty)' {
        BeforeAll {
            $script:sb5 = New-IsolatedFixtureRoot
            $script:s5_testRoot = [System.IO.Path]::Combine($script:sb5, 'test-turbo-plugin')
            $s5_svnRepo  = [System.IO.Path]::Combine($script:sb5, 'test-turbo-plugin-svn-repo')

            $script:s5_rc1 = Invoke-Reset -TestRoot $script:s5_testRoot -SvnRepo $s5_svnRepo -SkipSvn
            $script:s5_match1 = Test-DirsEqual -A $script:BaseDir -B $script:s5_testRoot

            $script:s5_rc2 = Invoke-Reset -TestRoot $script:s5_testRoot -SvnRepo $s5_svnRepo -SkipSvn
            $script:s5_match2 = Test-DirsEqual -A $script:BaseDir -B $script:s5_testRoot
        }
        AfterAll { Remove-IsolatedFixtureRoot -Dir $script:sb5 }

        It 'first reset exits 0' { $script:s5_rc1 | Should -Be 0 }
        It 'first reset matches base' { $script:s5_match1 | Should -BeTrue }
        It 'second reset exits 0' { $script:s5_rc2 | Should -Be 0 }
        It 'second reset still matches base (idempotent)' { $script:s5_match2 | Should -BeTrue }
    }
}
