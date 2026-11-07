-- ============================================================================
-- 11a_master_migration.sql — A 域 v0.1 -> v1.0 迁移（成员 A；2026-11-01）
-- 由 run_migration.sql 在外层事务内 :r 执行：不得 BEGIN/COMMIT/ROLLBACK 外层事务，
-- 不得切连接；失败由入口回滚外层并 THROW。
-- 落实：
--   ① a-normalization.md §5 第 1–5 项 —— 五个候选码补声明（UQ_*）；
--   ② 计划 §6.2 的 A 域查询/注册接口 —— sp_list_master_records、sp_list_sale_products、
--      sp_find_customer_for_order、sp_register_customer_for_order（应用层只经过程取数，
--      不向岗位开放基表 SELECT）。
--   ③ 契约 §1.2 的顾客端建档 sp_customer_register（§1 于 2026-11-06 冻结，2026-11-07 补入）；
--      它不按 USER_NAME() 认人，只授给 C 的 12_permissions 里的 cust_app。
-- 依据：docs/stage2/a-normalization.md §5、refactoring-design.md §7、
--       migration-guide.md §3（脚本形状与错误码段 533xx）、计划 §6.2 接口表。
-- 不在本文件：契约 §1.3 / §1.4 的顾客下单与查单（B 的 11b）；
--       全部新接口的授权（GRANT）由 C 的 12_permissions 落。
-- ============================================================================
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- ---------------------------------------------------------------------------
-- 1. 前置校验（v0.1 形状 + 重复值；有重复就报出业务键，不静默留一行）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
DECLARE @msg NVARCHAR(400);

IF OBJECT_ID(N'dbo.Category', N'U') IS NULL OR OBJECT_ID(N'dbo.MemberLevel', N'U') IS NULL
   OR OBJECT_ID(N'dbo.Ingredient', N'U') IS NULL OR OBJECT_ID(N'dbo.Product', N'U') IS NULL
    THROW 53300, N'11a: v0.1 A-domain tables are missing.', 1;

-- 11a 只在 v0.1 上跑一次：五个约束都还没有
IF EXISTS (SELECT 1 FROM sys.key_constraints
           WHERE name IN (N'UQ_MemberLevel_threshold_points', N'UQ_Category_category_name',
                          N'UQ_Product_product_name', N'UQ_Ingredient_name_unit',
                          N'UQ_MemberLevel_level_name'))
    THROW 53301, N'11a: candidate-key constraints already exist; 11a must run once on v0.1.', 1;

IF EXISTS (SELECT 1 FROM dbo.Category GROUP BY category_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Category.category_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), category_name), N',')
                              WITHIN GROUP (ORDER BY category_name)
                       FROM (SELECT category_name FROM dbo.Category
                             GROUP BY category_name HAVING COUNT(*) > 1) x), N'');
    THROW 53302, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.Product GROUP BY product_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Product.product_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), product_name), N',')
                              WITHIN GROUP (ORDER BY product_name)
                       FROM (SELECT product_name FROM dbo.Product
                             GROUP BY product_name HAVING COUNT(*) > 1) x), N'');
    THROW 53303, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.Ingredient GROUP BY ingredient_name, unit_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate Ingredient (ingredient_name, unit_name): '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), ingredient_name + N'|' + unit_name), N',')
                              WITHIN GROUP (ORDER BY ingredient_name, unit_name)
                       FROM (SELECT ingredient_name, unit_name FROM dbo.Ingredient
                             GROUP BY ingredient_name, unit_name HAVING COUNT(*) > 1) x), N'');
    THROW 53304, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.MemberLevel GROUP BY threshold_points HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate MemberLevel.threshold_points: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), threshold_points), N',')
                              WITHIN GROUP (ORDER BY threshold_points)
                       FROM (SELECT threshold_points FROM dbo.MemberLevel
                             GROUP BY threshold_points HAVING COUNT(*) > 1) x), N'');
    THROW 53305, @msg, 1;
END;
IF EXISTS (SELECT 1 FROM dbo.MemberLevel GROUP BY level_name HAVING COUNT(*) > 1)
BEGIN
    SET @msg = N'11a: duplicate MemberLevel.level_name: '
             + ISNULL((SELECT STRING_AGG(CONVERT(NVARCHAR(MAX), level_name), N',')
                              WITHIN GROUP (ORDER BY level_name)
                       FROM (SELECT level_name FROM dbo.MemberLevel
                             GROUP BY level_name HAVING COUNT(*) > 1) x), N'');
    THROW 53306, @msg, 1;
END;
GO

-- ---------------------------------------------------------------------------
-- 2. 补五个候选码（a-normalization §5 第 1–5 项）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

