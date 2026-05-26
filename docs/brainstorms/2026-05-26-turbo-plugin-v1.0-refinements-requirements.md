---
date: 2026-05-26
topic: turbo-plugin-v1.0-refinements
---

# turbo-plugin v1.0 Refinements

## Summary

四項 turbo-plugin v1.0 PR 前的收尾改動:把 `applicationhost.config` 從 VS 共生改成 turbo-plugin 自己擁有並動態渲染、重組 `tp-setup` 成 4 個清楚 Phase 並加上 Claude Code 友善功能的推薦安裝、修正 `tp-suggest-ignore` SKILL 文件對跨 worktree commit 行為的錯誤描述、修正 `svn-log` 中文亂碼 + 預設量過大 + 加修訂號參數 + 加入互動分頁。

---

## Problem Frame

- **apphost 共生負債**:目前 `posttooluse-enterworktree.ps1` 在進入 worktree 時把 `.turbo-plugin/applicationhost.config` 複製到 `.vs/<sln>/config/applicationhost.config`,然後 IIS Express 從 `.vs/...` 讀;VS UI 又會自己重新生成 `.vs/...`,造成兩端互相蓋寫的不確定行為。使用者只想要「turbo-plugin 自己擁有一份、VS 的部分跟我無關」。
- **tp-setup 走走停停 + 隱藏副作用**:現有 SKILL 是 Step 0/0.5/1/2-5/6/7/8 堆疊式長流程,每次新需求 append 一個 Step,流程越來越長;同時許多動作(安裝 binary、改 user-level 設定、寫 SVN server)沒有事前讓使用者知道,使用者不確定一次按下繼續會發生什麼。
- **缺少多人友善的開發環境設定入口**:LSP / compound-engineering / agent teams / TUI fullscreen 對 turbo-plugin 使用者體驗有顯著加分,但目前要使用者自己一個一個找文件設定,且每項設定的「正確寫到哪個 scope」也需要使用者判斷。
- **svn-ignore 文件 bug**:腳本本身已正確跨 `remote-*` worktree 同步並個別 commit、失敗 rollback;`tp-suggest-ignore` SKILL 也已透過 `--add-svn` / `--remove-svn` direct-mode flags 暴露 user-invocable 入口。但 SKILL.md 對 `--add-svn` 的描述寫成「on all remote worktrees in a single SVN commit」,實際上是「one SVN commit per worktree」 — 文件騙人,使用者預期錯。
- **svn-log 體驗破洞**:中文 commit message 在中文 Windows 顯示為 `?`、預設 50 筆過多塞滿訊息、不能指定修訂號查特定 commit、執行訊息留在 tool result UI 沒進 chat 訊息、看完 5 筆要再看更舊的得手敲 `--revision` 參數重新呼叫。

---

## Key Flows

- F1. **tp-setup 新流程**
  - **Trigger:** 使用者跑 `/tp-setup`
  - **Actors:** A1(turbo-plugin 使用者)
  - **Steps:**
    1. **Phase 1 偵測** — Pre-check(submodule + git version)、encoding profile、四 case 偵測(a 新建 / b init-from-existing / c 主 worktree 補設定 / d peer-mode)。
    2. **Phase 2 case-specific bootstrap** — 進對應 case 前先 phase summary 揭露「外部動作」(只列必然會發生的,例如 `svn checkout` / `svn commit`,不列 repo 內 file write 等內部動作),AskUserQuestion 確認後執行;不可拆 case override 仍維持(Step 1 既有設計)。
    3. **Phase 3 環境配置(整合)** — 一次 probe 所有可配置項(MSBuild path / IIS Express path / .NET SDK / Node.js / Claude Code 已啟用設定);列出「已配置(跳過)」 + 「尚未配置(以下會問)」清單後 AskUserQuestion 確認進 Phase 3。然後對缺項一次性 AskUserQuestion batch(per-item scope choice,每選項 preview 顯示該選項的外部動作)。
    4. **Phase 4 完成報告** — 偵測結果、寫入位置、使用者仍需手動處理的事(裝 LSP server binary、編輯 dbhub.local.toml 等)、下一步建議。
  - **Outcome:** turbo-plugin 環境就緒,使用者清楚知道剛才哪些外部動作執行了、哪些跳過了、下一步要做什麼。
  - **Covered by:** R5, R6, R7, R8, R11

