# Skill tests 結束 Rollback Checklist

per RBP Q3 resolution = **(b)** — Skill tests tp-setup 推薦項目實際安裝後**留到 Skill tests
全部結束再一次性 rollback**(K-Decision trade-off 2)。本檔列出所有 Skill tests 期間
留在使用者主機上的痕跡 + 對應的還原指令 + verify step。

> 執行時機:`skill-tests-session-plan.md` 「Skill tests 結束 checklist」全部勾完之後。
>
> 執行者:使用者(orchestrator 引導,但實際指令要在使用者主機跑)。

> **Pre-flight 備份**:Skill tests 開始前推薦使用者跑
> `Copy-Item ~/.claude/settings.json ~/.claude/settings.json.pre-turbo-plugin-test`,
> 完事後若這個 checklist 漏掉什麼可以直接還原。

---

## 1. Claude Code plugin uninstall(`~/.claude/plugins/cache/` + `enabledPlugins`)

每個 `claude plugins uninstall` 指令會同時(a) 從 `~/.claude/settings.json`
`enabledPlugins` 移除 entry、(b) 從 `~/.claude/plugins/cache/` 清掉對應 cache。

### 1.1 csharp-lsp@claude-plugins-official

- [ ] 執行:
  ```
  claude plugins uninstall csharp-lsp@claude-plugins-official
  ```
- [ ] **Verify**:
  ```
  claude plugins list
  ```
  輸出**不**含 `csharp-lsp@claude-plugins-official`。
- [ ] **Verify**(secondary):
  ```powershell
  Get-Content ~/.claude/settings.json | ConvertFrom-Json | Select-Object -ExpandProperty enabledPlugins
  ```
  輸出**不**含 `csharp-lsp@claude-plugins-official` key。

### 1.2 typescript-lsp@claude-plugins-official

- [ ] 執行:
  ```
  claude plugins uninstall typescript-lsp@claude-plugins-official
  ```
- [ ] **Verify**:
  ```
  claude plugins list
  ```
  輸出**不**含 `typescript-lsp@claude-plugins-official`。

### 1.3 compound-engineering@compound-engineering-plugin

- [ ] 執行:
  ```
  claude plugins uninstall compound-engineering@compound-engineering-plugin
  ```
- [ ] **Verify**:
  ```
  claude plugins list
  ```
  輸出**不**含 `compound-engineering@compound-engineering-plugin`。

### 1.4 移除 `extraKnownMarketplaces["compound-engineering-plugin"]` entry

(claude plugins uninstall 通常**不**會清 `extraKnownMarketplaces`,需手動。)

- [ ] 用 editor 開 `~/.claude/settings.json`,從 `extraKnownMarketplaces` 物件移除整個 `compound-engineering-plugin` key:
  ```diff
  {
    "extraKnownMarketplaces": {
  -   "compound-engineering-plugin": {
  -     "source": { "source": "git", "url": "..." },
  -     "autoUpdate": false
  -   },
      "<其它 user 既有 marketplace, 保留>": { ... }
    }
  }
  ```
- [ ] **Verify**:
  ```powershell
  Get-Content ~/.claude/settings.json | ConvertFrom-Json | Select-Object -ExpandProperty extraKnownMarketplaces
  ```
  輸出**不**含 `compound-engineering-plugin` key(若 `extraKnownMarketplaces` 整個被 phase 2 才建出來,移除整個 key 也可以)。

---

## 2. `~/.claude/settings.json` env / tui 還原

### 2.1 移除 `env.ENABLE_LSP_TOOL`

- [ ] 用 editor 開 `~/.claude/settings.json`,從 `env` 物件移除 `ENABLE_LSP_TOOL` key(若 Skill tests 前不存在;若 Skill tests 前是「1」其它原因,**保留**)。
- [ ] **Verify**:
  ```powershell
  (Get-Content ~/.claude/settings.json | ConvertFrom-Json).env.ENABLE_LSP_TOOL
  ```
  輸出為 `$null` 或空(若使用者 Skill tests 前該值是 `1`,本 step 不該動)。

### 2.2 移除 `env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`

- [ ] 用 editor 開 `~/.claude/settings.json`,從 `env` 物件移除 `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` key。
- [ ] **Verify**:
  ```powershell
  (Get-Content ~/.claude/settings.json | ConvertFrom-Json).env.CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS
  ```
  輸出為 `$null` 或空。

### 2.3 移除 top-level `tui = "fullscreen"`

- [ ] 用 editor 開 `~/.claude/settings.json`,移除 top-level `tui` key(或還原成使用者 Skill tests 前的值)。
- [ ] **Verify**:
  ```powershell
  (Get-Content ~/.claude/settings.json | ConvertFrom-Json).tui
  ```
  輸出為 `$null` 或使用者 Skill tests 前的值。

