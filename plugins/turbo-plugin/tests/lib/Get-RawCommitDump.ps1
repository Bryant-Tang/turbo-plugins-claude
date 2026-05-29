# Get-RawCommitDump.ps1
#
# 從 SVN repo 對指定 revision 取 commit message 的 raw bytes / decoded text。
# 給 Assert-SvnLogTextRoundTrip 與 script tests 中文 case 使用。
#
# 為什麼需要 raw bytes:
#   PS 5.1 + Windows console (Big5 / CP950) 處理 `svn log` stdout 的 codepage 在不同
#   環境會跑出不一樣的東西;若直接讀 string 比對，會被 codepage 干擾。本 script
#   call svn 並 capture stdout 為 byte[] (透過 ProcessStartInfo + StandardOutput
#   .BaseStream)，再用 [Console]::OutputEncoding decode (Bytes mode 就回 byte[])。
#
# 用法:
#   $bytes = & .\Get-RawCommitDump.ps1 -RevN 5 -RepoPathOrUrl 'C:\Turbo\test-turbo-plugin-svn-repo' -ReturnFormat Bytes
#   $text  = & .\Get-RawCommitDump.ps1 -RevN 5 -RepoPathOrUrl 'C:\Turbo\test-turbo-plugin-svn-repo' -ReturnFormat Text

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][int]$RevN,
    [Parameter(Mandatory = $true)][string]$RepoPathOrUrl,
    [Parameter(Mandatory = $true)][ValidateSet('Bytes', 'Text')][string]$ReturnFormat
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# 如果 RepoPathOrUrl 已經是 file:/// 或 http:// URL，直接用;
# 否則視為本機路徑，轉成 file:/// URI。
$repoArg = $RepoPathOrUrl
if ($repoArg -notmatch '^[a-z]+://') {
    # 本機路徑 → file:/// URI
    $normalized = $repoArg -replace '\\', '/'
    $repoArg = 'file:///' + $normalized
}

# 用 ProcessStartInfo 走 .NET 直接抓 stdout raw bytes，繞開 PS pipeline 自動
# string 轉換 (那會經過 [Console]::OutputEncoding，丟掉原 bytes 資訊)。
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = 'svn'
$psi.Arguments              = "log -r $RevN `"$repoArg`""
$psi.UseShellExecute        = $false
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError  = $true
$psi.CreateNoWindow         = $true

$proc = New-Object System.Diagnostics.Process
$proc.StartInfo = $psi
$null = $proc.Start()

$stdoutStream = $proc.StandardOutput.BaseStream
$memStream    = New-Object System.IO.MemoryStream
$buffer       = New-Object byte[] 4096
while ($true) {
    $read = $stdoutStream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { break }
    $memStream.Write($buffer, 0, $read)
}
$stderrText = $proc.StandardError.ReadToEnd()
$proc.WaitForExit()
$exitCode = $proc.ExitCode

$rawBytes = $memStream.ToArray()
$memStream.Dispose()

if ($exitCode -ne 0) {
    $errSnippet = if ([string]::IsNullOrEmpty($stderrText)) { '<empty>' } else { $stderrText.Trim() }
    throw "svn log -r $RevN $repoArg failed with exit code $exitCode. stderr: $errSnippet"
}

switch ($ReturnFormat) {
    'Bytes' {
        # 確保回傳的是真正的 byte[]，不是 PS 把單元素 pack 成 scalar
        return ,$rawBytes
    }
    'Text' {
        $enc = [Console]::OutputEncoding
        if ($null -eq $enc) { $enc = [System.Text.Encoding]::UTF8 }
        return $enc.GetString($rawBytes)
    }
}
