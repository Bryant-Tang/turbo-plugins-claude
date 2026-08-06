# 前端打包偵測（frontend pack check）共用片段

> **這份檔案是 turbo-plugin-dotnet-framework 的共用片段**,被 `tp-build` 與 `tp-publish` 的 SKILL 以
> 「**讀並遵循**」方式引用,路徑 `${CLAUDE_PLUGIN_ROOT}/assets/frontend-pack-check.md`。
> 它放在 plugin 根的 `assets/` 而不是某個 skill 底下,因為兩個 skill 都用它、沒有哪一個是它的擁有者。
>
> **`tp-run` / `tp-stop` 不引用本檔**——它們不建置,也就沒有打包這件事。

## 為什麼需要這一步

`Compress-Content` 在沒有前端設定時會**安靜跳過**(印一行 skip 訊息後 exit 0)。而 SKILL 要求你只把
結果模板的內容轉述給使用者,所以那行 skip 訊息**實際上沒有人會看到**——使用者只知道「build 成功」,
不會知道前端根本沒被打包。

這不是 script 的錯,也不是你的錯:是「該講的話沒有進到會被轉述的地方」。因此**在跑之前**由你判斷這專案
需不需要打包前端,別把它交給 script 的沉默。

publish 這條路徑更要緊——發佈產出會送到部署環境,缺前端資產卻沒人吭聲的代價比 build 高得多。

## 判斷順序（最多只問一次）

1. 讀 `.turbo-plugin/config.toml` / `config.local.toml` 的 `[frontend] dir`。
   **有值** → 已經設定好了,什麼都不必問,直接往下走。
2. 讀 `[frontend] enabled`。**是 `false`** → 使用者先前已表態這個專案不需要前端打包,
   **別再問**,直接往下走。
3. 兩者都沒有 → 用 Glob 在目標專案內找 `package.json`,**排除** `node_modules/`、`bin/`、`obj/`、
   `.vs/`、`.git/`。
   - **找不到** → 這專案沒有前端,不問,直接往下走。
   - **找到** → 進下面的詢問。

## 詢問（`AskUserQuestion`）

問句用**白話**,**不要**把設定檔的 key 名（`[frontend] dir` 之類）丟給使用者——他不需要知道設定檔長怎樣:

> 這個專案裡有前端程式(找到 `<package.json 的相對路徑>`)。建置時要一起打包前端嗎?

| 選項 | 動作 |
|---|---|
| (a) 要,一起打包 | 接著問「安裝指令」與「打包指令」。建議預設 `npm install` / `npm run build`,並**先讀 `package.json` 的 `scripts`**,把實際存在的 script 名當候選(專案可能是 `build:prod`、`dist` 等)。依下方「寫入規則」把 `dir` / `install_command` / `build_command` 寫進 `[frontend]`。 |
| (b) 不用 | 依下方「寫入規則」寫 `[frontend] enabled = false`,當作「已經問過」的記號,之後不再打擾。 |

**找到多個 `package.json`** → 把候選列給使用者選(通常最外層那個才是前端根;`node_modules` 已排除)。

## 寫入規則

遵循 `${CLAUDE_PLUGIN_ROOT}/assets/memory-save-back.md` 的「**寫進去之前:兩個必須先確保的前置**」與
「**怎麼寫:agent-Edit 讀-改-寫規則**」兩節(確保 `.turbo-plugin/` 與 dotnet 標記區塊存在、只動 marker
區塊內、key 一律落在 `[frontend]` header 之下、保留檔案 BOM 狀態)。

差別只有一個:**預設寫 committed 的 `config.toml`**,不是 local。前端怎麼打包是**專案結構事實**
(同事 clone 下來也一樣),不是個人偏好或機器路徑。使用者若明確說只要自己這台生效,才寫 `config.local.toml`。

## 銜接 TRUST_REQUIRED

選 (a) 之後,新寫進去的指令**必然**還沒通過信任核准,所以第一次執行會拿到 `TRUST_REQUIRED`。

那是**同一件事的第二次確認**,不要讓使用者以為自己被問了兩個不相干的問題。把它接成
「剛才你說要打包前端,這是實際會執行的指令,確認一下」,並直接顯示指令內容,而不是重新起一個
沒頭沒尾的確認問句。
