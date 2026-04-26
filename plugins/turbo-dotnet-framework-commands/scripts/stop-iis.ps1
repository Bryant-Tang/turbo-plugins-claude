Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'resolve-iis-settings.ps1')

function Normalize-PathString {
    param([string]$PathValue)

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return $null
    }

    # Convert Git Bash Unix drive path: /c/foo/bar → C:\foo\bar
    if ($PathValue -match '^/([a-zA-Z])/(.*)$') {
        $PathValue = "$($Matches[1].ToUpper()):\$($Matches[2] -replace '/', '\')"
    }

    return [System.IO.Path]::GetFullPath($PathValue)
}

try {
    $settings = Resolve-IisSettings
    $iisExpressPath = Normalize-PathString -PathValue $settings.IisExpressPath

    if ([string]::IsNullOrWhiteSpace($iisExpressPath)) {
        throw 'Missing RUN_IIS_EXPRESS_PATH in .claude/settings.local.json'
    }

    $processName = [System.IO.Path]::GetFileNameWithoutExtension($iisExpressPath)

    if ([string]::IsNullOrWhiteSpace($processName)) {
        throw 'Missing RUN_IIS_EXPRESS_PATH in .claude/settings.local.json'
    }

    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = '$($processName).exe'" -ErrorAction SilentlyContinue)

    if (-not [string]::IsNullOrWhiteSpace($settings.ApplicationhostConfigFile)) {
        $processes = @($processes | Where-Object {
            (Normalize-PathString -PathValue $_.ExecutablePath) -eq $iisExpressPath -and
            $_.CommandLine -like "*/config:*" -and
            $_.CommandLine -like "*$($settings.ApplicationhostConfigFile)*" -and
            $_.CommandLine -like "*/site:*" -and
            $_.CommandLine -like "*$($settings.IisConfigSiteName)*"
        })
    }
    else {
        $processes = @($processes | Where-Object {
            (Normalize-PathString -PathValue $_.ExecutablePath) -eq $iisExpressPath -and
            $_.CommandLine -like "*/path:*" -and
            $_.CommandLine -like "*$($settings.SiteRoot)*" -and
            $_.CommandLine -like "*/port:*" -and
            $_.CommandLine -like "*$($settings.IisPort)*"
        })
    }

    if ($null -eq $processes -or $processes.Count -eq 0) {
        Write-Output "No repo-specific $processName process found."
        exit 0
    }

    $processes | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
