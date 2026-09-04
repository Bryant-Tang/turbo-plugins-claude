# turbo-plugin SVN concern helpers. Core (universal helpers + the UTF-8 encoding
# preamble + StrictMode/EAP) is dot-sourced first; this concern lib must NOT reset the
# encoding Core establishes (KTD2a). All scripts source THIS file, which transitively pulls
# in Core.ps1 from the same lib/ directory.
. ([System.IO.Path]::Combine($PSScriptRoot, 'Core.ps1'))

# --- svn must NEVER prompt (single choke point) -------------------------------
# These scripts are driven by an agent / CI with no usable stdin. A prompting `svn` (conflict
# resolution, credential request, cert acceptance) does not fail -- it blocks FOREVER, which reads
# as "the script hung" and cannot be recovered or rolled back. Real incident: a bootstrap replay hit
# a tree conflict on `.gitignore` and sat in svn's interactive conflict prompt indefinitely.
#
# Shadowing `svn` here (rather than adding the flag at ~18 call sites) makes the invariant global
# and future-proof: every `& svn ...` in every script that dot-sources this lib gets it, including
# ones added later. The real executable is resolved with -CommandType Application so this function
# never recurses. $LASTEXITCODE propagates through the wrapper unchanged, so the existing
# `if ($LASTEXITCODE -ne 0)` guards and rollback blocks still work.
# NOTE: credentials must therefore already be cached -- an uncached password now fails loudly
# rather than waiting on a prompt nobody can answer.
#
# Lives in the SVN CONCERN lib, not in universal Core.ps1: Core.ps1 is the file copied
# byte-identical into every plugin (enforced by tools/verify-core-identical.sh), and an svn shim
# has no business in a plugin that never touches svn. Every script here that can invoke svn
# dot-sources THIS file, so the choke point is unchanged. Same reasoning as the earlier move of
# Get-WorktreesDir out of universal Core.

# --- svn must be new enough to have --show-item (single choke point) -----------
# `svn info --show-item` arrived in Subversion 1.9 and is used across build-svn-commit,
# checkout-svn-branch, initialize-git-svn-bridge, new-remote-bridge and this lib. On an older
# client every one of those dies with `svn: invalid option: --show-item` -- a message that says
# nothing about the actual problem, leaving the user to work out whether their environment is
# broken or the plugin is. That diagnosis time is exactly what this gate exists to remove.
#
# Not hypothetical: chocolatey's `svn` package is win32svn, last released 2015 and pinned at
# 1.8.15. It is also the likely shape of the problem in the field -- this plugin exists because a
# team is stuck on SVN, and those environments are the most likely to be running an old client.
#
# Checked ONCE per process from inside the shim, so every caller is covered without each script
# having to remember a pre-check, and the cost is one `svn --version` per run.
$script:TpSvnMinVersion = '1.9'
$script:TpSvnVersionChecked = $false

function Assert-SvnVersion {
    param([Parameter(Mandatory = $true)][string]$SvnExe)

    # try/catch around the native call: under EAP=Stop anything svn writes to stderr becomes a
    # terminating NativeCommandError before the emptiness check can run (repo CLAUDE.md, PS 5.1 #4).
    # This one deliberately calls the RAW EXE, not the `svn` shim below: it runs from inside that
    # shim's own version gate, so the shim is not usable yet. That means no --non-interactive here
    # -- harmless, because `--version` has no prompt path at all (measured: exit 0, empty stderr).
    $raw = ''
    try {
        $raw = (& $SvnExe --version --quiet 2>$null | Out-String).Trim()
    } catch {
        $raw = ''
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Could not determine the Subversion version (ran: $SvnExe --version --quiet). Subversion $script:TpSvnMinVersion or newer is required."
    }
    if ($raw -notmatch '(\d+)\.(\d+)') {
        throw "Could not parse the Subversion version from '$raw'. Subversion $script:TpSvnMinVersion or newer is required."
    }

    $major = [int]$Matches[1]
    $minor = [int]$Matches[2]
    if ($major -lt 1 -or ($major -eq 1 -and $minor -lt 9)) {
        throw @"
Subversion $script:TpSvnMinVersion or newer is required, but this client is $raw ($SvnExe).
Reason: turbo-plugin-git-svn uses 'svn info --show-item', which does not exist before 1.9;
on this client it fails with "svn: invalid option: --show-item".
Fix: install a current client -- SlikSVN or TortoiseSVN (with command line tools) on Windows.
Note: the chocolatey 'svn' package is win32svn and is pinned at 1.8.15, so it will not do.
"@
    }
}

