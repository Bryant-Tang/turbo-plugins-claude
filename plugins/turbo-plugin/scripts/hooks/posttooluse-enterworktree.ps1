Set-StrictMode -Version Latest
# Hooks must not throw the host session. Surface errors as stderr but never exit non-zero.
$ErrorActionPreference = 'Continue'

. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'applicationhost-helpers.ps1'))

function Emit-Json {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Compress -Depth 6)
    [Console]::Out.Write($json)
}

try {
    $stdin = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdin)) { Emit-Json @{}; exit 0 }

    $payload = $stdin | ConvertFrom-Json -ErrorAction Stop

    $worktreePath = $null
    if ($payload.PSObject.Properties.Match('tool_response').Count -gt 0 -and
        $null -ne $payload.tool_response -and
        $payload.tool_response.PSObject.Properties.Match('worktreePath').Count -gt 0) {
        $worktreePath = [string]$payload.tool_response.worktreePath
    }
    if ([string]::IsNullOrWhiteSpace($worktreePath)) { Emit-Json @{}; exit 0 }

    $newPath = Get-NormalizedAbsolutePath -Path $worktreePath
    if (-not (Test-Path -LiteralPath $newPath -PathType Container)) { Emit-Json @{}; exit 0 }

    $markerDir = Join-Path $newPath '.turbo-plugin'
    if (-not (Test-Path -LiteralPath $markerDir -PathType Container)) { Emit-Json @{}; exit 0 }

    $apphostSource = Join-Path $markerDir 'applicationhost.config'
    if (-not (Test-Path -LiteralPath $apphostSource -PathType Leaf)) { Emit-Json @{}; exit 0 }

    $csprojFiles = @(Get-ChildItem -LiteralPath $newPath -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|\.vs|\.git)\\' })
    if ($csprojFiles.Count -eq 0) { Emit-Json @{}; exit 0 }

    # Default target: write into the .vs/<sln-stem>/config/applicationhost.config under the
    # worktree. If a .sln is missing, fall back to the source-of-truth itself.
    $apphostTarget = $null
    $slnFile = @(Get-ChildItem -LiteralPath $newPath -Filter '*.sln' -ErrorAction SilentlyContinue) | Select-Object -First 1
    if ($null -ne $slnFile) {
        $slnStem = [System.IO.Path]::GetFileNameWithoutExtension($slnFile.FullName)
        $apphostTarget = Join-Path $newPath ".vs/$slnStem/config/applicationhost.config"
    } else {
        $apphostTarget = $apphostSource
    }

    $targetDir = [System.IO.Path]::GetDirectoryName($apphostTarget)
    if (-not (Test-Path -LiteralPath $targetDir -PathType Container)) {
        New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $apphostTarget -PathType Leaf)) {
        Copy-Item -LiteralPath $apphostSource -Destination $apphostTarget -Force
    }

    $updates = @()
    foreach ($csproj in $csprojFiles) {
        $rel = Get-RelativePathSafe -From $newPath -To $csproj.FullName
        $hash = Get-ProjectIdentityHash -RepoPath $newPath -CsprojRelPath $rel
        $siteName = Format-IisExpressSiteName -CsprojPath $csproj.FullName -IdentityHash $hash
        $newPhysical = [System.IO.Path]::GetDirectoryName($csproj.FullName)
        try {
            $result = Update-ApplicationhostConfig -ConfigPath $apphostTarget -SiteName $siteName -NewPhysicalPath $newPhysical
            $updates += $result
        } catch {
            # Site might not exist yet — that's expected for csprojs that haven't been registered.
            continue
        }
    }

    # @(...) wrap: a single-element Where-Object pipeline returns the unwrapped object;
    # without @(...) the next .Count reads the hashtable's KEY count (4 for our shape),
    # not the number of updated sites. Classic PS single-element pipeline gotcha.
    $updatedCount = @($updates | Where-Object { $_.Updated }).Count
    $msg = if ($updatedCount -gt 0) {
        "turbo-plugin: refreshed applicationhost.config for $updatedCount site(s) in $newPath"
    } else {
        $null
    }

    if ($msg) {
        Emit-Json @{ systemMessage = $msg }
    } else {
        Emit-Json @{}
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("turbo-plugin posttooluse-enterworktree: $($_.Exception.Message)")
    Emit-Json @{}
    exit 0
}
