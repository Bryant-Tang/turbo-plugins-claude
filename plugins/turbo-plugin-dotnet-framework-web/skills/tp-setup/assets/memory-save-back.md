# 記憶存回（save-back）共用片段

> **這份檔案是 turbo-plugin-dotnet-framework-web 的共用片段**,被 `tp-build` / `tp-publish` /
> `tp-run` 的 SKILL 以「**讀並遵循**」方式引用(比照 `tp-setup` 讀 `setup-base.md` 的 read-the-file
> 慣例),路徑 `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/memory-save-back.md`。
> 與 concern-neutral 的 `setup-base.md` 不同,**本檔是 dotnet-specific**(只談 build/run/publish 的
> 目標 / config / pubxml 記憶)。改這份只影響 dotnet,不必同步到其它 plugin。
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

## 怎麼寫:agent-Edit 讀-改-寫規則

存回用 **Read + Edit**(不要新增 TOML writer script)。規則:

1. **只動 dotnet marker 區塊內**(`# >>> turbo-plugin:dotnet >>>` … `# <<< turbo-plugin:dotnet <<<`);
   marker 外、其它 concern 的區塊一律不碰。
2. **key 一律落在對應 `[section]` header 之下、且在 marker 之內**。tp-setup 已 seed `[build]` /
   `[run]` / `[publish]` 三個(啟用但空的)section header,所以正常情況是「就地在既有 section 下填 key」。
   - 找到既有 `[build]`(或 run/publish)→ 在它底下加 / 取代該 key。
   - 該 key 已存在 → 直接取代值。
   - 撤回省略 → 刪掉該 key 那一行(section header 留著)。
   - **冷啟動例外**:若 marker 內真的找不到該 section header(被刪了),先補一行 `[section]` 再填 key——
     **絕不**把 `key = value` 寫在任何 `[section]` 之前(flat reader 會把 header 前的 key 綁到空 section、讀不到)。
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
