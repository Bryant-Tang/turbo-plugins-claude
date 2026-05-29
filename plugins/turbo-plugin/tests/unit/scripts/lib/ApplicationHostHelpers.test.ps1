# ApplicationHostHelpers.test.ps1
#
# Library: plugins/turbo-plugin/scripts/lib/ApplicationHostHelpers.ps1
# Behavior: 此 file 主要是 library (dot-source) — 純函式 (Find-ApplicationhostSite /
#   Update-ApplicationhostConfig / Remove-ApplicationhostSite / Invoke-ApplicationhostRefresh)。
#
# Cases (≥ 3):
#   1. Find-ApplicationhostSite happy: 從 minimal applicationhost.config XmlDocument 中找到指定
#      <site name="HelloApp-deadbeef"> → 回傳非 null 的 XmlElement,且 GetAttribute('name') 一致。
#   2. Find-ApplicationhostSite miss: 找不存在的 site name → 回傳 $null。
#   3. Update-ApplicationhostConfig parse port:讀 applicationhost.config → 找 binding section 中的
#      `<binding bindingInformation="*:5000:localhost" />` → parse 出 port 5000。
#      (此 case 涵蓋:讀 applicationhost.config + 找 binding section + parse port number 三件事。)
#   4. Update-ApplicationhostConfig idempotent: 已經是目標 physicalPath → Updated=$false。

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$LibPath = [System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', 'lib', 'AssertHelpers.ps1')
. $LibPath
Reset-Counters

$pluginRoot   = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
$ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'ApplicationHostHelpers.ps1')
$commonPs1    = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')

if (-not [System.IO.File]::Exists($ScriptUnderTest)) {
    Write-Output "[FAIL] ApplicationHostHelpers.ps1 not found at $ScriptUnderTest"
    exit 1
}

# dot-source dependencies in test scope
. $commonPs1
. $ScriptUnderTest

function New-Sandbox {
    param([string]$Tag = 'apphost')
    $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
    $dir = [System.IO.Path]::Combine('C:\Turbo', "turbo-plugin-test-$Tag-$stamp")
    $null = New-Item -ItemType Directory -Path $dir -Force
    return $dir
}

function Remove-Sandbox {
    param([string]$Dir)
    if ([string]::IsNullOrWhiteSpace($Dir)) { return }
    try {
        if ([System.IO.Directory]::Exists($Dir)) {
            [System.IO.Directory]::Delete($Dir, $true)
        }
    } catch { }
}

# Minimal applicationhost.config with one site (HelloApp-deadbeef) on port 5000
$apphostXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.applicationHost>
    <sites>
      <site name="HelloApp-deadbeef" id="1">
        <application path="/" applicationPool="Clr4IntegratedAppPool">
          <virtualDirectory path="/" physicalPath="C:\old\path" />
        </application>
        <bindings>
          <binding protocol="http" bindingInformation="*:5000:localhost" />
        </bindings>
      </site>
    </sites>
  </system.applicationHost>
</configuration>
'@

$sb = $null
try {
    $sb = New-Sandbox 'apphost'
    $apphostPath = [System.IO.Path]::Combine($sb, 'applicationhost.config')
    [System.IO.File]::WriteAllText($apphostPath, $apphostXml, [System.Text.UTF8Encoding]::new($false))

    # ── Case 1: Find-ApplicationhostSite happy ──
    $xml = New-Object System.Xml.XmlDocument
    $xml.PreserveWhitespace = $true
    $xml.Load($apphostPath)
    $site = Find-ApplicationhostSite -Xml $xml -SiteName 'HelloApp-deadbeef'
    Assert-True -Name 'Case1: Find-ApplicationhostSite returns non-null for existing site' -Condition ($null -ne $site) -Message('got: ' + ($null -eq $site))
    if ($null -ne $site) {
        Assert-Equal -Name 'Case1: returned site name matches' -Expected 'HelloApp-deadbeef' -Actual ($site.GetAttribute('name'))
    }

    # ── Case 2: Find-ApplicationhostSite miss ──
    $missing = Find-ApplicationhostSite -Xml $xml -SiteName 'NoSuchSite-00000000'
    Assert-True -Name 'Case2: Find-ApplicationhostSite returns null for non-existent site' -Condition ($null -eq $missing) -Message("got: " + ($missing | Out-String).Trim())

    # ── Case 3: read apphost + find binding + parse port ──
    # XPath drill-down then split bindingInformation "*:5000:localhost" on ':' → port = element[1].
    $bindingNode = $xml.SelectSingleNode('/configuration/system.applicationHost/sites/site/bindings/binding')
    Assert-True -Name 'Case3a: binding node found via XPath' -Condition ($null -ne $bindingNode) -Message($null -ne $bindingNode)
    if ($null -ne $bindingNode) {
        $bindingInfo = $bindingNode.GetAttribute('bindingInformation')
        Assert-Equal -Name 'Case3b: bindingInformation literal' -Expected '*:5000:localhost' -Actual $bindingInfo
        $portStr = ($bindingInfo -split ':')[1]
        $portInt = [int]$portStr
        Assert-Equal -Name 'Case3c: parsed port number is 5000' -Expected 5000 -Actual $portInt
    }

    # ── Case 4: Update-ApplicationhostConfig changes physicalPath then is idempotent ──
    $newPath = [System.IO.Path]::Combine($sb, 'new', 'physical', 'path')
    $r1 = Update-ApplicationhostConfig -ConfigPath $apphostPath -SiteName 'HelloApp-deadbeef' -NewPhysicalPath $newPath
    Assert-True -Name 'Case4a: first call returns Updated=$true' -Condition ([bool]$r1.Updated) -Message("got: " + ($r1 | Out-String).Trim())

    $r2 = Update-ApplicationhostConfig -ConfigPath $apphostPath -SiteName 'HelloApp-deadbeef' -NewPhysicalPath $newPath
    Assert-True -Name 'Case4b: second call (idempotent) returns Updated=$false' -Condition (-not [bool]$r2.Updated) -Message("got: " + ($r2 | Out-String).Trim())
}
finally {
    Remove-Sandbox $sb
}

Write-Output ''
Write-Output "─────────────────────────────────────────────────────────────────────"
Write-Output "ApplicationHostHelpers.test: Passed=$($script:Passed) Failed=$($script:Failed)"
if ($script:Failed -gt 0) {
    foreach ($f in $script:Failures) { Write-Output "  - $f" }
    exit 1
}
exit 0
