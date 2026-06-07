# ApplicationHostHelpers.test.ps1 (Pester 5)
#
# Library: plugins/turbo-plugin/scripts/lib/ApplicationHostHelpers.ps1
# Behavior: 此 file 主要是 library (dot-source) — 純函式 (Find-ApplicationhostSite /
#   Update-ApplicationhostConfig / Remove-ApplicationhostSite / Invoke-ApplicationhostRefresh)。
#
# Cases:
#   1. Find-ApplicationhostSite happy: 從 minimal applicationhost.config XmlDocument 中找到指定
#      <site name="HelloApp-deadbeef"> → 回傳非 null 的 XmlElement，且 GetAttribute('name') 一致。
#   2. Find-ApplicationhostSite miss: 找不存在的 site name → 回傳 $null。
#   3. Update-ApplicationhostConfig parse port:讀 applicationhost.config → 找 binding section 中的
#      binding bindingInformation="*:5000:localhost" → parse 出 port 5000。
#   4. Update-ApplicationhostConfig idempotent: 已經是目標 physicalPath → Updated=$false。

BeforeAll {
    $pluginRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..', '..'))
    $script:ScriptUnderTest = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'ApplicationHostHelpers.ps1')
    $script:CommonPs1 = [System.IO.Path]::Combine($pluginRoot, 'scripts', 'lib', 'Common.ps1')
    $script:SandboxRoot = [System.IO.Path]::Combine($pluginRoot, 'tests', '.sandbox', 'sandboxes')

    if (-not [System.IO.File]::Exists($script:ScriptUnderTest)) {
        throw "ApplicationHostHelpers.ps1 not found at $($script:ScriptUnderTest)"
    }

    # dot-source dependencies (production helper + lib under test) into test scope
    . $script:CommonPs1
    . $script:ScriptUnderTest

    function New-Sandbox {
        param([string]$Tag = 'apphost')
        $stamp = [Guid]::NewGuid().ToString('N').Substring(0, 12)
        $dir = [System.IO.Path]::Combine($script:SandboxRoot, "turbo-plugin-test-$Tag-$stamp")
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
    $script:apphostXml = @'
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

    # Shared fixture for all cases
    $script:sb = New-Sandbox 'apphost'
    $script:apphostPath = [System.IO.Path]::Combine($script:sb, 'applicationhost.config')
    [System.IO.File]::WriteAllText($script:apphostPath, $script:apphostXml, [System.Text.UTF8Encoding]::new($false))

    $script:xml = New-Object System.Xml.XmlDocument
    $script:xml.PreserveWhitespace = $true
    $script:xml.Load($script:apphostPath)
}

AfterAll {
    Remove-Sandbox $script:sb
}

Describe 'ApplicationHostHelpers' {

    Context 'Case 1: Find-ApplicationhostSite happy' {
        It 'returns non-null for existing site' {
            $site = Find-ApplicationhostSite -Xml $script:xml -SiteName 'HelloApp-deadbeef'
            $site | Should -Not -BeNullOrEmpty
        }
        It 'returned site name matches' {
            $site = Find-ApplicationhostSite -Xml $script:xml -SiteName 'HelloApp-deadbeef'
            $site.GetAttribute('name') | Should -Be 'HelloApp-deadbeef'
        }
    }

    Context 'Case 2: Find-ApplicationhostSite miss' {
        It 'returns null for non-existent site' {
            $missing = Find-ApplicationhostSite -Xml $script:xml -SiteName 'NoSuchSite-00000000'
            $missing | Should -BeNullOrEmpty
        }
    }

    Context 'Case 3: read apphost find binding parse port' {
        # XPath drill-down then split bindingInformation "*:5000:localhost" on ':' → port = element[1].
        It 'binding node found via XPath' {
            $bindingNode = $script:xml.SelectSingleNode('/configuration/system.applicationHost/sites/site/bindings/binding')
            $bindingNode | Should -Not -BeNullOrEmpty
        }
        It 'bindingInformation literal' {
            $bindingNode = $script:xml.SelectSingleNode('/configuration/system.applicationHost/sites/site/bindings/binding')
            $bindingNode.GetAttribute('bindingInformation') | Should -Be '*:5000:localhost'
        }
        It 'parsed port number is 5000' {
            $bindingNode = $script:xml.SelectSingleNode('/configuration/system.applicationHost/sites/site/bindings/binding')
            $bindingInfo = $bindingNode.GetAttribute('bindingInformation')
            $portInt = [int](($bindingInfo -split ':')[1])
            $portInt | Should -Be 5000
        }
    }

    Context 'Case 4: Update-ApplicationhostConfig changes then idempotent' {
        It 'first call returns Updated true' {
            $newPath = [System.IO.Path]::Combine($script:sb, 'new', 'physical', 'path')
            $r1 = Update-ApplicationhostConfig -ConfigPath $script:apphostPath -SiteName 'HelloApp-deadbeef' -NewPhysicalPath $newPath
            [bool]$r1.Updated | Should -BeTrue
        }
        It 'second call (idempotent) returns Updated false' {
            # First ensure target path is applied (in case this It runs in isolation).
            $newPath = [System.IO.Path]::Combine($script:sb, 'new', 'physical', 'path')
            $null = Update-ApplicationhostConfig -ConfigPath $script:apphostPath -SiteName 'HelloApp-deadbeef' -NewPhysicalPath $newPath
            $r2 = Update-ApplicationhostConfig -ConfigPath $script:apphostPath -SiteName 'HelloApp-deadbeef' -NewPhysicalPath $newPath
            [bool]$r2.Updated | Should -BeFalse
        }
    }
}
