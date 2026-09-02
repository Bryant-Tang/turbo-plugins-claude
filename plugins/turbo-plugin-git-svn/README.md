# turbo-plugin-git-svn

git↔SVN bridge 本機開發工具集（setup + SVN bridge）。turbo-plugins-claude marketplace 的獨立 plugin。

env-free 設計,集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

| Skill | 用途 |
|---|---|
| `/tp-setup` | 設定入口(四 case:新建 / 接管現有 git+SVN / 主 worktree 補設定 / peer-mode) |
| `/tp-pull-from-svn` | 從 SVN 拉更新到 `remote-svn/main` 並 merge 進工作分支 |
| `/tp-push-to-svn` | 將工作分支推送上 SVN(首推自動建 bridge;body 由腳本鎖定為範圍內所有非-merge commit subject、agent 只寫 title) |
| `/tp-checkout-svn-branch` | 把**既有** SVN 分支**唯讀**匯入成 bridge + 已填內容工作分支(對 SVN 端零寫入;日後走 `/tp-pull-from-svn` 同步) |
| `/tp-svn-log` | 在 `remote-svn-*` worktree 跑 SVN log(中文安全 + 互動分頁) |
| `/tp-merge-main-into-branches` | 把最新 main merge 進指定(預設全部非 remote-svn)本地分支 |
| `/tp-request-merge` | **沒有 git remote 時的 PR 等價物**:報告某條工作分支會併進 main 的內容(commit / diffstat / 領先落後),使用者確認後由腳本在主 worktree `git merge --no-ff`。合併完成後 `ExitWorktree` 的 `remove` 才安全 |
| `/tp-suggest-ignore` | 找出不該進版控的檔案並加進 `.gitignore`,也可把已不該追蹤的檔從 SVN un-track(SVN 移除委派 `Remove-SvnFile`,不裸 svn)。**哪些該排除由 agent 看專案實際內容判斷,不套固定 pattern 清單**(判準在 `skills/tp-suggest-ignore/assets/ignore-rubric.md`);`/tp-setup` 收尾會自動跑一次,`/tp-push-to-svn` 只在偵測到才出聲 |
| `/tp-commit-msg` | 撰寫 / 檢查 commit message 語意(祈使句、what+why;禁 SHA / 本地識別碼;不驗證 / 不限制 type) |

## 設定

- 需 git + SVN client(`svn` / `svnadmin` 在 PATH)。**SVN 需 1.9 以上**——腳本用 `svn info --show-item`,
  那是 1.9 才有的選項。版本不足時第一次呼叫 svn 就會直接說明原因與升級方式,不會讓你去猜
  `svn: invalid option: --show-item` 是什麼意思。
  > Windows 上請裝 SlikSVN 或 TortoiseSVN(勾 command line tools)。**chocolatey 的 `svn` 套件不行**:
  > 那是 win32svn,2015 年最後發佈、停在 1.8.15。
- `tp-setup` 會建立 `.turbo-plugin/` 並寫入 `config.toml`(+ `CLAUDE.md` base 區塊 + `.gitignore` base 區塊);machine-specific 偏好寫進 gitignored `config.local.toml`。
  - **注入的區塊用 `# >>> turbo-plugin:<concern> >>>` / `<!-- turbo-plugin:begin ... -->` 標記包夾,重跑 setup 會把標記之間的內容整段換掉。** 不要往裡面加自己的東西(區塊開頭也會這樣寫給你看);要加規範就寫在標記外面。
  - **`CLAUDE.md` base 區塊只留「不得提交僅限本機之物」這條硬規則。** 「這件事該寫在哪」的判準與 `TODO.md` 骨架已經移出去,由獨立的 [`turbo-plugin-knowledge-placement`](../turbo-plugin-knowledge-placement/README.md) 維護自己的標記區塊——這裡只留**結構**,不留**主張**:用了 git↔SVN 橋接不代表就得接受某一套文件方法。要那套判準就自己裝那個 plugin(沒有任何 plugin 相依它)。
  - **既有專案重跑 setup 會有一個有後果的變化**:base ignore 區塊不再含 `/TODO.md`,所以原本被忽略的 `TODO.md` 從此會出現在 `git status` 裡。`tp-setup` 偵測到這種情況會明講,並讓你選擇「自己在標記外加一行 ignore」或「把內容搬進記憶、交接時用 `/tp-export-handover` 匯出」。**它不會替你決定,也不會默默把那一行留著。**