---

## Requirements

**apphost runtime 分離**

- R1. tp-setup case (a)/(b)/(c) 進入時,**必須**檢查 `.turbo-plugin/applicationhost.config` 是否已存在;不存在則尋找 `.vs/<sln>/config/applicationhost.config` 並複製進來;兩者都不存在則 AskUserQuestion 三選一:(1) 提示使用者開 VS 產生再重跑、(2) 接受沒有 apphost 並在 config.toml 寫入 `[iis] enabled = false`(整個 IIS 相關 skill 之後會 fail-loudly with 提示)、(3) 取消 setup。
- R2. runtime(`tp-build` / `tp-run` / `tp-stop` / `tp-publish` / 任何讀 apphost 的 script)**必須**從 `.turbo-plugin/applicationhost.config` 讀,**不可**讀 `.vs/.../config/applicationhost.config`。
- R3. 啟動 IIS Express 時 physicalPath **必須**在 launch 時動態 patch 為當前 worktree 路徑(寫到 temp file,以 `-config:<temp>` 啟動),避免污染 canonical `.turbo-plugin/applicationhost.config`。
- R4. `posttooluse-enterworktree.ps1` 與 `sessionstart.ps1` 中對 `.vs/.../config/applicationhost.config` 的寫入路徑**必須**移除。VS UI 仍會自行生成 `.vs/.../config/applicationhost.config`,但 turbo-plugin 不再與之互動 — VS 的部分由 VS 自己負責。
- R5. config.toml 新增 `[iis] enabled = true|false`(預設 `true`)。`false` 時所有 IIS 相關 SKILL 在 procedure 開頭即 fail-loudly 告知「IIS 已停用」,不進實際邏輯。

**tp-setup 重組(4 Phase)**

- R6. tp-setup SKILL.md 改寫成 4 個 Phase(偵測 / case bootstrap / 環境配置 / 完成報告)的結構,**廢除**現有 Step 0/0.5/1/.../8 堆疊式編號。未來新需求**必須**融入既有 Phase 或開新獨立 skill,不再 append 新 Step。
- R7. Phase 3 整合所有「環境配置」項目:外部依賴可用性(MSBuild / IIS Express / SVN CLI / Docker)、.NET SDK / Node.js 偵測、Claude Code 功能項(LSP / compound-engineering / agent teams / TUI fullscreen)。Phase 3 是配置事務的單一入口。
- R8. Phase 3 進入前**必須**先 probe 全部項目並列出「已配置(跳過)」+ 「以下會詢問」清單;**已配置的項目不出現在 AskUserQuestion 選項中**。

**Per-item scope choice (Claude Code settings)**

- R9. Claude Code feature 設定(LSP plugin enable、ENABLE_LSP_TOOL、CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS、TUI fullscreen、compound-engineering plugin enable + marketplace)**每項分別** AskUserQuestion 提供 scope 選擇:跳過 / user-level (`~/.claude/settings.json`) / project-level (`.claude/settings.json`,進 git) / local-level (`.claude/settings.local.json`,不進 git)。
- R10. 同一 batch 的 AskUserQuestion 最多 4 題;若缺項超過 4 個,使用第二個 batch — 但**禁止**為了單一項目跳一次 batch 又跳一次(避免走走停停)。

**turbo-plugin 自己的設定集中化**

