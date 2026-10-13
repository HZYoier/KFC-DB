-- [归档脱敏版] 原脚本位于仓库外工作目录；口令已以 <operator-supplied-password> 代替。
-- 用途：在隔离库验证包含数据库用户路径（SET CONTAINMENT=PARTIAL / 口令用户 / EXECUTE AS）。
SET NOCOUNT ON;
-- pre-state
SELECT N'SERVERPROP_IsIntegratedSecurityOnly' AS probe, CAST(SERVERPROPERTY('IsIntegratedSecurityOnly') AS INT) AS val;
SELECT N'cfg_before' AS probe, name, value, value_in_use, is_dynamic
FROM sys.configurations WHERE name = 'contained database authentication';
-- enable instance option (dynamic per is_dynamic = 1)
EXEC sp_configure 'contained database authentication', 1;
RECONFIGURE;
SELECT N'cfg_after_reconfigure' AS probe, name, value, value_in_use, is_dynamic
FROM sys.configurations WHERE name = 'contained database authentication';
GO
IF DB_ID('C_TEST_CONTAINED') IS NOT NULL
BEGIN
    ALTER DATABASE C_TEST_CONTAINED SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE C_TEST_CONTAINED;
END
GO
CREATE DATABASE C_TEST_CONTAINED;
GO
SELECT N'db_before_contained' AS probe, name, containment, containment_desc, SUSER_SNAME(owner_sid) AS db_owner
FROM sys.databases WHERE name = 'C_TEST_CONTAINED';
GO
ALTER DATABASE C_TEST_CONTAINED SET CONTAINMENT = PARTIAL;
GO
SELECT N'db_after_contained' AS probe, name, containment, containment_desc, SUSER_SNAME(owner_sid) AS db_owner
FROM sys.databases WHERE name = 'C_TEST_CONTAINED';
GO
USE C_TEST_CONTAINED;
GO
CREATE TABLE dbo.T (id INT NOT NULL PRIMARY KEY, v NVARCHAR(50) NOT NULL);
INSERT dbo.T (id, v) VALUES (1, N'hello');
GO
CREATE PROCEDURE dbo.p_get_t AS SELECT id, v FROM dbo.T;
GO
CREATE ROLE r_app;
GRANT EXECUTE ON dbo.p_get_t TO r_app;
GO
CREATE USER ctest WITH PASSWORD = '<operator-supplied-password>';
ALTER ROLE r_app ADD MEMBER ctest;
GO
SELECT N'user_state' AS probe, name, type_desc, authentication_type_desc
FROM sys.database_principals WHERE name = 'ctest';
GO
-- fixture pattern: impersonation from the sysadmin session
EXECUTE AS USER = 'ctest';
SELECT N'impersonated_by_sysadmin' AS probe, USER_NAME() AS user_name, SUSER_SNAME() AS suser;
REVERT;
GO
