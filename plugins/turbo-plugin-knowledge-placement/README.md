# turbo-plugin-knowledge-placement

「這件事該寫在哪」的判準,以及讓 agent 記憶能夠**交接**的機制。

兩支 skill:

| Skill | 做什麼 |
|---|---|
| `tp-knowledge-placement-setup` | 把判準注入專案的 `CLAUDE.md`(一個標記區塊) |
| `tp-export-handover` | 把記憶裡「接手的人需要知道」那一格匯出成一份檔案 |

純 skill,沒有 script,不碰 `.turbo-plugin/` 狀態。

## 這個 plugin 在主張什麼

一件事寫錯地方**不會報錯**。它會在半年後以兩種形式浮出來:過期的文件把人帶錯路,或者交接之後這件事
沒人知道。

判準只有四格:

| 這件事的性質 | 落點 |
|---|---|
| 對**任何時間** checkout 這個 repo 的人都成立 | `CLAUDE.md` 或 `docs/` |
| 只有**現在**成立,但**接手的人需要知道** | agent 記憶,`type: project` |
| agent 自己的工作方式,或只對這台機器成立、**不需要交接**的事 | agent 記憶,`type: feedback` / `user` / `reference` |
| git / svn 本身就查得到 | 哪都不要寫 |

### 第一列在 mono repo 裡要再分一次:根還是子目錄

`CLAUDE.md` 有兩種,載入行為差很多——而一個 repo 裡放多個子專案時,兩種會同時存在:

| 落點 | 什麼時候進 context | compact 之後 |
| --- | --- | --- |
| **repo 根**的 `CLAUDE.md` | **無條件** | 會回來 |
| **子目錄**的 `CLAUDE.md` | 動到那個目錄底下的檔案時,**自動** | **不會回來** |
| `docs/` | 有人**主動去查**才會 | 不會回來 |

中間那列比 `docs/` 自動,卻比根那份不可靠:**規劃階段還沒讀任何檔案時它不在 context,而規劃正是最需要
規範的時候**。所以在同一個 repo 內的判準是:

> **這條規則會不會在「我還沒打開那個子專案的任何檔案」之前就需要用到?**
> 會 → 根。不會 → 子目錄。

判準是**雙向**的——「不確定就放根」不是安全解。實測一個九子專案的 repo,九份合計約 1800 行,去重之後
根落在 900–1100 行,已經接近規範被稀釋的邊界。同一個判準也適用 `docs/`:橫跨多個子專案的文件放**根
`docs/` 只留一份**,綁定單一子專案的留在**子專案 `docs/`**(SVN 這類可以只 checkout 子路徑的版控下,
這對只抓單一子專案的人是實質差別)。

### 為什麼待辦不放在一份不進版控的 `TODO.md`

「不進版控、但屬於交接內容」這個格子**沒有任何工具支援**:

- **git 不管它** —— 它被 ignore 了。
- **隔離工作副本只帶進去、不搬回來** —— 在副本裡加的那條,副本消失就沒了,而且沒有警告。
- **沒有合併機制** —— 兩個工作副本各加一條,沒有任何東西能把它們合起來。

想替這個格子補機制,補出來的每一樣都是在重造 merge:存一份快照就是 merge base、比對三個版本就是
three-way merge、把衝突寫成 `.from-worktree` 就是 conflict file。與其重寫一次 git,不如**把格子拆掉**:
待辦落在記憶,交接靠 `tp-export-handover` 匯出。

已經有一份**進了版控**的 `TODO.md` 是另一回事——那就是文件,適用第一列。

### 記憶裡的兩格,分野是「會不會被交接」

記憶不會跟著 repo 走。所以判準不是「進不進版控」(第二、三列都不進),而是:

> **這件事換人接手還需要嗎?**

需要 → `type: project`,在 `MEMORY.md` 留一行索引。不需要 → `feedback` / `user` / `reference`。

### 被 git 忽略的檔案:三個不變式

1. **不是用來編輯的**
2. **可以重新產生**
3. **可以接受手動編輯**

三條有一條不成立,那份內容就不該待在版控外——它要嘛進版控,要嘛進記憶。

這條不變式是「隔離工作副本只帶進去、不搬回來」的直接後果,也是
[`turbo-plugin-multi-repo-workspace`](../turbo-plugin-multi-repo-workspace/README.md) 實作
`.worktreeinclude` 時的判準:只放「工作副本裡必須存在才跑得起來」的東西。

## 交接匯出

```
/tp-export-handover
```

它會挑出 `project` / `reference` 類記憶、逐條查證是否仍然成立,然後**問你要哪一種**:

- **存成一個檔案** —— 不進版控,內容照實保留(含機器路徑、內網位址)。
- **放進 `docs/` 並提交** —— 會進版控,所以先把機器路徑、內網 hostname / URL、單次情境代號換成佔位符。

**消毒只發生在「進版控」那條路徑。** 這些內容當初就是因為不進版控才放記憶的;對一份私下交給接手者的
檔案做消毒,只會把真正有用的資訊(fixture 在哪、哪台機器)洗掉。判準是**這份東西會不會被推出去**。

## 安裝

```
/plugin marketplace add Bryant-Tang/turbo-plugins-claude
/plugin install turbo-plugin-knowledge-placement@turbo-plugins-claude
```

## 和其它 turbo-plugin 的關係

**沒有任何 plugin 相依這一個,這是刻意的。** 用了 git↔SVN 橋接、或多專案工作區,不代表就得接受這套
文件方法——那是兩件事,綁在一起只會逼人接受他沒要的東西。

- `turbo-plugin-git-svn` / `turbo-plugin-three-environment-db` 的 `tp-setup` 只留**結構**:
  `.gitignore` base 區塊,以及「不得提交僅限本機才有的東西」這條硬規則。**主張**在這裡。
  兩邊都裝時,`CLAUDE.md` 會有兩個各自獨立的標記區塊,各自的 setup 重跑時只取代自己那塊。
- [`turbo-plugin-code-comment`](../turbo-plugin-code-comment/README.md) 講的是**註解**該怎麼寫,
  同樣是一套主張,但粒度與強制性都不同,所以**維持獨立**、只交叉引用。

## 測試

```powershell
powershell -ExecutionPolicy Bypass -File tests/Invoke-ScriptTests.ps1
```
```bash
bash tests/invoke-script-tests.sh
```

這個 plugin 沒有 script,所以測試套件只驗證資產本身的一致性(注入用的 snippet 標記成對、
skill frontmatter 完整)。

## License

MIT
