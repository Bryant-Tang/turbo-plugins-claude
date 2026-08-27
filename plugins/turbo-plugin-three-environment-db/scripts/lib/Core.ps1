Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Force UTF-8 for both PS host output and how PS interprets native command stdout/stderr.
# Without this, Windows PowerShell 5.1 uses the system code page (Big5 / CP950 on Chinese
# Windows), and output from native exes (svn / msbuild / iisexpress) that emit UTF-8
# bytes renders as mojibake (`?` chars or garbage). Affects every script that
# dot-sources Core.ps1 (directly, or transitively via a concern lib).
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8
# Also read console input as UTF-8. Guarded: in non-interactive / redirected contexts
# (CI, piped stdin — no console input handle) assigning InputEncoding throws; swallow
# it. The OutputEncoding settings above are the load-bearing part.
try { [Console]::InputEncoding = [System.Text.Encoding]::UTF8 } catch { }

# Run a READ-ONLY git command and hand back its stdout together with the exit code.
#
# Why this exists instead of calling git inline: Windows PowerShell 5.1 turns ANY stderr output
# from a native command whose output is CAPTURED into a terminating NativeCommandError while
# $ErrorActionPreference = 'Stop' — and `2>$null` does NOT prevent it. git writes to stderr in
# perfectly healthy situations while still exiting 0; the everyday instance is
# `warning: detected dubious ownership in repository`, which is the normal state of a repo owned
# by another account — CI images, containers, and any machine where the clone was made under a
# different user. Callers that wrapped the inline call in try/catch therefore read a warning as
# "the command failed" and reported the exact opposite of the truth (issue #123: a healthy repo
# answering `Not inside a git repository.`), with nothing in the message pointing at the cause.
#
# Dropping $ErrorActionPreference to 'Continue' for the duration of the call is what makes
# $LASTEXITCODE reachable — it is the piece that keeps a stderr write from pre-empting the
# exit-code check. That restores the parity the bash half gets for free from `2>/dev/null || true`.
#
# $LASTEXITCODE is pre-seeded to 127 (the shell's command-not-found convention) because a `git`
# that is not on PATH never runs and so never sets it: without the seed the helper would report
# whatever the previous native command left behind, and under StrictMode an unset $LASTEXITCODE
# is itself an error. The `2>$null` also swallows the CommandNotFoundException record, so that
# case surfaces as Code=127 with empty Text rather than as console noise.
#
# STATE-CHANGING git calls must NOT go through this: they want EAP=Stop's fail-loud behaviour.
function Read-Git {
    param(
        [string]$Cwd = '',
        [Parameter(Mandatory = $true)][string[]]$GitArgs
    )

    $argv = @()
    if (-not [string]::IsNullOrWhiteSpace($Cwd)) { $argv += @('-C', $Cwd) }
    $argv += $GitArgs

    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $text = ''
    $code = 127
    try {
        $global:LASTEXITCODE = 127
        $text = (& git @argv 2>$null | Out-String)
        $code = $global:LASTEXITCODE
    } catch {
        $text = ''
        $code = 127
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($null -eq $code) { $code = 127 }

    return [PSCustomObject]@{ Text = $text; Code = $code }
}

function Probe-GitVersion {
    $probe = Read-Git -GitArgs @('--version')
    $raw = $probe.Text.Trim()
    # Empty output is part of the test, not redundant with the exit code: a `git` missing from
    # PATH leaves Code at the 127 seed, but so would any future change to how the miss is
    # detected — an unparseable empty string must never reach the version regex below.
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($raw)) {
        throw 'git CLI not available on PATH.'
    }
    if ($raw -notmatch 'git version (\d+)\.(\d+)') {
        throw "Unable to parse git version from '$raw'."
    }
    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 2 -or ($major -eq 2 -and $minor -lt 31)) {
        throw "Git >= 2.31 is required (for --path-format=absolute). Detected: $raw. Please upgrade."
    }
}

function Get-NormalizedAbsolutePath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Get-NormalizedAbsolutePath: empty path.'
    }

    if ($Path -match '^/([a-zA-Z])/(.*)$') {
        $Path = "$($Matches[1]):\$($Matches[2] -replace '/', '\')"
    }

    $resolved = $null
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        $resolved = [System.IO.Path]::GetFullPath($Path)
    }

    if ($resolved -match '^([a-zA-Z]):(.*)$') {
        $resolved = "$($Matches[1].ToString().ToLower()):$($Matches[2])"
    }

    return $resolved
}

