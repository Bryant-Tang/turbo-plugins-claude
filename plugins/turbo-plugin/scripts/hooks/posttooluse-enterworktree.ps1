Set-StrictMode -Version Latest
# Hooks must not throw the host session. Surface errors as stderr but never exit non-zero.
$ErrorActionPreference = 'Continue'

# v1.0 (U3) — PostToolUse EnterWorktree hook is fully no-op.
#
# Prior to v1.0, this hook copied .turbo-plugin/applicationhost.config into
# .vs/<sln>/config/applicationhost.config and rewrote physicalPath there for the
# entered worktree. That coupled turbo-plugin to VS's internal directory and
# polluted .vs/ writes on every EnterWorktree call.
#
# v1.0 separates concerns:
#   - Canonical applicationhost.config: .turbo-plugin/applicationhost.config
#     (committed to git, cross-worktree shared, never mutated at runtime)
#   - Runtime config: %TEMP%\turbo-plugin-iis-<identity-hash>.config
#     (rendered per launch by start-iis.ps1 with physicalPath substituted)
#   - VS UI: .vs/<sln>/config/applicationhost.config (VS-managed, turbo-plugin
#     no longer reads or writes)
#
# Therefore this hook has nothing to do — emit empty JSON and exit 0.

function Emit-Json {
    param([hashtable]$Payload)
    $json = ($Payload | ConvertTo-Json -Compress -Depth 6)
    [Console]::Out.Write($json)
}

try {
    # Drain stdin so the caller doesn't block on a broken pipe. We don't actually
    # use any of the payload — but reading it keeps the contract clean.
    $null = [Console]::In.ReadToEnd()
    Emit-Json @{}
    exit 0
} catch {
    [Console]::Error.WriteLine("turbo-plugin posttooluse-enterworktree: $($_.Exception.Message)")
    Emit-Json @{}
    exit 0
}
