Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'Common.ps1'))

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

    if (Test-Path -LiteralPath $markerDir -PathType Container) {
        # Marker present — bootstrap is done. turbo-plugin-git-svn has no marker-present
        # runtime concern (dbhub / IIS applicationhost live in sibling plugins), so this
        # is a silent exit.
        Emit-Json @{}
        exit 0
    }

    # Marker missing — plugin installed but bootstrap not done
    $commonDir = (& git rev-parse --path-format=absolute --git-common-dir 2>$null | Out-String).Trim()
    $topLevel = (& git rev-parse --path-format=absolute --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($commonDir) -or [string]::IsNullOrWhiteSpace($topLevel)) {
        Emit-Json @{}
        exit 0
    }
    $mainPath = Get-NormalizedAbsolutePath -Path ([System.IO.Path]::GetDirectoryName($commonDir))
    $curPath = Get-NormalizedAbsolutePath -Path $topLevel

    if ($mainPath -eq $curPath) {
        Emit-Json @{ systemMessage = "turbo-plugin: 偵測到本 worktree 尚未 bootstrap。請執行 `/tp-setup` 完成設定。" }
    } else {
        Emit-Json @{ systemMessage = "turbo-plugin: 偵測到本 worktree 尚未 bootstrap,且這裡是 peer worktree。請到主 worktree ($mainPath) 啟動 Claude 並執行 /tp-setup,完成 bootstrap 後再回此 worktree 工作。" }
    }
    exit 0
} catch {
    [Console]::Error.WriteLine("turbo-plugin Invoke-SessionStart: $($_.Exception.Message)")
    Emit-Json @{}
    exit 0
}
