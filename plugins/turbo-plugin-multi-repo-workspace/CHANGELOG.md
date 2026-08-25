# Changelog

本檔記錄 turbo-plugin-multi-repo-workspace 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.3.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-multi-repo-workspace--v0.3.0...turbo-plugin-multi-repo-workspace--v0.3.1) (2026-08-25)


### Fixed

* **multi-repo-workspace:** 在子專案裡開隔離時改建成工作區鏡像 ([0ec634a](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/0ec634a84459f3712ea1bf473a68c19d3a824bd4))
* **multi-repo-workspace:** 移除端也要認得重導向後的鏡像 ([028bbd3](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/028bbd3176a0089980e08221fdb81157e51fd105))
* **multi-repo-workspace:** 範本裡的指路示範改成無條件觸發 ([1734d6d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/1734d6d8c2539fc1554b86923551209be0240ac7))

## [0.3.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-multi-repo-workspace--v0.2.0...turbo-plugin-multi-repo-workspace--v0.3.0) (2026-08-19)


### Added

* **multi-repo-workspace:** hook 自己實作 .worktreeinclude ([632a80f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/632a80fe42a5a1a932532e31732a5ed534d2ed8b))
* **multi-repo-workspace:** 工作區形狀改用標記宣告,並修正專案偵測 ([5f42beb](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5f42beb761f586fd4319a4310eced79a2b43d229)), closes [#86](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/86)
* **multi-repo-workspace:** 工作區根只留指路,跨專案規範改放專門的子專案 ([7ba9e61](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7ba9e619690b6ec0e10864a6a2f5e4b56dfafebe))


### Fixed

* remove-worktree 補上註解,說明一般 repo 的容器目錄為何刻意不清理 _(文字經修正;原始標題以 SHA 為準)_ ([3fb675d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3fb675d633b0e0132c20a01d27e34b79ffa5bf2c))
* **multi-repo-workspace:** .worktreeinclude 不再跟隨 symlink ([d84c092](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d84c0928a812a19cb3bb8bb57f62e201814c5327))

## [0.2.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-multi-repo-workspace--v0.1.1...turbo-plugin-multi-repo-workspace--v0.2.0) (2026-08-17)


### Added

* **core:** linked worktree 繼承主 worktree 的機器層設定與 pack-content 核准 ([5a8ffc0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5a8ffc01774e018bd58d5b8c04d63e176bc51007)), closes [#61](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/61)
* **multi-repo-workspace:** WorktreeCreate / WorktreeRemove,讓隔離工作副本在工作區根可用 ([4ad397b](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/4ad397b92ed63af9032c28e0022c7964c7f7a7d3)), closes [#69](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/69)


### Fixed

* **core:** 設定檔的行內註解不再吃掉整個 section 或整個值 ([7b0a34e](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7b0a34e0cb84d88435c0d1f2da1e357c2b1ae253)), closes [#60](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/60)
* **multi-repo-workspace:** 移除 hook 也要認得一般 repo 的 worktree,並擋掉會跳出目錄的名稱 ([4dac9b8](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/4dac9b81dc30fcee6606a65cb2586773e0ed9db9))


### Changed

* **core:** 主 worktree 直接短路,不為了繼承設定多 fork 一次 git ([7d98b3b](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7d98b3b0cabea5d3513e5968d81d6ba2644f9ea3))
* **core:** 移除永遠不會生效的 bash 快取,並把成本寫清楚 ([50ccf70](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/50ccf70d07fb0e19dc8e7c19d8a9e728da44a9da))


### Documentation

* README 寫上 turbo-plugin-feedback 相依 _(文字經修正;原始標題以 SHA 為準)_ ([d9a3728](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d9a3728be8e0270c9170039bcc7b774489ae0e8a))

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-multi-repo-workspace--v0.1.0...turbo-plugin-multi-repo-workspace--v0.1.1) (2026-08-13)


### Fixed

* **core:** config 改用 UTF-8 讀取,非 ASCII 註解不再讓後面整段設定消失 ([c65b4a5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c65b4a50807b71fe8f0cf0c4e1a310d856473fd1))
* **multi-repo-workspace:** 注入的規範補上「動錯分支」,不只擋「動錯 repo」 ([6559003](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/65590034627489972400322ddcf97da4fc35ae8e))

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
