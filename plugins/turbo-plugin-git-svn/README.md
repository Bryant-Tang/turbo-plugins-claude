# turbo-plugin-git-svn

git↔SVN bridge 本機開發工具集（setup + SVN bridge）。是單體 `turbo-plugin`（v0.6.0）拆出的四個獨立 plugin 之一,以 `git mv` 保留 git lineage。

env-free 設計,集中設定於專案根的 `.turbo-plugin/`（與其它 turbo-plugin 共用）。

## Skills

| Skill | 用途 |
|---|---|
| `/tp-setup` | 設定入口(四 case:新建 / 接管現有 git+SVN / 主 worktree 補設定 / peer-mode) |
| `/tp-pull-from-svn` | 從 SVN 拉更新到 `remote-svn/main` 並 merge 進工作分支 |
| `/tp-push-to-svn` | 將工作分支推送上 SVN(首推自動建 bridge;body 由腳本鎖定為範圍內所有非-merge commit subject、agent 只寫 title) |
| `/tp-checkout-svn-branch` | 把**既有** SVN 分支**唯讀**匯入成 bridge + 已填內容工作分支(對 SVN 端零寫入;日後走 `/tp-pull-from-svn` 同步) |
| `/tp-svn-log` | 在 `remote-svn-*` worktree 跑 SVN log(中文安全 + 互動分頁) |
| `/tp-reset-branch-to-main` | 把指定分支 `git reset --hard` 成 main 內容 |
| `/tp-merge-main-into-branches` | 把最新 main merge 進指定(預設全部非 remote-svn)本地分支 |
| `/tp-suggest-ignore` | 偵測 untracked 檔案建議加入 `.gitignore`,並可把已不該追蹤的檔從 SVN un-track |
| `/tp-commit-msg` | 撰寫 / 檢查 commit message 語意(type 依 commitlint;禁 SHA / 本地識別碼) |

## 設定

- 需 git + SVN client(`svn` / `svnadmin` 在 PATH)。
- `tp-setup` 會建立 `.turbo-plugin/` 並寫入 `config.toml`(+ `.commitlintrc.json`、`CLAUDE.md` base 區塊);machine-specific 偏好寫進 gitignored `config.local.toml`。

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

## `.git` 不進 SVN 的機制

bridge 靠 `New-RemoteBridge` 建立時的 `svn rm --keep-local .git`（修正 `svn checkout --force` 的副作用）+ 固定 `svn:ignore=.git` 來確保 `.git` 不被推進 SVN。其餘該排除的檔一律由 `.gitignore` + push 腳本的 `git check-ignore` 決定（bridge 的 add-set = `svn status` 的 `?` 減去 git-ignored），讓 remote-svn 用起來更接近 remote git。

## SVN commit body 的組裝（`tp-push-to-svn`）

`tp-push-to-svn` 組裝 SVN commit body 時,收錄推送範圍內**所有非-merge commit 的 subject**,**不依 conventional-commit type 過濾**——`feat` / `fix` / `refactor` / `docs` / `db` / `chore` 等各型 subject 都會進 SVN body。唯一被排除的是 **merge commit**（`Merge ...`;且範圍內若全是 merge commit、沒有任何 code-level subject 可記,腳本會 hard-stop 提示先補一個非-merge commit）。body 由腳本鎖定、agent 只寫 title。

## Hooks

`turbo-plugin-git-svn` 自帶一個 hook,安裝即生效:

- **`SessionStart`**:每次 Claude session 啟動時觸發,依以下順序檢查:
  1. 非 git repo / submodule 內 → silent exit
  2. `.turbo-plugin/` marker 存在 → silent 通過（dbhub / IIS 的執行期檢查屬 sibling plugin）
  3. marker 不存在 → 提示主 worktree 路徑(若在 peer)或「請執行 `/tp-setup`」(若在主 worktree)

hook 是 advisory 不會 block session。

## 與其它 turbo-plugin 的關係

與 `turbo-plugin-dotnet-framework-web`、`turbo-plugin-three-environment-db`、`turbo-plugin-code-comment` 三者正交、各自獨立安裝。只需要哪塊就裝哪塊（`tp-setup` 目前隨本 plugin 一起發佈）。

## 測試

自動化測試套件（慣例佈局，CI 自動探索，新增此 plugin 零改 workflow）：

- `tests/Invoke-ScriptTests.ps1`（Windows PowerShell 5.1）/ `tests/invoke-script-tests.sh`（bash）。
- 各 SVN 腳本、`lib` helper（Common 的 SVN concern + Core）、SessionStart hook 的行為測試；缺 `svn` / `svnadmin` 的 runner 上對應測試自我 SKIP（CI 視為綠）。

## License

MIT — 見 [LICENSE](LICENSE)。
