# Rename-DbEnvironment.test.ps1 (Pester 5)
#
# Script under test: scripts/Rename-DbEnvironment.ps1 -- the migration that renames one database
# environment folder AND rewrites the environment name inside every .sql header under it. This is
# the Windows twin of rename-db-environment.test.sh; both suites assert the same contract, which
# is how the two native implementations are kept from drifting.
#
# Why the header rewrite is part of the contract: a .sql file records which environment it targets
# and, for a _modules/ baseline, which environment the baseline came from. Rename only the folder
# and every file asserts something false -- with no symptom, because the SQL still runs.
#
# NOTE on test names: no angle brackets anywhere in a name. Pester parses `<...>` in a test name as
# a -ForEach template placeholder and tries to expand it, which under StrictMode blows up the whole
# Context in BeforeAll with empty per-test error records.

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'Rename-DbEnvironment.ps1')

    function New-Workspace {
        # GetTempPath(), not $env:TEMP: TEMP is unset under pwsh on Linux, which would make the
        # path relative and drop the sandbox inside the repo. Short name on purpose -- a long one
        # plus the nested _modules path runs into MAX_PATH on Windows.
        $dir = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-ren-$([Guid]::NewGuid().ToString('N').Substring(0,8))")
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        return $dir
    }

    # A workspace with one one-off script and one _modules baseline, both carrying the environment
    # name in their header.
    function Add-SqlTree {
        param([string]$Workspace, [string]$EnvName)
        $feat = [System.IO.Path]::Combine($Workspace, '.turbo-plugin', 'sql', $EnvName, 'feat-x')
        $mods = [System.IO.Path]::Combine($Workspace, '.turbo-plugin', 'sql', $EnvName, '_modules', 'AppDb', 'Procedures')
        New-Item -ItemType Directory -Path $feat -Force | Out-Null
        New-Item -ItemType Directory -Path $mods -Force | Out-Null

        $oneOff = "/*`n目標環境: $EnvName`n- <sql_root>/$EnvName/feat-x/01.sql`n*/`nSELECT 1;`n"
        $module = "/*`n目標環境: $EnvName`n基線來源環境: $EnvName`n*/`nCREATE OR ALTER PROCEDURE dbo.X AS BEGIN SET NOCOUNT ON; END;`n"
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($feat, '01-AppDb-fill.sql'), $oneOff, $enc)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($mods, 'dbo.X.sql'), $module, $enc)
    }

    function Add-Config {
        param([string]$Workspace, [string]$EnvironmentsBody)
        $dir = [System.IO.Path]::Combine($Workspace, '.turbo-plugin')
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $body = "# >>> turbo-plugin:db >>>`n[db]`n# environments = [`"commented-local-db`"]`nenvironments = $EnvironmentsBody`n# <<< turbo-plugin:db <<<`n"
        $enc = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText([System.IO.Path]::Combine($dir, 'config.toml'), $body, $enc)
    }

    # Redirect to files rather than `2>&1`: on 5.1 that operator wraps a native exe's stderr in a
    # NativeCommandError, which under EAP=Stop throws and makes $LASTEXITCODE unreachable -- the
    # exact thing lint-ps-compat rule 4 exists to prevent. Stdout and stderr are read back
    # separately and joined here.
    function Invoke-Rename {
        param([string[]]$ScriptArgs)
        $stamp = [Guid]::NewGuid().ToString('N')
        $outFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-ren-out-$stamp.txt")
        $errFile = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "tp-ren-err-$stamp.txt")
        try {
            $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                         ('"' + $script:ScriptUnderTest + '"')) +
                       @($ScriptArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } })
            $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList `
                                  -RedirectStandardOutput $outFile -RedirectStandardError $errFile `
                                  -NoNewWindow -PassThru -Wait
            $out = if (Test-Path -LiteralPath $outFile -PathType Leaf) { [System.IO.File]::ReadAllText($outFile) } else { '' }
            $err = if (Test-Path -LiteralPath $errFile -PathType Leaf) { [System.IO.File]::ReadAllText($errFile) } else { '' }
            return @{ Stdout = ($out + "`n" + $err); ExitCode = $proc.ExitCode }
        } finally {
            foreach ($f in @($outFile, $errFile)) {
                if (Test-Path -LiteralPath $f -PathType Leaf) { try { [System.IO.File]::Delete($f) } catch { } }
            }
        }
    }
}

