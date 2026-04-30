param(
    [Parameter(Mandatory)][string]$SettingsFile,
    [Parameter(Mandatory)][string]$EnvJson
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Utf8NoBom {
    param([string]$FilePath, [string]$Content)
    [System.IO.File]::WriteAllText($FilePath, $Content, (New-Object System.Text.UTF8Encoding $false))
}

try {
    # Parse incoming env pairs
    try {
        $incoming = $EnvJson | ConvertFrom-Json
    } catch {
        throw "Invalid env JSON argument: $_"
    }

    # Ensure parent directory exists
    $dir = [System.IO.Path]::GetDirectoryName($SettingsFile)
    [System.IO.Directory]::CreateDirectory($dir) | Out-Null

    # Read existing settings or start fresh
    $settingsItem = Get-Item -LiteralPath $SettingsFile -ErrorAction SilentlyContinue
    if ($null -ne $settingsItem -and $settingsItem.Length -gt 0) {
        try {
            $rawContent = Get-Content -LiteralPath $SettingsFile -Raw -Encoding UTF8
            $existing = $rawContent | ConvertFrom-Json
        } catch {
            [Console]::Error.WriteLine("$SettingsFile is not valid JSON: $_")
            exit 1
        }
    } else {
        $existing = [PSCustomObject]@{}
    }

    # Ensure env block exists
    if ($null -eq $existing.PSObject.Properties['env'] -or $null -eq $existing.env) {
        $existing | Add-Member -NotePropertyName 'env' -NotePropertyValue ([PSCustomObject]@{}) -Force
    }

    # Merge incoming properties into env block
    foreach ($prop in $incoming.PSObject.Properties) {
        $existing.env | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
    }

    # Atomic write: write to .tmp then rename over the target
    # Use a temp JSON file to pass compact output to node for 2-space reformatting,
    # avoiding PS 5.1's argument-quoting bug that strips double-quotes from JSON strings.
    $tmpFile = $SettingsFile + '.tmp'
    $jsonCompact = $existing | ConvertTo-Json -Depth 32 -Compress
    $tmpJsonFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tmpJsonFile, $jsonCompact)
        $json = (& node -e "const fs=require('fs');process.stdout.write(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1],'utf8')),null,2)+'\n')" $tmpJsonFile) -join "`n"
    } finally {
        [System.IO.File]::Delete($tmpJsonFile)
    }
    Write-Utf8NoBom -FilePath $tmpFile -Content $json
    Move-Item -LiteralPath $tmpFile -Destination $SettingsFile -Force

} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
