# Changelog

本檔記錄 turbo-plugin-multi-repo-workspace 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-07-30

### Added

- 初版:針對「一個資料夾底下並排放著多個獨立 git repo」的工作區(`proj-root/proj-1` + `proj-root/proj-2` + …)提供設定 skill。相依 `turbo-plugin-git-svn`。
- `tp-multi-repo-workspace-setup`:探測工作區 → 注入工作區根 `CLAUDE.md` 標記區塊 → 逐一(一次一個、各自確認)委派各子專案的 git↔SVN setup。
- `scripts/Get-WorkspaceProjects.ps1` / `get-workspace-projects.sh`:唯讀探測。輸出零到多行 `PROJECT setup=<yes|no> main=<yes|no> path=<絕對路徑>` 資料行 + **唯一**的終結 token(`PROJECTS` / `WORKSPACE_IS_REPO` / `NO_PROJECTS` / `ERROR`);`path=` 固定放最後,含空白的路徑不需引號。目錄名內嵌的假 token 前綴會被消毒。
- **只掃直屬子目錄**:git-svn 的橋接 worktree 位在 `<專案>/.turbo-plugin/worktrees/remote-svn-*`(各自帶一個 `.git` 檔),是孫層;掃一層深就不會把橋接誤認成並排的專案。
- 注入的 `CLAUDE.md` 區塊(`skills/tp-multi-repo-workspace-setup/assets/claudemd-workspace-snippet.md`)寫的是使用者自己寫不出來、agent 也推導不出來的三件事:子資料夾的 `CLAUDE.md` 是**延遲載入**(要動之前先讀)、**`/compact` 之後不會自動回來**、以及**各子資料夾是獨立 repo**(不要跨專案 commit、不要在工作區根 `git init`)。
- 區塊**刻意不列出**子專案清單與各專案的資料庫 / SVN / 專屬規範,並在區塊裡寫明理由(新增專案或改設定時容易忘記回來更新,過期的清單比沒有清單更糟)。
- `main=no`(某個 repo 的 linked worktree)不提供設定選項:git↔SVN 的 setup 會拒絕在那裡建立橋接。
- 子專案的 setup 一律委派 `/turbo-plugin-git-svn:tp-setup`(帶 plugin 前綴,因為 `tp-setup` 這個 skill 名有多個 plugin 都有),不自行複製 SVN URL / git 身分 / 匯入粒度 / base 骨架那套互動。
- 兩層測試套件(`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh`):Pester 9 case + shUnit2 11 case,涵蓋並排專案列舉、`setup=` / `main=` 判定、橋接 worktree 不誤列、工作區本身是 repo / 位在 repo 內、無子專案、路徑不存在仍出 `TP_TOKEN:ERROR`、假 token 消毒、以及 8.3 短檔名下 token 行與資料行拼法一致。
