-- ============================================================================
-- 08_roles_permissions.sql
-- 负责人：C（库存、补货、员工权限、审计与总集成）
-- 用途：建立 7 个业务数据库角色与 7 个不带登录的测试用户；按授权矩阵逐对象
--       GRANT EXECUTE / GRANT SELECT（不授予任何表级 DML）；对三个敏感字段
--       DENY UPDATE；为三个角色同步过程建立证书签名，使 ALTER ANY ROLE /
--       ALTER ANY USER 只在模块内部生效。
-- 依赖：01/02/03（表）、04（A 域 18 个主数据过程）、05（B 域 8 个订单过程）、
--       06（C 域过程，含 sp_write_audit_log 与 sp_receive_inventory）、
--       07a/07b/07c（10 个视图）。因此本文件必须排在三域过程与视图之后。
-- 依据：docs/stage1-three-person-implementation-plan.md §5 C-1 line 303、§5 C-2 line 313-315；
--       docs/库存权限数据字典.md §11；docs/stage1-cross-domain-interface-contract.md。
-- 进度：完整交付（角色、测试用户、启动引导、授权矩阵、DENY、证书与三个签名）。
-- 说明：角色同步过程不得使用 EXECUTE AS OWNER（否则 USER_NAME() 会指向 dbo），
--       故改用证书签名把 ALTER ANY ROLE / ALTER ANY USER 抬进模块内部：店长本人
--       不拥有这两个权限，只拥有三个过程的 EXECUTE。
--       DMK 口令仅用于首次建立数据库主密钥以保护证书私钥，生产环境应由 DBA 预先
--       建好 DMK 并跳过该批次（run_all.sql 要求自包含，故此处给出可用的建钥语句）。
--       证书签名依赖过程体，改动 06 中的三个角色同步过程后必须重跑本文件末批。
-- ============================================================================

USE KFC_DB;
GO

-- 批次 1：业务角色、测试用户与受控启动引导
SET ANSI_NULLS ON;
SET ANSI_PADDING ON;
SET ANSI_WARNINGS ON;
SET ARITHABORT ON;
SET CONCAT_NULL_YIELDS_NULL ON;
SET QUOTED_IDENTIFIER ON;
SET NUMERIC_ROUNDABORT OFF;

IF DATABASE_PRINCIPAL_ID(N'role_store_manager') IS NULL CREATE ROLE role_store_manager;
GO
IF DATABASE_PRINCIPAL_ID(N'role_shift_manager') IS NULL CREATE ROLE role_shift_manager;
GO
IF DATABASE_PRINCIPAL_ID(N'role_cashier') IS NULL CREATE ROLE role_cashier;
GO
IF DATABASE_PRINCIPAL_ID(N'role_chef') IS NULL CREATE ROLE role_chef;
GO
IF DATABASE_PRINCIPAL_ID(N'role_packer') IS NULL CREATE ROLE role_packer;
GO
IF DATABASE_PRINCIPAL_ID(N'role_waiter') IS NULL CREATE ROLE role_waiter;
GO
IF DATABASE_PRINCIPAL_ID(N'role_rider') IS NULL CREATE ROLE role_rider;
GO

-- 测试用户一律不带登录，只用于验收脚本以 EXECUTE AS USER 切换主体
IF DATABASE_PRINCIPAL_ID(N'test_store_manager') IS NULL CREATE USER test_store_manager WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_shift_manager') IS NULL CREATE USER test_shift_manager WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_cashier') IS NULL CREATE USER test_cashier WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_chef') IS NULL CREATE USER test_chef WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_packer') IS NULL CREATE USER test_packer WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_waiter') IS NULL CREATE USER test_waiter WITHOUT LOGIN;
GO
IF DATABASE_PRINCIPAL_ID(N'test_rider') IS NULL CREATE USER test_rider WITHOUT LOGIN;
GO

