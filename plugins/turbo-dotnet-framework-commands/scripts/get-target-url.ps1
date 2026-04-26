Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

try {
    $settings = Resolve-IisSettings -ScriptDir $PSScriptRoot
    Write-Output "IIS URL: $($settings.IisUrl)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
