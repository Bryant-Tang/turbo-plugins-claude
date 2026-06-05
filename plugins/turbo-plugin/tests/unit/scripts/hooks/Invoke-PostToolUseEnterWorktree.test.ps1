# posttooluse-enterworktree.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/hooks/Invoke-PostToolUseEnterWorktree.ps1
# Behavior: v1.0 (U3) — fully no-op. Drain stdin, emit empty JSON `{}`, exit 0.
#   原本（v0.x）會把 .turbo-plugin/applicationhost.config 複製進 .vs/<sln>/config/,
#   v1.0 separates concerns（canonical / runtime / VS UI 三層分離），hook 無事可做。
#
# Cases:
#   1. happy no-op: invoke 不傳特殊 env / stdin → exit 0、stdout 是 `{}` JSON。
#   2. 中文 path no-op: cwd 含中文 → 仍 exit 0 + `{}`（R18 中文路徑 robustness 對應）。
#
# 注意:hook 是 advisory 設計（hooks.json 註解明示 "advisory（不會 block session）"），
# 故 contract = 「永遠 exit 0、不丟出 unhandled exception」。即使內部 try 失敗也走 catch
# 把 `{}` 印出再 exit 0,所以本 test focus 在「正常路徑的 contract」上,而非 error injection。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-PostToolUseEnterWorktree.ps1')

function New-Sandbox { param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine([System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes'), "turbo-plugin-test-$Purpose-$guid")
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}
function Remove-Sandbox { param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            [System.IO.Directory]::Delete($Dir, $true)
        }
    } catch { }
}

# Invoke hook script as a child powershell.exe via Start-Process so stdin / stdout / stderr
# are isolated. Hook 會 drain stdin 然後 emit JSON 到 stdout。為了讓 ReadToEnd() 不會阻塞,
# 我們透過 redirect 把空檔當 stdin。
function Invoke-Hook {
    param([string]$WorkDir)
    $tmpStdin  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookin-$([Guid]::NewGuid().ToString('N')).txt")
    $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookout-$([Guid]::NewGuid().ToString('N')).txt")
    $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookerr-$([Guid]::NewGuid().ToString('N')).txt")
    # 空檔當 stdin
    [System.IO.File]::WriteAllText($tmpStdin, '', (New-Object System.Text.UTF8Encoding($false)))
    try {
        # Quote -File so a spaced repo/parent path (AE8) survives Start-Process's space-join.
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $ScriptUnderTest + '"'))
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $argList -WorkingDirectory $WorkDir `
            -RedirectStandardInput $tmpStdin `
            -RedirectStandardOutput $tmpStdout `
            -RedirectStandardError $tmpStderr `
            -NoNewWindow -PassThru -Wait
        $stdout = if (Test-Path -LiteralPath $tmpStdout -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStdout, [System.Text.Encoding]::UTF8) } else { '' }
        $stderr = if (Test-Path -LiteralPath $tmpStderr -PathType Leaf) { [System.IO.File]::ReadAllText($tmpStderr, [System.Text.Encoding]::UTF8) } else { '' }
        return @{ Stdout = $stdout; Stderr = $stderr; Exit = $proc.ExitCode }
    } finally {
        foreach ($t in @($tmpStdin, $tmpStdout, $tmpStderr)) {
            if (Test-Path -LiteralPath $t -PathType Leaf) {
                try { [System.IO.File]::Delete($t) } catch { }
            }
        }
    }
}

$sb1 = $null
$sb2 = $null

try {
    # Case 1: happy no-op
    $sb1 = New-Sandbox 'hook-pttu-happy'
    $r1 = Invoke-Hook -WorkDir $sb1
    Assert-Equal -Name 'case1: exit 0' -Expected 0 -Actual $r1.Exit
    # stdout 是 empty JSON object `{}`（無 trailing newline 也算合法）
    Assert-Match -Name 'case1: stdout is empty JSON' -Pattern '^\{\s*\}\s*$' -InputText $r1.Stdout
    # 沒寫任何 fixture file 進 sandbox(hook is no-op)
    $childFiles = @(Get-ChildItem -LiteralPath $sb1 -Recurse -Force -ErrorAction SilentlyContinue)
    Assert-True -Name 'case1: hook 未在 sandbox 產生任何 fixture file' -Condition ($childFiles.Count -eq 0)

    # Case 2: 中文 path no-op
    $sb2 = New-Sandbox 'hook-pttu-中文'
    $r2 = Invoke-Hook -WorkDir $sb2
    Assert-Equal -Name 'case2: 中文 path exit 0' -Expected 0 -Actual $r2.Exit
    Assert-Match -Name 'case2: 中文 path stdout is empty JSON' -Pattern '^\{\s*\}\s*$' -InputText $r2.Stdout
}
catch {
    Write-Output "  [FAIL] unhandled exception: $($_.Exception.Message)"
    $script:Failed++
}
finally {
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2
}

Write-Output ''
Write-Output "posttooluse-enterworktree.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
