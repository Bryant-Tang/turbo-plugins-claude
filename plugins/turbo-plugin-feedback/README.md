# turbo-plugin-feedback

把 turbo-plugin 的問題回報成 GitHub issue 的 skill。turbo-plugins-claude marketplace 的獨立 plugin。

**其它 turbo-plugin 都相依它**,所以你不需要單獨安裝——裝任何一個 turbo-plugin 都會一起帶到。

## Skills

| Skill | 用途 |
|---|---|
| `/tp-report-issue` | 把 turbo-plugin 的 bug / 沉默失敗 / 功能缺口寫成 issue 並送出(含 public repo 的消毒規則)。**主動觸發**,不必等使用者開口 |

## 為什麼是一個獨立的 plugin

這支 skill 對每個 turbo-plugin 都一樣,而使用者可能只裝其中一個。三種放法:

| 放法 | 問題 |
|---|---|
| 每個 plugin 各放一份 | 五份一模一樣的 description 常駐在 context 裡,而且會有五個同名指令 |
| 只放在某一個 plugin | 裝別的 plugin 的人拿不到——**尤其拿不到消毒規則**,而那是唯一有真實代價的一條 |
| **獨立 plugin + 其它 plugin 相依它** | 只有一份;裝哪個都會帶到 |

相依宣告刻意**不帶版本約束**(`"dependencies": ["turbo-plugin-feedback"]`)。帶約束的相依在解析
不到符合的 tag 時會讓**依賴方直接被停用**,而 pre-1.0 的 `^` / `~` 只允許 patch、這個 repo 每個
`feat:` 都跳 minor——約束會立刻對不上,代價是五個 plugin 一起停用。不帶約束就完全避開那條路徑。

## 為什麼需要它

agent 從 plugin 內部原本**查不到**該往哪回報,也不知道回報前要消毒什麼。後果有兩個:

- 遇到問題只會在對話裡抱怨一句、然後自己繞過去——**繞過去之後就永遠不會被回報**。而這套 plugin
  處理的問題多半是**沉默**的(不報錯、不警告),只有實際在用的人會遇到。
- 就算想回報,也可能把內部 hostname、版本庫 URL、客戶或公司專案名寫進一個 **public** repo,
  而做的人不會察覺。

## 安裝

通常不需要——裝任何一個 turbo-plugin 就會自動帶到。要單獨裝的話:

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-feedback@turbo-plugins-claude
```

## 測試

純 skill、無 script,所以測試套件探索到零個測試檔即通過(與 `turbo-plugin-code-comment` 相同):
`tests/Invoke-ScriptTests.ps1` / `tests/invoke-script-tests.sh`。

## License

MIT — 見 [LICENSE](LICENSE)。
