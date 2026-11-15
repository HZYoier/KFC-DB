-- ============================================================================
-- test_20_schema_v1_1.sql — C 域 v1.1 结构断言（成员 C；2026-11-15）
-- 运行时机：已执行 sql/stage3/20_schema_v1_1.sql，且 21c 已执行（签名断言）。
-- 运行方式：
--   sqlcmd -S '.\SQLEXPRESS' -E -C -f 65001 -b -d KFC_DB -i 本文件
-- 分母：14（表/列/约束/索引/折扣列/两个对象签名）
-- 断言码：54930 前置缺失、54998 有失败、54999 分母不足。
-- ============================================================================
:on error exit
USE KFC_DB;
GO
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NULL
    THROW 54930, N'缺少 dbo.InventoryAudit；请先执行 sql/stage3/20_schema_v1_1.sql。', 1;
IF OBJECT_ID(N'dbo.sp_adjust_inventory', N'P') IS NULL
    THROW 54930, N'缺少 dbo.sp_adjust_inventory；请先部署 v1.0。', 1;
IF OBJECT_ID(N'dbo.fn_replenishment_qty', N'FN') IS NULL
    THROW 54930, N'缺少 dbo.fn_replenishment_qty；请先执行 sql/stage3/21c_inventory_programmability.sql。', 1;

IF OBJECT_ID(N'tempdb..#counters_schema') IS NOT NULL DROP TABLE #counters_schema;
CREATE TABLE #counters_schema (pass INT NOT NULL, fail INT NOT NULL);
INSERT INTO #counters_schema (pass, fail) VALUES (0, 0);

-- 1. 审计表存在
IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NOT NULL
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 2. 审计表列数正好 12
IF (SELECT COUNT(*) FROM sys.columns WHERE object_id = OBJECT_ID(N'dbo.InventoryAudit')) = 12
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 3. 主键与自增
IF EXISTS (SELECT 1
           FROM sys.key_constraints AS kc
           JOIN sys.index_columns AS ic
             ON ic.object_id = kc.parent_object_id
            AND ic.index_id = kc.unique_index_id
           JOIN sys.columns AS c
             ON c.object_id = ic.object_id
            AND c.column_id = ic.column_id
           WHERE kc.parent_object_id = OBJECT_ID(N'dbo.InventoryAudit')
             AND kc.type = 'PK'
             AND c.name = N'inventory_audit_id'
             AND c.is_identity = 1)
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 4. 原料外键指向 Inventory(ingredient_id)
IF EXISTS (SELECT 1
           FROM sys.foreign_keys AS fk
           JOIN sys.foreign_key_columns AS fkc
             ON fkc.constraint_object_id = fk.object_id
           WHERE fk.parent_object_id = OBJECT_ID(N'dbo.InventoryAudit')
             AND fk.referenced_object_id = OBJECT_ID(N'dbo.Inventory')
             AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'ingredient_id'
             AND COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) = N'ingredient_id')
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 5. 员工外键指向 EmployeeAccount(employee_id)
IF EXISTS (SELECT 1
           FROM sys.foreign_keys AS fk
           JOIN sys.foreign_key_columns AS fkc
             ON fkc.constraint_object_id = fk.object_id
           WHERE fk.parent_object_id = OBJECT_ID(N'dbo.InventoryAudit')
             AND fk.referenced_object_id = OBJECT_ID(N'dbo.EmployeeAccount')
             AND COL_NAME(fkc.parent_object_id, fkc.parent_column_id) = N'employee_id'
             AND COL_NAME(fkc.referenced_object_id, fkc.referenced_column_id) = N'employee_id')
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 6. 操作类型 CHECK 存在且覆盖三种事件
IF EXISTS (SELECT 1
           FROM sys.check_constraints AS cc
           WHERE cc.parent_object_id = OBJECT_ID(N'dbo.InventoryAudit')
             AND cc.name = N'CK_InventoryAudit_operation_type'
             AND cc.definition LIKE N'%INSERT%'
             AND cc.definition LIKE N'%UPDATE%'
             AND cc.definition LIKE N'%DELETE%')
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 7. 按原料和时间的查询索引存在
IF EXISTS (SELECT 1
           FROM sys.indexes
           WHERE object_id = OBJECT_ID(N'dbo.InventoryAudit')
             AND name = N'IX_InventoryAudit_ingredient_operated_at')
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 8. discount_rate 类型 DECIMAL(5,4) NOT NULL
IF EXISTS (SELECT 1
           FROM sys.columns AS c
           JOIN sys.types AS t
             ON t.user_type_id = c.user_type_id
           WHERE c.object_id = OBJECT_ID(N'dbo.SalesOrderItem')
             AND c.name = N'discount_rate'
             AND t.name = N'decimal'
             AND c.precision = 5
             AND c.scale = 4
             AND c.is_nullable = 0)
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 9. discount_amount 类型 DECIMAL(10,2) NOT NULL
IF EXISTS (SELECT 1
           FROM sys.columns AS c
           JOIN sys.types AS t
             ON t.user_type_id = c.user_type_id
           WHERE c.object_id = OBJECT_ID(N'dbo.SalesOrderItem')
             AND c.name = N'discount_amount'
             AND t.name = N'decimal'
             AND c.precision = 10
             AND c.scale = 2
             AND c.is_nullable = 0)
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 10. 两个折扣列有独立默认约束
IF (SELECT COUNT(*) FROM sys.default_constraints
    WHERE parent_object_id = OBJECT_ID(N'dbo.SalesOrderItem')
      AND parent_column_id IN (COLUMNPROPERTY(OBJECT_ID(N'dbo.SalesOrderItem'), N'discount_rate', 'ColumnId'),
                               COLUMNPROPERTY(OBJECT_ID(N'dbo.SalesOrderItem'), N'discount_amount', 'ColumnId'))) = 2
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 11. sp_adjust_inventory 签名保持四个参数（名称/类型/顺序）
DECLARE @expected_sp TABLE
(
    parameter_id INT NOT NULL,
    parameter_name SYSNAME NOT NULL,
    type_name SYSNAME NOT NULL,
    max_length SMALLINT NOT NULL,
    precision_value TINYINT NOT NULL,
    scale_value TINYINT NOT NULL
);
INSERT INTO @expected_sp VALUES
    (1, N'@ingredient_id', N'bigint', 8, 19, 0),
    (2, N'@on_hand_delta', N'decimal', 9, 12, 3),
    (3, N'@employee_id', N'bigint', 8, 19, 0),
    (4, N'@reason', N'varchar', 50, 0, 0);

