-- ============================================================================
-- 20_schema_v1_1.sql — v1.1 结构增量（成员 C；2026-11-15）
-- 定位：由 run_stage3.sql 在外层事务内 :r 执行；本文件不 BEGIN/COMMIT/ROLLBACK，
--       不删表、不删库、不改存量业务列语义，只做加法。
-- 内容：1) 新增 dbo.InventoryAudit（库存行级审计，22c 的触发器写入）
--       2) SalesOrderItem 增加 discount_rate / discount_amount 折扣快照两列
--           （B 的两条下单路径在 21b 中写入；A 的 sales-semantics.md F-01/F-03 定语义）
-- 前置：v1.0 已部署；Inventory、EmployeeAccount、SalesOrderItem 均存在。
-- 重复：v1.1 已存在时必须由 run_stage3.sql 拒绝；本文件另以对象存在守卫兜底。
-- 依据：docs/stage3/three-person-implementation-plan.md §0、§4.2、§5.1、§8.3；
--       docs/stage3/sales-semantics.md F-01/F-03。
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

IF OBJECT_ID(N'dbo.Inventory', N'U') IS NULL
   OR OBJECT_ID(N'dbo.EmployeeAccount', N'U') IS NULL
   OR OBJECT_ID(N'dbo.SalesOrderItem', N'U') IS NULL
    THROW 54410, N'20: v1.0 core tables are missing; deploy v1.0 before applying v1.1.', 1;

IF OBJECT_ID(N'dbo.InventoryAudit', N'U') IS NOT NULL
    THROW 54411, N'20: dbo.InventoryAudit already exists; v1.1 is already applied or partially applied.', 1;

IF COL_LENGTH(N'dbo.SalesOrderItem', N'discount_rate') IS NOT NULL
   OR COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') IS NOT NULL
    THROW 54412, N'20: SalesOrderItem discount columns already exist; v1.1 is already applied or partially applied.', 1;
GO

-- ---------------------------------------------------------------------------
-- 1. 库存行级审计表
--    AuditLog 记“谁做了什么业务动作”；InventoryAudit 记“哪一行库存数量
--    从多少变到多少”。两表分工不同，允许同一业务动作同时留下两类记录。
--    before_* / after_* 在 INSERT/DELETE 时为 NULL；employee_id 解析不到时
--    为 NULL（系统主体或直接 DML），但 operated_by 始终记录 USER_NAME()。
-- ---------------------------------------------------------------------------
CREATE TABLE dbo.InventoryAudit
(
    inventory_audit_id BIGINT IDENTITY(1,1) NOT NULL
        CONSTRAINT PK_InventoryAudit PRIMARY KEY,
    ingredient_id      BIGINT        NOT NULL,
    before_on_hand     DECIMAL(12,3) NULL,
    after_on_hand      DECIMAL(12,3) NULL,
    delta_on_hand      DECIMAL(12,3) NOT NULL,
    before_locked      DECIMAL(12,3) NULL,
    after_locked       DECIMAL(12,3) NULL,
    delta_locked       DECIMAL(12,3) NOT NULL,
    operation_type     VARCHAR(10)   NOT NULL,
    operated_by        VARCHAR(128)  NOT NULL,
    employee_id        BIGINT        NULL,
    operated_at        DATETIME2(0)  NOT NULL,
    CONSTRAINT FK_InventoryAudit_Inventory
        FOREIGN KEY (ingredient_id) REFERENCES dbo.Inventory(ingredient_id),
    CONSTRAINT FK_InventoryAudit_EmployeeAccount
        FOREIGN KEY (employee_id) REFERENCES dbo.EmployeeAccount(employee_id),
    CONSTRAINT CK_InventoryAudit_operation_type
        CHECK (operation_type IN ('INSERT', 'UPDATE', 'DELETE'))
);
GO

CREATE INDEX IX_InventoryAudit_ingredient_operated_at
    ON dbo.InventoryAudit(ingredient_id, operated_at DESC, inventory_audit_id DESC);
GO

-- ---------------------------------------------------------------------------
-- 2. 订单明细折扣快照两列
--    v1.0 存量行由 DEFAULT 填 0，语义为“无折扣 / 不回填历史”；
--    v1.1 新订单由 B 的 sp_create_order / sp_customer_place_order 写入当时快照。
--    只加列，不改 unit_price、total_amount 或任何存量行。
-- ---------------------------------------------------------------------------
ALTER TABLE dbo.SalesOrderItem
    ADD discount_rate DECIMAL(5,4) NOT NULL
            CONSTRAINT DF_SalesOrderItem_discount_rate DEFAULT (0),
        discount_amount DECIMAL(10,2) NOT NULL
            CONSTRAINT DF_SalesOrderItem_discount_amount DEFAULT (0.00);
GO

-- ---------------------------------------------------------------------------
-- 3. 本文件自检：列、约束、索引齐备后才让 run_stage3.sql 继续
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF (SELECT COUNT(*) FROM sys.columns
    WHERE object_id = OBJECT_ID(N'dbo.InventoryAudit')) <> 12
    THROW 54413, N'20: InventoryAudit must have exactly 12 columns.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'PK_InventoryAudit'
                 AND parent_object_id = OBJECT_ID(N'dbo.InventoryAudit'))
    THROW 54414, N'20: InventoryAudit primary key is missing.', 1;

IF (SELECT COUNT(*) FROM sys.foreign_keys
    WHERE parent_object_id = OBJECT_ID(N'dbo.InventoryAudit')) <> 2
    THROW 54415, N'20: InventoryAudit must have two foreign keys.', 1;

IF COL_LENGTH(N'dbo.SalesOrderItem', N'discount_rate') IS NULL
   OR COL_LENGTH(N'dbo.SalesOrderItem', N'discount_amount') IS NULL
    THROW 54416, N'20: SalesOrderItem discount columns are missing after ALTER.', 1;

IF NOT EXISTS (SELECT 1 FROM sys.default_constraints
               WHERE name = N'DF_SalesOrderItem_discount_rate'
                 AND parent_object_id = OBJECT_ID(N'dbo.SalesOrderItem'))
   OR NOT EXISTS (SELECT 1 FROM sys.default_constraints
                  WHERE name = N'DF_SalesOrderItem_discount_amount'
                    AND parent_object_id = OBJECT_ID(N'dbo.SalesOrderItem'))
    THROW 54417, N'20: SalesOrderItem discount defaults are missing.', 1;

PRINT N'20: InventoryAudit and SalesOrderItem discount columns created.';
GO
