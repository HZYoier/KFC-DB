-- Temporary verification for the first real 25-table capture (2026-11-03).
-- Compares every snapshot table with its live business table in both directions.
USE KFC_DB;
SET NOCOUNT ON;

DECLARE @b BIGINT = (SELECT batch_id FROM dbo.SchemaVersion WHERE version_code = N'v0.1');
DECLARE @tbl SYSNAME, @snap SYSNAME, @collist NVARCHAR(MAX), @sql NVARCHAR(MAX);
DECLARE @bad INT, @pass INT = 0, @fail INT = 0, @rows BIGINT;
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
    SELECT table_name, snapshot_table FROM dbo.MigrationBaselineScope ORDER BY table_name;

IF @b IS NULL THROW 53190, N'v0.1 batch missing', 1;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl, @snap;
WHILE @@FETCH_STATUS = 0
BEGIN
    SELECT @collist = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)) COLLATE DATABASE_DEFAULT,
                                 N',' COLLATE DATABASE_DEFAULT)
               WITHIN GROUP (ORDER BY column_id)
    FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.' + @snap) AND name <> N'batch_id';

    SET @sql = N'SELECT @bad = COUNT(*) FROM ('
        + N'SELECT ' + @collist + N' FROM dbo.' + QUOTENAME(@tbl)
        + N' EXCEPT SELECT ' + @collist + N' FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id=@b'
        + N') x;';
    EXEC sys.sp_executesql @sql, N'@b BIGINT, @bad INT OUTPUT', @b, @bad OUTPUT;
    IF @bad <> 0
    BEGIN
        PRINT N'FAIL: live->snapshot value mismatch: ' + @tbl;
        SET @fail += 1;
    END
    ELSE
    BEGIN
        SET @sql = N'SELECT @bad = COUNT(*) FROM ('
            + N'SELECT ' + @collist + N' FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id=@b'
            + N' EXCEPT SELECT ' + @collist + N' FROM dbo.' + QUOTENAME(@tbl)
            + N') x;';
        EXEC sys.sp_executesql @sql, N'@b BIGINT, @bad INT OUTPUT', @b, @bad OUTPUT;
        IF @bad <> 0
        BEGIN
            PRINT N'FAIL: snapshot->live value mismatch: ' + @tbl;
            SET @fail += 1;
        END
        ELSE
        BEGIN
            SET @sql = N'SELECT @rows = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@tbl) + N';';
            EXEC sys.sp_executesql @sql, N'@rows BIGINT OUTPUT', @rows OUTPUT;
            PRINT N'PASS: ' + @tbl + N' (' + CONVERT(NVARCHAR(20), @rows) + N' rows, exact both ways)';
            SET @pass += 1;
        END
    END
    FETCH NEXT FROM cur INTO @tbl, @snap;
END
CLOSE cur;
DEALLOCATE cur;

PRINT N'RESULT: pass=' + CONVERT(NVARCHAR(10), @pass) + N' fail=' + CONVERT(NVARCHAR(10), @fail);
IF @fail <> 0 THROW 53191, N'real capture value verification failed', 1;