# `svn` is SHADOWED by this function so that --non-interactive is injected at every call site,
# including ones added later. `Get-Command -CommandType Application` resolves the real exe, so
# there is no recursion. The bash twin is the `svn()` function in lib/common.sh.
#
# Why the flag is load-bearing (two separate reasons, issue #137):
#
#   1. It stops svn from HANGING. A bootstrap replay once hit a tree conflict on `.gitignore`
#      and sat in svn's interactive conflict prompt indefinitely. With --non-interactive svn
#      returns a non-zero exit instead of prompting, so the existing $LASTEXITCODE guards and
#      rollback traps do their job. (Credentials must therefore already be cached: an uncached
#      password now fails loudly rather than waiting on a prompt nobody can answer.)
#
#   2. It is ALSO what keeps the `& svn ... 2>$null` call sites safe under EAP=Stop. #128 fixed
#      the git side, where `warning: detected dubious ownership` writes to stderr on a HEALTHY,
#      exit-0 call -- under EAP=Stop the `2>` redirection then turns that into a terminating
#      NativeCommandError and the following $LASTEXITCODE guard becomes unreachable. #137 asked
#      whether svn has an equivalent. Measured on svn 1.14.5 / Windows PowerShell 5.1:
#
#        * the mechanism DOES apply to svn, and the function boundary changes nothing --
#          `& svn ... 2>$null` throws exactly like `& svn.exe ... 2>$null`;
#        * but svn's only "writes stderr while otherwise healthy" behaviour is its INTERACTIVE
#          PROMPTS (tree conflict, auth, certificate) -- and --non-interactive removes that
#          entire class. The same tree conflict that prompts (and writes the prompt to stderr)
#          exits 0 with an EMPTY stderr once the flag is present, reporting the conflict on
#          stdout instead;
#        * every other stderr write measured was a genuine failure with a non-zero exit, where
#          the existing try/catch fallbacks already produce the right answer.
#
#      So there is no `dubious ownership` analogue for svn AS THIS PLUGIN INVOKES IT, and that
#      is a property of this shim, not of svn. Two shapes DO write stderr on an otherwise fine
#      call and are NOT suppressed by --non-interactive:
#
#        * `svn status <path that is not a working copy>` -> exit 0 + `svn: warning: W155007`
#        * `svn propget <missing property>`               -> exit 1 + `svn: warning: W200017`
#
#      Both are normal conditions in this plugin, and today both call sites happen to run with
#      $ErrorActionPreference already lowered. That is COINCIDENCE, not design: a new call of
#      either shape inside an EAP=Stop region would reintroduce exactly the #128 failure. If you
#      add one, either lower EAP locally or drop the `2>` redirection.
function svn {
    $exe = (Get-Command svn -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    if (-not $script:TpSvnVersionChecked) {
        Assert-SvnVersion -SvnExe $exe
        # Set only AFTER a passing check, so a failure is re-reported on the next call instead of
        # being silently swallowed by a "already checked" flag.
        $script:TpSvnVersionChecked = $true
    }
    & $exe --non-interactive @args
}

# Granularity gate threshold (KTD7/R2/R3): per-revision SILENTLY at or below this many new
# revisions; ABOVE it the granularity choice is offered. One shared definition for Sync-FromSvn.ps1
# and Initialize-GitSvnBridge.ps1 (dot-sourced into their scope) so the two never drift.
$script:TpGranularityThreshold = 5


# Return the worktree container directory: <mainWorktree>/.turbo-plugin/worktrees.
# git-svn concern (the SVN remote worktree container) -- the SVN script pairs call this
# instead of each hardcoding a sibling path. If -MainWorktree is supplied it is used as-is;
# otherwise it is computed via Get-MainWorktree (defined in Core.ps1, sourced above).
# Guarantee `.svn/` is excluded from git for THIS repository, independent of any .gitignore.
#
# Every bridge worktree is simultaneously a git worktree and an svn working copy, and every script
# that runs `git add -A` inside one depends on this. It is not a tidiness measure: with autocrlf on,
# `git add -A` pulls the binary files under `.svn/pristine/` through the CRLF filter, and the next
# `svn commit` then fails with "Working copy text base is corrupt" -- the working copy is destroyed,
# not merely dirty (reproduced 2026-08-03).
#
# Written to info/exclude rather than a .gitignore so it holds whatever content SVN carries, and to
# the COMMON git dir because git does not read a linked worktree's own info/exclude. Idempotent.
# Let the bridge follow the platform, exactly like the main checkout and any ordinary worktree.
#
# THIS REPLACES A PIN THAT USED TO DO THE OPPOSITE, and the reversal is deliberate. Through 0.7.x
# the bridge was pinned to LF because SVN, with no svn:eol-style anywhere, stored whatever bytes it
# was handed: a bridge following the platform would have written CRLF into a repository whose other
# files were LF, invisibly, since afterwards git reports clean (it normalises on read) and svn
# reports clean (it committed exactly what was on disk). Issues #164 and #167 are that story.
#
# Now that the push path puts svn:eol-style=native on the text files it commits, the normalising
# happens on SVN's side -- so SVN holds LF and every working copy holds its own platform's endings,
# which is precisely the arrangement git already has with GitHub. Once SVN does that job, a bridge
# that behaves differently from every other working copy the user has is just a surprise with no
# remaining purpose.
#
# It UNSETS rather than merely not setting: a bridge created under 0.7.x still carries the old pin
# in its per-worktree config, and leaving it there would keep those bridges silently on the old
# behaviour forever while new ones moved on. Scoped to the bridge, so the user's own worktrees are
# untouched either way. Idempotent.
function Set-BridgeEolPlatformNative {
    param(
        [Parameter(Mandatory = $true)][string]$MainWorktree,
        [Parameter(Mandatory = $true)][string]$Bridge
    )
    # Nothing to undo unless per-worktree config was ever enabled -- and if it was not, the pin
    # cannot exist. Checked rather than enabled, so a repository that never carried the pin is not
    # given a repo-wide extension it has no use for.
    $ext = (Read-Git -Cwd $MainWorktree -GitArgs @('config', '--get', 'extensions.worktreeConfig')).Text.Trim()
    if ($ext -ne 'true') { return }

    # `--unset` on a key that is not set exits 5. That is the ordinary case for a bridge created
    # after this change, so Read-Git is used to swallow it rather than letting EAP=Stop turn a
    # normal outcome into a thrown error.
    $null = Read-Git -Cwd $Bridge -GitArgs @('config', '--worktree', '--unset', 'core.autocrlf')
    $null = Read-Git -Cwd $Bridge -GitArgs @('config', '--worktree', '--unset', 'core.eol')
}

# Which working-copy paths may carry svn:eol-style, decided by git's own EOL classification.
#
# `svn:eol-style=native` is what makes SVN behave the way GitHub does: the repository stores LF,
# and every working copy gets its platform's endings. Setting it on the wrong file is not a
# cosmetic mistake, so this picks the candidates rather than letting a caller guess:
#
#   - a BINARY file must never carry it -- svn would translate bytes that are not line endings
#   - a file with MIXED endings must never carry it -- svn refuses to commit such a file once
#     eol-style is set (E135000). A commit is atomic, so one overlooked mixed file fails the
#     whole batch; on a 20k-file tree that has to be known up front, not discovered halfway.
#
# `git ls-files --eol` answers both for the ENTIRE tree in one process, which is why it is used
# instead of a per-file content probe: on a tree this size, spawning processes per file is the
# difference between seconds and tens of minutes on Windows. Its output is
# `i/<index> w/<worktree> attr/<attrs><TAB><path>`, where the eol values are `lf`, `crlf`,
# `mixed`, `none` (no line endings at all) and `-text` (binary by git's heuristic).
#
# The WORKING-COPY column is the one that decides: svn commits the bytes on disk, so that is what
# it will accept or reject. `none` is included -- a file with no line endings has nothing to
# translate, and excluding it would leave a permanent hole in the tree's coverage.
# Echoes one object per tracked file with Bucket ('candidate', 'binary' or 'mixed') and Path.
#
# The excluded buckets are reported rather than silently dropped because the migration has to TELL
# the user which files it is leaving behind: a mixed-ending file is excluded permanently, and
# "we quietly skipped 30 files" is exactly the kind of thing discovered months later.
function Get-SvnEolClassification {
    param([Parameter(Mandatory = $true)][string]$Worktree)

    $result = Read-Git -Cwd $Worktree -GitArgs @('ls-files', '--eol')
    if ($result.Code -ne 0) {
        throw "Could not classify line endings in '$Worktree' (git ls-files --eol failed)."
    }

    $rows = New-Object System.Collections.Generic.List[psobject]
    foreach ($line in ($result.Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        # Split on the FIRST tab only: the status block never contains one, and a path may.
        $tab = $line.IndexOf("`t")
        if ($tab -lt 0) { continue }
        $status = $line.Substring(0, $tab)
        $path = $line.Substring($tab + 1)
        if ($status -notmatch 'w/(\S+)') { continue }
        $eol = $Matches[1]
        $bucket = switch ($eol) {
            'lf'    { 'candidate' }
            'crlf'  { 'candidate' }
            'none'  { 'candidate' }
            '-text' { 'binary' }
            'mixed' { 'mixed' }
            default { $null }
        }
        if ($null -ne $bucket) {
            $rows.Add([pscustomobject]@{ Bucket = $bucket; Path = $path })
        }
    }
    # Leading comma: returning an array bare lets PowerShell unwrap it, so an empty tree would
    # come back as $null and a one-file tree as a bare object.
    return , $rows.ToArray()
}

# The candidates alone, as repo-relative paths. A thin filter over the classifier above so the
# rule for what may carry the property lives in exactly one place.
function Get-SvnEolCandidate {
    param([Parameter(Mandatory = $true)][string]$Worktree)
    $paths = @(Get-SvnEolClassification -Worktree $Worktree | Where-Object { $_.Bucket -eq 'candidate' } | ForEach-Object { $_.Path })
    return , $paths
}

# Put svn:eol-style=native on the text files in a changeset that do not already carry it.
#
# This is what lets the bridge stop being pinned to LF. SVN normalises a file's line endings to LF
# when it stores it, but ONLY for files carrying svn:eol-style; without the property it stores the
# working-copy bytes verbatim. So a bridge that follows the platform -- CRLF on Windows, which is
# the whole point of the model -- would push CRLF into SVN for any file that has no property yet.
# Setting it here, BEFORE the commit, means svn does the normalising for us at commit time.
#
# Doing it per changeset rather than per tree is what makes a "have we migrated yet?" flag
# unnecessary: whatever this push touches is correct afterwards regardless of what the rest of the
# tree looks like, so an unmigrated repository degrades file by file instead of all at once.
#
# Setting a property to the value it already has is not a change as far as svn is concerned, so
# this is idempotent and adds nothing to the commit for files that are already correct.
#
# Returns the number of files it addressed.
function Set-SvnEolStyle {
    param(
        [Parameter(Mandatory = $true)][string]$Bridge,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Path
    )

    if ($Path.Count -eq 0) { return 0 }

    # Both sides are normalised to forward slashes before they meet. svn reports Windows paths with
    # backslashes while git always reports forward ones, and a separator mismatch here would not
    # error -- every path would simply fail to match and the whole step would do nothing, silently.
    $candidates = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    foreach ($c in @(Get-SvnEolCandidate -Worktree $Bridge)) {
        $null = $candidates.Add(($c -replace '\\', '/'))
    }

    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Path) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $norm = $p -replace '\\', '/'
        if ($candidates.Contains($norm)) {
            # ConvertTo-SvnTarget: a filename containing '@' is legal but makes svn read the tail
            # as a peg revision.
            $targets.Add((ConvertTo-SvnTarget -Path $norm))
        }
    }

    if ($targets.Count -gt 0) {
        $targetsFile = [System.IO.Path]::GetTempFileName()
        try {
            # Write-SvnTargetsFile, not a plain write: it uses the encoding svn reads paths back
            # in, which is what keeps non-ASCII filenames addressable (issue #35).
            Write-SvnTargetsFile -Path $targetsFile -Targets $targets.ToArray()
            Push-Location -LiteralPath $Bridge
            try {
                & svn propset svn:eol-style native --quiet --targets $targetsFile
                if ($LASTEXITCODE -ne 0) {
                    throw "Could not set svn:eol-style on $($targets.Count) file(s) in '$Bridge'."
                }
            } finally {
                Pop-Location
            }
        } finally {
            Remove-Item -LiteralPath $targetsFile -Force -ErrorAction SilentlyContinue
        }
    }

    return $targets.Count
}

function Set-SvnGitExcluded {
    param([Parameter(Mandatory = $true)][string]$MainWorktree)

    # Read-Git (issue #128): inline, a git that writes to stderr throws before the guard below,
    # replacing "could not resolve the git common dir" with a NativeCommandError about a warning.
    $gitCommonDir = (Read-Git -Cwd $MainWorktree -GitArgs @('rev-parse', '--git-common-dir')).Text.Trim()
    if ([string]::IsNullOrWhiteSpace($gitCommonDir)) { throw 'Could not resolve the git common dir.' }
    if (-not [System.IO.Path]::IsPathRooted($gitCommonDir)) {
        $gitCommonDir = [System.IO.Path]::Combine($MainWorktree, $gitCommonDir)
    }
    $excludeDir = [System.IO.Path]::Combine($gitCommonDir, 'info')
    if (-not (Test-Path -LiteralPath $excludeDir -PathType Container)) {
        New-Item -ItemType Directory -Path $excludeDir -Force | Out-Null
    }
    $excludeFile = [System.IO.Path]::Combine($excludeDir, 'exclude')
    $excludeLines = @()
    if (Test-Path -LiteralPath $excludeFile -PathType Leaf) {
        $excludeLines = @([System.IO.File]::ReadAllLines($excludeFile))
    }
    if (-not @($excludeLines | Where-Object { $_.Trim() -eq '.svn/' }).Count) {
        $excludeLines += '.svn/'
        [System.IO.File]::WriteAllLines($excludeFile, $excludeLines)
    }
}

function Get-WorktreesDir {
    param([string]$MainWorktree = '')
    if ([string]::IsNullOrWhiteSpace($MainWorktree)) {
        $MainWorktree = Get-MainWorktree
    }
    return [System.IO.Path]::Combine($MainWorktree, '.turbo-plugin', 'worktrees')
}

