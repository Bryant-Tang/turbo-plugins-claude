[CmdletBinding()]
param(
    [string]$SessionRoot = '',
    [switch]$PrintCommand
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Resolve which dbhub config to use, then exec the DBHub container. PowerShell sibling of
# start-dbhub.sh -- `.mcp.json` launches the bash one (an MCP `command` is exec'd, not run through
# a shell, and this plugin's SessionStart hook already establishes bash as a dependency); this one
# exists so the resolution rules are testable on Windows and stay symmetric.
#
# This wrapper exists for two defects found on a real machine 2026-07-31.
#
# 1. `.mcp.json` used to hand `docker run -v` the path
#    `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml` directly. Docker CREATES a directory
#    when a bind-mount source does not exist, so every folder a session was ever opened in got a
#    stray `.turbo-plugin/dbhub.local.toml/` -- an empty DIRECTORY, not a file. That is worse than
#    untidy: it blocks its own fix (you can no longer create a file of that name), and what dbhub
#    receives is a directory rather than a config. So: never pass a path to `-v` without having
#    confirmed it is an existing FILE.
#
# 2. `${CLAUDE_PROJECT_DIR}` is the session root. In a multi-project workspace (several sibling
#    repos under one folder) that root is not any of the projects, so the config -- which lives in
#    a project -- was never found. Resolution order (D1, decided 2026-08-03):
#       a) <session-root>/.turbo-plugin/dbhub.local.toml, if present, always wins.
#       b) otherwise the IMMEDIATE subdirectories are scanned; exactly one match is used.
#       c) several matches -> stop and list them (guessing which database is not recoverable).
#       d) no match -> stop and say where it looked.
#
# Every failure exits 0: a non-zero exit is reported to the user as a crashed MCP server, which is
# alarming and unhelpful when the real answer is "this project has no database configured".

$configRel = '.turbo-plugin/dbhub.local.toml'
$image = 'bytebase/dbhub:latest'

function Write-Note { param([string]$Message) [Console]::Error.WriteLine($Message) }

try {
    if ([string]::IsNullOrWhiteSpace($SessionRoot)) {
        Write-Note 'tp-dbhub: no session root was passed to Start-Dbhub.ps1, so there is nothing to search.'
        exit 0
    }
    if (-not (Test-Path -LiteralPath $SessionRoot -PathType Container)) {
        Write-Note "tp-dbhub: '$SessionRoot' is not a directory; cannot look for $configRel."
        exit 0
    }

    $rootConfig = [System.IO.Path]::Combine($SessionRoot, '.turbo-plugin', 'dbhub.local.toml')
    $config = ''
    if (Test-Path -LiteralPath $rootConfig -PathType Leaf) {
        $config = $rootConfig
    } else {
        # Immediate subdirectories only. Deeper is not searched on purpose: the workspace shape this
        # supports is "sibling projects one level down", and an unbounded walk would make which
        # database you connect to depend on directory depth.
        $matched = @()
        foreach ($dir in @(Get-ChildItem -LiteralPath $SessionRoot -Directory -ErrorAction SilentlyContinue)) {
            $candidate = [System.IO.Path]::Combine($dir.FullName, '.turbo-plugin', 'dbhub.local.toml')
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $matched += $candidate }
        }

        if (@($matched).Count -eq 1) {
            $config = $matched[0]
        } elseif (@($matched).Count -eq 0) {
            Write-Note 'tp-dbhub: no database config found.'
            Write-Note "  looked for: $rootConfig"
            Write-Note "  and in each project directly under: $SessionRoot"
            Write-Note 'Run /tp-setup in the project that has a database, then copy'
            Write-Note '  .turbo-plugin/dbhub.example.local.toml -> .turbo-plugin/dbhub.local.toml and fill it in.'
            exit 0
        } else {
            Write-Note 'tp-dbhub: several projects here have a database config, so which one to connect to is ambiguous:'
            foreach ($m in $matched) { Write-Note "  $m" }
            Write-Note "Pick one by putting a config at the workspace root ($rootConfig) --"
            Write-Note 'copying the chosen project''s file there is enough. A root config always wins.'
            exit 0
        }
    }

    # Docker wants forward slashes for the mount source on Windows.
    $mountSrc = $config -replace '\\', '/'
    $dockerArgs = @('run', '-i', '--rm', '--init', '-v', "${mountSrc}:/dbhub.toml", $image, '--transport', 'stdio', '--config', '/dbhub.toml')

    if ($PrintCommand) {
        Write-Output 'docker'
        foreach ($a in $dockerArgs) { Write-Output $a }
        exit 0
    }

    $dockerCmd = Get-Command docker -ErrorAction SilentlyContinue
    if ($null -eq $dockerCmd) {
        Write-Note 'tp-dbhub: docker was not found on PATH. The dbhub MCP server runs in a container;'
        Write-Note 'install Docker Desktop (or start it) and reopen the session.'
        exit 0
    }

    & docker @dockerArgs
    exit $LASTEXITCODE
}
catch {
    Write-Note "tp-dbhub: $($_.Exception.Message)"
    exit 0
}
