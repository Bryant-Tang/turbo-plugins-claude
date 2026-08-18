# KnowledgePlacementAssets.test.ps1 (Pester 5) -- twin of knowledge-placement-assets.test.sh
#
# This plugin ships no scripts, so what CAN break is the assets, and every failure checked here is
# one that produces no error at the time it happens:
#
#   * a mismatched marker pair means the setup skill's "replace the block" path never matches, so
#     every run APPENDS another copy instead of replacing the old one;
#   * a frontmatter `name` that disagrees with its directory means the skill cannot be invoked by
#     the name its own file claims;
#   * a non-English `description` costs context on EVERY session (descriptions are preloaded for
#     routing, bodies are not) without anything ever going red.
#
# THIS FILE IS DELIBERATELY PURE ASCII, so it needs no UTF-8 BOM and cannot regress into the
# Windows PowerShell 5.1 / codepage-950 mojibake trap. Keep it that way: no Chinese in comments.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
    $script:PluginRoot = (Resolve-Path ([System.IO.Path]::Combine($PSScriptRoot, '..', '..', '..'))).Path
    $script:Snippet = [System.IO.Path]::Combine(
        $script:PluginRoot, 'skills', 'tp-knowledge-placement-setup', 'assets',
        'claudemd-knowledge-placement-snippet.md')
    $script:SkillDirs = @(Get-ChildItem -LiteralPath ([System.IO.Path]::Combine($script:PluginRoot, 'skills')) -Directory)

    function Get-FrontmatterValue {
        param([string]$Path, [string]$Key)
        foreach ($line in (Get-Content -LiteralPath $Path)) {
            if ($line -match ('^{0}:\s*(.*)$' -f [regex]::Escape($Key))) { return $Matches[1] }
        }
        return ''
    }
}

Describe 'turbo-plugin-knowledge-placement assets' {

    It 'ships the injected snippet, non-empty' {
        Test-Path -LiteralPath $script:Snippet | Should -BeTrue
        (Get-Item -LiteralPath $script:Snippet).Length | Should -BeGreaterThan 0
    }

    # The setup skill replaces everything between the markers. One marker missing, or two of the
    # same, and the replace path silently degrades into "append another copy" -- CLAUDE.md then
    # carries the guidance twice and an edit to one copy leaves two versions loaded at once.
    It 'has exactly one matched marker pair, in order' {
        $lines = @(Get-Content -LiteralPath $script:Snippet)
        $begin = @($lines | Where-Object { $_ -like '*<!-- turbo-plugin:begin knowledge-placement -->*' })
        $end = @($lines | Where-Object { $_ -like '*<!-- turbo-plugin:end knowledge-placement -->*' })
        $begin.Count | Should -Be 1
        $end.Count | Should -Be 1
        $bi = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like '*begin knowledge-placement*' })
        $ei = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -like '*end knowledge-placement*' })
        $bi | Should -BeLessThan $ei
    }

    # The marker name is load-bearing in BOTH directions: this plugin must replace only its own
    # block, and must never touch the `base` block that git-svn / three-environment-db maintain.
    It 'does not claim another plugin''s marker name' {
        (Get-Content -LiteralPath $script:Snippet -Raw) | Should -Not -Match 'turbo-plugin:begin base'
    }

    It 'gives every skill complete frontmatter' {
        foreach ($d in $script:SkillDirs) {
            $skillFile = [System.IO.Path]::Combine($d.FullName, 'SKILL.md')
            Test-Path -LiteralPath $skillFile | Should -BeTrue -Because "$($d.Name) needs a SKILL.md"
            (Get-FrontmatterValue -Path $skillFile -Key 'name') |
                Should -Be $d.Name -Because 'the frontmatter name must match the directory'
            (Get-FrontmatterValue -Path $skillFile -Key 'description') |
                Should -Not -BeNullOrEmpty -Because "$($d.Name) needs a description"
            (Get-FrontmatterValue -Path $skillFile -Key 'user-invocable') |
                Should -Be 'true' -Because "$($d.Name) must be invocable by name"
        }
    }

    # Descriptions are the only part of a skill that is PRELOADED -- every installed skill's
    # description sits in context permanently so the model can route to it, while the body loads
    # only when the skill is actually used. A CJK description therefore costs tokens on every
    # session forever. Bodies stay in Traditional Chinese on purpose; this is the description only.
    It 'keeps every skill description in English' {
        foreach ($d in $script:SkillDirs) {
            $skillFile = [System.IO.Path]::Combine($d.FullName, 'SKILL.md')
            $desc = Get-FrontmatterValue -Path $skillFile -Key 'description'
            $nonAscii = [regex]::Matches($desc, '[^\x20-\x7E]')
            $nonAscii.Count | Should -Be 0 -Because "$($d.Name)'s description must be English; got: $desc"
        }
    }
}
