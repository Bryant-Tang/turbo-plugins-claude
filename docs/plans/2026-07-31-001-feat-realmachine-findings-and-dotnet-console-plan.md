---
title: 實機驗證發現修正 + dotnet plugin 改名與 console 支援 - Plan
type: feat
date: 2026-07-31
planned: 2026-07-31
topic: realmachine-findings-and-dotnet-console
artifact_contract: ce-unified-plan/v1
artifact_readiness: implementation-ready
product_contract_source: real-machine-verification
execution: code
---

# 實機驗證發現修正 + dotnet plugin 改名與 console 支援 - Plan

## Goal Capsule

- **Objective**: 收掉 2026-07-31 實機驗證找出的 14 個問題，並完成兩項使用者指定的改動：dotnet plugin 改名、console 專案支援。
- **Product authority**: plugin owner。
- **Open blockers**: 一項（D1，DB 的 MCP 在多專案工作區怎麼定位專案）。它只擋 U10；其餘 12 個 unit 都可以先做。

---

## 來源與證據

這批項目**不是**靜態審查推導出來的，除了三項標「分析」的以外，全部來自 2026-07-31 的實機驗證：一個
多專案工作區（三個並排的獨立 git repo，共用同一個 SVN 版本庫），跑完 setup / push / pull / svn-log /
分支匯入 / 建置 / 執行 / 停止 / 發佈 / 孤兒清理 / DB 設定，共 18 支 skill 中的 15 支。

每一項都附了觀察到的具體症狀。修的時候請以症狀為準——如果改完症狀沒消失，那就是修錯地方了。

---

## 已定決策

- **D2（#5 的範圍）** — SVN 路徑不存在時，**要問使用者要不要幫忙建**，而且**要一併問要不要建
  `trunk` / `branches` / `tags` 標準結構**。（使用者 2026-07-31 定案。）
- **D3（#12 的預設）** — `tp-db-management` 在沒有資料庫連線時，**預設先產出腳本並標註假設**，不要
  停下來問。理由：repo 裡就有 `db/*.sql`，表結構是現成的；這支 skill 的定位是「SQL 腳本撰寫」，
  停下來等連線會讓它在最常見的情境下不可用。仍要在輸出裡明講「未經實際資料庫驗證」。
- **D4（console 的形狀）** — **既有 skill 依專案型別分流**，不新增 console 專屬 skill。理由：使用者
  的心智模型是「這個專案」不是「這是 web 還是 console」；實測已證明 agent 從 csproj 的 `OutputType`
  判斷型別很可靠；新增一組會讓「跑起來」同時命中兩支 skill。
- **D5（console 的深度）** — **對齊 VS**。VS 對 .NET Framework console 的行為是：建置＝與 web 相同的
  MSBuild；執行＝跑 exe，參數與工作目錄存在機器本機的 `.csproj.user`；停止＝只在附加偵錯器時有意義，
  Ctrl+F5 跑的那個 VS 根本不追蹤；發佈＝**沒有這個概念**（右鍵 Publish 是 ClickOnce，與 web 的 Publish
  是兩回事）。因此：**不為 console 做孤兒清理**（超出 VS），**不做 console publish**（VS 沒有）。
- **D6（description 語言）** — description 改英文、body 維持繁中。分界理由：description 是唯一會被
  **前載**的部分，body 要用到才載；前者是給機器做路由的中繼資料，後者是給 agent 讀的作業說明。

## 待定決策

- **D1（#14）— DB 的 MCP 在多專案工作區怎麼定位設定檔？** 目前 `.mcp.json` 用
  `${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml`，而在多專案工作區裡 `CLAUDE_PROJECT_DIR` 是
  **工作區根**，不是任何一個專案 → 永遠找不到設定。三個方向：
  1. **包裝腳本自己找**（本計畫的預設提案）：`command` 改成 plugin 自己的腳本，由它往下找哪個子專案
     有 `dbhub.local.toml`。多個都有時的行為要定（取第一個？拒絕並要求指名？）
  2. **接受不相容並明講**：README 寫明「DB plugin 需要 session 開在專案內」，setup 偵測到多專案工作區
     就直說。工作量最小，但等於放棄一個組合。
  3. **工作區根放一份**：讓工作區根也能有 `.turbo-plugin/dbhub.local.toml`，明確指向要用的那個資料庫。
     簡單，但與「每個專案有自己的資料庫」的前提相衝。

  U10 開工前要定案。**#13（Docker 建空資料夾）在三個方向下都是同一個修法**（見 U10），所以那半邊不受阻塞。

---

## Implementation Units

> **順序硬性要求**：U1 必須最先做。它之後的每個碰 dotnet 的 unit（U7 / U8 / U11 / U13）都會用到新路徑，
> 順序顛倒等於每個檔案改兩次。U13 必須最後做（U11 會新增 / 改寫描述）。其餘 unit 彼此獨立，可任意順序。

### U1. dotnet plugin 改名（#15）

- **Goal**: `turbo-plugin-dotnet-framework-web` → `turbo-plugin-dotnet-framework`，讓名稱不再排除 console。
- **Dependencies**: 無。**必須第一個做。**
- **時機依據**: 目前 repo **0 個 tag、尚未發過版**。plugin 名稱是 load-bearing 的——release-please 的 tag
  是 `<plugin>--v<version>`，Claude Code 解析相依時就靠這個前綴篩 tag。現在改等於零成本；發版之後改，
  舊 tag 會留在舊 namespace、使用者要移除重裝、帶版本約束的相依會斷。
