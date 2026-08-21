Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Core.ps1'))

function Emit-Json {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Compress -Depth 6)
    [Console]::Out.Write($json)
}

# Emit BOTH channels.
#
# `systemMessage` is Claude Code printing a warning to the user -- not the assistant speaking, so
# it needs no user turn. But the docs do not pin down WHEN SessionStart's systemMessage renders,
# so relying on it alone bets on undocumented behaviour. `additionalContext` has the contract we
# actually need: inserted into Claude's context "at the start of the conversation, before the
# first prompt". So whatever the user types first, the assistant already knows why the database
# server cannot start -- instead of investigating from scratch, which is what happened 2026-08-03.
function Emit-Notice {
    param([string]$Message)
    Emit-Json @{
        systemMessage      = $Message
        hookSpecificOutput = @{
            hookEventName    = 'SessionStart'
            additionalContext = $Message
        }
    }
}

# The db marker has TWO accepted names, and both have to stay. `dbhub.example.toml` is what
# tp-setup deploys now; `dbhub.example.local.toml` is what every project set up before the rename
# already has committed. Recognising only the new name would make this hook conclude those projects
# do not use a database and go silent -- exactly the failure shape the gate below exists to prevent,
# and the user would get no signal that anything changed. Drop the old name only once no project is
# still on it.
function Test-DbMarkerIn {
    param([string]$Dir)
    foreach ($name in @('dbhub.example.toml', 'dbhub.example.local.toml')) {
        $marker = [System.IO.Path]::Combine($Dir, '.turbo-plugin', $name)
        if (Test-Path -LiteralPath $marker -PathType Leaf) { return $true }
    }
    return $false
}

try {
    $cwd = (Get-Location).Path
    $markerDir = Join-Path $cwd '.turbo-plugin'

    # db concern gate (KTD9): only act when db is actually in use. Otherwise a silent no-op.
    #
    # Look HERE first, then one level down -- the same resolution start-dbhub.js uses, and for the
    # same reason: in a multi-project workspace the session root is not any of the projects, so the
    # marker lives in a subdirectory. This gate used to look only at the cwd, and the whole hook
    # used to bail even earlier on "not a git repository" -- and a multi-project workspace root is
    # never a repo. Between them the hook could not fire in exactly the shape the db plugin's
    # multi-project support was built for: observed 2026-08-03, a session with no node on PATH said
    # nothing at all and the user had to ask why the MCP server was red.
    $dbInUse = Test-DbMarkerIn $cwd
    if (-not $dbInUse) {
        foreach ($dir in @(Get-ChildItem -LiteralPath $cwd -Directory -ErrorAction SilentlyContinue)) {
            if (Test-DbMarkerIn $dir.FullName) {
                $dbInUse = $true
                break
            }
        }
    }
    if (-not $dbInUse) {
        Emit-Json @{}
        exit 0
    }

    # Being inside a git work tree is NOT required to get this far -- only the peer-worktree branch
    # below needs it. `git rev-parse` writes "fatal: not a git repository" to stderr, which used to
    # surface to the user on a path that is meant to be a silent no-op, so keep it quiet.
    $inGitRepo = $false
    try {
        $eaGit = $ErrorActionPreference
        $ErrorActionPreference = 'SilentlyContinue'
        $inside = (& git rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
        $rc = $LASTEXITCODE
        $ErrorActionPreference = $eaGit
        if ($rc -eq 0 -and $inside -eq 'true' -and -not (Test-IsSubmodule)) { $inGitRepo = $true }
    } catch {
        $inGitRepo = $false
    }

    $notes = @()

    # node gate. The launcher `.mcp.json` runs is a node script, so when node is missing NOTHING
    # downstream can speak: the server dies before our code runs and the user gets a bare red cross
    # in /mcp with the reason buried in a debug log. This hook is the only component still running
    # in that case, so it is the one that has to say it. Gated on the db marker above, so a project
    # that does not use a database never sees it.
    if ($null -eq (Get-Command node -ErrorAction SilentlyContinue)) {
        $notes += "turbo-plugin-three-environment-db: 這個專案有用到資料庫,但這台機器的 PATH 上找不到 node。" +
                  "tp-dbhub MCP server 是用 node 啟動的,所以它不會起來(在 /mcp 只會看到一個紅叉,沒有其它說明)。" +
                  "裝好 Node.js 之後重開 session 就好。"
    }

    # dbhub branch: peer worktree + missing dbhub.local.toml -> Pattern B prompt with hybrid
    # warning. Only meaningful inside a repo -- "which worktree am I in" has no answer otherwise.
    if ($inGitRepo -and -not (Test-IsMainWorktree)) {
        $dbhubLocal = Join-Path $markerDir 'dbhub.local.toml'
        if (-not (Test-Path -LiteralPath $dbhubLocal -PathType Leaf)) {
            $notes += "turbo-plugin-three-environment-db: 偵測到 Pattern B 啟動於 peer worktree,但缺少 `.turbo-plugin/dbhub.local.toml`。" + `
                "tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 `dbhub.local.toml` 過來,或結束 session 改到主 worktree 啟動(Pattern A)。" + `
                "Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 進別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
        }
    }

    if ($notes.Count -gt 0) {
        Emit-Notice -Message ($notes -join ' ')
        exit 0
    }

    # All good -> silent exit
    Emit-Json @{}
    exit 0
} catch {
    [Console]::Error.WriteLine("turbo-plugin-three-environment-db Invoke-SessionStart: $($_.Exception.Message)")
    Emit-Json @{}
    exit 0
}
