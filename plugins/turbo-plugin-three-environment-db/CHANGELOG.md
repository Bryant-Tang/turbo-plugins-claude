# Changelog

本檔記錄 turbo-plugin-three-environment-db 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.4.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.4.0...turbo-plugin-three-environment-db--v0.4.1) (2026-08-27)


### Fixed

* git 對 stderr 出警告時不再把健康的 repo 誤判成「不是 git repo」 ([60fabcf](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/60fabcf63a2008b5735db429c12722ce375f8227)), closes [#123](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/123)

## [0.4.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.3.0...turbo-plugin-three-environment-db--v0.4.0) (2026-08-25)


### Added

* **three-environment-db:** SQL 落點改用 &lt;slug&gt;,沒有 git 時問使用者 ([2bef75f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/2bef75f1a7e36d699161da91fb5bc135efd707ce))


### Fixed

* **three-environment-db:** case (a) 照樣寫 CLAUDE.md base,且不再把 tp-db-management 說成不可用 ([6f085c9](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/6f085c935337addc33830f0246c22012b89276e5))
* **three-environment-db:** case (a) 自己供給白話,並把完成報告的四項都納入檢查 ([470d5e5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/470d5e5a8a5e5f2b417994e3c70ae4d8726ed56e))
* **three-environment-db:** dbhub 範本改名成 dbhub.example.toml,標記同時認舊檔名 ([12de519](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/12de51983fb04ac34f7e2f0133ee3aaab2d96f16))
* **three-environment-db:** 對齊 tp-setup 裡幾處互相不一致的說法 ([9f258db](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/9f258db67c6d873f834b5e9a0fadc77133845e2b))
* **three-environment-db:** 找不到設定時的提示也要提改名前的範本檔名 ([54e16ca](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/54e16cafa9464ba2ab465d345e7faa1c07737917))
* **three-environment-db:** 文件改用新範本名,並定死舊檔名不改也不重複部署 ([a9f1e3f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/a9f1e3f20d3efebf17a334c07320b0e57e47f653))
* **three-environment-db:** 更正 case (a) 對 CLAUDE.md marker 機制的說明 ([eb0605f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/eb0605ff1388f6223cd42495d6fae58c1759a521))
* **three-environment-db:** 更正 tp-setup 說 SQL 產出需要 git 的過時說法 ([97f0d6f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/97f0d6f03797b9703ae9c8e41fb31cd807a3347d))
* **three-environment-db:** 非 git repo 時只跳過需要 git 的段,不整個擋掉 ([b36e779](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/b36e779f4a6612f44d71be71db5524c526ddd3d5))
* 共用 setup base 的 ignore 說明改用新的 dbhub 範本檔名 ([a5f9816](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/a5f9816ccce9b5cd7457a8bcd3ba1ef94d396ad9))


### Documentation

* **three-environment-db:** Phase 2 概述句補上 case (a) 的例外 ([3b5f016](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3b5f0169c9fd581c776ed51c6317e52998c6fd60))
* **tp-setup base:** case (a) 的白話只描述情境,動作交給各 concern 自己接 ([82ae1cf](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/82ae1cfcea768bc30c236ef56e70802ab163c734))

## [0.3.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.2.0...turbo-plugin-three-environment-db--v0.3.0) (2026-08-19)


### Added

* 把「這件事該寫在哪」與 TODO.md 移出 tp-setup ([1ecfa13](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/1ecfa13292dea7733e743d4c014144af3c93c07b))

## [0.2.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.1.1...turbo-plugin-three-environment-db--v0.2.0) (2026-08-17)


### Added

* **core:** linked worktree 繼承主 worktree 的機器層設定與 pack-content 核准 ([5a8ffc0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5a8ffc01774e018bd58d5b8c04d63e176bc51007)), closes [#61](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/61)


### Fixed

* **core:** 設定檔的行內註解不再吃掉整個 section 或整個值 ([7b0a34e](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7b0a34e0cb84d88435c0d1f2da1e357c2b1ae253)), closes [#60](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/60)


### Changed

* **core:** 主 worktree 直接短路,不為了繼承設定多 fork 一次 git ([7d98b3b](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7d98b3b0cabea5d3513e5968d81d6ba2644f9ea3))
* **core:** 移除永遠不會生效的 bash 快取,並把成本寫清楚 ([50ccf70](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/50ccf70d07fb0e19dc8e7c19d8a9e728da44a9da))


### Documentation

* **setup:** 把 TODO.md 的追蹤判斷提到寫 ignore 區塊之前,並釐清舊區塊清理範圍 ([7f340d9](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7f340d9649652dfb9a10c6a20acb5af1cd14c8ad))
* README 寫上 turbo-plugin-feedback 相依 _(文字經修正;原始標題以 SHA 為準)_ ([d9a3728](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d9a3728be8e0270c9170039bcc7b774489ae0e8a))

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-three-environment-db--v0.1.0...turbo-plugin-three-environment-db--v0.1.1) (2026-08-13)


### Fixed

* **core:** config 改用 UTF-8 讀取,非 ASCII 註解不再讓後面整段設定消失 ([c65b4a5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c65b4a50807b71fe8f0cf0c4e1a310d856473fd1))
* tp-setup 注入的 base ignore 加上 .claude/worktrees/ _(文字經修正;原始標題以 SHA 為準)_ ([bfc3264](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/bfc32649ba0fac901a4a63b656a181bd0c779688))

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 初版:三環境 DB 開發輔助的獨立可安裝 plugin。
- `tp-db-management` skill(含 `assets/sql-script-template.sql`)。
- `tp-setup` skill(standalone:共用 `assets/setup-base.md` concern-neutral 骨架 + db concern〔`dbhub.example.local.toml` 範本、提示填 `dbhub.local.toml`、peer-mode 處理 per-peer `dbhub.local.toml`〕;無 git repo 時 fail-loud,不自行 git init)。
- `tp-db-management` 的 `description` 強化為**主動觸發**式(「做任何資料庫 / SQL 工作時主動使用、不要繞過直接手寫 SQL」),改靠 description 讓 agent 自動採用;`conventions.md`「先讀慣例」機制已整套退役,db setup 不再寫它。
- `tp-dbhub` MCP server 宣告(`.mcp.json`,經 DBHub 容器連 SQL Server,讀 `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`)。
- SessionStart advisory hook:當專案使用 db(`.turbo-plugin/dbhub.example.local.toml` 存在)、於 peer worktree 啟動且缺 `dbhub.local.toml` 時,提示 tp-dbhub MCP 將無法啟動。advisory(不 block session);專案未用 db 時 no-op(concern-marker gate)。
- `default-files/.turbo-plugin/dbhub.example.local.toml` 連線設定範本。
- 兩層測試套件入口 + SessionStart hook 行為測試(PS + bash:non-git / dbhub 警示 / no-marker 靜默 / gate no-op)。
- `scripts/lib/Core.{ps1,sh}`:universal core helper 複本(供 hook 用),與其它 plugin 逐位元組一致(由 repo 層 CI job 把關)。
