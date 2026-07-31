[CmdletBinding()]
param(
    [switch]$CheckOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

# Add the IIS Express development certificate to THIS USER's trusted-root store, so the browser
# stops warning on https://localhost. Same thing Visual Studio's one-time "install this
# certificate?" prompt does.
#
# Scope and risk, deliberately narrow:
#   * Writes to CurrentUser\Root only -- this Windows user, no administrator rights, reversible.
#   * Does NOT create certificates and does NOT touch http.sys port bindings. Both of those are
#     machine-global and need elevation; installing IIS Express already did them (ports
#     44300-44399 come pre-bound to this very certificate).
#   * Trust is optional. Without it https still serves, the browser just shows a warning. So
#     nothing in this plugin fails because the certificate is untrusted.
#
# WHY THIS IS A SEPARATE, EXPLICITLY-INVOKED SCRIPT rather than a step folded into a launch:
# Windows shows its own security dialog when anything is added to a Root store, and that dialog
# cannot be suppressed through the supported API. The call therefore BLOCKS until a human clicks.
# Buried inside setup that reads as a hang; as a short, separately-invoked command -- announced
# beforehand by the SKILL -- the block is expected and explained. It is also a security decision,
# which the user should make knowingly rather than absorb as a side effect of "setup".
#
# -CheckOnly reports the current state and writes nothing; it is what diagnostics should call.

try {
    Probe-GitVersion

    $cert = Get-IisExpressDevCert
    if ($null -eq $cert) {
        throw @"
找不到 IIS Express 的開發憑證(LocalMachine\My 裡沒有)。
通常表示這台機器沒有安裝 IIS Express,或安裝不完整 — 重新安裝 IIS Express 即可取得該憑證。
"@
    }

    $trusted = Test-IisExpressCertTrusted -Certificate $cert

    if ($trusted) {
        Write-Output 'CERT_OUTPUT (relay these lines to the user as the result):'
        Write-Output "  憑證     : $($cert.Subject) ($($cert.FriendlyName))"
        Write-Output "  指紋     : $($cert.Thumbprint)"
        Write-Output '  狀態     : 已在信任清單中,未做任何變更'
        exit 0
    }

    if ($CheckOnly) {
        Write-Output 'CERT_OUTPUT (relay these lines to the user as the result):'
        Write-Output "  憑證     : $($cert.Subject) ($($cert.FriendlyName))"
        Write-Output "  指紋     : $($cert.Thumbprint)"
        Write-Output '  狀態     : 尚未信任(瀏覽器會顯示憑證警告;不影響站台能否啟動)'
        Write-Output "TP_TOKEN:CERT_UNTRUSTED thumbprint=$($cert.Thumbprint)"
        exit 0
    }

    # Announce before blocking: the OS dialog is about to appear and the script will wait on it.
    Write-Output '即將把開發憑證加入你的信任清單。Windows 會跳出它自己的安全性確認視窗,'
    Write-Output '請按「是」完成;在你按下之前這裡會一直等待。'

    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
        [System.Security.Cryptography.X509Certificates.StoreName]::Root,
        [System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser)
    try {
        $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
        $store.Add($cert)
    } finally {
        $store.Close()
    }

    # Verify by reading the store back rather than trusting the call: declining the OS dialog
    # surfaces in different ways across Windows versions, and a silent no-op would otherwise be
    # reported as success.
    if (-not (Test-IisExpressCertTrusted -Certificate $cert)) {
        throw @"
憑證沒有被加入信任清單(可能是在 Windows 的確認視窗按了「否」)。
https 仍然可以使用,只是瀏覽器會顯示憑證警告。要再試一次就重跑這個指令。
"@
    }

    Write-Output 'CERT_OUTPUT (relay these lines to the user as the result):'
    Write-Output "  憑證     : $($cert.Subject) ($($cert.FriendlyName))"
    Write-Output "  指紋     : $($cert.Thumbprint)"
    Write-Output '  狀態     : 已加入信任清單,瀏覽器不會再顯示憑證警告'
    Write-Output '  影響範圍 : 只有目前這個 Windows 使用者帳號'
    Write-Output '  要還原   : 在「憑證管理員」的「受信任的根憑證授權單位」中刪除上述指紋的憑證'
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
