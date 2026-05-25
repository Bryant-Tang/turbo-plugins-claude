---
date: 2026-05-25
type: feat
origin: docs/brainstorms/turbo-plugin-requirements.md
status: active
---

# feat: turbo-plugin v0.2.4 script-level autonomous test plan

## Summary

agent-executable 完整 script-level 測試計畫,covering 所有 `.ps1` / `.sh` /
helper / hook 的所有狀況,目標**不要缺漏**。**25 個 Implementation Unit 分 6
phase**(Foundation / Build & IIS & Publish / SVN Bridge / SVN Tools / Hooks
/ Cross-cutting encoding & parity)。**agent autonomous 跑得到的全跑**,
SKILL agent-flow 部分由另一份 plan
(`2026-05-25-001-feat-turbo-plugin-acceptance-test-plan.md`)由人 manual 跑。

test 環境:`C:\Turbo\SampleGitWithSvn`(fixture,內容可隨意改)。每 unit
含 precondition / action / verification + pass-fail 判準,失敗時 agent 應
直接修(若 P0/P1)或記為 finding(若 P2/P3)。

**此 plan 補上一輪 script-level test 漏的部分**,具體:
- 中文檔名 push-to-svn(完全沒測,使用者點出)
- 多個 script 的 edge case(empty input / 非 ASCII / multiple-csproj 等)
- lib helper 直接 unit test(之前只間接驗)
- 全套 cross-platform parity(.ps1 vs .sh 配對)
- hook stdin payload 各種畸形 input

---

## Problem Frame

之前 script-level autonomous test:
- 跑通 ~20 個 script 的 happy path
- 抓出 3 個 P0(PS 5.1 Join-Path 3-arg / GetRelativePath / BOM)+ 2 個 P2
  + 修進 v0.2.1 ~ v0.2.4
- **但**:edge case / encoding / parity / hook 畸形 input 各項都沒完整跑;
  特別是**中文檔名 push-to-svn** 完全沒測

實際上 plugin 的設計強烈受 i18n + cross-platform 影響:
- 開發者多在中文 Windows 環境
- 同樣 script 跟 sibling .sh 必須結果一致(R8)
- SVN bridge 處理永久 history,失敗會打到生產

漏測 = bug 帶進 production = SVN 永久 history 亂碼或 plugin 不能跑。

---

## Scope Boundaries

### In scope

- **17 個 user-facing `.ps1` script**(`scripts/<name>.ps1`,不含 hooks/ 與 lib/)各 happy + edge + failure 完整 case
- **對應 `.sh` sibling**:其中 16 個有真實 bash 實作,U13(`cleanup-orphan-iis`)Windows-only,`.sh` 只是 ps1-delegate wrapper(不算真 sibling,U13 只測 Windows side + delegate 正確呼叫 ps1)
- **3 個 lib file**(`common.ps1`、`common.sh`、`applicationhost-helpers.ps1`)
  helper function 各別 unit test(directly invoked + return value 驗)
- **2 hook(`posttooluse-enterworktree` + `sessionstart`)**.ps1 + .sh
  各 input scenario(empty / malformed JSON / 各條件 short-circuit)
- 全體 .ps1 count:17 user-facing + 2 hooks + 2 lib(`common.ps1` + `applicationhost-helpers.ps1`)= **21 個 .ps1**;.sh count:16 真 sibling + 1 delegate(`cleanup-orphan-iis.sh`)+ 2 hooks + 1 lib(`common.sh`)+ 1 utility(`ps1-delegate.sh`)= **21 個 .sh**
- **Cross-cutting encoding test**:中文檔名 / 中文 commit message / 中文
  pattern / 中文 csproj 名 / 中文 directory 名
- **`tools/lint-ps-compat.ps1`** 對 turbo-plugin scope 跑 0 violation 確認
- 失敗:script 應該對應 design 行為(throw / exit code / structured token)

### Deferred to Follow-Up Work

- **真實啟動 IIS Express 完整 lifecycle** — fixture apphost 太簡會 fail,需
  VS 跑過一次或寫複雜 minimal apphost,留 manual acceptance plan U6
- **SKILL agent-flow 整合測試** — 不在 script-level 範圍,留 acceptance
  plan(`2026-05-25-001-...`)
- **GitHub Actions CI 整合** — `tools/lint-ps-compat.ps1` 進 workflow 留
  cutover 後
- **真實 dbhub MCP server connect 測試** — 需 user-side credentials,留 manual

### Outside this product's identity

- 既有 4 plugin (tdp/tnf/tgs/tpi) script test — cutover 後 disable,不測
- 生產 SVN repo 測試 — 只用本機 `SampleSvnServer/`
- Performance / load test — 非設計目標

---

## Key Technical Decisions

1. **Agent autonomous 跑得到的全跑**:script invocation + stdout/stderr/
   exit code 觀察 + file system 驗證 — 都是 agent autonomous 範圍
2. **不模擬真實 IIS Express start**:U-IIS-START 邏輯驗 fail-fast +
   process.HasExited check;真實啟動成功留 manual。理由:fixture apphost
   太簡會立刻 exit,反複測試浪費時間
2b. **fake iisexpress process spawn 機制**(U10.4 / U10.6 / U11.3-U11.5):用 `Start-Process iisexpress.exe -ArgumentList '/site:Fake-deadbeef','/config:<scratch-apphost>' -PassThru -WindowStyle Hidden`,scratch apphost 預先寫 `<site name="Fake-deadbeef">`。target test 只看 `Get-CimInstance Win32_Process` CommandLine 抓得到即可(無論 listening 與否)。測完 `Stop-Process -Force`。U13.8 lock 測試用 `[System.IO.File]::Open` FileShare.None。**Auto-mode pre-classification**:此類測試 spawn real process / lock file,**預設標 `auto_mode: needs-manual`** 寫在 unit Approach 頂;若 agent autonomous 跑得了(無 sandbox 擋)再 promote `ok`。**不要等跑到一半才發現擋** — plan 時就決定
3. **SVN test 用 `^/test-script-N`(N=1,2,3,…) namespace**:跟 manual
   plan 的 `^/test3` 區隔,避免互撞。測完一起 cleanup
4. **中文檔名測試**用 `測試檔案-${random}.txt` pattern,涵蓋:
   - Big5 編碼下的 PowerShell argv passing
   - UTF-8 stored SVN repo
   - git → svn add 中間的 filename encoding 鏈
5. **Cross-platform parity 用 diff-based verification**:同 input 餵兩個
   sibling script,比對 stdout (normalize line endings) + exit code +
   file system side-effect。差異視為 finding
6. **每 unit 失敗即修(依 CLAUDE.md versioning rule)**:P0/P1 立即 commit fix → 對應 patch bump(每 fix 一個 patch,不是「全部塞 v0.2.5」);P2/P3 累積到 phase 結尾批次 commit + 一次 bump。**若整 test run 找不到 P0/P1/P2/P3 → no bump**(violate CLAUDE.md「bump 須有實 change」)
8. **Privilege level assumption(SEC-009)**:全 test run 預設**non-elevated**(非 Administrator)身分跑。U8.3 canary `C:/tmp/SHOULD-NOT-EXIST-<n>` 要在 admin 也擋住才有意義 — 若 agent 被 elevated 啟動,U8.3 為 false positive(rm 不靠 shell composed 也可成功)。U1 preflight 加 `[System.Security.Principal.WindowsIdentity]::GetCurrent()` check;若 IsInRole(Administrator)= True → U8.3 mark **manual-needed**(等使用者在 non-admin shell 跑)。Process-kill tests(U10.5+/U11.3+/U13)若遇到跨用戶 process → Stop-Process 應 emit access-denied clear error 而非 silent exit 0(test 加 negative assertion)

7. **lib helper unit test 用 inline PowerShell dot-source + minimal harness**:**不**引入 Pester。Agent 自寫一個 minimal harness file `jobs/<job>/test-output/test-harness.ps1`,內含:
   ```powershell
   function Assert-Equal { param($Actual, $Expected, $Label) if ($Actual -ne $Expected) { Write-Host "[$Label] FAIL expected=$Expected actual=$Actual" -ForegroundColor Red; return $false } else { Write-Host "[$Label] PASS" -ForegroundColor Green; return $true } }
   function Assert-Match { param($Actual, $Pattern, $Label) if ($Actual -notmatch $Pattern) { Write-Host "[$Label] FAIL pattern=$Pattern actual=$Actual" -ForegroundColor Red; return $false } else { Write-Host "[$Label] PASS"; return $true } }
   function Assert-Throws { param([scriptblock]$Block, $Label) try { & $Block; Write-Host "[$Label] FAIL did not throw" -ForegroundColor Red; return $false } catch { Write-Host "[$Label] PASS"; return $true } }
   ```
   每 unit 第一行 `. $env:CLAUDE_JOB_DIR/test-output/test-harness.ps1`;每 sub-test 用 `Assert-Equal (FuncCall) ExpectedValue 'U2.1'` 統一輸出格式,U25.7 final report 可 grep `\[U(\d+)\.\d+\] (PASS|FAIL)` aggregate

---

## Output Structure

```
C:\Turbo\SampleGitWithSvn\                       # fixture
├── SampleGit\                                   # main worktree(已備)
│   ├── src\MinimalWebApp\                       # 主測 fixture
│   ├── src\測試專案\                            # 中文路徑測試 fixture(新)
│   │   └── 中文.csproj
│   └── ...
├── SampleGit.worktrees\
│   ├── dev-1\                                   # peer worktree
│   ├── remote-main\                             # SVN trunk
│   └── remote-test-script-N\                    # 各 test unit 暫時建用
└── SampleSvnServer\
    ├── main/
    ├── test/
    └── test-script-N/                           # 各 test unit 暫時建用

C:\Users\Mel Wu\.claude\jobs\<job-id>\           # agent 暫存
├── test-output\                                 # 各 unit 暫存 stdout/stderr
│   ├── U2-common-ps1.log
│   ├── U13-push-chinese-fname.log
│   └── ...
└── test-fixtures\                               # 暫時 hack 用 fixture(scratch)
    ├── apphost-with-fake-site.config
    ├── 中文檔名.txt
    └── ...
```

