-- =====================================================================
-- 第三阶段 A 域：隔离级别实验（第 13 周，3.4）
-- 文件：sql/stage3/26a_isolation_experiment.sql
-- 属主：A
-- 目的：对照 READ COMMITTED 与 REPEATABLE READ，观察同一行库存在
--       并发更新前后的可见性；记录数据库是否启用 RCSI。
-- 形状：实验表 dbo.Stage3IsolationLab_A 与 Inventory 同构（只留
--       lab_id / on_hand_qty / note），不碰真实库存行，也不触发
--       InventoryAudit；真实库存行的锁等待/死锁由 C 的 26c 覆盖。
-- 用法（仓库根目录，两个终端）：
--   终端 0（建表）：
--     sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=setup -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
--   终端 1（会话 1，REPEATABLE READ）：
--     sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=1 -v Level=RR -i sql/stage3/26a_isolation_experiment.sql
--   终端 2（会话 2，在终端 1 启动后立刻运行）：
--     sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=2 -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
--   对照：把终端 1 的 Level 改成 RC 再跑一遍；最后 cleanup。
-- 预期：
--   RC：会话 1 第一次读 100，第二次读 105（会话 2 已提交）。
--   RR：会话 1 两次都读 100；会话 2 的 UPDATE 被 S 锁挡住，
--       等会话 1 提交后才执行。
--   RCSI=1 时，RC 的第二次读来自语句级快照，仍看到 105，但会话 2
--   不会被阻塞；不擅自修改数据库的 RCSI 设置。
-- =====================================================================
USE KFC_DB;
GO
SET NOCOUNT ON;
GO

IF '$(Session)' = 'setup'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NOT NULL
        THROW 54930, N'实验表已存在：先跑 -v Session=cleanup，勿覆盖未完成的实验。', 1;

    CREATE TABLE dbo.Stage3IsolationLab_A
    (
        lab_id      INT           NOT NULL PRIMARY KEY,
        on_hand_qty DECIMAL(12,3) NOT NULL,
        note        VARCHAR(50)   NOT NULL
    );
    INSERT INTO dbo.Stage3IsolationLab_A (lab_id, on_hand_qty, note)
    VALUES (1, 100.000, 'isolation-lab');

    SELECT
        lab_id,
        on_hand_qty,
        note,
        rcsi_enabled = (SELECT d.is_read_committed_snapshot_on
                        FROM sys.databases AS d
                        WHERE d.database_id = DB_ID())
    FROM dbo.Stage3IsolationLab_A;
    RETURN;
END;

IF '$(Session)' = 'cleanup'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NOT NULL
        DROP TABLE dbo.Stage3IsolationLab_A;
    PRINT N'26a：实验表已清理。';
    RETURN;
END;

IF '$(Session)' = '1'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NULL
        THROW 54930, N'缺少实验表：先跑 -v Session=setup。', 1;

    IF '$(Level)' = 'RR'
        SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
    ELSE
        SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

    BEGIN TRANSACTION;
    SELECT
        phase = N'S1-first',
        isolation_level = CASE transaction_isolation_level
                              WHEN 2 THEN 'READ COMMITTED'
                              WHEN 3 THEN 'REPEATABLE READ'
                              ELSE CONVERT(VARCHAR(10), transaction_isolation_level)
                          END,
        on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    CROSS JOIN (SELECT transaction_isolation_level FROM sys.dm_exec_sessions
                WHERE session_id = @@SPID) AS s
    WHERE lab_id = 1;

    WAITFOR DELAY '00:00:08';

    SELECT phase = N'S1-second', on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    WHERE lab_id = 1;

    COMMIT TRANSACTION;
    RETURN;
END;

IF '$(Session)' = '2'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NULL
        THROW 54930, N'缺少实验表：先跑 -v Session=setup。', 1;

    WAITFOR DELAY '00:00:03';

    BEGIN TRANSACTION;
    UPDATE dbo.Stage3IsolationLab_A
       SET on_hand_qty = on_hand_qty + 5.000
     WHERE lab_id = 1;
    COMMIT TRANSACTION;

    SELECT phase = N'S2-after-commit', on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    WHERE lab_id = 1;

    -- 等会话 1 完成第二次读，再把实验数据恢复原值；不删行。
    WAITFOR DELAY '00:00:08';

    BEGIN TRANSACTION;
    UPDATE dbo.Stage3IsolationLab_A
       SET on_hand_qty = on_hand_qty - 5.000
     WHERE lab_id = 1;
    COMMIT TRANSACTION;

    SELECT phase = N'S2-restored', on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    WHERE lab_id = 1;
    RETURN;
END;

THROW 54930, N'$(Session) 不是 setup/1/2/cleanup 之一；Level 用 RR 或 RC。', 1;
GO