ALTER TABLE dbo.MemberLevel
    ADD CONSTRAINT UQ_MemberLevel_threshold_points UNIQUE (threshold_points);

ALTER TABLE dbo.Category
    ADD CONSTRAINT UQ_Category_category_name UNIQUE (category_name);

ALTER TABLE dbo.Product
    ADD CONSTRAINT UQ_Product_product_name UNIQUE (product_name);

ALTER TABLE dbo.Ingredient
    ADD CONSTRAINT UQ_Ingredient_name_unit UNIQUE (ingredient_name, unit_name);

ALTER TABLE dbo.MemberLevel
    ADD CONSTRAINT UQ_MemberLevel_level_name UNIQUE (level_name);
GO

-- ---------------------------------------------------------------------------
-- 3. 迁移内终态校验（只读；失败由入口回滚）
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;

IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_MemberLevel_threshold_points' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.MemberLevel'))
    THROW 53310, N'11a: UQ_MemberLevel_threshold_points was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Category_category_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Category'))
    THROW 53311, N'11a: UQ_Category_category_name was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Product_product_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Product'))
    THROW 53312, N'11a: UQ_Product_product_name was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_Ingredient_name_unit' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.Ingredient'))
    THROW 53313, N'11a: UQ_Ingredient_name_unit was not created.', 1;
IF NOT EXISTS (SELECT 1 FROM sys.key_constraints
               WHERE name = N'UQ_MemberLevel_level_name' AND type = N'UQ'
                 AND parent_object_id = OBJECT_ID(N'dbo.MemberLevel'))
    THROW 53314, N'11a: UQ_MemberLevel_level_name was not created.', 1;

-- 列契约：名字对了但列绑错一样算没落对
IF NOT EXISTS (SELECT 1 FROM sys.index_columns ic
               JOIN sys.key_constraints kc ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
               JOIN sys.columns c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
               WHERE kc.name = N'UQ_Ingredient_name_unit'
                 AND c.name IN (N'ingredient_name', N'unit_name'))
    THROW 53315, N'11a: UQ_Ingredient_name_unit does not cover both columns.', 1;
IF (SELECT COUNT(*) FROM sys.index_columns ic
    JOIN sys.key_constraints kc ON kc.parent_object_id = ic.object_id AND kc.unique_index_id = ic.index_id
    WHERE kc.name = N'UQ_Ingredient_name_unit') <> 2
    THROW 53316, N'11a: UQ_Ingredient_name_unit must have exactly two key columns.', 1;
GO

