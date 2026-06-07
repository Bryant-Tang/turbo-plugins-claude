# Invoke-SessionStart.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin/scripts/hooks/Invoke-SessionStart.ps1
# Behavior: 3-branch advisory hook(全部走 advisory message，不會 block session):
#   pre-check (1) — 非 git work tree → silent emit `{}` exit 0
#   pre-check (2) — 在 git submodule → silent emit `{}` exit 0
#   主邏輯:
#     (a) marker (.turbo-plugin/) 存在 + 在 main worktree → silent 通過
#     (b) marker 存在 + 在 peer worktree + 缺 dbhub.local.toml → advisory(Pattern B 警告)
#     (c) marker 存在 + dbhub.local.toml 也在 → silent 通過
#     (d) marker 不存在 + main worktree → advisory(請跑 /tp-setup)
#     (e) marker 不存在 + peer worktree → advisory(請回主 worktree 跑 /tp-setup)
#
# 因為設計是 advisory + 永遠 exit 0，本測試 focus 在「stdout JSON payload 內容」上。
#
# Cases:
#   1. non-git cwd: 非 git repo → silent exit 0 + `{}`
#   2. Pattern B + 缺 dbhub.local.toml: main repo + linked peer worktree + 在 peer cwd
#      + 有 dbhub.example.local.toml + 無 dbhub.local.toml → exit 0 + stdout 含
#      systemMessage 含 dbhub.local.toml 警告字串
#   3. 沒 marker(main worktree):git init + 沒 .turbo-plugin/ → exit 0 + stdout 含
#      systemMessage 含 /tp-setup 提示

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-SessionStart.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "turbo-plugin-test-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    # The non-git case MUST run from a dir that is NOT inside any git work tree. The repo-relative
    # tests/.sandbox/ lives INSIDE this repo's work tree, so a sandbox there would inherit the outer
    # repo. Use OS temp (outside the repo) for that one case only; long-form via GetFullPath so 8.3
    # short-names never appear.
    function New-NonGitSandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-plugin-test-$Purpose-$guid"))
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    function Remove-Sandbox {
        param([string]$Dir)
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
            # Quote -File so a spaced repo/parent path (AE8) survives Start-Process's space-join.
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"'))
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
}

Describe 'Invoke-SessionStart' {

    Context 'Case 1: non-git cwd silent' {
        BeforeAll {
            # Must be OUTSIDE any git work tree (see New-NonGitSandbox note above).
            $script:sb1 = New-NonGitSandbox 'hook-ss-nongit'
            $script:r1 = Invoke-Hook -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'non-git exits 0' { $script:r1.Exit | Should -Be 0 }
        # contract: 非 git → emit `{}` silent。不應該 emit systemMessage。
        It 'stdout is empty JSON object' { $script:r1.Stdout | Should -Match '^\{\s*\}\s*$' }
    }

    Context 'Case 2: Pattern B missing dbhub.local.toml warns' {
        BeforeAll {
            # 需要建一個 main worktree + linked peer worktree(讓 Test-IsMainWorktree 在 peer 回傳 false)。
            $script:sb2Main = New-Sandbox 'hook-ss-main'
            Push-Location -LiteralPath $script:sb2Main
            try {
                Invoke-GitSilent init -q -b main
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                [System.IO.File]::WriteAllText((Join-Path $script:sb2Main 'init.txt'), 'init', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                & git -c commit.gpgsign=false commit -q -m init *>$null
                Invoke-GitSilent branch peer-branch
            } finally { Pop-Location }
            # peer worktree dir 必須在 main 外部(linked worktree convention)，用 sibling 目錄
            $script:sb2Peer = [System.IO.Path]::Combine(
                [System.IO.Path]::GetDirectoryName($script:sb2Main),
                [System.IO.Path]::GetFileName($script:sb2Main) + '.peer-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
            Push-Location -LiteralPath $script:sb2Main
            try {
                Invoke-GitSilent worktree add $script:sb2Peer peer-branch
            } finally { Pop-Location }
            # 在 peer worktree 放 .turbo-plugin/ marker + dbhub.example.local.toml，但不放 dbhub.local.toml
            $peerMarkerDir = [System.IO.Path]::Combine($script:sb2Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($peerMarkerDir, 'dbhub.example.local.toml'),
                "# example`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r2 = Invoke-Hook -WorkDir $script:sb2Peer
        }
        AfterAll {
            # 先把 peer worktree 移除(避免 main 還想引用)
            if (-not [string]::IsNullOrWhiteSpace($script:sb2Main) -and [System.IO.Directory]::Exists($script:sb2Main) `
                    -and -not [string]::IsNullOrWhiteSpace($script:sb2Peer) -and [System.IO.Directory]::Exists($script:sb2Peer)) {
                Push-Location -LiteralPath $script:sb2Main
                try {
                    Invoke-GitSilent worktree remove --force $script:sb2Peer
                } catch { } finally { Pop-Location }
            }
            Remove-Sandbox $script:sb2Peer
            Remove-Sandbox $script:sb2Main
        }

        It 'Pattern B exits 0' { $script:r2.Exit | Should -Be 0 }
        It 'stdout 含 systemMessage 欄' { $script:r2.Stdout | Should -Match '"systemMessage"' }
        It '警告訊息提到 dbhub.local.toml' { $script:r2.Stdout | Should -Match 'dbhub\.local\.toml' }
    }

    Context 'Case 3: no marker main worktree prompts setup' {
        BeforeAll {
            $script:sb3 = New-Sandbox 'hook-ss-nomarker'
            Push-Location -LiteralPath $script:sb3
            try {
                Invoke-GitSilent init -q -b main
                Invoke-GitSilent config user.email 'test@example.invalid'
                Invoke-GitSilent config user.name 'Test'
                [System.IO.File]::WriteAllText((Join-Path $script:sb3 'init.txt'), 'init', (New-Object System.Text.UTF8Encoding($false)))
                Invoke-GitSilent add -A
                & git -c commit.gpgsign=false commit -q -m init *>$null
            } finally { Pop-Location }
            $script:r3 = Invoke-Hook -WorkDir $script:sb3
        }
        AfterAll { Remove-Sandbox $script:sb3 }

        It 'no-marker exits 0' { $script:r3.Exit | Should -Be 0 }
        It 'stdout 含 systemMessage 欄' { $script:r3.Stdout | Should -Match '"systemMessage"' }
        It '訊息提到 /tp-setup' { $script:r3.Stdout | Should -Match '/tp-setup' }
    }
}
