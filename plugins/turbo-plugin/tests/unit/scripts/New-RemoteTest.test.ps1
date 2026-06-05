# New-RemoteTest.test.ps1
#
# Hand-rolled tests for plugins/turbo-plugin/scripts/New-RemoteTest.ps1.
#
# Scope:
#   - missing arg:  -SvnUrl required → script throws.
#   - worktrees dir missing → script throws (early fail before any git mutation).
#   - URL trust validation (U2 / R1): malicious / out-of-trust-root URLs are REJECTED
#     before ANY git mutation or svn sink — no branch created, no worktree, no rollback.
#   - prefix-confusion (R10): <repos-root>-evil/... rejected.
#   - legitimate sibling branch URL (<repos-root>/branches/test-N) → passes trust check
#     (does not regress; proves trust base is repos-root, not trunk url).
#   - remote-main absent / not a working copy → fail-closed BEFORE any side effect.
#   - rollback regression (R8 / 002:U17.5): pre-create remote/test-<n> so the FIRST git
#     mutation inside the rollback try (`git branch remote/test-N`) fails → assert the
#     rollback trap actually fired (partial git state cleaned up), not a mere rejection.
#
# The trust-validation cases require remote-main to be a real svn working copy, so we
# build a throwaway svn repo from the seed dump and check out trunk into remote-main.
# Cases that need NO svn (missing-arg, worktrees-missing, fail-closed, rollback) use the
# plain git sandbox and do not depend on svn.exe.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$libDir = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib'))
. ([System.IO.Path]::Combine($libDir, 'AssertHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'lib', 'ScriptsCommon.ps1'))
Reset-Counters

$pluginRoot      = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
$scriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'New-RemoteTest.ps1')
$dumpPath        = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', 'fixtures', 'seed', 'svn-repo-r1-r20.dump'))

if (-not [System.IO.File]::Exists($scriptUnderTest)) {
    Write-Output "[FAIL] New-RemoteTest.ps1 not found at $scriptUnderTest"
    exit 1
}

function Get-WorktreesDir {
    # v1.0 (U1): container moved inside the main worktree at <Root>/.turbo-plugin/worktrees
    # (mirrors the production Get-WorktreesDir in scripts/lib/Common.ps1).
    param([string]$Root)
    return [System.IO.Path]::Combine($Root, '.turbo-plugin', 'worktrees')
}

# Build a throwaway svn repo (from the seed dump) and check out trunk into
# <worktreesDir>/remote-main so it becomes a valid trusted working copy. Returns the
# repos-root-url, or $null if svn/svnadmin/load/checkout couldn't be set up.
function Initialize-RemoteMainWc {
    param([string]$Root, [string]$Sandbox)
    $worktreesDir = Get-WorktreesDir -Root $Root
    $svnRepo = [System.IO.Path]::Combine($Sandbox, 'svnrepo')

    & svnadmin create $svnRepo
    if ($LASTEXITCODE -ne 0) { return $null }

    $loadCmd = "svnadmin load `"$svnRepo`" < `"$dumpPath`""
    & cmd.exe /c $loadCmd > $null 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }

    $repoUri = 'file:///' + ($svnRepo -replace '\\', '/')
    $remoteMain = [System.IO.Path]::Combine($worktreesDir, 'remote-main')
    & svn checkout "$repoUri/trunk" $remoteMain > $null 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }

    $reposRoot = (& svn info --show-item repos-root-url $remoteMain 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($reposRoot)) { return $null }
    return $reposRoot
}

