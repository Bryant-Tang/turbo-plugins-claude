# Assert-Helpers.ps1
#
# 純手刻的 assertion helper library，給 turbo-plugin v1.0 Phase 1 測試使用。
#
# 設計取捨 (plan correction F-1):
#   Plan 原本 mention Pester 3.4，但 doc-review 確認 Pester 3.4 的
#   `Should -Be / -Throw / -Match` dash-syntax 是 Pester 4+ 才有的。為了避免被
#   API 落差咬到，本 v1.0 採「純手刻 only」路線 — 維持與既有
#   plugins/turbo-plugin/tests/unit/scripts-lib/test_resolve_config_value_merge.ps1
#   同樣 shape:plain Assert-* helpers + try/finally + 模組層級 $script:Passed /
#   $script:Failed counters + 最後 exit ($script:Failed -eq 0 ? 0 : 1) (PS 5.1
#   沒 ternary，用 if 模仿)。
#
# 共 6 個 helper:
#   Assert-Equal                 一般 -eq 比對 (含 null safety)
#   Assert-True                  bool / truthy 斷言
#   Assert-Match                 regex pattern 比對
#   Assert-Throws                scriptblock 必須 throw，message 可選地 -match pattern
#   Assert-FileBytes             檔案 byte-level 比對 (非 SVN 路徑 — filesystem bytes 真的是 UTF-8)
#   Assert-SvnLogTextRoundTrip   SVN log 中文 text round-trip 比對 (語意比對，非 byte-equal)
#
# 為什麼 Assert-SvnLogTextRoundTrip 不做 byte-equal:
#   U1 fixture seed 階段確認，Windows + TortoiseSVN 把中文 commit msg 存的不是
#   canonical UTF-8 bytes，而是「cp1252 → UTF-8」mojibake form (例如 修 存的是
#   c3 a4 c2 bf c2 ae 而非 e4 bf ae)。Round-trip 經 cp950 / cp1252 / 任何
#   console codepage 都會還原成正確中文，使用者在 production 完全察覺不到。
#   因此本 helper 拿 svn log 的 raw stdout bytes，用 [Console]::OutputEncoding
#   decode (亦即測試跑當下 Windows console 用的 codepage)，再跟 expected 中文
#   做 string 比對。檔案實體 bytes (例如 pack-content 把 source `.cs` build
#   成 `.dll` 中的 string section) 仍走 Assert-FileBytes 做 byte-level compare。
#
# 與 runner 的 contract:
#   - $script:Passed (int)              當前 .ps1 累計 PASS 數
#   - $script:Failed (int)              當前 .ps1 累計 FAIL 數
#   - $script:Failures (string[])       failure messages
#   - Reset-Counters                    歸零 (runner 在跑每個 .Tests.ps1 之前呼叫一次)
#   - Get-CounterSummary                回傳 hashtable @{ Passed=N; Failed=N; Failures=@(...) }
#
# 用法 (在 test .ps1 裡):
#   . "$PSScriptRoot\..\lib\Assert-Helpers.ps1"
#   Reset-Counters
#   Assert-Equal -Name 'foo' -Expected 1 -Actual 1
#   ...
#   if ($script:Failed -gt 0) { exit 1 } else { exit 0 }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# ─── Counters ────────────────────────────────────────────────────────────────

$script:Passed   = 0
$script:Failed   = 0
$script:Failures = @()

function Reset-Counters {
    $script:Passed   = 0
    $script:Failed   = 0
    $script:Failures = @()
}

function Get-CounterSummary {
    return @{
        Passed   = $script:Passed
        Failed   = $script:Failed
        Failures = ,@($script:Failures)
    }
}

# ─── Internal helpers ────────────────────────────────────────────────────────

function _Repr {
    param($Value)
    if ($null -eq $Value) { return '<null>' }
    try {
        $typeName = $Value.GetType().Name
    } catch {
        $typeName = 'unknown'
    }
    return "'$Value' (type=$typeName)"
}

function _RecordPass {
    param([string]$Name)
    $script:Passed++
    Write-Output "  [PASS] $Name"
}

function _RecordFail {
    param([string]$Name, [string]$Detail)
    $script:Failed++
    $script:Failures += "${Name}: $Detail"
    Write-Output "  [FAIL] $Name"
    if (-not [string]::IsNullOrWhiteSpace($Detail)) {
        foreach ($line in ($Detail -split "`r?`n")) {
            Write-Output "         $line"
        }
    }
}

# ─── Assert-Equal ────────────────────────────────────────────────────────────

function Assert-Equal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Expected,
        $Actual,
        [string]$Message
    )
    $expectedRepr = _Repr $Expected
    $actualRepr   = _Repr $Actual
    $nullMatch    = (($null -eq $Expected) -eq ($null -eq $Actual))
    if ($nullMatch -and ($Expected -eq $Actual)) {
        _RecordPass $Name
    } else {
        $detail = "expected: $expectedRepr`nactual:   $actualRepr"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
    }
}

# ─── Assert-True ─────────────────────────────────────────────────────────────

function Assert-True {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        $Condition,
        [string]$Message
    )
    # PS 真值規則:$false / $null / 0 / '' / @() 都 falsy
    $truthy = $false
    if ($null -ne $Condition) {
        try {
            $truthy = [bool]$Condition
        } catch {
            $truthy = $false
        }
    }
    if ($truthy) {
        _RecordPass $Name
    } else {
        $detail = "expected truthy, got: $(_Repr $Condition)"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
    }
}

# ─── Assert-Match ────────────────────────────────────────────────────────────

