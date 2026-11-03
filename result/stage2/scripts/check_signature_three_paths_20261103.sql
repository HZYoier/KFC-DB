-- Signature three-path low-privilege acceptance for the three role-sync procedures.
-- Real v0.1; no 11b/12 dependency. Exactly three path-level assertions.
USE KFC_DB;
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;

IF OBJECT_ID(N'tempdb..#sig_counters') IS NOT NULL DROP TABLE #sig_counters;
CREATE TABLE #sig_counters (pass INT NOT NULL, fail INT NOT NULL);
INSERT #sig_counters VALUES (0, 0);

DECLARE @def NVARCHAR(MAX), @pos INT, @sigs INT, @err INT, @msg NVARCHAR(2048), @imp BIT;
DECLARE @mgr BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_store_manager' AND status = N'ACTIVE');
DECLARE @role BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'waiter' AND status = N'ACTIVE');
IF @mgr IS NULL OR @role IS NULL THROW 53610, N'signature fixture missing', 1;
IF (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role')) <> 1
    THROW 53611, N'initial signature is not one', 1;

-- Path 1: ALTER -> unsigned low-priv call fails -> ROLLBACK restores -> signed call succeeds.
BEGIN TRY
    BEGIN TRANSACTION;
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    SET @pos = CHARINDEX(N'CREATE PROCEDURE', @def);
    IF @pos = 0 THROW 53612, N'path1 definition lacks CREATE PROCEDURE', 1;
    SET @def = STUFF(@def, @pos, LEN(N'CREATE PROCEDURE'), N'ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 0 THROW 53613, N'path1 ALTER did not drop signature', 1;

    SET @err = NULL; SET @msg = NULL; SET @imp = 0;
    BEGIN TRY
        EXECUTE AS USER = N'test_store_manager';
        SET @imp = 1;
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    END CATCH;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;

    IF @err IS NULL OR @err <> 50000 OR @msg NOT LIKE N'%数据库角色不存在%'
        THROW 53614, N'path1 unsigned low-priv call did not fail with the expected signature-loss symptom', 1;
    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 1 THROW 53615, N'path1 ROLLBACK did not restore signature', 1;

    BEGIN TRANSACTION;
    SET @err = NULL; SET @msg = NULL; SET @imp = 0;
    BEGIN TRY
        EXECUTE AS USER = N'test_store_manager';
        SET @imp = 1;
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
        REVERT;
        SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    END CATCH;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    IF @err IS NOT NULL THROW 53616, N'path1 signed call after rollback failed', 1;

    UPDATE #sig_counters SET pass = pass + 1;
    PRINT N'PASS: path1 ALTER -> unsigned fail -> ROLLBACK restore -> signed success';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    UPDATE #sig_counters SET fail = fail + 1;
    PRINT N'FAIL: path1 ' + ERROR_MESSAGE();
END CATCH;

-- Path 2: ALTER -> re-sign -> signed call succeeds -> ROLLBACK restores signature -> signed call succeeds.
BEGIN TRY
    BEGIN TRANSACTION;
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    SET @pos = CHARINDEX(N'CREATE PROCEDURE', @def);
    IF @pos = 0 THROW 53620, N'path2 definition lacks CREATE PROCEDURE', 1;
    SET @def = STUFF(@def, @pos, LEN(N'CREATE PROCEDURE'), N'ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 0 THROW 53621, N'path2 ALTER did not drop signature', 1;
    ADD SIGNATURE TO dbo.sp_assign_employee_business_role BY CERTIFICATE cert_role_sync;
    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 1 THROW 53622, N'path2 re-sign did not create signature', 1;

    SET @imp = 0; SET @err = NULL;
    BEGIN TRY
        EXECUTE AS USER = N'test_store_manager';
        SET @imp = 1;
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
        REVERT;
        SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    END CATCH;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    IF @err IS NOT NULL THROW 53623, N'path2 signed call failed before rollback', 1;

    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 1 THROW 53624, N'path2 ROLLBACK did not restore signature', 1;

    BEGIN TRANSACTION;
    SET @imp = 0; SET @err = NULL;
    BEGIN TRY
        EXECUTE AS USER = N'test_store_manager';
        SET @imp = 1;
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
        REVERT;
        SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    END CATCH;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    IF @err IS NOT NULL THROW 53625, N'path2 signed call after rollback failed', 1;

    UPDATE #sig_counters SET pass = pass + 1;
    PRINT N'PASS: path2 ALTER -> re-sign -> signed success -> ROLLBACK restore -> signed success';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    UPDATE #sig_counters SET fail = fail + 1;
    PRINT N'FAIL: path2 ' + ERROR_MESSAGE();
END CATCH;

-- Path 3: ALTER -> re-sign -> COMMIT -> signed call succeeds; ordinary role gets 229.
BEGIN TRY
    BEGIN TRANSACTION;
    SET @def = OBJECT_DEFINITION(OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    SET @pos = CHARINDEX(N'CREATE PROCEDURE', @def);
    IF @pos = 0 THROW 53630, N'path3 definition lacks CREATE PROCEDURE', 1;
    SET @def = STUFF(@def, @pos, LEN(N'CREATE PROCEDURE'), N'ALTER PROCEDURE');
    EXEC sys.sp_executesql @def;
    ADD SIGNATURE TO dbo.sp_assign_employee_business_role BY CERTIFICATE cert_role_sync;
    COMMIT TRANSACTION;
    SET @sigs = (SELECT COUNT(*) FROM sys.crypt_properties WHERE class = 1 AND major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'));
    IF @sigs <> 1 THROW 53631, N'path3 committed signature is not one', 1;

    BEGIN TRANSACTION;
    SET @imp = 0; SET @err = NULL;
    BEGIN TRY
        EXECUTE AS USER = N'test_store_manager';
        SET @imp = 1;
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
        REVERT;
        SET @imp = 0;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
    END CATCH;
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    IF @err IS NOT NULL THROW 53632, N'path3 signed call after commit failed', 1;

    SET @err = NULL; SET @msg = NULL;
    BEGIN TRY
        EXECUTE AS USER = N'test_cashier';
        EXEC dbo.sp_assign_employee_business_role @employee_id = @mgr,
             @business_role_id = @role, @assigned_by_employee_id = @mgr;
    END TRY
    BEGIN CATCH
        SET @err = ERROR_NUMBER(); SET @msg = ERROR_MESSAGE();
        IF XACT_STATE() <> 0 ROLLBACK;
        IF USER_NAME() <> N'dbo' REVERT;
    END CATCH;
    IF @err IS NULL OR @err <> 229 THROW 53633, N'path3 ordinary role was not denied with 229', 1;

    UPDATE #sig_counters SET pass = pass + 1;
    PRINT N'PASS: path3 ALTER -> re-sign -> COMMIT -> signed success; ordinary role 229';
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @imp = 1 BEGIN REVERT; SET @imp = 0; END;
    UPDATE #sig_counters SET fail = fail + 1;
    PRINT N'FAIL: path3 ' + ERROR_MESSAGE();
END CATCH;

DECLARE @pass INT = (SELECT pass FROM #sig_counters);
DECLARE @fail INT = (SELECT fail FROM #sig_counters);
PRINT N'RESULT: pass=' + CONVERT(NVARCHAR(10), @pass) + N' fail=' + CONVERT(NVARCHAR(10), @fail);
IF @pass + @fail <> 3 THROW 53699, N'signature acceptance denominator is not 3', 1;
IF @fail > 0 THROW 53698, N'signature acceptance failed', 1;