- case (a)(新建)/(b)(接管現有 git+SVN)的 git↔SVN bridge bootstrap 由固定腳本 `Initialize-GitSvnBridge`(`.ps1` / `.sh`)承接(空 main 先行 → orphan bridge + `svn checkout` → 固定 `svn:ignore=.git` → `git merge --allow-unrelated-histories` 進當前分支),agent 只留收 SVN URL / 收 git 身分 / 確認;base 骨架在腳本成功後才疊上。

## 安裝

```
/plugin marketplace add <owner>/turbo-plugins-claude
/plugin install turbo-plugin-git-svn@turbo-plugins-claude
```

## Worktree 模型（git ↔ SVN 橋接）

`turbo-plugin-git-svn` 透過多個 git worktree 把 SVN 橋接職責拆開，全部收進主 worktree 內的 `.turbo-plugin/worktrees/`（整個 gitignored，於首次 `git worktree add` 前就先寫入 ignore 規則）：

```
<proj>/                                      ← main worktree（main / 工作分支切換）
└─ .turbo-plugin/
    └─ worktrees/                            ← gitignored 整個
        ├─ remote-svn-main/                  ← branch: remote-svn/main，SVN trunk 同步用
        └─ remote-svn-<branch>/              ← branch: remote-svn/<branch>，任意工作分支的 SVN bridge
```

- 目錄名（`remote-svn-main` / `remote-svn-<branch>`）與 branch ref（`remote-svn/main` / `remote-svn/<branch>`）兩維度一致，集中由 `Resolve-RemoteWorktree` / `resolve_remote_worktree`（`scripts/lib/`）解析；worktree 容器路徑由 `Get-WorktreesDir` / `get_worktrees_dir` helper 統一定義。工作分支名中的斜線（如 `feat/login`）在目錄名會轉成 dash（`remote-svn-feat-login`），branch ref 則保留斜線（`remote-svn/feat/login`）。
- `remote-svn-*` worktree 是 git/SVN 橋樑，通常不直接編輯。
- 在任一 worktree 開的 Claude session 都能呼叫指令——script 會自動定位主 worktree。
- 本 plugin 只管 `remote-svn-*` 橋接 worktree，**不建立 / 不碰**個人開發用的隔離 worktree（若你自行用 `git worktree add` 建 peer worktree，plugin 不干涉）。這條沒有變：`/tp-request-merge` 會**合併**在隔離 worktree 上開發出來的分支，但仍然不建立、不刪除任何 worktree。

## 沒有 git remote，就沒有「人按 Merge」那一關（`/tp-request-merge`）

本 plugin 服務的是**純本地 git ↔ SVN** 的專案：沒有 git 遠端，因此開不了 PR。平常不覺得少什麼，直到要收掉一個隔離工作副本的時候。

`ExitWorktree` 的 `remove` 會**連分支一起刪**，這隱含一個前提：走到這一步時分支已經被合併掉了。在有遠端的專案，那個前提由 PR 流程保證（開 PR → CI → 人手動按 Merge → 分支才被刪）。沒有遠端就沒有這條流程，而**沒有任何東西補上那一關**。結果是在「工作順利完成」這條最正常的路徑上，`remove` 兩條路都不可接受——不帶 `discard_changes` 會被拒（保護機制正確運作），帶了會毀掉還沒合併的成果。只能退回 `keep`，然後手動 merge、手動清理。

