# 第一阶段三人协作实施计划

**Goal:** 在 SQL Server 上交付一个能覆盖门店核心经营闭环的关系数据库：可建库、可完成规定 CRUD、可查询和查看视图、具有必要的数据约束，并按岗位实施最小权限。

**Architecture:** 数据库统一使用 `dbo` 架构，以“主数据与定价 → 订单履约与积分 → 库存补货与权限”三条业务线拆分。所有跨域写操作只能经由存储过程；订单域保存成交价和促销命中快照，库存域在同一事务内执行锁定、释放或实扣，避免各成员直接修改对方的表。

**Tech Stack:** SQL Server、T-SQL、Git、Markdown。客户端不限：VS Code + mssql 扩展或 SSMS 22 均可，但不影响第 1 节规定的 `sqlcmd` 部署方式。

**Spec:** [业务流程](业务流程.md)、[数据边界清单](数据边界清单.md)、[角色与职能清单](角色与职能清单.md)。`AI使用记录.md` 是历史说明，不作为新增功能的需求来源。

<a id="sec-global"></a>

## 全局约束

- 数据库名固定为 `KFC_DB`，所有对象使用 `dbo` 架构。
- 使用 `BIGINT IDENTITY(1,1)` 作为业务表的代理主键；业务编号另设唯一键，例如 `order_no`。
- 金额统一为 `DECIMAL(10,2)`；原料用量、库存量和建议量统一为 `DECIMAL(12,3)`；时间统一为 `DATETIME2(0)`。
- 目标 SQL Server 数据库兼容级别必须不低于 `130`，因为订单输入使用 `OPENJSON`；`00_create_database.sql` 必须在建库后显式检查兼容级别并在不足时 `THROW`。
- 状态值使用 `VARCHAR(20)` 加 `CHECK` 约束；不得只在注释或应用层约束状态。
- 历史订单明细中的 `unit_price`、`promotion_id` 必须是成交时快照；不得通过当前商品价或当前促销规则反算历史订单金额。
- `on_hand_qty`（现有量）和 `locked_qty`（锁定量）均不得小于零；可售量只能在视图中以 `on_hand_qty - locked_qty` 计算，不另建冗余字段。
- 不在数据库保存购物车、KVS 队列、GPS 轨迹、支付完整报文、密码明文、UI/小票文案。
- 禁止在他人负责的表上直接 `INSERT`、`UPDATE`、`DELETE`。跨域业务必须调用本计划规定的存储过程。
- 所有脚本的每个批次必须在 `CREATE`、`ALTER`、`DML` 之前显式设置 `SET ANSI_NULLS ON`、`SET ANSI_PADDING ON`、`SET ANSI_WARNINGS ON`、`SET ARITHABORT ON`、`SET CONCAT_NULL_YIELDS_NULL ON`、`SET QUOTED_IDENTIFIER ON`、`SET NUMERIC_ROUNDABORT OFF`，并用 `GO` 把该批次与后续语句分隔。`sqlcmd`（ODBC Driver 18）默认 `QUOTED_IDENTIFIER` 为 `OFF`，不设置会在建过滤索引时报错 1934，且任何读写带过滤索引的表的语句都会失败。`ProductCategory.is_primary`（A）与 `SalesOrder.pickup_code`（B）都是过滤唯一索引，A、B 的建表与过程脚本同样受约束。`CREATE PROCEDURE` 会在创建时固化 `ANSI_NULLS` 与 `QUOTED_IDENTIFIER`，用 `OFF` 建出的过程要到运行时才报错，因此过程脚本的每个批次也必须先设置这些选项。
- 建表脚本不得使用无条件 `DROP DATABASE`、`DROP TABLE` 或 `DELETE`；对象已存在时应明确报错并停止，避免覆盖已验收数据。
- 每条查询必须写明用途，不使用 `SELECT *`；每个视图的列名必须显式列出。
- 第一阶段套餐只支持一层：套餐父项必须是 `COMBO`，子项必须是已启用的 `SINGLE` 商品；禁止套餐嵌套和自引用。退款只支持在实扣前的全额退款，不支持部分退款。
- 所有面向业务角色的写过程必须从 `EmployeeAccount.database_user_name = USER_NAME()` 解析当前员工，验证其为 `ACTIVE`；若过程保留传入的员工参数（`@employee_id`、`@operator_employee_id`、`@*_by_employee_id`），该参数必须等于解析结果，否则 `THROW`。审计只能使用该解析出的员工 ID，禁止信任客户端伪造的主体名称或 ID。因此，任何调用这些过程的种子或验收脚本都必须先 `EXECUTE AS USER = '<test_主体>'` 再调用、随后 `REVERT`；以 sysadmin 或 `dbo` 身份直接调用会被过程拒绝。

---

## 1. 目录、脚本顺序与公共命名

创建下列目录和文件；三人只能修改自己标注“负责人”的文件。不存在多人直接编辑的公共 SQL 文件；跨域接口变更须三人审核后才可合并。

```text
sql/
  run_all.sql                          # C：唯一入口，SQLCMD :r 顺序执行全部脚本
  00_create_database.sql                  # C：建库、兼容级别检查与 USE KFC_DB（CREATE DATABASE 与 USE 之间须用 GO 分隔）
  01_master_schema.sql                    # A
  02_order_schema.sql                     # B
  03_inventory_security_schema.sql        # C
  04_master_constraints_crud.sql          # A
  05_order_constraints_crud.sql           # B
  06_inventory_constraints_crud.sql       # C
  07a_master_views_queries.sql             # A
  07b_order_views_queries.sql              # B
  07c_inventory_views_queries.sql          # C
  08_roles_permissions.sql                # C
  09a_master_seed_data.sql                 # A
  09b_order_seed_data.sql                  # B
  09c_inventory_opening_seed_data.sql      # C：订单前的期初库存 + 权限种子（EmployeeAccount / BusinessRole / RolePermission）
  09d_inventory_replenishment_seed_data.sql # C：订单后的补货与收货数据
  10a_master_acceptance_tests.sql         # A
  10b_order_acceptance_tests.sql          # B
  10c_inventory_security_acceptance_tests.sql # C
docs/
  主数据数据字典.md                         # A
  订单履约数据字典.md                       # B
  库存权限数据字典.md                       # C
  stage1-test-report.md                   # C 主写
```

唯一部署入口为 `sql/run_all.sql`：使用 `sqlcmd -S <实例> -E -C -f 65001 -i sql/run_all.sql`，或在 SSMS 启用 **SQLCMD Mode** 后执行该文件。`-C`（信任服务器证书）不可省略：ODBC Driver 18 默认强制加密，本地实例用的是自签证书，不加会报“证书链是由不受信任的颁发机构颁发的”而连不上。`-f 65001` 同样不可省略：`sql/` 下脚本是 UTF-8 无 BOM，不加该参数 `sqlcmd` 按代码页 936 解码，**中文字符串字面量会被静默读错**（不报错）。实测 `LEN(N'中文测试')` 不加得 6、加得 4，`UNICODE(首字)` 不加得 28051、加得 20013。这会让 `01` 以外的中文种子写成乱码、`THROW N'…'` 的报错变乱码；另一种形态是中文串吞掉收尾单引号使整批被当成未闭合字符串而静默作废（`exit=0`、无输出、语句未执行），比报错更危险。**单独执行任何含中文字面量的脚本（`04`、`09a`、`10a`、`09b`、`09c`、`10b`、`10c` 等）时同样要加。** 官方 VS Code mssql 扩展不支持 SQLCMD 的 `:r`，在编辑器中直接执行该文件会失败，必须走上述两种方式之一；它以 `:r` 固定引入 `00_create_database → 01_master_schema → 02_order_schema → 03_inventory_security_schema → 04_master_constraints_crud → 06_inventory_constraints_crud → 05_order_constraints_crud → 07a → 07b → 07c → 08 → 09a → 09c → 09b → 09d → 10a → 10b → 10c`。`09c` 必须先为订单提供期初库存，`09b` 才能调用锁库过程；`09d` 在订单制作触发补货建议后再创建收货数据。所有脚本不得依赖手工切换数据库或窗口变量。

公共对象命名：主键 `PK_<Table>`、外键 `FK_<Child>_<Parent>`、唯一键 `UQ_<Table>_<BusinessColumn>`、检查约束 `CK_<Table>_<Rule>`、默认约束 `DF_<Table>_<Column>`、索引 `IX_<Table>_<Column>`（唯一索引与过滤唯一索引用 `UQ_<Table>_<Column>`，例如 `UQ_ProductCategory_is_primary`）、存储过程 `dbo.sp_<verb>_<noun>`、视图 `dbo.v_<subject>`、数据库角色 `role_<job>`。

公共注释口径：脚本行内注释**只写对象“是什么”**（中文名、单位、口径），**不写“能取哪些值”**。枚举取值的唯一权威是 `04`/`05`/`06` 里的命名 `CHECK` 约束，各域数据字典的“取值范围”列跟随它。同一份取值写进注释、数据字典、`CHECK` 三处而又没约定谁说了算必然分叉——A 域已经出现过 `01` 注释写小写 `single` 而 `CHECK` 要写 `SINGLE` 的不一致。字段中文名在脚本里重复一遍是可以接受的：脚本是三人共读、要交要评的 DDL 文件，逐字段带中文名比裸英文可读得多，且字段名几乎不变。

<a id="sec-2"></a>

## 2. 三人边界与接口契约

| 成员 | 表与对象所有权 | 绝对不负责的内容 | 对其他成员的交付接口 |
| --- | --- | --- | --- |
| A（主数据与营销） | 分类、商品、原料、BOM、套餐组成、促销、会员等级、顾客；相应 CRUD、视图、约束 | 不创建订单、支付、库存流水或数据库角色 | 向 B 提供合法的商品、顾客、促销、会员等级外键；向 C 提供原料、安全库存线和 BOM |
| B（订单履约与积分） | 订单、订单明细、支付、配送、积分流水；相应 CRUD、视图、约束 | 不直接更新库存数量，不创建或授予数据库角色 | 在订单明细落库后调用 C 的库存过程；使用 A 的价格/促销/会员数据作快照 |
| C（库存补货、权限与集成） | 库存、库存流水、补货建议、采购单、采购收货、员工账号、审计日志；权限、最终集成、验收 | 不修改商品价格、订单金额、积分倍数的业务规则 | 向 B 提供锁库/释放/实扣/入库过程；向三人提供角色、授权脚本和验收基线 |

<a id="sec-2-1"></a>

### 2.1 必须先冻结的表名与主键

三人首次同步后不得更名。字段可新增，但不得删除或改变下列主键的数据类型。

| 业务域 | 表名 | 主键 | 必须存在的关键字段 |
| --- | --- | --- | --- |
| A | `Category` | `category_id` | `category_name`, `status` |
| A | `Product` | `product_id` | `product_name`, `base_price`, `product_type`, `status` |
| A | `ProductCategory` | `(product_id, category_id)` | `is_primary` |
| A | `Ingredient` | `ingredient_id` | `ingredient_name`, `unit_name`, `safety_stock_qty`, `status` |
| A | `ProductBom` | `(product_id, ingredient_id)` | `usage_qty` |
| A | `ComboComponent` | `(combo_product_id, child_product_id)` | `quantity` |
| A | `Promotion` | `promotion_id` | `promotion_name`, `promotion_type`, `start_at`, `end_at`, `status` |
| A | `PromotionProductRule` | `promotion_rule_id` | `promotion_id`, `product_id`, `weekday_no`, `start_time`, `end_time`, `promo_price`, `priority` |
| A | `MemberLevel` | `member_level_id` | `level_name`, `point_multiplier`, `threshold_points`, `status` |
| A | `Customer` | `customer_id` | `mobile`, `customer_type`, `member_level_id`, `current_points`, `status` |
| B | `SalesOrder` | `order_id` | `order_no`, `customer_id`, `order_status`, `fulfillment_method`, `pickup_code`, `total_amount`, `ordered_at`, `paid_at`, `production_started_at`, `production_finished_at`, `completed_at`, `cancelled_at` |
| B | `SalesOrderItem` | `order_item_id` | `order_id`, `product_id`, `parent_order_item_id`, `item_role`, `quantity`, `unit_price`, `promotion_id` |
| B | `Payment` | `payment_id` | `order_id`, `payment_method`, `paid_amount`, `payment_status`, `paid_at`, `refunded_amount`, `refunded_at`, `third_party_txn_no` |
| B | `Delivery` | `delivery_id` | `order_id`, `rider_employee_id`, `delivery_status`, `picked_up_at`, `delivered_at` |
| B | `PointLedger` | `point_ledger_id` | `order_id`, `customer_id`, `paid_amount_snapshot`, `point_multiplier_snapshot`, `point_delta`, `ledger_status`, `created_at`, `effective_at` |
| C | `Inventory` | `ingredient_id` | `on_hand_qty`, `locked_qty`, `updated_at` |
| C | `InventoryMovement` | `inventory_movement_id` | `ingredient_id`, `movement_type`, `on_hand_delta`, `locked_delta`, `reference_type`, `reference_id`, `moved_at` |
| C | `ReplenishmentSuggestion` | `replenishment_suggestion_id` | `ingredient_id`, `current_qty`, `suggested_qty`, `suggestion_status`, `created_by_employee_id`, `submitted_by_employee_id`, `approved_by_employee_id`, `rejected_by_employee_id` |
| C | `PurchaseOrder` | `purchase_order_id` | `purchase_order_no`, `replenishment_suggestion_id`, `purchase_status`, `approved_by_employee_id`, `approved_at` |
| C | `PurchaseOrderItem` | `(purchase_order_id, ingredient_id)` | `ordered_qty`, `received_qty` |
| C | `EmployeeAccount` | `employee_id` | `database_user_name`, `login_name`, `employee_name`, `job_code`, `status` |
| C | `BusinessRole` | `business_role_id` | `role_code`, `role_name`, `status` |
| C | `EmployeeBusinessRole` | `(employee_id, business_role_id)` | `assigned_by_employee_id`, `assigned_at` |
| C | `RolePermission` | `(business_role_id, permission_code)` | `permission_name`, `status` |
| C | `AuditLog` | `audit_log_id` | `employee_id`, `action_name`, `entity_name`, `entity_id`, `detail_json`, `logged_at` |

