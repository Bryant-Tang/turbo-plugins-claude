Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Core.ps1'))

function Emit-Json {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Compress -Depth 6)
    [Console]::Out.Write($json)
}

try {
    # pre-check (1): inside a git work tree?
    $inside = (& git rev-parse --is-inside-work-tree 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $inside -ne 'true') {
        Emit-Json @{}
        exit 0
    }

    # pre-check (2): inside a submodule? silent exit if so
    if (Test-IsSubmodule) {
        Emit-Json @{}
        exit 0
    }

    $cwd = (Get-Location).Path
    $markerDir = Join-Path $cwd '.turbo-plugin'

    # db concern gate (KTD9): only act when this project uses db (the committed
    # dbhub.example.local.toml template is present). Otherwise silent no-op.
    $dbhubExample = Join-Path $markerDir 'dbhub.example.local.toml'
    if (-not (Test-Path -LiteralPath $dbhubExample -PathType Leaf)) {
        Emit-Json @{}
        exit 0
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

    # dbhub branch: peer worktree + missing dbhub.local.toml -> Pattern B prompt with hybrid warning
    if (-not (Test-IsMainWorktree)) {
        $dbhubLocal = Join-Path $markerDir 'dbhub.local.toml'
        if (-not (Test-Path -LiteralPath $dbhubLocal -PathType Leaf)) {
            $notes += "turbo-plugin-three-environment-db: 偵測到 Pattern B 啟動於 peer worktree,但缺少 `.turbo-plugin/dbhub.local.toml`。" + `
                "tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 `dbhub.local.toml` 過來,或結束 session 改到主 worktree 啟動(Pattern A)。" + `
                "Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 進別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
        }
    }

    if ($notes.Count -gt 0) {
        Emit-Json @{ systemMessage = ($notes -join ' ') }
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