`/tp-request-merge` 補上那一關：

```
agent 完成工作、全部 commit
  → /tp-request-merge --branch <b>        報告：commit 清單 / diffstat / 領先落後
  → 使用者確認
  → 腳本在主 worktree 跑 git merge --no-ff
  → 這時 ExitWorktree 的 remove 才安全（分支已併入，刪掉不會掉東西）
```

幾個刻意的決定：

- **報告與合併是同一支腳本的兩個模式**（`--merge` 才動手），不是兩支腳本。`--merge` 會**重跑全部守門**，所以使用者看到的那道關卡與放行合併的那道關卡是同一段程式碼，不會漂移；使用者思考期間狀態變了也會被擋下來，而不是拿舊報告放行。
- **`SOURCE_DIRTY` 是這裡最重要的守門**。分支所在的 worktree 若有未 commit 的變更，那些變更不在這次合併裡，而接下來的 `remove` 會把它們刪掉——這是整條路徑上唯一會**無聲掉東西**的地方，所以腳本一律拒跑。
- **`remote-svn/*` 兩端都不碰。** 它出現在**目標**那端是「把工作併進橋接分支」，會污染要 commit 回 SVN 的樹（`/tp-merge-main-into-branches` 排除它也是同一個理由）；出現在**來源**那端則是 `/tp-pull-from-svn` 的工作——那支會連同修訂簿記一起維護，本 skill 只會產生一顆一樣的 merge commit 卻不更新任何狀態。兩種都直接擋下，而且是**按名字**擋，所以橋接分支還沒建起來時答案也一樣。
- **衝突永遠 `merge --abort`**，`<base>` 與開跑前完全一樣、不留衝突樹。建議先用 `/tp-merge-main-into-branches` 把 main 併進分支、在**分支上**解衝突。
- **沒有 CI 就不假裝有**。腳本只報客觀事實（commit、diffstat、乾不乾淨），不做驗收把關，也不要求 agent 交出結構化的「測試通過」宣告——那只會變成一句沒人驗證的自我宣稱。判斷這批東西能不能進 main 的是使用者。
- **不串 SVN**。併進 main 之後要不要 `/tp-push-to-svn` 是另一個明確決定，而且 SVN 寫入是永久的。

它和 `/tp-merge-main-into-branches` 是一對：那支是下行（main → 分支），這支是上行（分支 → main）。兩支都用 `Get-MainWorktree` 自行定位，所以**在 linked worktree 裡呼叫，操作仍落在主 worktree**。

## 要對哪個 repo 動手（`--repo-root`）

每支入口腳本都收一個可選的 `-RepoRoot <path>`（`.ps1`）／ `--repo-root <path>`（`.sh`）。

- **不傳**（預設）：腳本從當前目錄往上找 repo，再定位到它的主 worktree。單一專案的 session 裡這就是答案，行為與這個參數存在之前完全相同。
- **傳**：直接指名要動的 repo，不必先 `cd`。路徑接受 Git Bash 形式（`/c/Users/...`），不存在或不是目錄時腳本直接報 `repo root not found`、不會走到 git，也不會建立任何東西。

什麼時候該傳、agent 該怎麼判斷，寫在 **`assets/repo-target.md`**（跨七支 SKILL 共用的判準，只有這一份）。摘要：

- 當前目錄自己不是 repo、但底下並排著多個獨立 repo（多專案工作區的形狀）→ **必須指名**。不指名的話每支指令都會倒在 `not inside a git repository`。
- 會寫入的指令（`tp-setup` / `tp-push-to-svn` / `tp-pull-from-svn` / `tp-suggest-ignore` 的 SVN 移除）在動手前的確認裡會**先寫出要動的專案絕對路徑**。這道不是守門能取代的：當前目錄**是**一個合法 repo、只是不是使用者想的那個時，`tp-setup` 的三道守門一個都不會響。

