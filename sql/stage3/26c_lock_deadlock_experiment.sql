-- C 域并发实验；复跑方式和取证时机见 docs/stage3/concurrency.md。
-- 显式 -d 一次性 KFC_DB 或 KFC_DB_*；所有业务写入回滚。
-- -v Mode=wait|timeout|deadlock|ordered|observe|graph Session=1|2 IngredientA=<id> IngredientB=<id>
:on error exit
SET NOCOUNT ON;
SET XACT_ABORT ON;
SET TRANSACTION ISOLATION LEVEL READ COMMITTED;
SET LANGUAGE us_english;

DECLARE @mode VARCHAR(32) = '$(Mode)', @session INT = TRY_CONVERT(INT, '$(Session)');
DECLARE @a BIGINT = TRY_CONVERT(BIGINT, '$(IngredientA)'),
        @b BIGINT = TRY_CONVERT(BIGINT, '$(IngredientB)');
IF DB_NAME() <> N'KFC_DB' AND DB_NAME() NOT LIKE N'KFC[_]DB[_]%'
    THROW 54940, N'26c: select a disposable KFC_DB or KFC_DB_* using -d.', 1;
IF @mode NOT IN ('wait', 'timeout', 'deadlock', 'ordered', 'observe', 'graph')
    THROW 54940, N'26c: invalid Mode.', 1;

IF @mode = 'observe'
BEGIN
    -- 连接标签在事务前写入；用 sys.dm_exec_sessions 关联本库的实验会话。
    SELECT s.session_id, r.blocking_session_id, r.wait_type, r.wait_time, r.wait_resource
    FROM sys.dm_exec_sessions AS s
    JOIN sys.dm_exec_requests AS r ON r.session_id = s.session_id
    WHERE r.database_id = DB_ID() AND SUBSTRING(s.context_info, 1, 3) = 0x323663;

    SELECT l.request_session_id, l.resource_type, l.request_mode, l.request_status,
           l.resource_associated_entity_id, l.resource_description,
           OBJECT_NAME(p.object_id) AS object_name
    FROM sys.dm_tran_locks AS l
    JOIN sys.dm_exec_sessions AS s ON s.session_id = l.request_session_id
    LEFT JOIN sys.partitions AS p ON p.hobt_id = l.resource_associated_entity_id
    WHERE l.resource_database_id = DB_ID() AND SUBSTRING(s.context_info, 1, 3) = 0x323663
    ORDER BY l.request_session_id, l.request_status, l.resource_type;
    RETURN;
END;

IF @mode = 'graph'
BEGIN
    DECLARE @db_id INT = DB_ID();
    -- 读取最近的本库死锁图；用事件 UTC 时间、SPID 和对象名匹配本轮。
    ;WITH health AS
    (
        SELECT TRY_CAST(t.target_data AS XML) AS data
        FROM sys.dm_xe_sessions AS s
        JOIN sys.dm_xe_session_targets AS t ON t.event_session_address = s.address
        WHERE s.name = N'system_health' AND t.target_name = N'ring_buffer'
    )
    SELECT TOP (10) e.event.value('(@timestamp)[1]', 'datetimeoffset(3)') AS event_utc,
           e.event.query('(data/value/deadlock)[1]') AS deadlock_graph
    FROM health
    CROSS APPLY health.data.nodes('/RingBufferTarget/event[@name="xml_deadlock_report"]') AS e(event)
    WHERE e.event.exist('data/value/deadlock/process-list/process[@currentdb=sql:variable("@db_id")]') = 1
    ORDER BY event_utc DESC;
    RETURN;
END;

IF @session IS NULL OR @session NOT IN (1, 2) OR @a IS NULL OR @b IS NULL OR @a >= @b
    THROW 54940, N'26c: supply Session=1 or 2 and two inventory IDs with IngredientA < IngredientB.', 1;
IF OBJECT_ID(N'dbo.tr_Inventory_Audit', N'TR') IS NULL
   OR OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NULL
   OR OBJECT_ID(N'dbo.sp_adjust_inventory', N'P') IS NULL
    THROW 54941, N'26c: deploy v1.0 and 20/21c/22c before the experiment.', 1;