-- ---------------------------------------------------------------------------
-- 4. A 域查询/注册接口（计划 §6.2）
--    岗位守卫按 USER_NAME() 解析启用员工并要求牌面岗位；GRANT 由 12_permissions 落，
--    两层都在——授权漏了过程层仍拒绝，过程层漏了授权层仍 229。
--    结果集固定列、稳定键排序、不 SELECT *；无结果返回空集合，权限/身份问题必须抛错。
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- 4.1 店长维护主数据：九个实体码返回各自的固定列
CREATE PROCEDURE dbo.sp_list_master_records
    @entity_code VARCHAR(30),
    @status      VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE'
      AND ea.job_code = 'STORE_MANAGER';

    IF @employee_id IS NULL
        THROW 51004, N'sp_list_master_records：当前登录主体不是启用店长，拒绝执行。', 1;

    SET @entity_code = UPPER(LTRIM(RTRIM(ISNULL(@entity_code, N''))));

    IF @entity_code NOT IN (N'CATEGORY', N'PRODUCT', N'INGREDIENT', N'MEMBER_LEVEL',
                            N'CUSTOMER', N'PRODUCT_BOM', N'COMBO', N'PROMOTION',
                            N'PROMOTION_RULE')
        THROW 51000, N'sp_list_master_records：@entity_code 不在白名单内（CATEGORY / PRODUCT / INGREDIENT / MEMBER_LEVEL / CUSTOMER / PRODUCT_BOM / COMBO / PROMOTION / PROMOTION_RULE）。', 1;

    IF @status IS NOT NULL AND @status NOT IN ('ACTIVE', 'INACTIVE')
        THROW 51000, N'sp_list_master_records：@status 只能是 ACTIVE、INACTIVE 或 NULL。', 1;

    IF @status IS NOT NULL AND @entity_code IN (N'PRODUCT_BOM', N'COMBO', N'PROMOTION_RULE')
        THROW 51000, N'sp_list_master_records：该实体没有状态列，@status 必须为 NULL。', 1;

    IF @entity_code = N'CATEGORY'
        SELECT c.category_id, c.category_name, c.[status]
        FROM dbo.Category AS c
        WHERE @status IS NULL OR c.[status] = @status
        ORDER BY c.category_id;
    ELSE IF @entity_code = N'PRODUCT'
        SELECT p.product_id, p.product_name, p.base_price, p.product_type, p.[status]
        FROM dbo.Product AS p
        WHERE @status IS NULL OR p.[status] = @status
        ORDER BY p.product_id;
    ELSE IF @entity_code = N'INGREDIENT'
        SELECT i.ingredient_id, i.ingredient_name, i.unit_name, i.safety_stock_qty, i.[status]
        FROM dbo.Ingredient AS i
        WHERE @status IS NULL OR i.[status] = @status
        ORDER BY i.ingredient_id;
    ELSE IF @entity_code = N'MEMBER_LEVEL'
        SELECT ml.member_level_id, ml.level_name, ml.point_multiplier, ml.threshold_points, ml.[status]
        FROM dbo.MemberLevel AS ml
        WHERE @status IS NULL OR ml.[status] = @status
        ORDER BY ml.member_level_id;
    ELSE IF @entity_code = N'CUSTOMER'
        SELECT c.customer_id, c.mobile, c.customer_type, c.member_level_id, ml.level_name,
               c.current_points, c.[status]
        FROM dbo.Customer AS c
        LEFT JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
        WHERE @status IS NULL OR c.[status] = @status
        ORDER BY c.customer_id;
    ELSE IF @entity_code = N'PRODUCT_BOM'
        SELECT b.product_id, p.product_name, b.ingredient_id, i.ingredient_name, b.usage_qty
        FROM dbo.ProductBom AS b
        JOIN dbo.Product AS p ON p.product_id = b.product_id
        JOIN dbo.Ingredient AS i ON i.ingredient_id = b.ingredient_id
        ORDER BY b.product_id, b.ingredient_id;
    ELSE IF @entity_code = N'COMBO'
        SELECT cc.combo_product_id, cp.product_name AS combo_product_name,
               cc.child_product_id, ch.product_name AS child_product_name, cc.quantity
        FROM dbo.ComboComponent AS cc
        JOIN dbo.Product AS cp ON cp.product_id = cc.combo_product_id
        JOIN dbo.Product AS ch ON ch.product_id = cc.child_product_id
        ORDER BY cc.combo_product_id, cc.child_product_id;
    ELSE IF @entity_code = N'PROMOTION'
        SELECT pr.promotion_id, pr.promotion_name, pr.promotion_type,
               pr.start_at, pr.end_at, pr.[status]
        FROM dbo.Promotion AS pr
        WHERE @status IS NULL OR pr.[status] = @status
        ORDER BY pr.promotion_id;
    ELSE -- PROMOTION_RULE
        SELECT r.promotion_rule_id, r.promotion_id, pr.promotion_name,
               r.product_id, p.product_name, r.weekday_no,
               r.start_time, r.end_time, r.promo_price, r.[priority]
        FROM dbo.PromotionProductRule AS r
        JOIN dbo.Promotion AS pr ON pr.promotion_id = r.promotion_id
        JOIN dbo.Product AS p ON p.product_id = r.product_id
        ORDER BY r.promotion_id, r.[priority] DESC, r.promotion_rule_id;
END
GO

-- 4.2 收银选商品：启用商品 + 当前展示价（与定价函数同源，快照以下单过程为准）
CREATE PROCEDURE dbo.sp_list_sale_products
    @take INT = 100
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE'
      AND ea.job_code = 'CASHIER';

    IF @employee_id IS NULL
        THROW 51004, N'sp_list_sale_products：当前登录主体不是启用收银员，拒绝执行。', 1;

    IF @take IS NULL OR @take < 1 OR @take > 200
        THROW 51000, N'sp_list_sale_products：@take 必须在 1 到 200 之间。', 1;

    SELECT TOP (@take)
           p.product_id, p.product_name, price.effective_price, price.promotion_id
    FROM dbo.Product AS p
    CROSS APPLY dbo.fn_get_effective_product_price(p.product_id, SYSDATETIME()) AS price
    WHERE p.[status] = 'ACTIVE'
    ORDER BY p.product_id;
END
GO

-- 4.3 收银检索顾客：精确手机号、只回启用顾客；无结果返回空集合，不是错误
CREATE PROCEDURE dbo.sp_find_customer_for_order
    @mobile VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE'
      AND ea.job_code = 'CASHIER';

    IF @employee_id IS NULL
        THROW 51004, N'sp_find_customer_for_order：当前登录主体不是启用收银员，拒绝执行。', 1;

    IF @mobile IS NULL OR LTRIM(RTRIM(@mobile)) = N''
        THROW 51000, N'sp_find_customer_for_order：@mobile 不能为空。', 1;

    SELECT TOP (1)
           c.customer_id, c.mobile, c.customer_type, c.member_level_id, ml.level_name
    FROM dbo.Customer AS c
    LEFT JOIN dbo.MemberLevel AS ml ON ml.member_level_id = c.member_level_id
    WHERE c.mobile = LTRIM(RTRIM(@mobile))
      AND c.[status] = 'ACTIVE'
    ORDER BY c.customer_id;