Describe 'Rename-DbEnvironment' {

    It 'script-under-test exists' {
        Test-Path -LiteralPath $script:ScriptUnderTest | Should -BeTrue
    }

    It 'is stored with a UTF-8 BOM so PowerShell 5.1 can read its Chinese text' {
        # Without the BOM, 5.1 on a zh-TW machine decodes the file as cp950 and the parser fails.
        $bytes = [System.IO.File]::ReadAllBytes($script:ScriptUnderTest)
        $bytes[0] | Should -Be 0xEF
        $bytes[1] | Should -Be 0xBB
        $bytes[2] | Should -Be 0xBF
    }

    It 'dry run is the default and changes nothing' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            $r = Invoke-Rename @('local-db', 'dev-db', '-Root', $ws)
            $r.ExitCode | Should -Be 0
            $r.Stdout | Should -Match 'dry run'

            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db')) | Should -BeTrue
            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'dev-db')) | Should -BeFalse

            $f = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db', 'feat-x', '01-AppDb-fill.sql')
            [System.IO.File]::ReadAllText($f) | Should -Match 'local-db'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'renames the folder and rewrites both header fields when applied' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            $r = Invoke-Rename @('local-db', 'dev-db', '-Root', $ws, '-Apply')
            $r.ExitCode | Should -Be 0

            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'dev-db')) | Should -BeTrue
            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db')) | Should -BeFalse

            # The _modules baseline carries the baseline-source field, which is the one that
            # actually protects production.
            $mod = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'dev-db', '_modules', 'AppDb', 'Procedures', 'dbo.X.sql')
            $text = [System.IO.File]::ReadAllText($mod)
            $text | Should -Match '目標環境: dev-db'
            $text | Should -Match '基線來源環境: dev-db'
            $text | Should -Not -Match 'local-db'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'does not corrupt a longer environment name that shares the prefix' {
        # A substring replace turns an existing test-db into test-db-db, silently.
        $ws = New-Workspace
        try {
            $feat = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'test', 'feat-x')
            New-Item -ItemType Directory -Path $feat -Force | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText(
                [System.IO.Path]::Combine($feat, '01.sql'),
                "目標環境: test`n- <sql_root>/test/feat-x/01.sql`n- <sql_root>/test-db/feat-x/01.sql`n",
                $enc)

            Invoke-Rename @('test', 'test-db', '-Root', $ws, '-Apply') | Out-Null

            $f = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'test-db', 'feat-x', '01.sql')
            $text = [System.IO.File]::ReadAllText($f)
            $text | Should -Match '目標環境: test-db'
            $text | Should -Not -Match 'test-db-db'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses to merge into an existing target and leaves the source alone' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            New-Item -ItemType Directory -Path ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'dev-db')) -Force | Out-Null

            $r = Invoke-Rename @('local-db', 'dev-db', '-Root', $ws, '-Apply')
            $r.ExitCode | Should -Not -Be 0
            $r.Stdout | Should -Match 'already exists'
            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db')) | Should -BeTrue
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a source environment that does not exist' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            (Invoke-Rename @('nope', 'dev-db', '-Root', $ws, '-Apply')).ExitCode | Should -Not -Be 0
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'refuses a name that is not a single folder name' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            (Invoke-Rename @('local-db', 'a/b', '-Root', $ws, '-Apply')).ExitCode | Should -Not -Be 0
            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db')) | Should -BeTrue
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'updates the live environments line and leaves the commented-out one alone' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            Add-Config -Workspace $ws -EnvironmentsBody '["local-db", "test-db", "main-db"]'

            Invoke-Rename @('local-db', 'dev-db', '-Root', $ws, '-Apply') | Out-Null

            $cfg = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($ws, '.turbo-plugin', 'config.toml'))
            $cfg | Should -Match 'environments = \["dev-db", "test-db", "main-db"\]'
            $cfg | Should -Match '# environments = \["commented-local-db"\]'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    # Two matches separated by exactly ONE character: the first match consumes that character as
    # its right boundary, so a single pass leaves the second unmatched. This is why the
    # substitution runs twice, in the file contents AND in the config line.
    #
    # `local-db/local-db` is the shape that does it -- reachable for real when sql_root itself ends
    # in the environment name, which makes the expanded path in a header read
    # `.../local-db/local-db/_modules/...`. A TOML array does NOT produce this: between
    # `"local-db","local-db"` there are three characters, so the comma still serves as the second
    # match's left boundary and one pass suffices. A fixture built that way passes against the bug.
    It 'replaces two names separated by a single character' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            $enc = New-Object System.Text.UTF8Encoding($false)
            $adjacent = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'local-db', 'feat-x', '02-adjacent.sql')
            [System.IO.File]::WriteAllText($adjacent, "檔案落點: <sql_root>/local-db/local-db/_modules/AppDb/X.sql`n", $enc)
            Add-Config -Workspace $ws -EnvironmentsBody '["local-db/local-db"]'

            Invoke-Rename @('local-db', 'dev-db', '-Root', $ws, '-Apply') | Out-Null

            $moved = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'sql', 'dev-db', 'feat-x', '02-adjacent.sql')
            $text = [System.IO.File]::ReadAllText($moved)
            $text | Should -Match 'dev-db/dev-db'
            $text | Should -Not -Match 'local-db'

            $cfgPath = [System.IO.Path]::Combine($ws, '.turbo-plugin', 'config.toml')
            [System.IO.File]::ReadAllText($cfgPath) | Should -Match 'environments = \["dev-db/dev-db"\]'

            # Exactly one mention of the old name may survive: the commented-out sample line.
            $remaining = @(@(Get-Content -LiteralPath $cfgPath -Encoding UTF8) | Where-Object { $_ -match 'local-db' }).Count
            $remaining | Should -Be 1
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'says which environments line to add when there is none' {
        $ws = New-Workspace
        try {
            Add-SqlTree -Workspace $ws -EnvName 'local-db'
            $r = Invoke-Rename @('local-db', 'dev-db', '-Root', $ws)
            $r.Stdout | Should -Match 'environments = \["dev-db"'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'honours a custom sql_root read from config' {
        $ws = New-Workspace
        try {
            $tp = [System.IO.Path]::Combine($ws, '.turbo-plugin')
            $feat = [System.IO.Path]::Combine($ws, 'db', 'scripts', 'local-db', 'feat-x')
            New-Item -ItemType Directory -Path $tp -Force | Out-Null
            New-Item -ItemType Directory -Path $feat -Force | Out-Null
            $enc = New-Object System.Text.UTF8Encoding($false)
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($tp, 'config.toml'), "[db]`nsql_root = `"db/scripts`"`n", $enc)
            [System.IO.File]::WriteAllText([System.IO.Path]::Combine($feat, '01.sql'), "目標環境: local-db`n", $enc)

            Invoke-Rename @('local-db', 'dev-db', '-Root', $ws, '-Apply') | Out-Null

            Test-Path -LiteralPath ([System.IO.Path]::Combine($ws, 'db', 'scripts', 'dev-db')) | Should -BeTrue
            [System.IO.File]::ReadAllText([System.IO.Path]::Combine($ws, 'db', 'scripts', 'dev-db', 'feat-x', '01.sql')) | Should -Match '目標環境: dev-db'
        } finally { Remove-Item -LiteralPath $ws -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