- **Files**:
  - `plugins/turbo-plugin-dotnet-framework-web/` → `plugins/turbo-plugin-dotnet-framework/`（`git mv`，保留歷史）
  - 該目錄內 28 個提到舊名的檔案（含 `.claude-plugin/plugin.json` 的 `name`、README、CHANGELOG、
    skills、tests fixture）
  - `.claude-plugin/marketplace.json`（`name` + `source`）
  - `release-please-config.json`（`packages` key + `component` + `extra-files`）
  - `.release-please-manifest.json`（key 改名，值維持 `0.1.0`）
  - `.github/workflows/release-please.yml`（註解裡的四個基準 tag 名）
  - `tools/verify-core-identical.sh` / `.ps1`（`shared_specs` 內的 plugin 名）
  - `README.md`（安裝章節）
  - `plugins/turbo-plugin-git-svn/README.md`、`skills/tp-setup/SKILL.md`、
    `skills/tp-setup/assets/setup-base.md`
  - `plugins/turbo-plugin-three-environment-db/README.md`、`skills/tp-setup/SKILL.md`、
    `skills/tp-setup/assets/setup-base.md`
  - `plugins/turbo-plugin-code-comment/README.md`
  - `plugins/turbo-plugin-git-svn/tests/fixtures/base/`（`.turbo-plugin/config.toml`、`README.md`）
- **Approach**:
  - **`skill` 名稱不改**（`tp-build-dotnet-framework-web` 等維持原樣）。使用者實際打的是 skill 名，
    改它的衝擊比改 plugin 名大得多；U11 讓它們支援 console 之後再視情況處理。
  - `setup-base.md` 是**跨 plugin 位元組必須相同**的共用檔（釘在 `verify-core-identical` 的
    `shared_specs`）——兩份都要改，改完跑一次檢查。
  - release-please：因為還沒發過版，等於「舊 component 消失、新 component 從 `0.1.0` 起算」，
    manifest 直接改 key 即可，不需要遷移任何東西。
- **Test scenarios**:
  - `tools/verify-core-identical.sh` 與 `.ps1` 全綠（`shared_specs` 指得到新路徑）。
  - `plugins/turbo-plugin-dotnet-framework/tests/Invoke-ScriptTests.ps1` 與 `invoke-script-tests.sh` 全綠。
  - 全 repo grep `turbo-plugin-dotnet-framework-web` 只剩 `docs/brainstorms/`、`docs/plans/` 的歷史文件
    （決策artifact，不改）與各 plugin 的 `CHANGELOG.md` 舊條目。
- **Verification**: `git log --follow` 在改名後的檔案上仍看得到歷史；CI 的 plugin 探索抓到新目錄。

---

### U2. 建分支的橋不再污染換行（#1）

- **Goal**: 讓 `new-remote-bridge` 建出來的 bridge 工作副本與 SVN 一致，不要一建好就整棵樹 dirty。
- **Dependencies**: 無。
- **症狀（實測）**: 在新分支上只改了 `README.md` 一行，準備推送時異動清單出現 **11 個檔案整檔改寫**。
  查下去是換行：`core.autocrlf` 在 Git for Windows 是**系統層預設 `true`**，而 `new-remote-bridge.sh`
  的順序是 `git worktree add`（git 寫檔，LF→CRLF）→ `svn checkout --force`（把既有檔案**當成已版控**收編），
  於是整個工作副本跟 SVN 上的 LF 全部對不上。照推上去，SVN 會留下 11 個檔案整檔改寫的永久紀錄、blame 失效。
- **根因**: 三支建橋腳本裡，**只有這一支沒有先清空 worktree**：

  | 腳本 | 清空 | checkout |
  |---|---|---|
  | `initialize-git-svn-bridge.sh` | ✅ `git clean -dffx` | plain |
  | `checkout-svn-branch.sh` | ✅ `git rm -rf .` + `git clean -dffx` | plain |
  | **`new-remote-bridge.sh`** | ❌ | **`--force`** |

- **Files**:
  - `plugins/turbo-plugin-git-svn/scripts/new-remote-bridge.sh`（modify）
  - `plugins/turbo-plugin-git-svn/scripts/New-RemoteBridge.ps1`（modify）
  - `plugins/turbo-plugin-git-svn/tests/unit/scripts/new-remote-bridge.test.sh`（modify）
  - `plugins/turbo-plugin-git-svn/tests/unit/scripts/New-RemoteBridge.test.ps1`（modify）
- **Approach**: 比照兩支兄弟腳本——`git worktree add` 之後 `git rm -rf .` + `git clean -dffx` 清空
  （保留 `.git` 指標檔），再用 **plain `svn checkout`**（拿掉 `--force`）。腳本內既有的
  `--force` 註解（「`git worktree add` 已經建了檔，不加 `--force` 會被 svn 標成 obstructed」）要一併
  改寫成新的理由，否則下一個讀的人會把 `--force` 加回去。
- **不要用的修法**: **不要**改使用者的 `core.autocrlf`。實測那輪是靠把 proj-1 設成 `false` 繞過去的，
  那會改變該 repo 每一個檔案的簽出行為，是 workaround 不是 fix。
