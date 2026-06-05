# Meta-test for AssertHelpers.ps1 itself.
#
# 為什麼:script tests 把 case 結果歸 PASS / FAIL 完全靠這幾個 helper。如果它們本身有
# bug (例如 Assert-Equal 把 $null vs '' 當相等),所有 case 結果都不可信。本檔對
# 每個 helper 都跑 known-pass 與 known-fail 兩種 input,確認:
#   * 真正應該 PASS 的 input 不會被誤判 FAIL
#   * 真正應該 FAIL 的 input 不會被誤判 PASS
#
# 為了不讓「real fail」case 真的把整個檔案的 counter 變成 fail,我們用 inner
# scope (Reset-Counters + Get-CounterSummary) 取出實際 PASS/FAIL 計數,然後用外
# 部的 $meta_* counter 紀錄「helper 行為是否符合預期」。
#
# 預期至少 10 個 meta-case 全綠 → exit 0。
#
# 跑法:
#   powershell -NoProfile -ExecutionPolicy Bypass -File <this>.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# Locate AssertHelpers.ps1 relative to this file
$assertLib = [System.IO.Path]::Combine($PSScriptRoot, 'AssertHelpers.ps1')
if (-not [System.IO.File]::Exists($assertLib)) {
    Write-Error "AssertHelpers.ps1 not found at $assertLib"
    exit 1
}
. $assertLib

# ─── Meta counters ───────────────────────────────────────────────────────────

$meta_passed   = 0
$meta_failed   = 0
$meta_failures = @()

function Meta-Assert {
    param(
        [string]$Name,
        [bool]$Expected,
        [bool]$Actual
    )
    if ($Expected -eq $Actual) {
        $script:meta_passed++
        Write-Output "  [META-PASS] $Name"
    } else {
        $script:meta_failed++
        $script:meta_failures += "${Name}: expected $Expected, got $Actual"
        Write-Output "  [META-FAIL] $Name"
        Write-Output "             expected: $Expected"
        Write-Output "             actual:   $Actual"
    }
}

function Run-WithInnerCounters {
    param([scriptblock]$Block)
    # 把 $script:Passed/Failed 借走 (它們就是 AssertHelpers 用的 module-scope counter),
    # 跑完 capture 狀態,然後還原。
    $savedPassed   = $script:Passed
    $savedFailed   = $script:Failed
    $savedFailures = $script:Failures
    Reset-Counters
    & $Block | Out-Null
    $summary = Get-CounterSummary
    $script:Passed   = $savedPassed
    $script:Failed   = $savedFailed
    $script:Failures = $savedFailures
    return $summary
}

# ─── Helpers ─────────────────────────────────────────────────────────────────

function Make-TempFile {
    param([byte[]]$Bytes)
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $sandboxBase = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '.sandbox', 'sandboxes'))
    $path = [System.IO.Path]::Combine($sandboxBase, "turbo-plugin-test-asserthelpers-$stamp.bin")
    $parent = [System.IO.Path]::GetDirectoryName($path)
    if (-not [System.IO.Directory]::Exists($parent)) {
        $null = New-Item -ItemType Directory -Path $parent -Force
    }
    [System.IO.File]::WriteAllBytes($path, $Bytes)
    return $path
}

function Remove-TempFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    try {
        if ([System.IO.File]::Exists($Path)) {
            $fa = [System.IO.File]::GetAttributes($Path)
            if ($fa -band [System.IO.FileAttributes]::ReadOnly) {
                [System.IO.File]::SetAttributes($Path, $fa -band (-bnot [System.IO.FileAttributes]::ReadOnly))
            }
            [System.IO.File]::Delete($Path)
        }
    } catch {
        # best-effort
    }
}

# ─── Case 1: Assert-Equal happy ──────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: Assert-Equal — equal values → should PASS'
$r = Run-WithInnerCounters {
    Assert-Equal -Name 'equal int' -Expected 42 -Actual 42
}
Meta-Assert -Name 'Assert-Equal(equal) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)

# ─── Case 2: Assert-Equal sad ────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: Assert-Equal — unequal values → should FAIL'
$r = Run-WithInnerCounters {
    Assert-Equal -Name 'unequal int' -Expected 42 -Actual 99
}
Meta-Assert -Name 'Assert-Equal(unequal) records 1 FAIL' -Expected $true -Actual ($r.Passed -eq 0 -and $r.Failed -eq 1)

# ─── Case 3: Assert-True happy ───────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 3: Assert-True — $true → should PASS'
$r = Run-WithInnerCounters {
    Assert-True -Name 'plain true' -Condition $true
}
Meta-Assert -Name 'Assert-True(true) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)

# ─── Case 4: Assert-True sad ─────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 4: Assert-True — $false → should FAIL'
$r = Run-WithInnerCounters {
    Assert-True -Name 'plain false' -Condition $false
}
Meta-Assert -Name 'Assert-True(false) records 1 FAIL' -Expected $true -Actual ($r.Passed -eq 0 -and $r.Failed -eq 1)

# ─── Case 5: Assert-Match happy ──────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 5: Assert-Match — pattern matches → should PASS'
$r = Run-WithInnerCounters {
    Assert-Match -Name 'word boundary' -Pattern 'hello.*world' -InputText 'hello, beautiful world'
}
Meta-Assert -Name 'Assert-Match(match) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)