# Which worktree, if any, has branch -Want checked out. Returns the normalized absolute path of
# that worktree, or ''. -WorktreeLines is the trimmed output of `git worktree list --porcelain`.
#
# TWO SILENT-FAILURE DIRECTIONS THIS FUNCTION EXISTS TO CLOSE. Both of them produce "no worktree
# has this branch", which is byte-for-byte the healthy answer -- so neither one is visible at the
# call site:
#
#   1. PATH SPELLING. git reports Windows paths as `C:/...` while other sources hand back
#      `/c/...`, and comparing those two spellings is false every single time without saying so.
#      Hence Get-NormalizedAbsolutePath before the path is ever returned for comparison.
#   2. AN UNCHECKED WORKTREE LIST. The listing is taken as a parameter rather than read here, so
#      each caller keeps the read-once-and-check-the-exit-code shape its own error reporting
#      needs (a TP_TOKEN:ERROR line in Request-Merge.ps1, a throw in Merge-MainIntoBranches.ps1).
#      A healthy --porcelain listing always contains at least the main worktree, so an empty
#      -WorktreeLines means the caller handed over a failed or unchecked read -- throw rather
#      than answer "nobody has it".
#
# Why here and not in Core.ps1: Core.ps1 is copied byte-identical into every plugin (enforced by
# tools/verify-core-identical.sh), and no other plugin parses `git worktree list` at all. Same
# reasoning as the earlier move of Get-WorktreesDir out of universal Core.
function Get-WorktreeForBranch {
    param(
        [Parameter(Mandatory = $true)][string]$Want,
        # AllowEmptyString is load-bearing, not decoration: callers build this by splitting the
        # command output on newlines, so the trailing element is ALWAYS ''. A Mandatory [string[]]
        # rejects empty elements, which would make every real call a ParameterBindingException.
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][AllowEmptyString()][string[]]$WorktreeLines
    )
    if (@($WorktreeLines | Where-Object { $_ -ne '' }).Count -eq 0) {
        throw "Get-WorktreeForBranch: empty worktree list (a checked 'git worktree list --porcelain' always lists at least the main worktree)."
    }
    $cur = ''
    foreach ($line in $WorktreeLines) {
        if ($line -like 'worktree *') {
            $cur = $line.Substring('worktree '.Length)
        } elseif ($line -eq "branch refs/heads/$Want") {
            if ($cur -ne '') { return (Get-NormalizedAbsolutePath $cur) }
            return ''
        }
    }
    return ''
}


# Validate a branch name for remote-svn worktree mapping (allowlist).
# Throws with a sanitization message on rejection. 'main' is the canonical trust
# anchor and always passes; other casings of 'main' are rejected so they cannot
# impersonate the anchor directory.
function Assert-ValidRemoteBranchName {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$BranchName)

    if ([string]::IsNullOrEmpty($BranchName)) {
        throw "Invalid branch name: empty."
    }
    # Case-SENSITIVE: only the exact lowercase 'main' is the trust anchor. Other
    # casings (Main / MAIN) fall through to the reserved-name rejection below.
    if ($BranchName -ceq 'main') { return }

    if ($BranchName.Contains('..')) {
        throw "Invalid branch name '$BranchName': must not contain '..'."
    }
    if ($BranchName.StartsWith('-')) {
        throw "Invalid branch name '$BranchName': must not start with '-'."
    }
    if ($BranchName -match '[\s.]$') {
        throw "Invalid branch name '$BranchName': must not end with '.' or whitespace."
    }
    # Allowlist: letters, digits, '.', '_', '-', '/'. Rejects '\', ':', spaces,
    # control characters, and any other separator.
    if ($BranchName -notmatch '^[A-Za-z0-9._/-]+$') {
        throw "Invalid branch name '$BranchName': only letters, digits, '.', '_', '-', and '/' are allowed."
    }
    # Reserved names (case-insensitive): the 'main' anchor dir (any non-exact casing)
    # plus Windows reserved device names, checked against the dash-form and each
    # '/'-separated segment.
    $segments = @(($BranchName -replace '/', '-')) + ($BranchName -split '/')
    foreach ($seg in $segments) {
        $low = $seg.ToLowerInvariant()
        if ($low -eq 'main' -or $low -match '^(con|prn|aux|nul|com[1-9]|lpt[1-9])$') {
            throw "Invalid branch name '$BranchName': '$seg' is a reserved name."
        }
    }
}

# Returns the existing remote-svn branch that collides with $BranchName (maps to the
# same worktree dir name but is a different ref), or $null when there is no collision.
# Pure: the caller supplies the existing branch list (e.g. from
# `git branch --list 'remote-svn/*'` with the 'remote-svn/' prefix stripped).
function Find-RemoteWorktreeCollision {
    param(
        [Parameter(Mandatory = $true)][string]$BranchName,
        [string[]]$ExistingBranches
    )
    if ($null -eq $ExistingBranches) { return $null }
    $dash = $BranchName -replace '/', '-'
    foreach ($existing in $ExistingBranches) {
        if ([string]::IsNullOrEmpty($existing)) { continue }
        if ($existing -eq $BranchName) { continue }
        if (($existing -replace '/', '-') -eq $dash) {
            return $existing
        }
    }
    return $null
}

# Map any branch to its remote-svn ref + worktree dir (generalized from
# the old hard-coded main / test-<n>). Mapping:
#   ref      = remote-svn/<branch>                 (slashes preserved)
#   worktree = remote-svn-<branch with '/' -> '-'>
# Sanitization + MAX_PATH guard run here; collision is the caller's concern
# (Find-RemoteWorktreeCollision) since it needs the live branch list.
function Resolve-RemoteWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$BranchName,
        [Parameter(Mandatory = $true)][string]$WorktreesDir
    )

    Assert-ValidRemoteBranchName -BranchName $BranchName

    $dash = $BranchName -replace '/', '-'
    $name = "remote-svn-$dash"
    $path = [System.IO.Path]::Combine($WorktreesDir, $name)

    # MAX_PATH guard — distinct from the sanitization rejection above. Windows PS 5.1
    # / .NET Framework cannot create paths longer than 260 chars without long-path
    # support; fail loudly with guidance rather than letting the create blow up later.
    # MAX_PATH (260) counts the terminating NUL, so the usable string length is 259 —
    # reject at >= 260 (a 260-char path passes -gt 260 but Windows still refuses it).
    if ($path.Length -ge 260) {
        throw "Worktree path exceeds the Windows MAX_PATH limit (260): '$path' is $($path.Length) chars. Shorten the clone path, or enable long-path support (git config core.longpaths true, or the \\?\ prefix)."
    }

    return @{
        Name   = $name
        Branch = "remote-svn/$BranchName"
        Path   = $path
    }
}

# Normalize an SVN URL for boundary-safe trust comparison:
#   - trim a single trailing slash
#   - lowercase scheme + authority (host[:port]); for file:// also lowercase the
#     Windows drive letter immediately after the leading slash(es)
#   - percent-decode the whole thing
# Returns the normalized string. Does NOT validate the URL beyond this; callers
# must still apply the boundary-prefix check.
function ConvertTo-NormalizedSvnUrl {
    param([Parameter(Mandatory = $true)][string]$Url)

    $u = $Url.Trim()
    # percent-decode first so encoded slashes / drive letters normalize too.
    $u = [System.Uri]::UnescapeDataString($u)
    # split scheme://rest so we only lowercase scheme + authority, not the path.
    if ($u -match '^([A-Za-z][A-Za-z0-9+.\-]*://)([^/]*)(/.*)?$') {
        $scheme = $Matches[1].ToLowerInvariant()
        $authority = $Matches[2].ToLowerInvariant()
        $rest = if ($null -ne $Matches[3]) { $Matches[3] } else { '' }
        $u = "$scheme$authority$rest"
    } elseif ($u -match '^([A-Za-z][A-Za-z0-9+.\-]*:)(.*)$') {
        # scheme without authority (rare); lowercase scheme only.
        $u = $Matches[1].ToLowerInvariant() + $Matches[2]
    }
    # file:// drive letter — lowercase the drive letter after the leading slashes
    # (e.g. file:///C:/Repo -> file:///c:/Repo). Authority is empty for file URLs.
    if ($u -match '^(file://)(/*)([A-Za-z])(:.*)$') {
        $u = $Matches[1] + $Matches[2] + $Matches[3].ToLowerInvariant() + $Matches[4]
    }
    # trim a single trailing slash
    if ($u.Length -gt 1 -and $u.EndsWith('/')) {
        $u = $u.Substring(0, $u.Length - 1)
    }
    return $u
}

