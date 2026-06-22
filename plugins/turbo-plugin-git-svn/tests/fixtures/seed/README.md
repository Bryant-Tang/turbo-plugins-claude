# plugins/turbo-plugin-git-svn/tests/fixtures/seed/

turbo-plugin v1.0 PR-readiness Script tests 測試的 **SVN seed dump source**。

## 內容

```
seed/
├── Build-SeedRepo.ps1      # PowerShell 5.1 — orchestrator 跑這個
├── build-seed-repo.sh      # Bash mirror (Windows delegates to PS;Linux/macOS deferred)
├── svn-repo-r1-r20.dump    # ← 產出物;由 Build-SeedRepo.ps1 寫入
└── README.md
```

## svn-repo-r1-r20.dump 是怎麼生出來的

由 `Build-SeedRepo.ps1` 自動產生。流程:

1. 建臨時 SVN repo 在 repo 內 gitignored 的 `<tests>/.sandbox/seed-build/repo`
2. 建 `trunk` / `branches` / `tags` (r1)
3. checkout `trunk` 到臨時 working copy
4. 跑 r2-r19 一連串 add/modify commit;**r5 / r10 / r15 用中文 commit message**
5. r20 跑 `svn copy trunk@HEAD branches/test-1` 以供 `remote-test-1` worktree 用
6. **F-3 fix**:對 r5 / r10 / r15 額外跑 `svnadmin setlog -r <N> --bypass-hooks -F <utf8-file>`,
   把 commit msg revprop 強制寫成真 UTF-8 bytes (svn commit 在 Windows 不會給你這個)
7. **F-2 fix**:用 `cmd /c "svnadmin.exe dump <repo> > <dump>"` 把 dump 寫到 `svn-repo-r1-r20.dump`
   (PowerShell `>` redirect 會字串化 svnadmin 的 mixed 文字+二進位 stream,corrupt the dump)
8. byte-level round-trip check:load dump → svn:log r5 raw bytes 必須 == 字典 #3 第 1 條
   (確保 F-3 / F-2 都 effective)
9. 清掉臨時工作目錄

## 重建步驟

```powershell
# 從 worktree root
.\plugins\turbo-plugin\tests\fixtures\seed\Build-SeedRepo.ps1            # idempotent skip if dump exists
.\plugins\turbo-plugin\tests\fixtures\seed\Build-SeedRepo.ps1 -Force     # 強制重建
```

## 25 條中文字典 mapping

Build-SeedRepo.ps1 取 `$zhDict.commit_messages` 前 3 條給 r5 / r10 / r15。完整 25 條字典
就 inline 在 `Build-SeedRepo.ps1` 的 `$zhDict`（single source of truth）;`build-seed-repo.sh`
若有對應字典需與之一致。

## 為什麼 dump 進 git?

~10KB,可重現但每次重產要 ~5-10 sec + svn cli。把 dump commit 進 git 讓:

- CI / 新環境 clone repo 即可跑 Script tests reset
- 不依賴 svn cli 在每個 user 機器上 build 順利
- diff-able (`git diff` 看 dump 變動,catch unintended seed drift)
