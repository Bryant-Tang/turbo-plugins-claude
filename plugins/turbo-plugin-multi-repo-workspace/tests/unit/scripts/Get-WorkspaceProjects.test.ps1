# Get-WorkspaceProjects.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-multi-repo-workspace/scripts/Get-WorkspaceProjects.ps1
# Output contract: zero or more plain `PROJECT ...` lines, then EXACTLY ONE terminal `TP_TOKEN:` line.
# Symmetric with the bash sibling get-workspace-projects.test.sh.

# Skip conditions must be resolved at DISCOVERY time (Pester 5): a flag set in BeforeAll is $null
# during discovery, which would skip everything.
BeforeDiscovery {
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Get-WorkspaceProjects.ps1')
    if (-not (Test-Path -LiteralPath $script:ScriptUnderTest -PathType Leaf)) {
        throw "Get-WorkspaceProjects.ps1 not found at: $script:ScriptUnderTest"
    }

    # This suite CANNOT use the repo-relative tests/.sandbox/: the subject under test asks "is this
    # folder inside a git repository?", and a sandbox under plugins/ answers yes (this repo), so
    # every multi-repo-workspace scenario would collapse into WORKSPACE_IS_REPO. The work root
    # therefore has to sit outside any repo. Still path-free -- derived at runtime, never hardcoded,
    # and removed in the finally block of each It.
    function New-WorkspaceSandbox {
        # Expand 8.3 short-name segments in %TEMP% (e.g. FIRSTL~1): Remove-Item -LiteralPath on
        # PS 5.1 fails against a short-named parent, and Resolve-Path does not expand them.
        # GetTempPath(), not $env:TEMP: TEMP is a Windows-only variable and is unset under pwsh on
        # Linux, so Combine() would receive $null and yield a RELATIVE path -- the sandbox would be
        # created inside the repo. For this suite that is not just untidy: its own "is this folder
        # inside a git repo?" guard then correctly answers yes and skips every case, so the whole
        # file silently self-disabled on the ubuntu runner.
        $tempDir = [System.IO.Path]::GetTempPath()
        try { $tempDir = (Get-Item -LiteralPath $tempDir).FullName } catch { }
        $dir = [System.IO.Path]::Combine($tempDir, 'turbo-mrw-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }

    function Remove-WorkspaceSandbox {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try {
            if ([System.IO.Directory]::Exists($Dir)) {
                # git object files are read-only; clear the attribute before deleting.
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

    function Invoke-GitQuiet {
        param([string]$Dir, [string[]]$GitArgs)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & git -C $Dir @GitArgs 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $prev }
    }

    function New-Repo {
        param([string]$Path)
        $null = New-Item -ItemType Directory -Path $Path -Force
        Invoke-GitQuiet -Dir $Path -GitArgs @('init', '-q', '-b', 'main')
        Invoke-GitQuiet -Dir $Path -GitArgs @('config', 'user.email', 'test@example.invalid')
        Invoke-GitQuiet -Dir $Path -GitArgs @('config', 'user.name', 'Test')
        Invoke-GitQuiet -Dir $Path -GitArgs @('-c', 'commit.gpgsign=false', 'commit', '-q', '--allow-empty', '-m', 'init')
    }

    # Is this directory inside a git repo? The workspace scenarios REQUIRE that it is not.
    function Test-InsideRepo {
        param([string]$Path)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try { & git -C $Path rev-parse --git-dir 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }
        catch { return $false }
        finally { $ErrorActionPreference = $prev }
    }

    function Invoke-Survey {
        param([string]$WorkspaceRoot)
        $prev = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        try {
            # `powershell` only exists on Windows; PowerShell 7+ (including the ubuntu runner) ships
            # `pwsh`. Spawn the SAME edition this process runs under so the child resolves.
            $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
            $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest -WorkspaceRoot $WorkspaceRoot 2>$null
            $exit = $LASTEXITCODE
        } catch {
            $out = @($_.Exception.Message); $exit = 99
        } finally {
            $ErrorActionPreference = $prev
        }
        $lines = @($out | ForEach-Object { [string]$_ })
        return @{
            Lines    = $lines
            Text     = ($lines -join "`n")
            Exit     = $exit
            Tokens   = @($lines | Where-Object { $_ -like 'TP_TOKEN:*' })
            Projects = @($lines | Where-Object { $_ -like 'PROJECT *' })
        }
    }

    # The PROJECT line whose path ends with the given leaf name.
    function Get-ProjectLine {
        param($Result, [string]$Leaf)
        return @($Result.Projects | Where-Object { $_ -match ([regex]::Escape($Leaf) + '$') }) | Select-Object -First 1
    }
}

Describe 'Get-WorkspaceProjects output contract' -Skip:(-not $hasGit) {

    It 'lists sibling repos, one PROJECT line each, and ignores a folder without .git' {
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) {
                Write-Warning "skipped: the temp root ($sb) is inside a git repo; the workspace scenarios are UNGUARDED this run."
                Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return
            }
            $ws = [System.IO.Path]::Combine($sb, 'ws')
            New-Repo -Path ([System.IO.Path]::Combine($ws, 'proj-a'))
            New-Repo -Path ([System.IO.Path]::Combine($ws, 'proj-b'))
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($ws, 'just-a-folder')) -Force

            $r = Invoke-Survey -WorkspaceRoot $ws
            $r.Exit | Should -Be 0
            $r.Tokens.Count | Should -Be 1
            $r.Tokens[0] | Should -Be 'TP_TOKEN:PROJECTS count=2'
            $r.Projects.Count | Should -Be 2
            $r.Text | Should -Not -Match 'just-a-folder'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'reports setup=yes only for a project that already has a .turbo-plugin marker' {
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $ws = [System.IO.Path]::Combine($sb, 'ws')
            New-Repo -Path ([System.IO.Path]::Combine($ws, 'fresh'))
            New-Repo -Path ([System.IO.Path]::Combine($ws, 'done'))
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($ws, 'done', '.turbo-plugin')) -Force

            $r = Invoke-Survey -WorkspaceRoot $ws
            (Get-ProjectLine -Result $r -Leaf 'fresh') | Should -BeLike '*setup=no*'
            (Get-ProjectLine -Result $r -Leaf 'done') | Should -BeLike '*setup=yes*'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'reports main=no for a linked worktree among the children' {
        # The SKILL must not offer git-svn setup there: that setup refuses a linked worktree, so
        # offering it would walk the user into a guaranteed refusal.
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $ws = [System.IO.Path]::Combine($sb, 'ws')
            $projA = [System.IO.Path]::Combine($ws, 'proj-a')
            New-Repo -Path $projA
            Invoke-GitQuiet -Dir $projA -GitArgs @('worktree', 'add', '-q', [System.IO.Path]::Combine($ws, 'peer-wt'), '-b', 'feat/x')

            $r = Invoke-Survey -WorkspaceRoot $ws
            (Get-ProjectLine -Result $r -Leaf 'proj-a') | Should -BeLike '*main=yes*'
            (Get-ProjectLine -Result $r -Leaf 'peer-wt') | Should -BeLike '*main=no*'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'never lists a git-svn bridge worktree, because it is a grandchild' {
        # git-svn parks bridges at <project>/.turbo-plugin/worktrees/remote-svn-*, each carrying a
        # .git FILE. Scanning one level deep is what keeps a bridge from being mistaken for a
        # sibling project; this pins that the scan stays shallow.
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $ws = [System.IO.Path]::Combine($sb, 'ws')
            $projA = [System.IO.Path]::Combine($ws, 'proj-a')
            New-Repo -Path $projA
            $bridge = [System.IO.Path]::Combine($projA, '.turbo-plugin', 'worktrees', 'remote-svn-main')
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($projA, '.turbo-plugin', 'worktrees')) -Force
            Invoke-GitQuiet -Dir $projA -GitArgs @('worktree', 'add', '-q', $bridge, '-b', 'remote-svn/main')

            $r = Invoke-Survey -WorkspaceRoot $ws
            $r.Projects.Count | Should -Be 1
            $r.Text | Should -Not -Match 'remote-svn-main'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'answers WORKSPACE_IS_REPO when the folder is itself a repo, and lists no projects' {
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $solo = [System.IO.Path]::Combine($sb, 'solo')
            New-Repo -Path $solo
            New-Repo -Path ([System.IO.Path]::Combine($solo, 'vendored'))

            $r = Invoke-Survey -WorkspaceRoot $solo
            $r.Tokens.Count | Should -Be 1
            $r.Tokens[0] | Should -BeLike 'TP_TOKEN:WORKSPACE_IS_REPO*'
            $r.Projects.Count | Should -Be 0
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'answers WORKSPACE_IS_REPO for a plain subdirectory of a repo (rev-parse walks up)' {
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $outer = [System.IO.Path]::Combine($sb, 'outer')
            New-Repo -Path $outer
            $sub = [System.IO.Path]::Combine($outer, 'sub')
            New-Repo -Path ([System.IO.Path]::Combine($sub, 'nested'))

            $r = Invoke-Survey -WorkspaceRoot $sub
            $r.Tokens[0] | Should -BeLike 'TP_TOKEN:WORKSPACE_IS_REPO*'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'answers NO_PROJECTS when no child has .git' {
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $empty = [System.IO.Path]::Combine($sb, 'empty')
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($empty, 'a')) -Force
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($empty, 'b')) -Force

            $r = Invoke-Survey -WorkspaceRoot $empty
            $r.Exit | Should -Be 0
            $r.Tokens.Count | Should -Be 1
            $r.Tokens[0] | Should -BeLike 'TP_TOKEN:NO_PROJECTS*'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'a workspace root that does not exist fails as TP_TOKEN:ERROR, not tokenless' {
        $sb = New-WorkspaceSandbox
        try {
            $absent = [System.IO.Path]::Combine($sb, 'definitely-not-here')
            $r = Invoke-Survey -WorkspaceRoot $absent
            $r.Exit | Should -Not -Be 0
            $r.Tokens.Count | Should -Be 1
            $r.Tokens[0] | Should -BeLike 'TP_TOKEN:ERROR*'
            [System.IO.Directory]::Exists($absent) | Should -BeFalse
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }

    It 'emits the token line and the PROJECT lines with the same spelling of the workspace path' {
        # Resolve-Path leaves 8.3 short names alone while Get-ChildItem reports long names, so
        # without the explicit expansion in the script the token line and the PROJECT lines would
        # disagree on how the same directory is spelled -- which reads as two different places.
        $sb = New-WorkspaceSandbox
        try {
            if (Test-InsideRepo -Path $sb) { Set-ItResult -Skipped -Because 'temp root is inside a git repo'; return }
            $ws = [System.IO.Path]::Combine($sb, 'ws')
            New-Repo -Path ([System.IO.Path]::Combine($ws, 'proj-a'))

            # Ask using the raw %TEMP% spelling, which on this host may carry a short name.
            $rawWs = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), [System.IO.Path]::GetFileName($sb), 'ws')
            $r = Invoke-Survey -WorkspaceRoot $rawWs
            $r.Tokens.Count | Should -Be 1
            $projectPath = ($r.Projects[0] -replace '^.*\bpath=', '')
            # The project path must sit under the workspace path the script reported for itself.
            $r.Projects[0] | Should -BeLike '*proj-a'
            $parent = [System.IO.Path]::GetDirectoryName($projectPath)
            $parent | Should -Match 'ws$'
            $parent | Should -Not -Match '~1'
        } finally {
            Remove-WorkspaceSandbox -Dir $sb
        }
    }
}
