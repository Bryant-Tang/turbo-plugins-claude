<#
.SYNOPSIS
turbo-plugin-three-environment-db: rename ONE database environment.

.DESCRIPTION
Renames <sql_root>/<From>/ to <sql_root>/<To>/ AND rewrites the environment name inside every
.sql file under it -- the header fields ("目標環境", "基線來源環境", "檔案落點", and the
per-environment path list) carry the name as text, so renaming only the directory leaves every
file claiming it belongs somewhere it no longer is. Those headers are what tells a reader which
environment a baseline came from, so a half-done rename is worse than none.

DRY RUN BY DEFAULT. Nothing is touched until -Apply. A real project has hundreds of these files
and the damage from a wrong match is silent, so the default has to be the harmless one.

The .sh peer (rename-db-environment.sh) is a separate native implementation with the same
behaviour; both are driven by their own test suite.

.EXAMPLE
.\Rename-DbEnvironment.ps1 local-db dev-db
.EXAMPLE
.\Rename-DbEnvironment.ps1 local-db dev-db -Apply
#>
param(
    [Parameter(Mandatory = $true, Position = 0)][string]$From,
    [Parameter(Mandatory = $true, Position = 1)][string]$To,
    [switch]$Apply,
    [string]$SqlRoot = '',
    [string]$Root = ''
)

# Set-StrictMode comes AFTER param(): a script's param block must be the first statement in the
# file (comments aside), so putting the strict-mode call above it turns `param(...)` into a call
# to a command named `param` and the file stops parsing.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Core.ps1'))

function Fail {
    param([string]$Message)
    Write-Error "rename-db-environment: $Message"
    exit 1
}

# Restrict both names to what a folder name may safely be. This is not only hygiene: the names go
# into a regex and into a replacement string, where '$', '\' and '.' all mean something other than
# themselves. Refusing the characters outright is simpler than escaping them everywhere, and a
# database environment has no reason to need them.
foreach ($n in @($From, $To)) {
    if ($n -notmatch '^[A-Za-z0-9._-]+$') {
        Fail "environment name may only contain letters, digits, '.', '_' and '-': '$n'"
    }
    if ($n.StartsWith('.') -or $n.EndsWith('.')) {
        Fail "environment name must not start or end with '.': '$n'"
    }
}
if ($From -eq $To) { Fail "<From> and <To> are the same: '$From'" }

if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
    Fail "workspace root is not a directory: $Root"
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$configPath = [System.IO.Path]::Combine($Root, '.turbo-plugin', 'config.toml')

# Resolve <sql_root> the same way the skill does: [db] sql_root, else the default.
$sqlRootRel = ''
if (-not [string]::IsNullOrWhiteSpace($SqlRoot)) {
    $sqlRootRel = $SqlRoot
} elseif (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $cfg = Read-TurboPluginConfig -ConfigPath $configPath
    if ($cfg.ContainsKey('db') -and $cfg['db'].ContainsKey('sql_root')) {
        $sqlRootRel = [string]$cfg['db']['sql_root']
    }
}
if ([string]::IsNullOrWhiteSpace($sqlRootRel)) { $sqlRootRel = '.turbo-plugin/sql' }
$sqlRootRel = $sqlRootRel.TrimEnd('/', '\')

$sqlRootPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($Root, $sqlRootRel))
$oldDir = [System.IO.Path]::Combine($sqlRootPath, $From)
$newDir = [System.IO.Path]::Combine($sqlRootPath, $To)

if (-not (Test-Path -LiteralPath $sqlRootPath -PathType Container)) { Fail "SQL root does not exist: $sqlRootPath" }
if (-not (Test-Path -LiteralPath $oldDir -PathType Container))      { Fail "no such environment folder: $oldDir" }
if (Test-Path -LiteralPath $newDir)                                  { Fail "target already exists, refusing to merge two environments: $newDir" }

# Word boundaries so a rename like test -> test-db cannot turn an existing 'test-db' into
# 'test-db-db'. The name charset above is exactly what counts as "inside a word" here.
$boundL = '(^|[^A-Za-z0-9._-])'
$boundR = '([^A-Za-z0-9._-]|$)'
$matchRe = $boundL + [regex]::Escape($From) + $boundR
$replaceWith = '${1}' + $To + '${2}'

# @() so a single .sql file still yields an array -- .Count on a bare FileInfo reads a property
# that is not the file count.
$sqlFiles = @(Get-ChildItem -LiteralPath $oldDir -Recurse -File -Filter '*.sql' -ErrorAction SilentlyContinue |
              Sort-Object -Property FullName)

$hitFiles = 0
$hitLines = 0
$hitReport = New-Object System.Collections.ArrayList
$fileHits = @{}
foreach ($f in $sqlFiles) {
    $lines = @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)
    $n = @($lines | Where-Object { $_ -match $matchRe }).Count
    if ($n -gt 0) {
        $hitFiles++
        $hitLines += $n
        $fileHits[$f.FullName] = $n
        $rel = Get-RelativePathSafe -From $Root -To $f.FullName
        [void]$hitReport.Add("    $rel  ($n 行)")
    }
}

