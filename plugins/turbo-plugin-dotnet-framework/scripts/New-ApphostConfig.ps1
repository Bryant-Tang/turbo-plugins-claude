[CmdletBinding()]
param(
    [string]$Project = '',
    [switch]$Force,
    [string]$RepoRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'ApplicationHostHelpers.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

# Generate .turbo-plugin/applicationhost.config for a project, without needing Visual Studio.
#
# Every input Visual Studio uses to synthesise its <site> entry is checked into the .csproj
# (<IISUrl> / <IISExpressSSLPort> / <DevelopmentServerPort> / <IISExpressUseClassicPipelineMode>),
# so the config can be reproduced faithfully instead of asking the user to open VS once purely to
# make a file appear -- which contradicted the whole point of this plugin.
#
# The generated site carries the PLAIN project name and a physicalPath placeholder, i.e. exactly
# the canonical shape Start-Iis expects: nothing machine-specific, safe to commit and share. The
# identity-hashed runtime name and the real path are applied to the per-launch temp copy.
#
# HTTPS needs no certificate work here: installing IIS Express pre-binds ports 44300-44399 in
# http.sys to its own development certificate, which is why VS projects pick an SSL port from that
# range. The one-time "trust this certificate?" prompt VS shows is a per-MACHINE trust step, not a
# per-project one. This script therefore only DIAGNOSES the https prerequisites and reports them --
# creating or binding certificates is out of scope (binding needs elevation).

# Report whether http.sys already has an SSL certificate bound to $Port.
# Returns $true / $false, or $null when the binding table could not be read at all.
function Test-SslPortBound {
    param([string]$Port)
    $out = ''
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        $out = (& netsh http show sslcert 2>$null | Out-String)
    } catch {
        $out = ''
    } finally {
        $ErrorActionPreference = $prevEAP
    }
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    # Binding lines end with "<ip>:<port>"; anchor on the line end so 44300 never matches 443001.
    return [regex]::IsMatch($out, "(?m):$([regex]::Escape($Port))\s*$")
}

try {
    Probe-GitVersion

    $repoRoot = Resolve-DotnetRepoRoot -RepoRoot $RepoRoot

    $iisEnabled = Resolve-ConfigValue -RepoRoot $repoRoot -Section 'iis' -Key 'enabled' -CliValue $null -Default $true
    if ($iisEnabled -eq $false) {
        throw @"
IIS 已停用 (.turbo-plugin/config.toml [iis] enabled = false)。
若需要使用 IIS 相關功能,請編輯該檔將 enabled 設為 true 或移除該設定
(預設啟用)。
"@
    }

    # A .sln has no IIS settings; the site is always generated for one web csproj.
    $target = Resolve-ProjectTarget -RepoRoot $repoRoot -Section 'run' -CliProjectValue $Project
    $projectFile = $target.Path

    $canonical = Find-ApplicationhostTarget -RepoRoot $repoRoot -ProjectFile $projectFile
    $siteName = [System.IO.Path]::GetFileNameWithoutExtension($projectFile)

    # Read the csproj before touching anything on disk: a project with no IIS settings at all must
    # fail without leaving a half-written config behind.
    $binding = Get-IisProjectBinding -ProjectFile $projectFile

    # -Force regenerates THIS project's site from the csproj. It drops only that one entry, never
    # the whole file -- a shared config can hold a site per web project, and rebuilding from the
    # template would silently discard the siblings.
    if ($Force -and (Test-Path -LiteralPath $canonical -PathType Leaf)) {
        $null = Remove-ApplicationhostSite -ConfigPath $canonical -SiteName $siteName
    }

    # Generating needs IIS Express itself: its shipped applicationhost.config is the template.
    # -ProjectFile so the template comes from the SAME install tp-run will later launch: with
    # <Use64BitIISExpress>true</Use64BitIISExpress> that is the 64-bit one (issue #50).
    $iisExpressPath = Find-IisExpressPath -RepoRoot $repoRoot -ProjectFile $projectFile

    $result = Initialize-ApplicationhostSite `
        -ConfigPath $canonical `
        -TemplatePath (Get-ApplicationhostTemplatePath -IisExpressPath $iisExpressPath) `
        -SiteName $siteName `
        -Binding $binding

    $configNote = if ($result.ConfigCreated) {
        '(新建)'
    } elseif ($result.ConfigRebuilt -and $result.SiteAdded) {
        '(原本的內容 IIS Express 載不進去,已重建並補上這個專案的站台)'
    } elseif ($result.ConfigRebuilt) {
        '(原本的內容 IIS Express 載不進去,已重建;站台保留)'
    } elseif ($result.SiteAdded) {
        '(已存在,已補上這個專案的站台)'
    } else {
        '(已存在,未變更)'
    }

    # ---- result template ------------------------------------------------------
    Write-Output 'APPHOST_OUTPUT (relay these lines to the user as the result):'
    Write-Output "  設定檔     : $canonical $configNote"
    Write-Output "  專案站台   : $siteName"
    Write-Output "  應用程式集區: $($result.AppPool)"
    Write-Output "  網站位址   : $($binding.Uri.Scheme)://localhost:$($binding.Port)"

    $sslPort = $binding.SslPort
    if (-not [string]::IsNullOrWhiteSpace($sslPort)) {
        Write-Output "  HTTPS 位址 : https://localhost:$sslPort"
        $inReserved = $false
        $sslPortInt = 0
        if ([int]::TryParse($sslPort, [ref]$sslPortInt)) {
            $inReserved = ($sslPortInt -ge 44300 -and $sslPortInt -le 44399)
        }
        $bound = Test-SslPortBound -Port $sslPort
        if ($bound -eq $true) {
            Write-Output '  HTTPS 憑證 : 這個 port 已經綁好憑證(IIS Express 安裝時預先設定),可直接使用'
        } elseif ($null -eq $bound) {
            Write-Output '  HTTPS 憑證 : 無法讀取系統的憑證綁定表,請自行確認'
        } elseif ($inReserved) {
            Write-Output '  HTTPS 憑證 : 這個 port 在 IIS Express 保留範圍內,但目前沒有綁定憑證 — 通常表示 IIS Express 未正確安裝,重裝可修復'
        } else {
            Write-Output "  HTTPS 憑證 : ⚠ port $sslPort 不在 IIS Express 預設綁好憑證的範圍(44300-44399),https 會連不上"
            Write-Output "               最簡單的修法是把專案的 <IISExpressSSLPort> 改成 44300-44399 之間的號碼;"
            Write-Output "               要沿用這個 port 則需要系統管理員權限自行綁定憑證"
        }
        # Trust is advisory: untrusted only costs a browser warning, the site still serves. Emit a
        # token so the SKILL can offer to fix it, but never fail the setup over it.
        $devCert = Get-IisExpressDevCert
        if (($null -ne $devCert) -and (-not (Test-IisExpressCertTrusted -Certificate $devCert))) {
            Write-Output '               (開發憑證尚未加入信任清單,瀏覽器會顯示憑證警告;信任與否不影響站台能否啟動)'
            Write-Output "TP_TOKEN:CERT_UNTRUSTED thumbprint=$($devCert.Thumbprint)"
        }
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
