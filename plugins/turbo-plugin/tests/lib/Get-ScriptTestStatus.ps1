# Get-ScriptTestStatus.ps1
#
# 讀 caller 傳入的 -TargetDoc(通常為 <RunDir>/script-tests-results.md)的 tracking row,
# 統計 PASS / FAIL / FAIL-known / SKIP / BLOCKED-BY 各幾個,輸出 console summary,
# 並回傳合適 exit code。
#
# Exit code 規則 (R29 / R32 對齊):
#   0 = (a) 全 PASS  OR  (b) 所有 non-PASS 都是 FAIL-known / SKIP / BLOCKED-BY
#       (亦即「沒有 unacknowledged FAIL」)
#   1 = 至少 1 個 raw `FAIL` (未升級為 FAIL-known 也未 BLOCKED-BY 標記)
#
# R29 dedup:同 case ID 跑多次留多 row → 取最後一個為 authoritative。
#
# 用法:
#   & .\Get-ScriptTestStatus.ps1 -TargetDoc 'plugins/turbo-plugin/tests/runs/v1.0.0/script-tests-results.md'

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$TargetDoc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if (-not [System.IO.File]::Exists($TargetDoc)) {
    throw "TargetDoc not found: $TargetDoc"
}

$content = [System.IO.File]::ReadAllText($TargetDoc, [System.Text.Encoding]::UTF8)
$lines   = $content -split "`r?`n"

# 掃所有 markdown table data row (排除 header 與 separator)。
# 認可:第一個 cell 看起來像 case ID (`P1-...`)。
$cells = @()
$rowsByCase = @{}
foreach ($ln in $lines) {
    if (-not $ln.StartsWith('|')) { continue }
    if ($ln -match '^\|\s*case\s*ID\s*\|') { continue }
    if ($ln -match '^\|\s*-+') { continue }
    if ($ln -match '^\|\s*P1-') {
        # 拆 cell
        $body = $ln.Trim()
        if ($body.StartsWith('|')) { $body = $body.Substring(1) }
        if ($body.EndsWith('|'))   { $body = $body.Substring(0, $body.Length - 1) }
        $parts = $body -split '\s*\|\s*'
        if ($parts.Length -ge 6) {
            $caseId = $parts[0].Trim()
            $result = $parts[5].Trim()
            # 後寫覆蓋 (R29 authoritative latest)
            $rowsByCase[$caseId] = $result
            $cells += @{ CaseId = $caseId; Result = $result }
        }
    }
}

$total       = $rowsByCase.Count
$pass        = 0
$fail        = 0
$failKnown   = 0
$skip        = 0
$blocked     = 0
$other       = 0
$failRows    = @()
$blockedRows = @()

foreach ($k in $rowsByCase.Keys) {
    $r = $rowsByCase[$k]
    switch -Regex ($r) {
        '^PASS$'         { $pass++;     break }
        '^FAIL-known$'   { $failKnown++; break }
        '^FAIL$'         { $fail++;      $failRows += "$k -> $r"; break }
        '^SKIP$'         { $skip++;      break }
        '^BLOCKED-BY:.*' { $blocked++;   $blockedRows += "$k -> $r"; break }
        default          { $other++;     $failRows += "$k -> $r (unknown result)" }
    }
}

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
Write-Output "Script tests status (source: $TargetDoc)"
Write-Output '─────────────────────────────────────────────────────────────────────'
Write-Output "  Total unique cases:  $total"
Write-Output "  PASS:                $pass"
Write-Output "  FAIL:                $fail"
Write-Output "  FAIL-known:          $failKnown"
Write-Output "  SKIP:                $skip"
Write-Output "  BLOCKED-BY:          $blocked"
if ($other -gt 0) {
    Write-Output "  (unknown result):    $other"
}

if ($failRows.Count -gt 0) {
    Write-Output ''
    Write-Output 'Unacknowledged FAILs:'
    foreach ($r in $failRows) { Write-Output "  - $r" }
}
if ($blockedRows.Count -gt 0) {
    Write-Output ''
    Write-Output 'BLOCKED-BY rows:'
    foreach ($r in $blockedRows) { Write-Output "  - $r" }
}

if ($fail -gt 0 -or $other -gt 0) {
    exit 1
}
exit 0
