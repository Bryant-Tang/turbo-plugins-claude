# plugins/turbo-plugin-dotnet-framework/tests/fixtures/base/

turbo-plugin Script tests 的 **fixture base mirror source**。

## 用途

此目錄是 `Reset-Fixture.ps1` 跑 `robocopy /MIR` 的 source。每個 Script tests case 開始前
orchestrator 會把這個目錄完整 mirror 到 repo 內 gitignored 的 `<tests>/.sandbox/test-turbo-plugin/`,讓每 case 在
完全乾淨的 fixture 上跑。

## 內容

```
base/
├── HelloApp.sln                    # VS solution wrapping HelloApp.csproj
├── HelloApp.csproj                 # .NET Framework 4.7.2 Web Application
├── Controllers/HelloController.cs  # 最小 MVC controller + 中文 string literal
├── Scripts/site.js                 # 最小 JS + 中文 comment / string
├── Views/Home/Index.cshtml         # 最小 MVC view + 中文 markup
├── Web.config                      # .NET Framework Web App 設定
├── .turbo-plugin/
│   ├── applicationhost.config      # IIS Express config (含 __TURBO_PLUGIN_PHYSICAL_PATH__)
│   └── config.toml                 # [iis] enabled = true 等
└── README.md                       # 你正在讀這個
```

## **不要直接編輯運行中的 fixture(`<tests>/.sandbox/test-turbo-plugin/`)**

那個 workspace 由 `Reset-Fixture.ps1` 隨時可能被砍掉重建。任何永久性改動請改這個
`base/` 目錄,並重跑:

```powershell
.\tests\fixtures\reset\Reset-Fixture.ps1
```

## 變更時注意

1. 改 `.csproj` 後請確認 MSBuild 仍可 build(在當前 fixture 上手動跑 MSBuild 測一次)。
2. 改 `applicationhost.config` 不要動掉 `__TURBO_PLUGIN_PHYSICAL_PATH__` placeholder 字面值
   — tp-run-dotnet-framework 與 start-iis 等 script 都會檢查這個字串。
3. 加新檔請列入此 README 的「內容」section。
