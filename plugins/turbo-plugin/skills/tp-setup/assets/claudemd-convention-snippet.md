<!-- turbo-plugin:begin commit-type-convention -->
## Commit Message Type Convention（由 turbo-plugin 注入）

本專案採用 [conventional commits](https://www.conventionalcommits.org/) 11 類 + `db` 自訂類 = 共 12 類。完整類別與篩選規則由 `.commitlintrc.json` 維護（純諮詢，本專案不裝 commitlint hook）。

| Type | 用途 | 進 SVN history? |
|---|---|---|
| `feat` | 新功能（程式碼） | ✅ |
| `fix` | bug 修正（程式碼） | ✅ |
| `refactor` | 行為不變的整理 | ✅ |
| `perf` | 效能優化 | ✅ |
| `revert` | 撤回前次 commit | ✅ |
| `docs` | 純文件變更 | ❌ |
| `test` | 測試新增 / 調整 | ❌ |
| `chore` | 非實作雜務（依賴升級、設定調整等） | ❌ |
| `style` | 程式碼格式調整 | ❌ |
| `build` | 建置系統 / 工具鏈變更 | ❌ |
| `ci` | CI 設定變更 | ❌ |
| `db` | SQL / DB schema 變更 | ❌ |

**`/tp-push-to-svn` 在推送時會自 parse subject 篩選**:`feat` / `fix` / `refactor` / `perf` / `revert` 保留入 SVN history,其他類別僅留本地 git history。遇到 unknown type(parse 不出或不在 valid types)會 `AskUserQuestion` 三選一(保留 / 篩除 / 取消 push 讓使用者 amend)。

> `.commitlintrc.json` 為篩選 source-of-truth — 編輯該檔加 / 移除 type 後 `tp-push-to-svn` 自動同步。

<!-- turbo-plugin:end commit-type-convention -->
