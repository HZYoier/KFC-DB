-- ============================================================================
-- 03_inventory_security_schema.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：创建 C 域安全表与库存/补货/审计表；为 B 的 Delivery 补骑手外键
-- 依赖：00_create_database.sql、01_master_schema.sql（Ingredient）、
--       02_order_schema.sql（Delivery）
-- 依据：docs/stage1-three-person-implementation-plan.md §2.1、§5 C-1
-- 说明：表名、主键与关键字段冻结于 §2.1，字段可新增但不得删除或改主键类型；
--       值域与数值 CHECK 约束统一在 06_inventory_constraints_crud.sql 建立。
--       除最后一条 Delivery 骑手外键外，本文件其余语句均不依赖 B 的脚本。
-- ============================================================================

USE KFC_DB;
GO

-- 批次 1：安全域 4 张表（EmployeeAccount -> BusinessRole -> EmployeeBusinessRole -> RolePermission）
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

CREATE TABLE dbo.EmployeeAccount(
    employee_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_EmployeeAccount PRIMARY KEY,
    database_user_name VARCHAR(128) NOT NULL,
    login_name VARCHAR(128) NOT NULL,
    employee_name NVARCHAR(50) NOT NULL,
    job_code VARCHAR(20) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT UQ_EmployeeAccount_database_user_name
        UNIQUE (database_user_name),
    CONSTRAINT UQ_EmployeeAccount_login_name
        UNIQUE (login_name)
);

CREATE TABLE dbo.BusinessRole(
    business_role_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_BusinessRole PRIMARY KEY,
    role_code VARCHAR(20) NOT NULL,
    role_name NVARCHAR(50) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT UQ_BusinessRole_role_code
        UNIQUE (role_code)
);

CREATE TABLE dbo.EmployeeBusinessRole(
    employee_id BIGINT NOT NULL,
    business_role_id BIGINT NOT NULL,
    assigned_by_employee_id BIGINT NOT NULL,
    assigned_at DATETIME2(0) NOT NULL,
    CONSTRAINT PK_EmployeeBusinessRole
        PRIMARY KEY (employee_id, business_role_id),
    CONSTRAINT FK_EmployeeBusinessRole_Employee
        FOREIGN KEY (employee_id) REFERENCES dbo.EmployeeAccount(employee_id),
    CONSTRAINT FK_EmployeeBusinessRole_BusinessRole
        FOREIGN KEY (business_role_id) REFERENCES dbo.BusinessRole(business_role_id),
    CONSTRAINT FK_EmployeeBusinessRole_AssignedByEmployee
        FOREIGN KEY (assigned_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id)
);

CREATE TABLE dbo.RolePermission(
    business_role_id BIGINT NOT NULL,
    permission_code VARCHAR(50) NOT NULL,
    permission_name NVARCHAR(100) NOT NULL,
    status VARCHAR(20) NOT NULL,
    CONSTRAINT PK_RolePermission
        PRIMARY KEY (business_role_id, permission_code),
    CONSTRAINT FK_RolePermission_BusinessRole
        FOREIGN KEY (business_role_id) REFERENCES dbo.BusinessRole(business_role_id)
);
GO

-- 批次 2：库存、补货与审计 6 张表
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

CREATE TABLE dbo.Inventory(
    ingredient_id BIGINT NOT NULL
        CONSTRAINT PK_Inventory PRIMARY KEY,
    on_hand_qty DECIMAL(12,3) NOT NULL,
    locked_qty DECIMAL(12,3) NOT NULL,
    updated_at DATETIME2(0) NOT NULL,
    CONSTRAINT FK_Inventory_Ingredient
        FOREIGN KEY (ingredient_id) REFERENCES dbo.Ingredient(ingredient_id)
);

CREATE TABLE dbo.InventoryMovement(
    inventory_movement_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_InventoryMovement PRIMARY KEY,
    ingredient_id BIGINT NOT NULL,
    movement_type VARCHAR(20) NOT NULL,
    on_hand_delta DECIMAL(12,3) NOT NULL,
    locked_delta DECIMAL(12,3) NOT NULL,
    reference_type VARCHAR(20) NOT NULL,
    reference_id BIGINT NULL,
    moved_at DATETIME2(0) NOT NULL,
    CONSTRAINT FK_InventoryMovement_Inventory
        FOREIGN KEY (ingredient_id) REFERENCES dbo.Inventory(ingredient_id)
);

