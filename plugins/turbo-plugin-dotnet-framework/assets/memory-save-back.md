# 記憶存回（save-back）共用片段

> **這份檔案是 turbo-plugin-dotnet-framework 的共用片段**,被 `tp-build` / `tp-publish` /
> `tp-run` 的 SKILL 以「**讀並遵循**」方式引用,路徑
> `${CLAUDE_PLUGIN_ROOT}/assets/memory-save-back.md`。它放在 plugin 根的 `assets/` 而不是某個
> skill 底下,因為三個 skill 都用它、沒有哪一個是它的擁有者。
>
> **`tp-stop` 不引用本檔**——stop 只回報、永不 save-back。

## 這是什麼

把「給 agent 用的 VS 2022」的選擇記成 VS `.suo` 類比:你(agent)每次 build/run/publish 為某操作選定的
**目標(csproj / `.sln`)、明確選的 configuration/platform、pubxml**,執行後若與「已存的記憶」不同,就問
使用者要不要存起來,下次沿用。記憶走既有的兩層設定查找,**不另開機制**。

## 兩層記憶 = 既有設定查找

讀取沿用 `Resolve-ConfigValue` 的四層鏈:`CLI 參數 → config.toml → config.local.toml → 內建預設`
(`config.local.toml` 蓋 `config.toml`、後者進版控前者不進)。所以「存記憶」就是把值寫進這兩個檔之一的
**對應 section key**。

**每個操作讀/寫自己的 key,存回與讀回同一個**:

| 操作 | 目標 key | configuration/platform | pubxml |
|---|---|---|---|
| build | `[build].project`(可為 `.sln`) | `[build].configuration` / `[build].platform` | — |
| run / stop | `[run].project`(無值時 fallback 讀 `[build].project`) | 無(run 不涉 config) | — |
| publish | `[publish].project`(只能 csproj) | `[publish].configuration` / `[publish].platform` | `[publish].default_pubxml` |

> **向後相容**:run/stop 讀 `[run].project` 沒值時會 fallback 讀 `[build].project`(既有只設過
> `[build].project` 的專案不會 break)。但 save-back 一律寫 `[run].project`(別寫回 `[build]`)。

## 何時觸發 save-back

執行**成功後**,比對「**這次你實際選定的輸入**」vs「**已存記憶**」:

- **只比對你選的輸入**,不要比對 script 解析後的 MSBuild 有效值(模板報的是你的輸入,不是求值結果)。
- **你「省略」的 config 不算選擇,不要存**(省略 = 故意交 MSBuild/solution/props 決定,是對齊 VS 的預設;
  存下去反而把它變成每次硬帶 `/p:`,回不去 VS 對齊)。
- 若這次每個輸入都與已存記憶相同(或都同樣是省略)→ **不問、直接結束**。
- 若有任何一項不同(含「記憶原本是空、這次第一次選了值」、含「這次選的值剛好等於某個常見預設」——**嚴格版**,
  都要問)→ 進下面的詢問。

## 詢問:四去向(`AskUserQuestion`)

對「有差異的那幾項」一次問清楚要存哪裡。四個選項:

1. **存 committed(`.turbo-plugin/config.toml`)** — 進版控、跨同事/跨 worktree 共享。適合「這專案就是要建這個 csproj」這種團隊級的固定選擇。
2. **存 local(`.turbo-plugin/config.local.toml`,建議預設)** — 不進版控、只這台機器。適合個人習慣 / 暫時偏好。
3. **撤回成「省略」(刪掉該 key)** — 把先前存過的 config 值刪掉,讓該操作回到「不帶 `/p:`、交 MSBuild 決定」
   (對齊 VS)。只在「記憶裡原本有值、這次你想改回省略」時才出現。
4. **不存** — 這次就用、不記。

> 預設建議 **local**。target(`project`)這種專案結構事實,使用者常會選 committed;個人 config 偏好選 local。

