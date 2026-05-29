param(
    [string]$Project = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'Common.ps1'))
. ([System.IO.Path]::Combine($PSScriptRoot, 'lib', 'IisHelpers.ps1'))

try {
    $settings = Resolve-IisSettings -Project $Project
    Write-Output "IIS URL: $($settings.IisUrl)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