CREATE TABLE dbo.ReplenishmentSuggestion(
    replenishment_suggestion_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_ReplenishmentSuggestion PRIMARY KEY,
    ingredient_id BIGINT NOT NULL,
    current_qty DECIMAL(12,3) NOT NULL,
    suggested_qty DECIMAL(12,3) NOT NULL,
    suggestion_status VARCHAR(20) NOT NULL,
    created_by_employee_id BIGINT NOT NULL,
    submitted_by_employee_id BIGINT NULL,
    approved_by_employee_id BIGINT NULL,
    rejected_by_employee_id BIGINT NULL,
    CONSTRAINT FK_ReplenishmentSuggestion_Ingredient
        FOREIGN KEY (ingredient_id) REFERENCES dbo.Ingredient(ingredient_id),
    CONSTRAINT FK_ReplenishmentSuggestion_CreatedByEmployee
        FOREIGN KEY (created_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id),
    CONSTRAINT FK_ReplenishmentSuggestion_SubmittedByEmployee
        FOREIGN KEY (submitted_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id),
    CONSTRAINT FK_ReplenishmentSuggestion_ApprovedByEmployee
        FOREIGN KEY (approved_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id),
    CONSTRAINT FK_ReplenishmentSuggestion_RejectedByEmployee
        FOREIGN KEY (rejected_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id)
);

CREATE UNIQUE INDEX UQ_ReplenishmentSuggestion_ingredient_id
    ON dbo.ReplenishmentSuggestion(ingredient_id)
    WHERE suggestion_status IN ('PENDING', 'SUBMITTED', 'APPROVED');

CREATE TABLE dbo.PurchaseOrder(
    purchase_order_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_PurchaseOrder PRIMARY KEY,
    purchase_order_no VARCHAR(20) NOT NULL,
    replenishment_suggestion_id BIGINT NOT NULL,
    purchase_status VARCHAR(20) NOT NULL,
    approved_by_employee_id BIGINT NULL,
    approved_at DATETIME2(0) NULL,
    CONSTRAINT UQ_PurchaseOrder_purchase_order_no
        UNIQUE (purchase_order_no),
    CONSTRAINT FK_PurchaseOrder_ReplenishmentSuggestion
        FOREIGN KEY (replenishment_suggestion_id)
        REFERENCES dbo.ReplenishmentSuggestion(replenishment_suggestion_id),
    CONSTRAINT FK_PurchaseOrder_ApprovedByEmployee
        FOREIGN KEY (approved_by_employee_id) REFERENCES dbo.EmployeeAccount(employee_id)
);

CREATE TABLE dbo.PurchaseOrderItem(
    purchase_order_id BIGINT NOT NULL,
    ingredient_id BIGINT NOT NULL,
    ordered_qty DECIMAL(12,3) NOT NULL,
    received_qty DECIMAL(12,3) NOT NULL
        CONSTRAINT DF_PurchaseOrderItem_received_qty DEFAULT (0),
    CONSTRAINT PK_PurchaseOrderItem
        PRIMARY KEY (purchase_order_id, ingredient_id),
    CONSTRAINT FK_PurchaseOrderItem_PurchaseOrder
        FOREIGN KEY (purchase_order_id) REFERENCES dbo.PurchaseOrder(purchase_order_id),
    CONSTRAINT FK_PurchaseOrderItem_Ingredient
        FOREIGN KEY (ingredient_id) REFERENCES dbo.Ingredient(ingredient_id)
);

CREATE TABLE dbo.AuditLog(
    audit_log_id BIGINT IDENTITY(1,1)
        CONSTRAINT PK_AuditLog PRIMARY KEY,
    employee_id BIGINT NOT NULL,
    action_name VARCHAR(50) NOT NULL,
    entity_name VARCHAR(50) NOT NULL,
    entity_id BIGINT NULL,
    detail_json NVARCHAR(MAX) NULL,
    logged_at DATETIME2(0) NOT NULL,
    CONSTRAINT FK_AuditLog_Employee
        FOREIGN KEY (employee_id) REFERENCES dbo.EmployeeAccount(employee_id)
);
GO

-- 批次 3：为 B 的 Delivery 添加可空骑手外键（未分配骑手时 rider_employee_id 可空）
-- 注意：本批次要求 02_order_schema.sql 已创建 dbo.Delivery；缺文件时必须报错停止。
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

ALTER TABLE dbo.Delivery
    ADD CONSTRAINT FK_Delivery_RiderEmployee
        FOREIGN KEY (rider_employee_id) REFERENCES dbo.EmployeeAccount(employee_id);
GO
