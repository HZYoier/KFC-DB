/* =====================================================================
   check_a_migration_compare_20261109.sql
   迁移前后关键查询对照（只读）：把 MigrationBaseline_*（batch_id = 当前批次）
   与迁移后的 dbo.* 逐项比对，回答"v0.1 -> v1.0 有没有动坏业务数据"。

   用法（仓库根目录，-i 用相对路径）：
     sqlcmd -S localhost -E -C -f 65001 -b -I -i "result/stage2/scripts/check_a_migration_compare_20261109.sql"
   输出归档：result/stage2/a-migration-compare-2026-11-09.txt

   口径：
   - 逐单 / 逐明细 / 逐原料 / 逐人 对账只比业务事实列，不比 updated_at
     （迁移会重写审计时间戳，不构成数据变化）。
   - 权限部分预期变化：12 把授权行按 58 个权限码重建，RolePermission 从
     52 行扩到 71 行，permission_name 拆进 Permission 表；这里核的是
     "原授权不丢、名称不改、只增不减"。
   ===================================================================== */
:on error exit
SET NOCOUNT ON;
GO
USE KFC_DB;
GO

DECLARE @batch bigint = (SELECT MAX(batch_id) FROM dbo.MigrationBatch WHERE batch_status = 'COMPLETED');
IF @batch IS NULL
    THROW 53520, N'没有 COMPLETED 状态的迁移批次，无法对照', 1;

PRINT N'== 0. 迁移批次与版本标记 ==';
SELECT batch_id, batch_status, source_baseline, capture_scope_version, schema_digest,
       CONVERT(varchar(19), capture_started_at, 120)   AS capture_started_at,
       CONVERT(varchar(19), capture_completed_at, 120) AS capture_completed_at
FROM dbo.MigrationBatch
WHERE batch_id = @batch;

SELECT version_code, object_digest, batch_id,
       CONVERT(varchar(19), applied_at, 120) AS applied_at, note
FROM dbo.SchemaVersion
ORDER BY applied_at;

/* ---------- 1. 汇总对照 ---------- */
PRINT N'';
PRINT N'== 1. 汇总对照（迁移前 = Baseline 快照，迁移后 = 当前表）==';

CREATE TABLE #cmp (
    seq      int IDENTITY(1,1) PRIMARY KEY,
    item     nvarchar(40)  NOT NULL,
    before_v nvarchar(60)  NOT NULL,
    after_v  nvarchar(60)  NOT NULL,
    note     nvarchar(60)  NOT NULL
);

INSERT #cmp (item, before_v, after_v, note)
SELECT N'订单数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_SalesOrder WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.SalesOrder)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'订单总额',
       CONVERT(nvarchar(60), CAST((SELECT SUM(total_amount) FROM dbo.Baseline_SalesOrder WHERE batch_id = @batch) AS decimal(18,2))),
       CONVERT(nvarchar(60), CAST((SELECT SUM(total_amount) FROM dbo.SalesOrder) AS decimal(18,2))),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'订单明细行数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.SalesOrderItem)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'售出总份数',
       CONVERT(nvarchar(60), (SELECT SUM(quantity) FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT SUM(quantity) FROM dbo.SalesOrderItem)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'明细金额合计',
       CONVERT(nvarchar(60), CAST((SELECT SUM(quantity * unit_price) FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch) AS decimal(18,2))),
       CONVERT(nvarchar(60), CAST((SELECT SUM(quantity * unit_price) FROM dbo.SalesOrderItem) AS decimal(18,2))),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'商品数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_Product WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Product)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'库存行数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_Inventory WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Inventory)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'在库总量',
       CONVERT(nvarchar(60), CAST((SELECT SUM(on_hand_qty) FROM dbo.Baseline_Inventory WHERE batch_id = @batch) AS decimal(18,2))),
       CONVERT(nvarchar(60), CAST((SELECT SUM(on_hand_qty) FROM dbo.Inventory) AS decimal(18,2))),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'锁定总量',
       CONVERT(nvarchar(60), CAST((SELECT SUM(locked_qty) FROM dbo.Baseline_Inventory WHERE batch_id = @batch) AS decimal(18,2))),
       CONVERT(nvarchar(60), CAST((SELECT SUM(locked_qty) FROM dbo.Inventory) AS decimal(18,2))),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'顾客数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_Customer WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Customer)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'积分余额合计',
       CONVERT(nvarchar(60), (SELECT SUM(current_points) FROM dbo.Baseline_Customer WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT SUM(current_points) FROM dbo.Customer)),
       N'不应变化';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'业务表数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM sys.tables WHERE name LIKE 'Baseline[_]%')),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM sys.tables
                              WHERE name NOT LIKE 'Baseline[_]%'
                                AND name NOT IN ('MigrationBatch', 'SchemaVersion')
                                AND name NOT LIKE 'MigrationBaseline%')),
       N'新增 Permission 表';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'角色授权行数',
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Baseline_RolePermission WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.RolePermission)),
       N'按 v1.0 权限码重建，预期增';
