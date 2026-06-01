# cleanup-orphan-iis.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/Remove-OrphanIis.ps1
# Behavior: 找與 current site name 不同 hash 的 stale iisexpress 進程 + 沒人在用的 temp apphost 檔。
#   無 orphan → exit 0 + echo「No orphan...」。
#
# 注意:此 script **沒有** 自己的 [iis] enabled gate(只 SKILL.md 有;見 commit 84e944a)。
#   因此本 case 文檔記為 deviation:我們改 assert script behavior when called directly with
#   [iis]=false → 因為 script 本身沒 gate,行為與 [iis]=true 一致(exit 0 + No orphan)。
#   這是「SKILL is the gatekeeper」設計;在 Phase 2 SKILL 測試會 cover SKILL-level gate。
#
# Cases:
#   1. No orphan: fresh fixture (no orphan process) → exit 0,stdout 含「No orphan IIS Express」
#   2. SKILL entry re-invoke: 一致 (no-orphan)
#   3. [iis] enabled = false (script does NOT have script-level gate — by design):
#      script 仍 exit 0 + No orphan;此 case 文件 deviation,SKILL-level gate test 在 Phase 2 cover

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters


# ─── Git helper: PS 5.1 + EAP=Stop bites on git stderr warnings (LF/CRLF etc) ───
# wrap each git call so stderr noise doesn't trigger NativeCommandError termination.
function Invoke-GitSilent {
    $allArgs = $args
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @allArgs 2>$null | Out-Null
    } catch {
        # tolerate;tests assert outcomes from script-under-test, not fixture-init noise
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Remove-OrphanIis.ps1')

# Dot-source the production IIS helpers so we call the *real* Test-OrphanSiteNameMatch
# (which builds the same $stemPattern Remove-OrphanIis.ps1 uses). This guarantees that if
# anyone removes [regex]::Escape from production, the metacharacter cases below go red.
. ([System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'IisHelpers.ps1'))

$testRoot = 'C:\Turbo\test-turbo-plugin'
$cfgPath = [System.IO.Path]::Combine($testRoot, '.turbo-plugin', 'config.toml')

function Ensure-FixtureGit {
    if (-not [System.IO.Directory]::Exists($testRoot)) { return $false }
    if (-not [System.IO.Directory]::Exists([System.IO.Path]::Combine($testRoot, '.git'))) {
        Push-Location -LiteralPath $testRoot
        try {
            Invoke-GitSilent init -q
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            Invoke-GitSilent add -A
            & git -c commit.gpgsign=false commit -q -m init *>$null
        } finally { Pop-Location }
    }
    return $true
}

function Set-IisEnabled {
    param([bool]$Enabled)
    if (-not [System.IO.File]::Exists($cfgPath)) { throw "cfg not found: $cfgPath" }
    $text = [System.IO.File]::ReadAllText($cfgPath, [System.Text.Encoding]::UTF8)
    $valueLine = if ($Enabled) { 'enabled = true' } else { 'enabled = false' }
    $patched = [regex]::Replace($text, '(?m)^enabled\s*=\s*(true|false)\s*$', $valueLine)
    [System.IO.File]::WriteAllText($cfgPath, $patched, (New-Object System.Text.UTF8Encoding($false)))
}

function Invoke-Script {
    param([string]$WorkDir, [string[]]$ExtraArgs = @())
    $oldLoc = Get-Location
    try {
        Set-Location -LiteralPath $WorkDir
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-out-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptUnderTest) + $ExtraArgs
            $proc = Start-Process -FilePath 'powershell.exe' `
                -ArgumentList $argList -WorkingDirectory $WorkDir `
                -RedirectStandardOutput $tmpStdout -RedirectStandardError $tmpStderr `
                -NoNewWindow -PassThru -Wait
            $stdout = if (Test-Path -LiteralPath $tmpStdout -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStdout, [System.Text.Encoding]::UTF8) } else { '' }
            $stderr = if (Test-Path -LiteralPath $tmpStderr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStderr, [System.Text.Encoding]::UTF8) } else { '' }
            return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode }
        } finally {
            foreach ($t in @($tmpStdout, $tmpStderr)) {
                if (Test-Path -LiteralPath $t -PathType Leaf) {
                    try { [System.IO.File]::Delete($t) } catch { }
                }
            }
        }
    } finally { Set-Location -LiteralPath $oldLoc }
}

if (-not (Ensure-FixtureGit)) {
    Write-Output "  [FAIL] setup: $testRoot missing"
    exit 1
}

try {
    # Case 1: no orphan
    $r1 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case1: no-orphan exit 0' -Expected 0 -Actual $r1.Exit
    Assert-Match -Name 'case1: stdout 含 No orphan IIS Express' `
                 -Pattern 'No orphan IIS Express' -InputText $r1.Stdout

    # Case 2: SKILL entry re-invoke
    $r2 = Invoke-Script -WorkDir $testRoot
    Assert-Equal -Name 'case2: SKILL-entry no-orphan exit 0' -Expected 0 -Actual $r2.Exit
    Assert-Match -Name 'case2: 訊息一致' -Pattern 'No orphan IIS Express' -InputText $r2.Stdout

    # Case 3: [iis] enabled = false — script has NO script-level gate.
    # Documented deviation: SKILL.md guards [iis]=false; script proceeds normally.
    Set-IisEnabled -Enabled $false
    try {
        $r3 = Invoke-Script -WorkDir $testRoot
        # By design: script-level still runs (SKILL is the gatekeeper). exit 0 + No orphan.
        Assert-Equal -Name 'case3 (deviation): script-level no [iis] gate — still exits 0' `
                     -Expected 0 -Actual $r3.Exit
        Assert-Match -Name 'case3: 訊息仍是 No orphan' -Pattern 'No orphan IIS Express' -InputText $r3.Stdout
    } finally {
        Set-IisEnabled -Enabled $true
    }

    # ─── R5: regex-metacharacter誤殺防護 (canonical 斷言) ───────────────────────
    # v1.0 的 Remove-OrphanIis 比對 running iisexpress.exe 的 /site:<name> 命令列,
    # 用 "^<csprojStem>-<8hex>$" pattern。stem 須被當 literal (regex-escape),否則含
    # metachar 的 stem (如 My.Test) 會誤 match 別的站台 (如 MyXTest-deadbeef) → 把不該
    # 清的站台當 orphan 殺掉。以下證明 escape 生效:每個 metachar stem 對一個 near-miss
    # 站台名斷言「不」match (escape 生效),並對自己對應的 <stem>-<8hex> 斷言「要」match。
    #
    # near-miss 構造原則:把 metachar 換成「若當 regex 會 match、當 literal 不會」的字元。
    #   $stem        : 含 metachar 的 csproj stem
    #   $nearMiss    : 一個 near-miss 站台名 (literal 不該 match;若沒 escape 則 regex 會 match)
    # 每案的 NearMiss 在「未 escape 的 buggy pattern」下會誤 match (RawWouldMatch 標明),
    # 在 production 的 escaped pattern 下不該 match。標 RawWouldMatch=$false 的 (anchor / 結束
    # metachar) 表示未 escape 時該 metachar 反而破壞 pattern → 連自己對應站台都 match 不到 (under-kill);
    # 兩種失效模式都靠 escape 修掉,故仍納入矩陣。escape 真正有效性由 verification 的「暫拿掉 escape
    # 應使本檔變紅」驗證(見回報)。
    $metacharCases = @(
        # '.' regex = any char → 'My.Test' 當 regex 會 match 'MyXTest'
        @{ Char = '.';  Stem = 'My.Test';  NearMiss = 'MyXTest-deadbeef'; RawWouldMatch = $true }
        # '+' regex = 前字元一個以上 → 'Sva+b' 當 regex 會 match 'Svaab'
        @{ Char = '+';  Stem = 'Sva+b';    NearMiss = 'Svaab-deadbeef';  RawWouldMatch = $true }
        # '[' regex = char class 開始 → 'App[0-9]' 當 regex 會 match 'App5'
        @{ Char = '[';  Stem = 'App[0-9]'; NearMiss = 'App5-deadbeef';   RawWouldMatch = $true }
        # ']' 單獨結束 metachar → 'A[BC]D' 當 regex 會 match 'ABD' (char class [BC])
        @{ Char = ']';  Stem = 'A[BC]D';   NearMiss = 'ABD-deadbeef';    RawWouldMatch = $true }
        # '(' regex = group 開始 → '(App)' 當 regex 會 match 'App'
        @{ Char = '(';  Stem = '(App)';    NearMiss = 'App-deadbeef';    RawWouldMatch = $true }
        # ')' group 結束 → '(Foo)Bar' 當 regex 會 match 'FooBar'
        @{ Char = ')';  Stem = '(Foo)Bar'; NearMiss = 'FooBar-deadbeef'; RawWouldMatch = $true }
        # '{' regex = quantifier 開始 → 'Ap{1,2}' 當 regex 會 match 'App'
        @{ Char = '{';  Stem = 'Ap{1,2}';  NearMiss = 'App-deadbeef';    RawWouldMatch = $true }
        # '}' quantifier 結束 → 'a{2}b' 當 regex 會 match 'aab'
        @{ Char = '}';  Stem = 'a{2}b';    NearMiss = 'aab-deadbeef';    RawWouldMatch = $true }
        # '^' regex = 起始 anchor (零寬) → '^App' 未 escape 時 anchor 破壞 pattern,
        #   self-site 'App-...' 反而 match 不到 (under-kill);escape 後 self 正常 match。
        @{ Char = '^';  Stem = '^App';     NearMiss = 'XApp-deadbeef';   RawWouldMatch = $false }
        # '$' regex = 結束 anchor → 'App$X' 未 escape 時 'App' 後接 end-anchor 再接 'X' 為不可能 regex,
        #   self-site 'App$X-...' match 不到 (under-kill);escape 後 self 正常 match。
        @{ Char = '$';  Stem = 'App$X';    NearMiss = 'App-deadbeefX';   RawWouldMatch = $false }
    )

    foreach ($mc in $metacharCases) {
        # near-miss: stem 當 literal 不該 match (escape 生效);若 escape 被拿掉則會誤 match。
        $nm = Test-OrphanSiteNameMatch -CsprojStem $mc.Stem -SiteName $mc.NearMiss
        Assert-True -Name "R5 metachar '$($mc.Char)': near-miss '$($mc.NearMiss)' NOT matched (literal stem '$($mc.Stem)')" `
                    -Condition (-not $nm)

        # 對照組:該 stem 對自己對應的站台名 (<stem>-<8hex>) 一定要 match,
        # 證明不是「全部都不 match」才過。
        $selfSite = "$($mc.Stem)-deadbeef"
        $self = Test-OrphanSiteNameMatch -CsprojStem $mc.Stem -SiteName $selfSite
        Assert-True -Name "R5 metachar '$($mc.Char)': self-site '$selfSite' DOES match" `
                    -Condition $self
    }

    # 對照組 (seam (a)):真 orphan — stem 完全不對應的站台名仍被判定屬該 stem 家族時應 match,
    # 而毫不相干的站台名不該 match (證明 helper 不是恆真)。
    $realOrphan = Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'HelloApp-0badf00d'
    Assert-True -Name 'R5 control: real orphan HelloApp-0badf00d matches stem HelloApp' -Condition $realOrphan

    $unrelated = Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'OtherApp-0badf00d'
    Assert-True -Name 'R5 control: unrelated OtherApp-0badf00d does NOT match stem HelloApp' -Condition (-not $unrelated)

    # 邊界:正確 stem 但 hash 非 8 hex → 不該 match (pattern 的 hash 段仍有效)。
    $badHash = Test-OrphanSiteNameMatch -CsprojStem 'HelloApp' -SiteName 'HelloApp-zzzzzzzz'
    Assert-True -Name 'R5 control: non-hex hash does NOT match' -Condition (-not $badHash)
}
catch {
    Write-Output "  [FAIL] unhandled: $($_.Exception.Message)"
    $script:Failed++
}

Write-Output ''
Write-Output "cleanup-orphan-iis.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
