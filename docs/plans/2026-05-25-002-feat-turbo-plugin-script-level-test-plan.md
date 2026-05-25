---
date: 2026-05-25
type: feat
origin: docs/brainstorms/turbo-plugin-requirements.md
status: active
---

# feat: turbo-plugin v0.2.4 script-level autonomous test plan

## Summary

agent-executable 完整 script-level 測試計畫,covering 所有 `.ps1` / `.sh` /
helper / hook 的所有狀況,目標**不要缺漏**。21 個 Implementation Unit 分 6
phase(Foundation / Build & IIS / Publish / SVN Bridge / SVN Tools / Hooks
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

- **All 17 user-facing `.ps1` scripts**(`scripts/*.ps1`)各 happy + edge +
  failure 完整 case
- **All 17 `.sh` siblings**(`scripts/*.sh`)同 case,額外加 cross-platform
  parity 驗證
- **3 個 lib file**(`common.ps1`、`common.sh`、`applicationhost-helpers.ps1`)
  helper function 各別 unit test(directly invoked + return value 驗)
- **2 hook(`posttooluse-enterworktree` + `sessionstart`)**.ps1 + .sh
  各 input scenario(empty / malformed JSON / 各條件 short-circuit)
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
3. **SVN test 用 `^/test-script-N`(N=1,2,3,…) namespace**:跟 manual
   plan 的 `^/test3` 區隔,避免互撞。測完一起 cleanup
4. **中文檔名測試**用 `測試檔案-${random}.txt` pattern,涵蓋:
   - Big5 編碼下的 PowerShell argv passing
   - UTF-8 stored SVN repo
   - git → svn add 中間的 filename encoding 鏈
5. **Cross-platform parity 用 diff-based verification**:同 input 餵兩個
   sibling script,比對 stdout (normalize line endings) + exit code +
   file system side-effect。差異視為 finding
6. **每 unit 失敗即修**:P0/P1 立即 commit fix(bump patch version);
   P2/P3 累積到 unit 結尾批次 commit fix。所有 fix 收進 v0.2.5(預計)
7. **lib helper unit test 用 inline PowerShell dot-source**:無 test framework,
   直接 `. common.ps1; Assert-Equal (FuncCall) ExpectedValue`,簡單夠用

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
  - 不同 RepoPath(main vs peer git-common-dir)→ 同 hash if git-common-dir resolves to same
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
4 個 function 直接 unit test。

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
- **U8.3 install_command 含 shell metachar 不 compose shell**(security):
  - `install_command = "echo a; rm -rf C:/tmp/SHOULD-NOT-EXIST"` → `echo a; rm -rf...`
    被 tokenize 成 `echo`(arg `a;`、`rm`、`-rf`、`C:/tmp/SHOULD-NOT-EXIST`)
    → echo 印 `a; rm -rf C:/tmp/SHOULD-NOT-EXIST`,**rm 不執行**
  - assert `C:/tmp/SHOULD-NOT-EXIST` 仍存在 if 預先 mkdir 之
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
- **U13.9 stemPattern regex-escape**(Pass 4 SF2):
  - csproj `My.Test.csproj` → stem `My.Test`(含 `.` metachar)→ 對 site
    `MyXTestXabc12345`(隨機字代 `.`)**不** match
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
  - assert svn server 端`svn ls SampleGit.worktrees/remote-test-N/` 含
    `測試檔案-${rand}.txt`(**正確檔名,非 mojibake 也非 quote-printable**)
  - assert `svn log -v --limit 1` 列改動檔含正確檔名
- **U16.10 中文目錄名 + 中文檔名**:
  - 加 `測試目錄/中文檔.txt` → svn add --parents → 兩層都正確
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
- **U17.5 trap 位置 BEFORE first git mutation**(v0.2.3 B1):
  - 模擬 `git branch '<rev>'` 失敗(rev 不存在)→ trap 仍 fire 清掉殘
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
- **U21.6 marker .turbo-plugin/ missing**:emit `{}` exit 0
- **U21.7 apphost source missing**:emit `{}` exit 0
- **U21.8 no csproj in worktree**:emit `{}` exit 0
- **U21.9 multi-csproj count correct**:
  - 預先建 2 個 csproj + 對應 2 個 site in apphost → 都 update → count=2
- **U21.10 idempotent skip**:
  - 第一次 fire 後 apphost mtime A
  - 再 fire(physicalPath 已正確)→ updates Updated=false,**emit `{}` 不
    emit systemMessage**,apphost mtime 不變(Pass 1 T002)
- **U21.11 concurrent fire .tmp 唯一性**(Pass 4 AF2):
  - 兩個 hook 同時跑 → 不互相蓋(看 .tmp.PID.GUID 命名 + 沒 leftover)
- **U21.12 .sh stdin pipe `cat | powershell ...`**(Pass 1 REL-001):
  - sh sibling 餵 stdin → 正確傳到 ps1 處理(已 script-level 證實)
- **U21.13 .sh on non-Windows fail-safe**:
  - 在 fake non-Windows env(Git Bash 假裝)→ hook exit 0,不 block
- **U21.14 hooks.json bash command quoting**(v0.2.0 SF4 + 後續):
  - `${CLAUDE_PLUGIN_ROOT}` 含 space 路徑 → hook 仍正確 invoke

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
- **U22.5 sessionstart.ps1 Branch (i) auto-fix applicationhost.config**(Pass 1 #14 + Pass 2 M-08):
  - main worktree marker missing + apphost source 有 + csproj 在 → 靜默 update apphost(類 PostToolUse 行為)
- **U22.6 .sh on Windows powershell wrapped in if**(Pass 4 SF5):
  - powershell 失敗時 exit_code 仍捕到,ERR trap 不 shadow diagnostic
- **U22.7 .sh on non-Windows ERR-trap fail-safe**(Pass 3 WF3):
  - sh 在 non-Windows env 故意製造 common.sh source fail → exit 0,不 block session
- **U22.8 中文 systemMessage 不亂碼**:
  - sessionstart 訊息含中文 → Claude Code 收到 unicode-correct JSON

**Verification**:U22.2 main path interpolation 是 v0.2.1 fix regression test。

---

### Phase 6 — Cross-cutting

---

### U23. Encoding edge cases consolidated

**Goal**:把分散在各 unit 的 encoding 測試集中 sanity-check。

**Dependencies**:U2 / U3 / U16 / U19 / U20

**Files**:跨 script(non-unit-specific)

**Test scenarios**:

- **U23.1 中文 csproj filename 全流程**:`src/測試專案/中文.csproj` 跑
  compute-identity / resolve-iis / build → 全程不錯
- **U23.2 中文 commit subject git → svn → svn-log 渲染**:
  - git commit 含「修中文 bug」→ push-to-svn → svn-log 渲染**不亂碼**
- **U23.3 中文 filename git status `??` → svn add → svn ls**:
  - U16.9/U16.10 加強驗
- **U23.4 中文 svn:ignore pattern**:U19.8 加強驗
- **U23.5 中文 directory name**:`src/測試目錄/X.csproj` 全流程
- **U23.6 PowerShell argv encoding to svn.exe**(根因驗):
  - 用 .NET `Process.Start` 透過 PowerShell native exe invocation 傳含中文
    argv → svn.exe stdout assert 收到正確 bytes(若有 mojibake,加 fix
    `[Console]::InputEncoding` / native exe argv UTF-8 設定)
- **U23.7 BOM check after fix**(v0.2.0 fix 9 個 .ps1 加 BOM regression):
  - 所有 turbo-plugin .ps1 含非 ASCII → 前 3 byte 是 `EF BB BF`
- **U23.8 .sh on Windows Git Bash UTF-8**:
  - 同 U23.6 但 from bash → svn.exe 收到正確 UTF-8

**Verification**:全 PASS。若 U23.6 fail = bug,P0/P1 fix(可能需在 common.ps1
加 `chcp 65001` 或 `[Console]::InputEncoding`)。

---

### U24. Cross-platform parity verification

**Goal**:對所有有 .ps1 + .sh 配對的 script,跑 diff-based equivalence test。

**Dependencies**:U5–U20(每個 paired script unit 都已 single-platform 驗)

**Files**:跨 script

**Approach**:同一 input(cwd / args / env)餵 .ps1 + .sh,比對:
- stdout(normalize CRLF → LF + remove path drive case)
- stderr(同)
- exit code
- file system side-effects(file mtime / file content hash)

**Test scenarios**:per pair:

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
- **U25.6 中文路徑 fixture 清掉**(若加在 SampleGit):
  - 若 U23 加了 `src/測試專案/`,留下 commit 或 reset 視你決定
- **U25.7 fix commits bump version**:
  - 累積 finding fix 一起 commit 為 v0.2.5
  - CHANGELOG 加 entry 列每個 finding + fix

**Verification**:fixture 回 baseline state,SVN server 乾淨,版本 bump
land。

---

## Risks & Dependencies

| Risk | Mitigation |
|---|---|
| 部分 unit 需模擬 process(fake iisexpress 啟動)— Auto-mode 可能擋 | 用最少 process,測完 immediately kill;若擋 document 為 manual-needed |
| 中文 fixture 加進 SampleGit 後續難清 | 用 scratch dir `jobs/<job>/test-fixtures/` 隔離;非必要不動 SampleGit |
| 21 unit 跑完時間長(estimate 3-4 小時 agent autonomous) | 可分 phase 跑,phase 間 checkpoint;agent 在 BG session |
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
- [ ] U25 Final lint + cleanup + v0.2.5 bump

⭐ 標的是使用者明確點出之前漏的 — U16 中文檔名是首要補測項。

---

## Execution Notes

- **不要在 plan compose 階段執行任何 unit**(user 要先 compact session)
- 跑 unit 時 BG session 較合適(時間長)
- 每 phase 結束給 checkpoint summary(applied fix / finding / next phase)
- 任何 P0/P1 finding 立即修 + commit;P2/P3 累積 phase 結尾批次
- 全 25 unit 跑完後 emit final report(每 unit pass/fail + 累積 finding +
  v0.2.5 fix summary)