`weekday_no` 固定为 `1` 至 `7`（周一至周日）。它必须以 `DATEDIFF(DAY, DATEFROMPARTS(1900,1,1), CAST(@at AS DATE)) % 7 + 1` 计算（1900-01-01 为周一，取模得 0 即周一，故必须 `+1`），严禁直接使用受 `SET DATEFIRST` 影响的 `DATEPART(WEEKDAY, @at)`。`product_type` 只能是 `SINGLE` 或 `COMBO`。`customer_type` 只能是 `GUEST`、`WOW`、`PAID`。A 域六张表的 `status`（`Category`、`Product`、`Ingredient`、`Promotion`、`MemberLevel`、`Customer`）统一只能为 `ACTIVE` 或 `INACTIVE`，与 C 的 `EmployeeAccount.status`、`BusinessRole.status` 取值保持一致。`Promotion.promotion_type` 第一阶段只允许 `FIXED_PRICE`（一口价，价格取自 `PromotionProductRule.promo_price`）；新增促销类型必须同时修改本节、`fn_get_effective_product_price` 和相应 `CHECK` 约束，不得只放开约束而不实现分支——那会让价格函数把新类型当一口价静默算错。

<a id="sec-2-2"></a>

### 2.2 跨域定价与积分接口

下列对象由 A 创建和维护，B 只能调用，不能复制其促销条件、修改 `Customer.current_points` 或 `Customer.member_level_id`。

```sql
dbo.fn_get_effective_product_price(@product_id BIGINT, @at DATETIME2(0))
dbo.sp_apply_customer_points @customer_id BIGINT, @delta INT
```

- `fn_get_effective_product_price` 是一个内联表值函数，返回且只返回一行 `product_id`、`effective_price`、`promotion_id`。它以商品标准价为默认值；仅在促销处于启用状态、日期处于 `start_at` 至 `end_at`、星期和时段均命中规则时返回促销价。A 的 `v_active_product_price` 与 B 的 `sp_create_order` 都必须调用它，禁止各自重写判断逻辑。
- `sp_apply_customer_points` 只原子锁定并更新 `Customer.current_points`，再从全部 `ACTIVE` 会员等级中选择 `threshold_points <= 更新后积分` 的最高门槛等级（同门槛按 `member_level_id` 最小者）更新客户等级；它不得读取或更新 B 的 `PointLedger`。B 在调用前于同一显式事务中锁定并将本订单的 `PointLedger` 从 `PENDING` 更新为 `EFFECTIVE`；任一步失败则回滚两者。B 只在 `sp_pick_up_order` 和 `sp_confirm_delivery` 调用它。它同样必须遵守第 2.3 节的嵌套事务纪律：`@@TRANCOUNT = 0` 时才自行 `BEGIN TRANSACTION/COMMIT`，已处于调用方事务中时只建立保存点、绝不提交外层，失败时回滚至保存点并 `THROW`。

### 2.3 跨域库存过程接口

下列过程名、参数名、返回语义不得自行改变。C 先在 `06_inventory_constraints_crud.sql` 实现，B 再在订单过程里调用。

```sql
dbo.sp_lock_order_inventory    @order_id BIGINT
dbo.sp_release_order_inventory @order_id BIGINT, @reason VARCHAR(20)
dbo.sp_consume_order_inventory @order_id BIGINT
dbo.sp_receive_inventory       @purchase_order_id BIGINT, @employee_id BIGINT
```

- 四个库存过程必须支持嵌套事务：若 `@@TRANCOUNT = 0` 才自行 `BEGIN TRANSACTION/COMMIT`；若已处于调用方事务，则只建立保存点、绝不自行提交外层事务，失败时回滚至保存点并 `THROW`。B 的 `sp_create_order`、`sp_pay_order`、`sp_finish_production`、`sp_cancel_or_refund_order` 必须各自持有覆盖其订单状态、明细、支付/积分和库存过程调用的外层显式事务。
- `sp_lock_order_inventory`：读取 `item_role = 'SELLABLE'` 且 `Product.product_type = 'SINGLE'` 的单品，以及 `item_role = 'COMPONENT'` 的套餐子项，再经 `ProductBom` 汇总原料用量；不得把套餐父项直接当作有 BOM 的单品。使用事务和锁确保每种原料的 `on_hand_qty - locked_qty >= 所需用量`。成功时增加 `locked_qty` 并以 `reference_type = 'ORDER'`、`reference_id = order_id` 写 `LOCK` 流水；不足时抛错并回滚订单创建。
- 库存流水数值语义固定：`LOCK` 为 `on_hand_delta = 0, locked_delta = +需求量`；`RELEASE` 为 `0, -释放量`；`CONSUME` 为 `-实扣量, -实扣量`；`RECEIPT` 为 `+收货量, 0`；`ADJUSTMENT` 只能改变 `on_hand_delta` 且必须写审计日志。建立 `CHECK (on_hand_delta <> 0 OR locked_delta <> 0)`。
- `sp_release_order_inventory`：仅释放尚未实扣的锁定量，写 `RELEASE` 流水；`@reason` 只能是 `CANCEL`、`PAYMENT_TIMEOUT` 或 `REFUND`。
- `sp_consume_order_inventory`：制作完成时将同等数量从 `on_hand_qty` 和 `locked_qty` 同时扣减，写 `CONSUME` 流水；随后按 5.C-1 的安全库存规则生成或更新补货建议。
- `sp_receive_inventory`：只允许 `APPROVED` 或 `PARTIALLY_RECEIVED` 采购单收货；增加 `on_hand_qty`、累计更新 `received_qty`、写 `RECEIPT` 流水。未全收齐时订单转为 `PARTIALLY_RECEIVED`；全部收齐时订单转为 `CLOSED`，并将关联补货建议转为 `CLOSED`。每次收货量必须大于零且不超过未收数量。

### 2.4 跨域审计接口

`dbo.sp_write_audit_log @employee_id BIGINT, @action_name VARCHAR(50), @entity_name VARCHAR(50), @entity_id BIGINT, @detail_json NVARCHAR(MAX)` 由 C 实现。A 和 B 的过程在成功完成下列敏感操作后调用它：商品价格/BOM/促销变更、员工与业务角色分配、补货建议调整/提交/审批/驳回、采购收货、订单取消或退款。该过程只写 C 的 `AuditLog`，调用方不得直接写审计表；`detail_json` 只记录操作前后业务字段，不记录支付完整报文或密码。它必须以静态 SQL 实现并保持 `dbo` 所有权链，使 A、B 的过程无需显式授权即可调用。

### 2.5 三人分工总览（按 A、B、C 执行）

<a id="sec-a"></a>

#### A：主数据、促销、会员与定价接口

**A 干什么：** 把“卖什么、怎么做、卖多少钱、顾客是谁、积分倍率是多少”落为关系表与可调用规则。

- 负责表：`Category`、`Product`、`ProductCategory`、`Ingredient`、`ProductBom`、`ComboComponent`、`Promotion`、`PromotionProductRule`、`MemberLevel`、`Customer`。
- 负责脚本：`01_master_schema.sql`、`04_master_constraints_crud.sql`、`07a_master_views_queries.sql`、`09a_master_seed_data.sql`、`10a_master_acceptance_tests.sql`、`docs/主数据数据字典.md`。
- 负责过程：主数据 CRUD、商品上架校验、BOM/套餐配置、促销维护、会员等级维护；提供 `fn_get_effective_product_price` 与 `sp_apply_customer_points`。
- 必须交给 B：可用的 `customer_id`、`product_id`、`promotion_id`，以及唯一且可复用的成交价计算接口。
- 必须交给 C：原料、安全库存线、单品 BOM、套餐组成；所有在售单品和套餐展开子项必须可据此找到 BOM。
- A 完成的标志：商品改价不影响历史订单快照；套餐能展开原料；重叠促销按优先级只得到一个价格；无 BOM 商品不能上架/下单。

#### B：订单、支付、履约、配送与积分流水

**B 干什么：** 把“顾客下单到餐品交付”的每一步变成可追溯、可回滚的订单状态机。

- 负责表：`SalesOrder`、`SalesOrderItem`、`Payment`、`Delivery`、`PointLedger`。
- 负责脚本：`02_order_schema.sql`、`05_order_constraints_crud.sql`、`07b_order_views_queries.sql`、`09b_order_seed_data.sql`、`10b_order_acceptance_tests.sql`、`docs/订单履约数据字典.md`。
- 负责过程：下单、支付、开始制作、制作完成、自取、骑手取餐/送达、取消/退款；所有订单状态迁移与订单明细快照由 B 落库。
- 必须调用 A：下单只能调用 `fn_get_effective_product_price` 取得成交价/促销快照；订单终态只能调用 `sp_apply_customer_points` 更新顾客积分和等级。
- 必须调用 C：下单锁库、取消释放、制作实扣都只能调用 C 的库存过程；不得直接更新库存表、补货表或审计表。
- B 完成的标志：能跑通自取完成、外送完成、未支付取消三类订单；支付、订单、积分流水与库存变化始终处于同一完整事务结果中。

#### C：库存、补货、员工权限、审计与总集成

**C 干什么：** 把“原料是否够、何时补货、谁能操作什么、如何一键验收”落实为库存闭环和权限闭环。

- 负责表：`Inventory`、`InventoryMovement`、`ReplenishmentSuggestion`、`PurchaseOrder`、`PurchaseOrderItem`、`EmployeeAccount`、`BusinessRole`、`EmployeeBusinessRole`、`RolePermission`、`AuditLog`。
- 负责脚本：`run_all.sql`、`00_create_database.sql`、`03_inventory_security_schema.sql`、`06_inventory_constraints_crud.sql`、`07c_inventory_views_queries.sql`、`08_roles_permissions.sql`、`09c_inventory_opening_seed_data.sql`、`09d_inventory_replenishment_seed_data.sql`、`10c_inventory_security_acceptance_tests.sql`、`docs/库存权限数据字典.md`、`docs/stage1-test-report.md`。
- 负责过程：锁库、释放锁、实扣、收货、库存人工调整、补货建议创建/调整/提交/审批/驳回、员工角色分配/撤销/停用、审计写入。
- 必须给 B：可嵌套事务调用的库存接口，保证 `LOCK / RELEASE / CONSUME` 与订单状态能一起回滚或提交。
- 必须给全组：角色、测试用户、授权脚本、`EXECUTE AS USER` 验收环境、统一 SQLCMD 入口和最终测试报告。
- C 完成的标志：库存不会为负；低库存只有一张开放建议；采购可两次收货直至关单；不同角色只能执行被授权过程；`run_all.sql` 从空库一次执行通过。

---

## 3. A 的实施清单：主数据、促销与会员

**负责文件：** `01_master_schema.sql`、`04_master_constraints_crud.sql`、`07a_master_views_queries.sql`、`09a_master_seed_data.sql`、`docs/主数据数据字典.md`。

<a id="sec-a-1"></a>

### A-1：建表与关系

- [ ] 在 `01_master_schema.sql` 依次创建 `Category`、`MemberLevel`、`Ingredient`、`Product`、`ProductCategory`、`Customer`、`ProductBom`、`ComboComponent`、`Promotion`、`PromotionProductRule`。
- [ ] `01` 里除 `Customer.member_level_id`（等级被停用而置空、或显式清空时为空，见变更记录 2026-09-29）与复合主键的组成列（主键隐式 `NOT NULL`）外，**所有列一律显式写 `NOT NULL`**。原因是 `CHECK` 的表达式在 `NULL` 上求值为 `UNKNOWN`，`CHECK` 会直接放行——受 `CHECK` 约束的列若可空，等于绕过 `04` 里全部取值与数值约束。
- [ ] 为 `ProductCategory` 的两个字段、`Customer.member_level_id`、`ProductBom.product_id`、`ProductBom.ingredient_id`、`ComboComponent` 的两个商品字段、促销规则的促销和商品字段建立外键。`ProductCategory` 用复合主键，另建过滤唯一索引保证每个商品至多一个 `is_primary = 1` 分类；`sp_create_product` 必须同时写入至少一条分类关系。
- [ ] 在 `ProductBom` 和 `ComboComponent` 使用复合主键，不另设无意义的 ID。
- [ ] `Customer.mobile` 建唯一约束；允许用“游客临时手机号”建档，但格式固定为 `TEMP-` 加 11 位订单来源号码，不能为 NULL，并以命名 `CHECK` 约束保证该格式。
- [ ] 在 `docs/主数据数据字典.md` 中逐字段写入：中文含义、数据类型、是否可空、默认值、主外键、取值范围、来源文档段落。

<a id="sec-a-2"></a>

### A-2：约束与 CRUD 过程