INSERT #cmp (item, before_v, after_v, note)
SELECT N'权限码数',
       CONVERT(nvarchar(60), (SELECT COUNT(DISTINCT permission_code) FROM dbo.Baseline_RolePermission WHERE batch_id = @batch)),
       CONVERT(nvarchar(60), (SELECT COUNT(*) FROM dbo.Permission)),
       N'v1.0 权限目录，预期增';

SELECT seq AS 序号, item AS 指标, before_v AS 迁移前, after_v AS 迁移后,
       CASE WHEN before_v = after_v THEN N'一致' ELSE N'变化' END AS 判定,
       note AS 口径
FROM #cmp
ORDER BY seq;

/* ---------- 2. 逐行对账：应当零差异 ---------- */
PRINT N'';
PRINT N'== 2. 逐行对账（四组差异计数都应全 0）==';

SELECT N'订单' AS 对象,
       SUM(CASE WHEN b.order_id IS NULL THEN 1 ELSE 0 END) AS 仅迁移后存在,
       SUM(CASE WHEN s.order_id IS NULL THEN 1 ELSE 0 END) AS 仅基线有,
       SUM(CASE WHEN s.order_id IS NOT NULL AND b.order_id IS NOT NULL
                 AND (s.total_amount <> b.total_amount OR s.order_status <> b.order_status)
                THEN 1 ELSE 0 END) AS 字段不一致
FROM dbo.Baseline_SalesOrder b
FULL OUTER JOIN dbo.SalesOrder s ON s.order_id = b.order_id
WHERE b.batch_id = @batch OR b.batch_id IS NULL;

SELECT N'订单明细' AS 对象,
       SUM(CASE WHEN b.order_item_id IS NULL THEN 1 ELSE 0 END) AS 仅迁移后存在,
       SUM(CASE WHEN s.order_item_id IS NULL THEN 1 ELSE 0 END) AS 仅基线有,
       SUM(CASE WHEN s.order_item_id IS NOT NULL AND b.order_item_id IS NOT NULL
                 AND (s.product_id <> b.product_id
                      OR s.quantity <> b.quantity
                      OR s.unit_price <> b.unit_price)
                THEN 1 ELSE 0 END) AS 字段不一致
FROM dbo.Baseline_SalesOrderItem b
FULL OUTER JOIN dbo.SalesOrderItem s ON s.order_item_id = b.order_item_id
WHERE b.batch_id = @batch OR b.batch_id IS NULL;

SELECT N'库存' AS 对象,
       SUM(CASE WHEN b.ingredient_id IS NULL THEN 1 ELSE 0 END) AS 仅迁移后存在,
       SUM(CASE WHEN s.ingredient_id IS NULL THEN 1 ELSE 0 END) AS 仅基线有,
       SUM(CASE WHEN s.ingredient_id IS NOT NULL AND b.ingredient_id IS NOT NULL
                 AND (s.on_hand_qty <> b.on_hand_qty OR s.locked_qty <> b.locked_qty)
                THEN 1 ELSE 0 END) AS 字段不一致
FROM dbo.Baseline_Inventory b
FULL OUTER JOIN dbo.Inventory s ON s.ingredient_id = b.ingredient_id
WHERE b.batch_id = @batch OR b.batch_id IS NULL;

SELECT N'顾客' AS 对象,
       SUM(CASE WHEN b.customer_id IS NULL THEN 1 ELSE 0 END) AS 仅迁移后存在,
       SUM(CASE WHEN s.customer_id IS NULL THEN 1 ELSE 0 END) AS 仅基线有,
       SUM(CASE WHEN s.customer_id IS NOT NULL AND b.customer_id IS NOT NULL
                 AND (s.current_points <> b.current_points
                      OR ISNULL(s.member_level_id, -1) <> ISNULL(b.member_level_id, -1)
                      OR s.status <> b.status)
                THEN 1 ELSE 0 END) AS 字段不一致
FROM dbo.Baseline_Customer b
FULL OUTER JOIN dbo.Customer s ON s.customer_id = b.customer_id
WHERE b.batch_id = @batch OR b.batch_id IS NULL;

/* ---------- 3. 抽样（人工可读）---------- */
PRINT N'';
PRINT N'== 3. 抽样：订单逐单对照 ==';

SELECT b.order_id, b.order_no,
       b.order_status AS 迁移前状态, s.order_status AS 迁移后状态,
       b.total_amount AS 迁移前金额, s.total_amount AS 迁移后金额
FROM dbo.Baseline_SalesOrder b
JOIN dbo.SalesOrder s ON s.order_id = b.order_id
WHERE b.batch_id = @batch
ORDER BY b.order_id;

PRINT N'';
PRINT N'== 4. 抽样：订单明细按商品汇总，迁移前后逐商品对照 ==';

SELECT COALESCE(b.product_id, s.product_id) AS product_id,
       COALESCE(b.份数, 0) AS 迁移前份数,
       COALESCE(s.份数, 0) AS 迁移后份数,
       CASE WHEN ISNULL(b.份数, 0) = ISNULL(s.份数, 0) THEN N'一致' ELSE N'变化' END AS 判定
