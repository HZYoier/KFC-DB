-- B read-only post-migration check, run in the migrated database before resuming writes.
-- This is the baseline component of 13b, not the employee/authorization regression.
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
   OR OBJECT_ID(N'dbo.MigrationBatch', N'U') IS NULL
    THROW 51960, N'13b: migration metadata missing.', 1;

DECLARE @b13_batch BIGINT = (
    SELECT batch_id FROM dbo.SchemaVersion WHERE version_code = N'v1.0'
);
IF @b13_batch IS NULL OR NOT EXISTS (
    SELECT 1 FROM dbo.MigrationBatch WHERE batch_id = @b13_batch AND batch_status = 'COMPLETED'
)
    THROW 51960, N'13b: v1.0 does not point to a completed baseline.', 1;

DECLARE @b13_tables TABLE (id INT PRIMARY KEY, name SYSNAME, columns_expected INT);
INSERT @b13_tables VALUES (1,N'SalesOrder',15),(2,N'SalesOrderItem',10),
    (3,N'Payment',11),(4,N'Delivery',8),(5,N'PointLedger',9);

DECLARE @b13_i INT = 1, @b13_name SYSNAME, @b13_expected INT,
    @b13_source NVARCHAR(260), @b13_snapshot NVARCHAR(260), @b13_columns NVARCHAR(MAX),
    @b13_sql NVARCHAR(MAX), @b13_bad BIT, @b13_message NVARCHAR(2048);

WHILE @b13_i <= 5
BEGIN
    SELECT @b13_name = name, @b13_expected = columns_expected FROM @b13_tables WHERE id = @b13_i;
    SET @b13_source = N'dbo.' + QUOTENAME(@b13_name);
    SET @b13_snapshot = N'dbo.' + QUOTENAME(N'Baseline_' + @b13_name);
    IF (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(@b13_source, N'U')) <> @b13_expected
       OR (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(@b13_snapshot, N'U')) <> @b13_expected + 1
       OR EXISTS (
           SELECT name, system_type_id, max_length, precision, scale, is_nullable
           FROM sys.columns WHERE object_id = OBJECT_ID(@b13_source, N'U')
           EXCEPT
           SELECT name, system_type_id, max_length, precision, scale, is_nullable
           FROM sys.columns WHERE object_id = OBJECT_ID(@b13_snapshot, N'U') AND name <> N'batch_id'
       )
    BEGIN
        SET @b13_message = N'13b: baseline shape mismatch: ' + @b13_name;
        THROW 51961, @b13_message, 1;
    END;

    -- XML concatenation is compatible with the project's SQL compatibility level 130.
    SELECT @b13_columns = STUFF((
        SELECT N',' + CASE WHEN system_type_id IN (167,175,231,239)
            THEN N'CONVERT(VARBINARY(MAX),' + QUOTENAME(name) + N')'
            ELSE QUOTENAME(name) END
        FROM sys.columns WHERE object_id = OBJECT_ID(@b13_source, N'U')
        ORDER BY column_id FOR XML PATH(''), TYPE
    ).value('.', 'nvarchar(max)'), 1, 1, N'');
    SET @b13_sql = N'SELECT @bad = CASE WHEN '
        + N'(SELECT COUNT_BIG(*) FROM ' + @b13_source + N') <> '
        + N'(SELECT COUNT_BIG(*) FROM ' + @b13_snapshot + N' WHERE batch_id=@batch)'
        + N' OR EXISTS(SELECT ' + @b13_columns + N' FROM ' + @b13_source
        + N' EXCEPT SELECT ' + @b13_columns + N' FROM ' + @b13_snapshot + N' WHERE batch_id=@batch)'
        + N' OR EXISTS(SELECT ' + @b13_columns + N' FROM ' + @b13_snapshot + N' WHERE batch_id=@batch'
        + N' EXCEPT SELECT ' + @b13_columns + N' FROM ' + @b13_source + N') THEN 1 ELSE 0 END;';
    EXEC sys.sp_executesql @b13_sql, N'@batch BIGINT,@bad BIT OUTPUT', @b13_batch, @b13_bad OUTPUT;
    IF @b13_bad = 1
    BEGIN
        SET @b13_message = N'13b: row/value mismatch: ' + @b13_name;
        THROW 51962, @b13_message, 1;
    END;
    PRINT N'PASS 13b baseline ' + @b13_name;
    SET @b13_i += 1;
END;
PRINT N'RESULT 13b baseline: pass=5 fail=0 total=5';
