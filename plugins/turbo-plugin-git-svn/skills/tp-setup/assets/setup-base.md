# tp-setup 共用 base 段（concern-neutral）

> 這份檔案是 **turbo-plugin 系列共用的 setup base 段**,被**有 setup 指令的** plugin(git-svn / db)的
> `tp-setup` SKILL 引用。各 plugin 的 SKILL 會「先跑本 base 段,再跑自己的 concern 段」。
> 這些 plugin 各帶一份**內容相同**的本檔(像 `Core.{ps1,sh}` 一樣 byte-identical);修改時每一份都要同步。
>
> `turbo-plugin-dotnet-framework` **沒有** setup 指令(所有設定都是用到才建),故不帶本檔。
>
> base 段**只**處理 concern-neutral 的共用檔骨架,**不**碰任何單一 concern 的設定
> (git bridge / IIS apphost / dbhub 等一律由各 plugin 的 concern 段處理)。
>
> 註:`conventions.md` 的「先讀慣例」機制**已退役**——各 skill 改靠自身 `description` 讓 agent 主動觸發,
> base 不再建立 `conventions.md`,setup 也不寫它。

## Pre-check（任一失敗就停下回報,不繼續）

1. 跑 `${CLAUDE_PLUGIN_ROOT}/scripts/lib/Core.ps1`(PowerShell)或 `core.sh`(Bash)的
   `Probe-GitVersion` / `probe_git_version`。Git < 2.31 → fail loudly 帶升級提示。
   - 若某 plugin 該語言的 Core 不存在(例如 dotnet 只有 `Core.ps1`、無 `core.sh`,其 `.sh` 走 ps1-delegate;
     dotnet 為 Windows-only,實務上 setup 走 PowerShell 用 `Core.ps1`),退化為跑 `git --version` 自行比對 ≥ 2.31。
2. 跑 `git rev-parse --show-superproject-working-tree`。非空 → 拒跑,提示「submodule 不在
   turbo-plugin 管理範圍內,請在 superproject root 設定」。

## Marker 慣例（各 plugin 只寫自己的標記區塊,彼此不覆蓋）

共用檔用標記區塊隔開各 concern 的內容。setup 寫入時**只**動自己 concern 的區塊:

| 檔案 | 標記語法 | concern 值 |
|---|---|---|
| `.turbo-plugin/config.toml` | `# >>> turbo-plugin:<concern> >>>` … `# <<< turbo-plugin:<concern> <<<`(TOML 註解,reader 會略過) | `git-svn` / `dotnet` |
| 專案根 `.gitignore` | 同上(`#` 註解,git 會略過) | `base` / `git-svn` |
| 專案根 `CLAUDE.md` | `<!-- turbo-plugin:begin base -->` … `<!-- turbo-plugin:end base -->`(只有單一 base 區塊) | `base` |

**更新自己區塊的通用程序**(idempotent):讀檔 → 若找到自己 concern 的 begin/end 標記 → 用新內容
**取代**該對標記之間的內容(標記本身保留);若找不到 → 在檔尾**追加**一組自己的 begin/end 標記
+ 內容。**絕不**動別的 concern 的標記區塊或標記外的內容。