FROM (SELECT product_id, SUM(quantity) AS 份数
      FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch
      GROUP BY product_id) b
FULL OUTER JOIN (SELECT product_id, SUM(quantity) AS 份数
                 FROM dbo.SalesOrderItem
                 GROUP BY product_id) s ON s.product_id = b.product_id
ORDER BY product_id;

/* ---------- 5. 权限：按角色对账 ---------- */
PRINT N'';
PRINT N'== 5. 权限按角色对账（行数变化是 v1.0 权限码扩充的结果，不是丢授权）==';

SELECT r.business_role_id, r.role_code, r.role_name,
       ISNULL(b.授权行数, 0) AS 迁移前授权行数,
       ISNULL(a.授权行数, 0) AS 迁移后授权行数
FROM dbo.BusinessRole r
LEFT JOIN (SELECT business_role_id, COUNT(*) AS 授权行数
           FROM dbo.Baseline_RolePermission WHERE batch_id = @batch
           GROUP BY business_role_id) b ON b.business_role_id = r.business_role_id
LEFT JOIN (SELECT business_role_id, COUNT(*) AS 授权行数
           FROM dbo.RolePermission
           GROUP BY business_role_id) a ON a.business_role_id = r.business_role_id
ORDER BY r.business_role_id;

PRINT N'';
PRINT N'== 6. 权限码增删与名称一致性（删除应为 0，名称不一致应为 0）==';

SELECT N'基线有、迁移后没有的权限码' AS 口径, COUNT(*) AS 条数
FROM (SELECT DISTINCT permission_code FROM dbo.Baseline_RolePermission WHERE batch_id = @batch
      EXCEPT
      SELECT permission_code FROM dbo.Permission) d;

SELECT N'权限码名称迁移前后不一致' AS 口径, COUNT(*) AS 条数
FROM (SELECT DISTINCT b.permission_code, b.permission_name
      FROM dbo.Baseline_RolePermission b
      JOIN dbo.Permission p ON p.permission_code = b.permission_code
      WHERE b.batch_id = @batch
        AND p.permission_name <> b.permission_name) d;

SELECT p.permission_code, p.permission_name
FROM dbo.Permission p
WHERE NOT EXISTS (SELECT 1 FROM dbo.Baseline_RolePermission b
                  WHERE b.batch_id = @batch AND b.permission_code = p.permission_code)
ORDER BY p.permission_code;

/* ---------- 7. 结论 ---------- */
PRINT N'';
PRINT N'== 7. 结论 ==';

DECLARE @bad int = 0;

SET @bad += (SELECT COUNT(*)
             FROM (SELECT order_id, total_amount, order_status FROM dbo.Baseline_SalesOrder WHERE batch_id = @batch
                   EXCEPT
                   SELECT order_id, total_amount, order_status FROM dbo.SalesOrder) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT order_id, total_amount, order_status FROM dbo.SalesOrder
                   EXCEPT
                   SELECT order_id, total_amount, order_status FROM dbo.Baseline_SalesOrder WHERE batch_id = @batch) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT order_item_id, product_id, quantity, unit_price FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch
                   EXCEPT
                   SELECT order_item_id, product_id, quantity, unit_price FROM dbo.SalesOrderItem) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT order_item_id, product_id, quantity, unit_price FROM dbo.SalesOrderItem
                   EXCEPT
                   SELECT order_item_id, product_id, quantity, unit_price FROM dbo.Baseline_SalesOrderItem WHERE batch_id = @batch) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT ingredient_id, on_hand_qty, locked_qty FROM dbo.Baseline_Inventory WHERE batch_id = @batch
                   EXCEPT
                   SELECT ingredient_id, on_hand_qty, locked_qty FROM dbo.Inventory) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT ingredient_id, on_hand_qty, locked_qty FROM dbo.Inventory
                   EXCEPT
                   SELECT ingredient_id, on_hand_qty, locked_qty FROM dbo.Baseline_Inventory WHERE batch_id = @batch) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT customer_id, current_points, member_level_id, status FROM dbo.Baseline_Customer WHERE batch_id = @batch
                   EXCEPT
                   SELECT customer_id, current_points, member_level_id, status FROM dbo.Customer) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT customer_id, current_points, member_level_id, status FROM dbo.Customer
                   EXCEPT
                   SELECT customer_id, current_points, member_level_id, status FROM dbo.Baseline_Customer WHERE batch_id = @batch) d);
SET @bad += (SELECT COUNT(*)
             FROM (SELECT DISTINCT permission_code FROM dbo.Baseline_RolePermission WHERE batch_id = @batch
                   EXCEPT
                   SELECT permission_code FROM dbo.Permission) d);

SELECT CASE WHEN @bad = 0 THEN N'PASS' ELSE N'FAIL' END AS 结果,
       @bad AS 差异行数,
       N'订单 / 明细 / 库存 / 顾客四组业务事实逐行一致，原权限码一个不少' AS 判据;

IF @bad <> 0
    THROW 53521, N'迁移前后对照存在差异，见第 2 至 6 节', 1;
