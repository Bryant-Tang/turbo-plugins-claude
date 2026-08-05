# Invoke-SessionStart.test.ps1 (Pester 5)
#
# Script: scripts/hooks/Invoke-SessionStart.ps1 (turbo-plugin-git-svn)
# Behavior: advisory hook(全部走 advisory message，不會 block session):
#   pre-check (1) — 非 git work tree → silent emit `{}` exit 0
#   pre-check (2) — 在 git submodule → silent emit `{}` exit 0
#   主邏輯:
#     (a) marker (.turbo-plugin/) 存在 → silent 通過(git-svn 無 marker-present 執行期關切)
#     (b) marker 不存在 + main worktree → advisory(請跑 /tp-setup)
#     (c) marker 不存在 + peer worktree → advisory(請回主 worktree 跑 /tp-setup)
#
# 因為設計是 advisory + 永遠 exit 0，本測試 focus 在「stdout JSON payload 內容」上。
#
# Cases:
#   1. non-git cwd: 非 git repo → silent exit 0 + `{}`
#   2. 沒 marker(main worktree):git init + 沒 .turbo-plugin/ → exit 0 + stdout 含
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

    Context 'Case 2: no marker main worktree prompts setup' {
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