# ─── Case 6: Assert-Match sad ────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 6: Assert-Match — pattern misses → should FAIL'
$r = Run-WithInnerCounters {
    Assert-Match -Name 'no match' -Pattern 'goodbye' -InputText 'hello world'
}
Meta-Assert -Name 'Assert-Match(miss) records 1 FAIL' -Expected $true -Actual ($r.Passed -eq 0 -and $r.Failed -eq 1)

# ─── Case 7: Assert-Throws happy (throws, no pattern check) ──────────────────

Write-Output ''
Write-Output 'Case 7: Assert-Throws — block throws → should PASS'
$r = Run-WithInnerCounters {
    Assert-Throws -Name 'div-by-zero' -ScriptBlock { throw 'kaboom' }
}
Meta-Assert -Name 'Assert-Throws(threw) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)

# ─── Case 8: Assert-Throws sad (does not throw) ──────────────────────────────

Write-Output ''
Write-Output 'Case 8: Assert-Throws — block does NOT throw → should FAIL'
$r = Run-WithInnerCounters {
    Assert-Throws -Name 'should throw but does not' -ScriptBlock { $null }
}
Meta-Assert -Name 'Assert-Throws(no-throw) records 1 FAIL' -Expected $true -Actual ($r.Passed -eq 0 -and $r.Failed -eq 1)

# ─── Case 9: Assert-Throws with pattern (positive) ───────────────────────────

Write-Output ''
Write-Output 'Case 9: Assert-Throws — message matches pattern → should PASS'
$r = Run-WithInnerCounters {
    Assert-Throws -Name 'message contains foo' `
                  -ScriptBlock { throw 'something foo happened' } `
                  -ExpectedMessagePattern 'foo'
}
Meta-Assert -Name 'Assert-Throws(pattern hit) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)

# ─── Case 10: Assert-FileBytes happy with 中文 source string literal #5.1 ────

Write-Output ''
Write-Output 'Case 10: Assert-FileBytes — UTF-8 中文 bytes round-trip (dict #5.1 "你好,turbo-plugin")'
$zh51 = '"你好,turbo-plugin"'
$expectedBytes = [System.Text.Encoding]::UTF8.GetBytes($zh51)
$tmp = Make-TempFile -Bytes $expectedBytes
try {
    $r = Run-WithInnerCounters {
        Assert-FileBytes -Name 'zh51 byte-equal' -ExpectedBytes $expectedBytes -ActualFilePath $tmp
    }
    Meta-Assert -Name 'Assert-FileBytes(equal) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)
} finally {
    Remove-TempFile -Path $tmp
}

# ─── Case 11: Assert-FileBytes sad (length mismatch) ─────────────────────────

Write-Output ''
Write-Output 'Case 11: Assert-FileBytes — length mismatch → should FAIL'
$bytesShort = [byte[]](0x01, 0x02, 0x03)
$bytesLong  = [byte[]](0x01, 0x02, 0x03, 0x04)
$tmp2 = Make-TempFile -Bytes $bytesShort
try {
    $r = Run-WithInnerCounters {
        Assert-FileBytes -Name 'length-mismatch' -ExpectedBytes $bytesLong -ActualFilePath $tmp2
    }
    Meta-Assert -Name 'Assert-FileBytes(len-mismatch) records 1 FAIL' -Expected $true -Actual ($r.Passed -eq 0 -and $r.Failed -eq 1)
} finally {
    Remove-TempFile -Path $tmp2
}

# ─── Case 12: Assert-SvnLogTextRoundTrip mock — decode happy path ────────────
#
# 注意:這個 case 不真的跑 svn (real-SVN flow 留給 U4 的 svn-log 中文 case)。
# 用 -DecodeBytesOverride 注入 raw bytes 來測 decode 邏輯本身對不對。
# 我們模擬:UTF-8 console + 字典 #3.1 commit msg "修正中文 commit 訊息亂碼"
# (decode 後 text 應該包含此字串)。

Write-Output ''
Write-Output 'Case 12: Assert-SvnLogTextRoundTrip — decode mocked UTF-8 bytes (dict #3.1)'
$zh31 = '修正中文 commit 訊息亂碼'
# 模擬 svn log 完整 stdout (含 r 標頭 + msg)
$mockSvnOutput = "------------------------------------------------------------------------`nr5 | tester | 2026-01-15 10:00:00 +0800 | 1 line`n`n$zh31`n------------------------------------------------------------------------`n"
$mockBytes     = [System.Text.Encoding]::UTF8.GetBytes($mockSvnOutput)
# 確保 console 用 UTF-8 來 decode (本 helper 用 [Console]::OutputEncoding;
# 測試跑當下若 console 已是 UTF-8 → 直接命中)。先暫存原值,跑完還原。
$savedConsoleEnc = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $r = Run-WithInnerCounters {
        Assert-SvnLogTextRoundTrip `
            -Name 'mocked utf8 round-trip' `
            -ExpectedText $zh31 `
            -RevN 5 `
            -RepoPathOrUrl 'unused-fake-repo' `
            -DecodeBytesOverride $mockBytes
    }
    Meta-Assert -Name 'Assert-SvnLogTextRoundTrip(decode happy) records 1 PASS' -Expected $true -Actual ($r.Passed -eq 1 -and $r.Failed -eq 0)
} finally {
    [Console]::OutputEncoding = $savedConsoleEnc
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
Write-Output "AssertHelpers.test: meta_passed=$meta_passed meta_failed=$meta_failed"
if ($meta_failed -gt 0) {
    Write-Output ''
    Write-Output 'Meta-failures:'
    foreach ($f in $meta_failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