**每個注入的區塊都必須自己講明這件事**(issue #68)。上面那條「整段取代」的語意原本只寫在這份
SKILL 文件裡,而打開 `CLAUDE.md` 的人看到的只有一對 HTML 註解——標記不會告訴你裡面的內容有覆寫
語意,更不會告訴你不該往裡面加東西。實際發生過:使用者依「主題相鄰」把一條新規範寫進區塊內,
當下完全正常,直到重跑 setup 才會被無聲刪掉(而那個工作區根不是 repo,沒有歷史可以撈回來)。

所以每份注入的 snippet(`claudemd-base-snippet.md`、各 plugin 的 workspace snippet)開頭都帶一段
自我說明,`config.toml` 殼的 header 註解也有對應的一段。**改 snippet 時不要把它拿掉**;它放在區塊
**內**是刻意的——會被覆寫,但每次重跑都會回來,永遠跟著 snippet 的最新版走,setup 也不必額外維護
標記外的狀態。

> **併發範圍**:標記合併只保證**循序** setup 不互相覆蓋(單一維護者假設)。兩個 session 同時對同一
> 專案根跑 setup 的 read-modify-write 競態屬 out of scope。

## Base 檔骨架（idempotent,以「個別檔案是否存在」判斷,不是只看目錄）

依序確保下列 concern-neutral 共用檔就緒。各 plugin 的 concern 段稍後在自己的標記區塊內填內容。

**兩種 idempotent 語意,不要混用**——選錯的那一種不會報錯,只會讓修正永遠到不了既有專案:

- **整檔層級(存在就跳過)**:`.turbo-plugin/`、`config.toml` 殼、`TODO.md`。這些檔一旦建立,
  內容就歸使用者,重跑不覆寫。
- **標記區塊層級(找到就取代、找不到就追加)**:`.gitignore` 的 `base` 區塊、`CLAUDE.md` 的 `base`
  區塊。這些是 plugin 持續維護的內容,**必須調和**。用「整塊已存在就跳過」處理它們正是 issue #65:
  既有專案重跑 setup 永遠拿不到後續新增的規則,而且沒有任何提示。

1. **`.turbo-plugin/` 目錄** — 不存在則建立。
2. **`.turbo-plugin/config.toml`** — 不存在則複製 `${CLAUDE_PLUGIN_ROOT}/default-files/.turbo-plugin/config.toml`
   (concern-neutral 殼:header 註解 + 空的 `git-svn` / `dotnet` 標記區塊);**已存在則不覆寫整檔**
   (concern 段稍後只更新自己的標記區塊)。
   - db plugin **不碰** config.toml(db 在 config.toml 沒有設定);db 的 base 段跳過此項。
3. **專案根 `.gitignore`** — 確保含 base 標記區塊,內容如下。**用上面「更新自己區塊的通用程序」處理**
   (找到 `base` 標記 → 取代之間的內容;找不到 → 檔尾追加一組),不要用「整塊已存在就跳過」:
   ```
   # >>> turbo-plugin:base >>>
   .claude/**/*.local.*
   .claude/worktrees/
   .turbo-plugin/**/*.local.*
   !*.example.local.*
   /TODO.md
   # <<< turbo-plugin:base <<<
   ```
   - **為什麼要標記**(issue #65):這塊原本只有一行 `# turbo-plugin` 開頭、沒有結束標記,規則又是整塊
     層級的「已存在不覆寫」,所以**既有專案重跑 setup 永遠拿不到後續新增的規則**。`.claude/worktrees/`
     那一行就是這樣:0.1.2 加了它,但只有新 setup 的專案吃得到,既有專案不會有任何提示,要等到某次
     `git add -A` 把整包 worktree 塞進版控才會發現。同一份檔案裡的 `CLAUDE.md` 區塊有標記、會調和,
     行為本來就不該不一致。
   - **既有專案的舊區塊:只追加,絕不刪。** 舊的那幾行沒有結束標記,而它後面**緊接著** git-svn concern
     追加的行、再接使用者自己的規則,中間沒有任何分隔——**判斷不出舊區塊到哪裡結束**,猜錯就會吃掉
     使用者自己的 ignore 規則,那是不可接受的。所以找不到標記時一律在**檔尾追加**一組帶標記的新區塊,
     舊的那幾行原封不動留著(git 對重複的 ignore 規則完全無所謂,只是看起來冗餘)。
   - 追加完之後,**若偵測到疑似舊區塊**(某行是 `# turbo-plugin`,且其後數行落在上面這份清單裡),
     用 `AskUserQuestion` 把**那幾行原文列出來**問使用者要不要順手刪掉,並講明「它們現在跟新區塊重複、
     刪掉不影響行為」。使用者沒有明確同意就不要動——寧可留著冗餘,也不要刪錯。
   - **`.claude/worktrees/` 是必要的,上面那條 `.claude/**/*.local.*` 擋不住它**:Claude Code 內建的
     worktree 功能預設把工作副本建在 `<repo>/.claude/worktrees/`,那底下是**一份完整的 checkout**
     (含 `node_modules` 與建置產物,動輒數百 MB),而裡面的檔案**不含 `.local.`**,所以完全不受上一條
     規則影響。少了這行有兩個後果:`git status` 永遠掛著一筆 `?? .claude/`,雜訊會蓋掉真正該注意的未
     追蹤檔;以及任何一次 `git add -A` 都可能把整包工作副本塞進版控——**在 SVN 那側是永久的**。
     以**目錄**形式忽略也順帶保證底下的東西不會被後面的 `!` 規則重新納入(git 不允許重新納入被排除
     目錄底下的檔案),這正是這裡要的。
   - **那條 `!` 放行是必要的,不是裝飾**:`*.example.local.*` 是刻意要進版控的**範本**(例如
     `dbhub.example.local.toml`),讓同事看得到該填哪些欄位。少了它,前一條規則會把範本一起擋掉,
     於是「附一份範本給同事」這件事永遠不會成立——而真正含密碼的 `dbhub.local.toml` 仍然被擋住,
     因為它不含 `.example.`。改動這三行時務必兩邊都驗:範本**不**被忽略、真檔**被**忽略。
   - git bridge 的 ignore 規則(`.turbo-plugin/worktrees/`、`.svn/`)不在 base:由 git-svn 的 concern 段
     寫進它自己的 `git-svn` 標記區塊,調和方式與這裡相同。
   - **專案自己的建置產物沒有寫死清單**:由 agent 依
     `turbo-plugin-git-svn` 的 `skills/tp-suggest-ignore/assets/ignore-rubric.md` 判斷後追加。
4. **專案根 `TODO.md`** — 不存在則建立下面的骨架;**已存在則完全不碰**(裡面是使用者的內容)。
   ```
   # TODO / 現況

   > 這個檔案**不進版控**,但**屬於交接內容**——換手時要一起交出去。
   > 放「只有現在成立、但接手的人需要知道」的東西:待辦、環境現況、本機分支關係、暫時的繞道。
   > 對任何時間 checkout 都成立的規範寫進 `CLAUDE.md` / `docs/`;只對這台機器成立、下一個人
   > 根本不需要的留在 agent 記憶。判準見 `CLAUDE.md` 的「這件事該寫在哪」。

   （尚無項目）
   ```
   - **為什麼需要這一格**(issue #70):「只有現在成立、不進版控、但要交接」是最容易放錯的一格。
     它不能進版控(會過期、會外洩本機資訊),但也**不能只放進 agent 記憶**——記憶不會交接,換人
     換機器就沒了。沒有一個看得見的預設落點,內容就會滑進 `CLAUDE.md`(於是過期)或記憶(於是
     交接時消失),而兩種都不會有任何東西提醒你。
   - **骨架自己講明定位**,理由同上面的 Marker 慣例:一個「不進版控卻要交接」的檔案很反直覺,
     不寫在檔案裡就等於沒人知道。
   - **`TODO.md` 已被 git 追蹤時,不要把 `/TODO.md` 加進 ignore、也不要動那個檔**:那代表這個專案
     刻意把它進版控,這裡的假設不成立。照實告訴使用者,讓他決定。

5. **專案根 `CLAUDE.md`** — 確保含 turbo-plugin base 區塊(目前內容:「不得提交僅限本機之物」硬規則,以及「這件事該寫在哪」的四格判準——上一項的 `TODO.md` 就是那張表第二列的落點,兩者少任何一半另一半都會缺一角)。注入內容(複製
   `${CLAUDE_PLUGIN_ROOT}/skills/tp-setup/assets/claudemd-base-snippet.md`)用 `<!-- turbo-plugin:begin base -->`
   / `<!-- turbo-plugin:end base -->` 標記包夾:不存在則建立含該 snippet 的檔;已存在則用標記
   idempotent 取代/追加,不影響其它段落。

## Base 段不做的事（交給各 plugin 的 concern 段）

- **git init / 預設分支 / 初始 commit / `remote-svn/main` bridge / 連接歷史 / `[svn]` 設定 /
  `.svn/` ignore** → **git-svn** concern。
- **`[iis]/[build]/[publish]/[frontend]/[run]` 設定 / `applicationhost.config` / MSBuild / IIS Express 路徑**
  → **dotnet** plugin,但它**沒有 setup 指令**:這些全部由要用到它們的那支 skill 在當下自己建。
- **`dbhub.example.local.toml` / `dbhub.local.toml` / `.mcp.json`(tp-dbhub)** → **db** concern。

## Case 偵測（供各 plugin concern 段使用,固定優先序）

```
if not exist .git:                → case (a) 新建（只有 git-svn 會 git init;dotnet/db 見各自 fail-loud 規則）
elif not Test-IsMainWorktree:     → case (d) peer-mode
elif not exist .turbo-plugin:     → case (b) init-from-existing
else:                             → case (c) 補設定
```

- **Phase summary + override**:進 case 前先**平實白話**報告偵測到的情境與即將執行的高階步驟,並用
  `AskUserQuestion` 讓使用者「照偵測到的情境執行 / 改用其他情境 / 取消」。**對使用者一律用白話描述情境,
  不要把「case (a)/(b)/(c)/(d)」這類內部代號丟給使用者**(使用者不知道那是什麼);各情境的白話說法
  (concern-neutral,各 plugin concern 段可再補自己 concern 的具體動作):
  - 偵測 (a) → 「這看起來是全新的專案資料夾(還沒有版本控制)——將為它建立版控並完成首次設定」
  - 偵測 (b) → 「這是既有的 git 專案、但還沒被 turbo-plugin 設定過——將接管並補上設定」
  - 偵測 (c) → 「這個專案先前已設定過——將補齊 / 更新本機設定」
  - 偵測 (d) → 「這是附屬的工作目錄(peer worktree)——只確認設定已就緒」
  選項標籤與「即將執行」描述都用上述白話(「偵測 (X)」只是給 agent 對照、不要照唸代號)。**只列「會動到外部」**
  的 unconditional 動作(如 `svn checkout` 從伺服器抓內容);純 repo-only 的本地檔寫入 / git 本地 op 不列。