-- 受控启动引导：首个店长必须先成为 role_store_manager 成员，才能调用
-- sp_assign_employee_business_role 为其余员工建立成员关系；其余测试用户此时
-- 不加入任何业务角色，交由 09c 的 seed 经角色同步过程分配。
IF NOT EXISTS (SELECT 1
               FROM sys.database_role_members AS drm
               JOIN sys.database_principals AS r ON r.principal_id = drm.role_principal_id
               JOIN sys.database_principals AS m ON m.principal_id = drm.member_principal_id
               WHERE r.name = N'role_store_manager' AND m.name = N'test_store_manager')
    ALTER ROLE role_store_manager ADD MEMBER test_store_manager;
GO

-- 批次 2：授权矩阵——role_store_manager（A 域主数据过程）
GRANT EXECUTE ON dbo.sp_add_promotion_product_rule     TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_category                TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_customer                TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_ingredient              TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_member_level            TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_product                 TO role_store_manager;
GRANT EXECUTE ON dbo.sp_create_promotion               TO role_store_manager;
GRANT EXECUTE ON dbo.sp_set_combo_component            TO role_store_manager;
GRANT EXECUTE ON dbo.sp_set_product_bom                TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_category_status         TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_customer_member_level   TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_ingredient              TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_member_level            TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_member_level_status     TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_product_price           TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_product_status          TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_promotion_product_rule  TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_promotion_status        TO role_store_manager;
-- 批次 2：role_store_manager——C 域库存调整、补货审批与角色同步过程
GRANT EXECUTE ON dbo.sp_adjust_inventory                    TO role_store_manager;
GRANT EXECUTE ON dbo.sp_approve_replenishment_suggestion    TO role_store_manager;
GRANT EXECUTE ON dbo.sp_reject_replenishment_suggestion     TO role_store_manager;
GRANT EXECUTE ON dbo.sp_assign_employee_business_role       TO role_store_manager;
GRANT EXECUTE ON dbo.sp_revoke_employee_business_role       TO role_store_manager;
GRANT EXECUTE ON dbo.sp_update_employee_status              TO role_store_manager;
-- 批次 2：role_store_manager——订单取消/退款（B 域过程，由 C 侧授权）
GRANT EXECUTE ON dbo.sp_cancel_or_refund_order          TO role_store_manager;
-- 批次 2：role_store_manager——全部视图
GRANT SELECT ON dbo.v_active_product_price      TO role_store_manager;
GRANT SELECT ON dbo.v_customer_point_ledger     TO role_store_manager;
GRANT SELECT ON dbo.v_inventory_available       TO role_store_manager;
GRANT SELECT ON dbo.v_inventory_movement_history TO role_store_manager;
GRANT SELECT ON dbo.v_kitchen_queue             TO role_store_manager;
GRANT SELECT ON dbo.v_order_detail              TO role_store_manager;
GRANT SELECT ON dbo.v_order_inventory_trace     TO role_store_manager;
GRANT SELECT ON dbo.v_pickup_board              TO role_store_manager;
GRANT SELECT ON dbo.v_product_bom_detail        TO role_store_manager;
GRANT SELECT ON dbo.v_replenishment_dashboard   TO role_store_manager;
GO

-- 批次 3：授权矩阵——role_shift_manager（补货创建/调整/提交与采购收货 + 库存/补货视图）
GRANT EXECUTE ON dbo.sp_create_replenishment_suggestion TO role_shift_manager;
GRANT EXECUTE ON dbo.sp_update_replenishment_suggestion TO role_shift_manager;
GRANT EXECUTE ON dbo.sp_submit_replenishment_suggestion TO role_shift_manager;
GRANT EXECUTE ON dbo.sp_receive_inventory               TO role_shift_manager;
GRANT SELECT ON dbo.v_inventory_available        TO role_shift_manager;
GRANT SELECT ON dbo.v_inventory_movement_history TO role_shift_manager;
GRANT SELECT ON dbo.v_order_inventory_trace      TO role_shift_manager;
GRANT SELECT ON dbo.v_replenishment_dashboard    TO role_shift_manager;
GO