# The environments line in config.toml, if there is an uncommented one that mentions <From>.
$configLine = ''
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $configLines = @(Get-Content -LiteralPath $configPath -Encoding UTF8)
    $configLine = @($configLines | Where-Object { $_ -match '^\s*environments\s*=' } | Select-Object -First 1)
    if ($configLine.Count -gt 0) { $configLine = [string]$configLine[0] } else { $configLine = '' }
}
$configNeedsUpdate = ($configLine -ne '' -and $configLine -match $matchRe)

$oldRel = Get-RelativePathSafe -From $Root -To $oldDir
$newRel = Get-RelativePathSafe -From $Root -To $newDir

Write-Output "rename-db-environment: $From -> $To"
Write-Output "  工作區根 : $Root"
Write-Output "  SQL root : $sqlRootRel"
Write-Output ''
Write-Output '  [1] 目錄改名'
Write-Output "      $oldRel  ->  $newRel"
Write-Output "  [2] .sql 檔頭改寫: $hitFiles 個檔 / $hitLines 行 (掃過 $($sqlFiles.Count) 個 .sql)"
foreach ($line in $hitReport) { Write-Output $line }
Write-Output '  [3] config.toml 的 environments'
if ($configNeedsUpdate) {
    Write-Output "      會把那一行裡的 $From 換成 $To"
} elseif ($configLine -ne '') {
    Write-Output "      有 environments 但沒提到 $From — 不動它"
} else {
    Write-Output '      沒有未註解的 environments —— 改完請自己加一行,否則 tp-db-management 會看到'
    Write-Output '      「磁碟上有、清單裡沒有」而停下來:'
    Write-Output "        environments = [`"$To`", ...]"
}

if (-not $Apply) {
    Write-Output ''
    Write-Output '  這是 dry run,什麼都沒有改。確認無誤後加 -Apply。'
    exit 0
}

Write-Output ''
Write-Output '  套用中...'

# Content first, directory second: rewriting after the move would mean recomputing every path.
foreach ($f in $sqlFiles) {
    if (-not $fileHits.ContainsKey($f.FullName)) { continue }
    $text = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
    # Twice: a single pass consumes the boundary character, so two matches sharing one separator
    # (".../local-db/local-db/...") would leave the second behind. The second pass is a no-op
    # whenever the first was enough.
    $text = [regex]::Replace($text, $matchRe, $replaceWith)
    $text = [regex]::Replace($text, $matchRe, $replaceWith)
    Write-Utf8NoBom -Path $f.FullName -Content $text
}

$movedWithGit = $false
$isRepo = $false
try {
    $null = & git -C $Root rev-parse --is-inside-work-tree 2>$null
    $isRepo = ($LASTEXITCODE -eq 0)
} catch { $isRepo = $false }
if ($isRepo) {
    try {
        $null = & git -C $Root mv $oldDir $newDir 2>$null
        $movedWithGit = ($LASTEXITCODE -eq 0)
    } catch { $movedWithGit = $false }
}
if (-not $movedWithGit) {
    Move-Item -LiteralPath $oldDir -Destination $newDir
}

if ($configNeedsUpdate) {
    # ReadAllText + splice the one line, NOT Get-Content + rejoin. Get-Content strips the line
    # terminators and rejoining with "`n" rewrites EVERY line of a CRLF file as LF -- a whole-file
    # diff for a one-line change, and a behaviour the .sh peer does not share (sed treats \r as
    # line content and leaves it alone). It also used to append a trailing newline the file may
    # not have had.
    #
    # [^\r\n]* rather than .* keeps the \r outside the captured line, so the terminator is part of
    # the untouched remainder. No MatchEvaluator: a scriptblock-as-delegate works on 5.1 but is a
    # needless moving part when the match position is all that is needed.
    $text = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $lineMatch = [regex]::Match($text, '(?m)^[ \t]*environments[ \t]*=[^\r\n]*')
    if ($lineMatch.Success) {
        $oldLine = $lineMatch.Value
        $newLine = [regex]::Replace([regex]::Replace($oldLine, $matchRe, $replaceWith), $matchRe, $replaceWith)
        $text = $text.Remove($lineMatch.Index, $lineMatch.Length).Insert($lineMatch.Index, $newLine)
        Write-Utf8NoBom -Path $configPath -Content $text
    }
}

$moveHow = if ($movedWithGit) { '是(git mv)' } else { '是(檔案系統)' }
$configHow = if ($configNeedsUpdate) { '已更新' } else { '未動' }
Write-Output '  完成。'
Write-Output "    目錄改名  : $moveHow"
Write-Output "    檔案改寫  : $hitFiles 個"
Write-Output "    config    : $configHow"
Write-Output ''
Write-Output '  接下來:檢查 git diff 再 commit。基線檔頭是判斷「這份基線來自哪個環境」的唯一線索,'
Write-Output '  值得看過一遍。'
exit 0
