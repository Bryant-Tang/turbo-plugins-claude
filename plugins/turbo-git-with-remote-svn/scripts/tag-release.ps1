[CmdletBinding()]
param(
    [string]$Branch = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($Branch)) { throw 'Missing required argument: -Branch <main|test-<n>>' }

    if ($Branch -eq 'main') {
        $remoteBranch = 'remote/main'
    } elseif ($Branch -match '^test-(\d+)$') {
        $remoteBranch = "remote/test-$($Matches[1])"
    } else {
        throw "Unsupported branch '$Branch'. Only 'main' and 'test-<n>' branches are supported."
    }

    $prefix = "$Branch-release-$(Get-Date -Format 'yyyy-MM-dd')"
    $existing = git tag -l "$prefix-[0-9][0-9][0-9]" | Sort-Object | Select-Object -Last 1

    if ([string]::IsNullOrEmpty($existing)) {
        $serial = '001'
    } else {
        $lastNum = [int]($existing -split '-' | Select-Object -Last 1)
        $serial = '{0:D3}' -f ($lastNum + 1)
    }

    $tagName = "$prefix-$serial"
    git tag $tagName $remoteBranch
    if ($LASTEXITCODE -ne 0) { throw "git tag failed" }
    Write-Output "Created tag: $tagName"
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