# Assert that a caller-supplied SVN URL falls under the trusted repository root.
# Inputs:
#   -TrustedWorkingCopy: path to a working copy we trust (e.g. remote-svn-main). Its
#       `svn info --show-item repos-root-url` defines the trust base. MUST be
#       repos-root-url (not the trunk url) so legitimate sibling branches under
#       branches/ aren't falsely rejected.
#   -CandidateUrl: the untrusted URL to validate before any svn side effect.
# Behavior (fail closed):
#   - If repos-root-url can't be obtained (path missing / not a WC / server
#     unreachable) -> throw. The caller MUST NOT be able to swallow this and proceed.
#   - Candidate containing `..` traversal -> throw.
#   - After normalizing both ends (trailing slash, scheme/host case, file:// drive
#     letter, percent-decode), pass only when candidate == base OR
#     candidate startswith (base + '/'). Bare StartsWith(base) is rejected to stop
#     `repos` matching `repos-evil` (prefix confusion).
# On success: returns the normalized trusted base (for diagnostics); on any failure: throw.
function Assert-TrustedSvnUrl {
    param(
        [Parameter(Mandatory = $true)][string]$TrustedWorkingCopy,
        [Parameter(Mandatory = $true)][string]$CandidateUrl
    )

    if ([string]::IsNullOrWhiteSpace($CandidateUrl)) {
        throw 'Assert-TrustedSvnUrl: empty candidate URL.'
    }

    # Reject path traversal outright — `..` must never appear in a trusted URL.
    if ($CandidateUrl -match '(^|[/\\])\.\.([/\\]|$)') {
        throw "Untrusted SVN URL (path traversal '..' not allowed): $CandidateUrl"
    }

    # Obtain the trust base from the trusted working copy. Fail closed on any error.
    $base = ''
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $base = (& svn info --show-item repos-root-url $TrustedWorkingCopy 2>$null | Out-String).Trim()
    } catch {
        $base = ''
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($base)) {
        throw "Assert-TrustedSvnUrl: could not determine trusted repos-root-url from '$TrustedWorkingCopy' (path missing, not a working copy, or SVN unreachable). Refusing to proceed (fail closed). Run /tp-setup to bootstrap remote-svn-main."
    }

    $normBase = ConvertTo-NormalizedSvnUrl -Url $base
    $normCand = ConvertTo-NormalizedSvnUrl -Url $CandidateUrl

    # Re-check traversal AFTER percent-decoding — a percent-encoded `..` (%2e%2e)
    # passes the raw check above but decodes here; without this it could slip under
    # the boundary prefix as `<base>/../...`.
    if ($normCand -match '(^|[/\\])\.\.([/\\]|$)') {
        throw "Untrusted SVN URL (encoded path traversal '..' not allowed): $CandidateUrl"
    }

    # Boundary-safe ordinal comparison (both ends already lowercased where it matters).
    $isTrusted = ($normCand -eq $normBase) -or $normCand.StartsWith($normBase + '/', [System.StringComparison]::Ordinal)
    if (-not $isTrusted) {
        throw "Untrusted SVN URL: '$CandidateUrl' is not under trusted repository root '$base'. Refusing to proceed."
    }

    return $normBase
}

# Build the LOCKED SVN commit body for a push range. The body is a deterministic, '- '-prefixed
# list of EVERY non-merge commit subject (oldest first), one per line — git itself applies the
# '- ' prefix and the ordering, so the same commit set always yields a byte-identical body.
#
# Merge commits are excluded by parent count (--no-merges), NOT by a 'Merge ' subject-prefix
# match (KTD6/R11). There is NO commit-type filtering: docs/test/chore subjects all go in (R11).
# Subjects come straight from git's --pretty formatter, so backticks, '$', quotes, and a leading
# '- ' in a subject survive without any PowerShell interpolation.
#
# Capture happens OUTSIDE the ANSI OutputEncoding scope used for svn — commit subjects are UTF-8
# (KTD6); callers must invoke this while the console encoding is still the default (UTF-8 capable).
# Returns the body string ('' when the range has no non-merge commit).
# Expand an unversioned DIRECTORY into one "A|<tracked|ignored>|<relpath>" line per file inside it.
#
# `svn status` reports a directory that is not yet under version control as a SINGLE '?' entry and
# never recurses into it -- svn's own behaviour, not a defect here. The commit step, however, runs
# `svn add --parents` (recursive), so every file inside IS committed. That gap made the
# consolidated confirmation list show 3 folders where 14 files were actually going to SVN
# (issue #24). The confirmation exists so the user sees the full scope BEFORE the commit rather
# than reading it back out of the commit output afterwards.
#
# Paths are emitted relative to the working copy, matching what `svn status` itself prints, so the
# SKILL's list never mixes two path shapes.
#
# Args: -RemotePath = the bridge working copy; -RelativeDir = the unversioned dir, relative to it.
function Get-UnversionedDirectoryFiles {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$RelativeDir
    )

    $absDir = [System.IO.Path]::Combine($RemotePath, $RelativeDir)
    if (-not (Test-Path -LiteralPath $absDir -PathType Container)) { return @() }

    # .git / .svn are metadata, never content to be pushed. A bridge worktree always has both.
    # Both separators are matched: FullName uses '\' on Windows and '/' under pwsh on Linux, and the
    # test suite runs on both -- a backslash-only pattern silently stops excluding anything on Linux.
    $children = @(Get-ChildItem -LiteralPath $absDir -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '[\\/]\.(git|svn)[\\/]' } |
        Sort-Object -Property FullName)

    $lines = @()
    foreach ($child in $children) {
        $childRel = Get-RelativePathSafe -From $RemotePath -To $child.FullName

        $eaChild = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        & git -C $RemotePath check-ignore -q $childRel 2>$null | Out-Null
        $childIgnored = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $eaChild

        $childKind = if ($childIgnored) { 'ignored' } else { 'tracked' }
        $lines += "A|$childKind|$childRel"
    }
    return $lines
}

# Read the SOURCE BRANCH off a merge commit's own subject. Returns the name, or '' when the
# subject does not record one -- the caller must then NOT guess (see Get-SvnPushBody).
#
# Handles git's own default merge subjects (`Merge branch 'x'`, `... into y`, `Merge
# remote-tracking branch 'origin/x'`) and GitHub's (`Merge pull request #N from owner/x`);
# every plugin-generated merge uses the first form. The bridge-ref prefix is stripped so the
# internal `remote-svn/*` name never surfaces (a trunk-replay resolves to `main`).
function Get-MergeSourceBranch {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Subject)

    if (-not $Subject.StartsWith('Merge ')) { return '' }
    $name = ''
    if ($Subject -match "^Merge pull request #\S+ from (\S+)") {
        $name = $Matches[1]
        $slash = $name.IndexOf('/')
        if ($slash -ge 0) { $name = $name.Substring($slash + 1) }   # drop the owner
    } elseif ($Subject -match "branch '([^']*)'") {
        $name = $Matches[1]
    } else {
        return ''
    }
    if ([string]::IsNullOrEmpty($name)) { return '' }
    # A real branch name has no whitespace, and must not be able to forge a group header.
    if ($name -match '\s') { return '' }
    # U+3010 / U+3011 are the group-header brackets, referenced by code point so this guard does
    # not itself depend on the file's encoding.
    if ($name.IndexOf([char]0x3010) -ge 0 -or $name.IndexOf([char]0x3011) -ge 0) { return '' }
    if ($name.StartsWith('remote-svn/')) { $name = $name.Substring('remote-svn/'.Length) }
    if ([string]::IsNullOrEmpty($name)) { return '' }
    return $name
}

function Get-SvnPushBody {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$Range
    )
    $tip = ($Range -split '\.\.')[-1]
    # git may warn on stderr; under EAP=Stop that throws NativeCommandError, so soften locally.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    $gName = New-Object System.Collections.ArrayList
    $gBody = New-Object System.Collections.ArrayList
    $flat = New-Object System.Collections.ArrayList
    $unresolved = $false
    try {
        # OWN commits = the current branch's first-parent mainline (non-merge); everything else in
        # range arrived via a merge. Deciding "own" by topology stops a commit the current branch
        # shares with a sibling from being mis-attributed to the sibling.
        $own = @{}
        foreach ($o in @(& git -C $RepoDir rev-list --first-parent --no-merges $Range 2>$null)) {
            if (-not [string]::IsNullOrWhiteSpace($o)) { $own[$o] = $true }
        }

        # Attribute each merged-in commit to the merge that INTRODUCED it into the pushed branch,
        # and take the source-branch name from that merge commit's own subject.
        #
        # This used to ask `git name-rev` which branch describes the commit, and that answers a
        # different question: name-rev minimises (generation, distance) over ALL local heads, which
        # has no relation to how the commit entered the branch being pushed. Any branch that merely
        # DESCENDS from the commit is a candidate -- and `/tp-merge-main-into-branches` plus
        # ordinary stacked branches make that set large. Issue #67 hit exactly that: a commit that
        # reached `main` through one branch was labelled with another branch that had never been
        # merged into `main` at all, permanently, in an SVN log. Reading the merge commit instead
        # uses the record git wrote AT MERGE TIME, so a later branch rename, deletion or merge
        # cannot change the answer.
        $attr = @{}
        foreach ($m in @(& git -C $RepoDir rev-list --first-parent --merges $Range 2>$null)) {
            if ([string]::IsNullOrWhiteSpace($m)) { continue }
            $src = ''
            $parents = @("$(& git -C $RepoDir rev-list --parents -n 1 $m 2>$null)" -split '\s+' |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            # Only an ordinary two-parent merge has one unambiguous "other side" to name.
            if ($parents.Count -eq 3) {
                $src = Get-MergeSourceBranch -Subject "$(& git -C $RepoDir log -1 --format='%s' $m 2>$null)"
            }
            if ([string]::IsNullOrEmpty($src)) { $unresolved = $true; break }
            # Commits this merge brought in = reachable from the merged side but not from the
            # mainline. An earlier merge of the same branch already claimed its own commits, so
            # `--not <first parent>` keeps each commit with the merge that FIRST introduced it.
            foreach ($c in @(& git -C $RepoDir rev-list --no-merges "$m^2" --not "$m^1" 2>$null)) {
                if ([string]::IsNullOrWhiteSpace($c)) { continue }
                if (-not $attr.ContainsKey($c)) { $attr[$c] = $src }
            }
        }

        $shas = @(& git -C $RepoDir rev-list --no-merges --reverse $Range 2>$null)
        foreach ($sha in $shas) {
            if ([string]::IsNullOrWhiteSpace($sha)) { continue }
            $subj = "$(& git -C $RepoDir log -1 --format='%s' $sha 2>$null)"
            [void]$flat.Add("- $subj")
            if ($own.ContainsKey($sha)) {
                $branch = $tip
            } elseif ($attr.ContainsKey($sha)) {
                $branch = $attr[$sha]
            } else {
                # Reachable but attributable to no merge on the mainline: do not invent a source.
                $unresolved = $true
                $branch = $tip
            }
            $idx = $gName.IndexOf($branch)
            if ($idx -lt 0) {
                [void]$gName.Add($branch); [void]$gBody.Add("- $subj")
            } else {
                $gBody[$idx] = $gBody[$idx] + "`n- $subj"
            }
        }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $n = $gName.Count
    if ($n -eq 0) { return '' }
    # ONE source branch -> flat "- <subject>" list (backward compatible; no group header).
    # Anything unattributable -> flat as well: a wrong group is worse than no group, because the
    # SVN log is permanent and the agent may only write the title, never the body.
    if ($unresolved -or $n -eq 1) { return ($flat -join "`n") }
    # 2+ source branches -> group by branch, current branch first, others in first-appearance order.
    $order = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $n; $i++) { if ($gName[$i] -eq $tip) { [void]$order.Add($i) } }
    for ($i = 0; $i -lt $n; $i++) { if ($gName[$i] -ne $tip) { [void]$order.Add($i) } }
    $parts = foreach ($idx in $order) { "【" + [string]$gName[$idx] + "】`n" + [string]$gBody[$idx] }
    return ($parts -join "`n")
}

