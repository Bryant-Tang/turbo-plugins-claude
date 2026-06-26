# plugins/turbo-plugin-git-svn/tests/fixtures/base/

turbo-plugin-git-svn Script tests 的 **fixture base mirror source**。

## 用途

此目錄是 `Reset-Fixture.ps1` 跑 `robocopy /MIR` 的 source。每個 Script tests case 開始前
orchestrator 會把這個目錄完整 mirror 到 repo 內 gitignored 的 `<tests>/.sandbox/test-turbo-plugin/`,讓每 case 在
完全乾淨的 fixture 上跑。

git↔SVN bridge 是**內容無關**的(決定 push 哪些檔靠 git,不看檔案類型),所以這裡放什麼當工作樹內容都可以。
目前沿用一個小型 sample 專案當 version-control payload。**IIS / .NET 建置 / 發佈等 concern 屬
`turbo-plugin-dotnet-framework-web`**,所以此 fixture 不再帶 `applicationhost.config` 或
`[iis]/[build]/[publish]/[run]` 設定 — `.turbo-plugin/config.toml` 只留 git-svn 自己的 `[svn]` 區段。

## 內容

```
base/
├── HelloApp.sln                    # sample VS solution(SVN payload,內容無關)
├── HelloApp.csproj                 # sample 專案檔(SVN payload)
├── Controllers/HelloController.cs  # sample 源檔 + 中文 string literal
├── Scripts/site.js                 # sample JS + 中文 comment / string
├── Views/Home/Index.cshtml         # sample view + 中文 markup
├── Web.config                      # sample 設定檔(SVN payload)
├── .turbo-plugin/
│   └── config.toml                 # 只含 [svn] 區段
└── README.md                       # 你正在讀這個
```

## **不要直接編輯運行中的 fixture(`<tests>/.sandbox/test-turbo-plugin/`)**

那個 workspace 由 `Reset-Fixture.ps1` 隨時可能被砍掉重建。任何永久性改動請改這個
`base/` 目錄,並重跑 `Reset-Fixture.ps1`(`.ps1`)或 `reset-fixture.sh`(`.sh`)。

## 變更時注意

1. 這些 sample 檔只是 bridge 的 version-control payload(bridge 不在意檔案類型);改動後沿用既有測試重跑即可。
2. 加新檔請列入此 README 的「內容」section。
