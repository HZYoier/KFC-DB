-- ============================================================================
-- capture_baseline.sql — 2.2 基线采集入口（成员 C；2026-10-30）
-- 协议与快照形状：docs/stage2/migration-guide.md（冻结件）
-- 用法（仓库根目录，应用已停写并完成备份）：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -i sql/stage2/capture_baseline.sql ^
--          -v SourceBaseline="<v0.1 commit>" -v ConfirmAppStopped=YES
-- 依赖：sql/stage2/baseline_a.sql / baseline_b.sql / baseline_c.sql（各域属主）
-- 本文件不得在应用运行中使用；采集会话结束前不要关闭连接。
-- ============================================================================
:on error exit
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO
USE KFC_DB;
GO

-- ---------------------------------------------------------------------------
-- 0. 入口守卫 + 辅助表 + 采集范围（幂等）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @source_baseline VARCHAR(50) = N'$(SourceBaseline)';
DECLARE @confirm_app_stopped VARCHAR(10) = N'$(ConfirmAppStopped)';
DECLARE @operator_note NVARCHAR(200) = NULL;

IF DB_ID(N'KFC_DB') IS NULL
    THROW 53100, N'capture: KFC_DB does not exist.', 1;
IF @source_baseline LIKE N'%$%' OR LEN(LTRIM(RTRIM(@source_baseline))) = 0
    THROW 53100, N'capture: SourceBaseline is required (v0.1 source identifier).', 1;
IF UPPER(LTRIM(RTRIM(@confirm_app_stopped))) <> N'YES'
    THROW 53100, N'capture: ConfirmAppStopped=YES is required; stop application writes first.', 1;
