# Core.test.ps1 (Pester 5)
#
# Subject under test: plugins/turbo-plugin-git-svn/scripts/lib/Core.ps1 -- specifically its
# git-reading helpers (Probe-GitVersion / Get-MainWorktree / Test-IsMainWorktree /
# Test-IsSubmodule) and the Read-Git wrapper they all go through.
#
# Core.ps1 is carried BYTE-IDENTICALLY by four plugins (tools/verify-core-identical.sh pins the
# set and fails on drift), so testing the canonical git-svn copy tests all four. The other three
# suites deliberately do not duplicate this file -- a second copy could only ever disagree with
# this one about a file that is guaranteed to be the same bytes.
#
# What these cases exist for (issue #123)
# ---------------------------------------
# Windows PowerShell 5.1 turns ANY stderr write by a native command whose output is CAPTURED
# into a terminating NativeCommandError while $ErrorActionPreference = 'Stop', and `2>$null`
# does NOT prevent it. git warns on stderr while still exiting 0 in ordinary, healthy
# situations -- `warning: detected dubious ownership in repository` is what every CI image,
# container, and machine whose clone was made under another account produces. Before the fix:
#
#   Get-MainWorktree    swallowed the throw and answered 'Not inside a git repository.'
#                       -- the exact opposite of the truth, with nothing pointing at the cause.
#   Test-IsMainWorktree threw the raw NativeCommandError out of a predicate that has no
#   Test-IsSubmodule    failure mode at all, taking the whole calling script down with it.
#
# The bash half never had this: core.sh uses `2>/dev/null || true`, which drops the warning and
# keeps stdout. So each case below is also a .ps1-vs-.sh parity assertion.
#
# Every case runs the subject in a CHILD powershell.exe rather than calling it in-process. That
# is load-bearing: the bug only exists under `Set-StrictMode -Version Latest` +
# $ErrorActionPreference = 'Stop' at SCRIPT scope, which is how production entry scripts consume
# Core.ps1 but is NOT what a Pester `BeforeAll` gives you. Dot-sourcing into the test session
# would make every case here pass against the broken code.
#
# Git-only -- no SVN. Deliberately pure ASCII: a .ps1 carrying non-ASCII needs a UTF-8 BOM to
# survive PS 5.1 on a Big5 system codepage, and staying ASCII removes that dependency outright.

