# Invoke-PostToolUseEnterWorktree.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-dotnet-framework-web/scripts/hooks/Invoke-PostToolUseEnterWorktree.ps1
# Behavior: fully no-op. Drain stdin, emit empty JSON `{}`, exit 0.
#   Separates concerns（canonical / runtime / VS UI 三層分離），hook 無事可做。
#
# Cases:
#   1. happy no-op: invoke 不傳特殊 env / stdin → exit 0、stdout 是 `{}` JSON、
#      未在 sandbox 產生任何 fixture file。
#   2. 中文 path no-op: cwd 含中文 → 仍 exit 0 + `{}`（R18 中文路徑 robustness 對應）。
#
# 注意:hook 是 advisory 設計，contract = 「永遠 exit 0、不丟出 unhandled exception」。
# 本 test focus 在「正常路徑的 contract」上，而非 error injection。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-PostToolUseEnterWorktree.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "turbo-plugin-test-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    function Remove-Sandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try {
            if ([System.IO.Directory]::Exists($Dir)) {
                [System.IO.Directory]::Delete($Dir, $true)
            }
        } catch { }
    }

    # Invoke hook script as a child powershell.exe via Start-Process so stdin / stdout / stderr
    # are isolated. Hook 會 drain stdin 然後 emit JSON 到 stdout。空檔當 stdin 避免 ReadToEnd() 阻塞。
    function Invoke-Hook {
        param([string]$WorkDir)
        $tmpStdin  = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookin-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookout-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-hookerr-$([Guid]::NewGuid().ToString('N')).txt")
        [System.IO.File]::WriteAllText($tmpStdin, '', (New-Object System.Text.UTF8Encoding($false)))
        try {
            # Quote -File so a spaced repo/parent path (AE8) survives Start-Process's space-join.
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"'))
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
}

Describe 'Invoke-PostToolUseEnterWorktree' {

    Context 'Case 1: happy no-op' {
        BeforeAll {
            $script:sb1 = New-Sandbox 'hook-pttu-happy'
            $script:r1 = Invoke-Hook -WorkDir $script:sb1
            $script:childFiles = @(Get-ChildItem -LiteralPath $script:sb1 -Recurse -Force -ErrorAction SilentlyContinue)
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'exits 0' { $script:r1.Exit | Should -Be 0 }
        It 'stdout is empty JSON object' { $script:r1.Stdout | Should -Match '^\{\s*\}\s*$' }
        It 'hook 未在 sandbox 產生任何 fixture file' { $script:childFiles.Count | Should -Be 0 }
    }

    Context 'Case 2: chinese path no-op' {
        BeforeAll {
            $script:sb2 = New-Sandbox 'hook-pttu-中文'
            $script:r2 = Invoke-Hook -WorkDir $script:sb2
        }
        AfterAll { Remove-Sandbox $script:sb2 }

        It '中文 path exits 0' { $script:r2.Exit | Should -Be 0 }
        It '中文 path stdout is empty JSON object' { $script:r2.Stdout | Should -Match '^\{\s*\}\s*$' }
    }
}
