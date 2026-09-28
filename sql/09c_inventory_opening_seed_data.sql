-- ============================================================================
-- 09c_inventory_opening_seed_data.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：部署种子——建立 7 个业务角色行与 7 个 test_* 用户对应的员工档案，
--       填充每个业务角色应拥有的 RolePermission（与 08 的授权矩阵逐行镜像），
--       为 A 的 6 种原料建立期初库存（薯条与鸡腿肉压在各自安全线上），最后以
--       EXECUTE AS USER = 'test_store_manager' 仅经角色同步过程为 7 人分配业务角色。
-- 依赖：01（A 域原料）、03（C 域表）、06（三个角色同步过程）、08（7 个 role_* 数据库
--       角色、7 个 test_* 数据库用户与 test_store_manager 的启动引导）、
--       09a（A 域主数据；本文件只读引用其冻结 ID，不新增不修改）。
-- 依据：docs/stage1-three-person-implementation-plan.md §5 C-2 line 316、320；
--       docs/stage1-cross-domain-interface-contract.md §6（A 冻结的原料 ID 与安全线）、
--       §7.1（10a 以 test_store_manager 为写主体，依赖本文件建出该名的 ACTIVE 员工行）、
--       §7.2（不新增不修改 A 域数据）。
-- 冻结的 C 域种子 ID（供 09d / 10c 与 B 的 09b 只读引用）：
--       EmployeeAccount 1..7 = test_store_manager / test_shift_manager / test_cashier /
--       test_chef / test_packer / test_waiter / test_rider；
--       BusinessRole 1..7    = store_manager / shift_manager / cashier / chef /
--       packer / waiter / rider（与 EmployeeAccount 的行号一一对应）。
-- 说明：① BusinessRole、EmployeeAccount、RolePermission、Inventory 都是部署种子，
--       直接 INSERT，不调用业务过程；EmployeeBusinessRole 必须经
--       sp_assign_employee_business_role 建立（line 320），以走通身份解析、白名单
--       校验与审计，不得直接插入，也不得直接 ALTER ROLE 加其余测试用户。
--       ② login_name 仅登记生产登录名（Windows/AD 账号），本文件不写任何密码明文。
--       ③ 期初库存只写 Inventory 行、不写 InventoryMovement 流水：按 §6 不变量
--       on_hand_qty = 期初 + Σ on_hand_delta 的口径，“期初”是不产生流水的基线。
--       ④ 压线口径（E2E-06 的触发点）：**薯条（5）与鸡腿肉（1）** 的期初恰等于各自安全
--       线，其余四种取安全线的 10 倍；数量全部由 A 的安全线推导，A 若改线这里自动跟随。
--       薯条按 A 的契约 §6.2 压线；鸡腿肉是实测补充——B 的 09b 三笔种子订单全部落在商品
--       1（香辣鸡腿堡），实扣只触及原料 1/2/3/4，薯条永远不会被推到线下，因此必须让
--       “实际会被消耗”的原料也压线，制作完成的实扣才能生成补货建议（计划 6.2 的
--       E2E-06 靠这个衔接）。两种压线原料各只被消耗 2 个单位，实扣后仅鸡腿肉落到线下，
--       故全库恰有一张 PENDING 建议。
-- ============================================================================

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

-- 前置校验：本种子只允许在空库上执行，且 A 域主数据与两种压线原料的安全线必须已冻结
IF EXISTS (SELECT 1 FROM dbo.BusinessRole)
   OR EXISTS (SELECT 1 FROM dbo.EmployeeAccount)
   OR EXISTS (SELECT 1 FROM dbo.RolePermission)
   OR EXISTS (SELECT 1 FROM dbo.Inventory)
    THROW 51001, N'09c：C 域种子表非空（BusinessRole / EmployeeAccount / RolePermission / Inventory），本种子只允许在空库上执行。', 1;

IF (SELECT COUNT(*) FROM dbo.Ingredient WHERE ingredient_id BETWEEN 1 AND 6) <> 6
    THROW 51002, N'09c：A 域冻结的 6 种原料（ingredient_id 1–6）不齐，请先执行 09a_master_seed_data.sql。', 1;

DECLARE @fries_safety DECIMAL(12,3) =
    (SELECT i.safety_stock_qty FROM dbo.Ingredient AS i WHERE i.ingredient_id = 5);
DECLARE @thigh_safety DECIMAL(12,3) =
    (SELECT i.safety_stock_qty FROM dbo.Ingredient AS i WHERE i.ingredient_id = 1);
IF @fries_safety IS NULL OR @fries_safety <> 1000.000
    THROW 51003, N'09c：薯条（ingredient_id = 5）的安全线不是契约 §6 冻结的 1000.000，期初库存的压线口径需同步修订。', 1;
