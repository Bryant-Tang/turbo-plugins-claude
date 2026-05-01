---
name: csharp-comment
description: 'Write or update C# comments, including XML documentation comments plus single-line and multi-line explanatory comments, so a new engineer with no project background can understand the code. Use when implementing or revising C# classes, fields, properties, methods, constructors, or other members that need durable documentation comments.'
argument-hint: 'Optional: target C# file, symbol, or comment scope'
user-invocable: true
---

# CSharp Comment

## When to Use
- The task adds or changes C# classes, records, structs, interfaces, enums, or members that need durable documentation.
- The task requires adding or revising C# comments, including XML documentation comments, single-line comments, or multi-line comments.
- A C# file currently lacks enough member-level documentation for a new engineer to understand the intent and usage.
- Another skill such as `implement-task` needs a reusable comment standard for C# code.

## Primary Goal
- Write comments for a future new engineer who does not know this repository yet.
- Make the code understandable from the code symbol itself without relying on the current chat, ticket, or temporary requirement context.

## Core Rules
- Use the comment form that best fits the code: XML documentation comments with `///` for types and members that need API-style documentation, and single-line or multi-line comments for non-obvious logic, constraints, side effects, or workflow details inside the implementation.
- Do not mention the current request, goal, plan, task, test, temporary workaround, or chat context in the comments. Dates are not subject to this restriction.
- Write comments so they still make sense months later when the original requirement context is gone.
- Document the type itself and every member on any class that is in scope, including fields, properties, constructors, and methods.
- Method documentation must define every parameter with `<param name="...">`.
- If a method has a return value, document it with `<returns>`.
- If a generic type or method has type parameters, document them with `<typeparam>`.
- Keep comments focused on responsibility, meaning of inputs and outputs, important side effects, and behavior that is not obvious from the code alone.
- Do not restate trivial syntax that the signature already makes obvious unless it helps a new engineer understand domain meaning.
- Use Traditional Chinese for all prose comments and XML documentation in this repository, unless the surrounding file already uses English consistently and mixing languages would cause obvious style conflicts. When in doubt, use Traditional Chinese.
- When complex implementation logic still is not understandable from member-level XML documentation alone, add single-line or multi-line comments at the relevant code block.

## Member Coverage Rule
- Classes, records, structs, and interfaces must have a summary comment.
- If a class is added or modified, all of that class's fields must have documentation comments.
- If a class is added or modified, all of that class's properties must have documentation comments.
- If a class is added or modified, all of that class's constructors must have documentation comments.
- If a class is added or modified, all of that class's methods must have documentation comments with parameter definitions.
- Non-obvious implementation blocks in the changed scope should have single-line or multi-line comments when that context is needed for a new engineer to follow the logic.
- If events, delegates, or enum members are changed and would otherwise be unclear to a new engineer, document them too.

## Comment Content Guide
- For a type summary, explain the responsibility of the type and the role it plays in the module.
- For a field or property, explain what data it holds and why it exists.
- For a constructor, explain what dependencies or required state it establishes.
- For a method, explain what the method does, when it should be used, what each parameter means, what it returns, and any important side effects or constraints.
- For a single-line or multi-line implementation comment, explain the local intent, important constraint, edge case, or reason a specific logic branch exists.
- Prefer domain meaning over implementation chronology.

## Procedure
1. Identify the changed C# symbols that need documentation.
2. Check whether the surrounding file already uses XML documentation comments, single-line comments, or multi-line comments and align with that style.
3. Add or update the type-level comment first so the overall responsibility is clear.
4. If a class is in scope, add or update member-level comments for all of its fields, properties, constructors, and methods.
5. Add single-line or multi-line comments around non-obvious implementation blocks when a new engineer would otherwise struggle to understand the logic.
6. For every method or constructor parameter, write a concrete `<param>` description.
7. Add `<returns>` and `<typeparam>` where applicable.
8. Read the comments once from the perspective of a new engineer and remove any wording that depends on the current task context.

## Decision Rules
- If the existing comment contradicts the current code behavior, update the comment instead of preserving stale wording.
- If a member name is already fully self-explanatory, keep the comment short but still document the domain meaning or usage expectation.
- If a block comment would only paraphrase obvious code, do not add it.
- If a changed class has undocumented members in the changed scope, do not leave them partially documented.
- If a symbol is generated code or should not be manually documented, leave it alone unless the task explicitly says otherwise.

## Completion Checks
- Comments do not mention the current request, goal, plan, task, or test context.
- The documented symbols can be understood by a new engineer without prior project knowledge.
- Any class added or modified in the changed scope has XML documentation comments on the type and all of its fields, properties, constructors, and methods.
- Non-obvious implementation logic in the changed scope has single-line or multi-line comments when needed for comprehension.
- Every documented method or constructor parameter has a `<param>` entry.
- `<returns>` and `<typeparam>` are present when applicable.
- No stale or misleading comments remain in the changed scope.