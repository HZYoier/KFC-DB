-- ============================================================================
-- 22c_inventory_triggers.sql — C 域库存审计触发器（成员 C；2026-11-15，3.2 提前落稿）
-- 定位：由 run_stage3.sql 在外层事务内 :r 执行；不 BEGIN/COMMIT/ROLLBACK。
-- 目标：Inventory 行 INSERT/UPDATE/DELETE 后，按 inserted/deleted 集合写入
--       InventoryAudit；只改 updated_at 的更新不产生审计；无游标、无递归。
-- 依赖：20_schema_v1_1.sql 的 InventoryAudit、EmployeeAccount。
-- 依据：R11-01、R11-06、R11-08；计划 §5.1/§5.4。
-- 说明：Inventory 行删除不是正常业务动作（业务角色无 DELETE 授权，且
--       InventoryMovement 有外键）。DELETE 分支作为防御性分支保留；但
--       InventoryAudit 到 Inventory 的外键会在父行已删除时拒绝审计插入，
--       该边界登记在 docs/stage3/open-issues.md S3-02，不在本触发器里绕过。
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

USE KFC_DB;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54430, N'22c: InventoryAudit is missing; run 20_schema_v1_1.sql first.', 1;
IF OBJECT_ID(N'dbo.EmployeeAccount', N'U') IS NULL
    THROW 54431, N'22c: EmployeeAccount is missing; deploy v1.0 first.', 1;
IF OBJECT_ID(N'dbo.tr_Inventory_Audit', N'TR') IS NOT NULL
    THROW 54432, N'22c: tr_Inventory_Audit already exists; v1.1 is already applied.', 1;
GO

CREATE TRIGGER dbo.tr_Inventory_Audit
ON dbo.Inventory
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.InventoryAudit
    (
        ingredient_id,
        before_on_hand,
        after_on_hand,
        delta_on_hand,
        before_locked,
        after_locked,
        delta_locked,
        operation_type,
        operated_by,
        employee_id,
        operated_at
    )
    SELECT
        COALESCE(i.ingredient_id, d.ingredient_id),
        d.on_hand_qty,
        i.on_hand_qty,
        CAST(COALESCE(i.on_hand_qty, 0) - COALESCE(d.on_hand_qty, 0) AS DECIMAL(12,3)),
        d.locked_qty,
        i.locked_qty,
        CAST(COALESCE(i.locked_qty, 0) - COALESCE(d.locked_qty, 0) AS DECIMAL(12,3)),
        CASE
            WHEN d.ingredient_id IS NULL THEN 'INSERT'
            WHEN i.ingredient_id IS NULL THEN 'DELETE'
            ELSE 'UPDATE'
        END,
        USER_NAME(),
        (SELECT TOP (1) ea.employee_id
         FROM dbo.EmployeeAccount AS ea
         WHERE ea.database_user_name = USER_NAME()
           AND ea.status = 'ACTIVE'
         ORDER BY ea.employee_id),
        SYSDATETIME()
    FROM inserted AS i
    FULL OUTER JOIN deleted AS d
      ON d.ingredient_id = i.ingredient_id
    WHERE d.ingredient_id IS NULL
       OR i.ingredient_id IS NULL
       OR i.on_hand_qty <> d.on_hand_qty
       OR i.locked_qty <> d.locked_qty;
END;
GO

-- ---------------------------------------------------------------------------
-- 自检：只允许一个 AFTER 触发器，且挂在 Inventory 上
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1
               FROM sys.triggers
               WHERE object_id = OBJECT_ID(N'dbo.tr_Inventory_Audit')
                 AND parent_id = OBJECT_ID(N'dbo.Inventory')
                 AND is_disabled = 0
                 AND is_instead_of_trigger = 0)
    THROW 54433, N'22c: tr_Inventory_Audit is missing or disabled.', 1;

IF (SELECT COUNT(*) FROM sys.trigger_events AS te
    WHERE te.object_id = OBJECT_ID(N'dbo.tr_Inventory_Audit')
      AND te.type_desc IN (N'INSERT', N'UPDATE', N'DELETE')) <> 3
    THROW 54434, N'22c: tr_Inventory_Audit must handle INSERT, UPDATE, and DELETE.', 1;

IF OBJECT_DEFINITION(OBJECT_ID(N'dbo.tr_Inventory_Audit')) LIKE N'%CURSOR%'
    THROW 54435, N'22c: tr_Inventory_Audit must not use a cursor.', 1;

PRINT N'22c: tr_Inventory_Audit created (set-based inventory audit).';
GO
