/*
本模板只給 `_modules/` 底下的固定檔用（stored procedure / view / function / trigger）。
一次性的累加型變更（新增欄位 / 新增表 / 新增索引 / 補資料）請改用 sql-script-template.sql，
那份的版面是 TRY/CATCH + 顯式交易，而 CREATE OR ALTER 包不進交易裡。

物件: <schema>.<物件名>                 例如 dbo.USP_GetMember
物件類型: <PROCEDURE | VIEW | FUNCTION | TRIGGER>
資料庫: <DbName>
目標環境: <local-db | test-db | main-db>
檔案落點: <sql_root>/<目標環境>/_modules/<DbName>/<Procedures|Views|Functions|Triggers>/<schema>.<物件名>.sql

基線來源環境: <local-db | test-db | main-db>
              ← 必須跟上面的「目標環境」是同一個。拿 local 全文當 main-db 的基線，第一次全文
                覆寫就會把開發中、還沒核准的改動整批推上正式，而且腳本會執行成功、沒有任何警告。
基線取得方式: SSMS 物件總管 →「編寫指令碼為」→「CREATE 至」
              ← 不可用 SELECT OBJECT_DEFINITION(...)：它不含下面那兩行 SET（那兩行跟著物件
                持久化），而且在結果窗格會被無聲截斷（grid 預設 65535 字元、文字模式 8192），
                長 SP 被切一半而切口不會報錯。
基線取得日期: <YYYY-MM-DD>
先前的一次性腳本: <這個物件以前若在 <slug>/ 底下被改過，寫該檔路徑；沒有就寫「無」>

本次變更摘要:
1. <這一版改了什麼>

執行順序: 這個檔屬於 _modules/，同一批交付裡一律**最後**跑，排在所有 <slug>/ 一次性腳本之後。
          CREATE OR ALTER PROCEDURE 有 deferred name resolution —— 引用同一批才要新增的欄位時，
          建立會成功、執行才炸。

回滾: 不寫在這個檔裡，也不要為它另外寫一份反向 SQL。前一版全文用
      `git show <上一個 release tag>:<本檔路徑>` 取得；首次納管那一次的回滾來源是基線那顆 commit
      （所以基線必須自己獨立成一顆 commit，混進變更那顆就沒有前一版可取）。

SQL Server 版本需求: 2016 SP1+（CREATE OR ALTER，涵蓋 procedure / function / trigger / view）。
                     本檔只保證 SQL Server。PostgreSQL 是 CREATE OR REPLACE、MySQL 沒有對應語法
                     （只能 DROP + CREATE，而那正是下面說不要做的）——目標不是 SQL Server 就停下來
                     說明，不要自己代換。
*/

USE [<DatabaseName>];
GO

-- 這兩行跟著物件持久化，漏抄會改變物件行為（影響索引檢視、計算欄位索引這種平常看不出來的地方）。
-- 抄基線時 SSMS 產生的是哪個值就照抄哪個值，不要一律填 ON。
SET ANSI_NULLS ON;
GO

SET QUOTED_IDENTIFIER ON;
GO

-- 下面這段要換成實際的物件類型（PROCEDURE / VIEW / FUNCTION / TRIGGER）與完整定義。
--
-- 三件事不能動：
-- 1. CREATE OR ALTER 必須是批次裡的第一個陳述式，所以上面每一段都要用 GO 斷開。
-- 2. 不可以包進 BEGIN TRY 或顯式交易。
-- 3. 絕不改成 DROP + CREATE：那會把物件上的 GRANT 一起清掉，而且 DROP 成功 / CREATE 失敗時
--    物件就不見了 —— 對 trigger 特別嚴重，稽核從那一刻起斷掉且不會有人發現。
CREATE OR ALTER PROCEDURE [<schema>].[<物件名>]
    @<Param1> <Type> = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- <物件本體全文。>
    --
    -- 首次納管時這裡是從目標環境原封不動抄來的基線 —— 不要順手整理格式、排版或命名。
    -- 格式差異會讓下一次的 diff 混進雜訊，而 diff 是這個做法唯一的審查介面：
    -- 「基線 vs 我的改動」看不出來，這個檔就退回成一個 800 行的不透明新檔。
END;
GO
