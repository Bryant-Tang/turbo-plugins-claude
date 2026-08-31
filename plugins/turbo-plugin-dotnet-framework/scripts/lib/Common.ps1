# turbo-plugin-dotnet-framework concern helpers (MSBuild / csproj / IIS site name /
# project-identity). Core (universal helpers + the UTF-8 encoding
# preamble + StrictMode/EAP) is dot-sourced first; this concern lib must NOT reset the
# encoding Core establishes (KTD2a). All scripts source THIS file, which transitively pulls
# in Core.ps1 from the same lib/ directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'Core.ps1'))




# Resolve the anchor directory that project-relative paths (and therefore the identity hash) are
# measured from: the git worktree top-level when inside git, else the project root itself.
#
# Every caller that computes an identity needs the SAME anchor, because the hash mixes in the
# csproj path *relative to it* -- two callers disagreeing on the anchor produce two different site
# names for one project, and stop / orphan-cleanup then fail to match the running site. Keep this
# the single place that decision is made.
#
# The git call is wrapped in try/catch for the EAP=Stop + native-stderr reason documented on
# Get-ProjectIdentityHash below: without it, a non-git folder throws instead of falling back.
function Resolve-IdentityAnchor {
    param([Parameter(Mandatory = $true)][string]$RepoRoot)

    $topLevel = ''
    try {
        $topLevel = (& git -C $RepoRoot rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    } catch {
        $topLevel = ''
    }

    if ([string]::IsNullOrWhiteSpace($topLevel)) {
        return Get-NormalizedAbsolutePath -Path $RepoRoot
    }
    return Get-NormalizedAbsolutePath -Path $topLevel
}

# Compute the project-identity hash used for IIS Express site name suffixes
# and cross-worktree project matching. Inputs:
#   -RepoPath: an absolute path inside the worktree whose project we're identifying.
#   -CsprojRelPath: csproj path relative to the identity root (forward slashes preferred).
# Returns: first 8 hex chars of sha256(identity-root + "#" + lower(csproj-relpath)), where the
# identity root is the git-common-dir when inside git, else the project root's own path.
#
# git-common-dir is PREFERRED, not REQUIRED. It is the right root inside git because it is shared
# by every worktree of the same repository, so one project keeps one identity no matter which
# worktree it is run from. But a project folder that was never `git init`-ed still needs a stable
# site name: build/publish already work outside git entirely (see Resolve-DotnetRepoRoot), and
# making run/stop the only git-requiring operations left users with a project they could build but
# not run (issue #29). Outside git we therefore fall back to the project root's absolute path,
# which gives the same guarantee that actually matters here -- one checkout, one stable hash. The
# only property lost is cross-worktree sharing, which a non-git folder cannot have anyway.
#
# INVARIANT: inside git the identity string is byte-identical to the pre-fallback version, so
# existing site names, committed applicationhost.config entries and the site-name lookups in
# Stop-Iis / Remove-OrphanIis all keep matching. Do not "simplify" by always using $RepoPath.
function Get-ProjectIdentityHash {
    param(
        [Parameter(Mandatory = $true)][string]$RepoPath,
        [Parameter(Mandatory = $true)][string]$CsprojRelPath
    )

    # try/catch, not merely 2>$null: under EAP=Stop a native exe that WRITES stderr throws a
    # terminating NativeCommandError before the IsNullOrWhiteSpace check below can run (repo
    # CLAUDE.md, "PS 5.1 相容性" #4). Without the catch the non-git path would surface raw git
    # stderr instead of falling back -- i.e. the fallback would be dead code. Core.ps1's
    # Get-MainWorktree wraps its git call for exactly this reason.
    $commonDir = ''
    try {
        $commonDir = (& git -C $RepoPath rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    } catch {
        $commonDir = ''
    }

    $identityRoot = if ([string]::IsNullOrWhiteSpace($commonDir)) {
        Get-NormalizedAbsolutePath -Path $RepoPath
    } else {
        Get-NormalizedAbsolutePath -Path $commonDir
    }

    $relNorm = ($CsprojRelPath -replace '\\', '/').ToLower()
    $identity = "$identityRoot#$relNorm"

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($identity)
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    $hex = ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
    return $hex.Substring(0, 8)
}

function Format-IisExpressSiteName {
    param(
        [Parameter(Mandatory = $true)][string]$CsprojPath,
        [Parameter(Mandatory = $true)][string]$IdentityHash
    )
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($CsprojPath)
    return "$stem-$IdentityHash"
}

# Locate MSBuild.exe. Lookup order (strict cut, no env fallback):
#   1. .turbo-plugin/config.local.toml [tools] msbuild_path  (machine-specific, gitignored)
#   2. Standard install paths (VS 2017/2019/2022 Enterprise/Professional/Community/BuildTools)
#   3. Throw, pointing at config.local.toml.
# Build Tools is in the list because it is the whole point of not depending on Visual Studio: a CI
# agent or a trimmed developer machine installs "Build Tools for Visual Studio" + IIS Express and
# never installs the IDE. Without those paths this plugin still silently required a full VS.
# It comes last within each year: it is the most limited edition, so an IDE install on the same
# machine should win.
# $env:TURBO_PLUGIN_MSBUILD_PATH is deliberately NOT read — turbo-plugin is the
# first release; no legacy users to migrate. If the env var happens to be set by some
# other tool, it is ignored.
function Find-MSBuild {
    param([string]$RepoRoot = '')

    # Step 1: config.local.toml [tools] msbuild_path (via Resolve-ConfigValue's merge chain)
    if (-not [string]::IsNullOrWhiteSpace($RepoRoot)) {
        $configured = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'tools' -Key 'msbuild_path' -CliValue $null -Default $null
        if (-not [string]::IsNullOrWhiteSpace($configured)) {
            $resolved = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $configured
            if (Test-Path -LiteralPath $resolved -PathType Leaf) {
                return $resolved
            }
            throw @"
MSBuild 路徑設定指向不存在的檔案: $resolved
(來源: .turbo-plugin/config.local.toml [tools] msbuild_path)
請修正該檔內的路徑,或整行移除改用自動偵測。
"@
        }
    }

    # Step 2: probe standard install paths.
    # Build Tools 2022 still installs under Program Files (x86) by default even though VS 2022
    # itself is 64-bit, so both roots are probed for every year rather than assuming one.
    $candidates = @(
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Enterprise\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Professional\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\Community\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2019\BuildTools\MSBuild\Current\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Enterprise\MSBuild\15.0\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Professional\MSBuild\15.0\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\Community\MSBuild\15.0\Bin\MSBuild.exe",
        "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2017\BuildTools\MSBuild\15.0\Bin\MSBuild.exe"
    )
    $found = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1)
    if ($found.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($found[0])) {
        return $found[0]
    }

    # Step 3: throw, pointing at the one place a path can be pinned.
    throw @"
找不到 MSBuild。請安裝「Build Tools for Visual Studio」(不需要完整的 Visual Studio),
或手動在 .turbo-plugin/config.local.toml 加上:
  [tools]
  msbuild_path = "C:/Program Files (x86)/Microsoft Visual Studio/2022/BuildTools/MSBuild/Current/Bin/MSBuild.exe"
"@
}

# Resolve the EXPLICIT build/run/publish target (a .csproj or .sln) for an operation.
# "Give agent the VS 2022": no auto-detection — the agent (via the SKILL) decides which
# project to act on and passes it explicitly, or it comes from the operation's config
# memory. There is deliberately no repo scan and no "multiple found" throw; an ambiguous
# repo is the agent's call to make, not the script's.
#
# Resolution chain:
#   CLI -CliProjectValue  ->  [<Section>].project  ->  (run/stop only) [build].project  ->  clear error
#
# Args:
#   -RepoRoot        absolute repo root used for config lookup + relative-path resolution.
#   -Section         'build' | 'run' | 'publish' — selects the config key and the back-compat fallback.
#                    run/stop both resolve under 'run' (run/stop share one target).
#   -CliProjectValue an explicit CLI target (pass '' / $null when not provided).
#   -AllowSolution   when set, a .sln target is allowed (build only). Otherwise a .sln throws
#                    so run/stop/publish (which read csproj XML / project identity) fail loudly.
#   -AllowMissing    when set, returns $null instead of throwing when nothing resolves. Used by
#                    tp-cleanup-orphan-iis's no-project path to branch to generic site matching.
#
# Returns: [pscustomobject] @{ Path = <absolute path>; Type = 'csproj' | 'sln' }  (or $null with -AllowMissing).
# Per-project groups mean the config names SEVERAL sub-projects and nothing in it says which one
# this command is about, so there is no default target to fall back to. Picking one would act on a
# project the user did not name -- the exact failure per-project groups exist to prevent -- so this
# stops and lists the choices instead (issue #133).
#
# A bare `[<section>].project` is deliberately NOT used as the default once groups exist: it would
# make "forgot to pass --project" silently mean "the main project", which is the same wrong answer
# with an extra step. It is called out in the message so the reason is visible from the error alone.
#
# This check is section-agnostic, but only [build] / [publish] LAYER their values through
# Resolve-GroupedConfigValue -- [run] does not (issue #133 covers build and publish). So a
# `[run."proj-1"]` section makes run demand an explicit target while its other keys stay inert.
# That asymmetry is the safe direction (loud about the target, no silent mis-target) and it is
# documented in the README; making [run] layer too is a separate change, not a bug fix.
function Assert-ExplicitTargetWhenGrouped {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $sections = @(Get-ConfigGroupSections -RepoRoot $RepoRoot -Section $Section)
    if ($sections.Count -eq 0) { return }
    $keys = @($sections | ForEach-Object { Get-ConfigGroupKey -Section $_ -Parent $Section })
    $msg = "[$Section] has per-project groups, so there is no default target. " +
           "Specify the project explicitly. Configured groups: $($keys -join ', ')."
    $bare = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $Section -Key 'project' -CliValue $null -Default $null
    if (-not [string]::IsNullOrWhiteSpace([string]$bare)) {
        $msg += " ([$Section].project = '$bare' is not used as a default while groups exist.)"
    }
    throw $msg
}

function Resolve-ProjectTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][ValidateSet('build', 'run', 'publish')][string]$Section,
        [string]$CliProjectValue = '',
        [switch]$AllowSolution,
        [switch]$AllowMissing
    )
    if (-not [string]::IsNullOrWhiteSpace($CliProjectValue)) {
        $projectPathRel = $CliProjectValue
    } else {
        Assert-ExplicitTargetWhenGrouped -RepoRoot $RepoRoot -Section $Section
        $projectPathRel = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $Section -Key 'project' -CliValue $null -Default $null
        # Back-compat: run/stop fall back to [build].project when [run].project is unset, so users
        # who configured only [build].project before the per-operation key split keep working. The
        # grouped check applies to the section actually being read, or the fallback would reintroduce
        # the arbitrary pick through the back door.
        if ([string]::IsNullOrWhiteSpace($projectPathRel) -and $Section -eq 'run') {
            Assert-ExplicitTargetWhenGrouped -RepoRoot $RepoRoot -Section 'build'
            $projectPathRel = Resolve-ConfigValue -RepoRoot $RepoRoot -Section 'build' -Key 'project' -CliValue $null -Default $null
        }
    }
    if ([string]::IsNullOrWhiteSpace($projectPathRel)) {
        if ($AllowMissing) { return $null }
        $hint = switch ($Section) {
            'build'   { 'Specify -Project (a .csproj or .sln) or set [build].project in .turbo-plugin/config.toml.' }
            'run'     { 'Specify -Project (a .csproj) or set [run].project (falls back to [build].project) in .turbo-plugin/config.toml.' }
            'publish' { 'Specify -Project (a .csproj) or set [publish].project in .turbo-plugin/config.toml.' }
        }
        throw "No $Section target resolved. $hint"
    }
    $projectFile = Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $projectPathRel
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf)) {
        throw "Project file does not exist: $projectFile"
    }
    $isSolution = ([System.IO.Path]::GetExtension($projectFile)).ToLower() -eq '.sln'
    if ($isSolution -and -not $AllowSolution) {
        throw "A .sln target is only valid for build. The $Section operation needs a .csproj, got: $projectFile"
    }
    $type = if ($isSolution) { 'sln' } else { 'csproj' }
    return [pscustomobject]@{ Path = $projectFile; Type = $type }
}