- R11. turbo-plugin 自己讀的設定(MSBuild path、IIS Express path、frontend dir、`[svn] force_bash`、`[iis] enabled`、等)**全部寫到** `.turbo-plugin/config.toml`(進 git,專案共享)或 `.turbo-plugin/config.local.toml`(gitignored,machine-specific)。**廢除** user-level `TURBO_PLUGIN_MSBUILD_PATH` / `TURBO_PLUGIN_IIS_EXPRESS_PATH` 等 env var。
- R12. tp-setup Phase 1 偵測到既有 `TURBO_PLUGIN_*` env var(來自舊版 setup 寫的 user-level settings.json),**必須**自動遷移到 `.turbo-plugin/config.local.toml` `[tools]` section 並從 user-level settings.json 移除。Migration 是 silent 但 phase summary 會提到「會清除舊的 turbo-plugin 全域設定」。
- R13. `Resolve-ConfigValue` helper **必須**支援 merge:`config.local.toml` 優先於 `config.toml`(類似 settings.local.json 優先於 settings.json)。

**Transparency**

- R14. 任何「動到外部」的動作(網路安裝 binary、寫 user-level settings.json、Claude Code 從外部下載 plugin、SVN server commit、清除舊 user-level env)**必須**在執行前對使用者明示。Repo 內檔案 write / git 本地 op / template copy / AskUserQuestion / 檔案讀取**不必**列出。
- R15. 揭露分兩層:
  - **Phase 邊界 summary**:列 「不論使用者後續選什麼都會發生的外部動作」(unconditional)。
  - **AskUserQuestion 選項 preview**:該選項被選中時會做的外部動作(conditional)。
- R16. 揭露語言**必須**用平實白話 + 具體項目名稱:不用 shell 指令、不用檔案絕對路徑、不用 JSON key 名稱;但 binary / plugin / package 的**具體名稱**(如 `csharp-ls`、`typescript-language-server`、`csharp-lsp@claude-plugins-official`)**必須**寫出,使用者才知道實際裝了什麼、之後好 google。

**LSP 語言伺服器**

- R17. tp-setup Phase 3 詢問**兩個獨立** LSP 啟用題:(a) C# LSP(plugin: `csharp-lsp@claude-plugins-official` + binary: `csharp-ls`)、(b) TS/JS LSP(plugin: `typescript-lsp@claude-plugins-official` + binary: `typescript-language-server` + `typescript`)。
- R18. 偵測到 `dotnet` runtime → C# LSP 題正常提供 user/project/local scope 選項;偵測不到 → C# LSP 題降階為「跳過 / 我之後手動裝」二選一,完成報告列補裝指令。
- R19. 偵測到 `npm` runtime → TS/JS LSP 題正常提供 scope 選項;偵測不到 → 同上降階。
- R20. 任一 LSP 被啟用時,**必須**在所選 scope 寫入 `env.ENABLE_LSP_TOOL = "1"`。
- R21. LSP server binary 安裝**屬於機器全域**(`dotnet tool install -g` / `npm install -g`),不跟 scope 走 — 即使 LSP plugin 啟用在 project-level,binary 仍裝在電腦全域;此事實**必須**在選項 preview 中明示。

**Claude Code 其他推薦項**

- R22. tp-setup Phase 3 詢問 compound-engineering plugin 啟用(plugin: `compound-engineering@compound-engineering-plugin`,marketplace git URL: `https://github.com/EveryInc/compound-engineering-plugin.git`)+ scope 選擇。啟用時**必須**同時寫 `extraKnownMarketplaces` 與 `enabledPlugins` 兩個 key。
- R23. tp-setup Phase 3 詢問 agent teams 啟用(`env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"`)+ scope 選擇。
- R24. tp-setup Phase 3 詢問 TUI fullscreen 啟用(top-level `tui = "fullscreen"`)+ scope 選擇。

**tp-suggest-ignore 文件修正**

- R25. `tp-suggest-ignore` SKILL.md 的 `--add-svn` / `--remove-svn` 描述**必須**改成「on all remote worktrees, **one SVN commit per worktree** (cross-worktree sync; propset failure rolls back all)」 — 與實際腳本 `svn-ignore.ps1` / `.sh` 行為一致。腳本零改動。

**svn-log 修正**

