param(
    [string]$Configuration = '',
    [string]$Platform = '',
    [string]$Project = '',
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))

try {
    Probe-GitVersion

    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot

    # Target: explicit CLI arg → config.toml [build].project (no auto-detect). build accepts a
    # .sln (whole-solution) or a .csproj; the agent (SKILL) decides which and passes it explicitly.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'build' -CliProjectValue $Project -AllowSolution
    $projectFile = $target.Path

    # MSBuild path: config.local.toml [tools] msbuild_path → standard VS install locations
    # (strict cut, no env var fallback — throws pointing at config.local.toml if missing)
    $msbuildPath = Find-MSBuild -RepoRoot $repoRoot

    # Configuration / Platform: OMIT when the agent gave no value (no CLI, no [build] memory) so
    # MSBuild / the .sln / Directory.Build.props resolve them — this matches VS. Forcing Debug/AnyCPU
    # (the prior behavior) overrode the csproj's `<Configuration Condition="'$(Configuration)'==''">`
    # default and silently diverged from VS. -Default $null keeps "no value" as no value.
    $buildConfiguration = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'configuration' -CliValue $Configuration -Default $null
    $buildPlatform = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'build' -Key 'platform' -CliValue $Platform -Default $null

    # SolutionDir: for a .sln, derive from the .sln's own directory (so $(SolutionDir) resolves for a
    # non-root solution); for a csproj, use the repo root (unchanged). Keep the trailing separator the
    # $(SolutionDir) convention expects.
    $isSolution = ($target.Type -eq 'sln')
    $solutionDirBase = if ($isSolution) { [System.IO.Path]::GetDirectoryName($projectFile) } else { $repoRoot }
    $solutionDir = $solutionDirBase.TrimEnd('\') + '\'

    # /restore + /p:RestorePackagesConfig=true — both are load-bearing for packages.config projects:
    #
    #   * /restore must stay the SWITCH. Never rewrite it as `/t:Restore;Build`. packages.config
    #     projects pull their build-time .targets in through `<Import Condition="Exists(...)">`,
    #     which only binds if the project is re-evaluated AFTER restore. The switch runs restore in
    #     its own pass and then re-evaluates for build; one combined target list evaluates once and
    #     those imports stay dead.
    #   * RestorePackagesConfig is what makes NuGet look at packages.config at all. Without it,
    #     restore reports "no projects contain packages to restore" and does nothing (measured on a
    #     real 12-project packages.config solution, MSBuild 17.14, 2026-08-07 — with the flag the
    #     same command resolved every package; without it, zero).
    $msbuildArgs = @($projectFile, '/restore', '/t:Build', "/p:SolutionDir=$solutionDir", '/p:RestorePackagesConfig=true')
    if (-not [string]::IsNullOrWhiteSpace($buildConfiguration)) { $msbuildArgs += "/p:Configuration=$buildConfiguration" }
    if (-not [string]::IsNullOrWhiteSpace($buildPlatform)) { $msbuildArgs += "/p:Platform=$buildPlatform" }

    # Echo the whole command line, not just the target. An agent reading only "Running MSBuild for X"
    # has no way to know restore already ran, so on a NuGet-shaped failure it invents its own remedy —
    # in the field it told the user to go fetch nuget.exe, for a build that had already restored.
    # Printing the args makes this script's behaviour self-evident to whoever reads stdout.
    Write-Output "Running MSBuild for $projectFile"
    Write-Output "  MSBuild args: $($msbuildArgs -join ' ')"
    & $msbuildPath @msbuildArgs
    # Backstop only: under EAP=Stop a real MSBuild failure that writes stderr throws a terminating
    # NativeCommandError BEFORE this line (caught by the outer catch -> exit 1, still fail-loud). This
    # guard only catches the rare non-zero-exit-without-stderr case. Working-as-designed per repo
    # CLAUDE.md ("PS 5.1 相容性" — EAP=Stop + native-exe stderr); do not "fix" by forcing reachability.
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # Read [frontend] dir here as well as inside Compress-Content: the result template has to state
    # whether a frontend pack ran, and "it printed a skip message" is not something the agent ever
    # relays (issue #30). Read before invoking, so the reported state is the configured one even if
    # the pack itself is what fails.
    # -TargetProject is what makes the answer specific to THIS build: with several Web projects in
    # one repo, [frontend] groups are keyed by project and the un-keyed form is only reported as
    # applying when its directory actually belongs to the resolved target (issue #125).
    $frontendGroup = Resolve-FrontendGroup -RepoRoot $repoRoot -TargetProject $projectFile

    # Frontend pack is delegated to Compress-Content.ps1 (shipped alongside Build-Web.ps1);
    # Compress-Content exits 0 with a skip message when [frontend] isn't set, so no Test-Path guard needed.
    # -RepoRoot is forwarded (Publish-Web already does this): without it a -RepoRoot-targeted build in
    # a multi-project workspace would pack whichever project the ambient cwd happens to be.
    # -Project is forwarded for the same reason one level down: Compress-Content has to resolve the
    # SAME group this line just reported, or the template and the behaviour drift apart again.
    & ([System.IO.Path]::Combine($PSScriptRoot, 'Compress-Content.ps1')) -RepoRoot $repoRoot -Project $projectFile
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    # BUILD result template (KTD5): report the agent's inputs + the RESOLVED target (the 糾錯閘 so
    # the user sees which project/solution was built). Configuration/Platform left unspecified are
    # shown as MSBuild/solution-decided, never fabricated.
    Write-Output 'BUILD_OUTPUT (relay these lines to the user as the build result):'
    $buildLines = Format-BuildResultLines -ResolvedTarget $projectFile -Configuration $buildConfiguration -Platform $buildPlatform -FrontendGroup $frontendGroup -IsSolution:$isSolution
    foreach ($l in $buildLines) { Write-Output $l }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