END
GO

-- 4.4 收银建档：固定 GUEST、复用店长建档的默认等级规则与重复码（51005）
CREATE PROCEDURE dbo.sp_register_customer_for_order
    @mobile VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @employee_id BIGINT;

    SELECT @employee_id = ea.employee_id
    FROM dbo.EmployeeAccount AS ea
    WHERE ea.database_user_name = USER_NAME()
      AND ea.status = 'ACTIVE'
      AND ea.job_code = 'CASHIER';

    IF @employee_id IS NULL
        THROW 51004, N'sp_register_customer_for_order：当前登录主体不是启用收银员，拒绝执行。', 1;

    IF @mobile IS NULL
       OR LTRIM(RTRIM(@mobile)) NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        THROW 51000, N'sp_register_customer_for_order：@mobile 必须是 11 位数字。', 1;

    -- 默认等级判据、重复手机号 51005、事务边界都在店长建档过程里，一处实现不复制
    EXEC dbo.sp_create_customer @mobile = @mobile, @customer_type = 'GUEST';
END
GO

-- ---------------------------------------------------------------------------
-- 5. 顾客端建档（契约 §1.2；§1 于 2026-11-06 冻结）
--    顾客端没有员工身份：本过程不读 USER_NAME()，权限只在 12_permissions：
--    三个顾客过程齐了才把 EXECUTE 授给 cust_app；员工角色不得持有本过程。
-- ---------------------------------------------------------------------------
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE PROCEDURE dbo.sp_customer_register
    @mobile VARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;

    -- 参数是 VARCHAR(20)，绑定时超长值会被无声截断；20 位截断串再往下走就是给错人建档，
    -- 所以位数必须在这里挡（与 sp_register_customer_for_order 同一判据）。
    IF @mobile IS NULL
       OR LTRIM(RTRIM(@mobile)) NOT LIKE '[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]'
        THROW 53000, N'sp_customer_register：@mobile 必须是 11 位数字。', 1;

    SET @mobile = LTRIM(RTRIM(@mobile));

    DECLARE @entry_trancount INT = @@TRANCOUNT;

    IF @entry_trancount = 0
        BEGIN TRANSACTION;
    ELSE
        SAVE TRANSACTION C_customer_register;

    BEGIN TRY
        DECLARE @customer_id BIGINT;
        DECLARE @member_level_id BIGINT;
        DECLARE @is_new BIT = 0;

        -- 幂等：键范围锁把同一手机号的并发建档串起来，后到的那笔读到已提交的行
        SELECT @customer_id = c.customer_id
        FROM dbo.Customer AS c WITH (UPDLOCK, HOLDLOCK)
        WHERE c.mobile = @mobile;

        IF @customer_id IS NULL
        BEGIN
            -- 默认等级判据与 sp_create_customer 逐字相同：没有基准档是配置缺陷，让建档失败
            SET @member_level_id = (
                SELECT TOP (1) ml.member_level_id
                FROM dbo.MemberLevel AS ml
                WHERE ml.[status] = 'ACTIVE'
                  AND ml.threshold_points <= 0
                ORDER BY ml.threshold_points DESC, ml.member_level_id ASC
            );

            IF @member_level_id IS NULL
                THROW 51001, N'sp_customer_register：找不到可用的默认会员等级（threshold_points <= 0 的 ACTIVE 等级），拒绝建档。', 1;

            INSERT INTO dbo.Customer (mobile, customer_type, member_level_id, current_points, [status])
            VALUES (@mobile, 'GUEST', @member_level_id, 0, 'ACTIVE');

            SET @customer_id = SCOPE_IDENTITY();
            SET @is_new = 1;
        END
        ELSE
        BEGIN
            -- 已建档一律不覆盖：类型、等级、积分、状态都留给员工侧过程，这里只回读
            SELECT @member_level_id = c.member_level_id
            FROM dbo.Customer AS c
            WHERE c.customer_id = @customer_id;
        END

        IF @entry_trancount = 0
            COMMIT TRANSACTION;

        SELECT @customer_id    AS customer_id,
               @member_level_id AS member_level_id,
               @is_new         AS is_new;
    END TRY
    BEGIN CATCH
        IF @entry_trancount = 0 AND XACT_STATE() <> 0
            ROLLBACK TRANSACTION;
        ELSE IF @entry_trancount > 0 AND XACT_STATE() = 1
            ROLLBACK TRANSACTION C_customer_register;
        THROW;
    END CATCH;
END
GO