指名不會放寬任何守門——三道守門判的都是**指名的那個目標**：指到 linked worktree 一樣被拒，指到並排工作區一樣被拒。

## `.git` 不進 SVN 的機制

bridge 建立時靠 `svn rm --keep-local .git`（修正 `svn checkout` 副作用）+ 固定 `svn:ignore=.git` 來確保 `.git` 不被推進 SVN——首個 bridge（`tp-setup` case (a)/(b)）由 `Initialize-GitSvnBridge` / `initialize-git-svn-bridge.sh` 做、後續工作分支的 bridge 由 `New-RemoteBridge` / `Checkout-SvnBranch` 做。其餘該排除的檔一律由 `.gitignore` + push 腳本的 `git check-ignore` 決定（bridge 的 add-set = `svn status` 的 `?` 減去 git-ignored），讓 remote-svn 用起來更接近 remote git。

## SVN 路徑被改名時（`svn move` 過的資料夾）

企業 SVN 常有重整目錄、專案搬家、根資料夾改名這類事，而且改的是**上層資料夾**時，使用者根本不會意識到自己的專案路徑「變過」。

- **匯入歷史時跨改名（`tp-setup` 首次建 bridge）**：自動處理。歷史列舉是對「你給的 URL 加上明確 peg」下的，逐筆重放遇到改名邊界會 `svn switch` 跟過去，所以**逐筆歷史完整保留**，不需要退而求其次壓成一顆。偵測到時會回報一次，agent 會用白話告訴你資料夾改過名——因為你會在歷史裡看到路徑變動。
- **bridge 建好之後才被改名**：無法自動修復，會 fail loudly 並要你對新 URL 重跑 `/tp-setup`。原因是 SVN 只能從**現存**路徑往回追歷史，不能從已被刪除的舊路徑往前追（`svn info -r HEAD <舊URL>@<舊rev>` 直接 E160013），所以 bridge 沒有任何辦法自己查出新名字。

> 粒度參數（逐筆 / 壓成一顆 / 挑一段）**一律生效**。修訂數多寡只決定「要不要主動問你」，不決定「聽不聽你的」。

## 推送的規模與檔名限制

- **檔案數不受命令列長度限制**：推送走 svn 的 `--targets` 檔案清單，所以把既有專案首次匯入 SVN（動輒幾千個檔）不會再撞到 `Argument list too long`。
- **檔名含 `@` 沒問題**：`banner@2x.jpg` 這種 retina 命名會自動處理掉 svn 的 peg revision 語法。
- **檔名字元仍受系統字碼頁限制**：Windows 上路徑是透過系統 ANSI 字碼頁傳給 svn 的，所以檔名若用到你這台機器字碼頁裝不下的文字（例如繁中 cp950 系統上的日文假名、emoji），推送會**明確失敗並說明原因**，而不是送出壞掉的檔名。要用這類檔名請依 `/tp-setup` 的編碼說明改用 PowerShell 7+ 或開啟 Windows 的 UTF-8 設定。

## 印給人看的 git 輸出會關掉 `core.quotePath`

git 的 `core.quotePath` **預設是 `true`**，會把檔名裡的非 ASCII 逐 byte 轉成 `\ooo`。所以一份衝突清單
在中文檔名下長這樣：

```
"docs/\347\231\274\344\275\210\350\252\252\346\230\216.md"
```

資訊沒遺失，但要人腦解碼。更糟的是 escape 後長度約是原字串的 **4 倍**，會把 `git diff --stat` 的欄寬
撐爆而觸發截斷——而截斷位置常常**切在一個 `\ooo` 的中間**，連「拿去解碼」這條退路都沒了。

所以**輸出要給人看的 git 呼叫都帶 `-c core.quotePath=false`**（衝突檔案清單、`tp-request-merge` 的
diffstat、bridge 的差異清單，以及 SKILL 裡那幾條「Source:」指令）。它是**單次呼叫層級**的，不寫入任何
設定檔，**不改變使用者 repo 或全域的 git 設定**——換一台機器、換一個使用者，行為都一樣。