- **Test scenarios**:
  - 在 `core.autocrlf=true` 的 repo 上建分支 bridge，之後 `svn status` 是**空的**（零 dirty）。
  - 同上，在分支上只改一個檔並推送，SVN 該次修訂**只含那一個檔**。
  - `core.autocrlf=false` 的 repo 行為不變（回歸）。
- **Verification**: 新增的兩層測試通過；手動情境重現不再出現整檔改寫。

---

### U3. 共用版本庫下的 push 過期判斷（#2）

- **Goal**: 別人在**其它專案**的提交不該擋住你這個專案的 push。
- **Dependencies**: 無。
- **症狀（實測）**: proj-1 準備好推送後，送出時被擋：
  `Error: SVN HEAD changed since prepare (local r85, head r87)`。但 r86 / r87 是 **proj-2 / proj-3 的
  setup 提交**，proj-1 的路徑一個字都沒被動。更糟的是它叫你去 `/tp-pull-from-svn`，而 pull 回你
  `Already up to date at SVN r85`——**兩支指令互相打臉**。
- **根因**: `build-svn-commit.sh` 第 62–72 行有一整段註解在講「一律用**這個路徑**的
  last-changed-revision，絕不用 repository HEAD」，而且照做了。但 `submit-svn-commit.sh` 第 49–53 行
  用的**就是 repository HEAD**。同一個修正只套了一半。
- **Files**:
  - `plugins/turbo-plugin-git-svn/scripts/submit-svn-commit.sh`（modify）
  - `plugins/turbo-plugin-git-svn/scripts/Submit-SvnCommit.ps1`（modify）
  - `plugins/turbo-plugin-git-svn/tests/unit/scripts/submit-svn-commit.test.sh`（modify）
  - `plugins/turbo-plugin-git-svn/tests/unit/scripts/Submit-SvnCommit.test.ps1`（modify）
- **Approach**: 把 `HEAD_REV="$(svn info --show-item revision "$SVN_URL")"` 改成
  `last-changed-revision`，與 prepare 端一致。錯誤訊息也要跟著改——現在那句會把人導向一個
  「pull 說已是最新」的死路。
- **Patterns to follow**: `build-svn-commit.sh` 的 `PATH_REV` 與它上方的註解。
- **Test scenarios**:
  - 共用版本庫：在**別的路徑**提交推進 repo HEAD 之後，本路徑的 submit 仍然成功。
  - 本路徑真的被別人動過 → submit 仍然正確拒絕，訊息指向 pull。
  - 拒絕時的訊息與 pull 的實際行為一致（不會出現「叫你 pull、pull 說沒事」）。
- **Verification**: 兩層測試通過；三專案共用版本庫的情境下連續推送三個專案不需要中間插假 pull。

---

### U4. 首次接手不再必然撞 `.gitignore` 衝突（#3）

- **Goal**: 已經有 `.gitignore` 的專案（＝幾乎所有真實專案）第一次接手時不要必然衝突。
- **Dependencies**: 無。
- **症狀（實測）**: proj-1 沒有 `.gitignore` → 乾淨過關；proj-2 有一行 `*.log` → **merge 衝突**。
  bootstrap 會往 bridge 的 `.gitignore` 塞 `.svn/` 再 commit 進 bridge，主分支那邊本來就有一份 →
  兩邊各多一行 → 必然衝突。
- **Files**:
  - `plugins/turbo-plugin-git-svn/scripts/initialize-git-svn-bridge.sh`（modify）
  - `plugins/turbo-plugin-git-svn/scripts/Initialize-GitSvnBridge.ps1`（modify）
  - 對應兩層測試（modify）
- **Approach**: 兩個候選，實作時擇一並在 commit 訊息寫明理由：
  1. **bridge 端不動 `.gitignore`** — 改用 bridge worktree 專屬的 `.git/info/exclude` 或
     `core.excludesFile` 把 `.svn/` 擋掉。git 的 per-worktree `info/exclude` 有已知陷阱
     （linked worktree 只讀 common git dir，見既有記錄），實作前要先實證這條路可行。
  2. **對 `.gitignore` 做 union merge** — bootstrap 在 merge 前先把兩邊的行取聯集寫回，讓這個檔案
     不進入衝突狀態。行為可預期，但要處理排序與重複。
  無論哪條，**主分支既有的 `.gitignore` 內容一行都不能掉**。
- **Test scenarios**:
  - 主分支已有 `.gitignore`（含一條專案自訂規則）→ 接手後零衝突，且那條規則還在。
  - 主分支沒有 `.gitignore` → 行為與現在相同（回歸）。
  - 主分支的 `.gitignore` 已經含 `.svn/` → 不重複追加。
- **Verification**: 兩層測試通過；用 proj-2 形狀的 fixture 跑一次真實接手，零衝突。

---

### U5. SVN 路徑不存在的分類與處置（#4 + #5）

- **Goal**: 分清楚「連不到伺服器」與「路徑不存在」，並在後者提供建立路徑的選項。
- **Dependencies**: 無。
- **症狀（分析 + 實測驗證）**: 給一個版本庫存在、但路徑不存在的 URL，bootstrap 在前置檢查就失敗、
  **零殘留可乾淨重跑**（這部分是對的），但訊息是
  `could not read SVN revision from '<url>'. Is the URL reachable?`——版本庫明明完全連得到。svn 自己
  給的 `W170000: URL ... non-existent in revision N` 很精準，被 `2>/dev/null` 吞掉了。
