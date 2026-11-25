-- 27 — v1.1 权限迁移，由 run_stage3.sql 在外层事务中执行。
-- 新增 6 个对象码、7 行角色映射。已有过程的 ALTER 复用现有授权。
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF XACT_STATE() <> 1
    THROW 54420, N'27: run inside the Stage 3 migration transaction.', 1;

DECLARE @objects TABLE (
    permission_code VARCHAR(50) PRIMARY KEY,
    permission_name NVARCHAR(100) NOT NULL,
    object_type CHAR(2) NOT NULL,
    grant_name VARCHAR(7) NOT NULL
);
INSERT @objects VALUES
    ('sp_sales_report', N'销售统计报表', 'P', 'EXECUTE'),
    ('v_settled_sales_line', N'已结算销售明细', 'V', 'SELECT'),
    ('fn_calculate_discount', N'计算订单折扣', 'IF', 'SELECT'),
    ('fn_product_sales_summary', N'商品销售汇总', 'IF', 'SELECT'),
    ('fn_replenishment_qty', N'计算补货建议量', 'FN', 'EXECUTE'),
    ('InventoryAudit', N'库存数量审计查询', 'U', 'SELECT');

DECLARE @grants TABLE (
    permission_code VARCHAR(50) NOT NULL,
    role_code VARCHAR(50) NOT NULL,
    PRIMARY KEY (permission_code, role_code)
);
INSERT @grants SELECT permission_code, 'store_manager' FROM @objects;
INSERT @grants VALUES ('fn_replenishment_qty', 'shift_manager');

IF EXISTS (
    SELECT 1 FROM @objects
    WHERE OBJECT_ID(N'dbo.' + QUOTENAME(permission_code), object_type) IS NULL
)
    THROW 54421, N'27: a required v1.1 object is missing or has the wrong type.', 1;

IF EXISTS (
    SELECT 1 FROM @grants AS g
    WHERE DATABASE_PRINCIPAL_ID(N'role_' + g.role_code) IS NULL
       OR NOT EXISTS (SELECT 1 FROM dbo.BusinessRole AS r
                      WHERE r.role_code = g.role_code AND r.status = 'ACTIVE')
)
    THROW 54422, N'27: a required active business role or database role is missing.', 1;

ALTER TABLE dbo.Permission DROP CONSTRAINT CK_Permission_permission_code;
ALTER TABLE dbo.Permission WITH CHECK ADD CONSTRAINT CK_Permission_permission_code CHECK (
        permission_code IN (
            -- v0.1 旧 46 码（原 CK_RolePermission_permission_code 全量迁入）
            'sp_create_category', 'sp_update_category_status',
            'sp_create_ingredient', 'sp_update_ingredient',
            'sp_create_product', 'sp_update_product_price', 'sp_update_product_status',
            'sp_set_product_bom', 'sp_set_combo_component',
            'sp_create_promotion', 'sp_update_promotion_status',
            'sp_add_promotion_product_rule', 'sp_update_promotion_product_rule',
            'sp_create_member_level', 'sp_update_member_level',
            'sp_update_member_level_status',
            'sp_create_customer', 'sp_update_customer_member_level',
            'sp_create_order', 'sp_pay_order', 'sp_start_production',
            'sp_finish_production', 'sp_pick_up_order', 'sp_pick_up_delivery',
            'sp_confirm_delivery', 'sp_cancel_or_refund_order',
            'sp_adjust_inventory', 'sp_create_replenishment_suggestion',
            'sp_update_replenishment_suggestion', 'sp_submit_replenishment_suggestion',
            'sp_approve_replenishment_suggestion', 'sp_reject_replenishment_suggestion',
            'sp_receive_inventory', 'sp_assign_employee_business_role',
            'sp_revoke_employee_business_role', 'sp_update_employee_status',
            'v_active_product_price', 'v_product_bom_detail',
            'v_order_detail', 'v_kitchen_queue', 'v_customer_point_ledger',
            'v_pickup_board', 'v_inventory_available',
            'v_inventory_movement_history', 'v_replenishment_dashboard',
            'v_order_inventory_trace',
            -- v1.0 新增 12 码（B 六查询 + C 上下文/员工角色查询 + A 四接口）
            'sp_list_orders_for_payment', 'sp_get_order_for_payment',
            'sp_get_order_operation_status', 'sp_list_orders_for_packing',
            'sp_list_my_deliveries', 'sp_list_deliveries_available_for_pickup',
            'sp_get_current_employee_context',
            -- C 的员工角色查询（2026-11-05 补入，仅店长）
            'sp_list_employee_roles',
            -- A 的 11a 四个查询/注册接口（2026-11-03 补入）
            'sp_list_master_records', 'sp_list_sale_products',
            'sp_find_customer_for_order', 'sp_register_customer_for_order',
            'sp_sales_report', 'v_settled_sales_line',
            'fn_calculate_discount', 'fn_product_sales_summary',
            'fn_replenishment_qty', 'InventoryAudit'
        )
);