# Resolve a pubxml <PublishUrl> into the two display lines tp-publish prints (KTD8):
# the raw absolute path and a file:/// URL. For a FileSystem publish a relative PublishUrl is
# resolved against the project directory, the trailing backslash is trimmed, and the file:/// URL
# is the same path with backslashes flipped to forward slashes. For non-FileSystem methods (FTP,
# etc.) there is no local path, so both values are the URL as-is. Neither value carries trailing
# punctuation — the caller emits them verbatim for the agent to relay (no prose, no period), so the
# terminal renders them as clickable. Factored out of Publish-Web.ps1 so the two-line format is
# unit-testable without running MSBuild.
# Returns @{ Resolved = <raw path/url>; DisplayPath = <file:/// or url>; IsFileSystem = <bool> }.
function Get-PublishOutputLines {
    param(
        [Parameter(Mandatory = $true)][string]$PublishUrlRaw,
        [string]$Method = 'FileSystem',
        [string]$ProjectDir = ''
    )
    $isFileSystem = ($Method -eq 'FileSystem')
    if ($isFileSystem) {
        if ([System.IO.Path]::IsPathRooted($PublishUrlRaw)) {
            $resolved = [System.IO.Path]::GetFullPath($PublishUrlRaw)
        } else {
            $resolved = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($ProjectDir, $PublishUrlRaw))
        }
        $resolved = $resolved.TrimEnd('\')
        $displayPath = 'file:///' + ($resolved -replace '\\', '/')
    } else {
        $resolved = $PublishUrlRaw
        $displayPath = $PublishUrlRaw
    }
    return @{ Resolved = $resolved; DisplayPath = $displayPath; IsFileSystem = $isFileSystem }
}

