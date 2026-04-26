---
description: 'Apply a local Git stash for testing before running tests'
allowed-tools: Bash, PowerShell
---

Apply the configured local test stash to the working tree before running tests.

The working tree must be clean before applying. If `TEST_LOCAL_STASH_SHA` is not configured, the script skips silently — report this to the user and continue without error. If a stash has already been applied (state file exists), the script refuses and asks you to run `revert-local-test-stash` first.

## Config

Set the following key in the `env` block of `.claude/settings.local.json`. Omit it when no local test stash is needed.

```json
{
  "env": {
    "TEST_LOCAL_STASH_SHA": "<full SHA of the stash commit to apply>"
  }
}
```

## Execution

Run from the workspace root. Do not chain with other commands using `&&`:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/apply-local-test-stash.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/apply-local-test-stash.sh"
```