BeforeAll {
    # <plugin>/tests/unit/scripts/lib/<this>.ps1 -> <plugin> is ..,..,..,..
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:CorePs1 = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Core.ps1')
    if (-not (Test-Path -LiteralPath $script:CorePs1 -PathType Leaf)) {
        throw "Core.ps1 not found at: $script:CorePs1"
    }

    . ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'ScriptsCommon.ps1'))

    # The harness reproduces how a production entry script consumes Core.ps1: StrictMode +
    # EAP=Stop at script scope, dot-source, call one function. It prints exactly one line --
    # 'RESULT:<value>' or 'ERROR:<message>' -- so a case can tell "answered X" from "threw X"
    # without parsing PowerShell's error formatting.
    function New-CoreHarness {
        param([string]$Dir)
        $path = [System.IO.Path]::Combine($Dir, 'harness.ps1')
        $lines = @(
            'param([string]$CorePath, [string]$Call, [string]$RepoRoot = '''')',
            'Set-StrictMode -Version Latest',
            '$ErrorActionPreference = ''Stop''',
            '. $CorePath',
            'try {',
            '    switch ($Call) {',
            '        ''Probe-GitVersion''    { Probe-GitVersion; Write-Output ''RESULT:ok'' }',
            '        ''Get-MainWorktree''    { Write-Output (''RESULT:'' + (Get-MainWorktree -RepoRoot $RepoRoot)) }',
            '        ''Test-IsMainWorktree'' { Write-Output (''RESULT:'' + (Test-IsMainWorktree -RepoRoot $RepoRoot)) }',
            '        ''Test-IsSubmodule''    { Write-Output (''RESULT:'' + (Test-IsSubmodule -RepoRoot $RepoRoot)) }',
            '        default { throw "unknown call ''$Call''" }',
            '    }',
            '} catch {',
            '    Write-Output (''ERROR:'' + $_.Exception.Message)',
            '    exit 1',
            '}',
            'exit 0'
        )
        [System.IO.File]::WriteAllLines($path, $lines, [System.Text.Encoding]::ASCII)
        return $path
    }

    # A `git` that writes a warning to stderr on EVERY invocation and then defers to the real
    # git, so the exit code and stdout are genuine. Warning on every call (rather than on
    # selected subcommands) is the point: the failure being guarded against is triggered by the
    # stderr write alone, independent of which subcommand produced it.
    function New-WarningGitShim {
        param([string]$Dir)
        $realGit = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $null = New-Item -ItemType Directory -Path $Dir -Force
        [System.IO.File]::WriteAllLines(
            [System.IO.Path]::Combine($Dir, 'git.cmd'),
            @(
                '@echo off',
                'echo warning: detected dubious ownership in repository 1>&2',
                ('"' + $realGit + '" %*')
            ),
            [System.Text.Encoding]::ASCII)
        return $Dir
    }

    # A shim that never resolves, or one that does not actually warn, turns every case in this
    # file into a pass that means nothing. Assert it before trusting any conclusion drawn under
    # it. stderr goes to a file rather than being folded in: this asks about stderr
    # specifically, and it keeps the lint's `2>&1`-on-a-native-exe rule satisfied.
    function Assert-ShimInEffect {
        param([string]$Dir)
        $probeErr = [System.IO.Path]::Combine($Dir, 'probe.err')
        & cmd.exe /c "git --version 2> `"$probeErr`"" | Out-Null
        $text = [System.IO.File]::ReadAllText($probeErr)
        if ($text -notmatch 'dubious ownership') {
            throw "fixture: the git shim in '$Dir' did not take effect (stderr was: '$text')"
        }
    }

    # A directory that is genuinely outside any repository. It cannot come from New-Sandbox:
    # those live under the plugin's tests/.sandbox/, which is INSIDE this repository, so git
    # discovery walks up and answers about the REAL repo. Planting a decoy .git directory does
    # not help either -- git skips a .git that has no valid layout and keeps walking (measured,
    # not assumed: that decoy is what this helper replaced, and it returned the marketplace
    # repo's own root). GetTempPath(), not $env:TEMP, for the reason recorded in Common.test.ps1.
    function New-OutsideRepoDir {
        $tempDir = [System.IO.Path]::GetTempPath()
        try { $tempDir = (Get-Item -LiteralPath $tempDir).FullName } catch { }
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($tempDir, "tp-core-outside-$stamp")
        $null = New-Item -ItemType Directory -Path $dir -Force
        # Precondition: prove it really is outside a repo. A temp dir that somehow sits inside
        # one would make every negative control below pass for the wrong reason.
        if ((Run-Git -Cwd $dir -GitArgs @('rev-parse', '--git-dir')) -eq 0) {
            throw "fixture: '$dir' is inside a git repository -- the negative controls would be vacuous"
        }
        return $dir
    }

    function Remove-OutsideRepoDir {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try {
            if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) }
        } catch { }
    }

    function Get-HarnessLine {
        param([string]$Text)
        $lines = @(($Text -replace "`r", '') -split "`n" | Where-Object { $_ -like 'RESULT:*' -or $_ -like 'ERROR:*' })
        if ($lines.Count -eq 0) { return '' }
        return $lines[0]
    }

    # Run one Core function in a child powershell, optionally with the warning shim on PATH.
    function Invoke-CoreCall {
        param(
            [string]$Sandbox,
            [string]$Call,
            [string]$RepoRoot = '',
            [switch]$WithWarningGit
        )
        $harness = New-CoreHarness -Dir $Sandbox
        $savedPath = $env:PATH
        try {
            if ($WithWarningGit) {
                $shimDir = [System.IO.Path]::Combine($Sandbox, 'shim')
                $null = New-WarningGitShim -Dir $shimDir
                $env:PATH = $shimDir + ';' + $savedPath
                Assert-ShimInEffect -Dir $shimDir
            }
            $res = Invoke-PsScript -ScriptPath $harness -ScriptArgs @(
                '-CorePath', $script:CorePs1, '-Call', $Call, '-RepoRoot', $RepoRoot)
            return [PSCustomObject]@{
                Line     = Get-HarnessLine $res.Stdout
                ExitCode = $res.ExitCode
                Stdout   = $res.Stdout
                Stderr   = $res.Stderr
            }
        } finally {
            $env:PATH = $savedPath
        }
    }
}

Describe 'Core.ps1 git readers' {

    Context 'a git that warns on stderr while exiting 0 (issue #123)' {

        It 'Get-MainWorktree still resolves the repository' {
            $sb = New-Sandbox -Tag 'core-1'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-GitMainRepo -Root $root

                $res = Invoke-CoreCall -Sandbox $sb -Call 'Get-MainWorktree' -RepoRoot $root -WithWarningGit

                $res.Line | Should -Not -Match '^ERROR:'
                $res.Line | Should -Match '^RESULT:'
                $res.ExitCode | Should -Be 0
                # The answer must be the repo root itself, not merely "something non-empty":
                # a wrong-but-present path is the other way this could fail quietly.
                $answer = $res.Line.Substring('RESULT:'.Length).Trim()
                $answer.TrimEnd('\', '/') | Should -Be ((Get-Item -LiteralPath $root).FullName.TrimEnd('\', '/'))
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'Test-IsMainWorktree answers True instead of throwing' {
            $sb = New-Sandbox -Tag 'core-2'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-GitMainRepo -Root $root

                $res = Invoke-CoreCall -Sandbox $sb -Call 'Test-IsMainWorktree' -RepoRoot $root -WithWarningGit

                $res.Line | Should -Be 'RESULT:True'
                $res.ExitCode | Should -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'Test-IsSubmodule answers False instead of throwing' {
            $sb = New-Sandbox -Tag 'core-3'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-GitMainRepo -Root $root

                $res = Invoke-CoreCall -Sandbox $sb -Call 'Test-IsSubmodule' -RepoRoot $root -WithWarningGit

                $res.Line | Should -Be 'RESULT:False'
                $res.ExitCode | Should -Be 0
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'Probe-GitVersion accepts the version and leaks no warning to stderr' {
            $sb = New-Sandbox -Tag 'core-4'
            try {
                $res = Invoke-CoreCall -Sandbox $sb -Call 'Probe-GitVersion' -WithWarningGit

                $res.Line | Should -Be 'RESULT:ok'
                $res.ExitCode | Should -Be 0
                # Passing while spraying git's warnings at the user is not passing. The inline
                # call this replaced let the warning through to the console on every run.
                $res.Stderr | Should -Not -Match 'dubious ownership'
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }

        It 'Test-IsMainWorktree still answers False in a LINKED worktree' {
            # Tolerating the warning must not turn the predicate into a constant. This is the
            # case that would fail if a "fix" simply stopped consulting git.
            $sb = New-Sandbox -Tag 'core-5'
            try {
                $root = [System.IO.Path]::Combine($sb, 'proj')
                New-GitMainRepo -Root $root
                $linked = [System.IO.Path]::Combine($sb, 'wt')
                $null = Run-Git -Cwd $root -GitArgs @('worktree', 'add', '-b', 'side', $linked)
                if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($linked, '.git')))) {
                    throw "fixture: '$linked' is not a linked worktree -- git worktree add failed silently"
                }

                $res = Invoke-CoreCall -Sandbox $sb -Call 'Test-IsMainWorktree' -RepoRoot $linked -WithWarningGit
                $res.Line | Should -Be 'RESULT:False'

                # ...and Get-MainWorktree, asked from inside that linked worktree, must point
                # back at the main one rather than at itself.
                $res2 = Invoke-CoreCall -Sandbox $sb -Call 'Get-MainWorktree' -RepoRoot $linked -WithWarningGit
                $answer = $res2.Line.Substring('RESULT:'.Length).Trim()
                $answer.TrimEnd('\', '/') | Should -Be ((Get-Item -LiteralPath $root).FullName.TrimEnd('\', '/'))
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }

    Context 'negative controls -- the real failures must still be reported as failures' {

        It 'Get-MainWorktree throws "Not inside a git repository." for a plain directory' {
            $sb = New-Sandbox -Tag 'core-6'
            $plain = New-OutsideRepoDir
            try {
                $res = Invoke-CoreCall -Sandbox $sb -Call 'Get-MainWorktree' -RepoRoot $plain
                $res.Line | Should -Be 'ERROR:Not inside a git repository.'
                $res.ExitCode | Should -Be 1
            } finally {
                Remove-OutsideRepoDir -Dir $plain
                Remove-Sandbox -Dir $sb
            }
        }

        It 'the same plain directory is reported as not-a-repo under the warning git too' {
            # The fix must not have bought warning-tolerance by making the check unreachable.
            $sb = New-Sandbox -Tag 'core-7'
            $plain = New-OutsideRepoDir
            try {
                $res = Invoke-CoreCall -Sandbox $sb -Call 'Get-MainWorktree' -RepoRoot $plain -WithWarningGit
                $res.Line | Should -Be 'ERROR:Not inside a git repository.'
                $res.ExitCode | Should -Be 1

                $res2 = Invoke-CoreCall -Sandbox $sb -Call 'Test-IsMainWorktree' -RepoRoot $plain -WithWarningGit
                $res2.Line | Should -Be 'RESULT:False'
            } finally {
                Remove-OutsideRepoDir -Dir $plain
                Remove-Sandbox -Dir $sb
            }
        }

        It 'Probe-GitVersion reports a git that is absent from PATH' {
            $sb = New-Sandbox -Tag 'core-8'
            try {
                $harness = New-CoreHarness -Dir $sb
                $savedPath = $env:PATH
                try {
                    # System32 alone is NOT enough: cmd.exe lives there but powershell.exe lives
                    # in System32\WindowsPowerShell\v1.0, so a System32-only PATH launches
                    # nothing at all and the case would "pass" on empty output.
                    $sys32 = [System.IO.Path]::Combine($env:SystemRoot, 'System32')
                    $env:PATH = $sys32 + ';' + [System.IO.Path]::Combine($sys32, 'WindowsPowerShell', 'v1.0')
                    # Preconditions: git really is gone, powershell really is still reachable.
                    (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) | Should -BeNullOrEmpty
                    (Get-Command powershell.exe -CommandType Application -ErrorAction SilentlyContinue) | Should -Not -BeNullOrEmpty

                    $res = Invoke-PsScript -ScriptPath $harness -ScriptArgs @(
                        '-CorePath', $script:CorePs1, '-Call', 'Probe-GitVersion')
                } finally {
                    $env:PATH = $savedPath
                }
                # Named cause, not PowerShell's raw "The term 'git' is not recognized".
                (Get-HarnessLine $res.Stdout) | Should -Be 'ERROR:git CLI not available on PATH.'
                $res.ExitCode | Should -Be 1
            } finally {
                Remove-Sandbox -Dir $sb
            }
        }
    }
}