> **若難以人工 diff**:直接拿 `Copy-Item ~/.claude/settings.json.pre-turbo-plugin-test ~/.claude/settings.json` 還原備份檔(若 Pre-flight 備份有做),省事。

---

## 3. dotnet global tool uninstall

### 3.1 csharp-ls

- [ ] 執行:
  ```
  dotnet tool uninstall -g csharp-ls
  ```
- [ ] **Verify**:
  ```
  dotnet tool list -g | findstr csharp-ls
  ```
  輸出**為空**(無 csharp-ls 行)。

---

## 4. npm global package uninstall

### 4.1 typescript-language-server + typescript

- [ ] 執行:
  ```
  npm uninstall -g typescript-language-server typescript
  ```
- [ ] **Verify**:
  ```
  npm list -g --depth=0 | findstr typescript-language-server
  ```
  輸出**為空**。
- [ ] **Verify**(secondary):
  ```
  npm list -g --depth=0 | findstr "^.--.typescript@"
  ```
  輸出**為空**(若使用者 Skill tests 前有自己裝 typescript,該行可能仍在 — 確認使用者意願再決定是否還原該 install)。

---

## 5. `~/.claude/plugins/cache/` 清理(若 `claude plugins uninstall` 沒清乾淨)

某些 Claude Code 版本 `claude plugins uninstall` 可能不會清 cache 資料夾。手動 verify:

- [ ] 列出 `~/.claude/plugins/cache/`:
  ```powershell
  Get-ChildItem ~/.claude/plugins/cache/ -Directory
  ```
- [ ] 確認**不**含:
  - `csharp-lsp@claude-plugins-official`
  - `typescript-lsp@claude-plugins-official`
  - `compound-engineering@compound-engineering-plugin`
- [ ] 若有殘留,手動 `Remove-Item -Recurse -Force` 對應資料夾。
- [ ] **Verify**:重新跑 `Get-ChildItem ~/.claude/plugins/cache/ -Directory`,確認上述三個 entry 都不在。

---

## 6. test 環境清理(optional,不影響使用者 daily-driver)

這些是 Script tests + Skill tests 過程中 orchestrator 在 fixture 主機上建出來的痕跡,Skill tests 結束後可選擇保留(下次測試重用)或清掉:

- [ ] `C:\Turbo\test-turbo-plugin\test-turbo-plugin` 整個資料夾(下次測試 `Reset-Fixture.ps1` 會重建,所以可砍可留)
- [ ] `C:\Turbo\test-turbo-plugin\svn-repo` SVN repo(下次測試 `Build-SeedRepo.ps1` 會重建)

> 這兩個目錄不在「使用者主機污染」範疇 — 是測試專用沙盒。保留亦可,作為下次 v1.x 測試重用。

---

## 7. 重啟 Claude Code 確認生效

- [ ] 關掉所有正在跑的 Claude Code session
- [ ] 重新啟動 Claude Code
- [ ] 跑 `/plugin list`,確認 Skill tests 啟用的 3 個 plugin 都不在 list:
  - csharp-lsp@claude-plugins-official
  - typescript-lsp@claude-plugins-official
  - compound-engineering@compound-engineering-plugin
- [ ] 確認 TUI 不是 fullscreen(若 Skill tests 前不是)
- [ ] 確認沒 agent teams env(`echo $env:CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` 應為空)

---

## 完成

- [ ] 全部 6 個 section 的 checkbox 都打勾
- [ ] orchestrator 在 `feat/turbo-plugin-v1.0` branch commit:
  ```
  fix(turbo-plugin): mark v1.0.0 test plan complete + rollback restored
  ```
- [ ] 確認 `~/.claude/settings.json` 內容跟 `~/.claude/settings.json.pre-turbo-plugin-test`(若有備份)**一致**(可用 `Compare-Object`):
  ```powershell
  Compare-Object (Get-Content ~/.claude/settings.json) (Get-Content ~/.claude/settings.json.pre-turbo-plugin-test)
  ```
  輸出**為空**(或只有 whitespace 差異)。
- [ ] 移除備份檔(可選):
  ```powershell
  Remove-Item ~/.claude/settings.json.pre-turbo-plugin-test
  ```

> **若 verify 仍見殘留**:用 `Compare-Object` 看 diff,人工逐一還原差異 key,直到 `Compare-Object` 為空。若某個 key 跑 `claude plugins uninstall` 仍沒清掉,直接編輯 `~/.claude/settings.json` 手動移除即可。
