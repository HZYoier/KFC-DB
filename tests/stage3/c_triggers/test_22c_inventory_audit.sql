-- ============================================================================
-- test_22c_inventory_audit.sql — C 域库存审计触发器测试（成员 C；2026-11-15）
-- 运行时机：v0.1 + 20/21c 已执行，22c_inventory_triggers.sql 已执行。
-- 运行方式：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 覆盖：单条插入、单条修改、只改 updated_at、多条修改、审计字段形状、
--       集合处理（无 CURSOR）；测试数据和新审计全部在事务内回滚。
-- 分母：10。
-- 断言码：54930 前置缺失、54931 夹具不成立、54998 有失败、54999 分母不足。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54930, N'缺少 dbo.InventoryAudit；请先执行 sql/stage3/20_schema_v1_1.sql。', 1;
IF OBJECT_ID(N'dbo.tr_Inventory_Audit', N'TR') IS NULL
    THROW 54930, N'缺少 dbo.tr_Inventory_Audit；请先执行 sql/stage3/22c_inventory_triggers.sql。', 1;

DECLARE @pass INT = 0, @fail INT = 0;
DECLARE @ing_a BIGINT, @ing_b BIGINT;
DECLARE @audit_count INT, @insert_a INT, @insert_b INT;
DECLARE @update_a INT, @multi_a INT, @multi_b INT;
DECLARE @before_a DECIMAL(12,3), @after_a DECIMAL(12,3), @delta_a DECIMAL(12,3);
DECLARE @on_hand_a DECIMAL(12,3), @on_hand_b DECIMAL(12,3);
DECLARE @operated_by VARCHAR(128), @employee_id BIGINT;

BEGIN TRANSACTION;
BEGIN TRY
    INSERT dbo.Ingredient (ingredient_name, unit_name, safety_stock_qty, status)
    VALUES (N'C审计测试A', N'kg', 0.000, 'ACTIVE');
    SET @ing_a = SCOPE_IDENTITY();

    INSERT dbo.Ingredient (ingredient_name, unit_name, safety_stock_qty, status)
    VALUES (N'C审计测试B', N'kg', 0.000, 'ACTIVE');
    SET @ing_b = SCOPE_IDENTITY();

    IF @ing_a IS NULL OR @ing_b IS NULL
        THROW 54931, N'无法建立测试原料夹具。', 1;

    INSERT dbo.Inventory (ingredient_id, on_hand_qty, locked_qty, updated_at)
    VALUES (@ing_a, 10.000, 0.000, SYSDATETIME()),
           (@ing_b, 10.000, 0.000, SYSDATETIME());

    -- 1. 两条 INSERT 各生成一条审计
    SELECT @audit_count = COUNT(*) FROM dbo.InventoryAudit
    WHERE ingredient_id IN (@ing_a, @ing_b) AND operation_type = 'INSERT';
    IF @audit_count = 2
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 2. INSERT 审计的 before 为空、after/delta 等于插入值
    SELECT @before_a = before_on_hand, @after_a = after_on_hand, @delta_a = delta_on_hand
    FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_a AND operation_type = 'INSERT';
    IF @before_a IS NULL AND @after_a = 10.000 AND @delta_a = 10.000
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 3. 只改 updated_at 不产生审计
    UPDATE dbo.Inventory
       SET updated_at = DATEADD(SECOND, 1, updated_at)
     WHERE ingredient_id = @ing_a;
    SELECT @audit_count = COUNT(*) FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_a AND operation_type = 'UPDATE';
    IF @audit_count = 0
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 4. 单条 UPDATE 生成一条审计，before/after/delta 正确
    UPDATE dbo.Inventory
       SET on_hand_qty = 15.000, updated_at = SYSDATETIME()
     WHERE ingredient_id = @ing_a;
    SELECT @before_a = before_on_hand, @after_a = after_on_hand, @delta_a = delta_on_hand
    FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_a AND operation_type = 'UPDATE';
    IF @before_a = 10.000 AND @after_a = 15.000 AND @delta_a = 5.000
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 5. 多条 UPDATE 一次生成两条审计（集合处理，不是只记最后一行）
    UPDATE dbo.Inventory
       SET on_hand_qty = on_hand_qty + 2.000, updated_at = SYSDATETIME()
     WHERE ingredient_id IN (@ing_a, @ing_b);
    SELECT @multi_a = COUNT(*) FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_a AND operation_type = 'UPDATE';
    SELECT @multi_b = COUNT(*) FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_b AND operation_type = 'UPDATE';
    IF @multi_a = 2 AND @multi_b = 1
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 6. 多行审计各自保存正确的前后值
    IF EXISTS (SELECT 1 FROM dbo.InventoryAudit
               WHERE ingredient_id = @ing_a AND before_on_hand = 15.000
                 AND after_on_hand = 17.000 AND delta_on_hand = 2.000)
       AND EXISTS (SELECT 1 FROM dbo.InventoryAudit
                   WHERE ingredient_id = @ing_b AND before_on_hand = 10.000
                     AND after_on_hand = 12.000 AND delta_on_hand = 2.000)
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 7. 库存实际值等于两次更新后的结果
    SELECT @on_hand_a = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ing_a;
    SELECT @on_hand_b = on_hand_qty FROM dbo.Inventory WHERE ingredient_id = @ing_b;
    IF @on_hand_a = 17.000 AND @on_hand_b = 12.000
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 8. 审计操作者/时间字段非空，employee_id 对 dbo 为 NULL
    SELECT TOP (1) @operated_by = operated_by, @employee_id = employee_id
    FROM dbo.InventoryAudit
    WHERE ingredient_id = @ing_a
    ORDER BY inventory_audit_id DESC;
    IF @operated_by = N'dbo' AND @employee_id IS NULL
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 9. 触发器定义只操作审计表，不使用游标
    IF OBJECT_DEFINITION(OBJECT_ID(N'dbo.tr_Inventory_Audit')) NOT LIKE N'%CURSOR%'
       AND OBJECT_DEFINITION(OBJECT_ID(N'dbo.tr_Inventory_Audit')) LIKE N'%inserted%'
       AND OBJECT_DEFINITION(OBJECT_ID(N'dbo.tr_Inventory_Audit')) LIKE N'%deleted%'
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    -- 10. 触发器挂在 Inventory 上且启用，三种事件齐备
    IF EXISTS (SELECT 1 FROM sys.triggers
               WHERE object_id = OBJECT_ID(N'dbo.tr_Inventory_Audit')
                 AND parent_id = OBJECT_ID(N'dbo.Inventory')
                 AND is_disabled = 0)
       AND (SELECT COUNT(*) FROM sys.trigger_events
            WHERE object_id = OBJECT_ID(N'dbo.tr_Inventory_Audit')
              AND type_desc IN (N'INSERT', N'UPDATE', N'DELETE')) = 3
        SET @pass = @pass + 1;
    ELSE
        SET @fail = @fail + 1;

    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;

DECLARE @total INT = @pass + @fail;
PRINT CONCAT(N'RESULT: c-triggers inventory_audit pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @total <> 10
    THROW 54999, N'库存审计触发器测试分母不足：期望 10 条，实际计数不是 10。', 1;
IF @fail > 0
    THROW 54998, N'库存审计触发器测试存在失败断言。', 1;
GO
