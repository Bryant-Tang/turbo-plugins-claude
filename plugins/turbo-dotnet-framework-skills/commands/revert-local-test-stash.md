---
description: 'Revert the applied local test stash after testing is complete'
allowed-tools: Bash, PowerShell
---

Revert the local test stash that was applied by `apply-local-test-stash`, restoring the working tree to its original clean state.

The script reads the applied stash reference from the state file at `.git/testing-and-proof.applied-stash-ref`. If the state file does not exist, the script skips silently — this is not an error. After reverting, the script verifies the working tree is clean.

## Config

No environment variables required.

## Execution

Run from the workspace root. Do not chain with other commands using `&&`:

```powershell
powershell -ExecutionPolicy Bypass -File "${CLAUDE_PLUGIN_ROOT}/scripts/revert-local-test-stash.ps1"
```

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/revert-local-test-stash.sh"
```
