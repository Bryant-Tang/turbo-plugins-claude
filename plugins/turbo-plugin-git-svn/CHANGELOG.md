# Changelog

本檔記錄 turbo-plugin-git-svn 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 自單體 `turbo-plugin` v0.6.0 拆出,成為獨立可安裝 plugin;承接 git↔SVN bridge 與 setup 職責(以 `git mv` 保留 git lineage,完整歷史見 `git log --follow`)。
- 8 支 skill(保 `tp-*` 前綴):`tp-setup`、`tp-pull-from-svn`、`tp-push-to-svn`、`tp-svn-log`、`tp-reset-branch-to-main`、`tp-merge-main-into-branches`、`tp-suggest-ignore`、`tp-commit-msg`。
- SVN bridge 腳本對(`.ps1` + `.sh`):Build-SvnCommit / Submit-SvnCommit / Sync-FromSvn / Get-SvnLog / Get-PushPreflight / New-RemoteBridge / Merge-MainIntoBranches / Reset-BranchToMain / Tag-Release / Test-EncodingSupport。
- `lib`:`Core.{ps1,sh}` 複本 + SVN concern `Common.ps1` / `common.sh`(branch 名消毒、remote worktree 解析、SVN URL trust 邊界檢查、`svn status --xml` 解析,自單體抽出、去除 dotnet concern)+ `ps1-delegate.sh`。
- `SessionStart` advisory hook(marker 缺失時提示 `/tp-setup`;dbhub / IIS 分支已移至 sibling plugin)。
- `default-files/.turbo-plugin/`:`config.toml` + `conventions.md` 範本,引入 marker scaffolding(config.toml 用 `# >>> turbo-plugin:<concern> >>>` TOML 註解標記、conventions.md 用 `<!-- turbo-plugin:begin <concern> -->` 標記),讓各 plugin 的 setup 只寫自己的標記區塊、彼此不覆蓋(已驗證 `Read-TurboPluginConfig` 略過 `#` marker 行)。
- `tp-setup` 改為 **standalone 架構**:共用 `assets/setup-base.md`(concern-neutral 骨架,各 plugin 引用)+ git-svn concern(bridge bootstrap / `[svn]` / `.commitlintrc.json` / git-svn 標記區塊)。**移除 IIS apphost(→ dotnet plugin)、dbhub(→ db plugin)、Phase 3 Claude Code 功能詢問**。
- **`conventions.md`「先讀慣例」機制整套退役**:`tp-commit-msg` / `tp-csharp-comment` / `tp-js-comment` / `tp-db-management` 全改靠各自 skill 的 `description` 讓 agent 主動觸發。base 段不再建 `conventions.md`、setup 不寫它、移除 `default-files` 的 conventions.md 範本;`CLAUDE.md` base snippet 只留「不得提交僅限本機之物」硬規則(不再指向 conventions.md)。`tp-commit-msg` description 一併由「使用者要求時 / 建議執行」改為主動觸發式。
- 兩層測試套件入口 + 各 SVN 腳本 / lib helper / hook 行為測試(`Common.test.ps1` / `common.test.sh` 自單體拆出、只保留 SVN concern + Core 覆蓋;新增 config reader 容忍 `#` marker 行 + 未知 section 的回歸測試)。

### 遷移說明

- 舊安裝 `turbo-plugin@turbo-plugins-claude` 已由四個獨立 plugin 取代。git↔SVN bridge 與 setup 流程改裝 `turbo-plugin-git-svn@turbo-plugins-claude`;.NET Framework Web / 三環境 DB / 程式碼註解功能分別改裝 `turbo-plugin-dotnet-framework-web` / `turbo-plugin-three-environment-db` / `turbo-plugin-code-comment`。
