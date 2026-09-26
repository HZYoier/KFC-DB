-- ============================================================================
-- 07c_inventory_views_queries.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：C 域 4 个视图（可用库存 / 库存流水 / 补货看板 / 订单库存追溯）
--       与 3 条具名查询（Q-C1 低库存原料、Q-C2 指定订单的库存流水、
--       Q-C3 待审批补货建议）
-- 依赖：00_create_database.sql、01_master_schema.sql、02_order_schema.sql、
--       03_inventory_security_schema.sql
-- 依据：docs/stage1-three-person-implementation-plan.md §5 C-2
-- 说明：CREATE VIEW 必须是批次第一条语句（否则 Msg 111），故每个视图前用
--       “独立 SET 批次 + GO”；视图一律只读，不改任何基表；列名全部显式列出，
--       不使用 SELECT *；对视图的 GRANT SELECT 在 08_roles_permissions.sql 下发。
-- ============================================================================

USE KFC_DB;
GO

-- 批次 1：v_inventory_available —— 原料可用库存与低库存标记
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE VIEW dbo.v_inventory_available
AS
-- 用 LEFT JOIN 而不是 INNER JOIN：09c 为每种原料建一条库存记录，但万一漏建，
-- 该原料的可用量实际为 0、必然跌到安全线以下。INNER JOIN 会让它整行消失，
-- 低库存查询（Q-C1）就静默漏报了——漏报比报错危险，故此处补 0 兜底。
SELECT
    i.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    i.[status]                                                          AS ingredient_status,
    CAST(ISNULL(inv.on_hand_qty, 0) AS DECIMAL(12,3))                    AS on_hand_qty,
    CAST(ISNULL(inv.locked_qty, 0) AS DECIMAL(12,3))                     AS locked_qty,
    -- 可售量：只在视图里算，不落冗余字段（全局约束）
    CAST(ISNULL(inv.on_hand_qty, 0) - ISNULL(inv.locked_qty, 0) AS DECIMAL(12,3)) AS available_qty,
    i.safety_stock_qty,
    -- 是否低库存：与实扣后自动补货的触发口径一致（06 的补货刷新过程判的是
    -- 现有量低于安全库存线）。锁定量是已被订单占用、尚未出库的量，不参与
    -- “要不要补货”的判断；可售量反映的是“还能不能再接单”，两者不可混用。
    CAST(CASE WHEN ISNULL(inv.on_hand_qty, 0) < i.safety_stock_qty THEN 1 ELSE 0 END AS BIT) AS is_low_stock,
    inv.updated_at
FROM dbo.Ingredient AS i
LEFT JOIN dbo.Inventory AS inv
  ON inv.ingredient_id = i.ingredient_id;
GO


-- 批次 2：v_inventory_movement_history —— 库存流水（含关联单据号）
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE VIEW dbo.v_inventory_movement_history
AS
-- 只解析出单据号，不引入 Payment 与金额等无关支付信息（§5 C-2 明文要求）。
SELECT
    m.inventory_movement_id,
    m.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    m.movement_type,
    m.on_hand_delta,
    m.locked_delta,
    m.reference_type,
    m.reference_id,
    CASE m.reference_type
        WHEN 'ORDER'          THEN so.order_no
        WHEN 'PURCHASE_ORDER' THEN po.purchase_order_no
        ELSE NULL        -- 人工调整没有外部单据
    END                                                                  AS reference_no,
    m.moved_at
FROM dbo.InventoryMovement AS m
JOIN dbo.Ingredient AS i
  ON i.ingredient_id = m.ingredient_id
LEFT JOIN dbo.SalesOrder AS so
  ON m.reference_type = 'ORDER'
 AND so.order_id = m.reference_id
LEFT JOIN dbo.PurchaseOrder AS po
  ON m.reference_type = 'PURCHASE_ORDER'
 AND po.purchase_order_id = m.reference_id;
GO


-- 批次 3：v_replenishment_dashboard —— 补货建议看板（含采购与收货进度）
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE VIEW dbo.v_replenishment_dashboard
AS
-- 一条建议单最多对应一张采购单、一条采购明细：采购明细的主键是
-- （purchase_order_id, ingredient_id），而审批生成的采购单只含本建议的那一种原料，
-- 所以这里的 LEFT JOIN 不会放大行数。
SELECT
    rs.replenishment_suggestion_id,
    rs.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    rs.current_qty,
    rs.suggested_qty,
    rs.suggestion_status,
    rs.created_by_employee_id,
    cre.employee_name                                                   AS created_by_name,
    rs.submitted_by_employee_id,
    sub.employee_name                                                   AS submitted_by_name,
    rs.approved_by_employee_id,
    app.employee_name                                                   AS approved_by_name,
    rs.rejected_by_employee_id,
    rej.employee_name                                                   AS rejected_by_name,
    po.purchase_order_id,
    po.purchase_order_no,
    po.purchase_status,
    po.approved_at,
    poi.ordered_qty,
    poi.received_qty,
    -- 未收数量：还没生成采购单时为 NULL，不是 0——避免被读成“已收齐”
    CAST(poi.ordered_qty - poi.received_qty AS DECIMAL(12,3))           AS outstanding_qty
FROM dbo.ReplenishmentSuggestion AS rs
JOIN dbo.Ingredient AS i
  ON i.ingredient_id = rs.ingredient_id
LEFT JOIN dbo.PurchaseOrder AS po
  ON po.replenishment_suggestion_id = rs.replenishment_suggestion_id
LEFT JOIN dbo.PurchaseOrderItem AS poi
  ON poi.purchase_order_id = po.purchase_order_id
 AND poi.ingredient_id = rs.ingredient_id
LEFT JOIN dbo.EmployeeAccount AS cre
  ON cre.employee_id = rs.created_by_employee_id