# Resolve the project root these scripts act on (the folder holding `.turbo-plugin/`).
#
# Omitted -RepoRoot keeps the historical behaviour exactly: act on the current directory. Supplied,
# it names the target outright -- which is what makes a multi-project workspace usable, where the
# session sits at a root holding several sibling projects and `cd`-ing into one is both fragile and
# invisible in the transcript. Mirrors -RepoRoot in the git-svn scripts; validation (Git Bash
# /c/foo normalisation + "is it really a directory") comes from Core's Resolve-GitRoot, so a typo
# fails naming the argument instead of surfacing later as a confusing missing-csproj error.
#
# NOT Get-MainWorktree: these scripts operate on a project folder, which need not be a git worktree
# root (and Build/Publish work fine outside git entirely).
function Resolve-DotnetRepoRoot {
    param([string]$RepoRoot = '')
    $resolved = Resolve-GitRoot -RepoRoot $RepoRoot
    if ($resolved -eq '.') { return (Get-Location).Path }
    return $resolved
}

# Read a single MSBuild property out of any MSBuild XML file -- a .pubxml (publish reads
# <Configuration>) or a .csproj (run reads <OutputType> to tell a console project from a web one).
# Returns '' when the file is unreadable or the property is absent; callers treat '' as "no value".
#
# Case-insensitive on the element name for the same reason the PublishUrl lookup in Publish-Web.ps1
# is: XPath local-name() is case-sensitive and VS emits a mix of casings across pubxml versions.
# Last occurrence wins (matches MSBuild's last-definition-wins property semantics).
function Get-MsbuildProperty {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $lower = $Name.ToLowerInvariant()
    $xpath = "//*[translate(local-name(),'ABCDEFGHIJKLMNOPQRSTUVWXYZ','abcdefghijklmnopqrstuvwxyz')='$lower']"
    $nodes = @()
    try {
        $nodes = @(Select-Xml -Path $Path -XPath $xpath | ForEach-Object { $_.Node })
    } catch {
        return ''
    }
    if ($nodes.Count -eq 0) { return '' }
    return $nodes[$nodes.Count - 1].InnerText.Trim()
}

