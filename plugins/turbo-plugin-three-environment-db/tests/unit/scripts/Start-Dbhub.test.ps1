# Start-Dbhub.test.ps1 (Pester 5)
#
# Script under test: scripts/Start-Dbhub.ps1 -- the PowerShell sibling of the launcher `.mcp.json`
# runs for the tp-dbhub server. Everything is asserted through -PrintCommand, so no container is
# ever started.
#
# The two defects this locks down (real machine, 2026-07-31):
#   #13 `docker run -v <missing path>` CREATES a directory, so every folder a session opened in
#       collected a stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY. It then blocked
#       its own fix (no file of that name can be created) and dbhub got a directory as its config.
#   #14 `${CLAUDE_PROJECT_DIR}` is the session root, so in a multi-project workspace the config --
#       which lives inside a project -- was never found.
#
# Resolution order under test (D1): root config wins > exactly one project match > ambiguous stops
# > nothing found stops. Every stop must exit 0 (a non-zero exit shows up as a crashed MCP server)
# and must leave the filesystem untouched.

# Computed HERE, at DISCOVERY time, not in BeforeAll. Pester 5 evaluates `-Skip:` while it is
# discovering tests, which happens before any BeforeAll body runs -- a flag set in BeforeAll reads
# back as $null there, `-not $null` is $true, and every case silently SKIPs on a machine that can
# run them perfectly well. (Observed: 7/7 skipped on Windows.)
$script:HasWindowsPowerShell = $null -ne (Get-Command powershell.exe -ErrorAction SilentlyContinue)

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Start-Dbhub.ps1')

    function New-Workspace {
        # GetTempPath(), not $env:TEMP: TEMP is unset under pwsh on Linux, which would make the
        # path relative and drop the sandbox inside the repo.
        $dir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "turbo-dbhub-$([Guid]::NewGuid().ToString('N').Substring(0,12))")
        $null = New-Item -ItemType Directory -Path $dir -Force
        return $dir
    }

    function Remove-Workspace {
        param([string]$Dir)
        if ([string]::IsNullOrWhiteSpace($Dir)) { return }
        try { if ([System.IO.Directory]::Exists($Dir)) { [System.IO.Directory]::Delete($Dir, $true) } } catch { }
    }

    function Add-DbConfig {
        param([string]$Owner)
        $tp = [System.IO.Path]::Combine($Owner, '.turbo-plugin')
        $null = New-Item -ItemType Directory -Path $tp -Force
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tp, 'dbhub.local.toml'), "dsn = `"sqlserver://example`"`n")
    }

    function Invoke-Launcher {
        param([string[]]$ScriptArgs)
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-dbh-out-$([Guid]::NewGuid().ToString('N')).txt")
        $errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-dbh-err-$([Guid]::NewGuid().ToString('N')).txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $script:ScriptUnderTest + '"')) +
                       @($ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                                  -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                                  -NoNewWindow -PassThru -Wait
            $out = if (Test-Path -LiteralPath $outFile -PathType Leaf) { [System.IO.File]::ReadAllText($outFile) } else { '' }
            $err = if (Test-Path -LiteralPath $errFile -PathType Leaf) { [System.IO.File]::ReadAllText($errFile) } else { '' }
            return @{ Stdout = $out; Stderr = $err; Combined = ($out + "`n" + $err); Exit = $proc.ExitCode }
        } finally {
            foreach ($f in @($outFile, $errFile)) {
                if (Test-Path -LiteralPath $f -PathType Leaf) { try { [System.IO.File]::Delete($f) } catch { } }
            }
        }
    }
}

Describe 'Start-Dbhub' {

    It 'script-under-test exists' {
        Test-Path -LiteralPath $script:ScriptUnderTest -PathType Leaf | Should -BeTrue
    }

    It 'nothing configured: explains where it looked, exits 0, creates nothing' -Skip:(-not $script:HasWindowsPowerShell) {
        $ws = New-Workspace
        try {
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Exit | Should -Be 0 -Because 'a non-zero exit is reported to the user as a crashed MCP server'
            $r.Combined | Should -Match 'no database config found'
            $r.Stdout | Should -Not -Match 'docker'
            # The #13 regression: no bind mount was attempted, so nothing was created.
            (Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin'))) | Should -BeFalse
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'finds a config one level down (the multi-project workspace case)' -Skip:(-not $script:HasWindowsPowerShell) {
        $ws = New-Workspace
        try {
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'proj-1'))
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Exit | Should -Be 0
            $r.Stdout | Should -Match 'proj-1'
            $r.Stdout | Should -Match ':/dbhub.toml'
            $r.Stdout | Should -Match 'bytebase/dbhub:latest'
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'stops and lists when several projects have a config' -Skip:(-not $script:HasWindowsPowerShell) {
        $ws = New-Workspace
        try {
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'proj-1'))
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'proj-2'))
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Exit | Should -Be 0
            $r.Combined | Should -Match 'ambiguous'
            $r.Combined | Should -Match 'proj-1'
            $r.Combined | Should -Match 'proj-2'
            $r.Stdout | Should -Not -Match 'docker'
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'a workspace-root config wins outright (that is how the user settles the ambiguity)' -Skip:(-not $script:HasWindowsPowerShell) {
        $ws = New-Workspace
        try {
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'proj-1'))
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'proj-2'))
            Add-DbConfig -Owner $ws
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Exit | Should -Be 0
            $r.Combined | Should -Not -Match 'ambiguous'
            $r.Stdout | Should -Not -Match 'proj-'
            $r.Stdout | Should -Match 'dbhub\.local\.toml'
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'a DIRECTORY named like the config is not treated as one' -Skip:(-not $script:HasWindowsPowerShell) {
        # Exactly the state #13 left behind; mounting it would hand dbhub a directory.
        $ws = New-Workspace
        try {
            $null = New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'dbhub.local.toml')) -Force
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Exit | Should -Be 0
            $r.Combined | Should -Match 'no database config found'
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'does not search deeper than one level' -Skip:(-not $script:HasWindowsPowerShell) {
        # Which database you connect to must not depend on how far down someone buried a file.
        $ws = New-Workspace
        try {
            Add-DbConfig -Owner ([System.IO.Path]::Combine($ws, 'group', 'proj-1'))
            $r = Invoke-Launcher -ScriptArgs @('-SessionRoot', $ws, '-PrintCommand')
            $r.Combined | Should -Match 'no database config found'
        } finally { Remove-Workspace -Dir $ws }
    }

    It 'a missing or bad session root stops cleanly' -Skip:(-not $script:HasWindowsPowerShell) {
        $ws = New-Workspace
        try {
            $r = Invoke-Launcher -ScriptArgs @('-PrintCommand')
            $r.Exit | Should -Be 0
            $r.Combined | Should -Match 'session root'

            $r2 = Invoke-Launcher -ScriptArgs @('-SessionRoot', ([System.IO.Path]::Combine($ws, 'does-not-exist')), '-PrintCommand')
            $r2.Exit | Should -Be 0
            $r2.Combined | Should -Match 'not a directory'
        } finally { Remove-Workspace -Dir $ws }
    }
}