- R26. svn-log SKILL.md Procedure **必須**規定:執行完 script 後把 stdout 內容包成 markdown code block 貼到對話訊息,讓使用者直接讀到 log;**不可**只依賴 tool result UI 呈現(可能折疊或截斷)。
- R27. `svn-log.ps1` 與 `.sh` 內部**一律**呼叫 `svn log --xml ...`(svn 永遠輸出 UTF-8 XML,不看 console codepage),script 自己解析 XML 再 format 成原本的 `r<n> | <author> | <date> | <msg>` 純文字輸出。`--xml` 是 script 內部 implementation,**不**暴露給使用者作為 flag。
- R28. `--limit` / `-Limit` 預設值由 50 改為 5。
- R29. 新增 `--revision <spec>` (bash) / `-Revision <spec>` (PS) 參數,**直接透傳**給 svn log。接受 svn 原生格式:單一(`5` / `r5` / `HEAD` / `BASE`)、範圍(`3:10` / `5:HEAD` / `HEAD:1`)、日期(`{2026-01-01}:{2026-05-26}`)。`--revision` 與 `--limit` 同時給時由 svn 自然處理,腳本不做額外 conflict 邏輯。
- R30. svn-log SKILL 印出 log 之後**必須**在對話訊息中 emit「下一步選項」清單(plain text,**不**使用 AskUserQuestion),包含至少三個選項:(1) 印出下 5 筆(從本次最舊一筆往前 5 筆) / (2) 印出指定修訂(下一輪輸入修訂號或範圍) / (3) 其他(自由文字 escape)。SKILL 結束 turn 後等待使用者下一輪訊息。
- R31. SKILL 解析使用者下一輪訊息:
  - 若訊息符合分頁意圖(「1」/「next」/「下5筆」/「下一頁」等)→ 計算 `<本次最舊 revision - 1>:1 --limit 5` 並 re-invoke svn-log。
  - 若訊息是 revision spec(「r5」/「3:10」/「{2026-01-01}:{2026-05-26}」等)或前綴「2 」加 spec → re-invoke svn-log `--revision <spec>`。
  - 若訊息明顯不屬於分頁互動(包含「3 ...」「其他」「取消」或全然不相關話題)→ **退出**分頁迴圈,進一般對話。
  - 重新呼叫後再次 emit 下一步選項清單(可一直分頁直到使用者退出)。
- R32. 計算「最舊 revision」由 SKILL 從**已 emit 給使用者的對話內容**讀(parse `r<n>` headers),**不**仰賴 script 額外回傳 metadata — script 介面保持單一目的(只負責輸出 log,不維護分頁狀態)。

---

## Acceptance Examples

