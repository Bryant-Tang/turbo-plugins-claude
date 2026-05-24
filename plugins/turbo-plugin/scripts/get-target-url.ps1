param(
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'common.ps1'))
. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

try {
    $settings = Resolve-IisSettings -Project $Project
    Write-Output "IIS URL: $($settings.IisUrl)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
