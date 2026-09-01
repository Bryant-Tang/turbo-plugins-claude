[CmdletBinding()]
param(
    [string]$SvnUrl = '',
    [switch]$StandardLayout,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

# Create a project's landing path in the SVN repository, on explicit user confirmation.
#
# Why this exists: no other production script in this plugin runs `svn mkdir`, so a project's path
# had to be created by hand before /tp-setup could do anything -- while case (a) of tp-setup
# advertises "brand new git + SVN" and only ever delivered the git half. Creating a path is a
# PERMANENT write to a shared server (SVN has no delete-for-real), so this is a separate,
# explicitly-invoked script: nothing calls it implicitly, and the SKILL must show the full URL and
# get a yes first.
#
# -StandardLayout is only offered when the URL ends with /trunk, which is the layout it means: it
# additionally creates the sibling branches/ and tags/. Without that suffix the layout has no
# unambiguous reading, so only the given path is created.
#
# -DryRun prints the URLs that WOULD be created and exits 0 without touching the server.
try {
    if ([string]::IsNullOrWhiteSpace($SvnUrl)) {
        throw 'Missing required argument: -SvnUrl <url>'
    }

    # Strip a trailing slash so the /trunk suffix logic below is not fooled by '.../trunk/'.
    $url = $SvnUrl.TrimEnd('/')

    if ($url -notmatch '^(https?|svn|svn\+ssh)://' -and $url -notmatch '^file:///') {
        throw "-SvnUrl must be an SVN URL (http/https/svn/svn+ssh/file), got: $url"
    }

    # Already there? Say so and stop -- creating is not idempotent in a useful way (a second mkdir
    # fails), and a caller that reaches here with an existing path has misread its own preflight.
    # `2>$null` under EAP=Stop, deliberately left inline (issue #137). It looks like the #128 bug
    # -- a stderr write becomes terminating and the $LASTEXITCODE guard below is then unreachable
    # -- and the mechanism really does apply to svn. What makes it safe is that `svn` is the
    # --non-interactive shim in lib/Common.ps1: with that flag svn writes stderr only when the
    # call GENUINELY fails, and "genuinely failed" is exactly when $exists must be false. The
    # throw and the guard therefore agree. See the write-up at the shim before changing this.
    $exists = $false
    try {
        & svn info $url 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $exists = $true }
    } catch {
        $exists = $false
    }
    if ($exists) {
        throw "That path already exists in the repository: $url"
    }

    $targets = @($url)
    if ($StandardLayout) {
        if ($url -notmatch '/trunk$') {
            throw "-StandardLayout needs a URL ending in /trunk (it creates the sibling branches/ and tags/). Got: $url"
        }
        $base = $url -replace '/trunk$', ''
        $targets += @("$base/branches", "$base/tags")
    }

    if ($DryRun) {
        Write-Output 'Would create:'
        foreach ($t in $targets) { Write-Output "  $t" }
        exit 0
    }

    Write-Output 'Creating in the repository:'
    foreach ($t in $targets) { Write-Output "  $t" }

    # --parents so an absent intermediate directory (the project folder itself) is created too; all
    # targets go in ONE revision so a half-created layout is not possible.
    & svn mkdir --parents --encoding UTF-8 -m 'create project path (turbo-plugin)' @targets
    if ($LASTEXITCODE -ne 0) { throw 'svn mkdir failed' }

    Write-Output ''
    Write-Output 'Created. SVN paths are permanent -- there is no undo.'
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