IF OBJECT_ID(N'dbo.Customer', N'U') IS NULL OR OBJECT_ID(N'dbo.SalesOrder', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Inventory', N'U') IS NULL OR OBJECT_ID(N'dbo.RolePermission', N'U') IS NULL
    THROW 53100, N'capture: v0.1 core tables are missing; deploy v0.1 first.', 1;

IF OBJECT_ID(N'dbo.SchemaVersion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.SchemaVersion (
        version_code  VARCHAR(20)  NOT NULL CONSTRAINT PK_SchemaVersion PRIMARY KEY,
        object_digest CHAR(64)     NOT NULL,
        batch_id      BIGINT       NULL,
        applied_at    DATETIME2(0) NOT NULL,
        note          NVARCHAR(200) NULL
    );
END;

IF OBJECT_ID(N'dbo.MigrationBatch', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationBatch (
        batch_id             BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MigrationBatch PRIMARY KEY,
        batch_status         VARCHAR(20) NOT NULL
            CONSTRAINT CK_MigrationBatch_status CHECK (batch_status IN ('CAPTURING','COMPLETED','FAILED','VOID')),
        previous_batch_id    BIGINT NULL
            CONSTRAINT FK_MigrationBatch_Previous REFERENCES dbo.MigrationBatch(batch_id),
        source_baseline      VARCHAR(50) NOT NULL,
        capture_scope_version VARCHAR(20) NOT NULL,
        schema_digest        CHAR(64) NOT NULL,
        app_stop_confirmed   BIT NOT NULL,
        operator_note        NVARCHAR(200) NULL,
        capture_started_at   DATETIME2(0) NOT NULL,
        capture_completed_at DATETIME2(0) NULL,
        failed_at            DATETIME2(0) NULL,
        error_detail         NVARCHAR(1000) NULL,
        voided_at            DATETIME2(0) NULL,
        void_reason          NVARCHAR(200) NULL
    );
END;

IF OBJECT_ID(N'dbo.MigrationBaselineScope', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationBaselineScope (
        domain_code    CHAR(1)      NOT NULL,
        table_name     VARCHAR(128) NOT NULL CONSTRAINT PK_MigrationBaselineScope PRIMARY KEY,
        snapshot_table VARCHAR(128) NOT NULL
    );
END;

IF OBJECT_ID(N'dbo.MigrationBaseline', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.MigrationBaseline (
        batch_id         BIGINT       NOT NULL,
        domain_code      CHAR(1)      NOT NULL,
        table_name       VARCHAR(128) NOT NULL,
        snapshot_table   VARCHAR(128) NOT NULL,
        row_count        BIGINT       NOT NULL,
        content_checksum INT          NULL,
        captured_at      DATETIME2(0) NOT NULL,
        CONSTRAINT PK_MigrationBaseline PRIMARY KEY (batch_id, table_name),
        CONSTRAINT FK_MigrationBaseline_Batch FOREIGN KEY (batch_id) REFERENCES dbo.MigrationBatch(batch_id)
    );
END;

MERGE dbo.MigrationBaselineScope AS t
USING (VALUES
    ('A','Category','Baseline_Category'),
    ('A','MemberLevel','Baseline_MemberLevel'),
    ('A','Ingredient','Baseline_Ingredient'),
    ('A','Product','Baseline_Product'),
    ('A','ProductCategory','Baseline_ProductCategory'),
    ('A','Customer','Baseline_Customer'),
    ('A','ProductBom','Baseline_ProductBom'),
    ('A','ComboComponent','Baseline_ComboComponent'),
    ('A','Promotion','Baseline_Promotion'),
    ('A','PromotionProductRule','Baseline_PromotionProductRule'),
    ('B','SalesOrder','Baseline_SalesOrder'),
    ('B','SalesOrderItem','Baseline_SalesOrderItem'),
    ('B','Payment','Baseline_Payment'),
    ('B','Delivery','Baseline_Delivery'),
    ('B','PointLedger','Baseline_PointLedger'),
    ('C','Inventory','Baseline_Inventory'),
    ('C','InventoryMovement','Baseline_InventoryMovement'),
    ('C','ReplenishmentSuggestion','Baseline_ReplenishmentSuggestion'),
    ('C','PurchaseOrder','Baseline_PurchaseOrder'),
    ('C','PurchaseOrderItem','Baseline_PurchaseOrderItem'),
    ('C','EmployeeAccount','Baseline_EmployeeAccount'),
    ('C','BusinessRole','Baseline_BusinessRole'),
    ('C','EmployeeBusinessRole','Baseline_EmployeeBusinessRole'),
    ('C','RolePermission','Baseline_RolePermission'),
    ('C','AuditLog','Baseline_AuditLog')
) AS s(domain_code, table_name, snapshot_table)
ON t.table_name = s.table_name
WHEN MATCHED AND (t.domain_code <> s.domain_code OR t.snapshot_table <> s.snapshot_table) THEN
    UPDATE SET domain_code = s.domain_code, snapshot_table = s.snapshot_table
WHEN NOT MATCHED THEN
    INSERT (domain_code, table_name, snapshot_table) VALUES (s.domain_code, s.table_name, s.snapshot_table);

IF (SELECT COUNT(*) FROM dbo.MigrationBaselineScope) <> 25
    THROW 53100, N'capture: MigrationBaselineScope must contain exactly 25 tables.', 1;

DENY SELECT, INSERT, UPDATE, DELETE ON dbo.MigrationBatch TO public;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.MigrationBaseline TO public;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.MigrationBaselineScope TO public;
DENY SELECT, INSERT, UPDATE, DELETE ON dbo.SchemaVersion TO public;
GO

-- ---------------------------------------------------------------------------
-- 1. 摘要函数（迁移入口复用，禁止两处各写一套）
-- ---------------------------------------------------------------------------
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER FUNCTION dbo.fn_stage2_schema_digest()
RETURNS CHAR(64)
AS
BEGIN
    DECLARE @txt NVARCHAR(MAX);
    ;WITH pieces AS (
        SELECT CONVERT(NVARCHAR(MAX), 1) AS ord,
               CONVERT(NVARCHAR(MAX), CONCAT(N'O|', o.name, N'|', o.type)) AS piece
        FROM sys.objects o
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.is_ms_shipped = 0
          AND o.type IN ('U','V','P','FN','IF','TF')
          AND o.name NOT LIKE N'Migration%'
          AND o.name NOT LIKE N'Baseline[_]%'
          AND o.name NOT IN (N'SchemaVersion', N'fn_stage2_schema_digest', N'sp_mark_baseline_failed', N'sp_void_baseline_batch')
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 2),
               CONVERT(NVARCHAR(MAX), CONCAT(N'C|', OBJECT_NAME(c.object_id), N'|', c.column_id, N'|', c.name, N'|',
                   TYPE_NAME(c.user_type_id), N'|', c.max_length, N'|', c.precision, N'|', c.scale, N'|',
                   c.is_nullable, N'|', c.is_identity))
        FROM sys.columns c
        JOIN sys.objects o ON o.object_id = c.object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.is_ms_shipped = 0 AND o.type = 'U'
          AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%' AND o.name <> N'SchemaVersion'
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 3),
               CONVERT(NVARCHAR(MAX), CONCAT(N'K|', OBJECT_NAME(k.parent_object_id), N'|', k.name, N'|', k.type, N'|',
                   k.unique_index_id))
        FROM sys.key_constraints k
        JOIN sys.objects o ON o.object_id = k.parent_object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 4),
               CONVERT(NVARCHAR(MAX), CONCAT(N'FK|', fk.name, N'|', OBJECT_NAME(fk.parent_object_id), N'|',
                   OBJECT_NAME(fk.referenced_object_id), N'|', fk.is_disabled, N'|',
                   (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), CONCAT(COL_NAME(fkc.parent_object_id, fkc.parent_column_id), N'>',
                       COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id))) COLLATE DATABASE_DEFAULT, N',' COLLATE DATABASE_DEFAULT)
                           WITHIN GROUP (ORDER BY fkc.constraint_column_id)
                    FROM sys.foreign_key_columns fkc WHERE fkc.constraint_object_id = fk.object_id)))
        FROM sys.foreign_keys fk
        JOIN sys.objects o ON o.object_id = fk.parent_object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 5),
               CONVERT(NVARCHAR(MAX), CONCAT(N'IX|', OBJECT_NAME(i.object_id), N'|', i.name, N'|', i.type, N'|', i.is_unique, N'|',
                   ISNULL(i.filter_definition, N''), N'|',
                   (SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), COL_NAME(ic.object_id, ic.column_id)) COLLATE DATABASE_DEFAULT, N',' COLLATE DATABASE_DEFAULT)
                        WITHIN GROUP (ORDER BY ic.key_ordinal)
                    FROM sys.index_columns ic WHERE ic.object_id = i.object_id AND ic.index_id = i.index_id)))
        FROM sys.indexes i
        JOIN sys.objects o ON o.object_id = i.object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.is_ms_shipped = 0
          AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
          AND i.is_hypothetical = 0
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 6),
               CONVERT(NVARCHAR(MAX), CONCAT(N'D|', OBJECT_NAME(d.parent_object_id), N'|', d.name, N'|',
                   CONVERT(NVARCHAR(MAX), d.definition)))
        FROM sys.default_constraints d
        JOIN sys.objects o ON o.object_id = d.parent_object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 7),
               CONVERT(NVARCHAR(MAX), CONCAT(N'CK|', cc.name, N'|', OBJECT_NAME(cc.parent_object_id), N'|',
                   CONVERT(NVARCHAR(MAX), cc.definition)))
        FROM sys.check_constraints cc
        JOIN sys.objects o ON o.object_id = cc.parent_object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
        UNION ALL
        SELECT CONVERT(NVARCHAR(MAX), 8),
               CONVERT(NVARCHAR(MAX), CONCAT(N'M|', OBJECT_NAME(m.object_id), N'|', m.definition))
        FROM sys.sql_modules m
        JOIN sys.objects o ON o.object_id = m.object_id
        WHERE o.schema_id = SCHEMA_ID(N'dbo') AND o.is_ms_shipped = 0
          AND o.name NOT LIKE N'Migration%' AND o.name NOT LIKE N'Baseline[_]%'
          AND o.name NOT IN (N'SchemaVersion', N'fn_stage2_schema_digest', N'sp_mark_baseline_failed', N'sp_void_baseline_batch')
    )
    SELECT @txt = STRING_AGG(piece COLLATE DATABASE_DEFAULT, NCHAR(10) COLLATE DATABASE_DEFAULT) WITHIN GROUP (ORDER BY ord, piece COLLATE DATABASE_DEFAULT) FROM pieces;
    RETURN CONVERT(CHAR(64), HASHBYTES('SHA2_256', ISNULL(@txt, N'')), 2);