# Resolve an optional explicit repository root into the value handed to `git -C`.
#
# Omitted / empty returns '.', and `git -C .` is a no-op — so callers that pass nothing keep the
# historical behaviour exactly: git resolves the repository by walking up from whatever directory
# the process happens to be standing in. A supplied path is normalized (Git Bash /c/foo -> c:\foo)
# and asserted to be a real directory here, so a typo fails with a message naming the argument
# instead of surfacing later as git's own "cannot change to ..." mid-operation.
#
# Why this exists: deriving the target from the ambient cwd is how the marketplace repo once got a
# bridge bootstrapped into it. Every entry script now accepts -RepoRoot so the caller can name the
# repository outright, which is also what makes a multi-project workspace (several sibling repos
# under one session root) workable.
function Resolve-GitRoot {
    param([string]$RepoRoot = '')

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
        return '.'
    }
    $normalized = Get-NormalizedAbsolutePath -Path $RepoRoot
    if (-not (Test-Path -LiteralPath $normalized -PathType Container)) {
        throw "Repo root not found (or not a directory): $RepoRoot"
    }
    return $normalized
}

function Get-MainWorktree {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    # Read-Git, not an inline call in a try/catch: the catch shape this replaced could not tell
    # "git said no such repository" from "git warned on stderr and answered anyway", so it
    # reported the latter as the former. See the note on Read-Git.
    $probe = Read-Git -Cwd $root -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $commonDir = $probe.Text.Trim()
    if ($probe.Code -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) {
        throw 'Not inside a git repository.'
    }
    $parent = [System.IO.Path]::GetDirectoryName($commonDir)
    return Get-NormalizedAbsolutePath -Path $parent
}

function Test-IsMainWorktree {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    $commonProbe = Read-Git -Cwd $root -GitArgs @('rev-parse', '--path-format=absolute', '--git-common-dir')
    $topProbe = Read-Git -Cwd $root -GitArgs @('rev-parse', '--path-format=absolute', '--show-toplevel')
    $commonDir = $commonProbe.Text.Trim()
    $topLevel = $topProbe.Text.Trim()
    # Both codes, not just the last one: the single $LASTEXITCODE check this replaced could only
    # ever see the second call, so a first call that failed was judged by the second's success.
    if ($commonProbe.Code -ne 0 -or $topProbe.Code -ne 0 -or
        [string]::IsNullOrWhiteSpace($commonDir) -or [string]::IsNullOrWhiteSpace($topLevel)) {
        return $false
    }
    $parent = Get-NormalizedAbsolutePath -Path ([System.IO.Path]::GetDirectoryName($commonDir))
    $top = Get-NormalizedAbsolutePath -Path $topLevel
    return ($parent -eq $top)
}

function Test-IsSubmodule {
    param([string]$RepoRoot = '')

    $root = Resolve-GitRoot -RepoRoot $RepoRoot
    # No exit-code test on purpose, matching is_submodule in core.sh: outside a repository git
    # fails and prints nothing, and "no superproject" is the same answer as "not a submodule".
    # It still has to go through Read-Git — otherwise a stderr warning would throw straight out
    # of a predicate that has no failure mode of its own.
    $super = (Read-Git -Cwd $root -GitArgs @('rev-parse', '--show-superproject-working-tree')).Text.Trim()
    return -not [string]::IsNullOrWhiteSpace($super)
}

function Resolve-RepoPath {
    param(
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [string]$PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return [System.IO.Path]::GetFullPath($PathValue)
    }

    $PathValue = $PathValue -replace '^\.[\\/]', ''
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $PathValue))
}

function Write-Utf8NoBom {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $enc)
}

