# sessionstart.Tests.ps1
#
# Script: plugins/turbo-plugin/scripts/hooks/Invoke-SessionStart.ps1
# Behavior: 3-branch advisory hook(全部走 advisory message,不會 block session):
#   pre-check (1) — 非 git work tree → silent emit `{}` exit 0
#   pre-check (2) — 在 git submodule → silent emit `{}` exit 0
#   主邏輯:
#     (a) marker (.turbo-plugin/) 存在 + 在 main worktree → silent 通過
#     (b) marker 存在 + 在 peer worktree + 缺 dbhub.local.toml → advisory(Pattern B 警告)
#     (c) marker 存在 + dbhub.local.toml 也在 → silent 通過
#     (d) marker 不存在 + main worktree → advisory(請跑 /tp-setup)
#     (e) marker 不存在 + peer worktree → advisory(請回主 worktree 跑 /tp-setup)
#
# 因為設計是 advisory + 永遠 exit 0,本測試 focus 在「stdout JSON payload 內容」上。
#
# Cases:
#   1. non-git cwd: 非 git repo → silent exit 0 + `{}`
#   2. Pattern B + 缺 dbhub.local.toml: main repo + linked peer worktree + 在 peer cwd
#      + 有 .turbo-plugin/dbhub.example.local.toml + 無 dbhub.local.toml → exit 0 + stdout 含
#      `systemMessage` 含 "Pattern B" 或 "dbhub" 警告字串
#   3. 沒 marker(main worktree):git init + 沒 .turbo-plugin/ → exit 0 + stdout 含
#      `systemMessage` 含 "tp-setup" 提示

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters

$pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-SessionStart.ps1')

function New-Sandbox { param([string]$Purpose)
    $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-$Purpose-$guid")
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}
function Remove-Sandbox { param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                try {
                    $fa = [System.IO.File]::GetAttributes($_.FullName)
                    if ($fa -band [System.IO.FileAttributes]::ReadOnly) {
                        [System.IO.File]::SetAttributes($_.FullName, $fa -band (-bnot [System.IO.FileAttributes]::ReadOnly))
                    }
                } catch { }
            }
            [System.IO.Directory]::Delete($Dir, $true)
        }
    } catch { }
}

function Invoke-GitSilent {
    $allArgs = $args
    $oldEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git @allArgs 2>$null | Out-Null
    } catch {
        # tolerate noisy git stderr
    } finally {
        $ErrorActionPreference = $oldEap
    }
}

function Invoke-Hook {
    param([string]$WorkDir)
    $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookout-$([Guid]::NewGuid().ToString('N')).txt")
    $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookerr-$([Guid]::NewGuid().ToString('N')).txt")
    try {
        $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $ScriptUnderTest)
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList $argList -WorkingDirectory $WorkDir `
            -RedirectStandardOutput $tmpStdout `
            -RedirectStandardError $tmpStderr `
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
}

$sb1 = $null
$sb2Main = $null
$sb2Peer = $null
$sb3 = $null

try {
    # ─── Case 1: non-git cwd → silent exit 0 + `{}` ────────────────────────────
    $sb1 = New-Sandbox 'hook-ss-nongit'
    $r1 = Invoke-Hook -WorkDir $sb1
    Assert-Equal -Name 'case1: non-git exit 0' -Expected 0 -Actual $r1.Exit
    # contract: 非 git → emit `{}` silent。不應該 emit `systemMessage`。
    Assert-Match -Name 'case1: stdout empty JSON' -Pattern '^\{\s*\}\s*$' -InputText $r1.Stdout

    # ─── Case 2: Pattern B + 缺 dbhub.local.toml → 警告 ────────────────────────
    # 需要建一個 main worktree + linked peer worktree(讓 Test-IsMainWorktree 在 peer 回傳 false)。
    $sb2Main = New-Sandbox 'hook-ss-main'
    Push-Location -LiteralPath $sb2Main
    try {
        Invoke-GitSilent init -q -b main
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $sb2Main 'init.txt'), 'init', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
        # branch for the peer worktree
        Invoke-GitSilent branch peer-branch
    } finally { Pop-Location }
    # peer worktree dir 必須在 main 外部(linked worktree convention),用 sibling 目錄
    $sb2Peer = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($sb2Main),
        [System.IO.Path]::GetFileName($sb2Main) + '.peer-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Push-Location -LiteralPath $sb2Main
    try {
        Invoke-GitSilent worktree add $sb2Peer peer-branch
    } finally { Pop-Location }
    # 在 peer worktree 放 .turbo-plugin/ marker + dbhub.example.local.toml,但不放 dbhub.local.toml
    $peerMarkerDir = [System.IO.Path]::Combine($sb2Peer, '.turbo-plugin')
    $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
    [System.IO.File]::WriteAllText(
        [System.IO.Path]::Combine($peerMarkerDir, 'dbhub.example.local.toml'),
        "# example`n",
        (New-Object System.Text.UTF8Encoding($false)))
    $r2 = Invoke-Hook -WorkDir $sb2Peer
    Assert-Equal -Name 'case2: Pattern B exit 0' -Expected 0 -Actual $r2.Exit
    # 應該 emit `systemMessage` 含 Pattern B / dbhub.local.toml 警告字串
    Assert-Match -Name 'case2: stdout 含 systemMessage 欄' -Pattern '"systemMessage"' -InputText $r2.Stdout
    Assert-Match -Name 'case2: 警告訊息提到 dbhub.local.toml' -Pattern 'dbhub\.local\.toml' -InputText $r2.Stdout

    # ─── Case 3: 沒 marker(main worktree)→ setup prompt ───────────────────────
    $sb3 = New-Sandbox 'hook-ss-nomarker'
    Push-Location -LiteralPath $sb3
    try {
        Invoke-GitSilent init -q -b main
        Invoke-GitSilent config user.email 'test@example.invalid'
        Invoke-GitSilent config user.name 'Test'
        [System.IO.File]::WriteAllText((Join-Path $sb3 'init.txt'), 'init', (New-Object System.Text.UTF8Encoding($false)))
        Invoke-GitSilent add -A
        & git -c commit.gpgsign=false commit -q -m init *>$null
    } finally { Pop-Location }
    $r3 = Invoke-Hook -WorkDir $sb3
    Assert-Equal -Name 'case3: no-marker exit 0' -Expected 0 -Actual $r3.Exit
    Assert-Match -Name 'case3: stdout 含 systemMessage 欄' -Pattern '"systemMessage"' -InputText $r3.Stdout
    Assert-Match -Name 'case3: 訊息提到 /tp-setup' -Pattern '/tp-setup' -InputText $r3.Stdout
}
catch {
    Write-Output "  [FAIL] unhandled exception: $($_.Exception.Message)"
    $script:Failed++
}
finally {
    # 先把 peer worktree 移除(避免 main 還想引用)
    if (-not [string]::IsNullOrWhiteSpace($sb2Main) -and [System.IO.Directory]::Exists($sb2Main) `
            -and -not [string]::IsNullOrWhiteSpace($sb2Peer) -and [System.IO.Directory]::Exists($sb2Peer)) {
        Push-Location -LiteralPath $sb2Main
        try {
            Invoke-GitSilent worktree remove --force $sb2Peer
        } catch { } finally { Pop-Location }
    }
    Remove-Sandbox $sb1
    Remove-Sandbox $sb2Peer
    Remove-Sandbox $sb2Main
    Remove-Sandbox $sb3
}

Write-Output ''
Write-Output "sessionstart.Tests: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
