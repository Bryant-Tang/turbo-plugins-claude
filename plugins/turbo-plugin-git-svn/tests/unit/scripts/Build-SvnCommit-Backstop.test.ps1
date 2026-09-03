# Build-SvnCommit-Backstop.test.ps1 (Pester 5)
#
# Script: plugins/turbo-plugin-git-svn/scripts/Build-SvnCommit.ps1
#
# Covers ONLY the branch-mismatch backstop (issue #161): the predicate is "the requested branch
# is checked out in NO worktree at all", not "the main worktree is on something else". It has to
# match the pre-flight gate exactly, or the two disagree on the same question.
#
# A separate file from Build-SvnCommit.test.ps1 on purpose: these cases build their OWN sandbox
# (the point is the worktree LAYOUT -- a branch held by a linked worktree vs. one nobody holds),
# while that file drives the shared fixture the orchestrator resets. Keeping them apart means
# neither one's setup can mask the other's failures.

# Skip conditions must be resolved at DISCOVERY time (Pester 5): a flag set in BeforeAll is
# $null during discovery, which would silently skip everything while still reporting green.
BeforeDiscovery {
    $hasGit = [bool](Get-Command git -ErrorAction SilentlyContinue)
}

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Build-SvnCommit.ps1')
    $script:SandboxBase = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')
    $null = New-Item -ItemType Directory -Path $script:SandboxBase -Force

    # PS 5.1 + EAP=Stop bites on git's stderr warnings, so fixture git calls are silenced and
    # their outcome is asserted separately rather than inferred from the absence of noise.
    #
    # The parameter is -Dir, NOT -Cwd, and that is load-bearing: PowerShell resolves parameter
    # names by PREFIX, so a pass-through `-c commit.gpgsign=false` binds to a parameter named
    # -Cwd instead of landing in $args. The commit then runs as
    # `git -C commit.gpgsign=false commit ...`, fails, and -- because this helper swallows output
    # -- the fixture ends up with no commit at all while still looking like it worked.
    function Invoke-BsGit {
        param([string]$Dir)
        $rest = $args
        $oldEap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & git -C $Dir @rest 2>$null | Out-Null } catch { } finally { $ErrorActionPreference = $oldEap }
    }

    function New-BackstopSandbox {
        $sb = [System.IO.Path]::Combine($script:SandboxBase, "bsc-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
        $dir = [System.IO.Path]::Combine($sb, 'proj')
        $null = New-Item -ItemType Directory -Path $dir -Force
        Invoke-BsGit $dir init -q -b main
        Invoke-BsGit $dir config user.email 'test@example.invalid'
        Invoke-BsGit $dir config user.name 'Test'
        Set-Content -LiteralPath ([System.IO.Path]::Combine($dir, 'a.txt')) -Value 'x'
        Invoke-BsGit $dir add -A
        Invoke-BsGit $dir -c commit.gpgsign=false commit -q -m 'init'
        # Prove the seed commit exists. A repo with no commit is exactly what a swallowed git
        # failure produces here, and every assertion downstream would then mean nothing.
        $null = (& git -C $dir rev-parse --abbrev-ref HEAD 2>$null)
        if ($LASTEXITCODE -ne 0) { throw "fixture: '$dir' has no commit -- the seed git calls failed" }
        return $sb
    }

    # The script refuses before the backstop unless the bridge worktree exists.
    function Add-BsBridge {
        param([string]$Dir, [string]$Branch, [string]$Name)
        $path = [System.IO.Path]::Combine($Dir, '.turbo-plugin', 'worktrees', "remote-svn-$Name")
        Invoke-BsGit $Dir worktree add -q -b "remote-svn/$Branch" $path
        if (-not (Test-Path -LiteralPath ([System.IO.Path]::Combine($path, '.git')))) {
            throw "fixture: '$path' is not a linked worktree -- git worktree add failed silently"
        }
    }

    # Only the token line is read. The script legitimately goes on to svn-side work afterwards
    # and fails there in this sandbox (the bridge is a git worktree, not an svn working copy),
    # which says nothing about the gate under test.
    #
    # EAP=Continue around the child, and NO `2>` redirection: under EAP=Stop, PS 5.1 turns a
    # native command's stderr into a TERMINATING error, which would kill the case after the
    # token we came to read had already been printed.
    function Get-BsToken {
        param([string]$Dir, [string]$Branch)
        $oldEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $script:ScriptUnderTest -Branch $Branch -RepoRoot $Dir
        } catch {
            $out = @()
        } finally {
            $ErrorActionPreference = $oldEap
        }
        $text = (($out | Out-String) -replace "`r", '')
        return (@(($text -split "`n") | Where-Object { $_ -like 'TP_TOKEN:*' }) -join "`n")
    }
}

Describe 'Build-SvnCommit branch-mismatch backstop' {

    # Under a worktree workflow the old form ("is the main worktree on it") fired on every push
    # and named the wrong branch while doing it, because git forbids the main worktree from
    # holding a branch a linked worktree already has.
    It 'stays silent while a LINKED worktree holds the branch' -Skip:(-not $hasGit) {
        $sb = New-BackstopSandbox
        try {
            $dir = [System.IO.Path]::Combine($sb, 'proj')
            $wt = [System.IO.Path]::Combine($sb, 'wt-feat-x')
            Invoke-BsGit $dir worktree add -q -b feat-x $wt
            # Guard the fixture: a silently failed `worktree add` leaves nothing holding feat-x,
            # which is exactly the state the OLD code produced -- the case would then pass for
            # the wrong reason and assert nothing.
            (& git -C $wt rev-parse --abbrev-ref HEAD).Trim() | Should -Be 'feat-x'
            Add-BsBridge -Dir $dir -Branch 'feat-x' -Name 'feat-x'

            (Get-BsToken -Dir $dir -Branch 'feat-x') | Should -Not -BeLike '*BRANCH_MISMATCH_WARNING*'
        } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # The other direction, so the case above cannot pass by the backstop having gone silent for
    # good. The branch EXISTS here -- the question is checkout, not existence.
    It 'still warns for a branch no worktree holds' -Skip:(-not $hasGit) {
        $sb = New-BackstopSandbox
        try {
            $dir = [System.IO.Path]::Combine($sb, 'proj')
            Invoke-BsGit $dir branch feat-parked
            Add-BsBridge -Dir $dir -Branch 'feat-parked' -Name 'feat-parked'

            (Get-BsToken -Dir $dir -Branch 'feat-parked') | Should -BeLike '*BRANCH_MISMATCH_WARNING*requested=feat-parked*'
        } finally { Remove-Item -LiteralPath $sb -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