-- 鸡腿肉是压线触发原料（E2E-06）：安全线为 0 时期初也是 0，实扣后永远落不到线下
IF @thigh_safety IS NULL OR @thigh_safety <= 0
    THROW 51003, N'09c：鸡腿肉（ingredient_id = 1）的安全线缺失或不大于零，制作完成后的补货触发（E2E-06）不成立。', 1;

BEGIN TRANSACTION;
BEGIN TRY

    -- 业务角色白名单行：role_code 与 08 的 role_* 数据库角色逐一对应
    SET IDENTITY_INSERT dbo.BusinessRole ON;
    INSERT INTO dbo.BusinessRole (business_role_id, role_code, role_name, [status]) VALUES
        (1, 'store_manager', N'店长',     'ACTIVE'),
        (2, 'shift_manager', N'值班经理', 'ACTIVE'),
        (3, 'cashier',       N'收银员',   'ACTIVE'),
        (4, 'chef',          N'厨师',     'ACTIVE'),
        (5, 'packer',        N'配餐员',   'ACTIVE'),
        (6, 'waiter',        N'服务员',   'ACTIVE'),
        (7, 'rider',         N'骑手',     'ACTIVE');
    SET IDENTITY_INSERT dbo.BusinessRole OFF;

    -- 员工档案：database_user_name 必须与 08 建立的同名数据库用户一致，
    -- 角色同步过程据此校验“目标员工已由 DBA 建立同名数据库用户”
    SET IDENTITY_INSERT dbo.EmployeeAccount ON;
    INSERT INTO dbo.EmployeeAccount
        (employee_id, database_user_name, login_name, employee_name, job_code, [status]) VALUES
        (1, 'test_store_manager', 'test_store_manager', N'测试店长',     'STORE_MANAGER', 'ACTIVE'),
        (2, 'test_shift_manager', 'test_shift_manager', N'测试值班经理', 'SHIFT_MANAGER', 'ACTIVE'),
        (3, 'test_cashier',       'test_cashier',       N'测试收银员',   'CASHIER',       'ACTIVE'),
        (4, 'test_chef',          'test_chef',          N'测试厨师',     'CHEF',          'ACTIVE'),
        (5, 'test_packer',        'test_packer',        N'测试配餐员',   'PACKER',        'ACTIVE'),
        (6, 'test_waiter',        'test_waiter',        N'测试服务员',   'WAITER',        'ACTIVE'),
        (7, 'test_rider',         'test_rider',         N'测试骑手',     'RIDER',         'ACTIVE');
    SET IDENTITY_INSERT dbo.EmployeeAccount OFF;

    -- 角色权限：与 08 的 52 条 GRANT 逐行镜像（permission_code 全在
    -- CK_RolePermission_permission_code 白名单内，permission_name 仅作展示）
    INSERT INTO dbo.RolePermission (business_role_id, permission_code, permission_name, [status])
    SELECT br.business_role_id, src.permission_code, src.permission_name, 'ACTIVE'
    FROM (VALUES
        -- role_store_manager：A 域主数据过程 18 项
        ('store_manager', 'sp_add_promotion_product_rule',    N'新增促销商品规则'),
        ('store_manager', 'sp_create_category',               N'新增商品分类'),
        ('store_manager', 'sp_create_customer',               N'新增顾客'),
        ('store_manager', 'sp_create_ingredient',             N'新增原料'),
        ('store_manager', 'sp_create_member_level',           N'新增会员等级'),
        ('store_manager', 'sp_create_product',                N'新增商品'),
        ('store_manager', 'sp_create_promotion',              N'新增促销'),
        ('store_manager', 'sp_set_combo_component',           N'设置套餐组成'),
        ('store_manager', 'sp_set_product_bom',               N'设置商品用料'),
        ('store_manager', 'sp_update_category_status',        N'更新商品分类状态'),
        ('store_manager', 'sp_update_customer_member_level',  N'调整顾客会员等级'),
        ('store_manager', 'sp_update_ingredient',             N'更新原料'),
        ('store_manager', 'sp_update_member_level',           N'更新会员等级'),
        ('store_manager', 'sp_update_member_level_status',    N'更新会员等级状态'),
        ('store_manager', 'sp_update_product_price',          N'调整商品价格'),
        ('store_manager', 'sp_update_product_status',         N'更新商品状态'),
        ('store_manager', 'sp_update_promotion_product_rule', N'更新促销商品规则'),
        ('store_manager', 'sp_update_promotion_status',       N'更新促销状态'),
        -- role_store_manager：C 域库存、补货审批与角色同步过程 6 项
        ('store_manager', 'sp_adjust_inventory',                    N'库存调整'),
        ('store_manager', 'sp_approve_replenishment_suggestion',    N'审批补货建议'),
        ('store_manager', 'sp_reject_replenishment_suggestion',     N'驳回补货建议'),
        ('store_manager', 'sp_assign_employee_business_role',       N'分配员工业务角色'),
        ('store_manager', 'sp_revoke_employee_business_role',       N'撤销员工业务角色'),
        ('store_manager', 'sp_update_employee_status',              N'更新员工状态'),
        -- role_store_manager：B 域订单取消/退款 1 项
        ('store_manager', 'sp_cancel_or_refund_order',              N'订单取消或退款'),
        -- role_store_manager：全部 10 个视图
        ('store_manager', 'v_active_product_price',        N'在售商品价格视图'),
        ('store_manager', 'v_customer_point_ledger',       N'顾客积分流水视图'),
        ('store_manager', 'v_inventory_available',         N'原料可售量视图'),
        ('store_manager', 'v_inventory_movement_history',  N'库存流水视图'),
        ('store_manager', 'v_kitchen_queue',               N'后厨队列视图'),
        ('store_manager', 'v_order_detail',                N'订单明细视图'),
        ('store_manager', 'v_order_inventory_trace',       N'订单库存追溯视图'),
        ('store_manager', 'v_pickup_board',                N'取餐看板视图'),
        ('store_manager', 'v_product_bom_detail',          N'商品用料明细视图'),
        ('store_manager', 'v_replenishment_dashboard',     N'补货看板视图'),
        -- role_shift_manager：补货创建/调整/提交、采购收货与库存/补货视图 8 项
        ('shift_manager', 'sp_create_replenishment_suggestion', N'创建补货建议'),
        ('shift_manager', 'sp_update_replenishment_suggestion', N'修改补货建议'),
        ('shift_manager', 'sp_submit_replenishment_suggestion', N'提交补货建议'),
        ('shift_manager', 'sp_receive_inventory',               N'采购收货入库'),
        ('shift_manager', 'v_inventory_available',              N'原料可售量视图'),
        ('shift_manager', 'v_inventory_movement_history',       N'库存流水视图'),
        ('shift_manager', 'v_order_inventory_trace',            N'订单库存追溯视图'),
        ('shift_manager', 'v_replenishment_dashboard',          N'补货看板视图'),
        -- role_cashier
        ('cashier', 'sp_create_order', N'创建订单'),
        ('cashier', 'sp_pay_order',    N'订单支付'),
        -- role_chef
        ('chef', 'sp_start_production', N'开始制作'),
        ('chef', 'v_kitchen_queue',     N'后厨队列视图'),
        -- role_packer
        ('packer', 'sp_finish_production', N'完成制作'),
        ('packer', 'sp_pick_up_order',     N'取餐打包'),
        -- role_rider
        ('rider', 'sp_pick_up_delivery', N'骑手取件'),
        ('rider', 'sp_confirm_delivery', N'确认送达'),
        -- role_waiter
        ('waiter', 'v_pickup_board', N'取餐看板视图')
    ) AS src(role_code, permission_code, permission_name)
    JOIN dbo.BusinessRole AS br ON br.role_code = src.role_code;

    -- 期初库存：A 域 6 种原料各一条，数量由 A 的安全线推导（见文件头说明 ④）
    --   压线（恰等于安全线）：鸡腿肉（1，会被种子订单实扣）、薯条（5，契约 §6.2 指定）
    --   其余四种 = 安全线 × 10，不会被种子订单推到线下
    INSERT INTO dbo.Inventory (ingredient_id, on_hand_qty, locked_qty, updated_at)
    SELECT i.ingredient_id,
           CASE WHEN i.ingredient_id IN (1, 5)
                THEN i.safety_stock_qty
                ELSE CAST(i.safety_stock_qty * 10 AS DECIMAL(12,3))
           END,
           0.000,
           SYSDATETIME()
    FROM dbo.Ingredient AS i
    WHERE i.ingredient_id BETWEEN 1 AND 6;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    THROW;