# Assert no partial git state (branches / worktree dir) for the given index remains.
function Assert-NoOrphanState {
    param([string]$Root, [int]$Idx, [string]$Label)
    $remoteBranchListing = Run-Git-Capture -Cwd $Root -GitArgs @('branch', '--list', "remote/test-$Idx")
    $testBranchListing   = Run-Git-Capture -Cwd $Root -GitArgs @('branch', '--list', "test-$Idx")
    Assert-Equal -Name "$Label : no orphan remote/test-$Idx branch" -Expected '' -Actual $remoteBranchListing
    Assert-Equal -Name "$Label : no orphan test-$Idx branch" -Expected '' -Actual $testBranchListing
    $worktreesDir = Get-WorktreesDir -Root $Root
    $remoteWtPath = [System.IO.Path]::Combine($worktreesDir, "remote-test-$Idx")
    Assert-True -Name "$Label : no orphan remote-test-$Idx worktree dir" `
                -Condition (-not [System.IO.Directory]::Exists($remoteWtPath))
}

$svnAvailable = $false
try {
    $null = (& svn --version --quiet 2>$null)
    $svnAvailable = ($LASTEXITCODE -eq 0)
} catch {
    $svnAvailable = $false
}

# ─── Case 1: missing -SvnUrl ─────────────────────────────────────────────────

Write-Output ''
Write-Output 'Case 1: missing -SvnUrl → required-arg error'
$sb1 = New-Sandbox -Tag 'crt-1'
try {
    $root = [System.IO.Path]::Combine($sb1, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root -ScriptArgs @()
    Assert-True -Name 'exit != 0' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions SvnUrl required' -Pattern '-SvnUrl' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb1
}

# ─── Case 2: worktrees dir does not exist ────────────────────────────────────

Write-Output ''
Write-Output 'Case 2: worktrees dir missing → "Run /tp-setup first" error'
$sb2 = New-Sandbox -Tag 'crt-2'
try {
    $root = [System.IO.Path]::Combine($sb2, 'test-turbo-plugin')
    New-GitMainRepo -Root $root  # NO -CreateWorktreesDir → .worktrees/ absent at parent

    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                           -ScriptArgs @('-SvnUrl', 'file:///C:/Turbo/no-such-repo/branches/test-1')
    Assert-True -Name 'exit != 0 (worktrees dir missing)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions Worktrees directory not found' `
                 -Pattern 'Worktrees directory not found' -InputText $res.Combined
} finally {
    Remove-Sandbox -Dir $sb2
}

# ─── Case 3: remote-main absent / not a WC → fail-closed BEFORE any side effect ──
#
# Retargeted from the old "bogus file:// URL → rollback" case. With U2 validation in
# place, the trust check now runs BEFORE the rollback try. remote-main does NOT exist
# here (only the worktrees dir), so Assert-TrustedSvnUrl fails closed (can't read
# repos-root-url) and the script exits with NO branch / worktree created and WITHOUT
# entering rollback. This proves rejection happens before side effects — it is NOT a
# rollback case (rollback regression is Case 8 below).

