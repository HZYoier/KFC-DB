-- ============================================================================
-- 21c_inventory_programmability.sql — C 域第三阶段过程与函数（成员 C；2026-11-15）
-- 定位：由 run_stage3.sql 在外层事务内 :r 执行；本文件不 BEGIN/COMMIT/ROLLBACK。
-- 内容：
--   1) ALTER dbo.sp_adjust_inventory：签名不变，复核 R10-02 的拒绝路径，
--      业务错误码统一到 C 的 543xx 段；成功仍写 InventoryMovement + AuditLog，
--      库存数量审计由 22c 的触发器接管（本过程不重复写数量审计）。
--   2) CREATE dbo.fn_replenishment_qty：按可售量（on_hand - locked）与目标量
--      计算补货量；达到目标返回 0，原料不存在返回 NULL，结果永不为负。
-- 依据：docs/stage3/three-person-implementation-plan.md §4.4、§8.3；
--       R10-02/R10-03/R10-07/R10-09/R10-10。
-- 错误码：54301 参数为空；54302 增量为零；54303 缺原因；54304 未映射员工；
--         54305 员工不匹配；54306 非店长；54307 库存记录不存在；
--         54308 调整后库存为负。错误文案保留原过程的业务措辞。
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

IF OBJECT_ID(N'dbo.sp_adjust_inventory', N'P') IS NULL
    THROW 54420, N'21c: dbo.sp_adjust_inventory is missing; deploy v1.0 before v1.1.', 1;
IF OBJECT_ID(N'dbo.Inventory', N'U') IS NULL
   OR OBJECT_ID(N'dbo.InventoryMovement', N'U') IS NULL
   OR OBJECT_ID(N'dbo.AuditLog', N'U') IS NULL
    THROW 54421, N'21c: inventory/audit tables are missing; deploy v1.0 first.', 1;
IF OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NOT NULL
    THROW 54422, N'21c: dbo.fn_replenishment_qty already exists; v1.1 is already applied.', 1;
GO