INSERT dbo.Permission (permission_code, permission_name)
SELECT permission_code, permission_name FROM @objects;

INSERT dbo.RolePermission (business_role_id, permission_code, status)
SELECT r.business_role_id, g.permission_code, 'ACTIVE'
FROM @grants AS g
JOIN dbo.BusinessRole AS r ON r.role_code = g.role_code;

DECLARE @sql NVARCHAR(MAX);
SELECT @sql = STRING_AGG(CONVERT(NVARCHAR(MAX),
    N'GRANT ' + o.grant_name + N' ON OBJECT::dbo.' + QUOTENAME(o.permission_code)
    + N' TO ' + QUOTENAME(N'role_' + g.role_code) + N';'), NCHAR(10))
FROM @grants AS g
JOIN @objects AS o ON o.permission_code = g.permission_code;
EXEC sys.sp_executesql @sql;

IF EXISTS (
    SELECT permission_code FROM dbo.Permission
    EXCEPT SELECT permission_code FROM dbo.RolePermission
)
    THROW 54423, N'27: Permission and RolePermission code sets differ.', 1;

DECLARE @expected TABLE (object_id INT NOT NULL, principal_id INT NOT NULL, grant_name SYSNAME NOT NULL);
INSERT @expected
SELECT OBJECT_ID(N'dbo.' + QUOTENAME(o.permission_code)),
       DATABASE_PRINCIPAL_ID(N'role_' + g.role_code), o.grant_name
FROM @grants AS g
JOIN @objects AS o ON o.permission_code = g.permission_code;

IF EXISTS (
    SELECT g.permission_code, g.role_code FROM @grants AS g
    EXCEPT
    SELECT p.permission_code, r.role_code
    FROM dbo.RolePermission AS p
    JOIN dbo.BusinessRole AS r ON r.business_role_id = p.business_role_id
    WHERE p.status = 'ACTIVE'
) OR EXISTS (
    SELECT object_id, principal_id, grant_name FROM @expected
    EXCEPT
    SELECT major_id, grantee_principal_id, permission_name COLLATE DATABASE_DEFAULT
    FROM sys.database_permissions
    WHERE class = 1 AND minor_id = 0 AND state = 'G'
) OR EXISTS (
    SELECT p.major_id, p.grantee_principal_id, p.permission_name COLLATE DATABASE_DEFAULT
    FROM sys.database_permissions AS p
    JOIN (SELECT DISTINCT object_id FROM @expected) AS o ON o.object_id = p.major_id
    WHERE p.class = 1 AND (p.state <> 'G' OR p.minor_id <> 0 OR NOT EXISTS (
        SELECT 1 FROM @expected AS e
        WHERE e.object_id = p.major_id AND e.principal_id = p.grantee_principal_id
          AND e.grant_name = p.permission_name COLLATE DATABASE_DEFAULT
    ))
)
    THROW 54424, N'27: v1.1 mappings and object grants do not match the expected roles.', 1;

PRINT N'RESULT: 27 new_permission_codes=6 new_role_grants=7';
GO