# ─── [frontend] group resolution (issue #125) ───────────────────────────────────
#
# A repo has ONE .turbo-plugin/config.toml but may hold many Web projects, and the old single
# [frontend] was applied no matter which project was being built. That failed silently in BOTH
# directions at once: the target project's frontend was never packed, and some OTHER project's
# pack ran -- successfully, in its own directory, so nothing errored -- while the result template
# reported 已執行. The only way to notice was a downstream "why is this page dead after deploy".
#
# Two forms are supported:
#
#   [frontend]                          the bare group. Unchanged, and it still applies to
#                                       whatever is being built, so single-project repos (the
#                                       overwhelming majority) behave exactly as before.
#   [frontend."src/proj-1/Proj1.Web"]   a keyed group. Applies ONLY when the resolved target is
#                                       that project.
#
# The section name arrives verbatim from Core's TOML reader -- it does not parse dotted/quoted
# keys and does not need to, because the whole header string is the section name. So
# `frontend."x"` is simply a section whose name starts with `frontend.`.
#
# Once ANY keyed group exists the bare group stops being a catch-all: a project with no group of
# its own gets NO pack, reported as such. Falling back would reinstate exactly the bug above.
#
# Status values, and why they are distinct rather than collapsed into "no dir":
#   ready      a pack will run.
#   unset      nothing is configured for this target. Normal, and says so.
#   disabled   an applicable group exists with enabled = false. Deliberate, not absence.
#   unmatched  keyed groups exist but none names this target. SUSPICIOUS -- someone set frontend
#              up for this repo and this project is not covered, which is a different thing from
#              "this repo does no frontend work" and must not read the same (issue #30's lesson).
#   foreign    a bare group applies but its dir is not under the target project's directory. It
#              still runs -- silencing it would change behaviour for existing single-project
#              repos, which is not this change's business -- but the report says so, because in a
#              multi-project repo this is precisely the silent mis-pack described above.

# Comparable form for path equality on Windows: separators unified, trailing separator dropped,
# case folded. Windows paths are case-insensitive, and `src/web` vs `src\web\` vs `SRC\Web` are
# the same place -- a plain string compare answers "no" for all three and does it silently.
function ConvertTo-ComparablePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    return ($Path -replace '/', '\').TrimEnd('\').ToLowerInvariant()
}