- [ ] 对 `Product.base_price > 0`、`Ingredient.safety_stock_qty >= 0`、`ProductBom.usage_qty > 0`、`ComboComponent.quantity > 0`、`PromotionProductRule.promo_price > 0`、`PromotionProductRule.priority >= 0`、`MemberLevel.point_multiplier > 0`、`MemberLevel.threshold_points >= 0`、`Customer.current_points >= 0` 创建命名 `CHECK` 约束。
- [ ] 对 `Promotion.end_at > Promotion.start_at` 和 `PromotionProductRule.end_time > PromotionProductRule.start_time` 创建检查约束。
- [ ] 枚举取值的命名 `CHECK` 约束同样必须建（不得只在注释里约定）：`Category`、`Product`、`Ingredient`、`Promotion`、`MemberLevel`、`Customer` 的 `status` 只能是 `ACTIVE` 或 `INACTIVE`；`Product.product_type` 只能是 `SINGLE` 或 `COMBO`；`Customer.customer_type` 只能是 `GUEST`、`WOW`、`PAID`；`Promotion.promotion_type` 只能是 `FIXED_PRICE`。
- [ ] 实现下列过程，所有写操作记录 `created_at` / `updated_at`（如表内存在该字段），失败时使用 `THROW` 返回可读错误：

```text
sp_create_category             sp_update_category_status
sp_create_ingredient           sp_update_ingredient
sp_create_product              sp_update_product_price             sp_update_product_status
sp_set_product_bom             sp_set_combo_component
sp_create_promotion            sp_update_promotion_status          sp_add_promotion_product_rule
sp_update_promotion_product_rule
sp_create_member_level         sp_update_member_level              sp_update_member_level_status
sp_create_customer             sp_update_customer_member_level
```

- [ ] `sp_update_product_price` 只能更新 `Product.base_price`；不得更新历史 `SalesOrderItem.unit_price`。
- [ ] `sp_set_product_bom` 和 `sp_set_combo_component` 只能修改所属商品尚未停用时的配置；输入数量小于等于零必须抛错。`sp_set_product_bom` 必须验证商品为 `SINGLE`；`sp_set_combo_component` 必须验证父项为 `COMBO`、子项为在售 `SINGLE`、父子不相同；第一阶段发现子项为 `COMBO` 时必须抛错，不实现嵌套套餐。
- [ ] `sp_update_product_status` 将 `SINGLE` 商品改为 `ACTIVE` 前必须验证至少存在一条 BOM；将 `COMBO` 商品改为 `ACTIVE` 前必须验证至少存在一条合法 `ComboComponent` 且每个子项均有 BOM。`sp_create_order` 也必须重复验证该条件，防止绕过上架过程。
- [ ] 实现 `fn_get_effective_product_price(@product_id, @at)` 和 `sp_apply_customer_points @customer_id, @delta`，严格满足第 2.2 节接口；函数内部采用第 2.1 节的 `DATEDIFF` 星期映射。定价函数必须以 `TOP (1) ... ORDER BY priority DESC, promotion_rule_id ASC` 选择规则，未命中时返回标准价和 NULL 促销 ID，因而每次调用恰返一行。
- [ ] 在商品价格、BOM、套餐组成、促销规则和会员等级的新增/修改/停用过程成功后调用 C 的 `sp_write_audit_log`；操作人必须由过程内部按 `EmployeeAccount.database_user_name = USER_NAME()` 解析为 `ACTIVE` 员工（遵守全局约束），不得信任外部传入的主体参数；未解析到员工时过程必须拒绝执行（`THROW`），不得写 NULL 审计。

<a id="sec-a-3"></a>

### A-3：视图、查询和验收数据

- [ ] 在 `07a_master_views_queries.sql` 创建 `v_active_product_price`：通过 `ProductCategory.is_primary = 1` 取得展示分类，并调用 `fn_get_effective_product_price(product_id, SYSDATETIME())` 输出在售商品、分类、标准价、当前有效成交价和生效促销 ID；不得再次实现促销匹配条件。
- [ ] 创建 `v_product_bom_detail`：输出销售商品、实际用料商品、原料、单位、每销售单位用量、安全库存线。单品直接关联 `ProductBom`；套餐必须经 `ComboComponent → ProductBom` 展开并按套餐、原料汇总用量；仅展示在售商品和启用原料。
- [ ] 提供两条具名查询注释：`-- Q-A1 在售商品及当前售价`、`-- Q-A2 指定商品的 BOM 明细`，并以 `@product_id` 变量展示 Q-A2 用法。
- [ ] 在 `09a_master_seed_data.sql` 插入至少：2 个分类、6 个商品（含 1 个套餐）、每个商品至少一条 `ProductCategory` 关系、6 种原料、每个可制作的 `SINGLE` 商品的 BOM、3 个会员等级、3 位顾客、1 个周四 9.9 元促销及 2 条规则；套餐只配置 `ComboComponent`，不配置直接 BOM。
- [ ] 在 `10a_master_acceptance_tests.sql` 写入 A 域断言：重复手机号失败、负数价格失败、促销结束早于开始失败、同一商品同一时段的重叠促销依 `priority` 取唯一最高优先级、`v_active_product_price` 与 `fn_get_effective_product_price` 对同一时间返回相同价格和促销 ID、无 BOM 单品不能上架或下单、BOM 视图能返回套餐中子商品的汇总原料。凡调用 A 的写过程（如上架、改价）的断言，都必须先 `EXECUTE AS USER = 'test_store_manager'` 调用、随后 `REVERT`，与 B/C 的验收脚本保持一致。

**A 的完成判定：** B 可凭 A 的种子 `customer_id`、`product_id`、`promotion_id` 创建订单；C 可凭 `ingredient_id` 和 `ProductBom` 计算订单所需原料；A 的所有反例均被约束拒绝。

---

## 4. B 的实施清单：订单、支付、配送与积分

**负责文件：** `02_order_schema.sql`、`05_order_constraints_crud.sql`、`07b_order_views_queries.sql`、`09b_order_seed_data.sql`、`docs/订单履约数据字典.md`。

### B-1：建表与状态机

- [ ] 在 `02_order_schema.sql` 创建 `SalesOrder`、`SalesOrderItem`、`Payment`、`Delivery`、`PointLedger`。
- [ ] `SalesOrder.order_no` 建唯一约束；`SalesOrder` 外键指向 A 的 `Customer`；订单明细外键指向 `SalesOrder`、`Product`，促销外键指向 `Promotion` 且允许 NULL，`parent_order_item_id` 自引用 `SalesOrderItem.order_item_id` 且允许 NULL。
- [ ] `SalesOrderItem.item_role` 只能是 `SELLABLE` 或 `COMPONENT`。单品为一条 `SELLABLE` 明细且 `parent_order_item_id IS NULL`；套餐为一条带成交价和促销快照的 `SELLABLE` 父项，加一条或多条 `COMPONENT` 子项。子项的 `parent_order_item_id` 指向套餐父项、数量等于套餐数量乘以 `ComboComponent.quantity`、`unit_price = 0`、`promotion_id IS NULL`，订单总额只累计 `SELLABLE` 项。
- [ ] `SalesOrder` 的 `ordered_at`、`paid_at`、`production_started_at`、`production_finished_at`、`completed_at`、`cancelled_at` 必须在建表时显式定义；`completed_at` 是 `PICKED_UP` 或 `COMPLETED` 的统一终态时间，配送明细另存骑手取餐和送达时间。
- [ ] `Payment.order_id` 建唯一约束，保证每个订单至多一条有效支付记录；`Delivery.order_id` 建唯一约束。外送订单制作完成时创建 `WAITING_PICKUP` 配送记录，`rider_employee_id` 允许为空，骑手实际取餐时再填入。
- [ ] 订单状态只能为 `PENDING_PAYMENT`、`PAID`、`IN_PRODUCTION`、`READY_FOR_PICKUP`、`READY_FOR_DELIVERY`、`DELIVERING`、`PICKED_UP`、`COMPLETED`、`CANCELLED`。
- [ ] 支付状态只能为 `PENDING`、`SUCCESS`、`REFUNDED`、`VOIDED`；积分流水状态只能为 `PENDING`、`EFFECTIVE`、`VOIDED`；配送状态只能为 `WAITING_PICKUP`、`DELIVERING`、`DELIVERED`。
- [ ] `fulfillment_method` 只能为 `PICKUP` 或 `DELIVERY`；取餐方式为 `PICKUP` 的订单必须有 `pickup_code`，外送订单的 `pickup_code` 可为空。
- [ ] 对 `SalesOrder.total_amount >= 0`、`SalesOrderItem.quantity > 0`、`SalesOrderItem.unit_price >= 0`、`Payment.paid_amount > 0`、`Payment.refunded_amount >= 0 AND refunded_amount <= paid_amount`、`PointLedger.point_delta >= 0` 建立命名 `CHECK` 约束；对 `PointLedger.order_id` 建唯一约束，确保一笔订单最多一条正向积分流水；对 `SalesOrder.pickup_code` 建过滤唯一索引（`WHERE pickup_code IS NOT NULL`），既防止取餐码撞号，又允许外送订单为空。

### B-2：订单与履约过程

- [ ] 实现 `sp_create_order @customer_id, @fulfillment_method, @order_no, @items_json, @ordered_at DATETIME2(0) = NULL`。过程自身以 `SET XACT_ABORT ON` 开启外层显式事务，先以 `ISJSON(@items_json) = 1` 验证输入，并拒绝缺少 `product_id`、`quantity`、数量非正、重复套餐子项伪造、商品不存在或非 `ACTIVE` 的项；以 `COALESCE(@ordered_at, SYSDATETIME())` 同时写订单时间和调用价格函数。单品写一条 `SELLABLE` 明细，套餐先写套餐父项再按数据库中的 `ComboComponent` 写子项，调用方不得提交子项。所有父项价格和促销 ID 必须通过 `CROSS APPLY dbo.fn_get_effective_product_price(product_id, @effective_at)` 取得，禁止重写促销条件；验证单品和套餐子项均存在 BOM 后计算 `SELLABLE` 项总额并调用 `sp_lock_order_inventory @order_id`。任一步失败必须回滚整笔订单和锁库。`@ordered_at` 仅供 `test_*` 测试主体使用：`USER_NAME()` 不在测试主体白名单内却传入非空值时必须 `THROW`，防止真实登录名（如收银员）回溯下单时间套取已过期促销。
- [ ] 实现 `sp_pay_order @order_id, @payment_method, @paid_amount, @third_party_txn_no`。过程自身以 `SET XACT_ABORT ON` 开启覆盖支付记录、`paid_at`、订单迁移和积分快照的外层显式事务；仅 `PENDING_PAYMENT` 订单可支付；`paid_amount` 必须等于订单总额；成功后写支付记录、订单变 `PAID`，并写一笔 `PENDING` 积分流水：`paid_amount_snapshot = paid_amount`、`point_multiplier_snapshot = 支付时客户当前会员等级倍率`、`point_delta = FLOOR(paid_amount * point_multiplier_snapshot)`。积分小数一律向下取整；允许 `point_delta = 0`，终态时流水仍须变为 `EFFECTIVE`，客户积分不变。
- [ ] 实现 `sp_start_production @order_id`，仅允许 `PAID → IN_PRODUCTION`，写 `production_started_at`。
- [ ] 实现 `sp_finish_production @order_id`。过程自身以 `SET XACT_ABORT ON` 开启覆盖库存实扣、`production_finished_at`、订单下一状态和外送配送记录的外层显式事务；仅允许 `IN_PRODUCTION`，调用 `sp_consume_order_inventory` 并写 `production_finished_at`；自取订单变 `READY_FOR_PICKUP`，外送订单变 `READY_FOR_DELIVERY` 且创建 `WAITING_PICKUP` 配送记录；不得由 B 直接更新 `Inventory`。
- [ ] 实现 `sp_pick_up_order @order_id`，仅允许 `READY_FOR_PICKUP → PICKED_UP`，写 `completed_at`；在同一显式事务中锁定并将本订单 `PointLedger` 变为 `EFFECTIVE`，再调用 A 的 `sp_apply_customer_points @customer_id, @delta`，B 不得更新顾客积分或等级字段。
- [ ] 实现 `sp_pick_up_delivery @order_id, @rider_employee_id` 和 `sp_confirm_delivery @order_id`。前者仅允许 `READY_FOR_DELIVERY` 且配送状态为 `WAITING_PICKUP`，填骑手和 `picked_up_at`，配送和订单均变 `DELIVERING`；后者仅允许 `DELIVERING → COMPLETED`，写 `delivered_at` 和 `completed_at`，并以与 `sp_pick_up_order` 相同的事务顺序生效积分。
- [ ] 实现 `sp_cancel_or_refund_order @order_id, @reason, @operator_employee_id`。过程自身以 `SET XACT_ABORT ON` 开启覆盖订单、库存、支付和积分的外层显式事务；仅允许 `PENDING_PAYMENT`（取消）、`PAID` 或 `IN_PRODUCTION`（实扣前全额退款）进入。`PENDING_PAYMENT` 以 `PAYMENT_TIMEOUT` 或 `CANCEL` 调用 `sp_release_order_inventory`；`PAID` 与 `IN_PRODUCTION` 以 `REFUND` 调用它（制作中的订单释放锁后直接终止，不进入实扣），并将 `Payment.payment_status` 改为 `REFUNDED`、`refunded_amount` 写为全额 `paid_amount`、`refunded_at` 写当前时间；两分支都必须将订单设为 `CANCELLED` 并写 `cancelled_at`，未生效积分设为 `VOIDED`。已实扣的订单不得静默加回库存，必须抛错要求走退料/盘亏流程；第一阶段收到部分退款金额时必须抛错。
- [ ] 在 `sp_cancel_or_refund_order` 成功后调用 C 的 `sp_write_audit_log`；`detail_json` 固定记录订单状态、退款原因、退款金额和积分流水状态，不记录第三方支付报文。

### B-3：视图、查询和验收数据

