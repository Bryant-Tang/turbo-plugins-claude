Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

try {
    $settings = Resolve-IisSettings

    if ($settings.IisScheme -eq 'https' -and [string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        throw "Configured IISUrl uses HTTPS: $($settings.IisUrl)`nMissing RUN_IIS_APPLICATIONHOST_CONFIG_PATH in .claude/scripts.local.psd1.`nProvide an applicationhost.config path so IIS Express can start with /config and /site."
    }

    if ([string]::IsNullOrWhiteSpace($settings.IisExpressPath)) {
        throw 'Missing RUN_IIS_EXPRESS_PATH in .claude/scripts.local.psd1'
    }

    if (-not (Test-Path -LiteralPath $settings.IisExpressPath -PathType Leaf)) {
        throw "Configured IIS Express executable does not exist: $($settings.IisExpressPath)"
    }

    if (-not [string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        Start-Process -FilePath $settings.IisExpressPath -ArgumentList @("/config:$($settings.ApplicationhostConfigFile)", "/site:$($settings.IisConfigSiteName)") -WindowStyle Hidden | Out-Null
        Write-Output "Started IIS Express with applicationhost.config site: $($settings.IisConfigSiteName)"
        exit 0
    }

    $process = Start-Process -FilePath $settings.IisExpressPath -ArgumentList @("/path:$($settings.SiteRoot)", "/port:$($settings.IisPort)") -WindowStyle Hidden -PassThru
    Write-Output "Started IIS Express background process: $($process.Id)"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
