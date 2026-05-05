# Changelog

本專案所有重要變更皆會記錄於本檔案。

格式參考 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)，版本號遵循 [Semantic Versioning](https://semver.org/lang/zh-TW/)。

## [Unreleased]

## [0.5.0] - 2026-05-05

### Changed

- `push-to-svn` skill：commit 前新增「檔案清單確認」步驟，並把 merge 從 commit 階段提前到 prepare 階段，以利用 `svn status` 取得真正會送 SVN 的檔案清單（自動套用 svn:ignore 過濾，比 `git diff` 純 git 視角更準）
  - `push-to-svn-prepare`（`.ps1` / `.sh`）：偵測殘留 MERGE_HEAD（前次未完成的 prepare）→ 阻擋；驗證通過後執行 `git merge --no-ff --no-commit -m "..." <branch>`，把 merge 結果留在工作樹但不生成 commit；接著跑 `svn status` 將 `?` / `!` / `M` 對應到 `A` / `D` / `M`，每個檔案再用 `git check-ignore -q` 標記 `tracked` / `ignored`；輸出兩段 `COMMITS` + `FILES`（格式：`<status>|<tracked|ignored>|<path>`）
  - `push-to-svn-commit`（`.ps1` / `.sh`）：移除 merge 邏輯；改為先驗證 MERGE_HEAD 存在（否則拒絕執行）→ `git commit --no-edit` 沿用 prepare 留下的 `.git/MERGE_MSG` 完成 merge commit → 既有 svn add/delete + svn commit 流程
  - SKILL.md：新增 Step 6 顯示檔案清單摘要 + `AskUserQuestion` 確認；**Cancel** → `git -C <remote-worktree> merge --abort` 撤回 staged merge；conflict 時導引使用者手動解決或 abort；後續步驟編號 +2
- `suggest-ignore` SKILL.md：Analysis Mode 的四個類別從代號（A/B/C/D）改為語意名稱（**Git Ignore** / **SVN Ignore** / **Inconsistency** / **Un-track**），降低閱讀門檻；「D2 warning」改稱「Un-track option B warning」；所有 Category/Round 參照同步更新
- `merge-main-into-all`（`.ps1` / `.sh`）：新增 `archives/*` 分支排除條件；`archives/` 下的封存分支不會被 merge；command 說明同步更新
- `init-from-existing` SKILL.md：Phase 1 新增偵測所有 `test-<n>` 分支及對應 `remote/*` / worktree 的存在狀態，並讀取 `.code-workspace` `folders` 清單；Phase 2 Gap Analysis 表格新增每個 `test-<n>` 的 3 列狀態欄；Phase 3 新增步驟 3.4 針對缺少 remote/* 的 test 分支詢問是否補建；Phase 5 新增步驟 5.7 補全 `.code-workspace` 缺少的 worktree 項目；Completion Checks 新增驗證 `.code-workspace` folders 完整性

## [0.4.9] - 2026-05-04

### Fixed

- `suggest-ignore` SKILL.md：Step 2 / Category C 的 `git ls-files -i --exclude-standard` 補上 `-o`（→ `git ls-files -o -i --exclude-standard`），原本指令會 fatal：`ls-files -i must be used with either -o or -c`；`-o`（others，未追蹤）正好對應「SVN 加進來但 git 忽略」的 Category C 偵測情境

## [0.4.8] - 2026-05-04

### Changed

- `svn-ignore.ps1`：參數改用 `[Parameter(ValueFromRemainingArguments=$true)] [string[]]$Arguments` + 手動解析，支援 `-Add p1 -Add p2 -Remove p3 -Path ...` 重複旗標語法（與 `.sh` 對齊）。原本的 `[string[]]$Add` / `[string[]]$Remove` 在 `powershell -File ... -Add "a","b"` 呼叫情境下，外層 PowerShell 會把陣列展開成獨立 process args（`-Add a b`）→ 子 PowerShell 只 bind 第一個值、剩餘變 positional 報錯；採用 `-Add` 旗標重複語法即可避開此 native command 引數展開問題

### Fixed

- `svn-ignore.ps1`：`Get-SvnIgnorePatterns` 改用逗號運算子（`return ,@()`）回傳空陣列；`$argList` 初始化改用獨立 `if` 賦值（不再 `if/else` 回傳 `@()`），避免 PowerShell 在 pipeline 把 `@()` unroll 成 `$null`，導致 LIST 模式（無 `svn:ignore` 屬性、或無傳入參數時）`.Count` 在 `Set-StrictMode -Version Latest` 下拋出「The property 'Count' cannot be found on this object」
- `svn-ignore.sh`：`get_patterns` 改為 `(cd "$wt" && svn propget svn:ignore "$SVN_PATH")`，原本 `svn propget svn:ignore "$SVN_PATH" "$wt"` 同時傳入兩個路徑會觸發 SVN 的多路徑輸出格式（`<path> - <value>` 前綴），導致 LIST 模式第一個 pattern 顯示成 `C:\…\remote-main - *.tmp`

## [0.4.7] - 2026-05-04

### Changed

- `suggest-ignore` Analysis Mode：移除分支選擇步驟；改為分析**所有** remote worktree（Category C 對每個 worktree 獨立檢查 SVN 追蹤狀態）；svn:ignore 以 `remote-main` 為正本，套用變更時同步所有 remote worktree；移除 `--branch` 參數及 Branch Mapping 表

## [0.4.6] - 2026-05-04

### Fixed

- `suggest-ignore` SKILL.md：更新 Category B 說明為一次批次呼叫所有 pattern（而非逐一呼叫）；同步 Category C-B / D-A 腳本範例語法；`argument-hint` 加上 `…` 標示多 pattern 支援

## [0.4.5] - 2026-05-04

### Added

- `svn-ignore`（`.ps1` / `.sh`）：`--add-svn` / `--remove-svn` 支援一次傳入多個 pattern（ps1 用 `-Add p1 -Add p2`，sh 用 `--add p1 --add p2`），所有 pattern 合併為單一 SVN commit；已存在 / 不存在的 pattern 逐一回報並跳過，其餘有效 pattern 照常套用；同時抽出 `Set-SvnIgnorePatterns` helper 消除 ps1 重複的暫存檔邏輯

### Fixed

- `svn-ignore.ps1`：`Set-SvnIgnorePatterns` 暫存檔改用 CRLF（`\r\n`）作為行分隔符，解決 Windows SVN client 以 `--file` 讀入 LF-only 檔案時將所有 pattern 合併成單行的問題
- `svn-ignore.sh`：`svn propset svn:ignore --file -` 的 stdin pipe 插入 `awk '{printf "%s\r\n", $0}'` 轉為 CRLF，解決 Git Bash on Windows 呼叫 Windows svn.exe 時相同的單行問題；`awk` 比 `sed 's/$/\r/'` 更跨平台（macOS BSD sed 對 `\r` 的處理不一致）；Linux / macOS 原生 SVN 解析 CRLF property 值不受影響

## [0.4.4] - 2026-05-04

### Fixed

- `svn-ignore.ps1`：`svn propset svn:ignore` 改用暫存檔搭配 `--file` 傳遞多行 pattern，解決 Windows 上將多行 CLI 引數折疊成單行導致 `svn:ignore` 無法生效的問題（與 sh 腳本的 `--file -` stdin 方式一致）；暫存檔以 UTF-8 無 BOM 寫入，並在 `finally` 中確保清除

## [0.4.3] - 2026-05-04

### Fixed

- `svn-ignore.ps1`：`svn propget`、`svn status`（ADD / REMOVE 兩處）在呼叫前後暫時將 `$ErrorActionPreference` 設為 `'SilentlyContinue'`，解決 PS 5.1 下 `$ErrorActionPreference = 'Stop'` 在 `2>$null` 重導生效之前即攔截 native exe stderr ErrorRecord、拋出終止例外的問題

## [0.4.2] - 2026-05-04

### Fixed

- `svn-ignore.ps1`：`Get-SvnIgnorePatterns` 將 `svn propget` 的 stderr 重導從 `2>&1` 改為 `2>$null`，避免 PS 5.1 將 native exe 的 stderr 包成 `ErrorRecord` 注入 pipeline，進而被 `$ErrorActionPreference = 'Stop'` 升格為終止性錯誤（`svn propget` 在目錄尚無 `svn:ignore` 時會對 stderr 輸出警告，觸發此問題）

## [0.4.1] - 2026-05-04

### Fixed

- `svn-ignore`（`.ps1` / `.sh`）：dirty 檢查從「`svn status` 有任何輸出即阻擋」改為只攔真正有待處理 SVN 異動的行（column 1 符合 `MACDR!~`，或 column 2 符合 `M`/`C` 的 property 異動），排除 `?`（未版本化）、`I`（已忽略）、`X`（外部未版本化）等不影響 commit 的項目，解決 remote worktree 存在 `.claude/`、`.git` 等未版本化目錄時 `--add-svn` / `--remove-svn` 無法執行的問題

## [0.4.0] - 2026-05-02

### Added

- `init-from-existing` skill：分析既有 git 專案結構與 tgs 標準的落差，並互動式地執行遷移（建立 `remote/main` orphan 分支、`<proj>.worktrees/remote-main` worktree、SVN checkout、`.code-workspace`，以及初始 SVN sync）；已符合 tgs 結構的元件自動跳過（冪等）

## [0.3.0] - 2026-05-02

### Added

- `merge-main-into-all` command：將 `main` branch merge 進所有非 `remote/*` 的 branch（`test-<n>`、`dev-<n>` 等）；每個 branch 獨立報告 `OK` / `SKIP`（dirty worktree）/ `CONFLICT`（merge 已 abort）
- `pull-from-svn` skill：成功 pull 進 `main` 後推薦執行 `/tgs:merge-main-into-all`

## [0.2.0] - 2026-05-02

### Added

- `suggest-ignore` skill：管理 git/SVN ignore 的單一入口
  - **直接模式**：`--add-git` / `--remove-git` 直接操作 `.gitignore`（並 git commit）；`--add-svn` / `--remove-svn` 同步所有 remote worktrees 的 `svn:ignore`（支援 `--path`）
  - **分析模式**（不帶直接操作旗標）：互動式分析，推薦並設定 `.gitignore` 與 `svn:ignore`；處理 4 類情境：(A) 新增 git ignore、(B) 新增 svn:ignore、(C) 修正 SVN 追蹤但 git 忽略的不一致、(D) 從 git 和/或 SVN 停止追蹤

### Changed

- `create-remote-test`：新 remote worktree 的 `svn:ignore` 從 remote-main 複製現有設定（含使用者自訂 pattern），而非硬編碼 `.git`/`.gitignore`

### Fixed

- `push-to-svn-commit`：改用 explicit commit list，`?`/`!`/`M` 狀態的 git-ignored 項目不再被加入 / 刪除 / 提交到 SVN；本地檔案完整保留（不執行 svn revert）
- `create-remote-test`：`svn propget svn:ignore` 移除多餘的 `'.'` 路徑參數，避免從非 SVN 工作目錄呼叫時因 CWD 不是 SVN WC 而報錯
- `svn-log`：移除與 `[CmdletBinding()]` common parameter 衝突的 `[switch]$Verbose`，改用 `$VerbosePreference` 偵測 `-Verbose` 旗標

## [0.1.1] - 2026-04-30

### Added

- `push-to-svn` skill：push 完成後詢問是否建立 release tag；tag 格式為 `<branch>-release-YYYY-MM-DD-<serial>`（例如 `main-release-2026-04-30-001`），serial 為該分支單日流水號
- `tag-release` 腳本（`.sh` / `.ps1`）：計算當天流水號並在 `remote/<branch>` 上建立 git tag

### Fixed

- 所有 PowerShell 腳本新增 `[CmdletBinding()]`，傳入未知參數時現在會立即報錯而非靜默忽略

## [0.1.0] - 2026-04-30

### Added

- `create-project` command：在指定位置建立初始專案結構（main worktree + remote-main worktree + SVN checkout + .code-workspace）
- `pull-from-svn` skill：從 SVN 更新對應的 remote-* worktree，commit 到 remote/* branch，merge 進指定的 git 工作分支
- `push-to-svn` skill：將指定 git 工作分支 merge 進對應的 remote/* branch，並在 remote-* worktree 執行 SVN 送交
- `create-remote-test` command：建立 test-\<n\> branch + remote/test-\<n\> branch + remote-test-\<n\> worktree，可選擇性連結 SVN 分支 URL
- `create-dev-worktree` command：建立 dev-\<n\> worktree + 指定或新建的 git 分支，供個人開發隔離使用
- `svn-log` command：在指定 branch 對應的 remote-* worktree 執行 `svn log`，列出 SVN 歷史紀錄；支援 `--branch`（預設 main）、`--limit`（預設 50）、`--verbose` 參數
- `/tgs:setup` skill：互動式設定 tgs 環境變數，將設定寫入 `.claude/settings.local.json`
- `TGS_SVN_LOG_DEFAULT_BRANCH`、`TGS_SVN_LOG_DEFAULT_LIMIT`、`TGS_SVN_LOG_DEFAULT_VERBOSE` 環境變數：可覆寫 `svn-log` command 的 `--branch`、`--limit`、`--verbose` 預設值（優先序：CLI 參數 > 環境變數 > 內建預設值）
- `TGS_DEFAULT_WORKING_BRANCH` 環境變數：`pull-from-svn` / `push-to-svn` skill 的 `--branch` 預設分支；未設定時維持原本的互動詢問行為
- `create-project`、`create-remote-test`、`create-dev-worktree` 完成後顯示 `/tgs:setup` 推薦執行提示
