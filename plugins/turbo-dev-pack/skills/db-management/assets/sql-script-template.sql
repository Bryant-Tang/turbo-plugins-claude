/*
用途: <請填寫這支 SQL 的目的>
工單或主題: <例如 115-A008 或 student-elder-display>
資料庫: <TRAINING | SETSUser | WdaElder | WdaRestart>
目標環境: <local-db | test-db | main-db>
執行順序: <01 | 02 | 03>
檔名: <例如 01-TRAINING-新增欄位.sql>
是否需要回滾: <是 | 否>
SQL Server 版本需求: 2012+（本模板使用 THROW 語法）
對應環境檔案:
- local-db/<work-item-or-topic>/<file-name>.sql
- test-db/<work-item-or-topic>/<file-name>.sql
- main-db/<work-item-or-topic>/<file-name>.sql
備註:
1. <補充執行前提、影響範圍、需先停用排程等事項>
2. <若為 local-only 驗證腳本，請註明測完後如何回滾>
3. 以下類型的 SQL 指令不能包在 TRY/CATCH + TRANSACTION 區塊內，若使用請移除交易包裹並逐行執行：
   - 建立含 WITH ENCRYPTION 的物件（如 CREATE PROCEDURE WITH ENCRYPTION）
   - Service Broker 指令（例如 CREATE MESSAGE TYPE、CREATE CONTRACT、CREATE QUEUE）
   - 某些 DDL（例如 CREATE DATABASE、ALTER DATABASE、BACKUP/RESTORE）
   - 某些 Replication 相關指令
*/

USE [<DatabaseName>];
GO

-- Pre-check
-- 先查出受影響資料，避免直接盲改。
-- 範例:
-- SELECT TOP 100 *
-- FROM dbo.<TableName>
-- WHERE <Condition>;
GO

-- 如果此腳本可安全包在交易內，保留 TRY/CATCH + TRANSACTION。
-- 若包含不能置於顯式交易中的 SQL Server 指令，請改成適合的執行方式，
-- 並在檔頭備註原因。
BEGIN TRY
    BEGIN TRANSACTION;

    -- Main change
    -- 範例:
    -- UPDATE dbo.<TableName>
    -- SET <Column> = <Value>
    -- WHERE <Condition>;
    --
    -- INSERT INTO dbo.<TableName> (...)
    -- VALUES (...);
    --
    -- ALTER TABLE dbo.<TableName>
    -- ADD <ColumnName> NVARCHAR(50) NULL;

    -- Post-check
    -- 驗證異動結果，必要時比對異動前後筆數或欄位值。
    -- 範例:
    -- SELECT *
    -- FROM dbo.<TableName>
    -- WHERE <Condition>;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0
        ROLLBACK TRANSACTION;

    THROW;
END CATCH;
GO

-- Rollback hint
-- local-only 驗證腳本建議在此附上回滾方式，例如：
-- BEGIN TRANSACTION;
-- DELETE FROM dbo.<TableName> WHERE <Condition>;
-- ROLLBACK TRANSACTION;
GO