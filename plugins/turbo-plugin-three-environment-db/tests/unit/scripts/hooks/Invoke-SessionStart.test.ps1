# Invoke-SessionStart.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-three-environment-db/scripts/hooks/Invoke-SessionStart.ps1
# Behavior: advisory dbhub-branch-only hook (always exit 0, never blocks the session):
#   pre-check (1) — 非 git work tree → silent emit `{}`
#   pre-check (2) — 在 git submodule → silent emit `{}`
#   concern gate — 無 .turbo-plugin/dbhub.example.local.toml(專案未用 db) → silent `{}`
#   dbhub branch — db 在用 + peer worktree + 缺 dbhub.local.toml → advisory(Pattern B 警告)
#   其餘(main worktree、dbhub.local.toml 存在、無 marker) → silent `{}`
# db hook 不發 marker-missing 的 /tp-setup 提示(那屬 turbo-plugin-git-svn)。
#
# Cases:
#   1. non-git cwd → silent exit 0 + `{}`
#   2. db in use + Pattern B(peer + dbhub.example.local.toml + 無 dbhub.local.toml)
#      → exit 0 + stdout 含 systemMessage 含 dbhub.local.toml
#   3. no marker(main worktree) → exit 0 + `{}`(db 不做 setup 提示)
#   4. db NOT in use(peer + 無 dbhub.example.local.toml) → exit 0 + `{}`(gate no-op)

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-SessionStart.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "db-test-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    function New-NonGitSandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "db-test-$Purpose-$guid"))
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
        } finally {
            $ErrorActionPreference = $oldEap
        }
    }

    function New-MainAndPeer {
        param([string]$Purpose)
        $main = New-Sandbox $Purpose
        Push-Location -LiteralPath $main
        try {
            Invoke-GitSilent init -q -b main
            Invoke-GitSilent config user.email 'test@example.invalid'
            Invoke-GitSilent config user.name 'Test'
            [System.IO.File]::WriteAllText((Join-Path $main 'init.txt'), 'init', (New-Object System.Text.UTF8Encoding($false)))
            Invoke-GitSilent add -A
            & git -c commit.gpgsign=false commit -q -m init *>$null
            Invoke-GitSilent branch peer-branch
        } finally { Pop-Location }
        $peer = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($main),
            [System.IO.Path]::GetFileName($main) + '.peer-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        Push-Location -LiteralPath $main
        try { Invoke-GitSilent worktree add $peer peer-branch } finally { Pop-Location }
        return @{ Main = $main; Peer = $peer }
    }
    function Remove-MainAndPeer {
        param([hashtable]$Pair)
        if ($null -eq $Pair) { return }
        if (-not [string]::IsNullOrWhiteSpace($Pair.Main) -and [System.IO.Directory]::Exists($Pair.Main) `
                -and -not [string]::IsNullOrWhiteSpace($Pair.Peer) -and [System.IO.Directory]::Exists($Pair.Peer)) {
            Push-Location -LiteralPath $Pair.Main
            try { Invoke-GitSilent worktree remove --force $Pair.Peer } catch { } finally { Pop-Location }
        }
        Remove-Sandbox $Pair.Peer
        Remove-Sandbox $Pair.Main
    }

    function Invoke-Hook {
        param([string]$WorkDir)
        $tmpStdout = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "db-hookout-$([Guid]::NewGuid().ToString('N')).txt")
        $tmpStderr = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "db-hookerr-$([Guid]::NewGuid().ToString('N')).txt")
        try {
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

Describe 'db Invoke-SessionStart' {

    Context 'Case 1: non-git cwd silent' {
        BeforeAll {
            $script:sb1 = New-NonGitSandbox 'hook-ss-nongit'
            $script:r1 = Invoke-Hook -WorkDir $script:sb1
        }
        AfterAll { Remove-Sandbox $script:sb1 }

        It 'non-git exits 0' { $script:r1.Exit | Should -Be 0 }
        It 'stdout is empty JSON object' { $script:r1.Stdout | Should -Match '^\{\s*\}\s*$' }
    }

    Context 'Case 2: db in use + Pattern B missing dbhub.local.toml warns' {
        BeforeAll {
            $script:p2 = New-MainAndPeer 'hook-ss-warn'
            $peerMarkerDir = [System.IO.Path]::Combine($script:p2.Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($peerMarkerDir, 'dbhub.example.local.toml'),
                "# example`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r2 = Invoke-Hook -WorkDir $script:p2.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p2 }

        It 'Pattern B exits 0' { $script:r2.Exit | Should -Be 0 }
        It 'stdout 含 systemMessage 欄' { $script:r2.Stdout | Should -Match '"systemMessage"' }
        It '警告訊息提到 dbhub.local.toml' { $script:r2.Stdout | Should -Match 'dbhub\.local\.toml' }
    }

    Context 'Case 3: no marker main worktree is silent (no setup prompt)' {
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
        It 'stdout is empty JSON object (db emits no /tp-setup prompt)' { $script:r3.Stdout | Should -Match '^\{\s*\}\s*$' }
    }

    Context 'Case 4: db not in use gate no-op' {
        BeforeAll {
            $script:p4 = New-MainAndPeer 'hook-ss-gate'
            # marker dir exists but NO dbhub.example.local.toml (db not set up), no dbhub.local.toml
            $peerMarkerDir = [System.IO.Path]::Combine($script:p4.Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            $script:r4 = Invoke-Hook -WorkDir $script:p4.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p4 }

        It 'gate exits 0' { $script:r4.Exit | Should -Be 0 }
        It 'stdout is empty JSON object (db not in use)' { $script:r4.Stdout | Should -Match '^\{\s*\}\s*$' }
    }
}