-- ---------------------------------------------------------------------------
-- 1. 库存人工调整：签名保持 @ingredient_id/@on_hand_delta/@employee_id/@reason
--    既有外部调用方（app/inventory/dao.py、10c、09d）不需要改。
-- ---------------------------------------------------------------------------
ALTER PROCEDURE dbo.sp_adjust_inventory
    @ingredient_id BIGINT,
    @on_hand_delta DECIMAL(12,3),
    @employee_id   BIGINT,
    @reason        VARCHAR(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF @ingredient_id IS NULL OR @on_hand_delta IS NULL OR @employee_id IS NULL
    BEGIN
        THROW 54301, N'sp_adjust_inventory：@ingredient_id、@on_hand_delta、@employee_id 都不能为 NULL。', 1;
    END;

    IF @on_hand_delta = 0
    BEGIN
        THROW 54302, N'sp_adjust_inventory：@on_hand_delta 不能为 0，无变化请勿调整。', 1;
    END;

    IF @reason IS NULL OR LTRIM(RTRIM(@reason)) = ''
    BEGIN
        THROW 54303, N'sp_adjust_inventory：缺少调整原因 @reason。', 1;
    END;

    DECLARE @resolved_employee_id BIGINT;

    SELECT @resolved_employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE';

    IF @resolved_employee_id IS NULL
    BEGIN
        THROW 54304, N'sp_adjust_inventory：当前登录主体未映射到启用员工，拒绝执行。', 1;
    END;

    IF @employee_id <> @resolved_employee_id
    BEGIN
        THROW 54305, N'sp_adjust_inventory：传入员工 ID 与当前登录主体解析出的员工不一致，拒绝执行。', 1;
    END;

    IF NOT EXISTS (SELECT 1
                   FROM dbo.EmployeeBusinessRole AS ebr
                   JOIN dbo.BusinessRole AS br
                     ON br.business_role_id = ebr.business_role_id
                   WHERE ebr.employee_id = @resolved_employee_id
                     AND br.role_code = 'store_manager'
                     AND br.status = 'ACTIVE')
    BEGIN
        THROW 54306, N'sp_adjust_inventory：仅店长可调整库存。', 1;
    END;

    DECLARE @owns_tran BIT = CASE WHEN @@TRANCOUNT = 0 THEN 1 ELSE 0 END;

    IF @owns_tran = 1
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION sp_adjust_inventory;

    BEGIN TRY
        DECLARE @on_hand_qty DECIMAL(12,3), @new_on_hand_qty DECIMAL(12,3);

        SELECT @on_hand_qty = inv.on_hand_qty
        FROM dbo.Inventory AS inv WITH (UPDLOCK, HOLDLOCK)
        WHERE inv.ingredient_id = @ingredient_id;

        IF @on_hand_qty IS NULL
        BEGIN
            THROW 54307, N'sp_adjust_inventory：原料不存在或尚未建立库存记录。', 1;
        END;

        SET @new_on_hand_qty = @on_hand_qty + @on_hand_delta;
        IF @new_on_hand_qty < 0
        BEGIN
            THROW 54308, N'sp_adjust_inventory：调整后库存不能为负。', 1;
        END;

        UPDATE dbo.Inventory
           SET on_hand_qty = @new_on_hand_qty,
               updated_at = SYSDATETIME()
         WHERE ingredient_id = @ingredient_id;

        INSERT INTO dbo.InventoryMovement
            (ingredient_id, movement_type, on_hand_delta, locked_delta, reference_type, reference_id, moved_at)
        VALUES
            (@ingredient_id, 'ADJUSTMENT', @on_hand_delta, 0, 'ADJUSTMENT', NULL, SYSDATETIME());

        DECLARE @detail_json NVARCHAR(MAX) =
        (
            SELECT @reason AS reason,
                   @on_hand_qty AS on_hand_before,
                   @new_on_hand_qty AS on_hand_after
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER
        );

        EXEC dbo.sp_write_audit_log
             @employee_id = @resolved_employee_id,
             @action_name = 'ADJUST_INVENTORY',
             @entity_name = 'Inventory',
             @entity_id   = @ingredient_id,
             @detail_json = @detail_json;

        EXEC dbo.sp_refresh_replenishment_suggestion
             @ingredient_id     = @ingredient_id,
             @actor_employee_id = @resolved_employee_id;

        IF @owns_tran = 1
            COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @owns_tran = 1 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @owns_tran = 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION sp_adjust_inventory;

        THROW;
    END CATCH;
END;
GO

-- ---------------------------------------------------------------------------
-- 2. 补货量函数
--    可售量口径与 v_inventory_available.available_qty 一致：
--        COALESCE(on_hand_qty,0) - COALESCE(locked_qty,0)
--    不是账面在库量 on_hand_qty；锁定量的订单占用不应被补货量重复覆盖。
--    原料存在但没有 Inventory 行时按可售量 0 处理（与视图的 LEFT JOIN 口径一致）；
--    原料本身不存在、目标量为 NULL/负数、参数为 NULL 时返回 NULL。
--    @target_qty 优先；它为空时才取 @min_qty。两者皆空返回 NULL。
-- ---------------------------------------------------------------------------
CREATE FUNCTION dbo.fn_replenishment_qty
(
    @ingredient_id BIGINT,
    @target_qty    DECIMAL(12,3),
    @min_qty       DECIMAL(12,3) = NULL
)
RETURNS DECIMAL(12,3)
AS
BEGIN
    DECLARE @target DECIMAL(12,3) = COALESCE(@target_qty, @min_qty);

    IF @ingredient_id IS NULL OR @target IS NULL OR @target < 0
        RETURN NULL;

    IF NOT EXISTS (SELECT 1 FROM dbo.Ingredient AS i
                   WHERE i.ingredient_id = @ingredient_id)
        RETURN NULL;

    DECLARE @available DECIMAL(15,3);

    SELECT @available =
           CAST(ISNULL(inv.on_hand_qty, 0) AS DECIMAL(15,3))
         - CAST(ISNULL(inv.locked_qty, 0) AS DECIMAL(15,3))
    FROM dbo.Ingredient AS i
    LEFT JOIN dbo.Inventory AS inv
      ON inv.ingredient_id = i.ingredient_id
    WHERE i.ingredient_id = @ingredient_id;

    IF @available IS NULL
        RETURN NULL;

    IF @available >= @target
        RETURN CAST(0 AS DECIMAL(12,3));

    DECLARE @need DECIMAL(15,3) = @target - @available;
    IF @need > CAST(999999999.999 AS DECIMAL(15,3))
        SET @need = CAST(999999999.999 AS DECIMAL(15,3));

    RETURN CAST(@need AS DECIMAL(12,3));
END;
GO

-- ---------------------------------------------------------------------------
-- 3. 本文件自检
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NULL
    THROW 54423, N'21c: fn_replenishment_qty was not created.', 1;

IF (SELECT COUNT(*) FROM sys.parameters
    WHERE object_id = OBJECT_ID(N'dbo.fn_replenishment_qty')
      AND parameter_id > 0) <> 3
    THROW 54424, N'21c: fn_replenishment_qty must have exactly three parameters.', 1;

IF (SELECT COUNT(*) FROM sys.parameters
    WHERE object_id = OBJECT_ID(N'dbo.sp_adjust_inventory')
      AND parameter_id > 0) <> 4
    THROW 54425, N'21c: sp_adjust_inventory signature changed unexpectedly.', 1;

PRINT N'21c: sp_adjust_inventory upgraded and fn_replenishment_qty created.';
GO
