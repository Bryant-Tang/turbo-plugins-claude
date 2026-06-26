# turbo-plugin-code-comment

C# 與 JavaScript / TypeScript 的**註解撰寫慣例** skill 集。turbo-plugins-claude marketplace 的獨立 plugin。

純 skill plugin：**無 script、不碰 `.turbo-plugin/` 專案狀態、無需 setup**——裝了即可用。

## Skills

- **`tp-csharp-comment`** — 依慣例為 C# 程式碼撰寫 / 補強註解。附 `assets/example-with-comments.cs` 範例。
- **`tp-js-comment`** — 依慣例為 JavaScript / TypeScript 程式碼撰寫 / 補強註解。附 `assets/example-with-comments.ts` 範例。

## 安裝

在 Claude Code 內：

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-code-comment@turbo-plugins-claude
```

裝好後 `/tp-csharp-comment`、`/tp-js-comment` 即可使用（或在相關情境由 agent 依描述觸發）。

## 與其它 turbo-plugin 的關係

`turbo-plugin-code-comment` 與 `turbo-plugin-git-svn`、`turbo-plugin-dotnet-framework-web`、`turbo-plugin-three-environment-db` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 本 plugin 無 script，故無 script 行為測試；orchestrator 在無 `scripts/` 時跳過 lint pre-flight 與 Pester framework gate，於 windows 與 ubuntu 皆回 exit 0（綠）。
- skill 層（人工、可重複）測試見根 repo 的 `tests/docs/` 慣例。

## License

MIT — 見 [LICENSE](LICENSE)。