- **背景**: 整個 plugin 的生產腳本裡**沒有任何 `svn mkdir`**，所以專案在版本庫裡的落腳點必須先由人建好。
  但 `tp-setup` 的招牌 case (a) 就叫「新建 git + SVN」，實際上只做得了 git 那半邊。
- **Files**:
  - `plugins/turbo-plugin-git-svn/scripts/initialize-git-svn-bridge.sh` / `.ps1`（modify）
  - `plugins/turbo-plugin-git-svn/skills/tp-setup/SKILL.md`（modify）
  - 對應兩層測試（modify）
- **Approach**:
  - 前置檢查改成兩段：先 `svn info <版本庫根>` 判斷連得到與否，再 `svn info <完整路徑>` 判斷路徑存在與否。
    兩種情況給**不同的 token 與不同的訊息**，並把 svn 的原始訊息一併帶出來（不要吞 stderr）。
  - 路徑不存在時，SKILL 用 `AskUserQuestion` **白話**問兩件事（D2）：要不要幫你在版本庫建這個路徑；
    要不要一併建 `trunk` / `branches` / `tags` 標準結構。
  - 使用者同意才由腳本執行 `svn mkdir --parents`。**這是寫入共用伺服器的永久動作**，摘要要先寫出
    完整 URL；URL 打錯時自動建會安靜地造出一個錯路徑，所以預設**不建**、一定要問過。
  - `branches/` 的存在是後續建分支的前提（`svn copy` **沒有帶 `--parents`**），所以「建標準結構」
    這個選項不是裝飾。
- **Test scenarios**:
  - 版本庫不存在 → 訊息說「連不到」，含 svn 原文。
  - 版本庫存在、路徑不存在 → 訊息說「路徑不存在」，並提供建立選項；**零殘留可重跑**。
  - 使用者選建立 + 建標準結構 → `trunk` / `branches` / `tags` 都出現，然後 bootstrap 正常往下走。
  - 使用者選不建 → 乾淨結束，SVN 零寫入。
- **Verification**: 兩層測試通過；proj-3 形狀（空 trunk）與「連路徑都沒有」兩種情境各跑一次。

---

### U6. 分支 URL 預設值與名稱還原的說明（#6 + #7）

- **Goal**: 建分支時不要每次都要使用者手打完整 URL；匯入分支拿不到原名時要說明。
- **Dependencies**: 無。
- **症狀（#6，分析）**: 建分支的 URL **完全由使用者/agent 給**，腳本對 `trunk` / `branches` / `tags`
  這個慣例毫無概念。唯一的約束是必須落在同一個版本庫底下。所以：
  - `proj-1/branches/feat-x` → 正常
  - `proj-1/branches/team-a/feat-x` → 失敗（`svn copy` 沒有 `--parents`，中間層要先存在）
  - `proj-1/feat-x`（漏了 `branches`）→ **照建**，分支長在 trunk 隔壁，而且 SVN 歷史是永久的
- **症狀（#7，實測）**: 匯入 `feature-legacy-report`（裸 `svn copy` 開的，沒有 `tp:branch-name` 屬性）
  時，本機分支就叫 dash 形，**agent 全程沒有說明為什麼**。對照組 `feature/sample-branch-1`
  （plugin 建的、有屬性）匯回來斜線正確還原——機制是好的，只差沒講。
- **Files**:
  - `plugins/turbo-plugin-git-svn/skills/tp-push-to-svn/SKILL.md`（modify）
  - `plugins/turbo-plugin-git-svn/skills/tp-checkout-svn-branch/SKILL.md`（modify）
- **Approach**:
  - push 的首推 bootstrap：從 `remote-svn/main` 的 URL 推導預設值（`.../trunk` → `.../branches/<分支名>`，
    分支名用消毒過的 dash 形），當成 `AskUserQuestion` 的**第一選項**讓使用者確認或改。推導不出來
    （trunk 不是以 `/trunk` 結尾等非標準佈局）就退回現在的行為：要求使用者提供。
  - checkout：讀不到 `tp:branch-name` 時，在回報裡加一句白話說明——「這條分支不是本工具建的，SVN 路徑
    上沒有原始名稱，所以用了路徑名；如果你們的慣例是 `feature/xxx`，本機分支名可能與同事的不同」。
- **Test scenarios**:
  - 標準佈局 → 預設 URL 推導正確（`.../proj-1/trunk` → `.../proj-1/branches/feat-coupon`）。
  - 非標準佈局 → 不推導，退回要求輸入。
  - 有 `tp:branch-name` → 斜線還原（回歸），**不**出現那句說明。
  - 無 `tp:branch-name` → dash 形 + 出現說明。
- **Verification**: SKILL 層以一次真實操作人工驗證（這兩項是 agent-prose，沒有腳本可測）。

---

### U7. publish 的 Release 不再是假的（#9）