- AE1. **Covers R1.** Given case (a) 在新目錄跑 tp-setup,且既無 `.turbo-plugin/applicationhost.config` 也無 `.vs/<sln>/config/applicationhost.config`(尚未開過 VS),when Phase 2 開始,then tp-setup AskUserQuestion 提示「找不到 applicationhost.config,要(1)先去開 VS 產生並重跑、(2)接受無 IIS 設定並在 config.toml 標記 [iis] enabled=false、(3)取消 setup?」。
- AE2. **Covers R8.** Given 使用者已在 user-level 啟用 `tui = "fullscreen"`,when tp-setup Phase 3 啟動,then Phase 3 偵測列表顯示「✓ TUI fullscreen (跳過 — 已在 user-level 啟用)」,且 AskUserQuestion 中**不**出現 TUI 相關題目。
- AE3. **Covers R12.** Given 既有使用者已在 `~/.claude/settings.json` 設定 `env.TURBO_PLUGIN_MSBUILD_PATH = "C:\...\MSBuild.exe"`,when 跑 tp-setup case (c),then Phase 1 偵測該 env 後 silent 遷移到 `.turbo-plugin/config.local.toml` 的 `[tools] msbuild_path = "C:\...\MSBuild.exe"`,且從 user-level settings.json 移除該 env key;Phase 1 summary 提到「清除舊的 turbo-plugin 全域設定」。
- AE4. **Covers R18, R19.** Given 偵測到 `dotnet` 可用但 `npm` 不可用,when Phase 3 AskUserQuestion 顯示時,then C# LSP 題提供「跳過 / user-level / project-level / local-level」4 個選項;TS/JS LSP 題只提供「跳過 / 我之後手動裝」2 個選項;Phase 4 完成報告對 TS/JS 列出「需要先裝 Node.js,再跑 `npm install -g typescript-language-server typescript`」。
- AE5. **Covers R27.** Given SVN repo 有一筆 r5 的 commit message 含中文「修正中文檔名」,when 使用者在中文 Windows(codepage 950)跑 `/tp-svn-log`,then 對話訊息中出現 `r5 | bryant | 2026-05-26 | 修正中文檔名`,中文字元完整顯示**不**變成 `?`。
- AE6. **Covers R29.** Given SVN repo 有 r1 到 r10,when 使用者跑 `/tp-svn-log --revision 5:7`,then 對話訊息顯示 r5、r6、r7 三筆 commit。
- AE7. **Covers R14, R15.** Given 使用者在 Phase 3 點開 C# LSP 題的「user-level 啟用」選項 preview,when 看到 preview 內容,then preview 列出「啟用 csharp-lsp@claude-plugins-official plugin(寫到你的 Claude Code 全域設定 — 影響你機器上其他 Claude Code session)、Claude Code 從網路下載 csharp-lsp plugin、安裝 C# 語言伺服器(csharp-ls)到你的電腦」三項;**不**列出 repo 內檔案寫入、git op 或 AskUserQuestion 本身。
- AE8. **Covers R30, R31, R32.** Given SVN repo r1-r20,使用者跑 `/tp-svn-log`(預設顯示 r20-r16 共 5 筆),when 訊息結尾出現「下一步:1.下5筆 / 2.指定修訂 / 3.其他」 + 使用者下一輪回覆「1」,then SKILL 重新呼叫 svn-log 顯示 r15-r11,結尾再次 emit 選項清單;再下一輪「1」,then 顯示 r10-r6,以此類推。
- AE9. **Covers R31.** Given 上題接續顯示 r10-r6 後,when 使用者下一輪回覆「r5」或「2 r5」,then SKILL 重新呼叫 svn-log `--revision r5` 顯示單筆 r5 詳細內容,結尾再次 emit 選項清單。
- AE10. **Covers R31.** Given 分頁迴圈中,when 使用者下一輪回覆「換個話題,幫我看 build.ps1」或「其他」或「取消」,then SKILL **不**再呼叫 svn-log,**不**再 emit 選項清單,讓對話自然進行下一個話題。

---

## Success Criteria

- 跑 tp-setup 的使用者不需要中途查文件就能完成設定;每個 AskUserQuestion 選項都能讓使用者用「常識 + 提示資訊」決定。
- 跑 tp-setup 結束時使用者可以講出「剛剛裝了什麼到我電腦、改了什麼設定、還有什麼要我自己手動做」,不需要回頭看 log。
- IIS Express 在 turbo-plugin 跑(`/tp-run`)時讀的是 `.turbo-plugin/applicationhost.config`;VS UI 開的 IIS Express 跟 turbo-plugin 開的互不干擾;兩邊各自配置可以不同。
- `/tp-svn-log` 中文 commit message 在中文 Windows 上完整顯示。
- 看完 5 筆 commit 後使用者可在對話中直接回「下5筆」/「r5」/「3:10」等,SKILL 自動續看;不想看了直接換話題,SKILL 不再追問。
- `/tp-suggest-ignore --add-svn pattern` 一次同步寫到所有 `remote-*` worktree 並個別 commit;成功的 worktree 列出 revision,失敗的 worktree 明確標示;SKILL 文件描述與實作行為一致。
- ce-plan 從這份 requirements 開始能直接寫實作 plan,不需要再回頭問「scope 怎麼分」「哪個選項要 prompt 還是自動」「揭露要列到多細」這類產品決策。

---

## Scope Boundaries