END CATCH;
GO

-- 批次 3：角色分配——只经 sp_assign_employee_business_role（line 320）
-- 被调用的过程内部会 SET XACT_ABORT ON，故这里显式开事务做全有全无；
-- 实测：THROW 与 ROLLBACK 都不会自动还原 EXECUTE AS 上下文，故 CATCH 里必须显式 REVERT。
DECLARE @emp_store_manager BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_store_manager');
DECLARE @emp_shift_manager BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_shift_manager');
DECLARE @emp_cashier       BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_cashier');
DECLARE @emp_chef          BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_chef');
DECLARE @emp_packer        BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_packer');
DECLARE @emp_waiter        BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_waiter');
DECLARE @emp_rider         BIGINT = (SELECT employee_id FROM dbo.EmployeeAccount WHERE database_user_name = N'test_rider');

DECLARE @role_store_manager BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'store_manager');
DECLARE @role_shift_manager BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'shift_manager');
DECLARE @role_cashier       BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'cashier');
DECLARE @role_chef          BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'chef');
DECLARE @role_packer        BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'packer');
DECLARE @role_waiter        BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'waiter');
DECLARE @role_rider         BIGINT = (SELECT business_role_id FROM dbo.BusinessRole WHERE role_code = N'rider');

DECLARE @impersonating BIT = 0;

