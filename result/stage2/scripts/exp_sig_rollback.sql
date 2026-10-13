-- [归档版] 三路径：ALTER 回滚 / ALTER+重签回滚 / ALTER+重签提交；自建自清隔离库。
SET NOCOUNT ON;
SET XACT_ABORT ON;
IF DB_ID('C_TEST_SIG') IS NOT NULL
BEGIN
    ALTER DATABASE C_TEST_SIG SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE C_TEST_SIG;
END
GO
CREATE DATABASE C_TEST_SIG;
GO
USE C_TEST_SIG;
GO
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'SigExp!2026Key';
GO
CREATE CERTIFICATE cert_sig_exp WITH SUBJECT = 'sig experiment';
GO
CREATE PROCEDURE dbo.p_sig AS SELECT N'v1' AS ver;
GO
ADD SIGNATURE TO dbo.p_sig BY CERTIFICATE cert_sig_exp;
GO
SELECT N'baseline' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
-- Scenario A2: ALTER inside a transaction (no re-sign), then ROLLBACK.
BEGIN TRANSACTION;
GO
ALTER PROCEDURE dbo.p_sig AS SELECT N'v2' AS ver;
GO
SELECT N'A2-in-txn-after-alter' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
ROLLBACK TRANSACTION;
GO
SELECT N'A2-after-rollback' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
-- Scenario A: ALTER + re-sign inside a transaction, then ROLLBACK (mixed-state detector).
BEGIN TRANSACTION;
GO
ALTER PROCEDURE dbo.p_sig AS SELECT N'v2' AS ver;
GO
ADD SIGNATURE TO dbo.p_sig BY CERTIFICATE cert_sig_exp;
GO
SELECT N'A-in-txn-after-resign' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
ROLLBACK TRANSACTION;
GO
SELECT N'A-after-rollback' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
-- Scenario B: ALTER + re-sign inside a transaction, then COMMIT.
BEGIN TRANSACTION;
GO
ALTER PROCEDURE dbo.p_sig AS SELECT N'v3' AS ver;
GO
ADD SIGNATURE TO dbo.p_sig BY CERTIFICATE cert_sig_exp;
GO
COMMIT TRANSACTION;
GO
SELECT N'B-after-commit' AS phase,
       LEFT(OBJECT_DEFINITION(OBJECT_ID(N'dbo.p_sig')), 120) AS defn,
       (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.p_sig')) AS sig_cnt;
GO
USE master;
GO
ALTER DATABASE C_TEST_SIG SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
DROP DATABASE C_TEST_SIG;
GO