- **不包含** apphost.config 的「VS-side 同步」自動化 — VS 自己重新生成 `.vs/.../config/applicationhost.config` 由 VS 負責,turbo-plugin 不再介入。使用者如果在 VS UI 改了 IIS 設定要同步回 turbo-plugin,需手動複製 `.vs/.../config/applicationhost.config` → `.turbo-plugin/applicationhost.config`(或之後另開 brainstorm 討論 apphost unification)。
- **不包含** Claude Code plugin 安裝失敗的補救(如 git URL 不可達、cache 損毀)— 走 Claude Code 自己的錯誤路徑,turbo-plugin 不接手。
- **不包含** LSP server binary 安裝失敗的補救 — 失敗時 emit stderr + Phase 4 報告中註記,使用者手動跑指令補裝。
- **不包含** `tp-suggest-ignore` 行為修改 — 既有 SKILL 維持(agent 偵測到新檔案建議使用者跑 `/tp-svn-ignore`);本次只新增 user-invocable 入口。
- **不包含** svn-log 的 `--xml` flag 暴露給使用者作為原始輸出選項 — `--xml` 純內部使用,使用者只看格式化後的人類友善輸出。
- **不包含** turbo-plugin 自動安裝 .NET SDK / Node.js / Docker / VS / IIS Express — 這些是使用者本機環境責任,只 probe + prompt 設定路徑或跳過。

---

## Key Decisions