# The value for MSBuild's /p:SolutionDir, with the trailing separator the $(SolutionDir) convention
# expects.
#
# The packages.config `<HintPath>..\packages\...` convention is anchored on the SOLUTION directory.
# That is the same place as the repo root only in a single-solution repo; in a mono repo each
# sub-project owns its own .sln and its own packages\, so anchoring on the repo root restores into
# <repo>\packages\ while every HintPath points at <repo>\<sub>\packages\ (issue #132).
#
# What made that hard to diagnose: build passes the .sln, so SolutionDir was already derived
# correctly there, while publish only ever takes a csproj and fell back to the repo root. The same
# sub-project therefore BUILT fine and FAILED to publish, and MSBuild's message named a missing
# NuGet package -- pointing at restore, not at this argument.
#
# Resolution: a .sln answers with its own directory. A csproj walks UP from the project directory
# to the nearest .sln, which is the solution VS would have open for it. No .sln on that walk falls
# back to the repo root -- the historical answer, so a repo with no .sln at all is unaffected.
#
# The walk never leaves the repo. A .sln sitting ABOVE the repo root is not this repo's business,
# and following one would make the answer depend on where the repo happens to be checked out.
function Resolve-SolutionDir {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [switch]$IsSolution
    )

    if ($IsSolution) {
        return ([System.IO.Path]::GetDirectoryName($TargetPath).TrimEnd('\') + '\')
    }

    $rootCmp = ConvertTo-ComparablePath $RepoRoot
    $dir = [System.IO.Path]::GetDirectoryName($TargetPath)
    while (-not [string]::IsNullOrWhiteSpace($dir)) {
        $dirCmp = ConvertTo-ComparablePath $dir
        if ($dirCmp -ne $rootCmp -and -not $dirCmp.StartsWith($rootCmp + '\')) { break }
        # @() because a single match unrolls to the FileInfo itself, whose .Count is not the number
        # of matches.
        if (@(Get-ChildItem -LiteralPath $dir -Filter '*.sln' -File -ErrorAction SilentlyContinue).Count -gt 0) {
            return ($dir.TrimEnd('\') + '\')
        }
        if ($dirCmp -eq $rootCmp) { break }
        $parent = [System.IO.Path]::GetDirectoryName($dir)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return ($RepoRoot.TrimEnd('\') + '\')
}

# ─── per-project config groups ─────────────────────────────────────────────────
# `[<section>."<project path>"]` scopes a section's settings to one sub-project. Introduced for
# [frontend] (issue #125) and extended to [build] / [publish] (issue #133) unchanged: one repo
# holding several sub-projects is the mainline layout now that multi-repo-workspace is retired,
# and one flat [build] cannot hold two sub-projects whose .sln offer different platforms.
#
# The three helpers below are section-agnostic on purpose. Three sections sharing one spelling of
# "which sub-project is this for" is the whole value to the user; a second, subtly different
# matcher would be a rule they cannot see.

# Section names of the keyed groups under $Section, as written in config.toml.
function Get-ConfigGroupSections {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Section
    )

    $cfg = Get-TurboPluginConfig -RepoRoot $RepoRoot
    return @($cfg.Keys | Where-Object { $_ -like "$Section.*" } | Sort-Object)
}

# The project path a keyed section names: `frontend."x"` -> `x`.
# Quotes are optional so `[frontend.src/web]` -- what people write first -- also works.
function Get-ConfigGroupKey {
    param(
        [Parameter(Mandatory = $true)][string]$Section,
        [Parameter(Mandatory = $true)][string]$Parent
    )

    $k = $Section.Substring("$Parent.".Length).Trim()
    if ($k.Length -ge 2 -and $k.StartsWith('"') -and $k.EndsWith('"')) {
        return $k.Substring(1, $k.Length - 2)
    }
    if ($k.Length -ge 2 -and $k.StartsWith("'") -and $k.EndsWith("'")) {
        return $k.Substring(1, $k.Length - 2)
    }
    return $k
}

# A group key may name the project FILE or the directory that holds it; both are things a user
# would reasonably write, and `--project` accepts both spellings too.
#
# It does NOT match deeper: `proj-1` does not own `proj-1/src/Web/Web.csproj`. Ownership by
# containment would need a "the deepest group wins" rule on top, and that rule only ever shows up
# once two groups already overlap -- by which point the user is reading a config file whose
# effective values they cannot see. Exact-or-parent means the key you read is the key that matched.
function Test-ConfigGroupMatchesTarget {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$GroupKey,
        [Parameter(Mandatory = $true)][string]$TargetProject
    )

    $keyAbs = ConvertTo-ComparablePath (Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $GroupKey)
    if ([string]::IsNullOrWhiteSpace($keyAbs)) { return $false }
    $targetAbs = ConvertTo-ComparablePath $TargetProject
    $targetDir = ConvertTo-ComparablePath ([System.IO.Path]::GetDirectoryName($TargetProject))
    return ($keyAbs -eq $targetAbs) -or ($keyAbs -eq $targetDir)
}

# Which keyed group under $Section applies to $TargetProject.
#
# Returns Section (the config section to read from), Key (the group key, '' for the bare section)
# and Status:
#   none       the section has no keyed groups at all -- a single-project repo, unchanged
#   ready      a keyed group names this target
#   unmatched  keyed groups exist but none names this target; the bare section still supplies every
#              value (see Resolve-GroupedConfigValue), so this is not an error -- but it IS reported,
#              because "I wrote a group for this project and it did nothing" has to be visible
#
# Status is deliberately NOT a behaviour switch for build/publish: it exists so the result template
# can say which group was used. [frontend] is the exception and keeps its own stricter rules, where
# 'unmatched' means run nothing (packing another project's frontend is worse than not packing).
function Resolve-ConfigGroup {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$Section,
        [string]$TargetProject = ''
    )

    # @() at the CALL SITE: an empty array returned from a PowerShell function unrolls to $null and
    # a one-element array unrolls to the element, whose .Count would be a string length.
    $sections = @(Get-ConfigGroupSections -RepoRoot $RepoRoot -Section $Section)
    if ($sections.Count -eq 0) {
        return [PSCustomObject]@{ Section = $Section; Parent = $Section; Key = ''; Status = 'none' }
    }
    if ([string]::IsNullOrWhiteSpace($TargetProject)) {
        return [PSCustomObject]@{ Section = $Section; Parent = $Section; Key = ''; Status = 'unmatched' }
    }
    $matched = @($sections | Where-Object {
        Test-ConfigGroupMatchesTarget -RepoRoot $RepoRoot -GroupKey (Get-ConfigGroupKey -Section $_ -Parent $Section) -TargetProject $TargetProject
    })
    if ($matched.Count -eq 0) {
        return [PSCustomObject]@{ Section = $Section; Parent = $Section; Key = ''; Status = 'unmatched' }
    }
    if ($matched.Count -gt 1) {
        # Typically one group written by directory and one by .csproj. Picking the "more specific"
        # one would be a silent guess about which the user meant.
        throw ("Ambiguous [$Section] configuration: $($matched.Count) groups all name '$TargetProject' " +
               "($($matched -join ', ')). Keep exactly one group per project.")
    }
    return [PSCustomObject]@{
        Section = $matched[0]
        Parent  = $Section
        Key     = (Get-ConfigGroupKey -Section $matched[0] -Parent $Section)
        Status  = 'ready'
    }
}

# One setting, resolved through the group layering: CLI > this project's group > the bare section >
# default.
#
# Per-KEY layering, not whole-group replacement: `configuration` is usually the same across a repo
# while `platform` is not, so requiring every group to restate the shared values would mean editing
# N places to change one thing -- and missing one of them is silent.
function Resolve-GroupedConfigValue {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)]$Group,
        [Parameter(Mandatory = $true)][string]$Key,
        $CliValue = $null,
        $Default = $null
    )

    if ($null -ne $CliValue -and -not ([string]::IsNullOrWhiteSpace([string]$CliValue))) {
        return $CliValue
    }
    if ($Group.Status -eq 'ready') {
        $fromGroup = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $Group.Section -Key $Key -CliValue $null -Default $null
        if ($null -ne $fromGroup -and -not ([string]::IsNullOrWhiteSpace([string]$fromGroup))) {
            return $fromGroup
        }
    }
    # The bare section is the base layer, so a group that omits a key inherits it. Parent is carried
    # on the descriptor rather than recovered by splitting Section on '.', because a group key is a
    # PATH and may well contain dots.
    return Resolve-ConfigValue -RepoRoot $RepoRoot -Section $Group.Parent -Key $Key -CliValue $null -Default $Default
}

# Single source of truth for "will a frontend pack run, from which config group, against which
# directory, and if not -- why not".
#
# Build-Web / Publish-Web use it to fill the result template's Frontend line and Compress-Content
# uses it to decide whether to act, so the template can never claim a pack that did not happen --
# which is the whole point: the silent skip in issue #30 was invisible precisely because reporting
# and behaviour were decided in different places.
#
# `enabled = false` is an explicit opt-out and WINS over a configured dir (mirrors the existing
# `[iis] enabled` switch), so a project can keep its frontend settings while turning the step off.
# tp-build / tp-publish also write it as the "already asked, user said no" marker.
#
# $TargetProject is the RESOLVED project/solution path. Omitting it means "no target in view",
# and what that implies depends on how the repo is configured:
#
#   keyed groups exist  -> 'unmatched'. There is no way to tell WHICH group applies, and falling
#                          back to the bare group would pick one arbitrarily -- the precise
#                          mis-pack this function exists to prevent. Running nothing is the only
#                          answer that cannot be wrong.
#   no keyed groups     -> the bare group applies, with the containment check skipped (there is
#                          nothing to measure containment against).
#
# All three callers always pass it; this path is what a future caller gets if it forgets.
function Resolve-FrontendGroup {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$TargetProject = ''
    )

    $none = { param($Status) [PSCustomObject]@{ Section = ''; Key = ''; Dir = ''; Status = $Status; TargetDir = '' } }
    # Group selection is the shared one (Resolve-ConfigGroup), including its ambiguity throw. What
    # stays FRONTEND-SPECIFIC is everything after it: 'unmatched' means run nothing, and `enabled` /
    # `dir` are read from the matched section ALONE -- no layering onto the bare group. Inheriting
    # `dir` would point one project's pack at another project's directory, which is precisely the
    # silent mis-pack this function exists to prevent (issue #125).
    $group = Resolve-ConfigGroup -RepoRoot $RepoRoot -Section 'frontend' -TargetProject $TargetProject
    if ($group.Status -eq 'unmatched') { return (& $none 'unmatched') }
    $hasKeyedGroups = ($group.Status -ne 'none')
    $section = $group.Section
    $key = $group.Key

    $enabled = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $section -Key 'enabled' -CliValue $null -Default $true
    if ($enabled -eq $false) {
        return [PSCustomObject]@{ Section = $section; Key = $key; Dir = ''; Status = 'disabled'; TargetDir = '' }
    }

    $dir = Resolve-ConfigValue -RepoRoot $RepoRoot -Section $section -Key 'dir' -CliValue $null -Default $null
    if ($null -eq $dir) { return (& $none 'unset') }
    $dir = [string]$dir

    # Containment applies to the BARE group only. A keyed group's key IS its statement of
    # ownership, so second-guessing where it points would just add a rule the user cannot see.
    $status = 'ready'
    $targetDirDisplay = ''
    if (-not $hasKeyedGroups -and -not [string]::IsNullOrWhiteSpace($TargetProject)) {
        # A .sln legitimately spans projects, and its directory is usually the repo root, so this
        # check neutralises itself there rather than crying wolf on every solution build.
        $targetDirRaw = [System.IO.Path]::GetDirectoryName($TargetProject)
        $dirAbs = ConvertTo-ComparablePath (Resolve-RepoPath -RepoRoot $RepoRoot -PathValue $dir)
        $targetDirCmp = ConvertTo-ComparablePath $targetDirRaw
        if ($targetDirCmp -ne '' -and $dirAbs -ne '' -and
            $dirAbs -ne $targetDirCmp -and -not $dirAbs.StartsWith($targetDirCmp + '\')) {
            $status = 'foreign'
            $targetDirDisplay = $targetDirRaw
        }
    }
    return [PSCustomObject]@{ Section = $section; Key = $key; Dir = $dir; Status = $status; TargetDir = $targetDirDisplay }
}

# Thin wrapper kept because "the directory a pack will use, or '' for none" is what most callers
# actually want, and because it keeps the reporting/behaviour single-source property explicit.
function Resolve-FrontendPackDir {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$TargetProject = ''
    )

    return (Resolve-FrontendGroup -RepoRoot $RepoRoot -TargetProject $TargetProject).Dir
}

# ─── per-operation result-template family (KTD5) ────────────────────────────────
# Each Format-*ResultLines helper returns the ORDERED display lines the executor prints under
# its result marker. The agent relays the block as the fixed per-operation result template:
# the inputs the agent chose + the target the executor actually RESOLVED (the 糾錯閘, so the
# user sees which project was acted on) + the produced artifacts (URL / publish path / site).
# Helpers compute/format lines only; the executor owns the marker line + Write-Output and the
# success/fail line (mirrors the existing Get-PublishOutputLines / PUBLISH_OUTPUT split). The
# template reports AGENT-SUPPLIED values, never MSBuild-evaluated effective values — a config
# the agent left unspecified is shown as MSBuild/solution-decided, not fabricated as Debug.

# Note for a configuration/platform the agent left unspecified (executor omits /p:, VS-aligned).
function Get-UnspecifiedConfigNote {
    return '未指定 (由 MSBuild / solution / Directory.Build.props 決定)'
}

# Frontend-pack status, shared by the build and publish templates.
#
# This belongs IN the template rather than being left to Compress-Content's own stdout: the SKILLs
# tell the agent to relay the marker block verbatim as the result, so anything printed outside it
# is effectively invisible to the user. That is exactly how an unconfigured [frontend] came to be
# skipped in complete silence -- the skip message existed, but nothing was ever going to repeat it
# (issue #30). Projects with no frontend step still get a line, so "未設定" is an explicit
# statement rather than the absence of one.
# Takes the whole Resolve-FrontendGroup descriptor rather than just the directory: the four
# non-running outcomes are NOT interchangeable, and collapsing them into one 未設定 line is what
# made the original silent skip invisible. In particular `unmatched` -- frontend is configured for
# this repo but no group names this project -- is a suspicious state, while `unset` is a normal
# one, and a reader has to be able to tell them apart from the result template alone.
# Which config group supplied this run's settings, for the build/publish result templates.
#
# Returns $null -- and the caller emits NOTHING -- when the section has no groups at all. A
# single-project repo has one obvious answer, and a line restating it on every build would be noise
# that trains the reader to skip the block. Once groups EXIST the line is always emitted, including
# the 'no group matched' case: "I wrote a group for this project and it did nothing" is exactly the
# state a user cannot otherwise see, because the build still succeeds with the shared values.
function Format-ConfigGroupLine {
    param($Group, [string]$Label)

    if ($null -eq $Group -or $Group.Status -eq 'none') { return $null }
    if ($Group.Status -eq 'ready') {
        return ($Label + ': [' + $Group.Parent + '."' + $Group.Key + '"] (未寫在分組裡的項目沿用共用的 [' + $Group.Parent + '])')
    }
    return ($Label + ': 無對應分組,全部使用共用的 [' + $Group.Parent + ']')
}

function Format-FrontendStatusLine {
    param($Group)

    $none = 'Frontend: 未設定 (未執行前端打包)'
    if ($null -eq $Group) { return $none }
    switch ($Group.Status) {
        'ready' {
            if ([string]::IsNullOrWhiteSpace($Group.Key)) { return "Frontend: 已執行 ($($Group.Dir))" }
            return 'Frontend: 已執行 (' + $Group.Dir + ',設定來自 [frontend."' + $Group.Key + '"])'
        }
        'foreign' {
            return ('Frontend: 已執行 (' + $Group.Dir + ')。警告:這個目錄不在目標專案 (' + $Group.TargetDir +
                    ') 底下。[frontend] 只有一組,會套用到任何被建置的專案——一個 repo 裡有多個 Web 專案時,' +
                    '請改成以專案路徑為鍵的 [frontend."<專案路徑>"] 分組。')
        }
        'disabled'  { return 'Frontend: 已停用 (enabled = false,未執行前端打包)' }
        'unmatched' { return 'Frontend: 未設定 (config.toml 有 [frontend."..."] 分組,但沒有一組對應這個專案——未執行前端打包)' }
        default     { return $none }
    }
}

function Format-BuildResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedTarget,
        [string]$Configuration = '',
        [string]$Platform = '',
        $FrontendGroup = $null,
        $BuildGroup = $null,
        [switch]$IsSolution
    )
    $note = Get-UnspecifiedConfigNote
    $lines = @()
    $lines += if ($IsSolution) { "Target: $ResolvedTarget (整個 solution)" } else { "Target: $ResolvedTarget" }
    $lines += if ([string]::IsNullOrWhiteSpace($Configuration)) { "Configuration: $note" } else { "Configuration: $Configuration" }
    $lines += if ([string]::IsNullOrWhiteSpace($Platform)) { "Platform: $note" } else { "Platform: $Platform" }
    $groupLine = Format-ConfigGroupLine -Group $BuildGroup -Label '設定分組'
    if ($null -ne $groupLine) { $lines += $groupLine }
    $lines += Format-FrontendStatusLine -Group $FrontendGroup
    return $lines
}

