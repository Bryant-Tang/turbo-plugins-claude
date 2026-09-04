# Changelog

本檔記錄 turbo-plugin-git-svn 的版本變更,格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-TW/1.1.0/)。

## [0.7.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.7.0...turbo-plugin-git-svn--v0.7.1) (2026-09-04)


### Fixed

* **git-svn:** bridge 行尾釘選補上 core.eol,repo 有 text=auto 時不再寫出 CRLF ([3514d4d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3514d4df853106e39ae46459d12611365ab02c4b)), closes [#164](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/164)

## [0.7.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.6.0...turbo-plugin-git-svn--v0.7.0) (2026-09-03)


### Added

* **git-svn:** 佔用名單每一輪都要重算,不准沿用上一次 ([5bbc08e](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5bbc08e5d8672050b68422b064697c3e94f124a2))
* **git-svn:** 使用者說要收工時,停止跨 session 通訊 ([6711a53](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/6711a534248822412808f6a8629cd519eb4e414e)), closes [#163](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/163)
* **git-svn:** 分支被別的 worktree 佔用時,改成直接跟佔用它的 session 講 ([ae2c966](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/ae2c966f35b1f1609edaeabb4dcb21ad73510d64))
* **git-svn:** 合併時要指名使用者核准的那個 base 狀態,不是任何 base ([9614a59](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/9614a59993073e3c5a16312b6303dd57229a385c))


### Fixed

* **git-svn:** --expect-base 的錨點改用 \z,`$` 會放行結尾的換行 ([ee4766c](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/ee4766cffd5e7d6a0b22982aaec73476990e9f70))
* **git-svn:** 「分支被哪個 worktree 佔用」的查找從四份複本收成一份 ([e9c3980](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/e9c3980ad7901944e339a8fc31b8be2732d8165d))
* **git-svn:** worktree-list 失敗那個測試的 shim 改用 findstr,for 迴圈版對腳本沒生效 ([cc9b3e5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/cc9b3e5c95bededadf2b58c64836d01ab0bd9f6a))
* **git-svn:** 把上一顆 commit 誤留的突變狀態還原成真正的守門 ([8c1cd04](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/8c1cd04974a12e92f03decb4e349b0c0b6c7bb95))
* **git-svn:** 首推守門改判「分支被誰佔用」,不再要求主 worktree 站在它上面 ([bf839fe](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/bf839fe700014466053d2d211a58dfbcf90ccd5e)), closes [#161](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/161)
* **git-svn:** 首推的分支提示改成警告,確認過就往下走 ([9e948d5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/9e948d5affbc891071edb8004369025d8690060d))


### Documentation

* **git-svn:** README 補上首推守門與 base 狀態核准兩節 ([88b702c](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/88b702c08ed7002919f9eb0460294961a27d57a3))

## [0.6.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.5.0...turbo-plugin-git-svn--v0.6.0) (2026-09-02)


### Added

* **git-svn:** tp-request-merge 補上 PR 缺的兩關——落後 base 先擋、合併後收掉來源分支 ([9f4ea7c](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/9f4ea7c13c5d29e0d5cc24eb343e439cedb20a2d)), closes [#149](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/149) [#145](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/145)


### Fixed

* **git-svn:** 分支被別的 worktree 佔用時改報「已被 checkout」,不再誤報成衝突 ([4ddb4e0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/4ddb4e0583e7871aa94ccc2b0271aef7ce162978)), closes [#150](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/150)
* **git-svn:** 印給人看的 git 輸出關掉 core.quotePath,非 ASCII 檔名不再是八進位跳脫串 ([51511dc](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/51511dcf648c55ceb7ec53bf55cbcaba9a27cac7)), closes [#143](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/143)


### Documentation

* **git-svn:** 更正 svn rm 那則註解,那個離開碼 guard 其實是死碼 ([b547f05](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/b547f05e7a4fead824a84dd0fac046f63e14c49e))
* **git-svn:** 記錄 svn 呼叫為何不受 [#128](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/128) 影響,以及那個安全是碰巧的 ([6bd295d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/6bd295d2f02cbb410e0afad6ecfc8b315957bef3))

## [0.5.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.4.1...turbo-plugin-git-svn--v0.5.0) (2026-09-01)


### Added

* 共用 base 段承認 db 也會寫 config.toml,並要求標記區塊保住使用者填的值 ([3705c8f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3705c8f7bdec6cdf0b62fcafcd13e0e8cfd37cbe))


### Fixed

* **git-svn:** 復原路徑改走 Read-Git,不再因為 git 寫 stderr 而跳過收拾 ([ab3015a](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/ab3015a7b7fbba2870dd6a25af1f6b0d2158294e))
* **git-svn:** 讀取型 git 呼叫改走 Read-Git,守門不再打不到自己存在的理由 ([f4327d7](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/f4327d7255b5020c790f1c5c073e4f3ec8aac163)), closes [#128](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/128)


### Documentation

* base 段不再宣稱 config.toml 的殼一定帶 git-svn / dotnet 兩組空區塊 ([8847fb5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/8847fb56f968da04f54dcc5dd43128c295b9bf91))
* Core.ps1 的 Read-Git 說明補上「復原路徑是允許的例外」 ([89871b3](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/89871b319d28f547b6c1c20ac6a36d8aa600e4be))

## [0.4.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.4.0...turbo-plugin-git-svn--v0.4.1) (2026-08-27)


### Fixed

* git 對 stderr 出警告時不再把健康的 repo 誤判成「不是 git repo」 ([60fabcf](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/60fabcf63a2008b5735db429c12722ce375f8227)), closes [#123](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/123)


### Changed

* Core.ps1 的設定查找鏈抽成 Get-TurboPluginConfig,成為單一來源 ([a8fa467](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/a8fa46720ba7bbe45226f587109ad766953de307))

## [0.4.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.3.0...turbo-plugin-git-svn--v0.4.0) (2026-08-25)


### Added

* **git-svn:** tp-request-merge 拒絕 remote-svn/* 兩端,且不受 git 的 stderr 警告影響 ([f0ea227](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/f0ea227f9e86c6225b0721972b1a011d8737583e))
* **git-svn:** 沒有 git remote 時補上 PR 的等價物 tp-request-merge ([85bf110](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/85bf110274f83f6e3733d8f3a2cab6baf3d4de87))


### Fixed

* **git-svn:** tp-request-merge 的 PowerShell 版在 git 出警告時仍給出正常答案 ([51812a0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/51812a01ec4a357793732e88f5de9033cfcabcdd))
* 共用 setup base 的 ignore 說明改用新的 dbhub 範本檔名 ([a5f9816](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/a5f9816ccce9b5cd7457a8bcd3ba1ef94d396ad9))


### Documentation

* **tp-setup base:** case (a) 的白話只描述情境,動作交給各 concern 自己接 ([82ae1cf](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/82ae1cfcea768bc30c236ef56e70802ab163c734))

## [0.3.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.2.0...turbo-plugin-git-svn--v0.3.0) (2026-08-19)


### Added

* 把「這件事該寫在哪」與 TODO.md 移出 tp-setup ([1ecfa13](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/1ecfa13292dea7733e743d4c014144af3c93c07b))


### Fixed

* **git-svn:** push 清單的排序改用 ordinal,兌現「兩平台逐行相同」 ([3fb675d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3fb675d633b0e0132c20a01d27e34b79ffa5bf2c))
* **git-svn:** push 的檔案清單改由腳本自己印,不再透傳 svn 的亂碼輸出 ([25aee20](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/25aee20fdae5a4b9098ea2281e8de6e24cb09fcd)), closes [#79](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/79)
* **git-svn:** tp-svn-log 的 description 講明它是編碼安全的 ([0e20a87](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/0e20a87345c2128f59e7c8f15502d6c4f7e2fa09)), closes [#80](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/80)
* **git-svn:** 字碼頁表示不了的路徑改為明確失敗,不再靜默寫成問號 ([8c0523c](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/8c0523cd117dc2070a6d81c7da92ec004f905216))
* **git-svn:** 暫存檔清理改用 .NET 刪除,8.3 短路徑不再靜默洩漏 ([738a0b0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/738a0b042c1bcb1ec34e9e85ce99242fdb6bf646))

## [0.2.0](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.1.2...turbo-plugin-git-svn--v0.2.0) (2026-08-17)


### Added

* **core:** linked worktree 繼承主 worktree 的機器層設定與 pack-content 核准 ([5a8ffc0](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/5a8ffc01774e018bd58d5b8c04d63e176bc51007)), closes [#61](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/61)
* **setup:** 注入內容能自我說明、能調和,並補上 TODO.md 這一格落點 ([3a6ae4d](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/3a6ae4dea61bcaf3827819273747a2ea370fe437))


### Fixed

* **core:** 設定檔的行內註解不再吃掉整個 section 或整個值 ([7b0a34e](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7b0a34e0cb84d88435c0d1f2da1e357c2b1ae253)), closes [#60](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/60)
* **git-svn:** 推送 body 依實際併入路徑歸類來源分支,判不出來就不分組 ([619502f](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/619502fb94332e29c7ede839b7628673e5546410))


### Changed

* **core:** 主 worktree 直接短路,不為了繼承設定多 fork 一次 git ([7d98b3b](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7d98b3b0cabea5d3513e5968d81d6ba2644f9ea3))
* **core:** 移除永遠不會生效的 bash 快取,並把成本寫清楚 ([50ccf70](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/50ccf70d07fb0e19dc8e7c19d8a9e728da44a9da))


### Documentation

* **setup:** 把 TODO.md 的追蹤判斷提到寫 ignore 區塊之前,並釐清舊區塊清理範圍 ([7f340d9](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7f340d9649652dfb9a10c6a20acb5af1cd14c8ad))
* README 寫上 turbo-plugin-feedback 相依,並清掉 seed fixture 裡指向已退役文件的註解 _(文字經修正;原始標題以 SHA 為準)_ ([d9a3728](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/d9a3728be8e0270c9170039bcc7b774489ae0e8a))

## [0.1.2](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.1.1...turbo-plugin-git-svn--v0.1.2) (2026-08-13)


### Fixed

* **core:** config 改用 UTF-8 讀取,非 ASCII 註解不再讓後面整段設定消失 ([c65b4a5](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c65b4a50807b71fe8f0cf0c4e1a310d856473fd1))
* **git-svn:** git commit 前提示套用 tp-commit-msg,規範不再靜默落空 ([0f32a29](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/0f32a29f7435e41d632efee3e3db82394535297e))
* **git-svn:** tp-setup 注入的 base ignore 加上 .claude/worktrees/ ([bfc3264](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/bfc32649ba0fac901a4a63b656a181bd0c779688))
* **git-svn:** 另一個指令的 --no-edit 不再讓 commit 的提醒被略過 ([27b3ace](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/27b3ace4edae7fc4e1fe7f8e0c706ca80c8d4486))

## [0.1.1](https://github.com/Bryant-Tang/turbo-plugins-claude/compare/turbo-plugin-git-svn--v0.1.0...turbo-plugin-git-svn--v0.1.1) (2026-08-06)


### Fixed

* **git-svn:** SVN 祖先資料夾改過名時,首次匯入照樣能跨過去 ([c1d0478](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c1d0478c810ad7b5ced5cce2fadc2cc9d9dccb47)), closes [#32](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/32) [#33](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/33)
* **git-svn:** 展開新資料夾時,Linux 上的 .git/.svn 排除也要生效 ([7bf0777](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/7bf0777a4b899c8b5ef8bd71cc193732641d95c2))
* **git-svn:** 幾千個檔案的推送不再撞命令列長度上限 ([be48535](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/be48535e1c61c002bba40af64e46b664ce1a3f28)), closes [#35](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/35)
* **git-svn:** 推送清單展開全新資料夾內的檔案,svn 太舊時直接說要升級 ([77d2229](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/77d22296c8a77334a304bf033aed29d608f1b431)), closes [#24](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/24) [#26](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/26)
* **git-svn:** 檔名含 @ 不再讓整批推送失敗,失敗後也講清楚怎麼收拾 ([f2e0250](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/f2e025092687742ed47b067290f2a103e1369d34)), closes [#34](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/34)
* **git-svn:** 檔名編碼提醒改看實際字碼頁,不再假設是中文版 Windows ([73572e3](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/73572e3e5f8d48c9da36f18bfc0320af1311bde8)), closes [#27](https://github.com/Bryant-Tang/turbo-plugins-claude/issues/27)
* **git-svn:** 系統設成 UTF-8 的機器上,targets 檔不再被加上 BOM ([ead9309](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/ead9309f28c79d2e1d06a52e658a9a07d0603a2c))
* **git-svn:** 資料夾改名又改回來時,中間那幾個修訂也追得到 ([c61cad7](https://github.com/Bryant-Tang/turbo-plugins-claude/commit/c61cad70df9517e3a4ddb5f051c7cffce964845b))

## [Unreleased]

## [0.1.0] - 2026-06-20

### Added

- 初版:git↔SVN bridge 與 setup 的獨立可安裝 plugin。
- 8 支 skill(保 `tp-*` 前綴):`tp-setup`、`tp-pull-from-svn`、`tp-push-to-svn`、`tp-checkout-svn-branch`、`tp-svn-log`、`tp-merge-main-into-branches`、`tp-suggest-ignore`、`tp-commit-msg`。
- SVN bridge 腳本對(`.ps1` + `.sh`):Build-SvnCommit / Submit-SvnCommit / Sync-FromSvn / Get-SvnLog / Get-PushPreflight / Initialize-GitSvnBridge / New-RemoteBridge / Checkout-SvnBranch / Remove-SvnFile / Merge-MainIntoBranches / Tag-Release / Test-EncodingSupport。
- `lib`:`Core.{ps1,sh}` 複本 + SVN concern `Common.ps1` / `common.sh`(branch 名消毒、remote worktree 解析、SVN URL trust 邊界檢查、`svn status --xml` 解析;去除 dotnet concern)+ `ps1-delegate.sh`。**「`svn` 絕不互動」的 shim(shadow `svn`、一律補 `--non-interactive`)住在 SVN concern lib,不在 universal Core**:Core 是被位元組相同複製進每個 plugin 的檔(由 `tools/verify-core-identical.sh` 把關),svn shim 不該出現在不碰 svn 的 plugin 裡;本 plugin 每一支可能呼叫 svn 的腳本 source 的都是 concern lib,choke point 不變。(同理於先前把 `Get-WorktreesDir` 移出 universal Core。)
- `SessionStart` advisory hook(marker 缺失時提示 `/tp-setup`;dbhub / IIS 分支已移至 sibling plugin)。
- `default-files/.turbo-plugin/`:`config.toml` 範本,引入 marker scaffolding(config.toml 用 `# >>> turbo-plugin:<concern> >>>` TOML 註解標記),讓各 plugin 的 setup 只寫自己的標記區塊、彼此不覆蓋(已驗證 `Read-TurboPluginConfig` 略過 `#` marker 行)。
- `tp-setup` 改為 **standalone 架構**:共用 `assets/setup-base.md`(concern-neutral 骨架,各 plugin 引用)+ git-svn concern(bridge bootstrap / `[svn]` / git-svn 標記區塊)。**移除 IIS apphost(→ dotnet plugin)、dbhub(→ db plugin)、Phase 3 Claude Code 功能詢問**。case (a)(新建)/(b)(接管現有 git+SVN)的 git↔SVN bridge bootstrap 由固定腳本 `Initialize-GitSvnBridge`(`.ps1` / `.sh`)承接——空 main 先行 → orphan bridge + `svn checkout` → 固定 `svn:ignore=.git` → `git merge --allow-unrelated-histories` 進當前分支(case (b) 衝突由 agent 端手動解後接骨架);agent 只留收 SVN URL / 收 git 身分(`IDENTITY_REQUIRED` 重呼叫迴圈)/ 確認,base 骨架腳本後置。含兩層測試(Pester + shunit2,svn-gated;case a/b × 空/非空 SVN、可重入、rollback、MERGE_CONFLICT 回報)。
- **`conventions.md`「先讀慣例」機制整套退役**:`tp-commit-msg` / `tp-csharp-comment` / `tp-js-comment` / `tp-db-management` 全改靠各自 skill 的 `description` 讓 agent 主動觸發。base 段不再建 `conventions.md`、setup 不寫它、移除 `default-files` 的 conventions.md 範本;`CLAUDE.md` base snippet 只留「不得提交僅限本機之物」硬規則(不再指向 conventions.md)。`tp-commit-msg` description 一併由「使用者要求時 / 建議執行」改為主動觸發式。
- 兩層測試套件入口 + 各 SVN 腳本 / lib helper / hook 行為測試(`Common.test.ps1` / `common.test.sh` 只保留 SVN concern + Core 覆蓋;新增 config reader 容忍 `#` marker 行 + 未知 section 的回歸測試)。
- **`tp-push-to-svn` push 訊息改腳本鎖定(body 腳本組、title agent 寫)**:`build-svn-commit` 以 `git log --no-merges --pretty=format:'- %s'` 列出範圍內**所有非-merge commit subject**(`- ` 條列、無 hash、**無 commit-type 過濾**;merge 以 parent 數排除),把鎖定 body 寫進 `MERGE_HEAD.tp_svn_body` pin 檔並印 `BODY` 區段。`submit-svn-commit` 參數由 `--message` 改為 **`--title`**(agent 只給一行 title),讀回鎖定 body 自組「title + 空行 + body」;title 先 collapse 成單行,防止用換行把內容塞進 body 繞過鎖定。SKILL 移除 commit-type 篩選 / unknown-type 逐筆詢問 / 自由編輯迴圈,確認改固定三選「確認送出 / 改標題 / 取消」;區間只有 merge commit 時硬停(不 stage、不問 release tag,與「有 merge commit 才問 tag」規則一致)。新增 `Get-SvnPushBody` / `get_svn_push_body` lib helper,並補 body determinism(相同 commit 集合 → 位元組一致)/ no-merges 排除 / docs·chore 全入 body / 特殊字元原樣 / only-merge 空 body 的單元測試。
- **新 skill `tp-checkout-svn-branch`(U11 / R16–R20 / KTD5)**:一步把**既有** SVN 分支匯入成 `remote-svn/<branch>` bridge + 已填內容工作分支(工作分支由 bridge ref 開出,首次 `/tp-pull-from-svn` 不撞 unrelated histories)。**對 SVN 端唯讀**——以 `New-RemoteBridge` 為樣板但跳過其 `svn copy` / `svn:ignore` propset / `svn commit` arm,只 `svn checkout`(讀)+ 本機 git 寫;失敗完整回滾(work branch / worktree / bridge),被匯入分支無新 revision。前置:`remote-svn-main` 必須是有效 svn WC(訊息區分目錄缺 / WC 損壞並帶 svn info 原因,不自行 bootstrap 主 bridge)。所有守衛在任何 mutation 之前:`Assert-TrustedSvnUrl` 信任檢查(R18)、`Resolve-RemoteWorktree` 命名 / 碰撞(R19)、同名工作分支零副作用拒絕(R20)、分支名預設取 SVN 葉名消毒(葉名空 / 被 allowlist 拒 → 要求 `--branch`)。新增 `Checkout-SvnBranch.ps1` + `checkout-svn-branch.sh` 腳本對與兩層測試(arg / 衝突 / fail-closed 純 git 跑;trust 拒絕 / 唯讀 happy import round-trip〔bridge+work branch tip 相等、merge-base 非空、SVN 無新 revision〕svn-gated、無 svn 自我 SKIP)。
- **`tp-suggest-ignore` 的 SVN 移除改委派新腳本 `Remove-SvnFile`(`.ps1` / `.sh`)**:Un-track Option A 與 Inconsistency Option B 不再由 agent 裸下 `svn delete` / `svn commit`。`Remove-SvnFile` pre-flight(任何 svn delete 之前)定位 bridge、確認 svn-tracked、判 git-tracked?→ git-tracked(Un-track A)走 reconcile(`svn delete` + UTF-8 `--file` commit + bridge `git add -A` + `sync: svn r<rev>` commit + `Merge branch 'remote-svn/<branch>' into <branch>` `--no-ff`,**格式與 `/tp-pull-from-svn` 完全一致**,`remote-svn/*` 只有 sync + merge commit);git-ignored(Inconsistency B)只 `svn delete` + commit(bridge 本就乾淨、no-reconcile);非 svn-tracked / bridge 缺 → fail loudly 零副作用。**不委派 `/tp-push-to-svn`**(push 對「保留本機檔」的 un-track 有「main-clean gate」與「`check-ignore` skip」死結)。Un-track A 在 main 先 `git rm --cached` + `.gitignore` + commit(保留本機檔),再委派腳本。含兩層測試(Pester + shunit2,svn-gated:no-reconcile / reconcile〔含 commit 格式一致性〕/ pre-flight 拒絕;`.ps1` 另含非 ASCII CJK 檔名)。
- **多專案工作區支援(共用同一個 SVN repo / 同一個資料夾底下並排多個 repo)**:
  - **共用 SVN repo 的 push/pull 死鎖**:`Build-SvnCommit` / `build-svn-commit.sh` 的 up-to-date 比對從「repo HEAD」改成**這條路徑的 `last-changed-revision`**,所以兄弟路徑的 commit 不再讓 push 誤判為落後;`Sync-FromSvn` / `sync-from-svn.sh` 在「無事可做」分支若 working copy 落後 repo HEAD 仍做一次 `svn update`,兩半一起解掉死鎖。(實測依據:`last-changed-revision` 在目錄 URL 上會從深層檔案冒泡;WC 落後 repo HEAD 但自身路徑未變時 `svn commit` 會成功。)
  - **第三道跑錯資料夾守門**:`Initialize-GitSvnBridge` 在 `git init` 之前偵測「這裡不是 repo、但直屬子目錄是」→ 回 `TP_TOKEN:NESTED_GIT_REPOS dirs=<names>` 零變更退出,旗標 `-AllowNestedRepos` / `--allow-nested-repos`。前兩道守門擋不到這種情況,因為該目錄真的沒有 git 而 `git rev-parse` 只往上找;在這裡 `git init` 會把並排的專案全包成一個 repo 且事後無法還原。
  - **每支入口腳本可用 `-RepoRoot` / `--repo-root` 明確指定 repo**(11 支全部)。不給時行為與先前完全相同(內部傳 `.` 給 `git -C`,是 no-op);有給時正規化路徑並確認是目錄,typo 在此就報錯而不是稍後變成 git 的 "cannot change to"。三道守門判的都是**指名的那個目標**。`Get-MainWorktree` / `Test-IsMainWorktree` / `Test-IsSubmodule` 與新的 `Resolve-GitRoot` 收此參數(universal Core,已同步到所有 plugin 副本)。
  - **新共用判準 `assets/repo-target.md`**(跨七支 SKILL,只有一份):當前目錄是 repo → 不傳;當前目錄不是 repo 但底下並排多個 repo → 不要猜、先問使用者再指名;使用者點名別的專案 → 指名它。會寫入的指令(`tp-setup` / `tp-push-to-svn` / `tp-pull-from-svn` / `tp-suggest-ignore` 的 SVN 移除)在既有確認裡先寫出「要動的專案:`<絕對路徑>`」——當前目錄**是**一個合法 repo、只是不是使用者想的那個時,三道守門一個都不會響,只有把路徑攤出來才擋得下。
  - 各 SKILL 原本寫的「必須在 main worktree 跑」從來不字面成立(腳本自己會定位主 worktree),改為「作用對象是目標 repo 的主 worktree」。
- **逐修訂(per-revision)replay:pull 與首匯不再把整段 SVN 歷史壓成一顆快照**。`Sync-FromSvn` / `sync-from-svn.sh` 與 `Initialize-GitSvnBridge` 共用同一組 replay primitive(`lib` 的 `Invoke-SvnOneReplay` / `Invoke-SvnBoundaryCommit` / `Invoke-SvnReplayDispatch`,bash 對應 `svn_replay_one_revision` / `svn_boundary_commit` / `svn_replay_dispatch`),逐一 `svn update -r R` → 為每個 SVN 修訂建一顆對應的 git commit,**保留原作者 / 訊息 / 時間**。每顆 replay commit 由 `refs/tp/svn/<N>` ref 標記(不靠 commit message 解析,所以偽造不了),中斷後可續跑:已標記的修訂被視為可恢復狀態、不會被誤判成孤兒 sync commit。
- **粒度選擇(`TP_TOKEN:GRANULARITY_REQUIRED`)**:新修訂數 **≤ 5 時直接逐修訂、不打擾使用者**;超過 5 且未帶粒度參數時腳本回報此 token 並 **exit 0、零 commit、零落地**(乾淨可重跑),由 SKILL 用**白話**三選一詢問(一顆一顆保留 / 壓成一顆 / 指定一段逐一保留),再帶 `-Granularity`(必要時加 `-Range`)重跑。門檻常數集中在 concern lib(`TpGranularityThreshold` / `TP_GRANULARITY_THRESHOLD`),pull 與首匯共用同一個定義所以不會漂。
- **`tp-checkout-svn-branch` 的分岔點(fork-point)分級解析**:匯入的分支不再一律接在 `remote-svn/main` 的 tip 上——改為讀 SVN 的 copy-from 修訂,並以 **trunk 的有效版號**(而非 repo HEAD)分級查找對應的本機 git commit,再換 base ref、保留 SVN 那棵 tree 不變。這解掉了「長命分支 merge 回 main 出現假衝突」以及分級查找的無解死結。分支的原始名(含斜線)存在 svn 屬性 `tp:branch-name`,checkout 時優先用它還原,不靠 SVN 路徑的 dash 形反推。
- **`tp-svn-log` 輸出與互動**:改為框線區塊格式(每筆用雙線框住、區段用單線分隔),單一特定修訂自動帶 `--verbose` 變更清單,分頁游標以白話呈現(機器標記 `# LAST_SHOWN_REV=<n>` 只供 agent 內部讀取、不裸露給使用者);分頁互動用純文字選項而非 modal。`get-svn-log.sh` 一併**移除 xmllint 依賴**(改用 `grep -oE`,因為 zh-TW Git Bash 的非 UTF-8 locale 會讓 `grep -P` 整支拒跑),修好 bash 端 `--verbose` 的變更清單與 XML 實體解碼。
- **`tp-suggest-ignore` 的 Un-track A 完成後自動同步 `.gitignore` 到 SVN**:先前新增的 ignore 行只留在 `main`,要等下一次 push 才上 SVN;現在委派 `/tp-push-to-svn` 把它推上去(`Remove-SvnFile` 的 SVN commit 只含被刪的那個檔,所以 `.gitignore` 仍是 git 側的變更)。
- **已 bridge(兩個 root commit)的 repo 首推 / checkout 不再撞 `git branch 'not a valid object name'`**:`New-RemoteBridge` 的新分支改以 `remote-svn/main` 為 base(trunk 的 git 鏡像,永遠是單一 ref),`Checkout-SvnBranch` 改走 orphan;pull 與 `Remove-SvnFile` 的守衛也不再把 post-push 留下的 merge commit 誤判成「未併的 sync」。