-- 批次 4：授权矩阵——其余岗位角色（收银、后厨、打包、骑手、传菜）
GRANT EXECUTE ON dbo.sp_create_order TO role_cashier;
GRANT EXECUTE ON dbo.sp_pay_order    TO role_cashier;
GO
GRANT EXECUTE ON dbo.sp_start_production TO role_chef;
GRANT SELECT ON dbo.v_kitchen_queue      TO role_chef;
GO
GRANT EXECUTE ON dbo.sp_finish_production TO role_packer;
GRANT EXECUTE ON dbo.sp_pick_up_order     TO role_packer;
GO
GRANT EXECUTE ON dbo.sp_pick_up_delivery TO role_rider;
GRANT EXECUTE ON dbo.sp_confirm_delivery TO role_rider;
GO
GRANT SELECT ON dbo.v_pickup_board TO role_waiter;
GO

-- 批次 5：敏感字段禁止直接 UPDATE——只能经过程修改
DENY UPDATE ON dbo.Inventory TO role_store_manager, role_shift_manager, role_cashier, role_chef, role_packer, role_waiter, role_rider;
DENY UPDATE ON dbo.SalesOrderItem (unit_price) TO role_store_manager, role_shift_manager, role_cashier, role_chef, role_packer, role_waiter, role_rider;
DENY UPDATE ON dbo.Customer (current_points) TO role_store_manager, role_shift_manager, role_cashier, role_chef, role_packer, role_waiter, role_rider;
GO

-- 批次 6：数据库主密钥（仅用于保护证书私钥，不用于其他任何用途）
IF NOT EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = N'##MS_DatabaseMasterKey##')
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = N'KfcDb#Stage1#RoleSync#Dmk';
GO
-- 追加服务主密钥加密后，证书私钥可被服务直接打开，签名语句无需再传口令
IF NOT EXISTS (SELECT 1
               FROM sys.key_encryptions AS ke
               JOIN sys.symmetric_keys AS sk ON sk.symmetric_key_id = ke.key_id
               WHERE sk.name = N'##MS_DatabaseMasterKey##'
                 AND ke.crypt_type = 'ESKM')
    ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY;
GO

-- 批次 7：角色同步专用证书与证书用户
IF CERT_ID(N'cert_role_sync') IS NULL
    CREATE CERTIFICATE cert_role_sync WITH SUBJECT = N'C 域员工业务角色同步过程专用签名证书';
GO
IF DATABASE_PRINCIPAL_ID(N'cert_role_sync_user') IS NULL
    CREATE USER cert_role_sync_user FROM CERTIFICATE cert_role_sync;
GO
GRANT ALTER ANY ROLE TO cert_role_sync_user;
GRANT ALTER ANY USER TO cert_role_sync_user;
GO

-- 批次 8：为三个角色同步过程添加证书签名
-- 已签名的对象跳过（ADD SIGNATURE 重复执行会报 15557）；重跑本文件时仍是幂等的，
-- 而 06 里过程被重建后签名会随对象版本失效，此处的守卫为假、会重新签名。
-- 证书指纹取自 sys.certificates：CERTPROPERTY 不支持 'Thumbprint' 属性（实测返回 NULL）。
DECLARE @cert_thumbprint VARBINARY(32) =
    (SELECT c.thumbprint FROM sys.certificates AS c WHERE c.name = N'cert_role_sync');

IF NOT EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
               WHERE cp.class = 1
                 AND cp.thumbprint = @cert_thumbprint
                 AND cp.major_id = OBJECT_ID(N'dbo.sp_assign_employee_business_role'))
    ADD SIGNATURE TO dbo.sp_assign_employee_business_role BY CERTIFICATE cert_role_sync;

IF NOT EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
               WHERE cp.class = 1
                 AND cp.thumbprint = @cert_thumbprint
                 AND cp.major_id = OBJECT_ID(N'dbo.sp_revoke_employee_business_role'))
    ADD SIGNATURE TO dbo.sp_revoke_employee_business_role BY CERTIFICATE cert_role_sync;

IF NOT EXISTS (SELECT 1 FROM sys.crypt_properties AS cp
               WHERE cp.class = 1
                 AND cp.thumbprint = @cert_thumbprint
                 AND cp.major_id = OBJECT_ID(N'dbo.sp_update_employee_status'))
    ADD SIGNATURE TO dbo.sp_update_employee_status BY CERTIFICATE cert_role_sync;
GO
