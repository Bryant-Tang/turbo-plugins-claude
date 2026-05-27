# _Common.ps1
#
# U4-internal helper file dot-sourced by every <script>.Tests.ps1 in this directory.
# Not picked up by Run-Phase1 discovery (filter is *.Tests.ps1).
#
# Purpose: centralise PS 5.1 quirks workarounds so each .Tests.ps1 stays focused on its
# script-under-test scenarios. Specifically:
#
#   - Run-Git / Run-Git-Capture     wrap git native calls so EAP=Stop + StrictMode don't
#                                   blow up on harmless git stderr ("Switched to branch ...").
#   - Invoke-PsScript               run a script-under-test as a child powershell.exe via
#                                   cmd.exe /c with explicit stdout/stderr redirect to
#                                   tempfiles — bypasses pipeline ErrorRecord wrapping that
#                                   PS 5.1 imposes on native-tool stderr.
#   - New-Sandbox / Remove-Sandbox  isolated per-case work dir under C:\Turbo (avoid TEMP
#                                   short-name bugs).
#   - New-GitMainRepo               git init + initial commit + optional .worktrees/ skeleton
#                                   + optional remote-main worktree (covers most scripts'
#                                   precondition).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Git wrappers ────────────────────────────────────────────────────────────

function Run-Git {
    param([string]$Cwd, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        if ([string]::IsNullOrWhiteSpace($Cwd)) {
            & git @GitArgs 2>&1 | Out-Null
        } else {
            & git -C $Cwd @GitArgs 2>&1 | Out-Null
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    return $LASTEXITCODE
}

function Run-Git-Capture {
    param([string]$Cwd, [string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        if ([string]::IsNullOrWhiteSpace($Cwd)) {
            $out = & git @GitArgs 2>$null
        } else {
            $out = & git -C $Cwd @GitArgs 2>$null
        }
    } finally {
        $ErrorActionPreference = $prev
    }
    return ($out | Out-String).Trim()
}

# ─── Sandbox helpers ────────────────────────────────────────────────────────

function New-Sandbox {
    param([string]$Tag = 'sandbox')
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $sb = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-$Tag-$stamp")
    $null = New-Item -ItemType Directory -Path $sb -Force
    return $sb
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

# ─── Workspace bootstrap (git init + branches + linked worktrees) ───────────

function New-GitMainRepo {
    param(
        [string]$Root,
        [switch]$CreateWorktreesDir,
        [switch]$CreateRemoteMain
    )
    $null = New-Item -ItemType Directory -Path $Root -Force
    $null = Run-Git -Cwd $Root -GitArgs @('init', '-b', 'main')
    $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.email', 'test@turbo-plugin')
    $null = Run-Git -Cwd $Root -GitArgs @('config', 'user.name',  'turbo-plugin-test')
    [System.IO.File]::WriteAllText([System.IO.Path]::Combine($Root, 'init.txt'), 'init')
    $null = Run-Git -Cwd $Root -GitArgs @('add', '-A')
    $null = Run-Git -Cwd $Root -GitArgs @('commit', '-m', 'initial', '--allow-empty')
    if ($CreateWorktreesDir) {
        $wt = [System.IO.Path]::Combine(
            [System.IO.Path]::GetDirectoryName($Root),
            "$([System.IO.Path]::GetFileName($Root)).worktrees")
        $null = New-Item -ItemType Directory -Path $wt -Force
        if ($CreateRemoteMain) {
            $remoteMain = [System.IO.Path]::Combine($wt, 'remote-main')
            $null = Run-Git -Cwd $Root -GitArgs @('branch', 'remote/main', 'main')
            $null = Run-Git -Cwd $Root -GitArgs @('worktree', 'add', $remoteMain, 'remote/main')
        }
    }
}

# ─── Invoke a script-under-test as child powershell.exe ─────────────────────

function Invoke-PsScript {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string]$Cwd,
        [string[]]$ScriptArgs
    )
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) {
        Push-Location $Cwd
    }
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 10)
    $outFile = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-stdout-$stamp.txt")
    $errFile = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-stderr-$stamp.txt")
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $argsQuoted = if ($ScriptArgs) {
            ($ScriptArgs | ForEach-Object {
                '"' + ($_ -replace '"', '""') + '"'
            }) -join ' '
        } else { '' }
        $psCmd = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $argsQuoted"
        $cmdLine = "$psCmd > `"$outFile`" 2> `"$errFile`""
        & cmd.exe /c $cmdLine
        $rc = $LASTEXITCODE
        $stdoutText = if ([System.IO.File]::Exists($outFile)) { [System.IO.File]::ReadAllText($outFile, [System.Text.Encoding]::UTF8) } else { '' }
        $stderrText = if ([System.IO.File]::Exists($errFile)) { [System.IO.File]::ReadAllText($errFile, [System.Text.Encoding]::UTF8) } else { '' }
        return [PSCustomObject]@{
            ExitCode = $rc
            Stdout   = $stdoutText
            Stderr   = $stderrText
            Combined = "$stdoutText`n$stderrText"
        }
    } finally {
        if ([System.IO.File]::Exists($outFile)) { try { [System.IO.File]::Delete($outFile) } catch {} }
        if ([System.IO.File]::Exists($errFile)) { try { [System.IO.File]::Delete($errFile) } catch {} }
        $ErrorActionPreference = $prev
        if (-not [string]::IsNullOrWhiteSpace($Cwd)) { Pop-Location }
    }
}
