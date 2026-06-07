<!-- turbo-plugin:begin commit-type-convention -->
## 專案慣例（由 turbo-plugin 注入）

執行下列操作前,**先讀 `.turbo-plugin/conventions.md`** 並遵守其中指向的 skill:

- 任何**資料庫 / SQL** 操作前 → `/tp-db-management`
- 撰寫 **commit message** 前 → `/tp-commit-msg`
- 修改 **`*.cs`** 前 → `/tp-csharp-comment`
- 修改 **`*.js` / `*.ts`**(含 `.vue` / `.cshtml` 的 `<script>`)前 → `/tp-js-comment`

**不得提交僅限本機才有的東西**:機器路徑、內部 hostname / URL、僅本機 / 單次情境識別碼,一律不得寫進版控(文件需舉例時改用 placeholder token)。
<!-- turbo-plugin:end commit-type-convention -->
