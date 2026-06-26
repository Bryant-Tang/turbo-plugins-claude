param(
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

    # Target: explicit CLI arg → config.toml [build].project (no auto-detect). build accepts a
    # .sln (whole-solution) or a .csproj; the agent (SKILL) decides which and passes it explicitly.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'build' -CliProjectValue $Project -AllowSolution
    $projectFile = $target.Path

    # MSBuild path: config.local.toml [tools] msbuild_path → standard VS install locations
    # (v1.0+ U2: strict cut, no env var fallback — throws with /tp-setup guidance if missing)
    $msbuildPath = Find-MSBuild -RepoRoot $repoRoot

    # Configuration / Platform: OMIT when the agent gave no value (no CLI, no [build] memory) so
    # MSBuild / the .sln / Directory.Build.props resolve them — this matches VS. Forcing Debug/AnyCPU
    # (the pre-U3 behavior) overrode the csproj's `<Configuration Condition="'$(Configuration)'==''">`
    # default and silently diverged from VS. -Default $null keeps "no value" as no value.
    $buildConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'configuration' -CliValue $Configuration -Default $null
    $buildPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'platform' -CliValue $Platform -Default $null

    # SolutionDir: for a .sln, derive from the .sln's own directory (so $(SolutionDir) resolves for a
    # non-root solution); for a csproj, use the repo root (unchanged). Keep the trailing separator the
    # $(SolutionDir) convention expects.
    $isSolution = ($target.Type -eq 'sln')
    $solutionDirBase = if ($isSolution) { [System.IO.Path]::GetDirectoryName($projectFile) } else { $repoRoot }
    $solutionDir = $solutionDirBase.TrimEnd('\') + '\'

    Write-Output "Running MSBuild for $projectFile"
    $msbuildArgs = @($projectFile, '/restore', '/t:Build', "/p:SolutionDir=$solutionDir", '/p:RestorePackagesConfig=true')
    if (-not [string]::IsNullOrWhiteSpace($buildConfiguration)) { $msbuildArgs += "/p:Configuration=$buildConfiguration" }
    if (-not [string]::IsNullOrWhiteSpace($buildPlatform)) { $msbuildArgs += "/p:Platform=$buildPlatform" }
    & $msbuildPath @msbuildArgs
    # Backstop only: under EAP=Stop a real MSBuild failure that writes stderr throws a terminating
    # NativeCommandError BEFORE this line (caught by the outer catch -> exit 1, still fail-loud). This
    # guard only catches the rare non-zero-exit-without-stderr case. Working-as-designed per repo
    # CLAUDE.md ("PS 5.1 相容性" — EAP=Stop + native-exe stderr); do not "fix" by forcing reachability.
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Frontend pack is delegated to Compress-Content.ps1 (shipped alongside Build-Web.ps1);
    # Compress-Content exits 0 with a skip message when [frontend] isn't set, so no Test-Path guard needed.
    & ([System.IO.Path]::Combine($PSScriptRoot, 'Compress-Content.ps1'))
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # BUILD result template (KTD5): report the agent's inputs + the RESOLVED target (the 糾錯閘 so
    # the user sees which project/solution was built). Configuration/Platform left unspecified are
    # shown as MSBuild/solution-decided, never fabricated.
    Write-Output 'BUILD_OUTPUT (relay these lines to the user as the build result):'
    $buildLines = Format-BuildResultLines -ResolvedTarget $projectFile -Configuration $buildConfiguration -Platform $buildPlatform -IsSolution:$isSolution
    foreach ($l in $buildLines) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
