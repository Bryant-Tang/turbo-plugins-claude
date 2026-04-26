---
name: memory
description: 'Read and record durable project facts, decisions, constraints, and user-requested "記住" notes in MCP memory. Use when current work may depend on previously stored repo context, or when you should remember new repo-specific context for future work.'
argument-hint: 'Optional: read target, note summary, or memory target'
user-invocable: true
---

# Memory

## When to Use
- The current task may depend on previously stored project context that is not already present in chat.
- The user says `記住`, `記下來`, `幫我記住`, or otherwise asks you to remember project context.
- You discover durable project knowledge that will likely matter again in later work.
- You confirm a project-specific decision, workflow constraint, environment requirement, or proven command.

## Default Memory Access
- Preferred read tools: `mcp_memory-server_open_nodes`, `mcp_memory-server_search_nodes`
- Preferred write tool: `mcp_memory-server_add_observations`
- Use any appropriate MCP memory entity that best matches the note being read or stored.

## Read First Triggers
- The user asks a question that likely depends on repository-specific preferences, prior decisions, proven commands, or environment constraints.
- The task continues earlier work but the relevant facts are not present in the current chat.
- You need to confirm whether a durable project preference or previously proven workflow already exists before making changes.
- The user explicitly asks what has been remembered already.

## Read Strategy
1. Decide whether the task needs prior repository memory before proceeding.
2. If you already know the likely entity, read it directly with `mcp_memory-server_open_nodes`.
3. If the relevant memory is uncertain or you need to find a narrower fact, use `mcp_memory-server_search_nodes` first.
4. Extract only the observations that materially affect the current task.
5. Continue the task using the recalled facts as project context.

## Good Candidates to Store
- Proven build, run, test, or deployment commands that are specific to this repository.
- Stable environment facts such as ports, required tools, worktree conventions, or path assumptions.
- Confirmed architectural or business decisions.
- User preferences that apply specifically to this repository.

## Do Not Store
- Secrets, credentials, tokens, or personal data.
- Temporary failures, speculative guesses, or raw logs.
- Large code snippets or anything already obvious from the repository layout.
- Notes that only matter for the current turn and will not help later.

## Write Strategy
1. Decide whether the information is durable, project-specific, and likely to help in future turns.
2. Rewrite the information into short factual observations instead of chat-style prose.
3. Choose the most appropriate MCP memory entity for the note.
4. Add the observations with `mcp_memory-server_add_observations`.
5. If the chosen entity does not exist yet, create it with `mcp_memory-server_create_entities`, then continue with `mcp_memory-server_add_observations`.
6. Briefly tell the user what was stored when the memory write was user-requested or materially affects future work.

## Combined Procedure
1. Check whether the task needs prior memory context before acting.
2. If needed, read the most relevant MCP memory entity or search for the relevant observations first.
3. Complete the task using the recalled facts.
4. Decide whether the current turn produced any new durable project knowledge.
5. If yes, store that knowledge as concise factual observations in the appropriate entity.
6. Tell the user what was stored when the write was user-requested or materially affects future work.

## Decision Rules
- If the current task may depend on previously stored project knowledge and that context is not already in chat, read memory before proceeding.
- If you know the exact repository entity to inspect, prefer `mcp_memory-server_open_nodes`; if not, prefer `mcp_memory-server_search_nodes` to narrow the target.
- If the user says not to remember something, do not store it.
- If the information is uncertain, wait until it is confirmed.
- If the note is about this repository and might influence future implementation choices, store it under an entity that will still make sense in a future session.
- If the note is purely personal and not tied to this repository, choose an entity that matches that scope instead of forcing it into repository memory.
- If the MCP memory server is unavailable or returns a connection error, record a warning in the response and continue with the main task without blocking on memory. Do not treat a memory server failure as a hard stop.
- If supporting terminal commands are needed while using this skill, keep state-changing shell actions separate. Do not send multi-line shell blocks or chain side-effect commands with `&&`.

## Completion Checks
- Any needed prior project memory was read before task execution.
- The recalled observations were actually relevant to the task.
- The observation is concise and factual.
- The content is safe to retain.
- The note was added to an appropriate MCP memory entity instead of being left only in chat.
- The stored note would still be understandable in a future session without the current conversation.