# --- Per-revision SVN replay primitives (U1) ---------------------------------
# PowerShell peers of svn_enumerate_revisions / svn_replay_commit / svn_floor_commit_for_rev
# (common.sh). All three are pure git + XML (NO native svn call here — the caller captures the
# svn log and passes the XML string in), so git output stays UTF-8 (Core.ps1 default) and no
# ANSI OutputEncoding scoping is needed. Keep this block ASCII so the file's existing BOM is the
# only reason it holds non-ASCII bytes.

# Enumerate revisions from an `svn log --xml` document (passed as a Unicode string) into
# per-revision objects { Rev; Author; Date; Message } in ASCENDING revision order. System.Xml
# entity-decodes InnerText and preserves multi-line / CJK messages verbatim. Behavior-matched
# to common.sh's svn_enumerate_revisions (shape differs: objects here vs a NUL record stream there).
function Get-SvnRevisions {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$LogXml)

    $result = @()
    if ([string]::IsNullOrWhiteSpace($LogXml)) { return $result }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($LogXml)

    $entries = $doc.SelectNodes('/log/logentry')
    foreach ($e in $entries) {
        $rev = [int]$e.GetAttribute('revision')
        $authorNode = $e.SelectSingleNode('author')
        $dateNode   = $e.SelectSingleNode('date')
        $msgNode    = $e.SelectSingleNode('msg')
        $author  = if ($authorNode) { $authorNode.InnerText } else { '' }
        $date    = if ($dateNode)   { $dateNode.InnerText }   else { '' }
        $message = if ($msgNode)    { $msgNode.InnerText -replace "\r", '' } else { '' }
        $result += [pscustomobject]@{
            Rev     = $rev
            Author  = $author
            Date    = $date
            Message = $message
        }
    }
    # Force array (a single-entry result would otherwise unwrap to a scalar and break .Count / indexing).
    return @($result | Sort-Object -Property Rev)
}

