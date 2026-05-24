Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, '..', 'lib', 'applicationhost-helpers.ps1'))

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
    $cwdNorm = Get-NormalizedAbsolutePath -Path $cwd
    $markerDir = Join-Path $cwd '.turbo-plugin'

    if (Test-Path -LiteralPath $markerDir -PathType Container) {
        # Branch (i): marker exists — auto-fix applicationhost.config physicalPath if stale.
        # IIS Express is Windows-only; stale physicalPaths happen on worktree move/rename.
        $apphostSrc = Join-Path $markerDir 'applicationhost.config'
        if (Test-Path -LiteralPath $apphostSrc -PathType Leaf) {
            $csprojFiles = @(Get-ChildItem -LiteralPath $cwd -Recurse -Filter '*.csproj' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -notmatch '\\(bin|obj|node_modules|\.vs|\.git)\\' })
            if ($csprojFiles.Count -gt 0) {
                $slnFile = @(Get-ChildItem -LiteralPath $cwd -Filter '*.sln' -ErrorAction SilentlyContinue) | Select-Object -First 1
                if ($null -ne $slnFile) {
                    $slnStem = [System.IO.Path]::GetFileNameWithoutExtension($slnFile.FullName)
                    $apphostTarget = Join-Path $cwd ".vs/$slnStem/config/applicationhost.config"
                    if (Test-Path -LiteralPath $apphostTarget -PathType Leaf) {
                        foreach ($csproj in $csprojFiles) {
                            $rel = Get-RelativePathSafe -From $cwd -To $csproj.FullName
                            $hash = Get-ProjectIdentityHash -RepoPath $cwd -CsprojRelPath $rel
                            $siteName = Format-IisExpressSiteName -CsprojPath $csproj.FullName -IdentityHash $hash
                            $newPhysicalPath = [System.IO.Path]::GetDirectoryName($csproj.FullName)
                            try {
                                Update-ApplicationhostConfig -ConfigPath $apphostTarget -SiteName $siteName -NewPhysicalPath $newPhysicalPath | Out-Null
                            } catch {
                                # Site not yet registered (VS hasn't created it) — not an error here.
                                # Only emit systemMessage if Update-ApplicationhostConfig itself fails unexpectedly.
                                $errMsg = $_.Exception.Message
                                if ($errMsg -notmatch "not found in applicationhost\.config") {
                                    Emit-Json @{ systemMessage = "turbo-plugin: 自動修正 applicationhost.config 失敗: $errMsg。請執行 ``/tp-setup`` 完成設定。" }
                                    exit 0
                                }
                            }
                        }
                    }
                }
            }
        }

        # Branch (ii): peer worktree + missing dbhub.local.toml → Pattern B prompt with hybrid warning
        if (-not (Test-IsMainWorktree)) {
            $dbhubLocal = Join-Path $markerDir 'dbhub.local.toml'
            if (-not (Test-Path -LiteralPath $dbhubLocal -PathType Leaf)) {
                $msg = "turbo-plugin: 偵測到 Pattern B 啟動於 peer worktree,但缺少 `.turbo-plugin/dbhub.local.toml`。" + `
                    "tp-dbhub MCP server 將無法啟動。若要使用 dbhub,請從主 worktree 複製 `dbhub.local.toml` 過來,或結束 session 改到主 worktree 啟動(Pattern A)。" + `
                    "Hybrid 警告:Pattern B 啟動後再用 EnterWorktree 進別的 worktree 不會切換 MCP 連線(已鎖定原 peer)。"
                Emit-Json @{ systemMessage = $msg }
                exit 0
            }
        }

        # All good → silent exit
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
    [Console]::Error.WriteLine("turbo-plugin sessionstart: $($_.Exception.Message)")
    Emit-Json @{}
    exit 0
}