function Format-RunResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedTarget,
        [Parameter(Mandatory = $true)][string]$WebUrl
    )
    # URL stays bare at end of line so the terminal keeps it clickable (no trailing punctuation).
    return @("Target: $ResolvedTarget", "URL: $WebUrl")
}

# A console run has no URL, so it reports what it actually produced instead: which exe ran, and
# either the exit code (one-shot, the common shape -- a report tool, a migration) or the PID and
# log path (still running past the wait). Same 糾錯閘 lead as the rest of the family: Target is the
# csproj the executor RESOLVED, so the user can see it acted on the project they meant.
function Format-ConsoleRunResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$ResolvedTarget,
        [Parameter(Mandatory = $true)][string]$ExePath,
        [int]$ExitCode = -1,
        [int]$ProcessId = 0,
        [string]$LogPath = ''
    )
    $lines = @("Target: $ResolvedTarget", "Executable: $ExePath")
    if ($ProcessId -gt 0) {
        $lines += "Status: still running (PID $ProcessId)"
        # Bare path on its own line, no trailing punctuation, so the terminal keeps it clickable.
        if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
            $lines += 'Output so far:'
            $lines += $LogPath
        }
    } else {
        $lines += "Exit code: $ExitCode"
    }
    return $lines
}

# "Stopped" is stated explicitly rather than implied, because "nothing was running" is the NORMAL
# outcome for a one-shot console project and must not read as a failure.
function Format-ConsoleStopResultLines {
    param(
        [string]$ResolvedTarget = '',
        [bool]$Stopped = $false,
        [int]$ProcessId = 0
    )
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($ResolvedTarget)) { $lines += "Target: $ResolvedTarget" }
    if ($Stopped) {
        $lines += "Stopped: yes (PID $ProcessId)"
    } else {
        $lines += 'Stopped: nothing was running'
    }
    return $lines
}

