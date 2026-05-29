param(
    [string]$Pubxml = '',
    [string]$Configuration = '',
    [string]$Platform = '',
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))

try {
    Probe-GitVersion

    $repoRoot = (Get-Location).Path

    # Project: CLI arg → config.toml [build].project → auto-detect single .csproj
    $projectFile = Find-SingleCsproj -RepoRoot $repoRoot -CliProjectValue $Project

    # MSBuild path: config.local.toml [tools] msbuild_path → standard VS install locations
    # (v1.0+ U2: strict cut, no env var fallback — throws with /tp-setup guidance if missing)
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

    $publishConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'publish' -Key 'configuration' -CliValue $Configuration -Default 'Release'
    $publishPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'publish' -Key 'platform' -CliValue $Platform -Default 'Any CPU'

    # Pre-publish: run pack-content for frontend. pack-content.ps1 is shipped in this
    # plugin alongside publish-web.ps1, so the prior Test-Path guard was redundant —
    # pack-content already exits 0 with a skip message when [frontend] isn't configured.
    & ([System.IO.Path]::Combine($PSScriptRoot, 'pack-content.ps1'))
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $publishProfileName = [System.IO.Path]::GetFileNameWithoutExtension($pubxmlAbsPath)
    $publishProfileDir  = [System.IO.Path]::GetDirectoryName($pubxmlAbsPath)

    Write-Output "Running MSBuild Publish for $projectFile (Configuration: $publishConfiguration, Platform: $publishPlatform)"
    Write-Output "  Publish profile: $publishProfileName"
    Write-Output "  Profile root:    $publishProfileDir"

    & $msbuildPath $projectFile `
        /p:DeployOnBuild=true `
        "/p:PublishProfile=$publishProfileName" `
        "/p:PublishProfileRootFolder=$publishProfileDir" `
        "/p:Configuration=$publishConfiguration" `
        "/p:Platform=$publishPlatform"

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

    if ($publishUrlRaw -match '\$\(') {
        [Console]::Error.WriteLine('Warning: <PublishUrl> contains MSBuild properties; cannot resolve statically.')
        Write-Output "Published to: $publishUrlRaw"
        return
    }

    if ($method -eq 'FileSystem') {
        if ([System.IO.Path]::IsPathRooted($publishUrlRaw)) {
            $resolved = [System.IO.Path]::GetFullPath($publishUrlRaw)
        } else {
            $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $projectDir $publishUrlRaw))
        }
        $resolved = $resolved.TrimEnd('\')
        $displayPath = 'file:///' + ($resolved -replace '\\', '/')
    } else {
        $resolved = $publishUrlRaw
        $displayPath = $resolved
    }

    Write-Output "Published to: $displayPath"
    Write-Output "PUBLISH_OUTPUT_PATH=$resolved"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
