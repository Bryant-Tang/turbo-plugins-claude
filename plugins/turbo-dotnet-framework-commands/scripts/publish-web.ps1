param(
    # Path to the .pubxml publish profile. Falls back to PUBLISH_PUBXML_PATH env var.
    [string]$Profile = '',
    # MSBuild Configuration (e.g. Debug, Release). Falls back to PUBLISH_DEFAULT_CONFIGURATION env var, then 'Release'.
    [string]$Configuration = '',
    # MSBuild Platform (e.g. AnyCPU, x86, x64). Falls back to PUBLISH_DEFAULT_PLATFORM env var, then 'AnyCPU'.
    [string]$Platform = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Resolve-RepoPath {
    param(
        [string]$RepoRoot,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $PathValue
    }

    # Convert Git Bash Unix drive path: /c/foo/bar → C:\foo\bar
    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    $PathValue = $PathValue -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

try {
    $repoRoot = (Get-Location).Path
    $projectPathRel = $env:BUILD_PROJECT_PATH
    $msbuildPath = $env:BUILD_MSBUILD_PATH

    $pubxmlPathRaw = if (-not [string]::IsNullOrWhiteSpace($Profile)) { $Profile }
                     elseif (-not [string]::IsNullOrWhiteSpace($env:PUBLISH_PUBXML_PATH)) { $env:PUBLISH_PUBXML_PATH }
                     else { '' }

    $publishConfiguration = if (-not [string]::IsNullOrWhiteSpace($Configuration)) { $Configuration }
                            elseif (-not [string]::IsNullOrWhiteSpace($env:PUBLISH_DEFAULT_CONFIGURATION)) { $env:PUBLISH_DEFAULT_CONFIGURATION }
                            else { 'Release' }
    $publishPlatform = if (-not [string]::IsNullOrWhiteSpace($Platform)) { $Platform }
                       elseif (-not [string]::IsNullOrWhiteSpace($env:PUBLISH_DEFAULT_PLATFORM)) { $env:PUBLISH_DEFAULT_PLATFORM }
                       else { 'AnyCPU' }

    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        throw 'Missing BUILD_PROJECT_PATH environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($msbuildPath)) {
        throw 'Missing BUILD_MSBUILD_PATH environment variable'
    }

    if ([string]::IsNullOrWhiteSpace($pubxmlPathRaw)) {
        throw 'No publish profile specified. Provide -Profile <path> or set PUBLISH_PUBXML_PATH environment variable'
    }

    $projectFile = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $projectPathRel
    $msbuildPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $msbuildPath
    $pubxmlAbsPath = Resolve-RepoPath -RepoRoot $repoRoot -PathValue $pubxmlPathRaw

    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Configured project file does not exist: $projectFile"
    }

    if (-not (Test-Path -LiteralPath $msbuildPath -PathType Leaf)) {
        throw "Configured MSBuild executable does not exist: $msbuildPath"
    }

    if (-not (Test-Path -LiteralPath $pubxmlAbsPath -PathType Leaf)) {
        throw "Publish profile does not exist: $pubxmlAbsPath"
    }

    $publishProfileName = [System.IO.Path]::GetFileNameWithoutExtension($pubxmlAbsPath)
    $publishProfileDir  = [System.IO.Path]::GetDirectoryName($pubxmlAbsPath)

    Write-Output "Running MSBuild Publish for $projectPathRel (Configuration: $publishConfiguration, Platform: $publishPlatform)"
    Write-Output "  Publish profile: $publishProfileName"
    Write-Output "  Profile root:    $publishProfileDir"

    & $msbuildPath $projectFile `
        /p:DeployOnBuild=true `
        "/p:PublishProfile=$publishProfileName" `
        "/p:PublishProfileRootFolder=$publishProfileDir" `
        "/p:Configuration=$publishConfiguration" `
        "/p:Platform=$publishPlatform"

    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }

    Write-Output 'Publish succeeded.'

    try {
        $pubxml = [xml](Get-Content -LiteralPath $pubxmlAbsPath -Raw)
    }
    catch {
        [Console]::Error.WriteLine("Warning: failed to parse publish profile XML; output path unknown. ($($_.Exception.Message))")
        return
    }

    $publishUrlNodes = $pubxml.SelectNodes('//*[local-name()="PublishUrl"]')
    $methodNodes     = $pubxml.SelectNodes('//*[local-name()="WebPublishMethod"]')

    $method = if ($methodNodes -and $methodNodes.Count -gt 0) { $methodNodes[$methodNodes.Count - 1].InnerText.Trim() } else { '' }
    if ([string]::IsNullOrWhiteSpace($method)) { $method = 'FileSystem' }
    Write-Output "Method: $method"

    if (-not $publishUrlNodes -or $publishUrlNodes.Count -eq 0) {
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
        }
        else {
            $projectDir = [System.IO.Path]::GetDirectoryName($projectFile)
            $resolved = [System.IO.Path]::GetFullPath((Join-Path $projectDir $publishUrlRaw))
        }
        $resolved = $resolved.TrimEnd('\')
        $displayPath = 'file:///' + ($resolved -replace '\\', '/')
    }
    else {
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
