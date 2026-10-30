-- 2.2 baseline protocol verification (temporary test harness, 2026-10-30)
-- Assumes KFC_DB contains batches: 1 VOID, 2 COMPLETED, 3 COMPLETED, 4 VOID.
USE KFC_DB;
SET NOCOUNT ON;
DECLARE @pass INT = 0, @fail INT = 0, @msg NVARCHAR(400);
DECLARE @batches INT, @completed INT, @capturing INT, @meta INT, @total BIGINT;
DECLARE @tbl SYSNAME, @snap SYSNAME, @b BIGINT, @cnt BIGINT, @live BIGINT, @sql NVARCHAR(MAX);
DECLARE @digest CHAR(64), @v01 CHAR(64), @d2 CHAR(64), @d3 CHAR(64);
DECLARE @c1 INT, @c2 INT, @c3 INT;

SELECT @batches = COUNT(*), @completed = SUM(CASE WHEN batch_status='COMPLETED' THEN 1 ELSE 0 END),
       @capturing = SUM(CASE WHEN batch_status='CAPTURING' THEN 1 ELSE 0 END)
FROM dbo.MigrationBatch;
IF @batches = 4 AND @completed = 2 AND @capturing = 0
BEGIN SET @pass += 1; PRINT 'PASS: batch states (4 batches, 2 COMPLETED, 0 CAPTURING)'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: batch states'; END;

SELECT @meta = COUNT(*), @total = SUM(row_count) FROM dbo.MigrationBaseline WHERE batch_id = 2;
IF @meta = 25 AND @total = 178
BEGIN SET @pass += 1; PRINT 'PASS: batch 2 metadata 25 tables / 178 rows'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: batch 2 metadata'; END;

SELECT @meta = COUNT(*), @total = SUM(row_count) FROM dbo.MigrationBaseline WHERE batch_id = 3;
IF @meta = 25 AND @total = 178
BEGIN SET @pass += 1; PRINT 'PASS: batch 3 metadata 25 tables / 178 rows'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: batch 3 metadata'; END;

SELECT @v01 = object_digest FROM dbo.SchemaVersion WHERE version_code = N'v0.1';
SELECT @digest = dbo.fn_stage2_schema_digest();
SELECT @d2 = schema_digest FROM dbo.MigrationBatch WHERE batch_id = 2;
SELECT @d3 = schema_digest FROM dbo.MigrationBatch WHERE batch_id = 3;
IF @v01 = @digest AND @d2 = @digest AND @d3 = @digest
BEGIN SET @pass += 1; PRINT 'PASS: v0.1 digest equals live digest and both completed batches'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: schema digest mismatch'; END;

-- snapshot rows equal live rows for each completed batch/table
DECLARE cur CURSOR LOCAL FAST_FORWARD FOR SELECT table_name, snapshot_table FROM dbo.MigrationBaselineScope ORDER BY table_name;
OPEN cur;
FETCH NEXT FROM cur INTO @tbl, @snap;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @b = 2;
    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id = @b;';
    EXEC sys.sp_executesql @sql, N'@b BIGINT, @c BIGINT OUTPUT', @b, @cnt OUTPUT;
    SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@tbl) + N';';
    EXEC sys.sp_executesql @sql, N'@c BIGINT OUTPUT', @live OUTPUT;
    IF @cnt <> @live
    BEGIN SET @fail += 1; PRINT 'FAIL: snapshot row count ' + @tbl; END
    ELSE SET @pass += 1;
    FETCH NEXT FROM cur INTO @tbl, @snap;
END;
CLOSE cur;
DEALLOCATE cur;

IF (SELECT COUNT(*) FROM dbo.Baseline_Inventory WHERE batch_id IN (1,4)) = 0
BEGIN SET @pass += 1; PRINT 'PASS: failed/void batches have no snapshot rows (rollback)'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: failed/void snapshot rows remain'; END;

SELECT @c1 = current_points - ISNULL((SELECT SUM(point_delta) FROM dbo.Baseline_PointLedger
           WHERE batch_id=2 AND customer_id=1 AND ledger_status='EFFECTIVE'),0) FROM dbo.Baseline_Customer WHERE batch_id=2 AND customer_id=1;
SELECT @c2 = current_points - ISNULL((SELECT SUM(point_delta) FROM dbo.Baseline_PointLedger
           WHERE batch_id=2 AND customer_id=2 AND ledger_status='EFFECTIVE'),0) FROM dbo.Baseline_Customer WHERE batch_id=2 AND customer_id=2;
SELECT @c3 = current_points - ISNULL((SELECT SUM(point_delta) FROM dbo.Baseline_PointLedger
           WHERE batch_id=2 AND customer_id=3 AND ledger_status='EFFECTIVE'),0) FROM dbo.Baseline_Customer WHERE batch_id=2 AND customer_id=3;
IF @c1 = 0 AND @c2 = 500 AND @c3 = 1500
BEGIN SET @pass += 1; PRINT 'PASS: 13a opening offsets = 0/500/1500'; END
ELSE BEGIN SET @fail += 1; PRINT 'FAIL: opening offsets'; END;

SELECT @cnt = COUNT(*) FROM dbo.MigrationBaseline WHERE batch_id = 2 AND row_count = 0;
PRINT 'RESULT: pass=' + CONVERT(VARCHAR(10), @pass) + ' fail=' + CONVERT(VARCHAR(10), @fail);
IF @fail <> 0 THROW 53190, N'baseline protocol verification failed', 1;
