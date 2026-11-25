-- =====================================================================
-- 第三阶段 A 域：隔离级别实验（第 13 周，3.4）
-- 文件：sql/stage3/26a_isolation_experiment.sql
-- 属主：A
-- 目的：用库存 P（实验表，初值 10）对照：
--       1) 脏读：S1 补货更新未提交，S2 用 READ UNCOMMITTED / READ COMMITTED 读取；
--       2) 不可重复读：S1 在 READ COMMITTED / REPEATABLE READ 下两次读，
--          S2 在两次读之间提交 +5 的补货更新。
-- 形状：dbo.Stage3IsolationLab_A 与 Inventory 同构（只留 P=lab_id=1），
--       不碰真实 Inventory，也不触发 InventoryAudit；真实库存的业务
--       锁等待/死锁由 B/C 的 26b/26c 覆盖。实验结束 cleanup 删表。
-- 用法（仓库根目录，两个终端；每条命令都要带 -v）：
--   初始化：
--     sqlcmd -S localhost -E -C -f 65001 -b -d KFC_DB -v Session=setup -v Mode=NA -v Level=NA -i sql/stage3/26a_isolation_experiment.sql
--   脏读：S1 先启动，S2 在 S1 后约 3 秒启动；Level=RU 或 RC
--     sqlcmd ... -v Session=1 -v Mode=dirty -v Level=NA ...
--     sqlcmd ... -v Session=2 -v Mode=dirty -v Level=RU ...
--   不可重复读：S1 先启动，S2 约 3 秒后启动；Level=RC 或 RR
--     sqlcmd ... -v Session=1 -v Mode=nonrepeat -v Level=RC ...
--     sqlcmd ... -v Session=2 -v Mode=nonrepeat -v Level=NA ...
--   清理：
--     sqlcmd ... -v Session=cleanup -v Mode=NA -v Level=NA ...
-- 预期：
--   dirty + RU：S2 第一次读 15（未提交），S1 回滚后第二次读 10；
--   dirty + RC：S2 第一次读等待 S1 回滚，随后两次都读 10；
--   nonrepeat + RC：S1 两次读 10 / 15；
--   nonrepeat + RR：S1 两次都读 10，S2 的 +5 更新等 S1 提交后才完成。
--   RCSI=1 时另记 RC 的快照读结果；不擅自修改数据库设置。
-- =====================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF DB_NAME() <> N'KFC_DB' AND DB_NAME() NOT LIKE N'KFC[_]DB[_]%'
    THROW 54930, N'26a: 请在 KFC_DB 或一次性 KFC_DB_* 测试库上运行。', 1;

DECLARE @session VARCHAR(10) = LOWER(LTRIM(RTRIM('$(Session)')));
DECLARE @mode    VARCHAR(20) = LOWER(LTRIM(RTRIM('$(Mode)')));
DECLARE @level   VARCHAR(10) = UPPER(LTRIM(RTRIM('$(Level)')));

IF @session = 'setup'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NOT NULL
        THROW 54930, N'26a：实验表已存在，先跑 Session=cleanup，勿覆盖未完成的实验。', 1;

    CREATE TABLE dbo.Stage3IsolationLab_A
    (
        lab_id      INT           NOT NULL PRIMARY KEY,
        on_hand_qty DECIMAL(12,3) NOT NULL,
        note        VARCHAR(50)   NOT NULL
    );
    INSERT INTO dbo.Stage3IsolationLab_A (lab_id, on_hand_qty, note)
    VALUES (1, 10.000, 'inventory-P');

    SELECT phase = N'setup',
           session_id = @@SPID,
           on_hand_qty = 10.000,
           rcsi_enabled = (SELECT d.is_read_committed_snapshot_on
                           FROM sys.databases AS d
                           WHERE d.database_id = DB_ID());
    RETURN;
END;

IF @session = 'cleanup'
BEGIN
    IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NOT NULL
        DROP TABLE dbo.Stage3IsolationLab_A;
    PRINT N'26a：实验表已清理。';
    RETURN;
END;

IF OBJECT_ID(N'dbo.Stage3IsolationLab_A', N'U') IS NULL
    THROW 54930, N'26a：缺少实验表，先跑 Session=setup。', 1;
IF @session NOT IN ('1', '2') OR @mode NOT IN ('dirty', 'nonrepeat')
    THROW 54930, N'26a：Session 用 1/2/setup/cleanup，Mode 用 dirty/nonrepeat。', 1;

IF @level = 'RU'
    SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
ELSE IF @level = 'RR'
    SET TRANSACTION ISOLATION LEVEL REPEATABLE READ;
ELSE
    SET TRANSACTION ISOLATION LEVEL READ COMMITTED;

DECLARE @sid INT = @@SPID;

-- 脏读：S1 是未提交的补货更新；S2 是读者。
IF @mode = 'dirty' AND @session = '1'
BEGIN
    BEGIN TRANSACTION;
    UPDATE dbo.Stage3IsolationLab_A
       SET on_hand_qty = 15.000
     WHERE lab_id = 1;
    SELECT phase = N'S1-update-uncommitted', session_id = @sid, on_hand_qty
    FROM dbo.Stage3IsolationLab_A WHERE lab_id = 1;
    WAITFOR DELAY '00:00:08';
    ROLLBACK TRANSACTION;
    SELECT phase = N'S1-after-rollback', session_id = @sid, on_hand_qty
    FROM dbo.Stage3IsolationLab_A WHERE lab_id = 1;
    RETURN;
END;

IF @mode = 'dirty' AND @session = '2'
BEGIN
    WAITFOR DELAY '00:00:03';
    BEGIN TRANSACTION;
    SELECT phase = N'S2-first-read', session_id = @sid,
           isolation_level = transaction_isolation_level, on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    CROSS JOIN (SELECT transaction_isolation_level FROM sys.dm_exec_sessions
                WHERE session_id = @@SPID) AS s
    WHERE lab_id = 1;
    WAITFOR DELAY '00:00:06';
    SELECT phase = N'S2-second-read', session_id = @sid, on_hand_qty
    FROM dbo.Stage3IsolationLab_A WHERE lab_id = 1;
    COMMIT TRANSACTION;
    RETURN;
END;

-- 不可重复读：S1 是读者；S2 在两次读之间提交 +5。
IF @mode = 'nonrepeat' AND @session = '1'
BEGIN
    BEGIN TRANSACTION;
    SELECT phase = N'S1-first-read', session_id = @sid,
           isolation_level = transaction_isolation_level, on_hand_qty
    FROM dbo.Stage3IsolationLab_A
    CROSS JOIN (SELECT transaction_isolation_level FROM sys.dm_exec_sessions
                WHERE session_id = @@SPID) AS s
    WHERE lab_id = 1;
    WAITFOR DELAY '00:00:08';
    SELECT phase = N'S1-second-read', session_id = @sid, on_hand_qty
    FROM dbo.Stage3IsolationLab_A WHERE lab_id = 1;
    COMMIT TRANSACTION;
    RETURN;
END;

IF @mode = 'nonrepeat' AND @session = '2'
BEGIN
    WAITFOR DELAY '00:00:03';
    BEGIN TRANSACTION;
    UPDATE dbo.Stage3IsolationLab_A
       SET on_hand_qty = on_hand_qty + 5.000
     WHERE lab_id = 1;
    COMMIT TRANSACTION;
    SELECT phase = N'S2-after-commit', session_id = @sid, on_hand_qty
    FROM dbo.Stage3IsolationLab_A WHERE lab_id = 1;
    RETURN;
END;

THROW 54930, N'26a：会话/模式组合未覆盖。', 1;
GO