DECLARE @employee BIGINT = (
    SELECT employee_id FROM dbo.EmployeeAccount
    WHERE database_user_name = N'test_store_manager' AND status = 'ACTIVE'
);
DECLARE @hold CHAR(8) = CASE WHEN @session = 1 THEN '00:00:12' ELSE '00:00:00' END;
DECLARE @first BIGINT = CASE WHEN @mode = 'deadlock' AND @session = 2 THEN @b ELSE @a END;
DECLARE @second BIGINT = CASE WHEN @mode = 'deadlock' AND @session = 2 THEN @a ELSE @b END;
DECLARE @quantity DECIMAL(12,3), @impersonating BIT = 0;
DECLARE @started DATETIME2(3), @elapsed INT;
DECLARE @expected_error INT = CASE
    WHEN @mode = 'timeout' AND @session = 2 THEN 1222
    WHEN @mode = 'deadlock' AND @session = 2 THEN 1205
END;

IF @mode IN ('wait', 'timeout') AND @employee IS NULL
    THROW 54941, N'26c: the active test_store_manager fixture is missing.', 1;

SET CONTEXT_INFO 0x323663;
IF @mode = 'timeout' AND @session = 2
    SET LOCK_TIMEOUT 3000;
ELSE
    SET LOCK_TIMEOUT 25000;
IF @mode = 'deadlock' AND @session = 2
    SET DEADLOCK_PRIORITY LOW;
ELSE
    SET DEADLOCK_PRIORITY NORMAL;

SELECT started_utc = SYSUTCDATETIME(), spid = @@SPID, mode = @mode,
       lab_session = @session, first_ingredient = @first, second_ingredient = @second;

BEGIN TRY
    BEGIN TRANSACTION;
    SET @started = SYSUTCDATETIME();

    IF @mode IN ('wait', 'timeout')
    BEGIN
        EXECUTE AS USER = N'test_store_manager';
        SET @impersonating = 1;
        EXEC dbo.sp_adjust_inventory @ingredient_id = @a, @on_hand_delta = 1.000,
                                     @employee_id = @employee, @reason = N'26c lock wait';
        REVERT;
        SET @impersonating = 0;
        SET @elapsed = DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME());
    END
    ELSE
    BEGIN
        SELECT @quantity = on_hand_qty
        FROM dbo.Inventory WITH (UPDLOCK, ROWLOCK)
        WHERE ingredient_id = @first;
        IF @quantity IS NULL
            THROW 54941, N'26c: first inventory row is missing.', 1;
    END;

    DECLARE @ready NVARCHAR(200) = CONCAT(N'26c first lock: spid=', @@SPID, N' ingredient_id=', @first);
    RAISERROR(@ready, 10, 1) WITH NOWAIT;
    WAITFOR DELAY @hold;

    IF @mode IN ('deadlock', 'ordered')
    BEGIN
        SET @quantity = NULL;
        SELECT @quantity = on_hand_qty
        FROM dbo.Inventory WITH (UPDLOCK, ROWLOCK)
        WHERE ingredient_id = @second;
        IF @quantity IS NULL
            THROW 54941, N'26c: second inventory row is missing.', 1;
        SET @elapsed = DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME());
    END;

    ROLLBACK TRANSACTION;
    IF @expected_error IS NOT NULL
        THROW 54942, N'26c: expected timeout or victim error was absent; check launch timing.', 1;
END TRY
BEGIN CATCH
    DECLARE @error INT = ERROR_NUMBER(), @message NVARCHAR(2048) = ERROR_MESSAGE();
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @impersonating = 1 REVERT;

    IF @expected_error IS NULL OR @error <> @expected_error
       OR (@error = 1222 AND @message NOT LIKE N'%Lock request time out period exceeded%')
       OR (@error = 1205 AND @message NOT LIKE N'%chosen as the deadlock victim%')
        THROW;

    SET @elapsed = DATEDIFF(MILLISECOND, @started, SYSUTCDATETIME());
    SELECT expected_error = @error, error_message = @message;
END CATCH;

IF @@TRANCOUNT <> 0
    THROW 54942, N'26c: unexpected transaction left open.', 1;
SELECT elapsed_ms = @elapsed, open_transactions = @@TRANCOUNT;
PRINT N'RESULT: 26c pass=1 fail=0';
GO