# Compute a relative path from $From to $To, compatible with PowerShell 5.1.
# [System.IO.Path]::GetRelativePath is .NET Core / .NET 5+ only — not in .NET Framework
# (which is what powershell.exe runs on). Use System.Uri.MakeRelativeUri instead.
function Get-RelativePathSafe {
    param(
        [Parameter(Mandatory = $true)][string]$From,
        [Parameter(Mandatory = $true)][string]$To
    )
    # fix: define same-path return contract explicitly. MakeRelativeUri's
    # behavior on $From == $To is ambiguous (can return "" or "../<basename>" depending on
    # trailing-separator state); callers expecting a meaningful empty result get surprised.
    $fromTrimmed = $From.TrimEnd('\','/')
    $toTrimmed = $To.TrimEnd('\','/')
    if ($fromTrimmed -eq $toTrimmed) {
        return ''
    }
    # MakeRelativeUri needs $From treated as a directory — append a separator if missing
    # so the relative path is computed from the dir, not "as a sibling of the file".
    $fromNorm = $fromTrimmed + [System.IO.Path]::DirectorySeparatorChar
    $fromUri = New-Object System.Uri($fromNorm)
    $toUri = New-Object System.Uri($To)
    $relUri = $fromUri.MakeRelativeUri($toUri)
    $rel = [System.Uri]::UnescapeDataString($relUri.ToString())
    # MakeRelativeUri returns forward slashes; convert to OS native separator
    return $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
}

# Minimal TOML reader sufficient for the keys turbo-plugin emits in .turbo-plugin/config.toml.
# Returns a hashtable keyed by section name, where each value is a hashtable of key→value.
# Supports: [section] headers, `key = "string"`, `key = 'string'`, `key = <bool|int|float>`,
# `# comments`, and blank lines. Multi-line values, nested tables, and arrays are not handled.
#
# $ConfigPath accepts either a single string or an array of paths. When given
# multiple paths, files are read in order and merged with later paths overriding earlier
# ones at key-level (shallow per-section merge). Missing files are skipped silently.
# Typical use: pass @(config.toml, config.local.toml) so the local file (gitignored,
# machine-specific) overrides the canonical version-controlled file.
function Read-TurboPluginConfig {
    param(
        [Parameter(Mandatory = $true)]$ConfigPath
    )
    $result = @{}
    # Normalize input to array of paths so callers can pass a single string or an array.
    $paths = @($ConfigPath)

    foreach ($pathItem in $paths) {
        if ([string]::IsNullOrWhiteSpace($pathItem)) { continue }
        if (-not (Test-Path -LiteralPath $pathItem -PathType Leaf)) { continue }
        $currentSection = ''
        # -Encoding UTF8 is load-bearing. Without it, Windows PowerShell 5.1's Get-Content decodes
        # using the system ANSI code page (cp950 on zh-TW Windows), and that does not merely garble
        # non-ASCII text -- it swallows line breaks. A `[section]` header then gets merged into the
        # preceding comment line, is skipped by the StartsWith('#') test below, and every key under
        # that section silently vanishes: no parse error, no warning, the config simply behaves as
        # if it had never been written. Measured on a real config: 9 lines read back as 5.
        # Hardcoding UTF8 is correct rather than a guess -- the TOML spec requires UTF-8 -- and it
        # handles both BOM and BOM-less files on 5.1.
        $lines = Get-Content -LiteralPath $pathItem -Encoding UTF8
        foreach ($raw in $lines) {
            $line = $raw -replace '^\s+|\s+$', ''
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            if ($line.StartsWith('#')) { continue }
            # A table header may carry a trailing comment -- TOML allows it. Requiring the line to
            # END at ']' dropped the header, and with it EVERY key under that section, in silence.
            if ($line -match '^\[([^\]]+)\]\s*(#.*)?$') {
                $currentSection = $Matches[1].Trim()
                if (-not $result.ContainsKey($currentSection)) {
                    $result[$currentSection] = @{}
                }
                continue
            }
            if ($line -match '^([A-Za-z0-9_\-]+)\s*=\s*(.+)$') {
                $key = $Matches[1].Trim()
                $val = $Matches[2].Trim()
                # A quoted value ends at its closing quote, so match through the quote and allow a
                # comment after it. '#' INSIDE the quotes stays part of the value (a path may
                # contain one). Previously a quoted value with a trailing comment matched neither
                # the comment-stripping branch (it starts with a quote) nor the unquoting branch
                # (it does not end with one), so the value kept its quotes AND the comment.
                if ($val -match '^"([^"]*)"\s*(#.*)?$') { $val = $Matches[1] }
                elseif ($val -match "^'([^']*)'\s*(#.*)?$") { $val = $Matches[1] }
                else {
                    # Unquoted: the trailing inline comment is not part of the value, and only an
                    # unquoted token may be a bool/number ("true" in quotes is the string).
                    if ($val -match '^(.*?)\s+#') { $val = $Matches[1].Trim() }
                    if ($val -eq 'true') { $val = $true }
                    elseif ($val -eq 'false') { $val = $false }
                    elseif ($val -match '^-?\d+$') { $val = [int]$val }
                    elseif ($val -match '^-?\d+\.\d+$') { $val = [double]$val }
                }
                if ([string]::IsNullOrEmpty($currentSection)) {
                    if (-not $result.ContainsKey('')) { $result[''] = @{} }
                    $result[''][$key] = $val
                } else {
                    # In-place overwrite — later paths override earlier ones at key level.
                    $result[$currentSection][$key] = $val
                }
            }
        }
    }
    return $result
}

# The gitignored local config describes THIS MACHINE (tool paths, credentials), so it has no
# per-worktree meaning -- yet being gitignored is exactly what keeps it out of a newly created
# worktree. Every new worktree therefore started from defaults and the user had to re-enter
# machine settings they had already given (issue #61). Resolved once per root and cached: this
# shells out to git, and Resolve-ConfigValue is called many times in a single script run.
#
# Returns '' when there is no separate main worktree to inherit from, or when the directory is
# not a git repo at all (a plain directory is a legitimate caller -- do not throw).
$script:TpMainWorktreeCache = @{}
function Get-InheritedLocalConfigPath {
    param([string]$RepoRoot)

    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return '' }
    # Free discriminator: a linked worktree's .git is a FILE ("gitdir: ..."), so a DIRECTORY means
    # this IS the main worktree and there is nothing to inherit -- the common case never forks git.
    # An absent .git falls through: it may be a subdirectory of a worktree, and git answers that.
    if (Test-Path -LiteralPath ([System.IO.Path]::Combine($RepoRoot, '.git')) -PathType Container) { return '' }
    if (-not $script:TpMainWorktreeCache.ContainsKey($RepoRoot)) {
        $main = ''
        try { $main = Get-MainWorktree -RepoRoot $RepoRoot } catch { $main = '' }
        $script:TpMainWorktreeCache[$RepoRoot] = $main
    }
    $mainRoot = $script:TpMainWorktreeCache[$RepoRoot]
    if ([string]::IsNullOrWhiteSpace($mainRoot)) { return '' }
    $here = ''
    try { $here = Get-NormalizedAbsolutePath -Path $RepoRoot } catch { return '' }
    if ($mainRoot -eq $here) { return '' }
    return [System.IO.Path]::Combine($mainRoot, '.turbo-plugin', 'config.local.toml')
}

# The whole merged config for a repo root, as section → key → value.
#
# read config.toml first then merge config.local.toml on top of it.
# config.local.toml is gitignored (machine-specific tool paths etc.) and takes precedence.
# In a linked worktree the MAIN worktree's local config is layered in between, so machine
# settings are inherited -- but this worktree's own file still wins, so anyone who has
# deliberately set one per worktree keeps that behaviour.
#
# Resolve-ConfigValue is the right call for "give me one key"; this exists for the callers that
# must ENUMERATE sections (a plugin whose config carries a variable set of groups, keyed by
# something only the caller knows). Those callers must not rebuild the lookup chain themselves:
# the order above is load-bearing and a second copy of it would drift silently -- a config that
# resolves one way through one code path and another way through the other is exactly the kind
# of bug that shows up as "it works for me".
#
# No core.sh twin, and that is not an oversight. core.sh's reader streams and filters per key
# rather than building a table (bash has no natural return type for section → key → value), and
# the only plugin that needs enumeration is turbo-plugin-dotnet-framework, which ships no .sh
# implementations at all -- its scripts are reached through ps1-delegate.sh. A bash half here
# would be a translation with no caller.
function Get-TurboPluginConfig {
    param([string]$RepoRoot)

    $configPath      = [System.IO.Path]::Combine($RepoRoot, '.turbo-plugin', 'config.toml')
    $configLocalPath = [System.IO.Path]::Combine($RepoRoot, '.turbo-plugin', 'config.local.toml')
    $inheritedPath   = Get-InheritedLocalConfigPath -RepoRoot $RepoRoot
    $chain = if ([string]::IsNullOrWhiteSpace($inheritedPath)) {
        @($configPath, $configLocalPath)
    } else {
        @($configPath, $inheritedPath, $configLocalPath)
    }
    return Read-TurboPluginConfig -ConfigPath $chain
}

# Lookup chain: CLI arg → config.toml → inherited local → local → built-in default
#   1. $CliValue (already-resolved CLI argument; pass $null if not provided)
#   2. config.toml under repo-root .turbo-plugin/config.toml, $Section.$Key
#   3. the MAIN worktree's config.local.toml (linked worktrees only), then this root's own
#   4. $Default (built-in default; pass $null to skip)
function Resolve-ConfigValue {
    param(
        [string]$RepoRoot,
        [string]$Section,
        [string]$Key,
        $CliValue,
        $Default
    )
    if ($null -ne $CliValue -and -not ([string]::IsNullOrWhiteSpace([string]$CliValue))) {
        return $CliValue
    }
    $cfg = Get-TurboPluginConfig -RepoRoot $RepoRoot
    if ($cfg.ContainsKey($Section) -and $cfg[$Section].ContainsKey($Key)) {
        return $cfg[$Section][$Key]
    }
    if ($null -ne $Default) {
        return $Default
    }
    return $null
}
