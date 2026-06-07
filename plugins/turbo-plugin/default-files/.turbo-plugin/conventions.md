# turbo-plugin 專案慣例

本檔由 turbo-plugin 維護,進 git、跨同事共享。執行對應操作前,先讀本檔對應條目並遵守指向的 skill(完整規則在各 skill 內)。

- **資料庫 / SQL 操作** → 遵守 `/tp-db-management`(dbhub MCP 唯讀檢視 + SQL 標準化到 `.turbo-plugin/sql/`)。
- **撰寫 commit message** → 遵守 `/tp-commit-msg`(commit type 依 `.commitlintrc.json`;不得引用 git SHA 或僅本地識別碼;祈使句 + what+why + 語言一致)。
- **修改 `*.cs`(C#)** → 遵守 `/tp-csharp-comment`(XML doc + 解釋註解,寫給未來不在現場的新進工程師)。
- **修改 `*.js` / `*.ts`(含 `.vue` / `.cshtml` 的 `<script>` 區塊)** → 遵守 `/tp-js-comment`(JSDoc + 解釋註解)。
