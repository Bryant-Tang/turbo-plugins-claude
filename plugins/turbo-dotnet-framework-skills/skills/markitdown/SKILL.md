---
name: markitdown
description: 'Convert supported local documents to Markdown through the workspace MarkItDown MCP server by staging the input under the markitdown_workdir_path and calling the tool with a file:///workdir/... URI.'
argument-hint: 'Required: source file path. Optional: staged relative path or cleanup preference.'
user-invocable: true
---

# MarkItDown

## When to Use
- You need to convert a local file such as `.docx`, `.pptx`, `.xlsx`, `.pdf`, or another MarkItDown-supported document into Markdown.
- The source file is in this repository, another worktree, or anywhere else on the local machine, and the MarkItDown MCP server needs a container-visible file path.
- The user asks to inspect document content through the MarkItDown MCP tool instead of manually parsing the binary file.

## Fixed Constraints
- The MarkItDown MCP server mounts the path configured in `markitdown_workdir_path` user config inside the container as `/workdir`.
- Before calling the MarkItDown MCP tool, always stage the source file by copying it into the `markitdown_workdir_path` directory.
- Always pass a `file:///workdir/...` URI to `mcp_markitdown_convert_to_markdown`.
- Never pass a Windows absolute path, a workspace absolute path, or a path that points outside `/workdir` to the MarkItDown MCP tool.
- The staging folder location is controlled by the `MARKITDOWN_WORKDIR_PATH` environment variable set in `.claude/settings.local.json`; the default when unset is `.markitdown/workdir` relative to wherever the MCP server is launched from.
- If the source file is in another worktree such as `dev-1`, `dev-2`, `test-1`, or `test-2`, still copy it into the `markitdown_workdir_path` directory before conversion.
- Treat the staged copy as temporary input and clean it up after conversion unless the user explicitly asks to keep it for debugging.

## Workspace Path Rule
- Staging folder: the path set in `markitdown_workdir_path` user config
- Container path prefix: `/workdir/`
- Required URI pattern: `file:///workdir/<relative-path-inside-workdir>`
- Example local staging path: `<markitdown_workdir_path>/sample/sample.docx`
- Example URI: `file:///workdir/sample/sample.docx`
- If the staged relative path contains spaces or other URI-sensitive characters, encode them in the URI.

## Exact Workflow
1. Confirm the source file path on disk.
2. Create a short staging subfolder under `markitdown_workdir_path` when it helps avoid filename collisions.
3. Copy the source file into `markitdown_workdir_path`.
4. Build the MarkItDown URI from the staged relative path, not from the original file path.
5. Call `mcp_markitdown_convert_to_markdown` with that `file:///workdir/...` URI.
6. Return the Markdown result to the user or continue with the downstream task.
7. Remove the staged copy when it is no longer needed.

## Decision Rules
- If the source file is already under `markitdown_workdir_path` and is clearly the intended staged temp file, you may reuse it without copying again.
- If the source file is outside `markitdown_workdir_path`, do not try to reference it directly in the URI; copy it into `markitdown_workdir_path` first.
- If more than one file must be converted, stage each file under a distinct relative path so the generated URIs stay unambiguous.
- If the user wants the converted Markdown saved into a repository file, convert first, then write the output separately.
- If a state-changing shell step is needed for folder creation, copy, or cleanup, execute each step separately. Do not send one multi-line shell block and do not chain commands with `&&`.

## Exact Commands
Run state-changing commands one at a time. Replace `<markitdown_workdir_path>` with the actual path from user config.

### PowerShell (Windows native terminal or VS Code terminal)

```powershell
New-Item -ItemType Directory -Force "<markitdown_workdir_path>/sample" | Out-Null
Copy-Item "C:/path/to/source/sample.docx" "<markitdown_workdir_path>/sample/sample.docx" -Force
```

After conversion, clean up:

```powershell
Remove-Item "<markitdown_workdir_path>/sample/sample.docx" -Force
```

### Git Bash / WSL

```bash
mkdir -p "<markitdown_workdir_path>/sample"
cp "C:/path/to/source/sample.docx" "<markitdown_workdir_path>/sample/sample.docx"
```

After conversion, clean up:

```bash
rm -f "<markitdown_workdir_path>/sample/sample.docx"
```

Then call the MCP tool with:

```text
file:///workdir/sample/sample.docx
```

## Completion Checks
- The source file was staged under `markitdown_workdir_path` before conversion.
- The URI passed to `mcp_markitdown_convert_to_markdown` started with `file:///workdir/` and used only the staged relative path.
- No local absolute path was passed to the MCP tool.
- Temporary staged input was cleaned up unless the user asked to keep it.

## Notes
- The Docker volume mapping is defined in `.mcp.json` under the `markitdown` server entry, using the `MARKITDOWN_WORKDIR_PATH` environment variable to allow overriding the staging folder per repo.
- The main failure mode is using a host path such as `C:/...` or a workspace path such as `file:///c:/...`; those paths are not valid inside the MarkItDown container.
- The safest mental model is: copy into `markitdown_workdir_path` first, then pretend the container can only see `/workdir`.