- [ ] 创建 `v_order_detail`：订单号、顾客、履约方式、状态、各时间戳、订单明细商品、数量、成交价、促销 ID、订单总额、支付信息。
- [ ] 创建 `v_kitchen_queue`：只显示 `PAID` 和 `IN_PRODUCTION` 的订单，展示下单时间、状态和 `SELLABLE` 商品明细；套餐订单须并列其 `COMPONENT` 子项供后厨备料；明确第一阶段不存定制备注字段。
- [ ] 创建 `v_customer_point_ledger`：顾客、订单、积分变动、状态、生效时间和当前积分。
- [ ] 创建 `v_pickup_board`：只显示 `READY_FOR_PICKUP` 的订单，输出订单号、取餐码、状态和下单时间，不含金额与会员信息（供 `role_waiter`）。
- [ ] 提供三条具名查询：`-- Q-B1 待制作订单`、`-- Q-B2 某订单完整履约记录`、`-- Q-B3 某顾客积分流水`。
- [ ] 在 `09b_order_seed_data.sql` 使用 A/C 的数据创建恰好三类订单，且所有业务过程必须在对应测试主体下运行并紧跟 `REVERT`：以 `EXECUTE AS USER = 'test_cashier'` 创建和支付订单；以 `EXECUTE AS USER = 'test_chef'` 开始制作；以 `EXECUTE AS USER = 'test_packer'` 制作完成并对自取订单执行取餐；以 `EXECUTE AS USER = 'test_rider'` 对外送订单执行取餐、送达；第三笔未支付订单在 `test_cashier` 创建后，以 `EXECUTE AS USER = 'test_store_manager'` 取消。三笔分别为自取完成、外送完成、未支付取消；第三笔必须产生 `LOCK → RELEASE`，前两笔必须产生 `LOCK → CONSUME`。至少一笔调用 `sp_create_order` 时传入一个周四的 `@ordered_at` 以稳定命中促销。不得用直接 `INSERT` 绕过本域过程。
- [ ] 在 `10b_order_acceptance_tests.sql` 写入 B 域断言：非法 JSON、数量不为正、停用商品、无 BOM 商品均不能下单；未支付不能开工、付款金额不等于订单总额失败、重复支付失败、支付过程在写积分流水时故意抛错后支付记录、订单状态和积分流水均回滚、错误状态跳转失败、订单明细价格在商品改价后仍不变、积分按 `FLOOR(实付金额 × 支付时倍率)` 计算且恰到等级门槛时升级、取餐或送达后积分变为 `EFFECTIVE`；已支付未实扣订单退款后订单为 `CANCELLED`、支付为 `REFUNDED` 且退款额等于支付额。

**B 的完成判定：** 用过程能完整跑通“下单 → 锁库 → 支付 → 制作 → 自取/配送 → 积分到账”；取消未实扣订单时锁定量恢复；所有订单、支付、积分历史均可通过视图追溯。

---

## 5. C 的实施清单：库存、补货、权限与集成

**负责文件：** `run_all.sql`、`00_create_database.sql`、`03_inventory_security_schema.sql`、`06_inventory_constraints_crud.sql`、`07c_inventory_views_queries.sql`、`08_roles_permissions.sql`、`09c_inventory_opening_seed_data.sql`、`09d_inventory_replenishment_seed_data.sql`、`10c_inventory_security_acceptance_tests.sql`、`docs/库存权限数据字典.md`、`docs/stage1-test-report.md`。

### C-1：建表、库存过程与补货闭环

- [ ] 在 `03_inventory_security_schema.sql` 先创建 `EmployeeAccount`、`BusinessRole`、`EmployeeBusinessRole`、`RolePermission`，再创建 `Inventory`、`InventoryMovement`、`ReplenishmentSuggestion`、`PurchaseOrder`、`PurchaseOrderItem`、`AuditLog`。`Inventory.ingredient_id` 同时是主键和对 `Ingredient` 的外键。
- [ ] 在 `03_inventory_security_schema.sql` 对已由 B 创建的 `Delivery.rider_employee_id` 使用 `ALTER TABLE` 添加到 `EmployeeAccount.employee_id` 的可空外键；为 `ReplenishmentSuggestion` 的创建/提交/审批/驳回员工字段、`PurchaseOrder.replenishment_suggestion_id` 和 `PurchaseOrder.approved_by_employee_id`、`EmployeeBusinessRole.assigned_by_employee_id`、`AuditLog.employee_id` 创建明确的外键。未分配骑手时 `Delivery.rider_employee_id` 可空；建议单创建人不可空，提交人、审批人和驳回人分别在提交、审批、驳回前可空。
- [ ] `InventoryMovement.movement_type` 只能为 `LOCK`、`RELEASE`、`CONSUME`、`RECEIPT`、`ADJUSTMENT`；`InventoryMovement.reference_type` 只能为 `ORDER`、`PURCHASE_ORDER`、`ADJUSTMENT`，其中 `ORDER` 与 `PURCHASE_ORDER` 必须填写 `reference_id`，`ADJUSTMENT` 允许为空；`ReplenishmentSuggestion.suggestion_status` 只能为 `PENDING`、`SUBMITTED`、`APPROVED`、`REJECTED`、`CLOSED`；`PurchaseOrder.purchase_status` 只能为 `DRAFT`、`APPROVED`、`PARTIALLY_RECEIVED`、`CLOSED`。
- [ ] 在 `06_inventory_constraints_crud.sql` 建立 `on_hand_qty >= 0`、`locked_qty >= 0`、`suggested_qty > 0`、`ordered_qty > 0`、`received_qty >= 0 AND received_qty <= ordered_qty` 等命名检查约束。
- [ ] 对 `BusinessRole.role_code`、`EmployeeAccount.database_user_name`、`EmployeeAccount.login_name` 建唯一约束；`EmployeeBusinessRole` 使用复合主键；`RolePermission.permission_code` 的取值必须对应本计划授权矩阵中的过程或视图权限。
- [ ] 实现第 2.3 节四个库存接口过程，且每个过程都使用 `SET XACT_ABORT ON`、显式事务和 `UPDLOCK, HOLDLOCK` 锁定需要更新的 `Inventory` 行。
- [ ] 实现 `sp_adjust_inventory @ingredient_id, @on_hand_delta, @employee_id, @reason`：仅店长角色可调用；以 `UPDLOCK, HOLDLOCK` 更新 `on_hand_qty`、写 `reference_type = 'ADJUSTMENT'` 的 `ADJUSTMENT` 流水并调用 `sp_write_audit_log`；`on_hand_delta = 0` 时必须抛错，调整后 `on_hand_qty` 不得为负；`@employee_id` 必须等于按 `USER_NAME()` 解析出的店长；调整后若 `on_hand_qty >= Ingredient.safety_stock_qty`，将本原料处于 `PENDING` 或 `SUBMITTED` 的建议置 `CLOSED`。
- [ ] 实现 `sp_create_replenishment_suggestion @ingredient_id, @suggested_qty, @employee_id`、`sp_update_replenishment_suggestion @suggestion_id, @suggested_qty, @employee_id`、`sp_submit_replenishment_suggestion @suggestion_id, @employee_id`、`sp_approve_replenishment_suggestion @suggestion_id, @manager_employee_id`、`sp_reject_replenishment_suggestion @suggestion_id, @manager_employee_id, @reason`。值班经理只能创建/调整/提交本店处于 `PENDING` 的建议（含实扣时自动生成的建议）；店长只能审批或驳回 `SUBMITTED` 建议；审批必须在同一事务内将建议设为 `APPROVED`、生成带 `replenishment_suggestion_id` 的 `PurchaseOrder`（单号按 `PO` + `yyyyMMdd` + 当日 4 位序号生成并建唯一约束）、将采购单设为 `APPROVED` 并写 `approved_by_employee_id`、`approved_at` 和采购明细；驳回时设为 `REJECTED`、写 `rejected_by_employee_id` 并写审计日志。
- [ ] 在库存实扣后，若 `Inventory.on_hand_qty < Ingredient.safety_stock_qty`，以实扣后的 `on_hand_qty` 写入 `ReplenishmentSuggestion.current_qty`，以 `Ingredient.safety_stock_qty - Inventory.on_hand_qty`（保留 3 位小数）写入 `suggested_qty`，即刚好补到安全库存线。开放态严格定义为 `PENDING`、`SUBMITTED`、`APPROVED`，并以 `WHERE suggestion_status IN ('PENDING','SUBMITTED','APPROVED')` 的过滤唯一索引保证每原料最多一张开放建议；已有 `PENDING` 或 `SUBMITTED` 时更新当前量与建议量，已有 `APPROVED` 时不得修改或新增建议，待关联采购单关闭后再将建议置 `CLOSED`。自动生成时 `created_by_employee_id` 记录触发实扣的当前员工（按 `USER_NAME()` 解析，保证非空）。
- [ ] 实现 `sp_assign_employee_business_role @employee_id, @business_role_id, @assigned_by_employee_id`、`sp_revoke_employee_business_role @employee_id, @business_role_id, @operator_employee_id`、`sp_update_employee_status @employee_id, @status, @operator_employee_id`。业务角色是权限的权威来源：`sp_assign` 仅对已由 DBA 建立数据库用户的激活员工执行，按白名单将 `BusinessRole.role_code` 映射到同名 `role_*` 数据库角色，并同步写 `EmployeeBusinessRole`；若目标用户已是该数据库角色成员，`sp_assign` 只补业务映射和审计，不重复 `ADD MEMBER`。`sp_revoke` 同步 `DROP MEMBER` 和删除映射；停用员工必须撤销其全部 `role_*` 成员关系。过程绝不创建服务器登录名，且所有动态角色名只能来自固定白名单。
- [ ] 角色同步过程不得使用 `EXECUTE AS OWNER`，以确保 `USER_NAME()` 仍指向实际店长。改用证书签名授予最小权限：在 `08_roles_permissions.sql` 创建仅用于角色同步的数据库证书和对应证书用户，对该证书用户 `GRANT ALTER ANY ROLE, ALTER ANY USER`，再为 `sp_assign_employee_business_role`、`sp_revoke_employee_business_role`、`sp_update_employee_status` 添加该证书签名。普通店长仅拥有这三个过程的 `EXECUTE` 权限，不拥有 `ALTER ANY ROLE`；三个过程均先以 `USER_NAME()` 验证店长身份，再执行角色同步并写审计。
- [ ] 实现第 2.4 节 `sp_write_audit_log`；在本域所有建议单调整/提交/审批/驳回、采购收货、员工业务角色分配过程成功后调用它。

### C-2：视图、查询、权限与审计

- [ ] 创建 `v_inventory_available`：原料、单位、现有量、锁定量、可售量（计算列）、安全库存线、是否低库存。
- [ ] 创建 `v_inventory_movement_history`：原料、流水类型、数量变化、关联单据、操作时间；不得暴露无关支付信息。
- [ ] 创建 `v_replenishment_dashboard`：建议单、原料、当前量、建议量、状态、采购单号、审批信息和收货进度。
- [ ] 创建视图 `v_order_inventory_trace`：订单号、`SELLABLE` 商品、套餐子项（若有）、原料、库存流水类型、数量变化和操作时间；只关联同订单的 `LOCK`、`RELEASE`、`CONSUME` 流水。该视图由 C 独占实现。
- [ ] 提供三条具名查询：`-- Q-C1 低库存原料`、`-- Q-C2 指定订单的库存流水`、`-- Q-C3 待审批补货建议`。
- [ ] 在 `08_roles_permissions.sql` 创建 `role_store_manager`、`role_shift_manager`、`role_cashier`、`role_chef`、`role_packer`、`role_waiter`、`role_rider`，同时创建不带登录的测试用户 `test_store_manager`、`test_shift_manager`、`test_cashier`、`test_chef`、`test_packer`、`test_waiter`、`test_rider`。仅将 `test_store_manager` 直接加入 `role_store_manager` 作为启动角色同步的受控引导；其余 `test_*` 用户此时不加入任何业务角色。验收脚本必须以 `EXECUTE AS USER` 切换这些主体测试正反权限；生产部署将实际登录名映射到同名数据库用户，不在仓库保存密码。
- [ ] 授权矩阵：`role_store_manager` 获得全部 A 的主数据过程、`sp_adjust_inventory`、`sp_cancel_or_refund_order`、`sp_approve_replenishment_suggestion`、`sp_reject_replenishment_suggestion`、`sp_assign_employee_business_role`、`sp_revoke_employee_business_role`、`sp_update_employee_status`、全部视图的 `EXECUTE/SELECT`；`role_shift_manager` 仅获 `sp_create_replenishment_suggestion`、`sp_update_replenishment_suggestion`、`sp_submit_replenishment_suggestion`、`sp_receive_inventory` 和库存/补货视图；`role_cashier` 仅获 `sp_create_order`、`sp_pay_order`；`role_chef` 仅获 `sp_start_production` 和 `v_kitchen_queue`；`role_packer` 仅获 `sp_finish_production`、`sp_pick_up_order`；`role_rider` 仅获 `sp_pick_up_delivery`、`sp_confirm_delivery`；`role_waiter` 仅获 `v_pickup_board`。每项 `GRANT EXECUTE` 或 `GRANT SELECT` 必须精确到过程或视图，不授予表级 `UPDATE`。
- [ ] 对所有业务角色 `DENY` 直接 `UPDATE` `Inventory`、`SalesOrderItem.unit_price`、`Customer.current_points`；这些字段只能通过过程修改。骑手过程必须以 `EmployeeAccount.database_user_name = USER_NAME()` 找到当前员工：取餐时该员工必须等于参数 `@rider_employee_id` 且岗位为 `RIDER`、状态为 `ACTIVE`，确认送达时必须等于配送记录中的骑手。
- [ ] 在 `09c_inventory_opening_seed_data.sql` 完成权限种子：先插入 `BusinessRole` 白名单行（`store_manager`、`shift_manager`、`cashier`、`chef`、`packer`、`waiter`、`rider`），为每个 `test_*` 数据库用户直接插入对应的 `EmployeeAccount`（部署种子，不调用业务过程），再填充每个业务角色应拥有的 `RolePermission` 记录。实际环境登录名由 DBA 先映射为数据库用户，店长再经 `sp_assign_employee_business_role` 分配业务角色；不得伪造实际密码或写入密码明文。

