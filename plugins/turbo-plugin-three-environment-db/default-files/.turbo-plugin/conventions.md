# turbo-plugin 專案慣例

本檔由 turbo-plugin 系列 plugin 維護,進 git、跨同事共享。執行對應操作前,先讀本檔對應條目並遵守指向的 skill(完整規則在各 skill 內)。

下面的 `<!-- turbo-plugin:begin <concern> -->` / `<!-- turbo-plugin:end <concern> -->` 是各 plugin setup 的標記區塊,每個 plugin 只更新自己的區塊、彼此不覆蓋。

<!-- turbo-plugin:begin git-svn -->
<!-- turbo-plugin:end git-svn -->

<!-- turbo-plugin:begin db -->
<!-- turbo-plugin:end db -->

<!-- 以下程式碼註解慣例由 turbo-plugin-code-comment 提供(純 skill、無 setup,故為靜態內容) -->
- **修改 `*.cs`(C#)** → 遵守 `/tp-csharp-comment`(XML doc + 解釋註解,寫給未來不在現場的新進工程師)。
- **修改 `*.js` / `*.ts`(含 `.vue` / `.cshtml` 的 `<script>` 區塊)** → 遵守 `/tp-js-comment`(JSDoc + 解釋註解)。
