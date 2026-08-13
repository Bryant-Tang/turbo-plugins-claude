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
| `/tp-suggest-ignore` | 找出不該進版控的檔案並加進 `.gitignore`,也可把已不該追蹤的檔從 SVN un-track(SVN 移除委派 `Remove-SvnFile`,不裸 svn)。**哪些該排除由 agent 看專案實際內容判斷,不套固定 pattern 清單**(判準在 `skills/tp-suggest-ignore/assets/ignore-rubric.md`);`/tp-setup` 收尾會自動跑一次,`/tp-push-to-svn` 只在偵測到才出聲 |
| `/tp-commit-msg` | 撰寫 / 檢查 commit message 語意(祈使句、what+why;禁 SHA / 本地識別碼;不驗證 / 不限制 type) |

## 設定

- 需 git + SVN client(`svn` / `svnadmin` 在 PATH)。**SVN 需 1.9 以上**——腳本用 `svn info --show-item`,
  那是 1.9 才有的選項。版本不足時第一次呼叫 svn 就會直接說明原因與升級方式,不會讓你去猜
  `svn: invalid option: --show-item` 是什麼意思。
  > Windows 上請裝 SlikSVN 或 TortoiseSVN(勾 command line tools)。**chocolatey 的 `svn` 套件不行**:
  > 那是 win32svn,2015 年最後發佈、停在 1.8.15。
- `tp-setup` 會建立 `.turbo-plugin/` 並寫入 `config.toml`(+ `CLAUDE.md` base 區塊);machine-specific 偏好寫進 gitignored `config.local.toml`。
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
- 本 plugin 只管 `remote-svn-*` 橋接 worktree，**不建立 / 不碰**個人開發用的隔離 worktree（若你自行用 `git worktree add` 建 peer worktree，plugin 不干涉）。

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

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各 SVN 腳本、`lib` helper（Common 的 SVN concern + Core）、SessionStart hook 的行為測試；缺 `svn` / `svnadmin` 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