### C-3：集成种子、验收与交付报告

- [ ] 在 `09c_inventory_opening_seed_data.sql` 为每种 A 的原料建立一条库存记录；至少一种原料库存应设置在安全线附近，以便在 B 的制作完成后触发补货。完成上一条的 `EmployeeAccount` 与 `BusinessRole` 种子后，必须 `EXECUTE AS USER = 'test_store_manager'`，仅通过 `sp_assign_employee_business_role` 为自己和其余 `test_*` 用户分配角色，随后立即 `REVERT`；不得由部署者直接插入 `EmployeeBusinessRole` 或直接加入其余测试用户的 `role_*`。
- [ ] 在 `09d_inventory_replenishment_seed_data.sql` 验证 B 的三笔种子订单已跑出 `LOCK`、`CONSUME`、`RELEASE` 三类库存流水；对低库存建议先以 `EXECUTE AS USER = 'test_shift_manager'` 调用 `sp_submit_replenishment_suggestion` 并 `REVERT`，再以 `EXECUTE AS USER = 'test_store_manager'` 调用审批过程并 `REVERT`，之后分别两次 `EXECUTE AS USER = 'test_shift_manager'` 调用 `sp_receive_inventory` 并各自 `REVERT`：首次令状态为 `PARTIALLY_RECEIVED`，第二次收齐并变为 `CLOSED`，共写两组 `RECEIPT` 流水。
- [ ] 在 `10c_inventory_security_acceptance_tests.sql` 编写验收 SQL，每个断言以事务包裹，成功输出 `PASS: <测试名>`，失败使用 `THROW`。最少包含：库存不足下单回滚、取消释放锁、制作完成时故意抛错后订单状态与库存均回滚、库存永不为负、低于安全线生成唯一待审核建议、建议调整/提交/驳回状态迁移、非店长无法审批、两次收货后采购单由 `APPROVED → PARTIALLY_RECEIVED → CLOSED`、收货后库存增加、敏感操作产生审计日志、取餐员可查 `v_pickup_board` 但查不到含金额的视图、`EXECUTE AS USER` 下的正反权限测试。本计划所有“故意抛错”一律以违反既有约束或外键的方式注入（例如指向不存在的实体），不得为测试在过程中增加开关参数。
- [ ] 仅执行 `run_all.sql` 完成全量部署和验收，并将执行命令、客户端与 SQL Server 版本、实例名、执行日期、通过/失败数量写入 `docs/stage1-test-report.md`。
- [ ] 检查 `07a_master_views_queries.sql`、`07b_order_views_queries.sql`、`07c_inventory_views_queries.sql` 均能独立执行；检查脚本顺序不依赖客户端窗口手工操作或未声明变量。

**C 的完成判定：** 库存数量、流水、补货建议和采购收货完全可追溯；最小权限验证成功；全量脚本从空数据库可一次建立并通过验收。

---

## 6. 联调顺序、验收场景与提交规则

### 6.1 联调顺序

1. A 提交主数据架构、定价/积分接口、约束和主数据种子；B/C 执行 A 的脚本，确认商品、顾客、原料、BOM 均可查询。
2. B 完成订单表结构后，C 完成库存表与四个库存接口过程；C 先执行期初库存种子，B 再调用接口跑首笔下单和取消。
3. B 完成支付、制作、交付和套餐拆分后，由 C 验证库存和补货；A 验证 `fn_get_effective_product_price`、促销价、会员倍率和价格快照。
4. C 执行订单后的补货种子，汇总权限和验收脚本；三人从空数据库完整执行一次。

### 6.2 必须通过的端到端场景

| 编号 | 场景 | 预期数据库结果 | 负责人 |
| --- | --- | --- | --- |
| E2E-01 | 周四促销自取下单并支付 | 明细保存促销价和促销 ID；库存写 `LOCK`；订单为 `PAID`；积分流水为 `PENDING` | A+B+C |
| E2E-02 | 自取订单制作完成并取餐 | 库存写 `CONSUME`；订单为 `PICKED_UP`；积分生效并累计到顾客 | B+C |
| E2E-03 | 外送订单送达 | 配送表有骑手、取餐和送达时间；订单为 `COMPLETED`；积分生效 | B |
| E2E-04 | 未支付订单取消 | 订单为 `CANCELLED`；锁定量恢复；库存写 `RELEASE`；无有效积分 | B+C |
| E2E-05 | 原料不足下单 | 订单、明细、锁定量和流水全部回滚；返回库存不足错误 | B+C |
| E2E-06 | 制作后触发低库存 | 只生成一张 `PENDING` 补货建议；值班经理提交、店长审批后产生采购单；收货后增加现有量 | C |
| E2E-07 | 权限越权 | 收银员不能直接改商品价格/库存/积分；骑手不能操作其他订单；店长可审批补货 | C |

<a id="sec-6-3"></a>

### 6.3 提交与评审规则

- 每人每完成一个可单独执行的文件，提交一次：`feat(stage1): <domain> <deliverable>`。示例：`feat(stage1): add order schema and state checks`。
- 提交前在客户端从新查询窗口执行本人脚本（`run_all.sql` 除外，它必须走 `sqlcmd`）；在提交说明中写明“执行文件、依赖文件、已验证场景”。
- A/B 的合并请求必须由 C 检查脚本顺序与权限影响；C 的权限和验收脚本必须由 A、B 各复核一次。
- 发现字段、状态、过程接口冲突时，立即停止写实现，在本计划的“变更记录”新增一行；三人确认后再改。不得单方面改动第 2 节的表名、主键或接口。

<a id="sec-7"></a>

## 7. 最终交付检查表

- [ ] 空数据库按第 1 节的完整顺序可建立全部对象。
- [ ] 每张表有主键、需要的外键和业务约束；无孤儿订单、明细、库存或积分流水。
- [ ] 每个业务域至少有新增、查询、修改、停用/取消或删除（在不破坏历史的前提下）操作。
- [ ] 至少交付 10 个视图：A 2 个、B 4 个、C 4 个。
- [ ] 所有规定角色已建立且完成正向、反向权限测试。
- [ ] E2E-01 至 E2E-07 全部通过，结果写入 `docs/stage1-test-report.md`。
- [ ] `README.md` 补充实例名、登录方式、脚本执行顺序和复现步骤后，第一阶段方可验收。

## 8. 变更记录

