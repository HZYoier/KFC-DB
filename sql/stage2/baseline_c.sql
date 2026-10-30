-- ============================================================================
-- baseline_c.sql — C 域基线采集（库存/权限/审计 10 表）
-- 负责人：C；2026-10-30 建立。协议见 docs/stage2/migration-guide.md §2.5/§3。
-- 由 capture_baseline.sql 在采集事务内 :r 执行；不得含 GO、不得开/提交事务、
-- 不得用临时表；@batch_id 由入口声明。仅创建/写入 dbo.Baseline_<Table> 快照表。
-- ============================================================================


IF OBJECT_ID(N'dbo.Baseline_Inventory', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_Inventory (
        batch_id BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [on_hand_qty] DECIMAL(12,3) NOT NULL,
        [locked_qty] DECIMAL(12,3) NOT NULL,
        [updated_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_Inventory PRIMARY KEY (batch_id, [ingredient_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_InventoryMovement', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_InventoryMovement (
        batch_id BIGINT NOT NULL,
        [inventory_movement_id] BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [movement_type] VARCHAR(20) NOT NULL,
        [on_hand_delta] DECIMAL(12,3) NOT NULL,
        [locked_delta] DECIMAL(12,3) NOT NULL,
        [reference_type] VARCHAR(20) NOT NULL,
        [reference_id] BIGINT NULL,
        [moved_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_InventoryMovement PRIMARY KEY (batch_id, [inventory_movement_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_ReplenishmentSuggestion', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_ReplenishmentSuggestion (
        batch_id BIGINT NOT NULL,
        [replenishment_suggestion_id] BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [current_qty] DECIMAL(12,3) NOT NULL,
        [suggested_qty] DECIMAL(12,3) NOT NULL,
        [suggestion_status] VARCHAR(20) NOT NULL,
        [created_by_employee_id] BIGINT NOT NULL,
        [submitted_by_employee_id] BIGINT NULL,
        [approved_by_employee_id] BIGINT NULL,
        [rejected_by_employee_id] BIGINT NULL,
        CONSTRAINT PK_Baseline_ReplenishmentSuggestion PRIMARY KEY (batch_id, [replenishment_suggestion_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_PurchaseOrder', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_PurchaseOrder (
        batch_id BIGINT NOT NULL,
        [purchase_order_id] BIGINT NOT NULL,
        [purchase_order_no] VARCHAR(20) NOT NULL,
        [replenishment_suggestion_id] BIGINT NOT NULL,
        [purchase_status] VARCHAR(20) NOT NULL,
        [approved_by_employee_id] BIGINT NULL,
        [approved_at] DATETIME2(0) NULL,
        CONSTRAINT PK_Baseline_PurchaseOrder PRIMARY KEY (batch_id, [purchase_order_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_PurchaseOrderItem', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_PurchaseOrderItem (
        batch_id BIGINT NOT NULL,
        [purchase_order_id] BIGINT NOT NULL,
        [ingredient_id] BIGINT NOT NULL,
        [ordered_qty] DECIMAL(12,3) NOT NULL,
        [received_qty] DECIMAL(12,3) NOT NULL,
        CONSTRAINT PK_Baseline_PurchaseOrderItem PRIMARY KEY (batch_id, [purchase_order_id], [ingredient_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_EmployeeAccount', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_EmployeeAccount (
        batch_id BIGINT NOT NULL,
        [employee_id] BIGINT NOT NULL,
        [database_user_name] VARCHAR(128) NOT NULL,
        [login_name] VARCHAR(128) NOT NULL,
        [employee_name] NVARCHAR(50) NOT NULL,
        [job_code] VARCHAR(20) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_EmployeeAccount PRIMARY KEY (batch_id, [employee_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_BusinessRole', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_BusinessRole (
        batch_id BIGINT NOT NULL,
        [business_role_id] BIGINT NOT NULL,
        [role_code] VARCHAR(20) NOT NULL,
        [role_name] NVARCHAR(50) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_BusinessRole PRIMARY KEY (batch_id, [business_role_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_EmployeeBusinessRole', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_EmployeeBusinessRole (
        batch_id BIGINT NOT NULL,
        [employee_id] BIGINT NOT NULL,
        [business_role_id] BIGINT NOT NULL,
        [assigned_by_employee_id] BIGINT NOT NULL,
        [assigned_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_EmployeeBusinessRole PRIMARY KEY (batch_id, [employee_id], [business_role_id])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_RolePermission', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_RolePermission (
        batch_id BIGINT NOT NULL,
        [business_role_id] BIGINT NOT NULL,
        [permission_code] VARCHAR(50) NOT NULL,
        [permission_name] NVARCHAR(100) NOT NULL,
        [status] VARCHAR(20) NOT NULL,
        CONSTRAINT PK_Baseline_RolePermission PRIMARY KEY (batch_id, [business_role_id], [permission_code])
    );
END;

IF OBJECT_ID(N'dbo.Baseline_AuditLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.Baseline_AuditLog (
        batch_id BIGINT NOT NULL,
        [audit_log_id] BIGINT NOT NULL,
        [employee_id] BIGINT NOT NULL,
        [action_name] VARCHAR(50) NOT NULL,
        [entity_name] VARCHAR(50) NOT NULL,
        [entity_id] BIGINT NULL,
        [detail_json] NVARCHAR(MAX) NULL,
        [logged_at] DATETIME2(0) NOT NULL,
        CONSTRAINT PK_Baseline_AuditLog PRIMARY KEY (batch_id, [audit_log_id])
    );
END;

INSERT INTO dbo.Baseline_Inventory (batch_id, [ingredient_id], [on_hand_qty], [locked_qty], [updated_at])
SELECT @batch_id, [ingredient_id], [on_hand_qty], [locked_qty], [updated_at] FROM dbo.Inventory;

INSERT INTO dbo.Baseline_InventoryMovement (batch_id, [inventory_movement_id], [ingredient_id], [movement_type], [on_hand_delta], [locked_delta], [reference_type], [reference_id], [moved_at])
SELECT @batch_id, [inventory_movement_id], [ingredient_id], [movement_type], [on_hand_delta], [locked_delta], [reference_type], [reference_id], [moved_at] FROM dbo.InventoryMovement;

INSERT INTO dbo.Baseline_ReplenishmentSuggestion (batch_id, [replenishment_suggestion_id], [ingredient_id], [current_qty], [suggested_qty], [suggestion_status], [created_by_employee_id], [submitted_by_employee_id], [approved_by_employee_id], [rejected_by_employee_id])
SELECT @batch_id, [replenishment_suggestion_id], [ingredient_id], [current_qty], [suggested_qty], [suggestion_status], [created_by_employee_id], [submitted_by_employee_id], [approved_by_employee_id], [rejected_by_employee_id] FROM dbo.ReplenishmentSuggestion;

INSERT INTO dbo.Baseline_PurchaseOrder (batch_id, [purchase_order_id], [purchase_order_no], [replenishment_suggestion_id], [purchase_status], [approved_by_employee_id], [approved_at])
SELECT @batch_id, [purchase_order_id], [purchase_order_no], [replenishment_suggestion_id], [purchase_status], [approved_by_employee_id], [approved_at] FROM dbo.PurchaseOrder;

INSERT INTO dbo.Baseline_PurchaseOrderItem (batch_id, [purchase_order_id], [ingredient_id], [ordered_qty], [received_qty])
SELECT @batch_id, [purchase_order_id], [ingredient_id], [ordered_qty], [received_qty] FROM dbo.PurchaseOrderItem;

INSERT INTO dbo.Baseline_EmployeeAccount (batch_id, [employee_id], [database_user_name], [login_name], [employee_name], [job_code], [status])
SELECT @batch_id, [employee_id], [database_user_name], [login_name], [employee_name], [job_code], [status] FROM dbo.EmployeeAccount;

INSERT INTO dbo.Baseline_BusinessRole (batch_id, [business_role_id], [role_code], [role_name], [status])
SELECT @batch_id, [business_role_id], [role_code], [role_name], [status] FROM dbo.BusinessRole;

INSERT INTO dbo.Baseline_EmployeeBusinessRole (batch_id, [employee_id], [business_role_id], [assigned_by_employee_id], [assigned_at])
SELECT @batch_id, [employee_id], [business_role_id], [assigned_by_employee_id], [assigned_at] FROM dbo.EmployeeBusinessRole;

INSERT INTO dbo.Baseline_RolePermission (batch_id, [business_role_id], [permission_code], [permission_name], [status])
SELECT @batch_id, [business_role_id], [permission_code], [permission_name], [status] FROM dbo.RolePermission;

INSERT INTO dbo.Baseline_AuditLog (batch_id, [audit_log_id], [employee_id], [action_name], [entity_name], [entity_id], [detail_json], [logged_at])
SELECT @batch_id, [audit_log_id], [employee_id], [action_name], [entity_name], [entity_id], [detail_json], [logged_at] FROM dbo.AuditLog;