LEFT JOIN dbo.EmployeeAccount AS sub
  ON sub.employee_id = rs.submitted_by_employee_id
LEFT JOIN dbo.EmployeeAccount AS app
  ON app.employee_id = rs.approved_by_employee_id
LEFT JOIN dbo.EmployeeAccount AS rej
  ON rej.employee_id = rs.rejected_by_employee_id;
GO


-- 批次 4：v_order_inventory_trace —— 订单 → 商品/套餐子项 → 原料 → 本单库存流水
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO

CREATE VIEW dbo.v_order_inventory_trace
AS
-- 用料展开口径必须与 sp_lock_order_inventory 完全一致，否则追溯结果会与实际锁库对不上：
--   ① 只有 SELLABLE 单品与 COMPONENT 子项参与展开；套餐父项自身没有直接 BOM，
--      它的用料体现在子项行上，故父项以套餐名出现在子项行里（sale_product_name）。
--   ② COMPONENT 行的商品就是子项商品，数量已含套餐倍数（§4 line 254），
--      所以只需经 ProductBom 展开一次，不再乘套餐组成表里的子项数量。
--   ③ 在售但配置不出用料的商品在这里查不到行，与锁库时直接报错的口径一致。
-- 流水列（movement_type / on_hand_delta / locked_delta）是整张订单在该原料上的流水，
-- 它不区分由哪个商品行造成；同一原料被多行商品共用时会在多行重复出现，
-- 因此不要跨行对 delta 求和——按原料汇总请用 Q-C2 的流水明细。
-- line_required_qty 才是本行的需求量。尚未锁库的订单行也会出现（流水列为 NULL），
-- 便于看出“该锁而没锁”。
SELECT
    so.order_id,
    so.order_no,
    soi.order_item_id,
    soi.item_role,
    COALESCE(parent_product.product_id, p.product_id)                    AS sale_product_id,
    COALESCE(parent_product.product_name, p.product_name)                AS sale_product_name,
    CASE WHEN soi.item_role = 'COMPONENT' THEN p.product_id END           AS combo_child_product_id,
    CASE WHEN soi.item_role = 'COMPONENT' THEN p.product_name END         AS combo_child_product_name,
    soi.quantity                                                         AS sale_qty,
    b.ingredient_id,
    i.ingredient_name,
    i.unit_name,
    b.usage_qty                                                          AS qty_per_sale,
    CAST(b.usage_qty * soi.quantity AS DECIMAL(12,3))                     AS line_required_qty,
    m.inventory_movement_id,
    m.movement_type,
    m.on_hand_delta,
    m.locked_delta,
    m.moved_at
FROM dbo.SalesOrder AS so
JOIN dbo.SalesOrderItem AS soi
  ON soi.order_id = so.order_id
JOIN dbo.Product AS p
  ON p.product_id = soi.product_id
LEFT JOIN dbo.SalesOrderItem AS parent_item
  ON parent_item.order_item_id = soi.parent_order_item_id
 AND parent_item.order_id = so.order_id        -- 套餐父子项必须同单（§4 line 254）
LEFT JOIN dbo.Product AS parent_product
  ON parent_product.product_id = parent_item.product_id
JOIN dbo.ProductBom AS b
  ON b.product_id = soi.product_id
JOIN dbo.Ingredient AS i
  ON i.ingredient_id = b.ingredient_id
LEFT JOIN dbo.InventoryMovement AS m
  ON m.reference_type = 'ORDER'
 AND m.reference_id = so.order_id
 AND m.ingredient_id = b.ingredient_id
 AND m.movement_type IN ('LOCK', 'RELEASE', 'CONSUME')   -- 只关联本单的锁定/释放/实扣流水
WHERE (soi.item_role = 'SELLABLE' AND p.product_type = 'SINGLE')
   OR soi.item_role = 'COMPONENT';
GO


-- 具名查询
-- Q-C1 低库存原料
SELECT
    ingredient_id,
    ingredient_name,
    unit_name,
    on_hand_qty,
    locked_qty,
    available_qty,
    safety_stock_qty,
    CAST(safety_stock_qty - on_hand_qty AS DECIMAL(12,3)) AS shortfall_qty
FROM dbo.v_inventory_available
WHERE is_low_stock = 1
  AND ingredient_status = 'ACTIVE'
ORDER BY shortfall_qty DESC, ingredient_name;
GO

-- Q-C2 指定订单的库存流水
DECLARE @order_id BIGINT = 1;   -- 换成要查的订单 ID

-- (1) 该订单的库存流水明细：一行一笔流水，不重复
SELECT
    reference_no,
    ingredient_name,
    unit_name,
    movement_type,
    on_hand_delta,
    locked_delta,
    moved_at
FROM dbo.v_inventory_movement_history
WHERE reference_type = 'ORDER'
  AND reference_id = @order_id
ORDER BY moved_at, inventory_movement_id;

-- (2) 同一订单的商品—套餐子项—原料追溯：看这些流水是被哪些商品用掉的
SELECT
    order_no,
    sale_product_name,
    combo_child_product_name,
    ingredient_name,
    unit_name,
    line_required_qty,
    movement_type,
    on_hand_delta,
    locked_delta,
    moved_at
FROM dbo.v_order_inventory_trace
WHERE order_id = @order_id
ORDER BY order_item_id, ingredient_name, moved_at;
GO

-- Q-C3 待审批补货建议
SELECT
    replenishment_suggestion_id,
    ingredient_id,
    ingredient_name,
    unit_name,
    current_qty,
    suggested_qty,
    suggestion_status,
    created_by_name,
    submitted_by_name
FROM dbo.v_replenishment_dashboard
WHERE suggestion_status = 'SUBMITTED'
ORDER BY replenishment_suggestion_id;
GO