END;
GO

-- ---------------------------------------------------------------------------
-- 2. 失败标记 / 作废（操作者显式调用；不自动改 COMPLETED）
-- ---------------------------------------------------------------------------
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.sp_mark_baseline_failed
    @batch_id BIGINT,
    @error_detail NVARCHAR(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rc INT;
    EXEC @rc = sys.sp_getapplock @Resource = N'KFC_DB.Stage2Migration', @LockMode = 'Exclusive',
                                 @LockOwner = 'Session', @LockTimeout = 0;
    IF @rc < 0
        THROW 53102, N'mark_failed: migration lock is held by another session.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch WHERE batch_id = @batch_id AND batch_status = 'CAPTURING')
        THROW 53101, N'mark_failed: batch must exist in CAPTURING state.', 1;
    UPDATE dbo.MigrationBatch
       SET batch_status = 'FAILED', failed_at = SYSDATETIME(),
           error_detail = LEFT(ISNULL(@error_detail, N'(no detail)'), 1000)
     WHERE batch_id = @batch_id AND batch_status = 'CAPTURING';
END;
GO

SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO
CREATE OR ALTER PROCEDURE dbo.sp_void_baseline_batch
    @batch_id BIGINT,
    @reason NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @rc INT;
    EXEC @rc = sys.sp_getapplock @Resource = N'KFC_DB.Stage2Migration', @LockMode = 'Exclusive',
                                 @LockOwner = 'Session', @LockTimeout = 0;
    IF @rc < 0
        THROW 53102, N'void: migration lock is held by another session.', 1;
    IF NOT EXISTS (SELECT 1 FROM dbo.MigrationBatch WHERE batch_id = @batch_id AND batch_status = 'FAILED')
        THROW 53103, N'void: only FAILED -> VOID is allowed.', 1;
    UPDATE dbo.MigrationBatch
       SET batch_status = 'VOID', voided_at = SYSDATETIME(), void_reason = LEFT(ISNULL(@reason, N''), 200)
     WHERE batch_id = @batch_id AND batch_status = 'FAILED';
END;
GO

-- ---------------------------------------------------------------------------
-- 3. 采集主体（一个会话、一个采集事务）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @source_baseline VARCHAR(50) = N'$(SourceBaseline)';
DECLARE @confirm_app_stopped VARCHAR(10) = N'$(ConfirmAppStopped)';
DECLARE @operator_note NVARCHAR(200) = NULL;
IF @source_baseline LIKE N'%$%' OR LEN(LTRIM(RTRIM(@source_baseline))) = 0
    THROW 53100, N'capture: SourceBaseline is required.', 1;
IF UPPER(LTRIM(RTRIM(@confirm_app_stopped))) <> N'YES'
    THROW 53100, N'capture: ConfirmAppStopped=YES is required.', 1;

DECLARE @rc INT;
EXEC @rc = sys.sp_getapplock @Resource = N'KFC_DB.Stage2Migration', @LockMode = 'Exclusive',
                             @LockOwner = 'Session', @LockTimeout = 0;
IF @rc < 0
    THROW 53110, N'capture: migration lock is held by another session.', 1;

IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v1.0')
    THROW 53111, N'capture: database is already v1.0; baseline capture is not allowed.', 1;

DECLARE @schema_digest CHAR(64) = dbo.fn_stage2_schema_digest();
IF EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v0.1' AND object_digest <> @schema_digest)
    THROW 53112, N'capture: live schema differs from registered v0.1 digest; stop and re-baseline.', 1;
IF EXISTS (SELECT 1 FROM dbo.MigrationBaselineScope s WHERE OBJECT_ID(N'dbo.' + s.table_name, N'U') IS NULL)
    THROW 53116, N'capture: a v0.1 business table in scope is missing.', 1;

DECLARE @previous_batch_id BIGINT = (SELECT MAX(batch_id) FROM dbo.MigrationBatch);
DECLARE @batch_id BIGINT;

BEGIN TRANSACTION;
INSERT INTO dbo.MigrationBatch
    (batch_status, previous_batch_id, source_baseline, capture_scope_version, schema_digest,
     app_stop_confirmed, operator_note, capture_started_at)
VALUES
    ('CAPTURING', @previous_batch_id, @source_baseline, '2.2-v1', @schema_digest,
     1, @operator_note, SYSDATETIME());
SET @batch_id = SCOPE_IDENTITY();
COMMIT TRANSACTION;

BEGIN TRY
    BEGIN TRANSACTION;

    -- 各域快照（文件不得含 GO / 事务；使用本批 @batch_id）
    :r sql/stage2/baseline_a.sql
    :r sql/stage2/baseline_b.sql
    :r sql/stage2/baseline_c.sql

    -- 校验快照列契约、行数，并写元数据；摘要只作辅助定位
    DECLARE @dom CHAR(1), @tbl SYSNAME, @snap SYSNAME, @cnt BIGINT, @live BIGINT,
            @chk INT, @bad INT, @sql NVARCHAR(MAX), @collist NVARCHAR(MAX);
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT domain_code, table_name, snapshot_table FROM dbo.MigrationBaselineScope ORDER BY table_name;
    OPEN cur;
    FETCH NEXT FROM cur INTO @dom, @tbl, @snap;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        IF OBJECT_ID(N'dbo.' + @snap, N'U') IS NULL
            THROW 53113, N'capture: snapshot table is missing for a scope table.', 1;

        SET @sql = N'
            SELECT @bad = COUNT(*) FROM (
                SELECT c.name AS col_name, TYPE_NAME(c.user_type_id) AS col_type, c.max_length AS col_len,
                       c.precision AS col_prec, c.scale AS col_scale, c.is_nullable AS col_null
                FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''dbo.' + @tbl + N''')
                EXCEPT
                SELECT c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.is_nullable
                FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''dbo.' + @snap + N''') AND c.name <> N''batch_id''
            ) x;';
        EXEC sys.sp_executesql @sql, N'@bad INT OUTPUT', @bad = @bad OUTPUT;
        IF @bad <> 0
            THROW 53114, N'capture: snapshot columns do not match the business table.', 1;
        SET @sql = N'
            SELECT @bad = COUNT(*) FROM (
                SELECT c.name AS col_name, TYPE_NAME(c.user_type_id) AS col_type, c.max_length AS col_len,
                       c.precision AS col_prec, c.scale AS col_scale, c.is_nullable AS col_null
                FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''dbo.' + @snap + N''') AND c.name <> N''batch_id''
                EXCEPT
                SELECT c.name, TYPE_NAME(c.user_type_id), c.max_length, c.precision, c.scale, c.is_nullable
                FROM sys.columns c WHERE c.object_id = OBJECT_ID(N''dbo.' + @tbl + N''')
            ) x;';
        EXEC sys.sp_executesql @sql, N'@bad INT OUTPUT', @bad = @bad OUTPUT;
        IF @bad <> 0
            THROW 53114, N'capture: snapshot has extra columns.', 1;
        IF NOT EXISTS (SELECT 1 FROM sys.columns
                       WHERE object_id = OBJECT_ID(N'dbo.' + @snap) AND name = N'batch_id'
                         AND TYPE_NAME(user_type_id) = N'bigint' AND is_nullable = 0)
            THROW 53114, N'capture: snapshot batch_id column must be BIGINT NOT NULL.', 1;

        SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id = @b;';
        EXEC sys.sp_executesql @sql, N'@b BIGINT, @c BIGINT OUTPUT', @batch_id, @cnt OUTPUT;
        SET @sql = N'SELECT @c = COUNT_BIG(*) FROM dbo.' + QUOTENAME(@tbl) + N';';
        EXEC sys.sp_executesql @sql, N'@c BIGINT OUTPUT', @live OUTPUT;
        IF @cnt <> @live
            THROW 53115, N'capture: snapshot row count does not match the live table.', 1;

        SET @sql = N'SELECT @collist = STRING_AGG(CONVERT(NVARCHAR(MAX), QUOTENAME(name)) COLLATE DATABASE_DEFAULT, NCHAR(44) COLLATE DATABASE_DEFAULT) WITHIN GROUP (ORDER BY column_id)
                     FROM sys.columns WHERE object_id = OBJECT_ID(N''dbo.' + @snap + N''') AND name <> N''batch_id'' AND max_length <> -1;';
        EXEC sys.sp_executesql @sql, N'@collist NVARCHAR(MAX) OUTPUT', @collist = @collist OUTPUT;
        SET @sql = N'SELECT @k = CHECKSUM_AGG(BINARY_CHECKSUM(' + @collist + N')) FROM dbo.' + QUOTENAME(@snap) + N' WHERE batch_id = @b;';
        EXEC sys.sp_executesql @sql, N'@b BIGINT, @k INT OUTPUT', @batch_id, @chk OUTPUT;

        INSERT INTO dbo.MigrationBaseline
            (batch_id, domain_code, table_name, snapshot_table, row_count, content_checksum, captured_at)
        VALUES (@batch_id, @dom, @tbl, @snap, @cnt, @chk, SYSDATETIME());

        FETCH NEXT FROM cur INTO @dom, @tbl, @snap;
    END;
    CLOSE cur;
    DEALLOCATE cur;

    IF (SELECT COUNT(*) FROM dbo.MigrationBaseline WHERE batch_id = @batch_id) <> 25
        THROW 53116, N'capture: baseline metadata must contain exactly 25 tables.', 1;

    UPDATE dbo.MigrationBatch
       SET batch_status = 'COMPLETED', capture_completed_at = SYSDATETIME()
     WHERE batch_id = @batch_id AND batch_status = 'CAPTURING';

    IF NOT EXISTS (SELECT 1 FROM dbo.SchemaVersion WHERE version_code = N'v0.1')
        INSERT INTO dbo.SchemaVersion (version_code, object_digest, batch_id, applied_at, note)
        VALUES (N'v0.1', @schema_digest, @batch_id, SYSDATETIME(), N'baseline capture');

    COMMIT TRANSACTION;
    PRINT N'PASS: baseline batch completed.';
    SELECT @batch_id AS batch_id, @schema_digest AS schema_digest;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    DECLARE @err NVARCHAR(1000) = LEFT(ERROR_MESSAGE(), 1000);
    BEGIN TRY
        BEGIN TRANSACTION;
        UPDATE dbo.MigrationBatch
           SET batch_status = 'FAILED', failed_at = SYSDATETIME(), error_detail = @err
         WHERE batch_id = @batch_id AND batch_status = 'CAPTURING';
        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    END CATCH;
    PRINT N'FAIL: baseline batch failed and was marked FAILED where possible.';
    THROW;
END CATCH;
GO