function Format-StopResultLines {
    param(
        [Parameter(Mandatory = $true)][string]$Site,
        [string]$ResolvedTarget = ''
    )
    # "Site" is neutral (the site this stop targeted) so the template reads correctly whether a
    # process was actually stopped or none was found — the executor's own line conveys the action.
    $lines = @()
    if (-not [string]::IsNullOrWhiteSpace($ResolvedTarget)) { $lines += "Target: $ResolvedTarget" }
    $lines += "Site: $Site"
    return $lines
}

function Remove-PerLaunchTempFile {
    <#
    .SYNOPSIS
        Delete one per-launch temp file (a rendered .config, or a redirected .out.log / .err.log),
        tolerating the brief window right after a kill where the file is still held open.

    .DESCRIPTION
        Stop-Process only *requests* termination and returns immediately -- the OS releases the
        process's inherited stdout/stderr handles a moment later. Deleting straight after the kill
        therefore races that teardown and loses: observed in practice as "the .config went away but
        both .log files stayed", which then made cleanup-orphan-iis announce leftovers after a
        perfectly clean stop, with no way for the user to tell that apart from "something really is
        still running".

        Callers should ALSO wait for the process itself to exit (Wait-Process) -- that removes the
        cause. This retry only covers the tail where the handle outlives the process object.

        Lives in Common (not IisHelpers) because both launchers hit it: IIS Express and the console
        runner redirect their output the same way, and the console script must not have to load IIS
        helpers to get a fix that has nothing to do with IIS.

        Returns an object with Removed (bool) and Error (last failure message, $null on success).
        A file that is already absent counts as removed. Never throws: the caller decides how loud
        a genuine, persistent lock should be.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$RetryCount = 10,
        [int]$RetryDelayMilliseconds = 100
    )

    $attempts = [Math]::Max(1, $RetryCount)
    $lastError = $null

    for ($i = 0; $i -lt $attempts; $i++) {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            return [pscustomobject]@{ Removed = $true; Error = $null }
        }
        try {
            # [System.IO.File]::Delete, NOT Remove-Item -- and this is a bug fix, not a preference.
            #
            # PowerShell still runs its own path resolution under -LiteralPath, and that resolution
            # mangles a `~`. Every temp path contains one on a machine whose user profile has an 8.3
            # short name (C:\Users\MELWU~1\AppData\Local\Temp is what GetTempPath() returns there),
            # so the call throws
            #   An object at the specified path C:\Users\MELWU~1 does not exist
            # while the file plainly does. It is an argument-transformation error, so -ErrorAction
            # cannot suppress it either: callers that wrapped it in `catch { }` leaked the file
            # silently, and this retry loop burned its full delay before reporting a message that
            # contradicts itself. The .NET call takes the string exactly as given.
            # Test-Path is NOT affected (measured) and stays as the existence check.
            [System.IO.File]::Delete($Path)
            return [pscustomobject]@{ Removed = $true; Error = $null }
        } catch {
            $lastError = $_.Exception.Message
        }
        # Don't sleep after the final attempt -- that delay buys nothing and only makes a
        # genuinely stuck file cost the user an extra tick before the honest report.
        if ($i -lt ($attempts - 1)) { Start-Sleep -Milliseconds $RetryDelayMilliseconds }
    }

    return [pscustomobject]@{ Removed = $false; Error = $lastError }
}