- **Goal**: pubxml 指定 Release 時，產出的就要是 Release。
- **Dependencies**: **U1**（路徑改名）。
- **症狀（實測）**: 第一次發佈出來的是 **Debug** 組建（`/optimize-`、`DEBUG` 常數、來源
  `obj\Debug\`），卻放在 `bin\Release\Publish\`。agent 自己看出來、清掉重發才對。
- **根因**: `Publish-Web.ps1:51-52` 有一段明確的假設——

  > Configuration / Platform: OMIT when the agent gave no value — the pubxml's embedded
  > `<Configuration>/<Platform>` govern the publish (that is how VS publishes from a profile).

  **實測證明這個假設是錯的。** .NET Framework web publish 走 `/p:PublishProfile` 時，profile 裡的
  Configuration 不會在建置階段生效，csproj 的 `<Configuration Condition="...">Debug</Configuration>`
  預設值會贏。
- **Files**:
  - `plugins/turbo-plugin-dotnet-framework/scripts/Publish-Web.ps1`（modify）
  - `plugins/turbo-plugin-dotnet-framework/scripts/publish-web.sh`（視 U8 的結果，可能不需改）
  - `plugins/turbo-plugin-dotnet-framework/tests/unit/scripts/Publish-Web.test.ps1`（modify）
  - `plugins/turbo-plugin-dotnet-framework/tests/unit/scripts/publish-web.test.sh`（modify）
  - `plugins/turbo-plugin-dotnet-framework/skills/tp-publish-dotnet-framework-web/SKILL.md`（modify）
- **Approach**: agent 未指定 configuration 時，**從 pubxml 讀出 `<Configuration>` 並明確帶
  `/p:Configuration=`**。讀不到才維持省略。把那段錯誤的註解換成實測結論，避免有人日後又拿掉。
  **build 那邊的「省略以對齊 VS」不要動**——那條在 build 是對的，只有 publish 不是。
- **Test scenarios**:
  - pubxml 寫 `Release` 且 agent 未指定 → MSBuild 命令列含 `/p:Configuration=Release`，產出是 Release。
  - agent 明確指定 configuration → 以 agent 的值為準（pubxml 不覆蓋它）。
  - pubxml 沒有 `<Configuration>` → 維持省略（回歸）。
- **Verification**: 兩層測試通過；真實發佈一次，檢查產出的組建旗標（`/optimize+`、無 `DEBUG` 常數）。

---

### U8. dotnet 的目標指名與參數風格（#8 + #10）

- **Goal**: dotnet plugin 在多專案工作區能指名要動哪個專案，且 `.sh` 的參數風格不再誤導。
- **Dependencies**: **U1**。
- **症狀（#8，實測）**: 每一次呼叫都是 `cd "<專案>" && bash <腳本>`，agent 自己說「腳本以當前目錄判斷
  repo root」。查證：`Start-Iis.ps1` 只收 `-Project` 與 `-Timeout`，**11 支 `.sh` 沒有任何一支支援
  `--repo-root`**（對照：git-svn 12 支裡 11 支支援）。git-svn 的判準檔 `assets/repo-target.md` 明文說
  「用指名而不是 `cd`」，dotnet 完全沒有這個能力。
- **症狀（#10，實測）**: agent 用 `--remove-all` 失敗，改用 `-RemoveAll` 才過。原因：所有 dotnet `.sh`
  都是 `exec ps1-delegate.sh <Name> "$@"` 的薄殼，**零轉譯**，參數直接進 `powershell -File`。所以
  `--project` 碰巧能通（單字對得上 `-Project`），`--remove-all` 不通（實際參數是 `-RemoveAll`，
  沒有連字號）。單字能用、多字不能用，最容易誤導。
- **Files**:
  - `plugins/turbo-plugin-dotnet-framework/scripts/*.ps1`（入口腳本加 `-RepoRoot`）
  - `plugins/turbo-plugin-dotnet-framework/scripts/lib/ps1-delegate.sh`（modify）
  - `plugins/turbo-plugin-dotnet-framework/skills/*/SKILL.md`（五支，加目標判準與「要動的專案」那行）
  - 對應兩層測試
- **Approach**:
  - `.ps1` 入口加可選 `-RepoRoot`，語意與 git-svn 一致：不傳＝從當前目錄往上找（行為完全不變）；
    傳＝直接指名。內部既有的 `$repoRoot` 解析點改吃這個值。
  - **`.sh` 的參數風格**：在 `ps1-delegate.sh` 做一層 `--kebab-case` → `-PascalCase` 的轉譯，讓
    dotnet 的 `.sh` 與 git-svn 的 `.sh` 對外一致。轉不到的參數原樣傳遞並保留現有行為。
  - 五支 SKILL 比照 git-svn：引用 `repo-target.md` 的判準（或複製一份到 dotnet plugin——注意
    **跨 plugin 共用檔要進 `verify-core-identical` 的 `shared_specs`**），會寫入的動作在確認裡先寫出
    `要動的專案:<絕對路徑>`。
- **Test scenarios**:
  - 不傳 `--repo-root` → 行為與現在完全相同（回歸，全部既有測試須通過）。
  - 傳 `--repo-root` 指向並排工作區裡的某個專案 → 作用在該專案，不受當前目錄影響。
  - `--repo-root` 指向不存在的路徑 → 明確報錯，不建立任何東西。
  - `.sh` 用 `--remove-all` / `--project` 都能通；`.ps1` 用 `-RemoveAll` / `-Project` 都能通。
- **Verification**: 兩層測試通過；在多專案工作區從工作區根（不 `cd`）成功 build / run / stop 指定專案。

---

### U9. DB 範本可以進版控（#11）

- **Goal**: `dbhub.example.local.toml` 這個「設計上要進版控」的範本不要被自己寫的規則擋住。
- **Dependencies**: 無。
- **症狀（實測）**: db 的 setup 部署 `.turbo-plugin/dbhub.example.local.toml`（要給同事看的範本），
  但同一套 setup 又往 `.gitignore` 寫 `.turbo-plugin/**/*.local.*`。掃過全 repo：**沒有任何放行例外**。
  所以範本永遠傳不到同事手上，這支 skill 的核心目的直接落空。
- **Files**:
  - `plugins/turbo-plugin-git-svn/skills/tp-setup/assets/setup-base.md`（modify）
  - `plugins/turbo-plugin-three-environment-db/skills/tp-setup/assets/setup-base.md`（modify，**位元組
    必須與上一份相同**）
  - 兩支 `tp-setup/SKILL.md` 內重述該規則的段落
  - 對應兩層測試
- **Approach**: base `.gitignore` 骨架在 `*.local.*` 之後補一條放行：`!*.example.local.*`（或等效寫法）。
  **真正含密碼的 `dbhub.local.toml` 仍須被擋住**——這是這個 unit 的驗收重點。改完跑
  `tools/verify-core-identical.sh` 確認兩份共用檔仍一致。
- **Test scenarios**:
  - `git check-ignore` 對 `dbhub.example.local.toml` → **不被忽略**。
  - `git check-ignore` 對 `dbhub.local.toml` → **被忽略**。
  - `config.local.toml`、`encoding-status.local.md` → 仍被忽略（回歸）。
  - `verify-core-identical` 全綠。
- **Verification**: 兩層測試通過；在乾淨 repo 跑一次 db setup，範本出現在 `git status` 的未追蹤清單裡。

---

### U10. DB 的 MCP 啟動不再污染、且找得到設定（#13 + #14）

- **Goal**: 不要在任何開 session 的資料夾建出空資料夾；並讓 MCP 在多專案工作區找得到設定。
- **Dependencies**: **D1 定案**。
- **症狀（#13，實測）**: 工作區根被建出 `.turbo-plugin/dbhub.local.toml` —— 而且它是一個**空資料夾**，
  不是檔案。根因是 `.mcp.json` 的
  `-v "${CLAUDE_PROJECT_DIR}/.turbo-plugin/dbhub.local.toml:/dbhub.toml"`：Docker 在 bind mount 來源
  不存在時**會建目錄**。三個後果：① 任何開 session 的資料夾都被污染，即使那裡不是專案；
  ② **它擋住自己的修復路徑**——目錄一旦存在，使用者就沒辦法再建同名的檔案；③ 就算掛上去，
  dbhub 收到的是目錄不是設定檔。
- **症狀（#14，實測）**: session 開在工作區根 → `CLAUDE_PROJECT_DIR` = 工作區根，而設定在
  `proj-2/.turbo-plugin/`。**在多專案工作區裡 MCP 永遠找不到設定。** 這比 #8 難處理：MCP 設定是靜態
  JSON，沒有 agent 判斷的空間可以補救。
- **Files**:
  - `plugins/turbo-plugin-three-environment-db/.mcp.json`（modify）
  - `plugins/turbo-plugin-three-environment-db/scripts/Start-Dbhub.ps1` + `start-dbhub.sh`（create）
  - `plugins/turbo-plugin-three-environment-db/README.md`（modify）
  - 對應兩層測試（create）
- **Approach（提案，待 D1 定案）**:
  - `.mcp.json` 的 `command` 從 `docker` 改成 plugin 自己的包裝腳本。由腳本負責：
    1. **找設定檔**（D1 決定怎麼找）
    2. **找不到就乾淨結束並印出清楚訊息**——關鍵是**永遠不要用不存在的路徑去 `docker run -v`**，
       這樣 #13 就不會發生
    3. 找到才組出 `docker run` 並 exec
  - 這個包裝在 D1 的三個方向下都需要，所以 #13 那半邊不受阻塞；D1 只決定第 1 步怎麼寫。
  - 若 D1 選方向 2（接受不相容），腳本就只做「偵測到多專案工作區 → 明確說明並結束」。
- **Test scenarios**:
  - 設定不存在 → 腳本乾淨結束、印出可操作的訊息，**檔案系統零變更**（特別是不得建出任何目錄）。
  - 設定存在 → 正確組出 `docker run` 參數（以 dry-run 模式驗證命令列，不真的起容器）。
  - 多專案工作區 → 依 D1 的定案行為。
  - 已經被舊版建出空資料夾的情況 → 給出清楚的修復指引（`rmdir` 那個目錄）。
- **Verification**: 兩層測試通過；在工作區根開一次 session，`.turbo-plugin/` 不會被建出來。

---

### U11. console 專案支援（#16）

- **Goal**: run / stop 依專案型別分流，讓 console 專案也能用；build 只需描述涵蓋。
- **Dependencies**: **U1**。建議排在 U7、U8 之後（同一個 plugin，避免衝突）。
- **依據（實測）**: 你叫 agent「proj-3 也跑起來看看」時，它用**現有的** `tp-build-dotnet-framework-web`
  成功建了 console 專案（MSBuild 不在乎專案型別），然後自己讀 csproj 判斷 `OutputType=Exe`，
  改成「建置 + 執行 exe」，中文報表正確印出。所以型別判斷這件事 agent 天生就會做。
- **Files**:
  - `plugins/turbo-plugin-dotnet-framework/scripts/Start-Console.ps1` + `start-console.sh`（create）
  - `plugins/turbo-plugin-dotnet-framework/scripts/Stop-Console.ps1` + `stop-console.sh`（create，
    只處理「本工具啟動且仍在跑」的）
  - `plugins/turbo-plugin-dotnet-framework/skills/tp-run-dotnet-framework-web/SKILL.md`（modify，加分流）
  - `plugins/turbo-plugin-dotnet-framework/skills/tp-stop-dotnet-framework-web/SKILL.md`（modify，加分流）
  - `plugins/turbo-plugin-dotnet-framework/skills/tp-build-dotnet-framework-web/SKILL.md`（modify，
    只改描述與 Decision Rules，**程式碼不動**）
  - 對應兩層測試（create）
- **Approach**:
  - **分流判準**：讀 csproj 的 `OutputType`（`Exe` / `WinExe` → console 路徑；`Library` + web 專案型別
    GUID → IIS 路徑）。判不出來就問使用者，不要猜。
  - **run（console）**：建置後執行 exe。**參數與工作目錄比照 VS 存在機器本機設定**——VS 存在
    `<專案>.csproj.user`，我們存 `.turbo-plugin/config.local.toml` 的 `[run]` 區塊。回報 stdout /
    stderr 與 exit code。
  - **stop（console）**：只停「本工具啟動、且仍在跑」的那個，按 PID。**不做孤兒清理**——D5：VS 對
    不附加偵錯器的 console 也不追蹤，做了就超出 VS 的定位。
  - **publish**：**不做 console publish**（D5：VS 沒有這個概念）。若 agent 對 console 專案呼叫 publish，
    SKILL 要明講「VS 對 .NET Framework console 沒有發佈，你要的可能是直接複製 `bin\Release`」。
  - **cleanup-orphan-iis**：完全不動，它本來就是 IIS 專屬。
- **Test scenarios**:
  - console 專案 run → exe 被執行、stdout 被完整回報、exit code 正確傳回。
  - console 專案的參數與工作目錄從 `config.local.toml` 讀出並生效。
  - 一次性 console（跑完就結束）→ stop 回報「已經結束了」，不報錯。
  - 常駐 console → stop 按 PID 停掉它自己啟動的那個，不影響其它程序。
  - web 專案 run / stop → 行為完全不變（回歸，既有測試全數須通過）。
  - console 專案 publish → 明確說明不適用，不執行任何 MSBuild publish target。
  - 型別判不出來 → 詢問使用者，不猜。
- **Verification**: 兩層測試通過；用 proj-3 形狀（console）與 proj-1 形狀（web）各跑一次完整
  build → run → stop。

---

### U12. `tp-db-management` 無連線時先產腳本（#12）

- **Goal**: 沒有資料庫連線也要能產出 SQL 腳本。
- **Dependencies**: 無。
- **症狀（實測）**: 請它在 `Orders` 上建索引時，它查了 `dbhub.local.toml`（不存在）、找 MCP 工具
  （沒有），然後停下來問要「先填連線」還是「依假設先產」。它沒有拒絕、也提供了選項，但**預設是停下來問**。
- **Files**:
  - `plugins/turbo-plugin-three-environment-db/skills/tp-db-management/SKILL.md`（modify）
- **Approach（D3）**: 沒有連線時**預設先產出腳本**，並在輸出裡明確標註「未經實際資料庫驗證，依據是
  repo 內的 `db/*.sql`」。要驗證再問使用者要不要接上連線。腳本本身沿用既有慣例（編號、
  `IF NOT EXISTS` 包住、`GO` 結尾）——那正是「重複執行安全」的作法，也讓「沒查到現有索引」的風險落地。
- **Test scenarios**: 這支是純 agent-prose，無腳本可測。以一次真實操作人工驗證：在沒有
  `dbhub.local.toml` 的專案請它加一支索引腳本 → 直接產出、含假設標註，不停下來問。
- **Verification**: 人工驗證一次。

---

### U13. skill description 全面改英文（#17）

- **Goal**: 縮小前載的 description 體積，並把「description 英文、body 繁中」寫成常駐規約。
- **Dependencies**: **U11**（它會新增 / 改寫描述）。**必須最後做。**
- **現況量測**: 18 支 skill 的 description 合計 **4246 字元，其中 1287 個中文字**，粗估
  **2000–2800 tokens**；全改英文、語意不減大約落在 **500–700**。
  最長 `tp-setup`(git-svn) 395 字元；中文密度最高 `tp-multi-repo-workspace-setup`（255 字元／125 中文字）。
- **誠實說明**: 「Claude Code 會少載入部分 description」這個機制**無法從這裡驗證**。省 token 是實打實
  且可量測的，但不宣稱修好了某個已知的截斷問題——這件事的定位是「便宜的保險 + 對齊生態慣例」。
- **Files**:
  - 全部 18 支 `plugins/*/skills/*/SKILL.md` 的 frontmatter `description`（modify）
  - `CLAUDE.md`（新增規約段落）
  - 五個 plugin 的 `README.md`（若有重述 description）
- **Approach**:
  - **這不是機械翻譯。** description 裡藏著會改變觸發行為的限定語——例如 `tp-setup` 的
    「agent 偵測到 marker 不存在時**可建議**使用者執行，**不要自動觸發**」。翻掉一個限定詞，觸發行為
    就變了。逐支翻譯時要把這些限定語當成契約來對待。
  - **body 維持繁中**，只動 frontmatter 的 `description`。
  - `CLAUDE.md` 加一段：description 用英文（前載、給機器路由用）、body 用繁中（用到才載、給 agent 讀）。
- **Test scenarios**（觸發驗證，**每支都要用乾淨 session**）:
  - 實測已證實：**同一個 session 裡跑過一次之後就不會再自動觸發**，所以在跑過的 session 裡驗等於白驗。
  - 每支 skill 至少驗一個「應該觸發」的情境與一個「不該觸發」的情境。
  - 特別要驗 `tp-setup`（不該自動觸發，只該建議）與 `tp-suggest-ignore`（該在偵測到未忽略產物時主動出聲）。
- **Verification**: 改完重新量測總字元數；抽驗至少 5 支的觸發行為，含上述兩支特別的。

---

## Verification Contract

- **每個 plugin 的 orchestrator 全綠**：`plugins/<name>/tests/Invoke-ScriptTests.ps1`（Windows
  PowerShell 5.1）與 `tests/invoke-script-tests.sh`（bash）都要 lint 0 違規、Pester 0 失敗、
  shunit2 0 失敗。缺 `svn` / MSBuild / IIS 的環境自我 SKIP（非 FAIL），CI 視 SKIP 為綠。
- **共用檔一致性**：`tools/verify-core-identical.sh` 與 `.ps1` 全綠（U1 改了 `shared_specs`、
  U9 改了 `setup-base.md` 的兩份複本）。
- **PS 5.1 五禁忌**：無 3-arg `Join-Path`、無 `GetRelativePath`、含非 ASCII 的 `.ps1` 存成 UTF-8 BOM、
  native exe 不用 `2>&1`、單元素 pipeline 用 `@()` 強制陣列。
- **跨平台對稱**：每個改動的 `.ps1` 與它的 `.sh` 兄弟在共用 fixture 上行為一致。
- **回歸不得破**：每個 unit 的「行為與現在相同」測試情境都必須通過——特別是 U8 的「不傳
  `--repo-root` 行為不變」與 U11 的「web 專案 run / stop 行為不變」。
- **零全域污染**：測試只在 repo 相對的 gitignored sandbox 內動作；svn 全域設定沙箱隔離；
  跑完不得在 sandbox 外留下產物。
- **CI 綠**：`push` 觸發的 12 個 job 全綠（windows 跑 `.ps1` + `.sh`；ubuntu 跑可移植的 `.sh`）。

---

## Definition of Done

- U1–U13 各自落地成獨立的**繁中 conventional commit**（`feat` / `fix` / `refactor`），本機提交，
  **不 push、不開 PR**（除非另外指示）。
- 14 個實機發現的症狀逐一重現不出來——每個 unit 的「症狀」段就是驗收腳本。
- 全部 orchestrator 綠、`verify-core-identical` 綠、CI 綠。
- D1 已定案並在 U10 的 commit 訊息裡記錄選了哪個方向與理由。
- `CLAUDE.md` 記錄了 description 語言規約（U13）。
- 實機驗證環境（`C:\Turbo\test-turbo-plugin`）跑一次 `tools/reset-fixture.sh` 之後，重跑本計畫涵蓋的
  情境不再出現這 14 個症狀。
- merge 進 `main` 時**禁止 squash**（既有規約：合併後要在 merge commit 上打各 plugin 的 `0.1.0` 基準 tag）。

---

## 附錄：17 項對應表

| # | 項目 | 來源 | Unit |
|---|---|---|---|
| 1 | `new-remote-bridge` 未清空 worktree → 換行整檔改寫 | 實測 | U2 |
| 2 | `submit-svn-commit` 用 repo HEAD 判斷過期 | 實測 | U3 |
| 3 | 既有 `.gitignore` 首次接手必衝突 | 實測 | U4 |
| 4 | 「連不到」與「路徑不存在」訊息混同 | 分析 | U5 |
| 5 | 路徑不存在時要能幫忙建（含標準結構） | 分析 | U5 |
| 6 | 分支 URL 沒有預設值 | 分析 | U6 |
| 7 | 匯入分支拿不到原名時沒有說明 | 實測 | U6 |
| 8 | dotnet 入口腳本缺 `--repo-root` | 實測 | U8 |
| 9 | publish 的 pubxml Release 失效，實際產出 Debug | 實測 | U7 |
| 10 | dotnet `.sh` 參數風格與 git-svn 不一致 | 實測 | U8 |
| 11 | DB 範本被自己 setup 寫的 gitignore 規則擋住 | 實測 | U9 |
| 12 | `tp-db-management` 無連線時停下來問 | 實測 | U12 |
| 13 | Docker bind mount 把不存在的設定檔變成空資料夾 | 實測 | U10 |
| 14 | `${CLAUDE_PROJECT_DIR}` 在多專案工作區指到工作區根 | 實測 | U10 |
| 15 | dotnet plugin 改名 | 指定 | U1 |
| 16 | console 專案支援 | 指定 | U11 |
| 17 | skill description 改英文 | 指定 | U13 |

## 建議執行順序

```
U1（改名，必須最先）
 ├─ 可平行：U2  U3  U4  U5  U6  U9  U12
 ├─ U7 → U8 → U11（同一個 plugin，序列做避免衝突）
 ├─ U10（等 D1 定案）
 └─ U13（必須最後，等 U11 的描述定稿）
```