`docs/plans/2026-05-25-002-feat-turbo-plugin-script-level-test-plan.md`
= 本文件(plan)
`docs/plans/2026-05-25-001-feat-turbo-plugin-acceptance-test-plan.md`
= 補集(manual SKILL agent-flow plan,人跑)

---

## Implementation Units

### Script → Unit mapping table(traceability,避免「漏測哪個 script」)

| Script(.ps1) | 對應 .sh | 主 Unit | 涵蓋 sub-test |
|---|---|---|---|
| `lib/common.ps1` | `lib/common.sh` | U2 / U3 | U2.1-U2.16 / U3.1-U3.12 |
| `lib/applicationhost-helpers.ps1` | (PS-only) | U4 | U4.1-U4.9 |
| `compute-project-identity.ps1` | `.sh` | U5 | U5.1-U5.8 |
| `resolve-iis-settings.ps1` | `.sh` | U6 | U6.1-U6.9 |
| `build-web.ps1` | `.sh` | U7 | U7.1-U7.12 |
| `pack-content.ps1` | `.sh` | U8(security)| U8.1-U8.8 |
| `publish-web.ps1` | `.sh` | U9 | U9.1-U9.9 |
| `start-iis.ps1` | `.sh` | U10 | U10.1-U10.11 |
| `stop-iis.ps1` | `.sh` | U11 | U11.1-U11.7 |
| `check-iis-listening.ps1` | `.sh` | U12 | U12.1-U12.2, U12.5 |
| `get-target-url.ps1` | `.sh` | U12 | U12.3-U12.5 |
| `cleanup-orphan-iis.ps1` | `.sh`(delegate)| U13 | U13.1-U13.11 |
| `pull-from-svn.ps1` | `.sh` | U14 | U14.1-U14.9 |
| `push-to-svn-prepare.ps1` | `.sh` | U15 | U15.1-U15.9 |
| `push-to-svn-commit.ps1` | `.sh` | U16(中文檔名 ⭐)| U16.1-U16.14 |
| `create-remote-test.ps1` | `.sh` | U17 | U17.1-U17.9 |
| `reset-remote-test.ps1` | `.sh` | U18 | U18.1-U18.5 |
| `svn-ignore.ps1` | `.sh` | U19 | U19.1-U19.9 |
| `svn-log.ps1` | `.sh` | U20 | U20.1-U20.9 |
| `hooks/posttooluse-enterworktree.ps1` | `.sh` | U21 | U21.1-U21.14 |
| `hooks/sessionstart.ps1` | `.sh` | U22 | U22.1-U22.8 |

Count check:17 user-facing(`build-web` ~ `svn-log`)+ 2 hook + 2 lib = **21 .ps1**;對應 .sh 同 21(U13 delegate-only;`pack-content.sh` / `lib/common.sh` 與 hook 都有 sibling)。

### Phase 1 — Foundation(lib helpers + identity layer)

---

### U1. Pre-flight + lint baseline

**Goal**:確認 fixture 環境 ready,turbo-plugin scope lint 0 violation,所
後續 unit 跑 from known clean state。

**Dependencies**:無

**Files**:
- `SampleGit/` git state probe
- `tools/lint-ps-compat.ps1`(run)
- `C:\Users\Mel Wu\.claude\jobs\<job>\test-output\U1-preflight.log`

**Approach**:
1. probe SampleGit state(branch / HEAD / working tree clean)
2. probe SVN server up(`svn info file:///.../SampleSvnServer/main` exit 0)
3. probe MSBuild + IIS Express path exist
4. run `tools/lint-ps-compat.ps1 -Path <turbo-plugin>` 確認 0 violation

**Test scenarios**:

- **U1.1 SampleGit clean**:`git -C SampleGit status --porcelain` 空(除 `.claude/` `.turbo-plugin/dbhub.local.toml` 等 gitignored)
- **U1.2 SVN server up**:`svn ls file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/` exit 0,輸出含 `main/` `test/`
- **U1.3 MSBuild + IIS path**:`Test-Path 'C:/Program Files/Microsoft Visual Studio/2022/Community/MSBuild/Current/Bin/MSBuild.exe'` + `Test-Path 'C:/Program Files/IIS Express/iisexpress.exe'` 各 True
- **U1.4 Lint clean**:`tools/lint-ps-compat.ps1 -Path plugins/turbo-plugin` exit 0,訊息 `0 violations`
- **U1.5 PATH 工具齊**(F-U1.5 修正):`Get-Command svn,git,powershell -ErrorAction SilentlyContinue` 各 Source 非空;**iisexpress 不在 default PATH**(Windows 設計上裝在 `C:\Program Files\IIS Express\` 不加 PATH),改用 U1.3 file existence check 已涵蓋;`node` / `npm` 缺則 U7.10 / U8.1 / U8.6 mark `skip - no node`
- **U1.6 git version >=2.31**:`git --version` 解 numeric 比對(若 <2.31 → U2.3 / U5.1 等所有 git-common-dir / worktree 操作會 fail;mark blocker)

**Verification**:全 PASS = 環境 ready,後續 unit 可信賴 baseline 一致。

---

### U2. `lib/common.ps1` helper functions(direct unit test)

**Goal**:對 common.ps1 內的每個 export function 直接 unit test,validate
return value 與 throw 行為,不透過 caller 間接驗。

**Dependencies**:U1

**Files**:
- `plugins/turbo-plugin/scripts/lib/common.ps1`(SUT)
- agent 暫存 inline PowerShell test snippets

**Approach**:寫 PowerShell test script dot-source `common.ps1`,對每個
function 跑 happy + edge + failure case。所有 Assert 失敗即 finding。

**Test scenarios**:

- **U2.1 `Probe-GitVersion`**:
  - happy:git 2.31+ → no throw
  - failure:模擬 git < 2.31(難 — skip 或 mock)
- **U2.2 `Get-NormalizedAbsolutePath`**:
  - input `C:\Turbo\SampleGitWithSvn\SampleGit` → return `c:\Turbo\...`(lowercase drive)
  - input `/c/Turbo/SampleGitWithSvn/SampleGit`(Git Bash)→ return Windows-form lowercase drive
  - input `C:/Turbo/...`(forward slash)→ normalize
  - input `'  '` empty → throw `'empty path'`
- **U2.3 `Get-MainWorktree`**:
  - 從 main worktree cwd → return `c:\Turbo\SampleGitWithSvn\SampleGit`
  - 從 peer worktree cwd → return same main path
  - 從非 git repo cwd → throw `Not inside a git repository.`
- **U2.4 `Test-IsMainWorktree`**:main → True;dev-1 → False;remote-main → False
- **U2.5 `Test-IsSubmodule`**:non-submodule → False(沒 submodule 環境驗 True path)
- **U2.6 `Resolve-RepoPath`**:
  - relative input `src/x.csproj` → join with RepoRoot
  - absolute input → return as-is normalized
  - Git Bash style `/c/Turbo/...` → convert to Windows
  - empty → return $null
- **U2.7 `Resolve-RemoteWorktree`**:
  - `-BranchName main` → `{Name='remote-main', Branch='remote/main', Path='.../remote-main'}`
  - `-BranchName test-3` → `{Name='remote-test-3', ...}`
  - `-BranchName feature/X` → throw `Unsupported branch`
- **U2.8 `Write-Utf8NoBom`**:
  - 中文 content → file 寫出 UTF-8 bytes 無 BOM(前 3 byte 不是 `EF BB BF`)
- **U2.9 `Get-RelativePathSafe`**(v0.2.1 fix):
  - `-From C:\a -To C:\a\b\c.txt` → `b\c.txt`
  - `-From C:\a -To C:\a` → empty 或 `.`
  - non-existent path → 不 throw(URI-based,不需 path exist)
- **U2.10 `Get-ProjectIdentityHash`**(determinism + cross-OS):
  - 同 input 不同 invocation → 同 hash(determinism)
  - case variation in `CsprojRelPath`(`src/X.csproj` vs `SRC/X.csproj`)→ same hash(lowercase normalization)
  - **positive cross-worktree**:從 main + peer cwd 各 invoke → 同 hash(因 `git rev-parse --git-common-dir` 對 linked worktree 解到同一個 main `.git/`,是 git design;此 case 永遠 PASS 不是 bug,描述清楚原因)
  - **negative different repo**:另開一個 throwaway git repo `C:/tmp/throwaway-repo/`,加同 relative path `src/X.csproj`,跑 → hash 應**不同**於 SampleGit 的 hash(因 git-common-dir 不同)— 才真的驗到 cross-repo isolation
- **U2.11 `Format-IisExpressSiteName`**:
  - `-CsprojPath 'X.csproj' -IdentityHash 'abc123de'` → `X-abc123de`
  - 中文 csproj `測試.csproj` + hash → `測試-abc123de`(non-ASCII preserve)
- **U2.12 `Find-MSBuild`**:
  - env `TURBO_PLUGIN_MSBUILD_PATH` set valid → return that
  - env set invalid → throw
  - env unset → walk VS 2022 candidates,return first found
  - no env + no VS → throw `MSBuild not found`
- **U2.13 `Find-SingleCsproj`**:
  - single csproj in repo → return it
  - 0 csproj → throw
  - multiple csproj without -Project → throw with list
  - explicit `-CliProjectValue 'src/X.csproj'` → return that(ignore others)
  - config-level `[build].project` → return that
  - 4-layer lookup precedence:CLI > config > auto-detect
- **U2.14 `Resolve-ConfigValue` 4-layer lookup**:
  - CLI arg present → return CLI
  - CLI absent, config.toml present → return config
  - both absent → return $null(或 default)
- **U2.15 `Read-TurboPluginConfig` schema_version warning**:
  - config 含 `schema_version = 1` → no warning
  - config 含 `schema_version = 2` → stderr warning「schema_version=2 is not recognized」
  - guard 防 multi-emit(連跑 2 次 only 1 warning)
- **U2.16 UTF-8 console encoding**(v0.2.4):
  - 跑任意 invoke svn → 中文 output 不亂碼

**Verification**:每 sub-test Assert PASS。任一 fail = finding,P0/P1 立即修。

---

### U3. `lib/common.sh` bash helpers(direct unit test)

**Goal**:對 common.sh 內每個 function 直接 unit test,驗 bash side 跟
PS side 行為一致。

**Dependencies**:U1

**Files**:`plugins/turbo-plugin/scripts/lib/common.sh`(SUT)

**Approach**:bash test script 跑 `source common.sh` 然後 invoke functions,
比對 expected output。

**Test scenarios**:

- **U3.1 `probe_git_version`** — 同 U2.1
- **U3.2 `get_normalized_absolute_path`** — 同 U2.2(輸入正規化)
- **U3.3 `get_main_worktree`** — 從各 worktree 拿同 main path
- **U3.4 `test_is_main_worktree`** — exit 0/1 對應 True/False
- **U3.5 `resolve_repo_path`** — 路徑解析
- **U3.6 `resolve_remote_worktree`** — pipe-separated triple output `name|branch|path`
- **U3.7 `write_utf8_no_bom`** — file 寫無 BOM
- **U3.8 `format_iis_express_site_name`** — `<stem>-<hash>`
- **U3.9 `get_project_identity_hash`** — 跟 PS `Get-ProjectIdentityHash` **bit-for-bit identical** for same input(critical!)
- **U3.10 `read_turbo_plugin_config`**:
  - 無 args → 全 flat-text output(legacy)
  - 帶 section + key → 該 key 值帶 `__TP_FOUND__:` 前綴(found-empty vs not-found 分辨,v0.2.0 C3 sentinel)
- **U3.11 schema_version stderr warning** — 同 U2.15
- **U3.12 UTF-8 output behavior** — 中文不亂碼

**Verification**:每 sub-test PASS。U3.9 cross-language hash match 是 hard
requirement — fail 等於設計失敗。

---

### U4. `lib/applicationhost-helpers.ps1`(directly test 3 functions)

**Goal**:對 `Find-ApplicationhostSite` / `Save-ApplicationhostConfigAtomically`
(private)/ `Update-ApplicationhostConfig` / `Remove-ApplicationhostSite`
**4 個 function 直接 unit test**。

**Dependencies**:U1

**Files**:`plugins/turbo-plugin/scripts/lib/applicationhost-helpers.ps1`

**Approach**:準備 scratch apphost.config XML(在 jobs/test-fixtures/),
直接 invoke 4 個 function,assert XmlDocument 結果。

**Test scenarios**:

- **U4.1 `Find-ApplicationhostSite` case-insensitive match**(v0.2.3 B2):
  - apphost site name `MinimalWebApp-0eb9b6ee`,query `minimalwebapp-0eb9b6ee` → return node(`-eq` not `-ceq`)
  - query 不存在 name → return $null
  - apphost 無 `<sites>` node → return $null
- **U4.2 XPath injection prevention**(Pass 4 SF4):
  - 假設攻擊性 site name 含 single quote `O'Brien-abc12345`(不可能但測 defensive)→ Find 不 throw 不 inject
- **U4.3 `Update-ApplicationhostConfig` happy**:
  - apphost 有 site + virtualDirectory physicalPath 為 path A
  - 呼叫 Update 改成 path B
  - assert apphost 內 physicalPath 為 path B
  - return `{Updated=$true, SiteName=..., OldPaths=@(A), NewPath=B}`
- **U4.4 `Update-ApplicationhostConfig` idempotent skip**:
  - physicalPath 已是 path B,再呼叫 Update path B
  - return `{Updated=$false, Reason='physicalPath already matches; idempotent skip'}`
  - file mtime **不變**
- **U4.5 `Update-ApplicationhostConfig` site missing**:
  - apphost 無此 site → throw `Site '...' not found`
- **U4.6 `Update-ApplicationhostConfig` apphost missing**:
  - apphost 檔不在 → throw `applicationhost.config not found`
- **U4.7 `Save-ApplicationhostConfigAtomically`(private)** unique temp:
  - 連 invoke 2 次 → 2 個 temp 檔(.tmp.PID.GUID1 vs .tmp.PID.GUID2)
  - (難直驗 — 看 fixture mtime + 沒 leftover .tmp)
- **U4.8 `Remove-ApplicationhostSite` happy**:
  - apphost 有 site → 呼叫 Remove → site 從 XML 消失
  - return `{Removed=$true, SiteName=...}`
- **U4.9 `Remove-ApplicationhostSite` site missing**:
  - apphost 無此 site → return `{Removed=$false, Reason='site not found'}`(不 throw)

**Verification**:9 sub-test 全 PASS。U4.1 case-insensitive 是 v0.2.3 B2 fix
驗證;U4.4 idempotent 是 PostToolUse hook 無誤觸發前提。

---

### U5. `compute-project-identity.ps1` + `.sh`

**Goal**:整 script invocation + 跨 worktree consistency + 跨平台 parity 驗。

**Dependencies**:U2 / U3 / U4

**Files**:
- `plugins/turbo-plugin/scripts/compute-project-identity.ps1`
- `plugins/turbo-plugin/scripts/compute-project-identity.sh`

**Approach**:從 main / dev-1 / remote-main 各 cwd invoke,比對 stdout
(`PROJECT=...`、`IDENTITY_HASH=...`、`SITE_NAME=...`)。

**Test scenarios**:

- **U5.1 happy from main**:stdout 三行 PROJECT/IDENTITY_HASH/SITE_NAME
- **U5.2 happy from peer**:IDENTITY_HASH + SITE_NAME 同 main(已知 0eb9b6ee)
- **U5.3 multiple csproj without -Project**:throw with list
- **U5.4 0 csproj**:throw
- **U5.5 explicit -Project**:對應 csproj 的 identity hash
- **U5.6 outside git**:throw `Not inside a git repository.`
- **U5.7 中文 csproj 路徑**:`src/測試專案/中文.csproj` → identity hash 計算 work(non-ASCII 在 hash input)
- **U5.8 .ps1 vs .sh hash parity**:在同 cwd / 同 -Project 跑 .ps1 + .sh,
  IDENTITY_HASH **bit-for-bit identical**

**Verification**:全 PASS。U5.8 是 cross-platform critical。

---

### U6. `resolve-iis-settings.ps1` + `.sh`

**Goal**:Resolve-IisSettings function dot-source 後 invoke,驗各 field +
edge case。

**Dependencies**:U2 / U3 / U5

**Files**:`scripts/resolve-iis-settings.ps1` + `.sh`(library style,需
dot-source)

**Approach**:dot-source + invoke `Resolve-IisSettings`,assert 9 個 field
(RepoRoot / ProjectFile / IisUrl / IisScheme / IisPort / SiteRoot /
IisExpressPath / ApplicationhostConfigFile / IisConfigSiteName /
IdentityHash)。

**Test scenarios**:

- **U6.1 happy from main**:9 field 各正確
- **U6.2 happy from peer**:RepoRoot / ProjectFile / SiteRoot /
  ApplicationhostConfigFile 各指 peer 路徑;SiteName + IdentityHash 同 main
- **U6.3 csproj 缺 `<IISUrl>`**:throw `Missing <IISUrl> in project file`
- **U6.4 IISUrl 非法**:throw `Invalid <IISUrl>`(test `http://invalid url`、
  非 URL string)
- **U6.5 IISUrl port out of range**:throw `Unable to parse port`
- **U6.6 TURBO_PLUGIN_IIS_EXPRESS_PATH 無效**:`Find-IisExpressPath` 找 fallback
- **U6.7 IIS Express 不存在**(unset env + no installed)→ `IisExpressPath = $null`(不 throw,讓後續 caller 處理)
- **U6.8 ApplicationhostConfigFile 路徑計算**:有 .sln → `.vs/<sln-stem>/...`;
  無 .sln → $null
- **U6.9 .ps1 vs .sh field parity**:同 cwd 同結果 9 個 field 全 match

**Verification**:全 PASS。

---

### Phase 2 — Build, IIS, Publish

---

### U7. `build-web.ps1` + `.sh`

**Goal**:MSBuild invocation + frontend handling + 各 config override + edge
case。

**Dependencies**:U1 / U5 / U6

**Files**:`scripts/build-web.ps1` + `.sh`

**Test scenarios**:

- **U7.1 happy default config**:Debug + Any CPU → `Build succeeded` + `bin/X.dll` 出現
- **U7.2 -Configuration Release**:Release build artifact
- **U7.3 -Platform 變更**:測 x64(若 csproj 支援)— 應該 fail loudly 若不支援
- **U7.4 explicit -Project**:對指定 csproj build
- **U7.5 0 csproj**:throw(U2.13 已覆蓋的 helper-level,這裡再從 script invocation 驗)
- **U7.6 multiple csproj without -Project**:throw with list
- **U7.7 TURBO_PLUGIN_MSBUILD_PATH 無效**:throw 訊息含 path
- **U7.8 [frontend] config 缺**:略過 pack-content,直接 MSBuild
- **U7.9 [frontend] dir 缺**(config 有 path 但 dir 不存在):fail loudly
- **U7.10 [frontend] install_command 失敗** exit 非 0:script 傳出非 0 exit
- **U7.11 中文 csproj path**:`src/測試專案/中文.csproj` → MSBuild 收到正確
  filename + build 成功
- **U7.12 .ps1 vs .sh parity**:同 csproj build 結果 bin/X.dll mtime 都更新

**Verification**:全 PASS。U7.10 + U7.11 是高風險 edge。

---

### U8. `pack-content.ps1` + `.sh`(security-critical tokenization)

**Goal**:tokenized invocation 防 shell injection + 邊界情境。

**Dependencies**:U1

**Files**:`scripts/pack-content.ps1` + `.sh`

**Test scenarios**:

- **U8.1 happy install + build success**:`install_command = "npm install"; build_command = "npm run build"` → 各跑成功(若無 frontend 可 mock)
- **U8.2 install_command 單 token**(Pass 4 P0 finding):
  - `install_command = "yarn"` → 不 throw,正確 invoke `yarn`,不傳 garbage args
- **U8.3 install_command 含 shell metachar 完整套**(security):各 metachar 預先 `mkdir` canary `C:/tmp/SHOULD-NOT-EXIST-<n>`,跑完 assert 仍存在:
  - (a) **semicolon `;`**:`install_command = "echo a; rm -rf C:/tmp/SHOULD-NOT-EXIST-1"`
  - (b) **pipe `|`**:`"echo a | rm -rf C:/tmp/SHOULD-NOT-EXIST-2"` → echo 印 literal `a | rm ...`,canary 仍存在
  - (c) **subshell `$(...)`**(PowerShell-specific):`"npm $(Remove-Item -Recurse C:/tmp/SHOULD-NOT-EXIST-3)"` → 不 expand subshell
  - (d) **subshell backtick**(legacy):`'npm \`rm -rf C:/tmp/SHOULD-NOT-EXIST-4\`'` → 不 expand
  - (e) **compound `&&`**:`"npm && rm -rf C:/tmp/SHOULD-NOT-EXIST-5"` → `&&` 為 literal arg
  - (f) **`||`**:`"npm || rm -rf C:/tmp/SHOULD-NOT-EXIST-6"`
  - (g) **null byte injection**:`"npm$([char]0x00) rm -rf ..."` → 不分 token 為 rm
  - **bash 端同套**(U8.4 originally;移到此處):每 metachar 餵給 `pack-content.sh` 驗 — bash IFS / `$()` / backtick 在 bash 是 shell expand,需確認 `.sh` 把 install_command 當 single command 跑或同 PS 一樣 split 處理
- **U8.4 install_command empty**:skip 進 build_command
- **U8.5 install_command 空白 only**:skip
- **U8.6 install_command 失敗 exit propagate**:`install_command = "exit 5"`
  → script exit 5
- **U8.7 frontend dir 不存在**:fail loudly,訊息含路徑
- **U8.8 .ps1 vs .sh parity**:相同 install_command → 相同行為(若可)

**Verification**:全 PASS。U8.2 + U8.3 是 v0.2.0 sec-invoke-expression fix
的核心 regression test。

---

### U9. `publish-web.ps1` + `.sh`

**Goal**:publish flow + .pubxml lookup + edge case。

**Dependencies**:U1 / U5 / U7

**Files**:`scripts/publish-web.ps1` + `.sh`

**Test scenarios**:

- **U9.1 happy with FileSystem.pubxml**(已 fixture):MSBuild publish 成功 +
  stdout 含 `PUBLISH_OUTPUT_PATH=<absolute path to bin\PublishOutput>`
- **U9.2 no .pubxml**:throw `No .pubxml found`
- **U9.3 multiple .pubxml**:throw with list
- **U9.4 --profile 指定**:對應 profile build
- **U9.5 --profile 無效 name**:throw
- **U9.6 publish output cleanup**:`DeleteExistingFiles=True` 應清舊
- **U9.7 frontend pack 整合**:[frontend] config 在 → pack-content 也跑
- **U9.8 中文 .pubxml 路徑**:可選
- **U9.9 .ps1 vs .sh parity**:publish output bytes-identical

**Verification**:全 PASS。

---

### U10. `start-iis.ps1` + `.sh`(邏輯驗,不需真實 IIS 啟動)

**Goal**:start-iis 邏輯各 edge case 驗,**fail-fast guard 為主**,真實啟動
可選 skip。

**Dependencies**:U6

**Files**:`scripts/start-iis.ps1` + `.sh`

**Test scenarios**:

- **U10.1 apphost 不存在**:fail loudly with 訊息 + 建議跑 /tp-setup
- **U10.2 site 在 apphost 缺**(Pass 2 adv-002):fail-fast,訊息含 site name
- **U10.3 port 已占**(他人 process 在 51999):fail with port 占用訊息
- **U10.4 同 port + 同 site name(cross-worktree self-heal, R15a)**:
  - 模擬 fake iisexpress(假 commandLine /site:<same>)→ start-iis 應該停舊啟新
- **U10.5 同 port + 不同 site name(R15b 別 project 撞 port)**:fail loudly,**不殺別人**
- **U10.5b prefix attack**:foreign site name 是 `MinimalWebApp-0eb9b6ee-extra`(legit name 為 prefix)→ stop-iis 不殺(因 `-eq` exact match);verify
- **U10.5c hex-stem overlap**:csproj 命名 `MyApp-deadbeef.csproj`,stem `MyApp-deadbeef`,site `MyApp-deadbeef-cafe1234`;同時 fake 另一個 site `MyApp-deadbeefdeadbeef` 跑 → confirm orphan secondary scan 用 `^MyApp-deadbeef-[0-9a-f]{8}$` 不會 false-positive 抓到後者
- **U10.6 process spawn 後 prematurely exit**(Pass 1 REL-002 HasExited check):
  - 模擬手工 sleep 後 kill iisexpress → script `Wait-PortListening` 內偵測
    HasExited → throw `IIS Express process (PID xxx) exited prematurely`
- **U10.7 listening_timeout_seconds = 1 fast fail**(config.toml):
  - 設 1 秒 timeout → 啟不起 IIS 時 1 秒就 fail
- **U10.8 listening_timeout_seconds = 0**(v0.2.0 adv-011):
  - 設 0 → 立即 timeout(不退回 default 30)
- **U10.9 anchored regex /site: match**(Pass 2 C2 + sec):
  - 同 stem 不同 hash 不誤殺(eg `MinimalWebApp-0eb9b6ee` 不 match `MinimalWebApp-deadbeef`)
- **U10.10 中文 csproj-stem 的 IIS Express site name**:可選
- **U10.11 .ps1 vs .sh parity**

**Verification**:fail-fast 各 path PASS;真實 IIS 啟動非範圍。

---

### U11. `stop-iis.ps1` + `.sh`

**Goal**:stop 各 case + orphan secondary scan。

**Dependencies**:U10(模擬 process 用)

**Files**:`scripts/stop-iis.ps1` + `.sh`

**Test scenarios**:

- **U11.1 no instance**:`No IIS Express process found for site '<name>'.` exit 0
- **U11.2 site 匹配** → Stop-Process + 訊息
- **U11.3 同 stem 不同 hash orphan secondary scan**(Pass 1 #20):
  - 模擬 process `/site:MinimalWebApp-deadbeef` 在跑 + 主 site name
    `MinimalWebApp-0eb9b6ee`
  - stop-iis(用主 identity)應該 emit 「撈不到 instance,但偵測到下列同
    csproj-stem 但不同 hash 的 instance」訊息列 deadbeef
- **U11.4 `$Matches[1]` clobber regression**(v0.2.1 fix):
  - 同 U11.3 場景下,confirm orphan filter 確實列 deadbeef
    (修前會錯列**所有** iisexpress instance,因 `$Matches[1]` 被 second
    `-match` 洗成 $null,filter 永遠通過)
- **U11.5 anchored regex 精準**(Pass 2 C4 + sec):
  - 同 port 不同 site name 別 project iisexpress → stop **不殺**
- **U11.6 中文 site name**:可選
- **U11.7 .ps1 vs .sh parity**

**Verification**:U11.4 是 P0 regression test。

---

### U12. `check-iis-listening.ps1` + `.sh` + `get-target-url.ps1` + `.sh`

**Goal**:輔助 script 行為驗。

**Dependencies**:U6

**Files**:`scripts/check-iis-listening.ps1` + `.sh` + `scripts/get-target-url.ps1` + `.sh`

**Test scenarios**:

- **U12.1 check-iis-listening port LISTEN**:fake port listener → script 印 listening + exit 0
- **U12.2 check-iis-listening timeout**:no listener → 超時後 exit 非 0
- **U12.3 get-target-url 從 csproj**:print `http://localhost:51999/`
- **U12.4 get-target-url csproj 缺 IISUrl**:fail
- **U12.5 .ps1 vs .sh parity**

---

### U13. `cleanup-orphan-iis.ps1`(Windows-only,no .sh sibling besides delegate)

**Goal**:enumerate + remove + PARTIAL_FAILURE 全 case。

**Dependencies**:U4 / U10 / U11

**Files**:`scripts/cleanup-orphan-iis.ps1` + `scripts/cleanup-orphan-iis.sh`(delegate)

**Test scenarios**:

- **U13.1 enumerate no orphan**:`No orphan IIS Express instances or applicationhost.config sites found.` exit 0
- **U13.2 enumerate process orphan**:fake process → output `ORPHAN: <name> process pid=<n>` 一行
- **U13.3 enumerate xml orphan**:apphost 加 fake site → output `ORPHAN: <name> xml pid=-` 一行
- **U13.4 enumerate both**:process + XML 同 name → `ORPHAN: <name> both pid=<n>`
- **U13.5 -RemoveSite single match**:殺 process + remove XML node,exit 0
- **U13.6 -RemoveSite name 不在 orphan list**:exit non-0,訊息「not in orphan list」
- **U13.7 -RemoveAll multiple**:全清 + exit 0
- **U13.8 -RemoveAll partial failure**(Pass 4 B5):
  - lock apphost(`[System.IO.File]::Open` FileShare.None)→ Remove 第二個 fail
  - assert stdout 含 `PARTIAL_FAILURE: failed=1 sites=<that-name>`
  - assert stderr 含 per-site reason
  - assert exit code = **2**(not 1)
- **U13.9 stemPattern regex-escape 完整套**(Pass 4 SF2 + SEC-003):每 metachar 各 csproj stem 一條,測 fake-site negative match:
  - (a) `.` — csproj `My.Test.csproj` stem `My.Test` → 對 fake site `MyXTestXabc12345` **不** match
  - (b) `+` — csproj `App+v2.csproj` stem `App+v2` → 對 `Apv2-deadbeef` **不** match(原本 `+` 為 quantifier 會誤匹配)
  - (c) `[` `]` — csproj `Feature[X].csproj` stem `Feature[X]` → 對 `FeatureX-deadbeef` **不** match(原本 char class)
  - (d) `(` `)` — csproj `Mod(A).csproj` stem `Mod(A)` → 對 `ModA-deadbeef` **不** match
  - (e) `{` `}` — csproj `App{1}.csproj` stem `App{1}` → 對 `App1-deadbeef` **不** match
  - (f) `^` — csproj `Base^Hook.csproj` stem `Base^Hook` → 對 `BaseHook-deadbeef` **不** match
  - (g) `$` — csproj `Var$.csproj` stem `Var$` → 對 `Var-deadbeef` **不** match
  - (h) `*` `?` — csproj `Wild*.csproj` / `Maybe?.csproj` → 同
  - (i) `|` — csproj `A|B.csproj` → 同
  - (j) `\` — csproj `Path\X.csproj`(Windows 不允許但 defensive)→ 同
- **U13.10 -RemoveAll + -RemoveSite 同時傳**:script 應拒(or 優先一個 +
  document)
- **U13.11 .sh delegate**:`cleanup-orphan-iis.sh -RemoveAll` 經 ps1-delegate 正確傳 switch parameter

**Verification**:全 PASS。U13.8 PARTIAL_FAILURE 是 critical structured token。

---

### Phase 3 — SVN Bridge

---

### U14. `pull-from-svn.ps1` + `.sh`

**Goal**:pull 各 path + 中文 commit message。

**Dependencies**:U1

**Files**:`scripts/pull-from-svn.ps1` + `.sh`

**Test scenarios**:

- **U14.1 already up-to-date**:exit 0 + `Already up to date`
- **U14.2 SVN ahead**:svn update 拉 + git fetch + git merge fast-forward
- **U14.3 merge conflict + auto-rollback**(Pass 4 B6):
  - 預先製造衝突(main + remote-main 兩邊同檔同行改)
  - pull → svn update OK → git merge fail → `git merge --abort` + checkout 原 branch
  - emit `Merge conflict detected. ... Conflicting files: <list>`
- **U14.4 rollback failure INCONSISTENT_STATE**(Pass 4 B3 — 但 v0.2.0 B3
  fix 拒絕加 structured token,留 freeform):
  - 製造衝突 + 預先卡住 `.git/index.lock`(touch 然後 chmod readonly?)
  - pull → merge --abort fail → script 印 `INCONSISTENT_STATE: abort_exit=<n> checkout_exit=<n>`(若 v0.2.3 已 land)或 freeform `inconsistent state`(若仍 freeform)
- **U14.5 --branch invalid**:throw `Unsupported branch`
- **U14.6 --branch test-N not exist**:remote worktree 不在 → fail loudly
- **U14.7 SVN server unreachable**(fake URL):fail loudly
- **U14.8 中文 commit message in SVN**:r17 已是中文(mojibake),v0.2.4 fix
  後 svn log output **不亂碼**(用 svn-log U18 驗;此 unit confirm)
- **U14.9 .ps1 vs .sh parity**

**Verification**:U14.3 + U14.4 是 v0.2.0-v0.2.3 reliability fix 的 regression test。

---

### U15. `push-to-svn-prepare.ps1` + `.sh`(SHA pin 寫入 + token 行為)

**Goal**:prepare 各狀態。

**Dependencies**:U14(remote worktree ready)

**Files**:`scripts/push-to-svn-prepare.ps1` + `.sh`

**Test scenarios**:

- **U15.1 happy prepare**:
  - svn rev check pass + merge staged
  - stdout 印 `COMMITS\n<hash>|<subject>\n...\n\nFILES\n<status>|<path>\n...`
  - **`<remote-path-gitdir>/MERGE_HEAD.tp_branch_sha`** 寫入 source branch HEAD SHA(critical — Pass 3 F1 fix)
  - **gitdir 透過 `git rev-parse --absolute-git-dir`** 取(不是 `Join-Path
    $remote.Path '.git'`),這樣 linked worktree 的 `.git` pointer file 場景才 work
- **U15.2 dirty working tree**:reject + 提示 `please commit / stash`
- **U15.3 SVN HEAD ahead of local**:fail loudly + 提示先 pull
- **U15.4 nothing to push**:exit early + 訊息 `Nothing to push`
- **U15.5 PENDING_MERGE_DETECTED**(已有 stage merge state):
  - stdout 印 `PENDING_MERGE_DETECTED <remote-path>` + exit 0(structured token,
    Pass 4 F3 fix for .sh)
- **U15.6 merge conflict during prepare**(rare,通常不同 branch 不衝突 — skip)
- **U15.7 bash .sh PENDING_MERGE_DETECTED parity**(v0.2.0 F3):
  - .sh 同 .ps1 emit `PENDING_MERGE_DETECTED <path>` exit 0
- **U15.8 bash .sh SHA pin write parity**(v0.2.0 F2):
  - .sh 跑 prepare → 同樣寫 `<gitdir>/MERGE_HEAD.tp_branch_sha`
- **U15.9 中文 commit subject in COMMITS section**:中文 subject 在 stdout
  不亂碼(v0.2.4 fix)

**Verification**:U15.1 + U15.7 + U15.8 是 SHA pin 設計 land 驗證;U15.5 是
SKILL three-option choreography 的前提。

---

### U16. `push-to-svn-commit.ps1` + `.sh`(中文檔名 + SHA pin guard + cleanup)

**Goal**:commit 各 path,**含使用者點出的中文檔名 push**。

**Dependencies**:U15

**Files**:`scripts/push-to-svn-commit.ps1` + `.sh`

**Test scenarios**:

- **U16.1 happy commit**:UTF-8 no-BOM 訊息 + svn commit + 印 `Pushed to SVN r<n>`
- **U16.2 SHA pin match**:pinned == current → 正常 commit
- **U16.3 SHA pin mismatch**(prepare → 在 commit 前外部加新 commit):
  - throw `Branch '...' has new commits since prepare (pinned: <8hex>, current: <8hex>)`
  - **short-form Substring guard**(v0.2.0 AF3):pinned 不足 8 char 不 throw
- **U16.4 SHA pin file 不在**:script 跳過 pin check,正常 commit(legacy
  compat,Pass 2)
- **U16.4b SHA pin tampered content**(SEC-004):
  - (a) 寫 4096-byte 字串到 pin file → script 應 reject(訊息「pinned SHA not 8-hex / malformed」)而非 silently accept
  - (b) 寫含 embedded newline 的 SHA(`abc12345\nMORE_DATA`)→ `.Trim()` truncate 第一行,若剛好不 match current → 觸發 mismatch throw;若 match 則 silent OK(file system level risk note)
  - (c) pin file 為 symlink 指到 `C:/Windows/win.ini` → `Get-Content -LiteralPath` 跟著 symlink 讀;assert 行為(讀 target 內容 ≠ SHA → mismatch throw)正確不 hang;若不放心改 `-NoFollow` 或檢查 symlink reparse point
- **U16.4c .git 為 symlink 邊界**(SEC-004 advisory):若 `.git` 在 UNC 網路 share、且 share 為 world-writable → 攻擊者可 race 替換 pin file。本 plan **不直驗**此 case(需特殊 lab 環境),只在 plan threat-model 段標記為 deferred
- **U16.5 SHA pin cleanup on success**(v0.2.0 + v0.2.1 + v0.2.2 P1F1):
  - 成功 push 後 `Test-Path <gitdir>/MERGE_HEAD.tp_branch_sha` 為 False
- **U16.6 SHA pin RETAIN on failure**(v0.2.0 WF2 + v0.2.2 P1F1):
  - 故意讓 svn commit fail → pin file **仍存在**(retry path)
- **U16.7 noCommit path pin cleanup**(v0.2.2 P1F1):
  - 全 git-ignore 情境(`svn status` 為空)→ exit 0 + pin file 同樣被清(PS1
    跟 .sh 一致)
- **U16.8 中文 commit message UTF-8 no-BOM**:
  - 訊息含「修中文檔案的 bug」→ svn log 顯示**不亂碼**
- **U16.9 ⭐ 中文檔名 add + commit**(user 點出):
  - 預先在 test/rc-N 加新檔 `測試檔案-${rand}.txt`(內容 ASCII)
  - git commit 該檔
  - 跑 push-to-svn-commit → svn add 該檔 → svn commit
  - **assert server bytes(URL form 直接打 server,不靠 working-copy index)**:
    - `svn ls file:///C:/Turbo/SampleGitWithSvn/SampleSvnServer/test-script-N/` 含 `測試檔案-${rand}.txt`(**正確檔名,非 mojibake 也非 quote-printable**)
    - `svn log -v --xml -r HEAD file:///.../test-script-N/` 解析 `<path>` element 確認 server 端 bytes 為正確 UTF-8
- **U16.10 中文目錄名 + 中文檔名**:
  - 加 `測試目錄/中文檔.txt` → svn add --parents → 兩層都正確
  - 同 U16.9 用 URL form 驗 server bytes:`svn ls file:///.../test-script-N/測試目錄/` 含 `中文檔.txt`
- **U16.11 svn status 各 status char 處理**:
  - `?` → svn add
  - `!` → svn delete
  - `M` → 進 commit targets
  - git-ignored → skip(訊息 `Skipping git-ignored ($statusChar): $filePath`)
- **U16.12 svn add --parents needed**(nested dir):
  - 新檔在 `src/new-dir/x.txt`(new-dir 也新)→ svn add --parents
- **U16.13 .sh SHA pin parity**(v0.2.0 F2):
  - .sh 跑 commit 同樣 read pin + 比對 + cleanup
- **U16.14 .sh svn status capture-into-var**(v0.2.3 P1F2):
  - svn status 失敗時不再 silent exit 0,改 emit error + exit 1

**Verification**:U16.9 + U16.10 是 user 點出的 critical missing test;U16.6
+ U16.7 是 v0.2.x 連續 fix 的 regression coverage;U16.13 + U16.14 是
cross-platform parity。

---

### U17. `create-remote-test.ps1` + `.sh`(rollback + svn:ignore over-sensitivity)

**Goal**:create 各 path。

**Dependencies**:U1

**Files**:`scripts/create-remote-test.ps1` + `.sh`

**Test scenarios**:

- **U17.1 happy SVN path 不存在 → create + checkout + propset**:
  - 新 SVN branch + git branches + worktree 都建好
- **U17.2 happy SVN path 已存在 → checkout only**:略過 svn copy
- **U17.3 svn:ignore not found on remote-main**(v0.2.2 fix):
  - remote-main 無 propset → 不 throw,fall through 用 default `.git\n.gitignore`
- **U17.4 ERR-trap rollback**(Pass 3 WF1 + Pass 4 B5):
  - 故意傳無效 SVN URL → svn copy fail → rollback git branches + worktree
- **U17.4b SVN URL path traversal / scheme switching**(SEC-005,**expected FAIL → 預期生 finding**):
  - (a) `-SvnUrl file:///C:/Windows/System32/`(path traversal 出 repo root)→ 目前 script line 73 直接 `svn copy $mainSvnUrl $SvnUrl` 不做 prefix 驗證 → svn 可能成功 copy 到此 path,污染 system32(雖然 ACL 一般擋住但 defense-in-depth)
  - (b) `-SvnUrl http://attacker.example/fake-svn` → scheme 切換給 svn copy 跨 server。svn 本身會 fail,但 plugin design 不該允許這條
  - **Action item**:此 finding 加進 v0.2.5,fix「`create-remote-test.ps1` 開頭加 `svn info <repoRoot> --show-item repos-root-url` 拿 trusted base URL,assert `$SvnUrl.StartsWith($baseUrl)` 否則 throw」
- **U17.5 trap 位置 BEFORE first git mutation**(**expected FAIL — 預期會生 finding**):
  - CHANGELOG v0.2.3 並沒有 "B1 trap-position" entry,本 plan 之前誤引用
  - 現行 code(`create-remote-test.ps1` line 51-58):`git branch $remoteBranch $initCommit` + `git branch $testBranch 'main'` + `git worktree add` **outside 內層 try**;若 line 51 fail → 跳 OUTER catch(line 118)只 emit stderr + exit 1,**沒 rollback**
  - 模擬:傳一個 SVN URL 不存在的 source 給 `--init-from-rev`(或讓 `$initCommit` 是 invalid SHA)→ git branch fail → 預期看到沒 rollback,有殘留 git branch(部分 mutation)
  - **Action item**:此 finding 加進 v0.2.5,fix 方向「把內層 try 往前包到 line 51 第一個 git mutation,讓 trap 涵蓋 git branch 失敗」
- **U17.6 PARTIAL_ROLLBACK emission**(Pass 4 B5):
  - 部分 cleanup fail → emit `PARTIAL_ROLLBACK: worktree-remove=<n> branch-D-remote=<n> branch-D-test=<n>`
- **U17.7 --n 撞名 existing**:fail loudly
- **U17.8 -N invalid**(non-integer):reject
- **U17.9 .ps1 vs .sh parity**(rollback path 也 parity)

**Verification**:U17.3 PASS = v0.2.2 fix regression test。

---

### U18. `reset-remote-test.ps1` + `.sh`

**Goal**:diff-only preview + 實 reset + edge。

**Dependencies**:U17

**Files**:`scripts/reset-remote-test.ps1` + `.sh`

**Test scenarios**:

- **U18.1 happy --diff-only preview**:
  - test-N 領先 main 3 commits,main 領先 test-N 5 commits → stdout 印
    `LOSE: 3 commits ...` + `GAIN: 5 commits ...`
  - **無 git mutation**(working tree clean,test-N HEAD 不動)
- **U18.2 happy actual reset**(無 --diff-only):
  - `git reset --hard main` 跑 → test-N SHA == main SHA + `Reset test-N to main.` 印
- **U18.3 already equal**:`Branches already equal — nothing to reset.` exit 0
- **U18.4 --branch invalid**:reject
- **U18.5 .ps1 vs .sh parity**

**Verification**:U18.1 + U18.3 cover SKILL Procedure 三步 fix(v0.2.3 B1)
前 script-level 的行為。

---

### Phase 4 — SVN Tools

---

### U19. `svn-ignore.ps1` + `.sh`

**Goal**:svn-ignore 全套(list / -Add / -Remove / 多 worktree / partial failure)。

**Dependencies**:U1

**Files**:`scripts/svn-ignore.ps1` + `.sh`

**Test scenarios**:

- **U19.1 list 無 propset**:`No SVN ignore patterns at '.'` exit 0
- **U19.2 -Add single pattern**:propset + commit on all remote worktree
- **U19.3 -Add multiple patterns at once**(`-Add "*.tmp" -Add "*.log"`):
  - 一次 SVN commit 含兩 pattern
- **U19.4 -Remove single from propset**(or propdel if only one):
- **U19.5 -Remove multiple**:
- **U19.6 --path subdirectory**:對子目錄 propset
- **U19.7 2-phase commit + partial failure**(Pass 2 F26 + Pass 3 WF4):
  - 多 remote worktree(remote-main + remote-test-N)
  - 第二個 commit 故意 lock(rename SampleSvnServer/db 短時間)
  - assert pass-1 全 propset OK,pass-2 第一個 commit OK,第二個 fail
  - **per-iteration capture**(不 abort),loop 結束後 emit structured error 列
    succeeded vs failed list,exit 1
- **U19.8 中文 ignore pattern**(`*.測試`):propset + commit + list 都正確
  (svn 編碼)
- **U19.9 .ps1 vs .sh parity**:同 invocation → 相同 propset + 相同 commit

**Verification**:U19.7 PASS = v0.2.0 partial-failure design land;U19.8 是
encoding cross-cutting cover。

---

### U20. `svn-log.ps1` + `.sh`

**Goal**:svn-log 各 case + 中文 commit message 渲染。

**Dependencies**:U1

**Files**:`scripts/svn-log.ps1` + `.sh`

**Test scenarios**:

- **U20.1 default Limit 50**:列最近 50 條
- **U20.2 -Limit 3**:列 3 條
- **U20.3 -Limit 'abc' invalid**(.ps1):PowerShell param binding reject
- **U20.4 -Limit -5 negative**:script throw `Limit must be a positive integer`
- **U20.5 --verbose / -VerboseOutput**:列改動檔
- **U20.6 -Branch invalid**:reject
- **U20.7 header (from /trunk:rN) strip**(Pass 2 C7):
  - svn copy 後的 log 含 `r<n> | author | date (from /trunk:r<m>)`
  - script 應 strip ` (...)` 只在 header line,body line 不動
- **U20.8 中文 commit message 不亂碼**(v0.2.4 fix):
  - r17 (中文 commit) → stdout 顯示中文正確
- **U20.9 .ps1 vs .sh parity**

**Verification**:U20.7 PASS = Pass 2 C7 fix regression;U20.8 PASS = v0.2.4
UTF-8 console output fix regression。

---

### Phase 5 — Hooks

---

### U21. `hooks/posttooluse-enterworktree.ps1` + `.sh`

**Goal**:hook 各 stdin scenario + apphost update 行為 + count off-by-N。

**Dependencies**:U4

**Files**:`scripts/hooks/posttooluse-enterworktree.ps1` + `.sh`

**Test scenarios**:

- **U21.1 happy stdin** worktreePath valid + marker exists + apphost source exists + csproj exists:
  - apphost copy + update physicalPath
  - **stdout JSON `{"systemMessage":"turbo-plugin: refreshed applicationhost.config for 1 site(s) in <path>"}`**(`1 site(s)` 不是 4 — v0.2.3 fix)
  - exit 0
- **U21.2 empty stdin**:emit `{}` exit 0,不 throw
- **U21.3 malformed JSON**:emit `{}` exit 0
- **U21.4 worktreePath missing in JSON**:emit `{}` exit 0
- **U21.5 worktreePath 不存在 directory**:emit `{}` exit 0
- **U21.5b worktreePath 是合法但 repo 外的 directory**(SEC-006):
  - 餵 `{"tool_response": {"worktreePath": "C:\\Windows\\System32"}}` → hook 應 emit `{}` exit 0 不掃 system32 內容(`.turbo-plugin` marker 在 system32 不會在,line 32 marker check 應守住)
  - assert hook 沒 enumerate `.csproj` in system32(看 process trace 或 mock `Find-SingleCsproj` log)
- **U21.5c pathological JSON 大 payload**(SEC-006):
  - 10 MB deeply-nested JSON(`{"a":{"a":{...}}}` 10000 層)→ hook 5 秒內結束、無 OOM、emit `{}` exit 0
- **U21.5d null byte injection**(SEC-006):
  - 餵 `{"tool_response": {"worktreePath": "C:\\valid evil"}}` → `ConvertFrom-Json` 應 reject 或 `Get-NormalizedAbsolutePath` throw 乾淨;不該 silent accept
- **U21.6 marker .turbo-plugin/ missing**:emit `{}` exit 0
- **U21.7 apphost source missing**:emit `{}` exit 0
- **U21.8 no csproj in worktree**:emit `{}` exit 0
- **U21.9 multi-csproj count correct**:
  - 預先建 2 個 csproj + 對應 2 個 site in apphost → 都 update → count=2
- **U21.10 idempotent skip**:
  - 第一次 fire 後 apphost mtime A
  - 再 fire(physicalPath 已正確)→ updates Updated=false,**emit `{}` 不
    emit systemMessage**,apphost mtime 不變(Pass 1 T002)
- **U21.11 atomic save .tmp 唯一性 deterministic surrogate**(Pass 4 AF2):
  - **原 design「兩 hook 並行 fire」agent autonomous 跑不出來**(需 Start-Job + timing-dependent)。改 deterministic surrogate:
  - invoke `Save-ApplicationhostConfigAtomically` 兩次 in rapid sequence(同一 PowerShell session 連 call,但兩次 build 不同 XmlDocument 內容)
  - assert (a) 兩次 return 都成功(no throw)、(b) target apphost 最終內容 = 第二次的(後寫贏)、(c) **沒 leftover `.tmp.*` file** in target dir(用 `Get-ChildItem '*tmp*' -ErrorAction SilentlyContinue` 確認 = $null)、(d) instrument 在 helper 加暫 log 印 GUID,確認兩次 GUID 不同
  - 真正 concurrency contention 留 manual acceptance(plan 不涵蓋)
- **U21.12 .sh stdin pipe `cat | powershell ...`**(Pass 1 REL-001):
  - sh sibling 餵 stdin → 正確傳到 ps1 處理(已 script-level 證實)
- **U21.13 .sh on non-Windows fail-safe**:
  - 在 fake non-Windows env(Git Bash 假裝)→ hook exit 0,不 block
- **U21.14 hooks.json bash command quoting 完整套**(v0.2.0 SF4 + SEC-011):
  - (a) **space**:`${CLAUDE_PLUGIN_ROOT}` 含 space(`Program Files\...`)→ hook 仍正確 invoke
  - (b) **single-quote**:plugin 安裝於 `C:\Users\O'Brien\...` → hook 仍正確 invoke,不 break shell quoting
  - (c) **subshell metachar `$()`**:plugin 安裝路徑含 `$(evil)`(理論上 file system 允許)→ hook 不 evaluate
  - 先確認 hooks.json 用哪種 quoting strategy(double-quoting / single-quoting),test 對應 strategy 的 holdout case

**Verification**:全 PASS。U21.1 site count = 1 是 v0.2.3 P3 regression。

---

### U22. `hooks/sessionstart.ps1` + `.sh`

**Goal**:sessionstart 三分支 + fail-safe + main path interpolation。

**Dependencies**:U4

**Files**:`scripts/hooks/sessionstart.ps1` + `.sh`

**Test scenarios**:

- **U22.1 Branch (i) main no marker**:
  - 從主 worktree(無 `.turbo-plugin/`)→ stdout JSON 含「請執行 /tp-setup」
- **U22.2 Branch (ii) peer no marker**:
  - 從 peer worktree(無 `.turbo-plugin/`)→ stdout JSON 含**真正 main path**
    (`c:\Turbo\SampleGitWithSvn\SampleGit` 之類絕對路徑,**非字面 `$mainPath`** —
    Pass 2 AF1 fix)
- **U22.3 Branch (iii) marker 在但 dbhub.local.toml 缺**:
  - 從 main / peer with marker but no dbhub.local.toml → stdout JSON 含
    「請複製 dbhub.example.local.toml ...」
- **U22.4 marker + dbhub.local.toml 都在**:
  - emit `{}` exit 0,no systemMessage(silent)
- **U22.5 sessionstart.ps1 marker-present auto-fix applicationhost.config**(Pass 1 #14 + Pass 2 M-08):
  - **precondition 修正**:apphost auto-fix 在 `if (Test-Path $markerDir)` block 裡(line 31-64),**marker 必須 EXISTS** 才跑(原 plan 寫 marker missing 走不到此 path)
  - 場景:marker 存在 + `.turbo-plugin/applicationhost.config` 在 + `.vs/<sln-stem>/config/applicationhost.config` target 在但 `physicalPath` 為 stale(指到舊路徑)
  - Action:開新 session 在 SampleGit/
  - **Expected**:hook 在 line 50 呼叫 `Update-ApplicationhostConfig` 把 physicalPath 更新到當前 worktree;不 emit systemMessage(silent fix);apphost mtime 更新
  - **Note**:sessionstart.ps1 line 5 直接 import applicationhost-helpers.ps1,呼叫同一個 `Update-ApplicationhostConfig`,**不是「import PostToolUse」**,共享 helper 而已
- **U22.6 .sh on Windows powershell wrapped in if**(Pass 4 SF5):
  - powershell 失敗時 exit_code 仍捕到,ERR trap 不 shadow diagnostic
- **U22.7 .sh on non-Windows ERR-trap fail-safe**(Pass 3 WF3):
  - sh 在 non-Windows env 故意製造 common.sh source fail → exit 0,不 block session
- **U22.8 中文 systemMessage 不亂碼**:
  - sessionstart 訊息含中文 → Claude Code 收到 unicode-correct JSON
- **U22.9 .turbo-plugin/ junction/symlink defense-in-depth**(SEC-007 advisory,low):
  - `cmd /c mklink /J SampleGit\.turbo-plugin C:\Windows\Temp\evil-payload`(junction 指外部含 malformed apphost)
  - 開 session → hook 進 marker-present branch、嘗試讀 evil-payload 的 applicationhost.config
  - **Expected**:hook 對 malformed XML graceful fail(parse error catch + emit `{}` exit 0),不寫回 evil junction target
  - 限制:realistic threat 需 attacker 有 repo write perm;標 defense-in-depth advisory

**Verification**:U22.2 main path interpolation 是 v0.2.1 fix regression test。

---

### Phase 6 — Cross-cutting

---

### U23. Encoding edge cases — 只測 prior unit 沒涵蓋的 2 條

**Goal**:U23 收斂成「prior unit 沒涵蓋的 encoding edge」,不重跑已 inline 驗過的部分。

**Dependencies**:U5 / U16 / U19 / U20(已 inline 驗 unit-specific encoding;本 unit 只補 missing piece)

**Files**:跨 script

**已 covered by prior unit(本 unit 不重跑,pass confirmation 即可)**:
- ~~U23.1 中文 csproj filename 全流程~~ → 由 **U5.7** covered
- ~~U23.2 中文 commit subject git→svn→svn-log~~ → 由 **U16.8 + U20.8** covered
- ~~U23.3 中文 filename git status / svn add / svn ls~~ → 由 **U16.9 + U16.10** covered(FEAS-002 已修 URL form)
- ~~U23.4 中文 svn:ignore pattern~~ → 由 **U19.8** covered
- ~~U23.5 中文 directory name~~ → 由 **U5.7 variant** covered

**Test scenarios — 唯一兩條新增**:

- **U23.6 PowerShell argv → svn.exe byte-level**(根因驗,prior unit 沒涵蓋):
  - 用 .NET `Process.Start` 透過 PowerShell native exe invocation 傳含中文 argv → svn.exe 收到正確 UTF-8 bytes(`[Console]::OutputEncoding` v0.2.4 fix 只管 stdout 解碼,**InputEncoding / argv encoding 沒明確設定**;此 test 驗 argv 是否也正確)
  - 若 mojibake,加 fix `[Console]::InputEncoding = [System.Text.Encoding]::UTF8` 到 `common.ps1`,或測 native exe argv UTF-8 設定
  - .sh on Windows Git Bash 同套(原 U23.8):從 bash invoke 含中文 argv 給 svn.exe,驗 server bytes 正確
- **U23.7 BOM check sanity re-run**(prior unit 沒涵蓋,避免跟 U1.4/U25.1 重複):
  - 直接 re-run `tools/lint-ps-compat.ps1 -Path plugins/turbo-plugin` 確認 v0.2.1 加 BOM 的 9 個檔(build-web / publish-web / start-iis / stop-iis / svn-ignore / posttooluse-enterworktree / sessionstart / applicationhost-helpers / common)仍是 BOM 開頭、無 regression
  - **不**做 byte-level audit(已被 lint 涵蓋);只 sanity-check 9-file set,差異視為 regression finding

**Verification**:全 PASS。若 U23.6 fail = bug,P0/P1 fix(可能需在 common.ps1
加 `chcp 65001` 或 `[Console]::InputEncoding`)。

---

### U24. Cross-platform parity verification — **gate checklist only(不 re-execute)**

**Goal**:**不重跑** U5-U22 已 inline 驗過的 parity sub-test。U24 變成 single gate:確認 U5-U22 各 unit 的 parity sub-test **全 PASS** 即 U24 PASS。

**Dependencies**:U5-U22(各 unit 的 parity sub-test 必須先跑完)

**Files**:跨 script

**Approach**:**no re-execution**;agent grep `jobs/<job>/test-output/*.log` 找各 unit parity sub-test 的 PASS/FAIL record,逐 pair confirm。

**Gate criteria**:18 pair parity sub-test 全 PASS:

- **U24.1 compute-project-identity parity**:U5.8 加強(byte-identical hash)
- **U24.2 resolve-iis-settings parity**:U6.9 加強(9 field 全 match)
- **U24.3 build-web parity**:bin/X.dll bytes-identical
- **U24.4 publish-web parity**:PublishOutput bytes-identical
- **U24.5 pack-content parity**:install_command 各 case 結果一致
- **U24.6 start-iis parity**:fail-fast 行為一致(真實啟動 skip)
- **U24.7 stop-iis parity**:殺 process + 訊息格式一致
- **U24.8 check-iis-listening parity**:listen detection 一致
- **U24.9 get-target-url parity**:URL output 一致
- **U24.10 pull-from-svn parity**:happy + conflict-rollback 訊息格式一致
- **U24.11 push-to-svn-prepare parity**:COMMITS/FILES/PENDING_MERGE_DETECTED token 格式一致
- **U24.12 push-to-svn-commit parity**:SHA pin write/read/cleanup 一致 + 中文檔名行為一致
- **U24.13 create-remote-test parity**:rollback 行為一致
- **U24.14 reset-remote-test parity**:LOSE/GAIN 格式一致
- **U24.15 svn-ignore parity**:propset / propdel 一致
- **U24.16 svn-log parity**:log 渲染 + header strip 一致
- **U24.17 posttooluse-enterworktree parity**:.sh delegate 結果跟 .ps1 一致
- **U24.18 sessionstart parity**:三分支 JSON output 一致

**Verification**:每 pair PASS。差異 = finding(P2 if 行為差、P0 if 結果差)。

---

### U25. Final lint + cleanup

**Goal**:全測完跑 lint 確認 turbo-plugin 仍 0 violation;cleanup SVN 殘留 +
git branches。

**Dependencies**:U1–U24

**Files**:`tools/lint-ps-compat.ps1`(run)+ SVN cleanup script

**Test scenarios**:

- **U25.1 lint 0 violation**:同 U1.4
- **U25.2 SVN 殘留清掉**:
  - `svn delete file:///.../test-script-N` 各 N
  - 確認 `svn ls SampleSvnServer/` 只剩 `main/` `test/`
- **U25.3 git branches 清掉**:
  - `git branch -D test/rc-script-N remote/test-script-N` 各 N
  - `git worktree remove --force <each>`
- **U25.4 iisexpress process 清掉**:
  - `Get-Process iisexpress -ErrorAction SilentlyContinue | Stop-Process -Force`
- **U25.5 scratch fixtures 清掉**:
  - 刪 `jobs/<job>/test-fixtures/*`
- **U25.5b dbhub.local.toml leak guard**(SEC-010):
  - `git -C SampleGit log --all --oneline --name-only -- '**/dbhub.local.toml'` 應**完全無輸出**(整 test run 期間沒有 commit 把 dbhub.local.toml 帶進 history)
  - `git -C SampleGit log --all --oneline --name-only | Select-String -Pattern 'dbhub.local'` 同樣空
  - 若 match → finding,確認 .gitignore 是否被誤動 / 哪個 unit 跑了 `git add .`
- **U25.6 中文路徑 fixture 清掉**(若加在 SampleGit):
  - 若 U23 加了 `src/測試專案/`,留下 commit 或 reset 視你決定
- **U25.7 fix commits bump version**(per CLAUDE.md):
  - **依 CLAUDE.md versioning rule**:每 P0/P1 fix 一個 patch bump;phase 內 P2/P3 累積批次 commit + 一次 bump
  - 若整 test run 找不到任何 finding → **no version bump**(plan 不能預設「一定 bump v0.2.5」)
  - CHANGELOG 加 entry 列每個 finding + fix(若有 bump)

**Verification**:fixture 回 baseline state,SVN server 乾淨,版本 bump
land。

---

## Threat Model — Top 3 Exploit Surfaces(SEC-012)

由 security-lens review 合成,這 3 條是 plan 跑下去要特別注意的高風險 path,fix 方向已散在對應 unit:

1. **Malicious `config.toml` → shell command injection via pack-content**(機率最高)
   - 攻擊面:有人能寫 `.turbo-plugin/config.toml` 的 `[frontend] install_command` 就能 inject
   - 緣由:tokenizer split on `\s+` 已擋 `;` 一種,但 `|` / `$()` / `&&` / 多 shell side 多 metachar 還沒 test
   - 涵蓋:**U8.3 (a)-(g)** 完整 metachar 套 + bash 端
   - 緩解:文件明寫 `config.toml` 是 trust boundary,只能透過 tp-setup 或 reviewed commit 改

2. **SVN URL injection → unauthorized SVN branch creation**(影響最大)
   - 攻擊面:`create-remote-test -SvnUrl` 完全沒 prefix 驗證
   - 緣由:`svn copy $mainSvnUrl $SvnUrl` line 73 直接 pass-through;惡意 URL 可在 SVN repo 任意位置建 branch(SVN history 不可逆)
   - 涵蓋:**U17.4b** 兩條 + fix 方向「`svn info --show-item repos-root-url` 拿 trusted base + assert prefix」
   - **Action item v0.2.5**:加 SvnUrl prefix validation

3. **Encoding confusion → silent mojibake in SVN permanent history**(最 subtle)
   - 攻擊面:中文 Windows(CP950)native exe argv encoding
   - 緣由:v0.2.4 fix 只設 `[Console]::OutputEncoding`,**InputEncoding / argv encoding 沒設**;svn.exe 收到 mojibake bytes commit 進 SVN → 永久 history 亂碼,只能 svnadmin recover
   - 涵蓋:**U23.6** byte-level argv 驗 + **U16.9/U16.10 URL form** server bytes 驗(FEAS-002 修)
   - 緩解:若 U23.6 fail,在 `common.ps1` 加 `[Console]::InputEncoding = [System.Text.Encoding]::UTF8`

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| 部分 unit 需模擬 process(fake iisexpress 啟動)— Auto-mode 可能擋 | 用最少 process,測完 immediately kill;若擋 document 為 manual-needed |
| 中文 fixture 加進 SampleGit 後續難清 | 用 scratch dir `jobs/<job>/test-fixtures/` 隔離;非必要不動 SampleGit |
| 25 unit 跑完時間長(估 6-10 小時 agent autonomous,U2 含 16 sub-test、U24 整 18 pair parity) | 可分 phase 跑,phase 間 checkpoint;agent 在 BG session;agent 自定 must-run vs nice-to-have 排序 |
| SVN file:// repo 殘留多 test branch(每 push 留 history) | 用 `test-script-N` namespace + U25 cleanup |
| fix 累積多 → 集體 commit 風險 | 每 phase 結尾 commit 一次,bump patch version |
| Edge case 觸到未 design 的 path 引發新 finding | 預期會發生,正常 acceptance process |

**Dependencies(unit 順序)**:
- Phase 1(U1-U6)foundation,必 first
- Phase 2(U7-U13)independent of Phase 3-5,可並
- Phase 3(U14-U18)SVN bridge sequence:pull → push-prepare → push-commit
- Phase 4(U19-U20)independent
- Phase 5(U21-U22)hooks,independent
- Phase 6(U23-U25)收尾,last

---

## System-Wide Impact

- **All script files touched**:21 個 `.ps1` + 17 個 `.sh` + 3 lib + 2 hook
  pairs = 完整 turbo-plugin scripts/ 範圍
- **Fixture mutation**:
  - SampleSvnServer 新增 `^/test-script-N` SVN paths(由 U17 / U16 建,U25 清)
  - SampleGit `main` 可能多測試 commits(中文檔名 / pattern 等),U25 視情況 reset
  - SampleGit.worktrees 可能多 `remote-test-script-N` worktree(U25 清)
- **iisexpress process**:U10-U13 模擬 / 啟用 fake instance,U25 統一 kill
- **新檔生成**:
  - `jobs/<job>/test-output/U*.log` 每 unit 一 log
  - `jobs/<job>/test-fixtures/` scratch fixture(apphost / 中文檔等)
- **plugin code**:預期累積 fix → commit v0.2.5(若多 P0/P1 finding 直接修)
- **CHANGELOG**:v0.2.5 entry 列每個 finding + fix
- **`docs/plans/2026-05-25-002-...`**(本檔)+ `2026-05-25-001-...`(manual
  acceptance)兩份 plan 互補,本檔由 agent 跑,前檔由人跑

---

## 進度追蹤(checkbox 給 agent 自填)

### Phase 1 — Foundation
- [ ] U1 Pre-flight + lint baseline
- [ ] U2 common.ps1 helpers
- [ ] U3 common.sh helpers
- [ ] U4 applicationhost-helpers.ps1
- [ ] U5 compute-project-identity .ps1+.sh
- [ ] U6 resolve-iis-settings .ps1+.sh

### Phase 2 — Build, IIS, Publish
- [ ] U7 build-web .ps1+.sh
- [ ] U8 pack-content .ps1+.sh(security)
- [ ] U9 publish-web .ps1+.sh
- [ ] U10 start-iis .ps1+.sh(邏輯)
- [ ] U11 stop-iis .ps1+.sh
- [ ] U12 check-iis-listening + get-target-url .ps1+.sh
- [ ] U13 cleanup-orphan-iis .ps1

### Phase 3 — SVN Bridge
- [ ] U14 pull-from-svn .ps1+.sh
- [ ] U15 push-to-svn-prepare .ps1+.sh
- [ ] **U16 push-to-svn-commit .ps1+.sh(含中文檔名 ⭐)**
- [ ] U17 create-remote-test .ps1+.sh
- [ ] U18 reset-remote-test .ps1+.sh

### Phase 4 — SVN Tools
- [ ] U19 svn-ignore .ps1+.sh
- [ ] U20 svn-log .ps1+.sh

### Phase 5 — Hooks
- [ ] U21 posttooluse-enterworktree .ps1+.sh
- [ ] U22 sessionstart .ps1+.sh

### Phase 6 — Cross-cutting
- [ ] U23 Encoding edge cases(含 PowerShell argv → svn.exe)
- [ ] U24 Cross-platform parity(18 pair)
- [ ] U25 Final lint + cleanup + 依 finding 數量 patch bump(若無 finding 不 bump)

⭐ 標的是使用者明確點出之前漏的 — U16 中文檔名是首要補測項。

---

## Execution Notes

- **不要在 plan compose 階段執行任何 unit**(user 要先 compact session)
- 跑 unit 時 BG session 較合適(時間長)
- 每 phase 結束給 checkpoint summary(applied fix / finding / next phase)
- 任何 P0/P1 finding 立即修 + commit;P2/P3 累積 phase 結尾批次
- 全 25 unit 跑完後 emit final report(每 unit pass/fail + 累積 finding +
  v0.2.5 fix summary)