> 這跟 issue #79 是**不同的兩件事**，只是症狀都叫「檔名看不懂」。#79 是 **svn** 用系統字碼頁編它的
> 人類可讀輸出（資訊真的遺失，變成 `?`）；這裡是 **git** 主動 escape（資訊還在）。修法也不同。

**界線：給機器解析的輸出不要加。** `--porcelain` 的跳脫是**格式的一部分**——含空白或換行的檔名靠它
消歧義，關掉會讓解析變得不安全。目前那幾處只判斷「空不空」，關掉無妨；真的要解析內容時，正確做法是
`--porcelain -z`，不是關 quotePath。`tools`/測試裡的 `git status --porcelain`、以及不含檔名的
`git log --oneline` 都**刻意沒有加**。

`tests/unit/scripts/quote-path.test.sh` 守著這條規則：新增的衝突清單 / diffstat 呼叫漏了旗標會紅。

## SVN commit body 的組裝（`tp-push-to-svn`）

`tp-push-to-svn` 組裝 SVN commit body 時,收錄推送範圍內**所有非-merge commit 的 subject**,**不依 conventional-commit type 過濾**——`feat` / `fix` / `refactor` / `docs` / `db` / `chore` 等各型 subject 都會進 SVN body。唯一被排除的是 **merge commit**（`Merge ...`;且範圍內若全是 merge commit、沒有任何 code-level subject 可記,腳本會 hard-stop 提示先補一個非-merge commit）。body 由腳本鎖定、agent 只寫 title。

## Hooks

`turbo-plugin-git-svn` 自帶兩個 hook,安裝即生效:

- **`SessionStart`**:每次 Claude session 啟動時觸發,依以下順序檢查:
  1. 非 git repo / submodule 內 → silent exit
  2. `.turbo-plugin/` marker 存在 → silent 通過（dbhub / IIS 的執行期檢查屬 sibling plugin）
  3. marker 不存在 → 提示主 worktree 路徑(若在 peer)或「請執行 `/tp-setup`」(若在主 worktree)

- **`PreToolUse`(matcher `Bash`)**:偵測到即將執行 `git commit` 時,提示先套用 `tp-commit-msg`,
  並附上核對該 repo 既有 type 慣例的指令。`git -C <path> commit`、`git -c k=v commit`、
  `git commit -F -` 加 heredoc 都攔得到;`--no-edit`(沒有在寫訊息)與其它 git 子指令則安靜通過。

  存在的理由是 `tp-commit-msg` 標了 proactive 卻**沒有任何機制保證它被載入**——agent 可以直接
  `git commit` 而整份規範靜默落空,且不會有任何訊號。那個失效發生在「agent 意識到需要查」之前,
  所以記憶或 CLAUDE.md 這類「要先被讀到才有效」的手段救不了它。

**兩個 hook 都是 advisory**:不會 block session、不會擋下指令,也**不會代為授予權限**(不回
`permissionDecision`,所以你原本的權限設定完全不受影響)。

> hook 在 Claude Code **session 啟動時載入**。剛安裝或剛更新 plugin 的話,要重開一次 session 才會生效。

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-dotnet-framework`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊（`tp-setup` 目前隨本 plugin 一起發佈）。

**相依 `turbo-plugin-feedback`**（安裝時自動一起裝上，不必自己裝）：它只有一個 skill `/tp-report-issue`，
用途是把你遇到的 turbo-plugin bug 或沉默失敗整理成 issue 送出，含**送進 public repo 前的消毒規則**。
相依宣告不帶版本約束，理由見 `turbo-plugin-feedback/README.md`。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各 SVN 腳本、`lib` helper（Common 的 SVN concern + Core）、SessionStart hook 的行為測試；缺 `svn` / `svnadmin` 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