# Replay one SVN revision as a git commit on the CURRENT HEAD of -RepoDir (in production the
# remote-svn/<branch> worktree, already `svn update`d to this revision's tree). Returns a token:
#   'SKIP:idempotent'  HEAD already carries a commit with this revision's `svn-revision:` trailer
#                      (KTD4 idempotency — an interrupted-then-rerun pull mints no duplicate).
#   'SKIP:empty'       `git add -A` left the index unchanged (tree identical to parent) → no commit.
#   'COMMIT:<sha>'     committed. Author = "<svn-username> <>" (raw username, empty <> email; KTD2),
#                      SVN date as the git AUTHOR-date (committer-date = replay moment; KTD6),
#                      message = SVN message + blank line + `svn-revision: <rev>` trailer (KTD3).
# commit.cleanup is pinned to 'whitespace' so a '#'-leading message line survives (default 'strip'
# would delete it) while the trailer paragraph is still recognized.
function Invoke-SvnReplayCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$Rev,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Author,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Date,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message
    )

    # git warns on stderr (LF/CRLF etc); under EAP=Stop that throws NativeCommandError, so soften
    # locally and drive control flow off $LASTEXITCODE (mind the PS5.1 EAP=Stop stderr-throw trap).
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        # Idempotency: this revision is already marked AND that marker is on HEAD → nothing to do.
        # A marker left by a rolled-back attempt is not an ancestor of HEAD, so it never blocks a re-run.
        $marked = Get-SvnRevMark -RepoDir $RepoDir -Rev $Rev
        if (-not [string]::IsNullOrWhiteSpace($marked)) {
            & git -C $RepoDir merge-base --is-ancestor $marked HEAD 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return 'SKIP:idempotent' }
        }

        & git -C $RepoDir add -A 2>$null | Out-Null
        # Guard the stage: a failed `git add -A` leaves the index unchanged, which the empty-delta
        # check below would misread as "identical tree", silently dropping this revision's commit
        # (and its marker). The bash sibling fails loud here via `set -e`.
        if ($LASTEXITCODE -ne 0) { throw "Invoke-SvnReplayCommit: git add -A failed for r$Rev (exit $LASTEXITCODE)." }

        # Empty index (tree identical to parent) → this revision changed nothing we track, so HEAD
        # ALREADY carries its content: mark HEAD, mint no commit. Marking (rather than skipping
        # outright) is what lets a revision whose content arrived some other way -- notably one this
        # repo pushed itself -- still be resolvable by the floor lookup. --quiet writes nothing to
        # stderr, so $LASTEXITCODE is reliable: 0 = no staged changes, 1 = staged changes.
        & git -C $RepoDir diff --cached --quiet 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $headSha = (& git -C $RepoDir rev-parse --verify --quiet HEAD 2>$null | Out-String).Trim()
            if (-not [string]::IsNullOrWhiteSpace($headSha)) {
                Set-SvnRevMark -RepoDir $RepoDir -Rev $Rev -Sha $headSha
            }
            return 'SKIP:empty'
        }

        # git dislikes the .000000Z microseconds svn emits; keep it to whole seconds.
        $dateGit = $Date -replace '\.\d+Z$', 'Z'

        $authorArg = @()
        if (-not [string]::IsNullOrEmpty($Author)) {
            $authorArg = @("--author=$Author <>")
        }

        # The SVN message is committed VERBATIM -- the revision number lives in refs/tp/svn/<rev>,
        # so nothing is appended to (or stripped from) what the author wrote.
        & git -C $RepoDir -c commit.gpgsign=false commit --cleanup=whitespace @authorArg `
            --date=$dateGit -m $Message 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Invoke-SvnReplayCommit: git commit failed for r$Rev (exit $LASTEXITCODE)."
        }

        $sha = (& git -C $RepoDir rev-parse HEAD 2>$null | Out-String).Trim()
        Set-SvnRevMark -RepoDir $RepoDir -Rev $Rev -Sha $sha
        return "COMMIT:$sha"
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# --- Shared per-revision replay loop (U3 pull + U7 first-import bootstrap) -----
# One shared body so the steady-state pull (Sync-FromSvn) and the first-import bootstrap
# (Initialize-GitSvnBridge) mint IDENTICAL commit shapes (author / date / trailer). Both callers own
# their own >5 granularity GATE (the residue-free "needs choice" exit differs per caller); this code
# only MATERIALISES an already-chosen mode against a bridge worktree at the resume baseline.

# Replay ONE svn revision: svn update -r R in the bridge worktree, assert the WC is uniformly at R
# (KTD4 sparse guard), then hand off to Invoke-SvnReplayCommit. Returns the U1 token.
# Escape a path so svn accepts it as a TARGET argument.
#
# svn parses a trailing @<rev> on EVERY target as a peg revision, so a perfectly legal filename
# containing '@' -- `banner@2x.jpg`, the standard retina naming convention -- makes svn try to read
# "2x.jpg" as a revision and fail with:
#   svn: E200009: '<path>': a peg revision is not allowed here
# `--` does NOT prevent this: it terminates OPTION parsing, and peg parsing happens per-target
# afterwards (issue #34).
#
# The documented escape is to append one '@'. It is harmless for paths that contain no '@' at all
# (`foo.txt@` still resolves to `foo.txt`), so it is applied UNCONDITIONALLY -- a detect-then-escape
# branch would only add a way for our parsing to disagree with svn's.
#
# Use it for FILE targets. Do NOT wrap fixed targets like '.', which have their own meaning to svn.
function ConvertTo-SvnTarget {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Path)
    return "$Path@"
}

# Write a --targets file for svn: one path per line, in the encoding svn will read it back with.
#
# Why a targets file at all: passing each path as its own argument overflows the command-line length
# limit once a push touches enough files (issue #35). On Windows that limit is CreateProcess's 32767
# characters, and the failure mode is worse than bash's "Argument list too long" -- arguments get
# truncated and svn complains about paths that look fine.
#
# Why the ANSI codepage and not UTF-8: verified against a local repository -- a UTF-8 targets file
# makes svn look for a mojibake path and fail with "is not under version control", while the same
# list written in CP_ACP commits correctly. This is the same channel the command line already went
# through (argv is CP_ACP too), so it is not a new limitation -- but a filename using characters
# outside the active codepage cannot be expressed here, exactly as it could not be on the command
# line.
#
# ANSICodePage rather than [Text.Encoding]::Default: Default IS CP_ACP under Windows PowerShell 5.1
# but is UTF-8 under PowerShell 7+, so relying on it would silently write the wrong bytes on the
# newer host -- the kind of difference that only shows up on someone else's machine.
#
# Paths must ALREADY be escaped with ConvertTo-SvnTarget: a targets file is peg-parsed line by line,
# just like argv (verified -- an unescaped `banner@2x.jpg` in a targets file still fails E200009).
function Write-SvnTargetsFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][string[]]$Targets
    )

    $enc = $null
    try {
        $acp = [System.Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage
        if ($acp -eq 65001) {
            # CP_ACP is already UTF-8 (the Windows "Use Unicode UTF-8 worldwide" system-locale
            # option -- which is exactly what /tp-setup recommends to users who need filenames
            # beyond their codepage, so this is a configuration we actively steer people into).
            #
            # It must NOT go through GetEncoding(65001): that returns Encoding.UTF8, whose preamble
            # is a 3-byte BOM, and File.WriteAllText writes the preamble. svn would then read those
            # bytes as part of the FIRST path in the file and fail to find it -- the same
            # "is not under version control" class of failure this function exists to prevent.
            # The bash side already sidesteps this by not re-encoding at all when cp == 65001.
            $enc = New-Object System.Text.UTF8Encoding($false)
        } elseif ($acp -gt 0) {
            $enc = [System.Text.Encoding]::GetEncoding($acp)
        }
    } catch {
        $enc = $null
    }
    # Non-Windows hosts have no CP_ACP; there svn reads the file in the locale encoding, i.e. UTF-8.
    if ($null -eq $enc) { $enc = New-Object System.Text.UTF8Encoding($false) }

    $content = ''
    if (@($Targets).Count -gt 0) { $content = (@($Targets) -join "`n") + "`n" }

    # FAIL when the codepage cannot represent a path, instead of writing what it can.
    #
    # GetEncoding's default encoder fallback SUBSTITUTES '?' for every unmappable character, so a
    # CJK filename on a CP1252 host was silently written as "??????.md". svn then reported
    # "E200009: Could not add all targets ... don't exist" -- a message that names neither the file
    # nor the reason, and sends the reader looking for a bug in the push logic. The bash twin has
    # always failed loudly here (iconv returns non-zero and the script says which codepage and
    # why); this is the same behaviour, so the two sides now fail the same way for the same reason.
    # Observed on the CI Windows runner, whose ACP is 1252.
    $encStrict = $enc
    if (-not ($enc -is [System.Text.UTF8Encoding])) {
        $encStrict = [System.Text.Encoding]::GetEncoding(
            $enc.CodePage,
            [System.Text.EncoderFallback]::ExceptionFallback,
            [System.Text.DecoderFallback]::ReplacementFallback)
    }
    try {
        $bytes = $encStrict.GetBytes($content)
    } catch [System.Text.EncoderFallbackException] {
        throw ("a path in this commit uses characters your system codepage (CP{0}) cannot represent, " +
               "so it cannot be passed to svn on this host. See the encoding notes in /tp-setup.") -f $enc.CodePage
    }
    [System.IO.File]::WriteAllBytes($Path, $bytes)
}

# Return the URL that -BaseUrl (pegged at -PegRev) had at -Rev, or '' when svn cannot answer, so a
# caller never mistakes "unknown" for "unchanged".
#
# The peg is what makes this work across renames. `svn info -r R URL@PEG` follows copy history
# BACKWARDS from the pegged path, so a path renamed at some revision still resolves to its older
# name for revisions before the rename. The reverse does NOT hold: asking where an OLD path lives
# at HEAD fails with E160013 once that path has been deleted (verified against a local repository
# reproducing issue #32) -- so every lookup must peg at a revision where the path exists, normally
# HEAD.
function Get-SvnUrlAtRev {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][int]$PegRev,
        [Parameter(Mandatory = $true)][int]$Rev
    )
    # `2>$null` under EAP=Stop, left inline on purpose (issue #137): safe only because `svn` is the
    # --non-interactive shim above, which removes the one class of svn behaviour that writes stderr
    # on an otherwise healthy call (interactive prompts). A throw here therefore means the lookup
    # really failed, which is what the empty-string fallback already encodes.
    $url = ''
    try {
        $url = (& svn info --show-item url -r $Rev "$BaseUrl@$PegRev" 2>$null | Out-String).Trim()
    } catch {
        $url = ''
    }
    if ($LASTEXITCODE -ne 0) { return '' }
    return $url
}

# Position the bridge working copy at -Rev, following a path rename when one is in play.
#
# `svn update -r R` cannot cross a rename: the WC is bound to the path as it existed at its own
# revision, and updating to a revision where that path no longer exists fails with E160005. When the
# URL this path has at -Rev is known, switching to it (with an explicit peg) moves the WC to the
# right place instead. --ignore-ancestry because a rename IS a delete+copy: svn otherwise refuses
# the switch for having no common ancestry.
#
# Two ways in, and BOTH are needed:
#   - -TargetUrl given: the caller already detected a rename across the range, so switch straight
#     away instead of failing first.
#   - -TargetUrl empty but -BaseUrl given: try the plain update, and if it fails, resolve this
#     revision's own URL and switch. This is what covers a rename the range-endpoint check cannot
#     see -- a path renamed A->B->A INSIDE one pending window looks unrenamed at both ends, yet the
#     revisions in the middle live at B. Paying for the lookup only after a failure keeps the
#     common (never-renamed) case at exactly one svn call, as before.
function Set-SvnWcPosition {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][int]$Rev,
        [string]$TargetUrl = '',
        [string]$BaseUrl = '',
        [int]$PegRev = 0
    )
    if (-not [string]::IsNullOrWhiteSpace($TargetUrl)) {
        $wcUrl = (& svn info --show-item url $RemotePath | Out-String).Trim()
        if ($wcUrl -ne $TargetUrl) {
            Push-Location $RemotePath
            try {
                & svn switch --ignore-ancestry -r $Rev "$TargetUrl@$Rev"
                if ($LASTEXITCODE -ne 0) { throw "svn switch to $TargetUrl@$Rev failed" }
            } finally {
                Pop-Location
            }
            return
        }
    }

    # EAP-softened so a failed update surfaces as a non-zero exit we can act on, rather than a
    # terminating NativeCommandError thrown the moment svn writes to stderr.
    $updateExit = 0
    Push-Location $RemotePath
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            & svn update -r $Rev
            $updateExit = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $prevEap
        }
    } finally {
        Pop-Location
    }
    if ($updateExit -eq 0) { return }

    # Update failed. If we can ask where this path lived at -Rev, a mid-range rename is the likely
    # cause; switching there is a recovery, not a guess -- the URL comes from svn's own copy history.
    if (-not [string]::IsNullOrWhiteSpace($BaseUrl) -and $PegRev -gt 0) {
        $recovered = Get-SvnUrlAtRev -BaseUrl $BaseUrl -PegRev $PegRev -Rev $Rev
        if (-not [string]::IsNullOrWhiteSpace($recovered)) {
            [Console]::Error.WriteLine("Note: r$Rev is not reachable at the current path; following the rename to $recovered")
            Push-Location $RemotePath
            try {
                & svn switch --ignore-ancestry -r $Rev "$recovered@$Rev"
                if ($LASTEXITCODE -ne 0) { throw "svn switch to $recovered@$Rev failed" }
            } finally {
                Pop-Location
            }
            return
        }
    }

    throw "svn update -r $Rev failed"
}

function Invoke-SvnOneReplay {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][int]$Rev,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Author,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Date,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Message,
        [string]$TargetUrl = '',
        [string]$BaseUrl = '',
        [int]$PegRev = 0
    )
    Set-SvnWcPosition -RemotePath $RemotePath -Rev $Rev -TargetUrl $TargetUrl -BaseUrl $BaseUrl -PegRev $PegRev
    $wc = [int]((& svn info --show-item revision $RemotePath | Out-String).Trim())
    if ($wc -ne $Rev) { throw "Remote worktree not uniformly at r$Rev (got r$wc); refusing per-revision replay." }
    return (Invoke-SvnReplayCommit -RepoDir $RemotePath -Rev $Rev -Author $Author -Date $Date -Message $Message)
}

# Squash the current SVN HEAD-of-range into ONE boundary commit on the bridge worktree's HEAD.
# Subject `sync: svn r<rev>` (steady-state shape) + a second -m appending the `svn-revision: <rev>`
# trailer so floor-lookup (U5) treats the squashed range as a single boundary. Skips an empty delta.
function Invoke-SvnBoundaryCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][int]$Rev
    )
    & git -C $RemotePath add -A
    if ($LASTEXITCODE -ne 0) { throw 'git add failed in remote worktree' }
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & git -C $RemotePath diff --cached --quiet 2>$null | Out-Null
        $hasChanges = ($LASTEXITCODE -ne 0)
    } finally {
        $ErrorActionPreference = $prev
    }
    if ($hasChanges) {
        & git -C $RemotePath -c commit.gpgsign=false commit -m "sync: svn r$Rev"
        if ($LASTEXITCODE -ne 0) { throw 'git commit failed in remote worktree' }
    }
    # Mark the boundary either way: with or without a new commit, HEAD is where revision $Rev is
    # materialised, and the floor lookup needs that mapping.
    # Read-Git (issue #128): the read just above softens EAP for its own call, this one did not.
    # A throw here skips the boundary marker entirely, and an empty read skips it silently -- either
    # way revision $Rev becomes unresolvable to the floor lookup on a repo that is otherwise fine.
    $sha = (Read-Git -Cwd $RemotePath -GitArgs @('rev-parse', '--verify', '--quiet', 'HEAD')).Text.Trim()
    if (-not [string]::IsNullOrWhiteSpace($sha)) {
        Set-SvnRevMark -RepoDir $RemotePath -Rev $Rev -Sha $sha
    }
}

# Enumerate r(Cur+1)..HeadRev on the bridge worktree, then materialise commits per -Mode:
#   per-revision : one replay commit per revision (empty deltas skipped)
#   squash       : one boundary commit at HeadRev
#   range        : per-revision inside <lo>:<hi> (from -Range), squash the leading + trailing rest
# Re-enumerates from the WC so the caller only hands over the decided mode.
function Invoke-SvnReplayDispatch {
    param(
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][string]$RemoteName,
        [Parameter(Mandatory = $true)][int]$Cur,
        [Parameter(Mandatory = $true)][int]$HeadRev,
        [Parameter(Mandatory = $true)][string]$Mode,
        [string]$Range = '',
        [string]$BaseUrl = ''
    )
    # KTD4 sparse guard: a full (infinite-depth) checkout is required so `svn update -r R` yields a
    # uniform per-revision tree -- otherwise an empty post-update delta could mean "sparse update",
    # not "identical tree". Assert once, before the loop.
    $depth = (& svn info --show-item depth $RemotePath | Out-String).Trim()
    if ($depth -ne 'infinity') {
        throw "Remote worktree depth is '$depth', not 'infinity'; per-revision replay needs a full checkout."
    }

    # Enumerate against the URL pegged at HeadRev, NOT against the working copy.
    #
    # A WC checked out at an older revision is bound to the path as it existed THEN. If any ancestor
    # was renamed since, `svn log <WC>` asks about a path that no longer exists at head and dies with
    # E160013 naming a path the user never typed (issue #32). The pegged URL follows copy history, so
    # the same range enumerates correctly whether or not a rename happened.
    if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
        $BaseUrl = (& svn info --show-item url $RemotePath | Out-String).Trim()
    }

    $revs = @()
    if ($Cur -lt $HeadRev) {
        $logXml = (& svn log --xml -r "$($Cur + 1):$HeadRev" "$BaseUrl@$HeadRev" | Out-String)
        if ($LASTEXITCODE -ne 0) {
            throw @"
svn log failed for r$($Cur + 1):r$HeadRev on $BaseUrl@$HeadRev
  If the error names a path you never entered, that path (or one of its parent folders) was renamed on SVN.
  A bridge already built against the old path cannot find the new one on its own -- re-run /tp-setup with the current URL.
"@
        }
        $revs = @(Get-SvnRevisions -LogXml $logXml)
    }

    # Was this path renamed anywhere inside the pending range? Asked ONCE, by comparing where it
    # lived at the first pending revision with where it lives at head. Equal -- the overwhelmingly
    # common case -- means no per-revision URL lookups happen at all, so unrenamed repositories pay
    # nothing for this. Only when they differ does each replayed revision resolve its own URL.
    $renamed = $false
    if ($Cur -lt $HeadRev) {
        $urlFirst = Get-SvnUrlAtRev -BaseUrl $BaseUrl -PegRev $HeadRev -Rev ($Cur + 1)
        $urlHead = Get-SvnUrlAtRev -BaseUrl $BaseUrl -PegRev $HeadRev -Rev $HeadRev
        if (-not [string]::IsNullOrWhiteSpace($urlFirst) -and -not [string]::IsNullOrWhiteSpace($urlHead) -and $urlFirst -ne $urlHead) {
            $renamed = $true
            Write-Output "TP_TOKEN:SVN_PATH_RENAMED old=$urlFirst new=$urlHead range=r$($Cur + 1):r$HeadRev"
            Write-Output "Note: this SVN path was renamed within r$($Cur + 1)..r$HeadRev; the import will follow the rename."
        }
    }

    # Resolve the URL a given revision needs, or '' when nothing was renamed (plain update path).
    $targetUrlFor = {
        param([int]$R)
        if (-not $renamed) { return '' }
        return (Get-SvnUrlAtRev -BaseUrl $BaseUrl -PegRev $HeadRev -Rev $R)
    }

    if ($Mode -eq 'per-revision') {
        Write-Output "Replaying $(@($revs).Count) SVN revision(s) r$($Cur + 1)..r$HeadRev into $RemoteName..."
        foreach ($rec in $revs) {
            $null = Invoke-SvnOneReplay -RemotePath $RemotePath -Rev $rec.Rev -Author $rec.Author -Date $rec.Date -Message $rec.Message -TargetUrl (& $targetUrlFor $rec.Rev) -BaseUrl $BaseUrl -PegRev $HeadRev
        }
    }
    elseif ($Mode -eq 'squash') {
        Write-Output "Squashing SVN r$($Cur + 1)..r$HeadRev into one commit in $RemoteName..."
        Set-SvnWcPosition -RemotePath $RemotePath -Rev $HeadRev -TargetUrl (& $targetUrlFor $HeadRev) -BaseUrl $BaseUrl -PegRev $HeadRev
        Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev $HeadRev
    }
    elseif ($Mode -eq 'range') {
        if ($Range -notmatch '^[0-9]+:[0-9]+$') {
            throw "Granularity 'range' requires -Range <lo>:<hi> (got '$Range')."
        }
        $loRaw, $hiRaw = $Range -split ':', 2
        $lo = [Math]::Max([int]$loRaw, $Cur + 1)
        $hi = [Math]::Min([int]$hiRaw, $HeadRev)
        if ($lo -gt $hi) { throw "Granularity range r$loRaw:r$hiRaw does not overlap the pending r$($Cur + 1):r$HeadRev." }
        Write-Output "Replaying r$lo..r$hi per-revision, squashing the rest, into $RemoteName..."
        # Leading squash: r(cur+1)..r(lo-1) -> one boundary commit at r(lo-1). Skipped when lo==cur+1.
        if (($lo - 1) -ge ($Cur + 1)) {
            Set-SvnWcPosition -RemotePath $RemotePath -Rev ($lo - 1) -TargetUrl (& $targetUrlFor ($lo - 1)) -BaseUrl $BaseUrl -PegRev $HeadRev
            Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev ($lo - 1)
        }
        # Per-revision inside [lo,hi].
        foreach ($rec in $revs) {
            if ($rec.Rev -ge $lo -and $rec.Rev -le $hi) {
                $null = Invoke-SvnOneReplay -RemotePath $RemotePath -Rev $rec.Rev -Author $rec.Author -Date $rec.Date -Message $rec.Message -TargetUrl (& $targetUrlFor $rec.Rev) -BaseUrl $BaseUrl -PegRev $HeadRev
            }
        }
        # Trailing squash: r(hi+1)..rHEAD -> one boundary commit at rHEAD. Skipped when hi>=HeadRev.
        if ($hi -lt $HeadRev) {
            Set-SvnWcPosition -RemotePath $RemotePath -Rev $HeadRev -TargetUrl (& $targetUrlFor $HeadRev) -BaseUrl $BaseUrl -PegRev $HeadRev
            Invoke-SvnBoundaryCommit -RemotePath $RemotePath -Rev $HeadRev
        }
    }
    else {
        throw "Unknown granularity '$Mode' (expected per-revision | squash | range)."
    }
}

# --- Revision markers: refs/tp/svn/<N> (R14) ----------------------------------
# PowerShell peers of svn_rev_mark_set / svn_rev_mark_get / svn_rev_marks / floor / max
# (common.sh). See that file for the full rationale; in short, the revision->commit map lives in a
# dedicated ref namespace rather than in commit messages, both pull and push write it, and that is
# what lets a revision this repo PUSHED still be resolvable by the floor lookup.

# Point refs/tp/svn/<Rev> at <Sha> (create or move).
function Set-SvnRevMark {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$Rev,
        [Parameter(Mandatory = $true)][string]$Sha
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        & git -C $RepoDir update-ref "refs/tp/svn/$Rev" $Sha 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Set-SvnRevMark: update-ref refs/tp/svn/$Rev failed (exit $LASTEXITCODE)." }
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# SHA marked for <Rev>, or '' when unmarked.
function Get-SvnRevMark {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$Rev
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $sha = (& git -C $RepoDir rev-parse --verify --quiet "refs/tp/svn/$Rev^{commit}" 2>$null | Out-String).Trim()
        return $sha
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# All markers as [pscustomobject]@{Rev;Sha}, DESCENDING by revision (numeric).
function Get-SvnRevMarks {
    param([Parameter(Mandatory = $true)][string]$RepoDir)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $lines = @(& git -C $RepoDir for-each-ref --format='%(refname:lstrip=3) %(objectname)' 'refs/tp/svn/*' 2>$null)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    $out = foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $parts = $line.Trim() -split '\s+'
        if ($parts.Count -ne 2 -or $parts[0] -notmatch '^[0-9]+$') { continue }
        [pscustomobject]@{ Rev = [int]$parts[0]; Sha = $parts[1] }
    }
    return @($out | Sort-Object -Property Rev -Descending)
}

# Floor revision->commit lookup (KTD3 floor semantics, R8/R14): the marker with the GREATEST
# revision <= -TargetRev whose commit is REACHABLE FROM `main`. Returns one SHA, or $null when no
# marker <= target is reachable (the genuine "predates earliest" case -> checkout's R10 path).
# Ambiguity is impossible by construction (one ref per revision), so there is no duplicate branch;
# markers left by a rolled-back import are simply unreachable from main and skipped.
#
# WHY `main` and not the bridge ref (remote-svn/main) -- load-bearing, not an oversight:
#   * The SHA returned here becomes the PARENT of the branch checkout is about to create. A later
#     `git merge-base main <branch>` can only resolve to it if it sits in main's OWN history; that
#     is the entire point of grading the fork point (U5).
#   * Commits the bridge has but main does not come in two flavours, and NEITHER is a usable base:
#     the `Merge branch 'main' into remote-svn/main` commits that push creates (the bridge tip is
#     verifiably NOT an ancestor of main), and commits pull has already replayed but whose merge
#     into main has not landed yet.
#   * So widening the scan to the bridge would not buy reachability -- merge-base still would not
#     land on the chosen base. It would only trade "stop with a clear error" for "silently attach
#     the branch to history that main may never acquire".
# Scope differs per caller BY DESIGN, which is why Get-SvnMaxRevReachable takes -Ref:
#   pull resume point -> remote-svn/main | push alignment -> the pushed branch |
#   checkout grading bound + this floor -> main.
function Get-SvnFloorCommit {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][int]$TargetRev
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        foreach ($m in (Get-SvnRevMarks -RepoDir $RepoDir)) {
            if ($m.Rev -gt $TargetRev) { continue }
            & git -C $RepoDir merge-base --is-ancestor $m.Sha main 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $m.Sha }
        }
        return $null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# Greatest marked revision REACHABLE FROM -Ref; 0 when none. Single "where are we" answer shared by
# the pull resume point, the checkout grading bound and the push alignment advance, so those three
# can no longer disagree (they used to: the pull read the working-copy revision while checkout read
# message trailers, which deadlocked a checkout behind a pull that had nothing to do).
function Get-SvnMaxRevReachable {
    param(
        [Parameter(Mandatory = $true)][string]$RepoDir,
        [Parameter(Mandatory = $true)][string]$Ref
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        foreach ($m in (Get-SvnRevMarks -RepoDir $RepoDir)) {
            & git -C $RepoDir merge-base --is-ancestor $m.Sha $Ref 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { return $m.Rev }
        }
        return 0
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# The checkout grading bound `cur` = greatest marked revision reachable from `main`.
function Get-SvnHighestReplayedRev {
    param([Parameter(Mandatory = $true)][string]$RepoDir)
    return (Get-SvnMaxRevReachable -RepoDir $RepoDir -Ref 'main')
}

# --- tp:* branch-metadata property helpers (U2) ------------------------------
# PowerShell peers of svn_copyfrom_rev_xml / get_svn_branch_copyfrom_rev / get_tp_branch_prop /
# set_tp_branch_prop (common.sh). Read/write the two branch-metadata SVN properties the bridge
# cannot otherwise share (KTD5) plus the trunk copyfrom-rev a branch was `svn copy`-ed from. Keep
# this block ASCII so the file's existing BOM is the only reason it holds non-ASCII bytes.

# Extract the trunk copyfrom-rev of a branch from an `svn log -v --stop-on-copy --xml` document
# (passed as a string). Under --stop-on-copy the OLDEST logentry (smallest revision) IS the copy,
# whose branch-root path carries copyfrom-rev="N" (the TRUNK revision the branch was copied from) --
# NOT the branch's own creation revision (the logentry's revision, which never touched trunk and
# carries no svn-revision: trailer). Returns the value as a string, or '' when the XML has no
# copyfrom path. Reuses XmlDocument.LoadXml + SelectNodes (mirrors Get-SvnLog.ps1); GetAttribute
# returns '' for a missing attribute, so the IsNullOrWhiteSpace guard is correct.
function Get-SvnCopyfromRevFromXml {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Xml)

    if ([string]::IsNullOrWhiteSpace($Xml)) { return '' }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($Xml)
    $logRoot = $doc.SelectSingleNode('/log')
    if ($null -eq $logRoot) { return '' }
    # @()-wrap so a single logentry does not unwrap to a scalar (five-taboo #5).
    $entries = @($logRoot.SelectNodes('logentry'))
    if ($entries.Count -eq 0) { return '' }

    $minRev = $null; $minEntry = $null
    foreach ($e in $entries) {
        $r = $e.GetAttribute('revision')
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $ri = [int]$r
        if ($null -eq $minRev -or $ri -lt $minRev) { $minRev = $ri; $minEntry = $e }
    }
    if ($null -eq $minEntry) { return '' }
    foreach ($p in @($minEntry.SelectNodes('paths/path'))) {
        $cfr = $p.GetAttribute('copyfrom-rev')
        if (-not [string]::IsNullOrWhiteSpace($cfr)) { return $cfr }
    }
    return ''
}

# Thin wrapper: run svn for a branch URL, feed its XML to the pure parser. Softens EAP so a native
# stderr write cannot throw a NativeCommandError under EAP=Stop; throws on a genuine non-zero exit
# so callers never treat empty as "not a copy".
function Get-SvnBranchCopyfromRev {
    param([Parameter(Mandatory = $true)][string]$BranchUrl)

    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $xml = (& svn log -v --stop-on-copy --xml $BranchUrl 2>$null | Out-String)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($LASTEXITCODE -ne 0) { throw "svn log --stop-on-copy failed for $BranchUrl" }
    return (Get-SvnCopyfromRevFromXml -Xml $xml)
}

# Getter: return the value of tp:<Name> on -Target (a branch URL or a working-copy path), or ''
# when the property is absent. `svn propget` on a missing custom property exits NON-ZERO with empty
# output (observed rc=1 on 1.14), so we suppress stderr, soften EAP (so a stderr write cannot throw
# under EAP=Stop -- precedent: Assert-TrustedSvnUrl), and do NOT trust the exit code. Trim the
# trailing CR/LF propget + Out-String append.
function Get-TpBranchProp {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Target
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $val = (& svn propget "tp:$Name" $Target 2>$null | Out-String)
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ($null -eq $val) { return '' }
    return ($val -replace '(\r?\n)+$', '')
}

# Setter: in the branch working copy set tp:<Name>=<Value>, then a SCOPED property commit and an
# `svn update`. `--depth empty` + the explicit '.' target is load-bearing -- the fb42a63 fix that
# stops `svn checkout --force` overlay drift being swept into the commit; the trailing `svn update`
# clears the mixed-revision lag so the next build falsely-demand-a-pull check passes. Push-Location
# + explicit $LASTEXITCODE checks after each native call mirror New-RemoteBridge.ps1. Fixed ASCII msg.
function Set-TpBranchProp {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$WorkingCopy
    )
    Push-Location -LiteralPath $WorkingCopy
    try {
        & svn propset "tp:$Name" $Value '.'
        if ($LASTEXITCODE -ne 0) { throw "svn propset tp:$Name failed" }
        & svn commit --depth empty -m "set tp:$Name (turbo-plugin metadata)" '.'
        if ($LASTEXITCODE -ne 0) { throw "svn commit tp:$Name failed" }
        & svn update | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "svn update after tp:$Name commit failed" }
    } finally {
        Pop-Location
    }
}

# Resolve a caller-supplied relative path against a worktree root, refusing anything that escapes
# it. Returns the resolved absolute path.
#
# Why this is worth a guard even though the value is not attacker-supplied in practice: the caller
# (Remove-SvnFile) uses the result for `svn delete` + `svn commit` against the SHARED repository,
# and that is irreversible -- deleting the wrong path costs everyone on the team a recovery, and
# SVN history keeps the mistake forever. The path arrives from an agent reading `git status` /
# `svn status` output, so a `..` segment means something upstream is already wrong; the point is to
# stop there rather than to discover it after the commit. Mirrors the existing fail-closed stance
# of the SVN URL trust check above, which rejects `..` outright rather than trying to sanitize it.
function Resolve-PathWithinWorktree {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$RelativePath
    )

    if ([string]::IsNullOrWhiteSpace($RelativePath)) {
        throw "Refusing an empty path."
    }
    if ([System.IO.Path]::IsPathRooted($RelativePath)) {
        throw "Refusing an absolute path: '$RelativePath'. Paths are relative to the worktree root."
    }
    # Check the segments, not a substring: a filename may legitimately contain '..' (e.g. "a..b.txt")
    # and rejecting that would be wrong.
    $segments = ($RelativePath -replace '\\', '/') -split '/'
    if ($segments -contains '..') {
        throw "Refusing a path containing '..': '$RelativePath'."
    }

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not $rootFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
        $rootFull += [System.IO.Path]::DirectorySeparatorChar
    }
    # GetFullPath (not GetRelativePath -- that one is .NET Core only and absent on PS 5.1) collapses
    # any remaining oddities, so the prefix test below sees the real destination.
    $targetFull = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $RelativePath))

    if (-not $targetFull.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a path that resolves outside the worktree: '$RelativePath' -> $targetFull"
    }
    return $targetFull
}