# Component-wise numeric version compare. Missing components count as 0, so 18 == 18.0.0 and
# 18.20 > 18.4 (which a string compare gets backwards). Returns -1 / 0 / 1.
function Compare-DottedVersion {
    param(
        [Parameter(Mandatory = $true)][int[]]$Left,
        [Parameter(Mandatory = $true)][int[]]$Right
    )
    $count = [Math]::Max($Left.Count, $Right.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $l = 0
        $r = 0
        if ($i -lt $Left.Count) { $l = $Left[$i] }
        if ($i -lt $Right.Count) { $r = $Right[$i] }
        if ($l -lt $r) { return -1 }
        if ($l -gt $r) { return 1 }
    }
    return 0
}

# Does the running Node satisfy the [frontend] node_version requirement?
#
# Accepted forms (leading `v` and surrounding spaces optional):
#   18 / 18.20.8      exact MAJOR match  -- `18` accepts v18.20.8. This is the historical meaning
#                     of a bare value and is kept so existing configs do not change behaviour.
#   >=16 / >=16.0.0   minimum, compared numerically over the components actually written
#   >16 / <=20 / <20  same, other directions
#
# npm range syntax (^18, ~18, `||` unions, hyphen ranges) is REJECTED with a message rather than
# guessed at. Silently misreading a requirement is what made issue #49 so hard to diagnose.
#
# The bug it replaces: the old code did Split('.')[0] on the requirement, so ">=16.0.0" yielded the
# literal ">=16", which was string-compared against "18" and never matched -- so EVERY Node version
# was rejected, while the message still read "Required major: >=16.0.0". That phrasing points at
# the Node install, so the natural response is to go switch Node versions, which cannot ever help.
#
# Returns $true/$false. Throws only when the requirement (or the reported Node version) cannot be
# parsed at all -- an unusable config should fail loudly, not quietly reject everything.
function Test-NodeVersionSatisfied {
    param(
        [Parameter(Mandatory = $true)][string]$CurrentVersion,
        [Parameter(Mandatory = $true)][string]$Requirement
    )

    $operator = ''
    $requiredText = $Requirement.Trim()
    # Split the comparator off first rather than making it an optional regex group: under
    # StrictMode a non-participating group is an awkward thing to read back out of $Matches.
    if ($requiredText -match '^(>=|<=|>|<|=)\s*(.*)$') {
        $operator = $Matches[1]
        $requiredText = $Matches[2].Trim()
    }
    $requiredText = $requiredText -replace '^v', ''
    if ($requiredText -notmatch '^\d+(\.\d+)*$') {
        throw ("Unsupported [frontend] node_version: '$Requirement'. Use an exact major (18) or a " +
               "comparison (>=16, >=16.0.0, >16, <=20, <20). npm range syntax such as ^18, ~18, " +
               "unions (||) and hyphen ranges are not supported.")
    }
    $requiredParts = @($requiredText.Split('.') | ForEach-Object { [int]$_ })

    $currentText = ($CurrentVersion -replace '^\s*v', '').Trim()
    if ($currentText -notmatch '^(\d+(\.\d+)*)') {
        throw "Unable to parse the running Node version: '$CurrentVersion'."
    }
    $currentParts = @($Matches[1].Split('.') | ForEach-Object { [int]$_ })

    if ([string]::IsNullOrEmpty($operator) -or $operator -eq '=') {
        return ($currentParts[0] -eq $requiredParts[0])
    }

    $comparison = Compare-DottedVersion -Left $currentParts -Right $requiredParts
    if ($operator -eq '>=') { return ($comparison -ge 0) }
    if ($operator -eq '>')  { return ($comparison -gt 0) }
    if ($operator -eq '<=') { return ($comparison -le 0) }
    if ($operator -eq '<')  { return ($comparison -lt 0) }
    return $false
}