function Assert-Match {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Pattern,
        [string]$InputText,
        [string]$Message
    )
    $text = if ($null -eq $InputText) { '' } else { [string]$InputText }
    if ($text -match $Pattern) {
        _RecordPass $Name
    } else {
        $snippet = if ($text.Length -gt 200) { $text.Substring(0, 200) + '...<truncated>' } else { $text }
        $detail = "pattern: $Pattern`ninput:   $snippet"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
    }
}

# ─── Assert-Throws ───────────────────────────────────────────────────────────

function Assert-Throws {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
        [string]$ExpectedMessagePattern,
        [string]$Message
    )
    $threw     = $false
    $thrownMsg = ''
    try {
        & $ScriptBlock | Out-Null
    } catch {
        $threw     = $true
        $thrownMsg = $_.Exception.Message
    }

    if (-not $threw) {
        $detail = 'expected scriptblock to throw, but it did not'
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
        return
    }

    if ([string]::IsNullOrWhiteSpace($ExpectedMessagePattern)) {
        _RecordPass $Name
        return
    }

    if ($thrownMsg -match $ExpectedMessagePattern) {
        _RecordPass $Name
    } else {
        $detail = "thrown message did not match pattern.`npattern: $ExpectedMessagePattern`nmessage: $thrownMsg"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
    }
}

# ─── Assert-FileBytes ────────────────────────────────────────────────────────

function Assert-FileBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][byte[]]$ExpectedBytes,
        [Parameter(Mandatory = $true)][string]$ActualFilePath,
        [string]$Message
    )
    if (-not [System.IO.File]::Exists($ActualFilePath)) {
        $detail = "file does not exist: $ActualFilePath"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
        return
    }

    $actualBytes = [System.IO.File]::ReadAllBytes($ActualFilePath)

    if ($actualBytes.Length -ne $ExpectedBytes.Length) {
        $detail = "byte length mismatch.`nexpected length: $($ExpectedBytes.Length)`nactual length:   $($actualBytes.Length)"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
        return
    }

    for ($i = 0; $i -lt $ExpectedBytes.Length; $i++) {
        if ($ExpectedBytes[$i] -ne $actualBytes[$i]) {
            $expHex = ('{0:X2}' -f $ExpectedBytes[$i])
            $actHex = ('{0:X2}' -f $actualBytes[$i])
            $detail = "byte mismatch at offset $i.`nexpected: 0x$expHex`nactual:   0x$actHex"
            if (-not [string]::IsNullOrWhiteSpace($Message)) {
                $detail = "$Message`n$detail"
            }
            _RecordFail $Name $detail
            return
        }
    }

    _RecordPass $Name
}

# ─── Assert-SvnLogTextRoundTrip ──────────────────────────────────────────────
#
# 為什麼是 text round-trip 而不是 byte-equal:見檔頭註解 (plan F-3 correction)。
# 此 helper 把 svn log 的 raw stdout bytes 用 [Console]::OutputEncoding decode 成
# string，然後跟 $ExpectedText (UTF-8 source 中的中文 literal) 做 string -eq 比對。
# Pass 條件 = decoded text 「語意上」與 expected 相等 (string equality 在 PS 用
# .NET String.Equals，是 Unicode codepoint sequence 比對)。

function Assert-SvnLogTextRoundTrip {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$ExpectedText,
        [Parameter(Mandatory = $true)][int]$RevN,
        [Parameter(Mandatory = $true)][string]$RepoPathOrUrl,
        [string]$Message,
        # 注入點 — 給 meta-test 用 (在不真的跑 svn 的情況下測 decode 邏輯)。
        # 一般 caller 不需要傳。
        [byte[]]$DecodeBytesOverride
    )

    if ($null -ne $DecodeBytesOverride) {
        # 測試 / mock 路徑:跳過 svn 直接 decode 給定 bytes。
        $rawBytes = $DecodeBytesOverride
    } else {
        # 真實 SVN 路徑:呼叫 svn log -r <N> <repo> 取 stdout raw bytes。
        # 透過 Get-RawCommitDump.ps1 helper (位於同 lib 目錄)。
        $dumpScript = [System.IO.Path]::Combine($PSScriptRoot, 'Get-RawCommitDump.ps1')
        if (-not [System.IO.File]::Exists($dumpScript)) {
            $detail = "Get-RawCommitDump.ps1 not found at: $dumpScript"
            if (-not [string]::IsNullOrWhiteSpace($Message)) {
                $detail = "$Message`n$detail"
            }
            _RecordFail $Name $detail
            return
        }
        try {
            $rawBytes = & $dumpScript -RevN $RevN -RepoPathOrUrl $RepoPathOrUrl -ReturnFormat Bytes
        } catch {
            $detail = "Get-RawCommitDump.ps1 threw: $($_.Exception.Message)"
            if (-not [string]::IsNullOrWhiteSpace($Message)) {
                $detail = "$Message`n$detail"
            }
            _RecordFail $Name $detail
            return
        }
    }

    if ($null -eq $rawBytes -or $rawBytes.Length -eq 0) {
        $detail = "raw svn log bytes empty for r$RevN @ $RepoPathOrUrl"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
        return
    }

    $consoleEnc = [Console]::OutputEncoding
    if ($null -eq $consoleEnc) { $consoleEnc = [System.Text.Encoding]::UTF8 }
    $decoded = $consoleEnc.GetString($rawBytes)

    if ($decoded.Contains($ExpectedText)) {
        _RecordPass $Name
    } else {
        $snippet = if ($decoded.Length -gt 400) { $decoded.Substring(0, 400) + '...<truncated>' } else { $decoded }
        $detail = "decoded svn log text does not contain expected.`nexpected: $ExpectedText`ndecoded:  $snippet"
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $detail = "$Message`n$detail"
        }
        _RecordFail $Name $detail
    }
}