BEGIN TRY
    BEGIN TRANSACTION;

    EXECUTE AS USER = N'test_store_manager';
    SET @impersonating = 1;

    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_store_manager, @business_role_id = @role_store_manager, @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_shift_manager, @business_role_id = @role_shift_manager, @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_cashier,       @business_role_id = @role_cashier,       @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_chef,          @business_role_id = @role_chef,          @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_packer,        @business_role_id = @role_packer,        @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_waiter,        @business_role_id = @role_waiter,        @assigned_by_employee_id = @emp_store_manager;
    EXEC dbo.sp_assign_employee_business_role @employee_id = @emp_rider,         @business_role_id = @role_rider,         @assigned_by_employee_id = @emp_store_manager;

    REVERT;
    SET @impersonating = 0;

    COMMIT TRANSACTION;
END TRY
BEGIN CATCH
    -- 顺序要紧：必须先 ROLLBACK 再 REVERT。本域过程内部都设了 SET XACT_ABORT ON，
    -- 过程一抛错外层事务即不可提交（XACT_STATE() = -1；实测即使会话级 OFF 也如此）；
    -- 在不可提交事务里执行 REVERT 会被拒（Msg 3930），整批中止且模拟身份残留到批次结束。
    -- ROLLBACK 在该状态下是允许的，且回滚后模拟身份仍在，紧接着 REVERT 才安全。
    IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;
    IF @impersonating = 1 REVERT;
    THROW;
END CATCH;
GO

-- 自查：7 角色 / 7 员工 / 52 条角色权限 / 7 条成员关系 / 6 条期初库存 / 0 条低于安全线
IF (SELECT COUNT(*) FROM dbo.BusinessRole) <> 7
    THROW 51004, N'09c：BusinessRole 不是 7 行。', 1;
IF (SELECT COUNT(*) FROM dbo.EmployeeAccount) <> 7
    THROW 51005, N'09c：EmployeeAccount 不是 7 行。', 1;
IF (SELECT COUNT(*) FROM dbo.RolePermission) <> 52
    THROW 51006, N'09c：RolePermission 不是 52 行（与 08 的授权矩阵逐行镜像）。', 1;
IF (SELECT COUNT(*) FROM dbo.EmployeeBusinessRole) <> 7
    THROW 51007, N'09c：员工-业务角色成员关系不是 7 条，角色分配未全部生效。', 1;
IF (SELECT COUNT(*) FROM dbo.Inventory) <> 6
    THROW 51008, N'09c：Inventory 不是 6 行（A 域 6 种原料各一条）。', 1;
IF EXISTS (SELECT 1
           FROM dbo.Inventory AS i
           JOIN dbo.Ingredient AS g ON g.ingredient_id = i.ingredient_id
           WHERE i.on_hand_qty < g.safety_stock_qty)
    THROW 51009, N'09c：期初库存存在低于安全线的原料，与“压线原料恰在线上、其余高于线”的冻结口径不符。', 1;
IF NOT EXISTS (SELECT 1
               FROM dbo.EmployeeAccount AS ea
               WHERE ea.database_user_name = N'test_store_manager' AND ea.[status] = 'ACTIVE')
    THROW 51010, N'09c：test_store_manager 没有 ACTIVE 的 EmployeeAccount 行（10a 的部署前提，契约 §7.1）。', 1;
IF (SELECT COUNT(*) FROM dbo.EmployeeBusinessRole WHERE assigned_by_employee_id <> 1) <> 0
    THROW 51011, N'09c：存在不由测试店长（employee_id = 1）分配的成员关系。', 1;
GO

-- 自查结果集：供人工核对（行数不符时上面的断言已先中止）
SELECT 'business_roles'        AS k, COUNT(*) AS n FROM dbo.BusinessRole
UNION ALL SELECT 'employee_accounts',      COUNT(*) FROM dbo.EmployeeAccount
UNION ALL SELECT 'role_permissions',       COUNT(*) FROM dbo.RolePermission
UNION ALL SELECT 'employee_business_roles', COUNT(*) FROM dbo.EmployeeBusinessRole
UNION ALL SELECT 'inventory_rows',         COUNT(*) FROM dbo.Inventory
UNION ALL SELECT 'low_stock_ingredients',  COUNT(*)
    FROM dbo.Inventory AS i
    JOIN dbo.Ingredient AS g ON g.ingredient_id = i.ingredient_id
    WHERE i.on_hand_qty < g.safety_stock_qty;
GO
