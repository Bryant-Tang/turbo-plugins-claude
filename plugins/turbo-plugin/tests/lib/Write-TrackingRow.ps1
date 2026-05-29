# Write-TrackingRow.ps1
#
# 把一個 script test case 結果 append 為一個 Markdown table row 到 tracking doc 對應
# section 下方。Schema 對應 plugins/turbo-plugin/tests/docs/phase1-scripts-schema.md
# (U7 會 rename 為 script-tests-schema.md)的 `## Tracking schema` 段:
#
#   | case ID | section | fixture | expected | actual | result | evidence |
#
# 行為:
#   1. 讀 $TargetDoc，找 `### <Section>` heading。
#   2. 在該 heading 下方第一個非空白行附近 append 新 row (保持 markdown table 結構)。
#      若 section 下方還沒有 table，補一個 markdown table header 再 append。
#   3. Cell 內 escape:literal `|` → `\|`，newline (`\r\n` / `\n`) → `<br>`。
#   4. Append-only:絕不蓋掉既有 row;同 case ID 跑多次會留多 row (R29 後寫者
#      authoritative 由 Get-ScriptTestStatus 處理)。
#
# Result 允許值:`PASS` / `FAIL` / `FAIL-known` / `SKIP` / `BLOCKED-BY:<id>`
# (Get-ScriptTestStatus.ps1 統計時依此 enum 分桶)
#
# 用法 (caller — Invoke-ScriptTests.ps1 — 透過 -RunDir 算出 -TargetDoc 路徑後傳入):
#   & .\Write-TrackingRow.ps1 `
#     -CaseId    'P1-svn-log-中文' `
#     -Section   'svn-log' `
#     -Fixture   'fresh-base + r5 中文 commit' `
#     -Expected  'stdout 顯示 r5 訊息 byte-level 等於字典 3.1' `
#     -Actual    'exit 0;byte-compare OK' `
#     -Result    'PASS' `
#     -Evidence  '<RunDir>/_artifacts/svn-log/zh.nunit.xml' `
#     -TargetDoc '<RunDir>/script-tests-results.md'

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$CaseId,
    [Parameter(Mandatory = $true)][string]$Section,
    [Parameter(Mandatory = $true)][string]$Fixture,
    [Parameter(Mandatory = $true)][string]$Expected,
    [Parameter(Mandatory = $true)][string]$Actual,
    [Parameter(Mandatory = $true)][string]$Result,
    [Parameter(Mandatory = $true)][string]$Evidence,
    [Parameter(Mandatory = $true)][string]$TargetDoc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

if (-not [System.IO.File]::Exists($TargetDoc)) {
    throw "TargetDoc not found: $TargetDoc"
}

function Escape-Cell {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    $t = $Text -replace '\|', '\|'
    # newline → <br>;順序很重要,先處理 \r\n 再處理 \n / \r
    $t = $t -replace "`r`n", '<br>'
    $t = $t -replace "`n", '<br>'
    $t = $t -replace "`r", '<br>'
    return $t
}

$row = '| ' + (@(
    Escape-Cell $CaseId
    Escape-Cell $Section
    Escape-Cell $Fixture
    Escape-Cell $Expected
    Escape-Cell $Actual
    Escape-Cell $Result
    Escape-Cell $Evidence
) -join ' | ') + ' |'

# 讀整份 doc 為 lines (保留結尾 newline 行為)
$content = [System.IO.File]::ReadAllText($TargetDoc, [System.Text.Encoding]::UTF8)
$lines   = $content -split "`r?`n"

# 找 `### <Section>` heading 的行索引
$headingPattern = '^###\s+' + [regex]::Escape($Section) + '\s*$'
$headingIdx = -1
for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match $headingPattern) {
        $headingIdx = $i
        break
    }
}
if ($headingIdx -lt 0) {
    throw "Section heading '### $Section' not found in $TargetDoc"
}

# 從 heading 下方掃,找下一個 `### ` heading 或 `---` 分隔線 (即本 section 結尾)
# 在那之前找最後一個 markdown table row (以 `| ` 開頭、不是 `|---`)
$sectionEnd = $lines.Length
for ($i = $headingIdx + 1; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match '^###\s+' -or $lines[$i] -match '^---\s*$' -or $lines[$i] -match '^##\s+') {
        $sectionEnd = $i
        break
    }
}

# 在 [headingIdx+1, sectionEnd) 範圍找最後一個 table row
$lastTableRowIdx = -1
$hasTableHeader  = $false
for ($i = $headingIdx + 1; $i -lt $sectionEnd; $i++) {
    $ln = $lines[$i]
    if ($ln -match '^\|') {
        $lastTableRowIdx = $i
        if ($ln -match '^\|\s*case\s*ID\s*\|') {
            $hasTableHeader = $true
        }
    }
}

$newLines = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $lines.Length; $i++) {
    $newLines.Add($lines[$i]) | Out-Null
}

if ($lastTableRowIdx -ge 0) {
    # 已有 table → 直接 append 新 row 在最後一個 table row 後面
    $newLines.Insert($lastTableRowIdx + 1, $row) | Out-Null
} else {
    # Section 下還沒 table → 插入 header + separator + row。
    # 找 section heading 後第一個非空白行的位置作為 anchor;若 anchor 是 `_(rows TBD ...)_`
    # placeholder 則保留它在後面 (informational)。
    $insertAt = $headingIdx + 1
    # 跳過 heading 後緊接的空白行,讓 table 起始與 heading 之間維持 1 空行。
    while ($insertAt -lt $sectionEnd -and [string]::IsNullOrWhiteSpace($lines[$insertAt])) {
        $insertAt++
    }
    # 在 insertAt 處插入新 block (前後留空行)。
    $block = @(
        ''
        '| case ID | section | fixture | expected | actual | result | evidence |'
        '|---|---|---|---|---|---|---|'
        $row
        ''
    )
    for ($k = $block.Length - 1; $k -ge 0; $k--) {
        $newLines.Insert($insertAt, $block[$k]) | Out-Null
    }
}

# 寫回 — 保留原 file ending convention (用 "`n" join 是因為 markdown doc 通常 LF)。
# 為了避免改動既有非本 section 內容的 line ending，我們用 join "`n"。
$out = ($newLines -join "`n")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($TargetDoc, $out, $utf8NoBom)

Write-Output "Wrote row to '### $Section' in $TargetDoc"
