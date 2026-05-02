---
name: js-comment
description: 'Write or update JavaScript and TypeScript comments, including JSDoc documentation comments plus single-line and multi-line explanatory comments, so a new engineer with no project background can understand the code. Use when implementing or revising JS/TS modules, classes, functions, interfaces, type aliases, or other exported symbols that need durable documentation. Covers standalone .js/.ts files and <script> sections in .vue, .cshtml, and .html files.'
argument-hint: 'Optional: target JS/TS file, symbol, or comment scope'
user-invocable: true
---

# JS Comment

## When to Use
- The task adds or changes JavaScript or TypeScript modules, classes, functions, interfaces, type aliases, enums, or exported constants that need durable documentation.
- The task requires adding or revising JS/TS comments, including JSDoc documentation comments, single-line comments, or multi-line comments.
- A JS/TS file or `<script>` section currently lacks enough member-level documentation for a new engineer to understand the intent and usage.
- The task touches `<script>` or `<script setup>` sections in `.vue`, `.cshtml`, or `.html` files that need explanation.
- Another skill such as `implement-task` needs a reusable comment standard for JS/TS code.

## Primary Goal
- Write comments for a future new engineer who does not know this repository yet.
- Make the code understandable from the code symbol itself without relying on the current chat, ticket, or temporary requirement context.

## Core Rules
- Use the comment form that best fits the code: JSDoc comments (`/** ... */`) for exported types and members that need API-style documentation, and single-line or multi-line comments for non-obvious logic, constraints, side effects, or workflow details inside the implementation.
- Do not mention the current request, goal, plan, task, test, temporary workaround, or chat context in the comments. Dates are not subject to this restriction.
- Write comments so they still make sense months later when the original requirement context is gone.
- Document every exported function, class, interface, type alias, and enum in any scope that is changed.
- Function and method documentation must define every parameter with `@param`.
- If a function or method has a return value, document it with `@returns`.
- If a generic function, class, or type has type parameters, document them with `@template`.
- Keep comments focused on responsibility, meaning of inputs and outputs, important side effects, and behavior that is not obvious from the code alone. TypeScript types already carry type information — do not restate them unless the domain meaning adds context.
- Do not restate trivial syntax that the signature already makes obvious unless it helps a new engineer understand domain meaning.
- Use Traditional Chinese for all prose comments and JSDoc documentation in this repository, unless the surrounding file already uses English consistently and mixing languages would cause obvious style conflicts. When in doubt, use Traditional Chinese.
- When complex implementation logic is not understandable from function-level JSDoc alone, add single-line or multi-line comments at the relevant code block.
- For `<script>` or `<script setup>` sections in `.vue`, `.cshtml`, or `.html` files, apply the same rules to the JS/TS code within those sections.

## Member Coverage Rule
- Every exported function at module scope must have a JSDoc comment.
- Every exported class must have a JSDoc comment.
- If a class is added or modified, all of its fields must have documentation comments.
- If a class is added or modified, all of its properties must have documentation comments.
- If a class is added or modified, all of its constructors must have documentation comments.
- If a class is added or modified, all of its methods must have documentation comments with parameter definitions.
- Every exported interface, type alias, and enum in the changed scope must have a JSDoc comment.
- Non-obvious implementation blocks in the changed scope should have single-line or multi-line comments when that context is needed for a new engineer to follow the logic.

## Comment Content Guide
- For a module or file, describe the module's overall responsibility if it is not obvious from the file name.
- For a class or interface, explain the responsibility of the type and the role it plays in the module.
- For a field or property, explain what data it holds and why it exists.
- For a constructor, explain what dependencies or required state it establishes.
- For a function or method, explain what it does, when it should be used, what each parameter means, what it returns, and any important side effects or constraints.
- For a type alias or interface, explain the structure's purpose and when it is used.
- For a single-line or multi-line implementation comment, explain the local intent, important constraint, edge case, or reason a specific logic branch exists.
- Prefer domain meaning over implementation chronology.

## Procedure
1. Identify the changed JS/TS symbols and `<script>` sections that need documentation.
2. Check whether the surrounding file already uses JSDoc, single-line, or multi-line comments and align with that style.
3. Add or update module-level or class-level JSDoc first so the overall responsibility is clear.
4. If a class is in scope, add or update member-level documentation for all of its fields, properties, constructors, and methods.
5. Add or update JSDoc for all exported functions, interfaces, type aliases, and enums in the changed scope.
6. Add single-line or multi-line comments around non-obvious implementation blocks when a new engineer would otherwise struggle to understand the logic.
7. For every function or constructor parameter, write a concrete `@param` description.
8. Add `@returns` and `@template` where applicable.
9. Read the comments once from the perspective of a new engineer and remove any wording that depends on the current task context.

## Decision Rules
- If the existing comment contradicts the current code behavior, update the comment instead of preserving stale wording.
- If a member name is already fully self-explanatory, keep the comment short but still document the domain meaning or usage expectation.
- If a block comment would only paraphrase obvious code, do not add it.
- If a changed class has undocumented members in the changed scope, do not leave them partially documented.
- If a symbol is generated code, a framework stub, or should not be manually documented, leave it alone unless the task explicitly says otherwise.
- For TypeScript code, do not restate type annotations in JSDoc. Focus on intent, domain meaning, and behavior instead.

## Completion Checks
- Comments do not mention the current request, goal, plan, task, or test context.
- The documented symbols can be understood by a new engineer without prior project knowledge.
- Every exported function in the changed scope has a JSDoc comment with `@param` entries for every parameter.
- Every exported class added or modified in the changed scope has JSDoc on the class and all of its fields, properties, constructors, and methods.
- Every exported interface, type alias, and enum in the changed scope has a JSDoc comment.
- Non-obvious implementation logic in the changed scope has single-line or multi-line comments when needed for comprehension.
- `@returns` and `@template` are present when applicable.
- No stale or misleading comments remain in the changed scope.
- `<script>` sections in `.vue`, `.cshtml`, or `.html` files follow the same standards as standalone JS/TS files.
