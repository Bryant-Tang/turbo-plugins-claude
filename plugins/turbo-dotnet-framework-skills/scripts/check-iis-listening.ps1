Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

try {
    $settings = Resolve-IisSettings
    $matches = @((& netstat -ano | Select-String -Pattern ":$($settings.IisPort)" | ForEach-Object { $_.Line }))

    if ($matches.Count -eq 0) {
        Write-Output "No listening socket found for IISUrl port: $($settings.IisPort)"
        exit 1
    }

    $listeningMatches = @($matches | Where-Object { $_ -match 'LISTENING' })

    if ($listeningMatches.Count -eq 0) {
        Write-Output "Port is present but not LISTENING for IISUrl port: $($settings.IisPort)"
        $matches | ForEach-Object { Write-Output $_ }
        exit 1
    }

    $listeningMatches | ForEach-Object { Write-Output $_ }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
