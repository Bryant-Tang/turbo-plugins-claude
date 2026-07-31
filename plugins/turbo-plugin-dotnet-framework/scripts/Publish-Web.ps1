param(
    [string]$Pubxml = '',
    [string]$Configuration = '',
    [string]$Platform = '',
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    $repoRoot = (Get-Location).Path

    # Target: explicit CLI arg → config.toml [publish].project (no auto-detect). publish needs a
    # .csproj (reads PublishProfiles / publishes one project); a .sln is rejected (no -AllowSolution).
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'publish' -CliProjectValue $Project
    $projectFile = $target.Path

    # MSBuild path: config.local.toml [tools] msbuild_path → standard VS install locations
    # (strict cut, no env var fallback — throws pointing at config.local.toml if missing)
    $msbuildPath = Find-MSBuild -RepoRoot $repoRoot

    # pubxml: CLI arg → config.toml [publish].default_pubxml → auto-detect single .pubxml under project's Properties/PublishProfiles
    $pubxmlPathRaw = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'publish' -Key 'default_pubxml' -CliValue $Pubxml -Default $null
    if ([string]::IsNullOrWhiteSpace($pubxmlPathRaw)) {
        $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
        $profilesDir = Join-Path $projectDir 'Properties/PublishProfiles'
        $pubxmls = @()
        if (Test-Path -LiteralPath $profilesDir -PathType Container) {
            $pubxmls = @(Get-ChildItem -LiteralPath $profilesDir -Filter '*.pubxml' -ErrorAction SilentlyContinue)
        }
        if ($pubxmls.Count -eq 0) {
            throw 'No .pubxml found. Specify -Pubxml or set [publish].default_pubxml in .turbo-plugin/config.toml.'
        }
        if ($pubxmls.Count -gt 1) {
            $names = ($pubxmls | ForEach-Object { $_.Name }) -join ', '
            throw "Multiple .pubxml files found under $profilesDir ($names). Specify -Pubxml or set [publish].default_pubxml."
        }
        $pubxmlAbsPath = $pubxmls[0].FullName
    } else {
        $pubxmlAbsPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $pubxmlPathRaw
    }
    if (-not (Test-Path -LiteralPath $pubxmlAbsPath -PathType Leaf)) {
        throw "Publish profile does not exist: $pubxmlAbsPath"
    }

    # Configuration / Platform: OMIT when the agent gave no value — the pubxml's embedded
    # <Configuration>/<Platform> govern the publish (that is how VS publishes from a profile).
    # Forcing Release/Any CPU (the prior default) overrode the profile and could publish the
    # wrong configuration. -Default $null keeps "no value" as no value.
    $publishConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'publish' -Key 'configuration' -CliValue $Configuration -Default $null
    $publishPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'publish' -Key 'platform' -CliValue $Platform -Default $null

    # Pre-publish: run Compress-Content for frontend. Compress-Content.ps1 is shipped in this
    # plugin alongside Publish-Web.ps1, so the prior Test-Path guard was redundant —
    # Compress-Content already exits 0 with a skip message when [frontend] isn't configured.
    & ([System.IO.Path]::Combine($PSScriptRoot, 'Compress-Content.ps1'))
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $publishProfileName = [System.IO.Path]::GetFileNameWithoutExtension($pubxmlAbsPath)
    $publishProfileDir  = [System.IO.Path]::GetDirectoryName($pubxmlAbsPath)

    Write-Output "Running MSBuild Publish for $projectFile"
    Write-Output "  Publish profile: $publishProfileName"
    Write-Output "  Profile root:    $publishProfileDir"

    # Pass /p:Configuration | /p:Platform only when the agent supplied a value; otherwise let the
    # pubxml's embedded values govern (VS-aligned).
    $publishArgs = @(
        $projectFile,
        '/p:DeployOnBuild=true',
        "/p:PublishProfile=$publishProfileName",
        "/p:PublishProfileRootFolder=$publishProfileDir"
    )
    if (-not [string]::IsNullOrWhiteSpace($publishConfiguration)) { $publishArgs += "/p:Configuration=$publishConfiguration" }
    if (-not [string]::IsNullOrWhiteSpace($publishPlatform)) { $publishArgs += "/p:Platform=$publishPlatform" }
    & $msbuildPath @publishArgs

    # Backstop only: under EAP=Stop a real MSBuild failure that writes stderr throws a terminating
    # NativeCommandError BEFORE this line (caught by the outer catch -> exit 1, still fail-loud). This
    # guard only catches the rare non-zero-exit-without-stderr case. Working-as-designed per repo
    # CLAUDE.md ("PS 5.1 相容性" — EAP=Stop + native-exe stderr); do not "fix" by forcing reachability.
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    Write-Output 'Publish succeeded.'

    # Parse via Select-Xml (avoids PS 5.1 + StrictMode + outer-try interaction that
    # caused [xml] cast / New-Object XmlDocument to silently coerce to String here).
    $publishUrlNodes = $null
    $methodNodes = $null
    try {
        # VS-generated pubxml uses camelCase <publishUrl> (and PascalCase <WebPublishMethod>);
        # local-name() is case-sensitive, so query both shapes via translate() lowercase-match.
        $publishUrlNodes = @(Select-Xml -Path $pubxmlAbsPath -XPath "//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='publishurl']" | ForEach-Object { $_.Node })
        $methodNodes     = @(Select-Xml -Path $pubxmlAbsPath -XPath "//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='webpublishmethod']" | ForEach-Object { $_.Node })
    } catch {
        [Console]::Error.WriteLine("Warning: failed to parse publish profile XML; output path unknown. ($($_.Exception.Message))")
        return
    }

    $method = if ($methodNodes.Count -gt 0) { $methodNodes[$methodNodes.Count - 1].InnerText.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($method)) { $method = 'FileSystem' }
    Write-Output "Method: $method"

    if ($publishUrlNodes.Count -eq 0) {
        [Console]::Error.WriteLine('Warning: <PublishUrl> not found in profile; output path unknown.')
        return
    }

    $publishUrlRaw = $publishUrlNodes[$publishUrlNodes.Count - 1].InnerText.Trim()
    if ([string]::IsNullOrWhiteSpace($publishUrlRaw)) {
        [Console]::Error.WriteLine('Warning: <PublishUrl> is empty; output path unknown.')
        return
    }

    # The result-template lead lines (the 糾錯閘) shared by every PUBLISH_OUTPUT branch:
    # Target = the csproj actually resolved/published, Profile = the pubxml used. They sit above the
    # bare path/URL line(s) so the agent relays "which project" the same way build/run/stop do
    # (Format-*ResultLines / KTD5), while the path/URL lines stay bare for terminal clickability.
    $publishMarker = 'PUBLISH_OUTPUT (relay these lines to the user as the publish result; keep the path/URL line(s) bare so they stay clickable):'
    $publishLead   = @("Target: $projectFile", "Profile: $publishProfileName")

    if ($publishUrlRaw -match '\$\(') {
        [Console]::Error.WriteLine('Warning: <PublishUrl> contains MSBuild properties; cannot resolve statically.')
        # Unresolved MSBuild property — no real path computable; relay the raw PublishUrl as the
        # location line after the shared lead, via the SAME marker so the SKILL parses one shape.
        Write-Output $publishMarker
        foreach ($l in $publishLead) { Write-Output $l }
        Write-Output $publishUrlRaw
        return
    }

    $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
    $out = Get-PublishOutputLines -PublishUrlRaw $publishUrlRaw -Method $method -ProjectDir $projectDir

    # KTD8: after the shared marker + lead lines, emit the publish location as BARE
    # line(s) the agent relays VERBATIM — the raw Windows path then the file:/// URL (FileSystem),
    # each on its own line with NO trailing punctuation, so the terminal keeps the paths clickable.
    Write-Output $publishMarker
    foreach ($l in $publishLead) { Write-Output $l }
    if ($out.IsFileSystem) {
        Write-Output $out.Resolved
        Write-Output $out.DisplayPath
    } else {
        Write-Output $out.Resolved
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
