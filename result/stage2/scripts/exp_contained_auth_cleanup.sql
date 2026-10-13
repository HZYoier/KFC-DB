-- [归档版] 删除隔离库、恢复 contained database authentication 选项为 0。
USE master;
GO
IF DB_ID('C_TEST_CONTAINED') IS NOT NULL
BEGIN
    ALTER DATABASE C_TEST_CONTAINED SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE C_TEST_CONTAINED;
END
GO
EXEC sp_configure 'contained database authentication', 0;
RECONFIGURE;
GO
SELECT N'cfg_restored' AS probe, name, value, value_in_use, is_dynamic
FROM sys.configurations WHERE name = 'contained database authentication';
GO