Write-Output ''
Write-Output 'Case 3: remote-main absent → fail-closed, no side effects, no rollback'
$sb3 = New-Sandbox -Tag 'crt-3'
try {
    $root = [System.IO.Path]::Combine($sb3, 'test-turbo-plugin')
    New-GitMainRepo -Root $root -CreateWorktreesDir   # worktrees dir exists, but NO remote-main
    $url = 'file:///C:/Turbo/no-such-repo/branches/test-99'
    $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                           -ScriptArgs @('-N', '99', '-SvnUrl', $url)
    Assert-True -Name 'exit != 0 (fail-closed: remote-main absent)' -Condition ($res.ExitCode -ne 0)
    Assert-Match -Name 'stderr mentions fail closed / repos-root-url' `
                 -Pattern '(fail closed|repos-root-url)' -InputText $res.Combined
    # Must NOT have rolled back (because it never started) — and must NOT show "Creating".
    Assert-True -Name 'never printed "Creating test environment" (rejected pre-side-effect)' `
                -Condition (-not ($res.Combined -match 'Creating test environment'))
    Assert-True -Name 'never entered rollback (no "rolling back" message)' `
                -Condition (-not ($res.Combined -match 'rolling back'))
    Assert-NoOrphanState -Root $root -Idx 99 -Label 'fail-closed'
} finally {
    Remove-Sandbox -Dir $sb3
}

# ─── Case 4-6: malicious / out-of-trust URLs rejected (need valid remote-main WC) ──
#
# Covers 002:U17.4b. file:///C:/Windows/System32/  → reject, no side effect, no rollback
# Covers 002:U17.4b. http://attacker.example/repo  → reject, no side effect
# Covers R10.        <repos-root>-evil/branches/test-1 (prefix-confusion) → reject

if (-not $svnAvailable) {
    Write-Output ''
    Write-Output '  [SKIP] svn not on PATH — trust-validation reject/legit cases skipped.'
} elseif (-not [System.IO.File]::Exists($dumpPath)) {
    Write-Output ''
    Write-Output "  [SKIP] seed dump missing at $dumpPath — run Build-SeedRepo.ps1."
} else {
    Write-Output ''
    Write-Output 'Case 4: file:///C:/Windows/System32/ → reject, no side effect (002:U17.4b)'
    $sb4 = New-Sandbox -Tag 'crt-4'
    try {
        $root = [System.IO.Path]::Combine($sb4, 'test-turbo-plugin')
        New-GitMainRepo -Root $root -CreateWorktreesDir
        $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb4
        if ($null -eq $reposRoot) {
            Write-Output '  [SKIP] could not build remote-main svn WC (svnadmin load/checkout failed).'
        } else {
            $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                                   -ScriptArgs @('-N', '4', '-SvnUrl', 'file:///C:/Windows/System32/')
            Assert-True -Name 'exit != 0 (out-of-trust file:// rejected)' -Condition ($res.ExitCode -ne 0)
            Assert-True -Name 'rejected before side effects (no "Creating")' `
                        -Condition (-not ($res.Combined -match 'Creating test environment'))
            Assert-True -Name 'no rollback fired (rejection, not rollback)' `
                        -Condition (-not ($res.Combined -match 'rolling back'))
            Assert-NoOrphanState -Root $root -Idx 4 -Label 'reject file://'
        }
    } finally {
        Remove-Sandbox -Dir $sb4
    }

    Write-Output ''
    Write-Output 'Case 5: http://attacker.example/repo → reject, no side effect (002:U17.4b)'
    $sb5 = New-Sandbox -Tag 'crt-5'
    try {
        $root = [System.IO.Path]::Combine($sb5, 'test-turbo-plugin')
        New-GitMainRepo -Root $root -CreateWorktreesDir
        $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb5
        if ($null -eq $reposRoot) {
            Write-Output '  [SKIP] could not build remote-main svn WC.'
        } else {
            $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                                   -ScriptArgs @('-N', '5', '-SvnUrl', 'http://attacker.example/repo')
            Assert-True -Name 'exit != 0 (different scheme/host rejected)' -Condition ($res.ExitCode -ne 0)
            Assert-True -Name 'rejected before side effects (no "Creating")' `
                        -Condition (-not ($res.Combined -match 'Creating test environment'))
            Assert-NoOrphanState -Root $root -Idx 5 -Label 'reject http'
        }
    } finally {
        Remove-Sandbox -Dir $sb5
    }

    Write-Output ''
    Write-Output 'Case 6: <repos-root>-evil/branches/test-1 → reject (R10 prefix-confusion)'
    $sb6 = New-Sandbox -Tag 'crt-6'
    try {
        $root = [System.IO.Path]::Combine($sb6, 'test-turbo-plugin')
        New-GitMainRepo -Root $root -CreateWorktreesDir
        $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb6
        if ($null -eq $reposRoot) {
            Write-Output '  [SKIP] could not build remote-main svn WC.'
        } else {
            $evilUrl = "$reposRoot-evil/branches/test-1"
            $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                                   -ScriptArgs @('-N', '6', '-SvnUrl', $evilUrl)
            Assert-True -Name 'exit != 0 (prefix-confusion rejected)' -Condition ($res.ExitCode -ne 0)
            Assert-True -Name 'rejected before side effects (no "Creating")' `
                        -Condition (-not ($res.Combined -match 'Creating test environment'))
            Assert-NoOrphanState -Root $root -Idx 6 -Label 'reject evil-prefix'
        }
    } finally {
        Remove-Sandbox -Dir $sb6
    }

    # ─── Case 7: legitimate sibling branch URL passes the trust check (no regression) ──
    #
    # Covers: a URL under the trusted repos-root (branches/test-N) must NOT be rejected by
    # the new validation. We can't run the full svn copy/checkout happy path hermetically
    # here, but we PROVE the trust gate accepts it: the script gets past the gate (prints
    # "Creating test environment", creates the git branches/worktree) and only fails later
    # on a downstream svn step. The key assertion is "got past trust gate" + the failure is
    # NOT a trust rejection. (Downstream svn failure correctly rolls back — observed.)

    Write-Output ''
    Write-Output 'Case 7: legit sibling <repos-root>/branches/test-7 → passes trust gate (no regression)'
    $sb7 = New-Sandbox -Tag 'crt-7'
    try {
        $root = [System.IO.Path]::Combine($sb7, 'test-turbo-plugin')
        New-GitMainRepo -Root $root -CreateWorktreesDir
        $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb7
        if ($null -eq $reposRoot) {
            Write-Output '  [SKIP] could not build remote-main svn WC.'
        } else {
            $legitUrl = "$reposRoot/branches/test-7"
            $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                                   -ScriptArgs @('-N', '7', '-SvnUrl', $legitUrl)
            # Trust gate accepted it → script proceeded past the gate.
            Assert-True -Name 'trust gate accepted legit sibling URL (got to "Creating")' `
                        -Condition ($res.Combined -match 'Creating test environment')
            # And whatever happens after, it was NOT a trust rejection.
            Assert-True -Name 'failure (if any) is NOT a trust rejection' `
                        -Condition (-not ($res.Combined -match 'Untrusted SVN URL'))
        }
    } finally {
        Remove-Sandbox -Dir $sb7
    }
}

# ─── Case 8: rollback regression — git mutation failure triggers rollback (R8 / 002:U17.5) ──
#
# Pre-create remote/test-<n> so the FIRST git mutation inside the rollback try
# (`git branch remote/test-N`) fails. This needs a VALID trusted URL to get past the
# new trust gate first; we use a real remote-main WC and a legit sibling branch URL.
# We assert the rollback actually executed: the script must print the rollback message
# AND any partially-created state (the test-N branch / worktree) must be cleaned up —
# NOT merely a non-zero exit, and NOT a trust rejection.

if (-not $svnAvailable -or -not [System.IO.File]::Exists($dumpPath)) {
    Write-Output ''
    Write-Output '  [SKIP] Case 8 rollback regression needs svn + seed dump.'
} else {
    Write-Output ''
    Write-Output 'Case 8: pre-existing remote/test-8 collision → git branch fails → rollback fires (R8)'
    $sb8 = New-Sandbox -Tag 'crt-8'
    try {
        $root = [System.IO.Path]::Combine($sb8, 'test-turbo-plugin')
        New-GitMainRepo -Root $root -CreateWorktreesDir
        $reposRoot = Initialize-RemoteMainWc -Root $root -Sandbox $sb8
        if ($null -eq $reposRoot) {
            Write-Output '  [SKIP] could not build remote-main svn WC.'
        } else {
            # Pre-create remote/test-8 so the inner `git branch remote/test-8` fails.
            # NOTE: we collide remote/test-8 (the FIRST inner mutation), NOT test-8 —
            # test-8 is caught by the try-OUTSIDE pre-check and would never reach rollback.
            $null = Run-Git -Cwd $root -GitArgs @('branch', 'remote/test-8', 'main')

            $legitUrl = "$reposRoot/branches/test-8"
            $res = Invoke-PsScript -ScriptPath $scriptUnderTest -Cwd $root `
                                   -ScriptArgs @('-N', '8', '-SvnUrl', $legitUrl)

            Assert-True -Name 'exit != 0 (collision → failure)' -Condition ($res.ExitCode -ne 0)
            # Proves we passed the trust gate and entered the rollback try.
            Assert-True -Name 'trust gate accepted (got to "Creating")' `
                        -Condition ($res.Combined -match 'Creating test environment')
            Assert-True -Name 'rollback actually executed (saw "rolling back")' `
                        -Condition ($res.Combined -match 'rolling back')
            Assert-True -Name 'NOT a trust rejection' `
                        -Condition (-not ($res.Combined -match 'Untrusted SVN URL'))
            # The pre-existing remote/test-8 we created must survive (rollback -D only
            # removes what THIS run created; but the failing `git branch` did not create
            # it). The test-8 branch must NOT have been left behind, and no worktree dir.
            $testBranchListing = Run-Git-Capture -Cwd $root -GitArgs @('branch', '--list', 'test-8')
            Assert-Equal -Name 'rollback removed partial test-8 branch' -Expected '' -Actual $testBranchListing
            $worktreesDir = Get-WorktreesDir -Root $root
            $remoteWtPath = [System.IO.Path]::Combine($worktreesDir, 'remote-test-8')
            Assert-True -Name 'rollback removed partial remote-test-8 worktree dir' `
                        -Condition (-not [System.IO.Directory]::Exists($remoteWtPath))
        }
    } finally {
        Remove-Sandbox -Dir $sb8
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────

Write-Output ''
Write-Output '─────────────────────────────────────────────────────────────────────'
$sum = Get-CounterSummary
Write-Output "New-RemoteTest: passed=$($sum.Passed) failed=$($sum.Failed)"
if ($sum.Failed -gt 0) {
    Write-Output ''
    Write-Output 'Failures:'
    foreach ($f in $sum.Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