| 日期 | 变更内容 | 发起人 | 三人确认 |
| --- | --- | --- | --- |
| 2026-09-10 | 首版三人实施边界、对象命名与验收标准；本日期为计划制定日，`AI使用记录.md` 中 2026-09-09 为此前需求讨论日，保留其原始日期 | 项目组 | 待确认 |
| 2026-09-10 | 评审修订：修正 Spec 相对链接；`weekday_no` 取模改为 `% 7 + 1`（原式会错一天）；A 的过程操作人改由 `USER_NAME()` 解析、10a 补 `EXECUTE AS`；退款范围放开至 `IN_PRODUCTION`；`sp_apply_customer_points` 补嵌套事务纪律；补 `BusinessRole` 权限种子与 `sp_adjust_inventory`；定义 `reference_type` 取值与 `pickup_code` 过滤唯一索引；`v_kitchen_queue` 补套餐 `COMPONENT` 子项；`@ordered_at` 限种子/测试主体；`run_all.sql` 与 `00_create_database.sql` 消除编号撞车；合并 09c 重复描述 | 项目组 | 待确认 |
| 2026-09-10 | 二次评审修订：`@ordered_at` 判据由“业务角色”改为“`test_*` 测试主体白名单”（原判据与 09b 种子冲突）；值班经理可提交本店任意 `PENDING` 建议（原“只能提交自己的”使自动建议无法进入审批）；09d 补 `sp_submit_replenishment_suggestion` 步骤；新增 `v_pickup_board` 供 `role_waiter`（原授权引用不存在的视图）；明确自动建议 `created_by_employee_id` 取触发实扣的当前员工；补 `purchase_order_no` 生成规则与 `rejected_by_employee_id` 字段；`sp_adjust_inventory` 补操作人校验与开放建议置 `CLOSED`；`sp_write_audit_log` 要求静态 SQL 保持所有权链；证书用户加授 `ALTER ANY USER`；`TEMP-` 手机号加 `CHECK`；统一“故意抛错”的注入方式；`00_create_database.sql` 注明 `GO` 分隔 | 项目组 | 待确认 |
| 2026-09-14 | 客户端不再限定 SSMS：Tech Stack 改为“VS Code + mssql 扩展或 SSMS 22 均可”；补注官方 mssql 扩展不支持 SQLCMD 的 `:r`，`run_all.sql` 只能走 `sqlcmd -i` 或 SSMS SQLCMD Mode；验收报告与提交规则中“SSMS 版本/SSMS 窗口”改为“客户端版本/客户端窗口”；`sqlcmd` 命令统一补 `-C`（ODBC Driver 18 默认强制加密，本地自签证书不加此参数会报证书链错误） | 项目组 | 待确认 |
| 2026-09-16 | 建库实施反馈修订：全局约束新增 SET 选项批（`QUOTED_IDENTIFIER` 等必须为 ON，否则过滤索引创建与相关 DML 报错 1934；`ProductCategory.is_primary` 与 `SalesOrder.pickup_code` 都涉及；`CREATE PROCEDURE` 会在创建时固化该选项，过程脚本同样要先设置）；§2.1 定义 A 域六张表 `status` 只能为 `ACTIVE` 或 `INACTIVE`，并在 §3 A-2 补充相应枚举 `CHECK` 约束；§1 补索引命名规则 `IX_<Table>_<Column>` 与 `UQ_<Table>_<Column>` | 项目组 | 待确认 |
| 2026-09-19 | 定义 `Promotion.promotion_type` 取值：第一阶段只允许 `FIXED_PRICE`（一口价，价格取自 `PromotionProductRule.promo_price`），§2.1 与 §3 A-2 同步补充；约定新增促销类型必须同时改本节、价格函数与 `CHECK` 约束，不得只放开约束不实现分支，以免价格函数把新类型静默当一口价处理 | 项目组 | 待确认 |
| 2026-09-19 | A 域非空订正：`01` 原除主键与 `ProductCategory.is_primary` 外全部列可空，而 `CHECK` 在 `NULL` 上求值为 `UNKNOWN` 会放行，等于绕过全部数值与取值约束。已为 32 个业务列补 `NOT NULL`（`Customer.member_level_id` 保留可空），§3 A-1 补相应要求。同时订正 `PromotionProductRule.priority` 注释方向为“数字越大优先级越高”，与 §2.2 的 `ORDER BY priority DESC` 一致；`04` 文件名拼写 `constrains` 订正为 `constraints`，与 `run_all.sql` 第 20 行对齐 | 项目组 | 待确认 |
| 2026-09-19 | 新增公共注释口径（§1）：脚本行内注释只写对象“是什么”，不写“能取哪些值”；枚举取值的唯一权威是 `04`/`05`/`06` 的命名 `CHECK`，各域数据字典的“取值范围”列跟随。起因是 `01` 注释把 `product_type`、`customer_type` 的取值按小写/别名写了一遍，与 `CHECK` 将采用的 `SINGLE`/`COMBO`、`GUEST`/`WOW`/`PAID` 不一致（`01` 两处注释已按新口径改为只写中文名） | 项目组 | 待确认 |
| 2026-09-22 | §1 部署命令补 `-f 65001`：`sql/` 下脚本为 UTF-8 无 BOM，不加该参数 `sqlcmd` 按代码页 936 解码，中文字符串字面量会被静默读错（实测 `LEN(N'中文测试')` 不加得 6、加得 4；`UNICODE(首字)` 不加得 28051、加得 20013）。影响所有含中文字面量的脚本（`04`、`09a`、`10a` 及各域种子/验收脚本），且不报错——或写成乱码，或整批被当成未闭合字符串静默作废（`exit=0`、无输出、语句未执行）。`run_all.sql` 已于 `01e67f1` 先行更新，本节补齐；C 在 `fb0041d` 中另为 `sp_write_audit_log` 增加按 `USER_NAME()` 复核 `ACTIVE` 员工的身份校验（签名不变），与本节 §2.4 的审计要求一致 | 项目组 | 待确认 |
| 2026-09-22 | **A 域：§3 A-2 line 227 与 line 228 之间存在互锁陷阱，已按计划字面实现，本节不改。** 计划未规定建档时的 `status`，而 line 227 的"只能修改所属商品尚未停用时的配置"实际上要求商品为 `ACTIVE`。若商品建档即 `INACTIVE`，line 227 就禁止配 BOM，而 line 228 又要求"改为 `ACTIVE` 前必须已有 BOM/子项"，新商品永远配不上用料——A 的实现一度采用该组合并放宽了 line 227，按本项目流程复核后**回退为计划字面**：`sp_create_product` 建档即 `ACTIVE`，`sp_set_product_bom` / `sp_set_combo_component` 在商品非 `ACTIVE` 时 `THROW 51002`，line 227 其余要求（数量 ≤ 0 抛错、类型校验、父子不相同、发现 `COMBO` 子项即抛错不实现嵌套套餐）与 line 228 全部保留。**遗留代价**：商品建档时尚未配 BOM 而状态已是 `ACTIVE`，故"在售但无可制作配置"成为可达状态，A 域内部再无约束可拦，只能靠 line 228 要求的 `sp_create_order` 重复校验（B 域）与 `09a` 的写入顺序兜住。请 B、C 确认该代价可接受（B 的点单校验直接相关），结论记于字典 §11 第 9 项第 3 条 | 成员 A | 待确认 |
| 2026-09-24 | **§2.3 line 141 的"失败时回滚至保存点"与 §5 C-1 line 298 的"每个过程都使用 `SET XACT_ABORT ON`"互斥，C 按 §5 C-1 实现。** `XACT_ABORT ON` 下 `THROW` 会把事务标记为不可提交（`XACT_STATE() = -1`），此后 `ROLLBACK TRANSACTION <保存点>` 也恢复不了；本机 SQL Server 2025 Express 隔离实验三组：`XACT_ABORT OFF` + `THROW` → `xact_state = 1`；`ON` + `THROW` → `-1`；`ON` + `THROW` + 保存点回滚 → 仍为 `-1`（`06` 第二段断言 T14 复现）。C 的立场：**保留 `XACT_ABORT ON`、不删保存点代码**——前者语义更严（失败即放弃整个外层事务），且与 `02_order_schema.sql` 已有的 `IF XACT_STATE() <> 0 ROLLBACK` 兜底一致；若日后改回 `XACT_ABORT OFF`，保存点分支自动生效。建议 §2.3 line 141 补一句勘误"在 `XACT_ABORT ON` 下保存点不可用，失败由调用方回滚整个事务"。外层事务持有方是 B 域，影响最大，请 B 定夺。C 的 `06` 第二段已按此实现并通过 20 条断言 | 成员 C | 待确认 |
| 2026-09-24 | **§2.3 line 138 与契约 §3.5 冻结的 `sp_receive_inventory @purchase_order_id BIGINT, @employee_id BIGINT`（2 参数）与同节 line 146 的"每次收货量必须大于零且不超过未收数量"不自洽。** 一张建议单只对应一个原料，审批生成的采购单只有一条明细（`PurchaseOrderItem` 主键为 `purchase_order_id` + `ingredient_id`），2 参数下过程无从得知本次收多少：若按"未收数量"全收，则第一次就收齐并直接 `CLOSED`，于是 §5 C-3 line 321 要求的 `09d` 两次调用（首次 `PARTIALLY_RECEIVED`、第二次 `CLOSED`）与 line 322 要求 `10c` 断言的两次迁移都不可达。C 的立场：**补第 3 参数 `@received_qty DECIMAL(12,3)`**，即 `sp_receive_inventory @purchase_order_id, @received_qty, @employee_id`，与 line 146、321、322 全部自洽；需同步改契约 §3.5、§2.3 line 138 与 `contract_interface_check.sql` 第 59-60 行的签名断言。按 §6.3「三人确认后再改」，C **暂不实现 `sp_receive_inventory`**；其余三个订单库存过程不受影响，已按冻结签名实现。契约冻结方与调用方都是 B，请 B 定夺。另：`sp_lock_order_inventory` 已按冻结签名实现，并加了一条计划未写的防御——同一订单重复锁库直接 `THROW`，防止 `locked_qty` 重复计数（B 的 `sp_create_order` 每单只调用一次，正常路径不受影响）。本单库存按 `LOCK`/`RELEASE`/`CONSUME` 三类流水勾稽，`locked_qty` 恒等于三者 `locked_delta` 之和，可在 `10c` 里直接断言 | 成员 C | 待确认 |
| 2026-09-24 | 回应 A 于 2026-09-22 提出的 A-2 互锁遗留代价（"在售但无可制作配置"成为可达状态，请 B、C 确认可接受）：**C 域确认可接受**。C 域四张表（`Inventory`、`InventoryMovement`、`ReplenishmentSuggestion`、`PurchaseOrder` 与其明细）都不引用 `ProductBom`/`ComboComponent`，该状态不落入 C 的任何不变量。C 另在 `sp_lock_order_inventory` 里加了兜底：若订单的任一 `SELLABLE` 单品或 `COMPONENT` 子项经 `ProductBom` 展开后**零用料**，过程直接 `THROW` 而不是静默锁 0，使该状态在下单侧立刻报错并回滚订单创建——这只是强化 line 228 已要求的 B 域重复校验，不改变冻结接口。B 域是直接受影响方，请 B 确认 | 成员 C | 待确认 |
| 2026-09-24 | **C 复核 B 的 `contract_interface_check.sql`（§6.3 line 357 要求 C 检查 A/B 提交的脚本顺序与权限影响），两处建议改。** ① 第 52 行断言 `dbo.fn_get_effective_product_price` 的 `@at` 为 `max_length = 8` 是错的：`DATETIME2(0)` 在 `sys.parameters.max_length` 里实测是 **6**（`sys.parameters` 的 `max_length` 是存储字节数，不是类型宽度；`BIGINT` 8、`INT` 4、`VARCHAR(50)` 50、`NVARCHAR(MAX)` −1 可对照）。契约 §2.1 冻结的就是 `DATETIME2(0)`，A 的 `04` 也按契约实现，所以该断言会**对合规实现必然误报 `THROW 52901`**——本机定向查证该谓词确实命中（`@at` → 断言 8、实际 6）。建议改为比较 `scale = 0`（`max_length` 只对字符/二进制类型有意义）。同法请自查第 59-60 行对 `sp_receive_inventory` 的参数断言。② `sql/contract_interface_check.sql` 与 `docs/stage1-cross-domain-interface-contract.md` 都**不在 §1 的文件清单里、也没有「负责人」头**，前者还不在 `run_all.sql` 的 `:r` 序列中；建议按 §1 的表格格式补登记（负责人、依赖、是否纳入 `:r` 顺序），否则最终交付时“空库一次建齐”的检查表会漏掉它们 | 成员 C | 待确认 |
| 2026-09-24 | **C 在 `08_roles_permissions.sql` 落地 §5 C-1 line 303 的证书签名方案，为满足 §5 C-3 line 323「仅执行 `run_all.sql` 完成全量部署」的自包含要求，数据库主密钥口令以明文写在脚本里。** 实现：`08` 建 DMK（`##MS_DatabaseMasterKey##`，幂等）→ 追加服务主密钥加密 → 建证书 `cert_role_sync`（私钥由 DMK 保护，签名时无需口令）→ 建证书用户 `cert_role_sync_user FROM CERTIFICATE` → 授 `ALTER ANY ROLE`/`ALTER ANY USER` → 为 `sp_assign_employee_business_role`、`sp_revoke_employee_business_role`、`sp_update_employee_status` 逐个 `ADD SIGNATURE`（`08` 整体幂等，可重复执行）。C 的立场：**课程项目可接受**——该 DMK 只保护这一个证书私钥、不保护任何业务数据，脚本已注明生产环境应由 DBA 预先建好 DMK 并跳过该批次；若三人认为不可接受，替代方案是 `08` 不建 DMK、改由部署者执行前手工建钥，代价是 `run_all.sql` 不再自包含（与 line 323 冲突）。实现已实机验证：32 条断言全通过，含「店长经签名过程完成一次角色分配」「业务角色均不持有 `ALTER ANY ROLE`/`ALTER ANY USER`」「证书用户持有这两项」 | 成员 C | 待确认 |
| 2026-09-24 | **C 对 §5 C-2 line 314「`role_shift_manager` 仅获 … 和库存/补货视图」的读法：C 域四个视图全给，含 `v_order_inventory_trace`。** C 域四视图为 `v_inventory_available`、`v_inventory_movement_history`、`v_replenishment_dashboard`、`v_order_inventory_trace`；追溯视图只输出订单号、商品与子项、原料、流水类型、数量变化与操作时间，不含金额与顾客信息，是值班经理核对订单用料与库存勾稽的正当工具。按此读法，`role_store_manager` 得全部 10 个视图（line 314 要求「全部视图」），`role_shift_manager` 得其中 4 个，`role_waiter` 仅 `v_pickup_board`、`role_chef` 仅 `v_kitchen_queue`，收银/打包/骑手不获任何视图。若三人认为追溯视图不应给值班经理，删掉 `08` 中对应的那一行 `GRANT SELECT` 即可，不影响其他授权。该视图同时读 B 的订单明细与 A 的 BOM，受影响方是 B、A，请两位确认 | 成员 C | 待确认 |
| 2026-09-24 | **C 交付 `sql/08_roles_permissions.sql`（提交 `6b23286`）并自验 32 条断言，按 §6.3 line 357「C 的权限和验收脚本必须由 A、B 各复核一次」请 A、B 各复核一次。** 交付内容：7 个 `role_*` 数据库角色；7 个不带登录的 `test_*` 用户（仅 `test_store_manager` 作受控启动引导，其余交由 `09c` 经角色同步过程分配）；按 §5 C-2 line 313–315 的 **52 条 `GRANT`**，覆盖 `CK_RolePermission_permission_code` 白名单全部 46 项（36 过程 + 10 视图）且无任何指向白名单之外的对象；按 line 315 的 **3 条 `DENY UPDATE`**（`Inventory` 表级、`SalesOrderItem.unit_price` 与 `Customer.current_points` 列级，共 21 行权限记录）；按 §5 C-1 line 303 的证书 `cert_role_sync`、证书用户与三个角色同步过程的 `ADD SIGNATURE`。**建议复核要点**：① 逐角色核对授权矩阵是否与 line 314 的字面一致（尤其值班经理的「库存/补货视图」是否含 `v_order_inventory_trace`，见本表同日「追溯视图」一行）；② 三条 `DENY` 是否恰好覆盖 line 315 要求的三个字段、无多余或遗漏；③ 证书用户只持有 `ALTER ANY ROLE`/`ALTER ANY USER`，任何业务角色都不持有，且三个过程各有且仅有一条 `SPVC` 签名；④ `08` 可重复执行——角色/用户/证书/主密钥/授权/签名均带存在性守卫，连跑两遍不报错（`ADD SIGNATURE` 非幂等，重复执行会报 15557）；⑤ 主密钥口令明文入库的取舍见本表同日「主密钥」一行。复核方式：以代码复核为主（B 的 `05/07b` 尚未合并，若要直接执行 `08`，需相应过程与视图已存在） | 成员 C | 待确认 |
| 2026-09-27 | **A 复核 `sql/08_roles_permissions.sql`（回应本表 2026-09-24「C 交付 08 并请 A、B 各复核一次」一行），按 C 列出的五个复核要点逐条回复。** ① **授权矩阵：与 §5 C-2 line 314 一致，通过。** `role_store_manager` 的 A 域过程授权恰为 18 条、与 `04` 的 18 个过程一一对应，视图授权恰为全部 10 个（含 A 的 `v_active_product_price`、`v_product_bom_detail`）；`role_shift_manager` 得 4 个库存/补货视图、`role_chef` 仅 `v_kitchen_queue`、`role_waiter` 仅 `v_pickup_board`，与 line 314 逐行相符；52 条 `GRANT` 无一指向 `CK_RolePermission_permission_code` 白名单之外。不向任何角色授予 `sp_apply_customer_points`、`fn_get_effective_product_price`、`sp_write_audit_log` 及 C 的三个 `sp_*_order_inventory` 是**正确的**：本机隔离实验证明同库 `dbo` 所有权链会穿透「过程→过程」与「视图→`CROSS APPLY`→内联表值函数」两种间接调用（只持外层过程 `EXECUTE` 即可间接调用内层，直调内层报 Msg 229），故 B 经 `sp_create_order` 走到 A 的定价函数与积分过程不需要额外授权。② **三条 `DENY`：字段范围通过，但语义需订正。** 恰好覆盖 line 315 要求的 `Inventory`、`SalesOrderItem.unit_price`、`Customer.current_points`，7 个角色各 3 条、无多余无遗漏。但实测**所有权链连表级与列级 `DENY` 一并穿透**：主体只持过程 `EXECUTE`、且对该过程要写的列有列级 `DENY UPDATE` 时，过程照样写成功；追加表级 `DENY UPDATE` 后仍然成功。`DENY` 只对**直接 DML** 生效（有表级 `UPDATE` 的主体直接改被 `DENY` 的列报 Msg 230，表级 `DENY` 后直接改任意列报 Msg 229）。由于 `08` 本就不给任何角色表级 DML，**这三条 `DENY` 目前对七个角色都不产生实际约束**，其意义是「将来若给角色表级 DML，这几列仍写不了」，不应被读成「`DENY` 在保护这些列」。建议在批次 5 补一句注释点明这层含义，授权本身不必改。③ **证书与签名：代码复核通过，但 A 侧无法独立复验。** `06` 的三个角色同步过程确实用 `EXEC(...)` 拼 `ALTER ROLE ... ADD MEMBER`，动态 SQL 会切断所有权链并以调用者身份执行，故 `ADD SIGNATURE` 是**必需而非装饰**；证书用户只持 `ALTER ANY ROLE`/`ALTER ANY USER`、七个业务角色均不持有，符合 line 303。动态 SQL 无注入路径：角色名来自硬编码的 7 值 `role_code` 白名单并过 `QUOTENAME`，目标用户取自 `EmployeeAccount`。本机 `KFC_DB` 装不了 `08`（依赖的 `05`/`07b` 尚未合并），`sys.crypt_properties` 里没有对应签名，故签名生效性只能采信 C 的 32 条断言。④ **幂等性：有一处死代码建议删。** 批次 6 第 159 行的守卫谓词 `crypt_type = 'ESKM'` 在首次执行即为真——实测 `ESKM` 就是「由服务主密钥保护」，而 `CREATE MASTER KEY ENCRYPTION BY PASSWORD` 本身就同时加上该保护（建完立刻同时存在 `ESKM` 与 `ESP2` 两行；执行 `ALTER MASTER KEY DROP ENCRYPTION BY SERVICE MASTER KEY` 后该行数 1→0，可据此确认），所以**第 160 行的 `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY` 永不执行**。目标状态正确（证书私钥仍可由服务直接打开、`ADD SIGNATURE` 无需口令），但该行注释描述的那一步没跑；且该分支**真被触发时**（部署者预建 DMK 后又丢掉 SMK 保护）会直接报 **Msg 15581**（此时 DMK 只有口令保护、处于关闭态，而 `08` 没有 `OPEN MASTER KEY`），即该分支不可用。建议删除第 160 行并订正注释，或把该分支改成显式 `THROW` 提示部署者手工处理。⑤ **主密钥口令明文：A 认同 C 的取舍**（该 DMK 只保护一个证书私钥、不保护任何业务数据），但它是仓库「不保存明文口令」规矩的例外，仍建议最终由三人拍板；替补方案（`08` 不建 DMK、改由部署者手工建钥）与 §5 C-3 line 323「仅执行 `run_all.sql` 完成全量部署」冲突，A 不赞成。**另附 A 侧发现的 `08` 与 `10a` 的依赖**：`10a` 的写断言以 `test_store_manager` 为调用主体，依赖 `09c` 为该用户名建一条 `status = 'ACTIVE'` 的 `EmployeeAccount` 行（§5 C-2 line 316 已定由 `09c` 插入；A 的 `10a` 已把它列为部署前提，缺行即 `THROW 51900`），请在 `09c` 落地时确认，同条已记入跨域契约 §7.1 | 成员 A | 待确认 |
| 2026-09-27 | **C 交付 `sql/09c_inventory_opening_seed_data.sql` 并自验通过（15 条断言 0 FAIL；重跑被守卫 `THROW 51001` 拒绝，证明“只允许在空库上执行”），同时按本表同日 A 行对 `08` 的复核意见完成修订。** ① `09c` 内容：7 个 `BusinessRole` 白名单行（`store_manager`、`shift_manager`、`cashier`、`chef`、`packer`、`waiter`、`rider`）；7 个 `test_*` 的 `EmployeeAccount`（部署种子直接插入，**`test_store_manager` 为 ACTIVE**，覆盖契约 §7.1 对 `10a` 的部署前提）；**52 条 `RolePermission`**；A 域 6 种原料各一条期初 `Inventory`。角色成员关系**只经** `sp_assign_employee_business_role` 建立：`EXECUTE AS USER = 'test_store_manager'` → 7 次分配 → `REVERT`，留下 7 条 `(i, i)` 映射与 7 条 `ASSIGN_EMPLOYEE_BUSINESS_ROLE` 审计（店长本人因 08 的受控启动引导已是 `role_store_manager` 成员，其 `detail_json` 恰为 `member_added:false` + `mapping_inserted:true`，其余 6 人为 `true` + `true`）；实现细节：`THROW` 与 `ROLLBACK` 都**不会**自动还原 `EXECUTE AS` 上下文（隔离实验实测），故分配批次在 `CATCH` 里显式 `REVERT` 再回滚。已验证的强一致断言：`RolePermission` 与 `sys.database_permissions` 里 7 个 `role_*` 的 `GRANT`（`class = 1 AND state = 'G'`）**双向差集均为空**，即 09c 的权限种子与 08 的授权矩阵逐行一致。② **冻结的 C 域种子 ID（供 `09b`/`09d`/`10c` 只读引用）**：`BusinessRole` 1..7 = `store_manager`、`shift_manager`、`cashier`、`chef`、`packer`、`waiter`、`rider`；`EmployeeAccount` 1..7 = `test_store_manager`、`test_shift_manager`、`test_cashier`、`test_chef`、`test_packer`、`test_waiter`、`test_rider`（与 `BusinessRole` 行号一一对应，`test_rider` 的 `job_code = 'RIDER'`）。③ **期初库存（数量全部由 A 的安全线推导，A 改线这里自动跟随）**：**压线（恰等于各自安全线）两种——鸡腿肉（1）与薯条（5）**；其余四种 = 安全线 × 10（汉堡面包 400 / 生菜 5000 / 沙拉酱 8000 / 可乐原浆 20000）。薯条按契约 §6.2 压线；**鸡腿肉是 C 侧实测后补上的触发原料**：B 的 `09b` 三笔种子订单全部落在商品 1（香辣鸡腿堡），实扣只触及原料 1/2/3/4，薯条永远不会被推到线下——仓库外整链预演实测：原“只让薯条压线”的设计在 09b 之后 `ReplenishmentSuggestion` **一行都没有**，`09d`/`10c` 的“值班经理提交 → 店长审批 → 两次收货”链条没有起点。因此 **C 撤回本行原对 B 的请求（不再要求 `09b` 含薯条），改由 C 侧让“实际会被消耗”的原料也压线，`09b` 不必改动**。预演复验：制作完成实扣后鸡腿肉 40.000 → 38.000，恰生成**一张** `PENDING` 建议（`current_qty = 38.000`、`suggested_qty = 2.000`、`created_by_employee_id = 5` 即触发实扣的配餐员），薯条仍为 1000.000、其余原料均不低于各自安全线，E2E-06 的“只生成一张建议”成立。若日后 B 的 `09b` 改成会消耗薯条，全库会同时出现两张建议，`09d`/`10c` 须按“逐原料”而非“全库恰一张”断言，届时同条修订。④ **`08` 的两处修订（按 A 行意见，尚未提交）**：批次 5 补 DENY 语义注释（所有权链连表级/列级 `DENY` 一并穿透，三条 `DENY` 只对直接 DML 生效、当前不由它们提供保护；C 侧 `t8` 的 T12 每次运行同样复现该事实）；批次 6 删去恒不执行的 `ALTER MASTER KEY ADD ENCRYPTION BY SERVICE MASTER KEY`，改为缺失 ESKM 保护时显式 `THROW 50000` 并给出修复指引（原分支真触发时会报 Msg 15581）。改后重跑链 C：`08` 连跑两遍 `exit=0`、`t8` **32 条断言 0 FAIL**。A 复核的 ⑤（DMK 口令明文）仍待三人拍板；③（签名生效性）A 已说明无法独立复验。**`08` 的复核仍缺 B 一方**，请 B 一并看本表的 2026-09-24 C 行与同日 A 行 | 成员 C | 待确认 |
| 2026-09-27 | **C 确认 A 于 2026-09-26 追加的契约第 6–8 节（该节自述"待 B、C 确认后再并入上文"），C 侧受影响项逐条核对完毕、无异议。** ① **A 点名请 C 确认的那条已满足**：`09c` 为 7 个 `test_*` 插入 `EmployeeAccount`，其中 `test_store_manager` 的 `status = 'ACTIVE'` 且 `database_user_name` 恰为 `test_store_manager`（`t9` 的 T2/T4 断言），`10a` 的部署前提成立。② 契约 §6 约定 2 请 C"把薯条期初设在安全线附近"——`09c` 取的是**恰好等于**安全线 `1000.000`（比"附近"更严格；按"实扣后 `< safety_stock_qty` 才生成建议"的口径，压线在实扣前不生成建议、实扣后必生成）。契约 §6 约定 4 的号段（A 占 `13900000001–3`、夹具占 `139000099xx`）与 C 侧无冲突：`09c` 不插 `Customer`；`09d`/`10c` 若需要顾客行将避开这两个号段（`Customer.mobile` 有唯一约束）。③ 契约 §7.2「`09b`/`09c`/`09d` 只读引用 A 域 ID、不得增改 A 域内容」C 侧已遵守：`09c` 对 A 域只有一条 `SELECT`（取 `Ingredient.safety_stock_qty`）；据此，`10c` 若要 A 域夹具一律按契约 §7.4 第 1 条在回滚事务内临时插入。④ 契约 §7.4 第 5 条 C 侧**独立复现**（`THROW` 的 message 位与 `EXEC` 的实参位都不接受表达式）：`THROW 51000, CONCAT(N'a',N'b'), 1`、`EXEC #p @x = 1 + 1`、`EXEC #p @x = CAST(3 AS INT)` 三种写法全部报 **Msg 102**（语法级拒绝，且**令所在整批静默作废**，与 Msg 207/8156 同族）；`10c` 将一律先算进变量再传。⑤ 契约 §8 第 3 项的行号说明：A 引的是 line 311（`v_order_inventory_trace` 的语义行，确未规定授权），授权矩阵在 **line 314**，两处引用不矛盾，建议 B 决策时以 line 314 的字面为准。⑥ 提醒（不影响本次确认）：现在存在**两张待确认表**——本表九行与契约 §8 三项，后者三项均能在本表找到对应行（第 2、4、6 条），终交付前宜收敛为一处，以免三人各看一张走岔 | 成员 C | 待确认 |
| 2026-09-27 | **C 复核 A 的 `sql/10a_master_acceptance_tests.sql`（§6.3 义务）：发现一处会让 `run_all` 停在 `10a` 的 P0 顺序缺陷（已按 A 的真实形状实测复现），另有 4 条次要项；同一坑在我自己的 `09c` 里也存在、已修好并复验。** ① **P0：`REVERT` 必须在 `ROLLBACK` 之后**。`10a` 五处失败收尾是 `REVERT`（line 45、125、212、373、464）在 `ROLLBACK`（line 46、126、213、374、465）之前。实测：让 `XACT_STATE() = -1`（不可提交事务）后的 `REVERT` 会被拒 **Msg 3930「当前事务无法提交，而且无法支持写入日志文件的操作」**；`ROLLBACK` 则被允许，且回滚后模拟身份仍在、紧接着的 `REVERT` 才成功。**A 的真实形状复现**（`KFC_DB` 链 D 终态、会话 `SET XACT_ABORT ON` 模拟 `run_all` 里 `02_order_schema.sql:15` 未复位的泄漏、`EXECUTE AS USER = 'test_store_manager'` 后调 `sp_create_customer` 撞重复手机号）：输出 `R1 XACT_STATE=-1 err=51005 msg=sp_create_customer：该手机号已建档。` → 第 15 行 `REVERT` 报 Msg 3930 → 其后的 `ROLLBACK` 与后续语句**一行都没执行**。即：`run_all.sql` 跑到 `10a` 的**第一条反例**就会整批中止，`:on error exit` 会让 `10b/10c` 一条都不跑，"空库一次建齐"交付失败。**建议改法（不动语义、零代价）**：把五处的两行对调，写成 `IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;` 再 `IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;`。不推荐改用"在 `10a` 顶部补 `SET XACT_ABORT OFF`"来回避——它能治当前症状，但会改变会话状态并留给后续脚本，且顺序一旦脆弱，将来任何过程内 `SET XACT_ABORT ON`（我的 `06` 过程就是）都会再触发。② **机制订正（对复核结论的推论有影响）**：**过程内部的 `SET XACT_ABORT ON` 在返回时确实复位，但复位不影响"已经发生的 abort"**——实测（会话级 `SET XACT_ABORT OFF`，只调用一个内部 `SET XACT_ABORT ON` 后 `THROW` 的过程）：`XACT_STATE() = -1`。所以不可提交事务是我方过程（`06` 全部过程）固有的失败态，**不依赖 `02` 的泄漏**；A 的 `04` 全程不设 `XACT_ABORT`（`grep` 计数 0），故 `10a` 只在 `run_all` 路径踩雷、单独执行正常——这正是它到现在没被发现的原因。③ **C 侧同一坑已修**：`sql/09c_inventory_opening_seed_data.sql` 批次 3 的 `CATCH` 原为 `REVERT` 先于 `ROLLBACK`，现已改为 `ROLLBACK` → `REVERT` → `THROW`，并在注释里记明原因。验证：链 D 重跑 `09c` 部署 `exit=0`、`t9` **15 条断言 0 FAIL**、`09c` 重跑仍被 `51001` 守卫拒绝；另用 09c 真实调用形状做失败路径实验，`sp_assign_employee_business_role` 对不存在员工抛 `50000` 后，`ROLLBACK 成功（doomed 下允许）`、`REVERT 成功, current_user=dbo`、原始错误码与文案均保留。**这条修复对 `10c` 同样适用：凡 `EXECUTE AS` + 期望失败的断言，一律 `ROLLBACK` 在前、`REVERT` 在后。** ④ **A 的 `10a` 结尾缺 `RESULT: pass=… fail=…` 行**（全文 13 条 `PRINT N'PASS: …'`，无任何 `RESULT`；C 侧 `t3`–`t9` 均以该行收尾，`AGENTS.md` H7 也是这么判的）。缺它的实际代价：本项目最危险的失败模式是**整批静默作废**（`-f 65001` 吞引号、Msg 207/8156），此时"13 条全过"与"整批没执行、`run_all` 却 `exit=0`"在日志里只差 13 行 PASS。建议 A 按 C 侧写法加 `@pass/@fail` 计数并在独立批次收尾打印（`10a` 是首错即 `THROW` 的设计，该行能打印时 `fail` 必为 0，它的价值就是证明"13 条确实跑了"）。⑤ 次要两条供 10b/10c 接线：`10a` 的夹具（`Product`/`Customer`/`Promotion`）都在回滚事务内、**数据不留痕但 IDENTITY 当前值不回退**，而它在 `run_all` 里排在 `10b/10c` 之前，故"单独跑 10a"与"整跑 run_all"两种情形下后续脚本看到的下一个标识值不同——`10b/10c` 不要用绝对 ID 断言；另 `10a` 的 A7/A8/A12/A13 在部署登录（sysadmin）上下文读 `v_active_product_price`/`v_product_bom_detail`，**`08` 对这两个视图的 `GRANT SELECT` 在 A 域验收里无人验证**，C 会在 `10c` 里用 `test_store_manager` 补一次正反探针。⑥ 复核边界：本次为只读复核 + 仓库外实验，未改动 A 的任何文件（H1） | 成员 C | 待确认 |
| 2026-09-27 | **C 在仓库外做了一次整链预演（12 个仓库文件 + B 分支 `origin/codex/b-order-integration`（`a3ef3be`）的 `05/07b/09b/10b` + 只补 `sp_receive_inventory` 的 2 参数桩；单会话 + `:on error exit`，忠实复现 `run_all` 的 `XACT_ABORT` 泄漏），得到五条结论。** ① **`sp_receive_inventory` 缺失会先把整链拦在 `08`**：`08` 批次 3 第 6 行 `GRANT EXECUTE ON dbo.sp_receive_inventory` 报 **Msg 15151**（对象不存在），`:on error exit` 下 `09a`/`09c`/`09b`/`10a` 一条都不跑——即该过程的签名决定已是关键路径。本表 2026-09-24 一行已请 B 定夺；C 的立场仍是补第 3 参数 `@received_qty DECIMAL(12,3)`，**并建议给第 3 参数加默认值**（`= NULL` 表示“收齐未收数量”），这样契约 §3.5 的 2 参数调用仍然有效、B 只需在 `contract_interface_check.sql` 追加一行参数断言（该文件第 83–95 行有“参数个数必须相等”的 `52902` 断言，任何签名变动都必须由 B 同步改这一行）。② **A 的 `10a` P0 在整链中复现**：`08 → 09a → 09c → 09b` 全部通过后，`10a` 在第一条反例处以 **Msg 3930** 中止（批次内第 22 行），`10b`/`10c` 一条不跑——本表同日最后一行（C 复核 `10a`）的结论由此获得真实 18 文件链路的证据。③ **B 的 `10b` 在本链状态下第 7 条断言 （`duplicate payment is rejected`）失败，抛 `51007`**：它第 154 行按 `TOP (1) … ORDER BY customer_id` 取到 A 冻结种子的 `1` 号顾客（`13900000001`，**GUEST、无会员等级**），而 B 的 `sp_pay_order` 在顾客没有正倍率等级时抛 `52205`（`Customer needs a current active member level with a positive multiplier.`），于是“预期成功的第一次支付”本身就失败；B 自己的 `09b` 是筛过 `MemberLevel.status = 'ACTIVE' AND point_multiplier > 0` 的，两处口径不一致。**附带一个跨域问题**：A 的契约 §6 与 `10a` 都要求“新建档顾客不带会员等级”（`10a` 的 A2 断言 `member_level_id IS NULL`），而 B 的支付要求有等级——按现设计**新顾客与散客无法支付**，请 A、B 定夺（建档即给默认等级，还是支付时对无等级顾客按倍率 1.00 计 0 分）。④ **B 的 `10b` 全文没有 `RESULT: pass=… fail=…` 行**（H7 判据失效，与 A 的 `10a` 同一问题；C 侧 `t3`–`t9` 均以此收尾）。⑤ 顺带证实：B 分支的 `contract_interface_check.sql`（含 `@at` 的 `max_length` 8→6 修正）在合规签名下 **PASS**——A 的定价函数与积分过程、C 的三个库存过程与审计过程、B 的对象都与冻结契约一致。**本次为只读复核 + 仓库外预演，未改动 A、B 任何文件**（H1） | 成员 C | 待确认 |
| 2026-09-29 | **A 修复 `sql/10a_master_acceptance_tests.sql` 的 P0 与同族 4 处站点（回应本表 2026-09-27 的 C 复核两行与 C 整链预演 ②）。** C 的诊断与本机实测一致：`02_order_schema.sql:15` 的 `SET XACT_ABORT ON` 是批次级、会话内一直有效，`run_all.sql` 单会话执行时必然留到 `10a`；此时过程内的 `THROW`（**包括反例期望的那一次**）会把外层事务打成不可提交（`XACT_STATE() = -1`），而 `REVERT` 在不可提交事务里被拒并报 **Msg 3930**，整批中止，`10b`/`10c` 一条不跑。`04` 全文没有 `SET XACT_ABORT`（grep 计数 0），所以 `10a` 单跑 13/13 通过、只在整链里死——这正是 C 预演 ② 的复现条件。**A 的修法与 C 的建议有一处刻意的分歧**：C 建议 9 处统一改为"先无条件 `ROLLBACK` 再 `REVERT`"，但其中 4 处是"本该成功的对照断言"，其读回**就在事务内**（A2 的 `SELECT ... FROM dbo.Customer`、A4 的 `@price_after`、A6 与 A10 同型），提前回滚会把读回一起丢掉、把对照断言变成恒失败。A 改为每处插入一行**条件**回滚 `IF XACT_STATE() = -1 ROLLBACK TRANSACTION;`——只救不可提交态（实测该状态下 `ROLLBACK` 允许、`@@TRANCOUNT` 归零、`XACT_STATE()` 不再为 −1，`REVERT` 随即成功），`REVERT` 留在原位，5 处反例站点（A1/A3/A5/A9/A11）再把无条件的 `IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;` 移到 `REVERT` 之后，4 处对照站点（A2/A4/A6/A10）则只在意外报错分支里回滚，读回因此仍在事务内完成。**没有**在 `10a` 里写 `SET XACT_ABORT OFF`：那等于把本轮要暴露的部署语义从验收里摘掉，同类缺陷将来仍只会在整链里发作。另按 C 预演 ④（`10a` 缺 `RESULT` 行、H7 判据形同失效）补了断言计数表 `#a10_assertion` 与收尾批：13 条各插一行，末批打印 `RESULT: pass=13 fail=0`，计数不足 13 即 `THROW 51918` 并点明"有批次被静默作废"——`-f 65001` 缺失那类静默作废从此有计数可抓。**实测证据**：单跑 13 条 PASS、`RESULT: pass=13 fail=0`、`exit=0`；`run_all` 单会话形态（同一会话先 `SET XACT_ABORT ON`、`:on error exit`、再 `:r 10a`）改前为 `Msg 3930`、批内第 22 行、**0 条 PASS**、`exit=1`（与 C 预演 ② 逐项吻合），改后 13 条 PASS、`RESULT: pass=13 fail=0`、`exit=0`、无错误行。改动只在 `10a` 自身的事务收尾写法，未动任何跨域接口。**请 C 复验**：是否同意用"A 的条件回滚"替代原建议的无条件前置回滚（分歧只在 4 处对照站点），以及计数收尾是否符合 H7 的意图 | 成员 A | 待确认 |
| 2026-09-29 | **A 采纳 C 整链预演 ③ 的附带跨域问题：建档即带默认等级（用户 2026-09-29 拍定）。** C 指出"新建档顾客无等级"与 B 的 **52205**（顾客没有正倍率等级则拒绝支付）互斥，使"新建档 → 直接下单支付"这条最普通的路径被自己的守卫拦死；A 的判断是这该由 A 修（"0 分的顾客落在哪一档"是 A 域一次能答清的事），而不是放宽 B 的守卫——守卫拦的"等级被停用而置空、被手工清空"是真实坏数据，放宽它等于拆兜底。**落点四处**：① `04` 的 `sp_create_customer` 在建档前解析默认档并写进 `INSERT`，判据与 `sp_apply_customer_points` 对 0 分顾客算出的那一档**逐字相同**（`ACTIVE` 且 `threshold_points <= 0` 中门槛最高、同门槛取最小 `member_level_id`），找不到基准档则 `THROW 51001` 拒绝建档（配置缺陷宁可响亮失败，也别建出一个付不了款的顾客）；签名仍只有 `@mobile`、`@customer_type`，**不加参数**（契约冻结）。② `09a` 种子顾客 1 号（散客）由 `member_level_id = NULL` 改为 `1`，与新口径一致。③ `10a` A2 由"初始态为 `NULL`"改为断言"取默认档"，且判据在断言里**现算**而非写死 `1`，以后调整门槛档位不会让这条断言失真。④ 文档同步：契约 §6 的 `Customer` 种子行改记"等级 1"并新增约定 6（含"与 §2.2 在无档可归时写 `NULL` 的差异是刻意的"）、§8 新增第 4 项；字典 §6 `member_level_id` 字段行与设计要点、§4 可空列说明、§11 新增第 11 项；本表 §3 A-1 关于该列可空的那句括注同步订正。**`member_level_id` 的可空性保留**：停用等级即置空、`sp_update_customer_member_level(@member_level_id => NULL)` 显式清空都仍可达，所以 **B 的 52205 守卫保留为兜底**，只是不再是建档后的必经状态。**给 B 的一条提醒（不阻塞）**：若 `10b` 里 52205 那条断言的触发夹具靠"建档即无等级"，本次口径变化会让它失效，需改成"先建档再清空/停用"（同条已记入契约 §8 第 4 项）。**本机实测**：单批重装 `04` 的该过程后，`10a` A2 通过，单跑与 `run_all` 单会话形态均 13 条 PASS、`RESULT: pass=13 fail=0`、`exit=0`，`10a` 的部署前提（`test_store_manager` + `EmployeeAccount`）用完即撤、本地库已还原。**一处未覆盖的诚实说明**：`09a` 有"只允许空库执行"的守卫，本地库未清空，故其**种子文本未在本地重跑**（改的只是一个字面量与一句注释），新值的合法性由契约 §6 冻结的 `MemberLevel` 1 号行与 `10a` A2 的读回覆盖；最终由下一次空库全量部署验证 | 成员 A | 待确认 |
| 2026-09-27 | **C 复核 `sql/10a_master_acceptance_tests.sql` 的补充：同族还有 4 处站点（78、161、249、411）。** 这四处是“本该成功的对照断言”（A2 新建档、A4 改价、A6 建促销、A11 有用料单品可上架），其 `CATCH` 捕获到**意外**错误后，紧跟的 `IF @impersonating = 1 BEGIN REVERT; … END;` 仍会**先执行**——此时外层事务已被过程内部的 `SET XACT_ABORT ON` 弄成不可提交，`REVERT` 报 **Msg 3930** 并中止整批，本该打印的 `519xx` 诊断被顶掉（失败仍是响亮的 `exit ≠ 0`，不会静默通过，后果比第一处 P0 轻）。建议 A 把这 9 处（45/125/212/373/464 + 78/161/249/411）统一写成先 `IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;` 再 `IF @impersonating = 1 BEGIN REVERT; SET @impersonating = 0; END;`。依据：C 的 `09c` 同一坑已按此修好并复验（本表同日 C 行），以及三组隔离实验（会话 `SET XACT_ABORT ON` 下：`THROW` 后 `XACT_STATE() = -1`；该状态下 `ROLLBACK` 允许、`REVERT` 被拒并报 **Msg 3930**） | 成员 C | 待确认 |
| 2026-09-27 | **C 在仓库外做出 `sp_receive_inventory` 原型，把签名争议收敛为“B 只需加一行断言”。** 原型参数形态：`sp_receive_inventory @purchase_order_id BIGINT, @employee_id BIGINT, @received_qty DECIMAL(12,3) = NULL`（第 3 参数放**最后**并带默认值）。这样：① **契约 §3.5 冻结的两参数调用行为上仍然有效**——实测“只传两参数”会收齐未收数量并使采购单 `CLOSED`；② B 的 `contract_interface_check.sql` **现有两行参数断言原样不动**，只需在 `@parameters` 追加一行 `(N'dbo.sp_receive_inventory', N'@received_qty', 3, N'decimal', 9)`，`52902` 的个数断言随之通过（实测：不加该行时检查器报 52902，因为参数 1、2 与期望逐字一致）；③ `09d`/`10c` 要的“两次收货”仍可达。**实测证据**（B 分支 `a3ef3be` 的真实 `05/07b/09b` + C 的 `09c` 与 `06`）：`PENDING`（鸡腿肉 38.000 / 建议 2.000 / 创建人=触发实扣的配餐员，由 09c 的压线设计自动产生）→ 值班经理提交 → 店长审批（生成 `PO202609270001`）→ 收货 1.000（`APPROVED → PARTIALLY_RECEIVED`）→ 收货 1.000（`PARTIALLY_RECEIVED → CLOSED`，关联建议置 `CLOSED`，鸡腿肉回到 40.000，两条 `RECEIPT` 流水 `on_hand_delta = 1.000`、`reference_type = 'PURCHASE_ORDER'`、审计 `RECEIVE_INVENTORY` 两条）；两个反例同样被 `THROW 50000` 拒绝（超量收货、已收齐后再收）。**目录事实**：该参数在 `sys.parameters` 里是 `decimal / max_length 9 / precision 12 / scale 3`，而 `has_default_value` 对 T-SQL 对象**恒为 0**（官方口径：该列只为 CLR 对象维护），所以“带默认值”只能按行为验证或用 `sys.sql_modules.definition` 文本断言。**C 的立场**：请 B 按此形态定签名；若 B 仍坚持严格两参数，则“两次收货”与 plan §5 C-3 line 321/322 的验收要求必须同步改成单次收货（需三人确认）。原型只存在于仓库外（临时脚本一律放 `D:\DBLab\_kfcdb_tmp\`，不进 `sql/`）；B 点头后我把等价实现写进 `06`（批次 6；白名单与 `08` 的 `GRANT` 早已含该过程名，无需改动），再按 §7 跑链 B 的 `t4` + 链 C | 成员 C | 待确认 |
