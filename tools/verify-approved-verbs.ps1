# Verify PowerShell script filenames use approved Verb-Noun PascalCase.
#
# Rules (per docs/brainstorms/2026-05-28-turbo-plugin-naming-conventions-requirements.md
# KD-1 and docs/plans/2026-05-28-001-... R13):
#   1. Path whitelist — .ps1 files under any '/lib/' directory are noun-only
#      libraries (e.g., Common.ps1, AssertHelpers.ps1) and are skipped.
#   2. Verb-Noun single hyphen only — outside lib/, .ps1 basename must contain
#      exactly one '-' (Get-SvnLog OK; Get-Svn-Log violates).
#   3. Case-sensitive PascalCase verb — first char of verb (before '-') must
#      be uppercase. 'build-web.ps1' (lowercase) FAILS even though 'Build' is
#      approved — catches case-insensitive NTFS hiding incomplete renames.
#   4. Approved verb — verb portion must appear in `(Get-Verb).Verb` list
#      (case-sensitive comparison).
#
# Test file mirror — `<Source>.test.ps1` is allowed to mirror its source name.
# Strip `.test` suffix before applying rules. So `Build-Web.test.ps1` ->
# `Build-Web` -> verify against rules.
#
# Self-skip — this script itself lives at tools/verify-approved-verbs.ps1
# which is multi-hyphen kebab; skip when scanning encounters it.
#
# Tools whitelist — the entire `tools/` directory is a kebab-named tooling
# area outside the plugin scope; the user runs the verifier with `-Path`
# pointed at `plugins/turbo-plugin/`, but if `-Path` is broader and includes
# tools/, the verifier skips tools/.
#
# Exit code 0 = clean, 1 = violations found. No external module needed
# (`Get-Verb` is built-in to PS 5.1+).
#
# Usage:
#   pwsh tools/verify-approved-verbs.ps1 -Path plugins/turbo-plugin/scripts
#   pwsh tools/verify-approved-verbs.ps1 -Path plugins/turbo-plugin/tests

[CmdletBinding()]
param(
    [string]$Path = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

if ([string]::IsNullOrWhiteSpace($Path)) {
    $repoRoot = (& git rev-parse --show-toplevel 2>$null | Out-String).Trim()
    if ([string]::IsNullOrWhiteSpace($repoRoot)) {
        Write-Error 'Not inside a git repository and no -Path given.'
        exit 1
    }
    $Path = $repoRoot
}

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Error "Path not found: $Path"
    exit 1
}

# Cache approved verbs once. (Get-Verb).Verb returns PascalCase strings.
#
# Policy extension: 'Build' is in PS 7.3+ Get-Verb but NOT in PS 5.1's. We
# approve it by policy because:
#   - Plan KD-2 / KD-3 chose `Build-Web.ps1` / `Build-SvnCommit.ps1` for
#     semantic precision (msbuild artifact / sync git→svn commit candidate).
#   - PSScriptAnalyzer's PSUseApprovedVerbs rule (when run with the PS 7.3+
#     module installed) accepts these too.
#   - Renaming to PS 5.1 alternatives (New-Web / New-SvnCommit) was considered
#     and rejected in ce-work U2 — Build is more semantically precise.
# 'Deploy' (also PS 7.3+) is included for parity; no current script uses it.
$policyApprovedExtras = @('Build', 'Deploy')
$approvedVerbs = @((Get-Verb).Verb) + $policyApprovedExtras

$violations = @()

Get-ChildItem -Path $Path -Recurse -Filter '*.ps1' -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_.FullName

    # Self-skip: do not flag ourselves (multi-hyphen kebab in tools/).
    if ($file -match '\\tools\\verify-approved-verbs\.ps1$') { return }

    # Tools whitelist: skip the tools/ directory entirely. It is a kebab
    # tooling area outside plugin naming scope (matches lint-ps-compat.ps1
    # convention).
    if ($file -match '\\tools\\') { return }

    # Path whitelist: noun-only library files under any /lib/ directory.
    $isInLibDir = ($file -match '\\lib\\')

    # Compute basename without .ps1, then strip .test suffix if present
    $basename = [System.IO.Path]::GetFileNameWithoutExtension($file)
    if ($basename.EndsWith('.test')) {
        $basename = $basename.Substring(0, $basename.Length - 5)
    }

    $hyphenCount = ($basename.ToCharArray() | Where-Object { $_ -eq '-' } | Measure-Object).Count

    if ($hyphenCount -eq 0) {
        # No hyphen — must be in lib/ (noun-only library)
        if ($isInLibDir) {
            return  # OK, noun-only library
        }
        $violations += [pscustomobject]@{
            File   = $file
            Rule   = 'entry-no-verb'
            Detail = "basename '$basename' has no hyphen but is not under a /lib/ directory (entry scripts must be Verb-Noun)"
        }
        return
    }

    if ($hyphenCount -gt 1) {
        $violations += [pscustomobject]@{
            File   = $file
            Rule   = 'multi-hyphen'
            Detail = "basename '$basename' has $hyphenCount hyphens (only single hyphen allowed in Verb-Noun)"
        }
        return
    }

    # Single hyphen — split into verb / noun
    $dashIndex = $basename.IndexOf('-')
    $verb = $basename.Substring(0, $dashIndex)
    $noun = $basename.Substring($dashIndex + 1)

    if ([string]::IsNullOrEmpty($verb)) {
        $violations += [pscustomobject]@{
            File   = $file
            Rule   = 'verb-empty'
            Detail = "basename '$basename' has empty verb portion before hyphen"
        }
        return
    }

    # Case-sensitive PascalCase check on verb's first character (A-Z only).
    $firstChar = $verb[0]
    if ($firstChar -clt 'A' -or $firstChar -cgt 'Z') {
        $violations += [pscustomobject]@{
            File   = $file
            Rule   = 'verb-not-pascal'
            Detail = "verb '$verb' must start with uppercase letter (PascalCase); got first char '$firstChar'"
        }
        return
    }

    # Case-sensitive approved-verb check.
    # -cin / -cnotin do case-sensitive collection membership.
    if ($verb -cnotin $approvedVerbs) {
        # Provide useful diagnostic: is it merely case-mismatched against an
        # approved verb? (e.g. 'build' vs 'Build')
        $caseInsensitiveMatch = $approvedVerbs | Where-Object { $_ -ieq $verb } | Select-Object -First 1
        if ($null -ne $caseInsensitiveMatch) {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = 'verb-not-pascal'
                Detail = "verb '$verb' must be PascalCase; case-insensitive match exists ('$caseInsensitiveMatch') so this is likely an incomplete rename"
            }
        } else {
            $violations += [pscustomobject]@{
                File   = $file
                Rule   = 'verb-not-approved'
                Detail = "verb '$verb' is not in (Get-Verb).Verb approved list"
            }
        }
        return
    }
}

# Always force violations to be an array, even when zero elements, so .Count works under StrictMode.
$violations = @($violations)

Write-Output ''
Write-Output '---------------------------------------------------------------------'
Write-Output "Verify approved verbs -- scanned: $Path"
Write-Output '---------------------------------------------------------------------'

if ($violations.Count -eq 0) {
    Write-Output '  Result: 0 violations — all verbs approved + PascalCase + single hyphen.'
    Write-Output ''
    exit 0
}

Write-Output "  Result: $($violations.Count) violation(s):"
Write-Output ''
foreach ($v in $violations) {
    Write-Output "  [$($v.Rule)] $($v.File)"
    Write-Output "      $($v.Detail)"
}
Write-Output ''
exit 1