- **apphost 採完全 runtime 分離(非 hybrid 共生)**:雖然 hybrid(canonical 同時寫 .turbo-plugin 與 .vs)可以讓 VS UI 與 turbo-plugin 共用,但兩邊互相蓋寫的不可預測性實際代價高於 VS UI 與 turbo-plugin 分頭管理。使用者明確選擇「分離」。
- **turbo-plugin 自己的設定全部走 config.toml family(廢除 TURBO_PLUGIN_* env var)**:Project-scope 安裝的 plugin 不該污染 user-level env;且把所有設定集中在 `.turbo-plugin/` 下對使用者 mental model 一致(「想找 turbo-plugin 設定?去 `.turbo-plugin/` 看」)。
- **Claude Code 功能設定走 settings.json + per-item scope**:這些是 Claude Code 讀的,只能走 Claude Code 自己的 settings 系統;讓使用者每項分別決定 scope 是必要彈性(例如:LSP 想 user-wide 享受、compound-engineering 想 project-only 隔離測試)。
- **Transparency 用 just-in-time disclosure(非 pre-disclose all)**:Phase 邊界只列必然動作,選項 preview 才列該選項條件動作 — 避免使用者誤以為按下 phase 繼續按鈕會做所有後續可能的事情。
- **svn-log 用 svn `--xml` 內部解析,不暴露 `--xml` flag**:`--xml` 是 svn 觸發 UTF-8 輸出的唯一手段(其他方案如 `force_bash` routing 或 `chcp 65001` 都有條件破洞或 side effect)。對外仍是純文字格式化輸出,使用者無感。
- **svn-log 分頁互動不用 AskUserQuestion**:AskUserQuestion 是 modal UI 質感太重,對「下一頁」這種輕量回饋體驗不順手;改用 plain-text 選項清單 + SKILL 在下一輪訊息解析使用者意圖,讓對話流動更自然。代價是分頁狀態靠 agent 從對話內容讀(parse 已輸出的 r<n>),script 不維護狀態 — 但這也保持 script 介面單一目的,沒有 hidden state。
- **svn:ignore 部分只修文件 bug**:既有 `tp-suggest-ignore` 已透過 `--add-svn` / `--remove-svn` direct-mode 提供 user-invocable 入口,腳本行為也正確;唯一問題是 SKILL.md line 34-35 描述跟實作對不上(寫成 single commit 實際是 per-worktree commit)。最小變更 = 修文件,不新增 SKILL 不動腳本。
- **tp-setup 限定 4 個 Phase,未來新需求融入或另開 skill**:現在的 Step 0/0.5/1/.../8 已經是技術債,本次強制重組;之後若再追加需求要嚴守此原則,避免回退到堆疊式。
- **LSP plugin 是兩個獨立 plugin(C# / TS-JS)而非單一 plugin**:此為 Anthropic 官方 marketplace 的實際結構(`csharp-lsp@claude-plugins-official` + `typescript-lsp@claude-plugins-official`,經 sub-agent 驗證使用者本機 `~/.claude/plugins/cache/`),tp-setup 必須對應拆成兩題詢問。

---

## Dependencies / Assumptions

- 假設 Anthropic 官方 LSP plugin marketplace 名稱為 `claude-plugins-official`(已驗證:使用者本機 `installed_plugins.json` 含此 key,且 `extraKnownMarketplaces` 未列 → 推斷為內建 marketplace,不需要寫進 settings.json `extraKnownMarketplaces`)。
- 假設 `csharp-lsp@claude-plugins-official` 與 `typescript-lsp@claude-plugins-official` 為 enabledPlugins 的精確 key 格式(已驗證:使用者本機 settings.json 第 193-194 行)。
- 假設 `~/.claude/settings.json` 的 `tui: "fullscreen"` 為 TUI 全螢幕的精確 key + value(已驗證:使用者本機 settings.json 第 213 行)。
- 假設 `ENABLE_LSP_TOOL = "1"` 與 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS = "1"` 為精確 value(已驗證:tpi dependency-check SKILL 第 61 行 + 使用者本機 settings.json)。
- 假設 svn `log --xml` 在所有 turbo-plugin 支援的 svn 版本(>= 1.10)永遠輸出 UTF-8 — 此為 svn 官方合約。
- 假設 IIS Express 的 `-config:<path>` flag 可以指定任意 applicationhost.config 路徑(本次 R3 動態 patch 設計依賴此假設)— 此為 IIS Express 官方文件公開行為。
- 假設使用者在 zh-TW Windows 上的常見 codepage 為 950(Big5),其他語言 Windows 的 codepage 不在本次 scope 內(若使用者在英文 Windows 跑,中文 `?` 問題未必出現,但 svn `--xml` 修法**不會**讓英文 Windows 變壞)。

---

## Outstanding Questions

### Resolve Before Planning

- [Affects R22][Needs research] `compound-engineering@compound-engineering-plugin` plugin 的 `extraKnownMarketplaces` 必填欄位是 `source.source = "git"` + `source.url`,還是有 `autoUpdate` 等其他欄位必填? 需查 Claude Code 官方 docs 或 inspect 使用者既有 settings.json `extraKnownMarketplaces` block 確認。

### Deferred to Planning

- [Affects R3][Technical] IIS Express 啟動時 physicalPath 動態 patch 的具體技術(temp file 路徑命名、生命週期清理時機、與 cleanup-orphan-iis 的互動)在 planning 階段定。
- [Affects R5][Technical] `[iis] enabled = false` 時各 IIS 相關 SKILL 的 fail-loudly 訊息精確措辭、是否提供「重新 enable」的 hint,planning 階段定。
- [Affects R10][Technical] AskUserQuestion 4 題一個 batch 的最佳排序(優先讓使用者最在意的先決定?還是按 dependency 先決定 LSP 再決定 server install?),planning 階段定。
- [Affects R12][Technical] Migration 完成後在何處留下 marker(避免下次又重跑 migration 找不到 env),planning 階段定。
- [Affects R13][Technical] `Resolve-ConfigValue` merge 規則的精確語意(整個 section 替換還是 key-level 覆寫?array 怎麼處理?),planning 階段定 — 預計 key-level 覆寫,但需確認既有 caller 沒有依賴整個 section 替換。
- [Affects R27][Technical] svn XML 解析的具體工具(PS 用 `[xml]` cast;.sh 用 `xmllint` / `xsltproc` / `grep+sed`?— xmllint 在 macOS / Linux 預設裝,Git Bash 未必有,需驗證),planning 階段定。
- [Affects R29][Needs research] svn log `--revision` + `--limit` 同時給時,svn 實際的優先順序(revision 範圍內取 limit 筆?還是 revision 鎖住特定 N 筆 ignored limit?)需查 svn docs 驗證,確認腳本不需要額外邏輯。