IF NOT EXISTS
(
    SELECT parameter_id, parameter_name, type_name, max_length, precision_value, scale_value
    FROM @expected_sp
    EXCEPT
    SELECT p.parameter_id, p.name, TYPE_NAME(p.user_type_id),
           p.max_length, p.precision, p.scale
    FROM sys.parameters AS p
    WHERE p.object_id = OBJECT_ID(N'dbo.sp_adjust_inventory')
      AND p.parameter_id > 0
)
AND NOT EXISTS
(
    SELECT p.parameter_id, p.name, TYPE_NAME(p.user_type_id),
           p.max_length, p.precision, p.scale
    FROM sys.parameters AS p
    WHERE p.object_id = OBJECT_ID(N'dbo.sp_adjust_inventory')
      AND p.parameter_id > 0
    EXCEPT
    SELECT parameter_id, parameter_name, type_name, max_length, precision_value, scale_value
    FROM @expected_sp
)
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 12. fn_replenishment_qty 是标量函数且存在
IF EXISTS (SELECT 1 FROM sys.objects
           WHERE object_id = OBJECT_ID(N'dbo.fn_replenishment_qty')
             AND type = 'FN')
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 13. 函数三个参数名称/类型/顺序
DECLARE @expected_fn TABLE
(
    parameter_id INT NOT NULL,
    parameter_name SYSNAME NOT NULL,
    type_name SYSNAME NOT NULL,
    precision_value TINYINT NOT NULL,
    scale_value TINYINT NOT NULL
);
INSERT INTO @expected_fn VALUES
    (1, N'@ingredient_id', N'bigint', 19, 0),
    (2, N'@target_qty', N'decimal', 12, 3),
    (3, N'@min_qty', N'decimal', 12, 3);

IF NOT EXISTS
(
    SELECT parameter_id, parameter_name, type_name, precision_value, scale_value
    FROM @expected_fn
    EXCEPT
    SELECT p.parameter_id, p.name, TYPE_NAME(p.user_type_id), p.precision, p.scale
    FROM sys.parameters AS p
    WHERE p.object_id = OBJECT_ID(N'dbo.fn_replenishment_qty')
      AND p.parameter_id > 0
)
AND NOT EXISTS
(
    SELECT p.parameter_id, p.name, TYPE_NAME(p.user_type_id), p.precision, p.scale
    FROM sys.parameters AS p
    WHERE p.object_id = OBJECT_ID(N'dbo.fn_replenishment_qty')
      AND p.parameter_id > 0
    EXCEPT
    SELECT parameter_id, parameter_name, type_name, precision_value, scale_value
    FROM @expected_fn
)
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

-- 14. 第三个参数可用 DEFAULT 调用（SQL Server 要求实参个数写满；
--      sys.parameters.has_default_value 对 T-SQL 标量函数不返回 1，
--      因此用真实调用验证默认参数，而不是查目录标志）。
DECLARE @schema_ingredient BIGINT =
    (SELECT TOP (1) ingredient_id FROM dbo.Ingredient ORDER BY ingredient_id);
IF @schema_ingredient IS NOT NULL
   AND dbo.fn_replenishment_qty(@schema_ingredient,
                                CAST(1.000 AS DECIMAL(12,3)), DEFAULT) IS NOT NULL
    UPDATE #counters_schema SET pass = pass + 1;
ELSE
    UPDATE #counters_schema SET fail = fail + 1;

DECLARE @pass INT = (SELECT pass FROM #counters_schema);
DECLARE @fail INT = (SELECT fail FROM #counters_schema);
DECLARE @total INT = @pass + @fail;

PRINT CONCAT(N'RESULT: c-programmability schema pass=', @pass,
             N' fail=', @fail, N' total=', @total);
IF @total <> 14
    THROW 54999, N'20 结构测试分母不足：期望 14 条，实际计数不是 14。', 1;
IF @fail > 0
    THROW 54998, N'20 结构测试存在失败断言。', 1;
GO