## 寫進去之前:兩個必須先確保的前置

**這個 plugin 沒有 setup 指令**——需要什麼就在用到的時候自己建。所以存回之前先確保下面兩件事,
**每次都檢查**(已經就緒就跳過,不要重寫)。

### 前置 1 — 檔案與區塊(不要假設有人先建好)

依序確保:

1. **`.turbo-plugin/` 目錄**存在;不存在就建。
2. **要寫的那個檔**(`config.toml` 或 `config.local.toml`)存在;不存在就建立空檔。
   - `config.toml` 可以複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/config.toml` 當骨架
     (裡面已有 header 註解與空的標記區塊);`config.local.toml` 直接新建空檔即可。
3. **dotnet 標記區塊**存在;找不到 `# >>> turbo-plugin:dotnet >>>` … `# <<< turbo-plugin:dotnet <<<`
   就在**檔尾追加**一組(這兩行是 TOML 註解,reader 會略過)。
4. **要寫的 `[section]` header** 在該區塊**之內**存在;不存在就先補一行 `[build]` / `[run]` / `[publish]`。

### 前置 2 — 寫 `*.local.*` 之前先確保它被 ignore（不變式）

**要寫 `config.local.toml`(或任何 `*.local.*` 檔)之前**,先確認專案根 `.gitignore` 含這一行:

```
.turbo-plugin/**/*.local.*
```

缺就補上(idempotent,不要重複追加)。理由:`config.local.toml` 裝的是機器專屬路徑與個人偏好,
**進了版控就是把本機路徑推給同事**(而在 SVN 那側是永久的)。把它綁在「誰寫這種檔、誰負責先擋住」
比綁在某個 setup 指令可靠——後者只是「假設有人跑過」,前者是保證。

> 沒有 `.gitignore` 就建一個。這個專案若也裝了 `turbo-plugin-git-svn` 並跑過它的 `/tp-setup`,
> 這行通常已經在了,那就什麼都不用做。

## 怎麼寫:agent-Edit 讀-改-寫規則

存回用 **Read + Edit**(不要新增 TOML writer script)。規則:

1. **只動 dotnet marker 區塊內**(`# >>> turbo-plugin:dotnet >>>` … `# <<< turbo-plugin:dotnet <<<`);
   marker 外、其它 concern 的區塊一律不碰。
2. **key 一律落在對應 `[section]` header 之下、且在 marker 之內**(前置 1 已確保兩者都在)。
   - 找到既有 `[build]`(或 run/publish)→ 在它底下加 / 取代該 key。
   - 該 key 已存在 → 直接取代值。
   - 撤回省略 → 刪掉該 key 那一行(section header 留著)。
   - **絕不**把 `key = value` 寫在任何 `[section]` 之前(flat reader 會把 header 前的 key 綁到空 section、讀不到)。
3. **存 committed 時清掉 local 影子**:寫 `config.toml` 的某 key 前,先看 `config.local.toml` 有沒有同
   section 同 key 的值。有的話 local 會蓋 committed,寫了 committed 下次還是讀到 local 舊值(重問迴圈)——
   所以要一併刪掉 `config.local.toml` 裡那個 key(或明確告知使用者去清)。反向(存 local)不需動 committed。
4. **保留檔案編碼**:`config.toml` / `config.local.toml` 可能含中文註解;Edit 時維持原本的 BOM 狀態,別把
   有 BOM 的存成無 BOM(反之亦然)。

## 記憶是提示、不是權威

沿用記憶前先驗證它仍然有效:

- 存的 `project` / `default_pubxml` 指到的檔還在不在?不在(專案改結構 / profile 改名)→ 別硬用,
  重新判斷或詢問使用者,並順手把失效的記憶更新掉。
- 記憶有值即代表「明示選擇」,執行時要把它當這次的輸入附上 `/p:`(或當 target)、並在結果模板回報——
  使用者才看得到這次到底用了哪個。
