---
name: tp-knowledge-placement-setup
description: 'Inject the "where does this belong" criteria into a project''s CLAUDE.md: durable facts go to CLAUDE.md or docs/, current-only facts that a successor still needs go to agent memory as type project, machine-only facts go to memory as feedback/user, and gitignored files must stay regenerable. Run on request; you may SUGGEST it when a project has no such section, but **do NOT auto-trigger** -- it writes CLAUDE.md.'
argument-hint: 'optional: --project-root <path>'
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, AskUserQuestion
---

# tp-knowledge-placement-setup

## Purpose

把「這件事該寫在哪」的判準注入專案的 `CLAUDE.md`,成為一個 `turbo-plugin:begin knowledge-placement`
標記區塊。

**為什麼是 `CLAUDE.md` 而不是留在這支 skill 裡**:這套判準自己那張表就說了——「在你還不知道自己需要它
的時候就會發作」的東西必須無條件載入。而寫錯落點的失敗模式**正是不知道有這回事**:沒有人會在寫下一段
規範之前先想「我該去查一下判準」。skill 只有被判定相關時才會載入,那對這件事來說太晚了。

## Tool Preference

涉及檔案 read / write / search / edit 的工作,優先使用 Read / Write / Edit / Glob / Grep,避開
Bash / PowerShell / Python / Node.js 做檔案操作。委派 subagent 時一併傳遞這條規則。

## Procedure

1. **決定目標專案根**。有 `--project-root` 就用它;否則用當前工作目錄,並先確認那裡是不是專案根
   (有 `.git`,或使用者明講)。**不要從 ambient cwd 推導後直接動手** —— 在隔離工作副本裡跑時,
   猜錯的代價是寫進別的 checkout。不確定就問。

2. **讀目標 `CLAUDE.md`**(不存在則視為空)。

3. **找 `<!-- turbo-plugin:begin knowledge-placement -->` 到 `<!-- turbo-plugin:end knowledge-placement -->`**:
   - **有**:整段取代成 `assets/claudemd-knowledge-placement-snippet.md` 的內容。標記**外面**的內容
     一個字都不要動——那是使用者自己寫的。
   - **沒有**:把整份 snippet(含兩個標記)附加到檔案末尾。

4. **告訴使用者做了什麼**:寫了哪個檔、是新增還是取代、以及標記外的內容未被更動。

## Decision Rules

- **只碰標記之間**。這是這支 skill 唯一會寫的區域。使用者在標記外寫的規範永遠保留。
- **`CLAUDE.md` 不存在時要先確認**再建立。憑空在一個目錄建出 `CLAUDE.md` 是會被載入的行為,不該無聲發生。
- **不要順手改別的 turbo-plugin 的區塊**(`turbo-plugin:begin base` 等)。那些由各自的 setup 維護,
  這裡動它們會在下次那邊重跑時被還原,製造兩份互相打架的內容。
- **這個 plugin 不是任何其它 plugin 的相依**。用了 git↔SVN 橋接或多專案工作區,不代表就得接受這套
  文件方法。要不要裝、要不要注入,是使用者的選擇。

## Completion Checks

- 目標 `CLAUDE.md` 含**恰好一組** `knowledge-placement` 標記(不是零組,也不是兩組)。
- 標記之間的內容與 `assets/claudemd-knowledge-placement-snippet.md` 一致。
- 標記外原有的內容逐字保留。
