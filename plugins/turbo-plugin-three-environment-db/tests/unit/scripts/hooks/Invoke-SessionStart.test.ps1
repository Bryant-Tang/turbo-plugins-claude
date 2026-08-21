# Invoke-SessionStart.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-three-environment-db/scripts/hooks/Invoke-SessionStart.ps1
# Behavior: advisory dbhub-branch-only hook (always exit 0, never blocks the session):
#   pre-check (1) — 非 git work tree → silent emit `{}`
#   pre-check (2) — 在 git submodule → silent emit `{}`
#   concern gate — 無 .turbo-plugin/dbhub.example.toml(專案未用 db) → silent `{}`
#   dbhub branch — db 在用 + peer worktree + 缺 dbhub.local.toml → advisory(Pattern B 警告)
#   其餘(main worktree、dbhub.local.toml 存在、無 marker) → silent `{}`
# db hook 不發 marker-missing 的 /tp-setup 提示(那屬 turbo-plugin-git-svn)。
#
# Cases:
#   1. non-git cwd → silent exit 0 + `{}`
#   2. db in use + Pattern B(peer + dbhub.example.toml + 無 dbhub.local.toml)
#      → exit 0 + stdout 含 systemMessage 含 dbhub.local.toml
#   3. no marker(main worktree) → exit 0 + `{}`(db 不做 setup 提示)
#   4. db NOT in use(peer + 無任何 example 範本) → exit 0 + `{}`(gate no-op)
#   5/6. 改名前的舊範本名(dbhub.example.local.toml)一樣要 gate 得到 —— cwd 與下一層各一個。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'hooks', 'Invoke-SessionStart.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    # Keep sandbox names SHORT, and do not lengthen them casually.
    #
    # `git worktree add` writes an admin file at `<main>\.git\worktrees\<peer-name>\HEAD`, and on
    # Windows that whole path must fit in MAX_PATH (260). The peer name is derived from the main
    # one, so every character here is spent twice. The previous naming
    # (`db-test-<purpose>-<12 hex>` plus a `.peer-<8 hex>` suffix) fitted for three of the four
    # peer Contexts and overflowed on the fourth -- and because `git worktree add` is silenced,
    # that Context ran against an ordinary directory instead of a worktree.
    function New-Sandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 6)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "db-$Purpose-$guid")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }
    function New-NonGitSandbox {
        param([string]$Purpose)
        $guid = [Guid]::NewGuid().ToString('N').Substring(0, 6)
        $dir = [System.IO.Path]::GetFullPath(
            [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "db-$Purpose-$guid"))
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
            [System.IO.Path]::GetFileName($main) + '-p')
        Push-Location -LiteralPath $main
        try { Invoke-GitSilent worktree add $peer peer-branch } finally { Pop-Location }
        return @{ Main = $main; Peer = $peer }
    }
    # Every peer-worktree Context must assert this before anything else.
    #
    # `git worktree add` in New-MainAndPeer is silenced, so when it fails the caller still gets a
    # path -- and the next New-Item creates that path as an ORDINARY directory. The hook then runs
    # inside whatever repository contains the sandbox, and its answer depends on whether THAT
    # checkout is a main or a linked worktree. Both outcomes are wrong and neither looks wrong.
    # Observed 2026-08-21 in the bash twin: four peer tests reported green for that reason.
    function Test-IsLinkedWorktree {
        param([string]$Peer)
        return (Test-Path -LiteralPath ([System.IO.Path]::Combine($Peer, '.git')))
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
            $script:p2 = New-MainAndPeer 'warn'
            $peerMarkerDir = [System.IO.Path]::Combine($script:p2.Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($peerMarkerDir, 'dbhub.example.toml'),
                "# example`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r2 = Invoke-Hook -WorkDir $script:p2.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p2 }

        It 'fixture: the peer really is a linked worktree' { Test-IsLinkedWorktree $script:p2.Peer | Should -BeTrue }
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
            $script:p4 = New-MainAndPeer 'gate'
            # marker dir exists but NO example template at all (db not set up), no dbhub.local.toml
            $peerMarkerDir = [System.IO.Path]::Combine($script:p4.Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            $script:r4 = Invoke-Hook -WorkDir $script:p4.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p4 }

        It 'fixture: the peer really is a linked worktree' { Test-IsLinkedWorktree $script:p4.Peer | Should -BeTrue }
        It 'gate exits 0' { $script:r4.Exit | Should -Be 0 }
        It 'stdout is empty JSON object (db not in use)' { $script:r4.Stdout | Should -Match '^\{\s*\}\s*$' }
    }

    # Cases 5 + 6: the PRE-RENAME template name must keep gating.
    #
    # `dbhub.example.local.toml` is what every project set up before the rename has committed.
    # If the gate stopped recognising it, those projects would silently stop being warned -- the
    # hook would decide they do not use a database at all. Nothing would look broken, which is why
    # this is tested rather than trusted: the only symptom is the absence of a message the user
    # never knew to expect. Both lookups are covered because the cwd check and the one-level-down
    # scan are separate call sites.
    #
    # Emitting a systemMessage at all is what proves the gate let it through: every note the hook
    # can produce sits behind that gate, so `{}` and a warning cleanly separate the two outcomes.
    Context 'Case 5: pre-rename template name still gates (cwd)' {
        BeforeAll {
            $script:p5 = New-MainAndPeer 'lgc'
            $peerMarkerDir = [System.IO.Path]::Combine($script:p5.Peer, '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $peerMarkerDir -Force
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($peerMarkerDir, 'dbhub.example.local.toml'),
                "# example`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r5 = Invoke-Hook -WorkDir $script:p5.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p5 }

        It 'fixture: the peer really is a linked worktree' { Test-IsLinkedWorktree $script:p5.Peer | Should -BeTrue }
        It 'legacy name exits 0' { $script:r5.Exit | Should -Be 0 }
        It '舊檔名一樣觸發警示' { $script:r5.Stdout | Should -Match '"systemMessage"' }
    }

    Context 'Case 6: pre-rename template name still gates (one level down)' {
        BeforeAll {
            $script:p6 = New-MainAndPeer 'lgcd'
            $subMarkerDir = [System.IO.Path]::Combine($script:p6.Peer, 'sub', '.turbo-plugin')
            $null = New-Item -ItemType Directory -Path $subMarkerDir -Force
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($subMarkerDir, 'dbhub.example.local.toml'),
                "# example`n",
                (New-Object System.Text.UTF8Encoding($false)))
            $script:r6 = Invoke-Hook -WorkDir $script:p6.Peer
        }
        AfterAll { Remove-MainAndPeer $script:p6 }

        It 'fixture: the peer really is a linked worktree' { Test-IsLinkedWorktree $script:p6.Peer | Should -BeTrue }
        It 'legacy name one level down exits 0' { $script:r6.Exit | Should -Be 0 }
        It '舊檔名在下一層也 gate 得到' { $script:r6.Stdout | Should -Match '"systemMessage"' }
    }
}
