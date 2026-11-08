/*
 B-owned order reporting views and runnable query examples.
 Requires the five B tables from 02_order_schema.sql and the Customer/Product
 master tables installed before this script. Execute with sqlcmd -b.
*/
USE KFC_DB;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
SET XACT_ABORT ON;
IF EXISTS (
    SELECT 1
    FROM (VALUES
        (N'SalesOrder'), (N'SalesOrderItem'), (N'Payment'), (N'Delivery'), (N'PointLedger')
    ) AS required_b_table(name)
    WHERE OBJECT_ID(N'dbo.' + required_b_table.name, N'U') IS NULL
)
    THROW 52900, 'B view prerequisites are missing: install all five B tables from 02_order_schema.sql first.', 1;
IF EXISTS (
    SELECT 1
    FROM (VALUES (N'Customer'), (N'Product')) AS required_master_table(name)
    WHERE OBJECT_ID(N'dbo.' + required_master_table.name, N'U') IS NULL
)
    THROW 52901, 'B view prerequisites are missing: install A Customer and Product tables first.', 1;
IF EXISTS (
    SELECT 1
    FROM (VALUES
        (N'v_order_detail'), (N'v_kitchen_queue'),
        (N'v_customer_point_ledger'), (N'v_pickup_board')
    ) AS planned_view(name)
    WHERE OBJECT_ID(N'dbo.' + planned_view.name) IS NOT NULL
)
    THROW 52902, 'One or more B views already exist; use a reviewed migration.', 1;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE VIEW dbo.v_order_detail
(
    order_id, order_no, customer_id, customer_mobile, customer_type,
    fulfillment_method, order_status, pickup_code,
    ordered_at, order_paid_at, production_started_at, production_finished_at,
    completed_at, cancelled_at, order_created_at, order_updated_at,
    order_item_id, item_role, parent_order_item_id, product_id, product_name,
    quantity, unit_price, promotion_id, total_amount,
    payment_id, payment_method, paid_amount, payment_status, payment_paid_at,
    refunded_amount, refunded_at
)
AS
SELECT
    o.order_id, o.order_no, c.customer_id, c.mobile, c.customer_type,
    o.fulfillment_method, o.order_status, o.pickup_code,
    o.ordered_at, o.paid_at, o.production_started_at, o.production_finished_at,
    o.completed_at, o.cancelled_at, o.created_at, o.updated_at,
    oi.order_item_id, oi.item_role, oi.parent_order_item_id, p.product_id, p.product_name,
    oi.quantity, oi.unit_price, oi.promotion_id, o.total_amount,
    pay.payment_id, pay.payment_method, pay.paid_amount, pay.payment_status, pay.paid_at,
    pay.refunded_amount, pay.refunded_at
FROM dbo.SalesOrder AS o
INNER JOIN dbo.Customer AS c ON c.customer_id = o.customer_id
INNER JOIN dbo.SalesOrderItem AS oi ON oi.order_id = o.order_id
INNER JOIN dbo.Product AS p ON p.product_id = oi.product_id
LEFT JOIN dbo.Payment AS pay ON pay.order_id = o.order_id;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE VIEW dbo.v_kitchen_queue
(
    order_id, order_no, ordered_at, order_status,
    order_item_id, item_role, parent_order_item_id, product_id, product_name,
    quantity, customization_note
)
AS
SELECT
    o.order_id, o.order_no, o.ordered_at, o.order_status,
    oi.order_item_id, oi.item_role, oi.parent_order_item_id, p.product_id, p.product_name,
    oi.quantity, CAST(N'第一阶段不存定制备注' AS NVARCHAR(20))
FROM dbo.SalesOrder AS o
INNER JOIN dbo.SalesOrderItem AS oi ON oi.order_id = o.order_id
INNER JOIN dbo.Product AS p ON p.product_id = oi.product_id
WHERE o.order_status IN ('PAID', 'IN_PRODUCTION')
  AND oi.item_role IN ('SELLABLE', 'COMPONENT');
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE VIEW dbo.v_customer_point_ledger
(
    point_ledger_id, customer_id, customer_mobile, customer_type,
    order_id, order_no, paid_amount_snapshot, point_multiplier_snapshot,
    point_delta, ledger_status, ledger_created_at, effective_at, current_points
)
AS
SELECT
    pl.point_ledger_id, c.customer_id, c.mobile, c.customer_type,
    o.order_id, o.order_no, pl.paid_amount_snapshot, pl.point_multiplier_snapshot,
    pl.point_delta, pl.ledger_status, pl.created_at, pl.effective_at, c.current_points
FROM dbo.PointLedger AS pl
INNER JOIN dbo.Customer AS c ON c.customer_id = pl.customer_id
INNER JOIN dbo.SalesOrder AS o ON o.order_id = pl.order_id;
GO

SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;
GO
CREATE VIEW dbo.v_pickup_board
(
    order_no, pickup_code, order_status, ordered_at
)
AS
SELECT
    o.order_no, o.pickup_code, o.order_status, o.ordered_at
FROM dbo.SalesOrder AS o
WHERE o.order_status = 'READY_FOR_PICKUP';
GO

-- Q-B1 待制作订单
-- Purpose: let kitchen staff retrieve only the active production queue.
SELECT
    q.order_id, q.order_no, q.ordered_at, q.order_status,
    q.order_item_id, q.item_role, q.parent_order_item_id, q.product_id,
    q.product_name, q.quantity, q.customization_note
FROM dbo.v_kitchen_queue AS q
ORDER BY q.ordered_at, q.order_no, q.order_item_id;
GO

-- Q-B2 某订单完整履约记录
-- Purpose: trace the order, its item snapshots, and any payment/refund outcome.
DECLARE @order_no VARCHAR(50) = 'B-SEED-PICKUP-001';
SELECT
    d.order_id, d.order_no, d.customer_id, d.customer_mobile, d.customer_type,
    d.fulfillment_method, d.order_status, d.pickup_code,
    d.ordered_at, d.order_paid_at, d.production_started_at, d.production_finished_at,
    d.completed_at, d.cancelled_at, d.order_created_at, d.order_updated_at,
    d.order_item_id, d.item_role, d.parent_order_item_id, d.product_id, d.product_name,
    d.quantity, d.unit_price, d.promotion_id, d.total_amount,
    d.payment_id, d.payment_method, d.paid_amount, d.payment_status,
    d.payment_paid_at, d.refunded_amount, d.refunded_at
FROM dbo.v_order_detail AS d
WHERE d.order_no = @order_no
ORDER BY d.order_item_id;
GO

-- Q-B3 某顾客积分流水
-- Purpose: review one customer's immutable points snapshots and current balance.
DECLARE @customer_id BIGINT = 1;
SELECT
    l.point_ledger_id, l.customer_id, l.customer_mobile, l.customer_type,
    l.order_id, l.order_no, l.paid_amount_snapshot, l.point_multiplier_snapshot,
    l.point_delta, l.ledger_status, l.ledger_created_at, l.effective_at, l.current_points
FROM dbo.v_customer_point_ledger AS l
WHERE l.customer_id = @customer_id
ORDER BY l.ledger_created_at, l.point_ledger_id;
GO
