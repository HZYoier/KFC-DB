# 第二阶段命名口径（naming）

> A；2026-10-27；依据 R5-09「命名能对应数据字典」与计划 §7.2 门槛 2.1 的「A 命名和情形验证」。
> 本文件**只定口径与登记偏差**，不改任何 SQL。v0.1 已于第一阶段部署验收，改名会牵动 47 份证据里的对象名，因此偏差一律登记为 2.2 迁移项，不就地重命名。
> 方法：全部结论由脚本扫 `sql/01`–`sql/08` 的 DDL/GRANT 得出，逐条可复算；人读的对照口径见三份数据字典。

## 0. 判定标准

一条命名合格，须同时满足三件事：

1. **能对上数据字典**——业务人员拿中文名，能查到唯一的表/列（R5-09 的字面要求）。
2. **能读出对象种类**——只看名字就知道它是表、过程、约束、索引还是角色，不需要打开定义。
3. **同类同形**——同一类对象只有一个形状；出现第二个形状必须写进本文件并给出理由。

本文件第 5 节登记现状中**不满足第 3 条**的地方，共 5 条：4 条留到 2.2 迁移修正，1 条（N-05）判定不改并记为例外。全部是 v0.1 的历史遗留，不涉及语义错误。

## 1. 对象形状总表

| 对象 | 形状 | 示例 | 现状 |
| --- | --- | --- | --- |
| 表 | PascalCase 单数名词 | `SalesOrder`、`PromotionProductRule` | 25/25 一致 |
| 列 | lower_snake_case | `product_id`、`ordered_at` | 一致，无大写列 |
| 主键 | `PK_<表>` | `PK_SalesOrder` | 25/25 具名 |
| 外键 | `FK_<子表>_<引用表或角色>` | `FK_SalesOrderItem_Product`、`FK_PurchaseOrder_ApprovedByEmployee` | **26 具名 + 9 匿名**（见 N-01） |
| 唯一约束 | `UQ_<表>_<列小写>` | `UQ_SalesOrder_order_no` | 9/9；其中 `UQ_Customer_Mobile` 列名段是大写，记为例外（N-05） |
| 检查约束 | `CK_<表>_<语义>` | `CK_PointLedger_point_delta` | 51/51 |
| 默认值 | `DF_<表>_<列>` | `DF_SalesOrder_ordered_at` | 19/19 |
| 普通索引 | `IX_<表>_<列>` | `IX_SalesOrderItem_order_id` | 1/1 |
| 唯一索引 | `UQ_<表>_<列>`（与唯一约束同形） | `UQ_SalesOrder_pickup_code` | 3 个；**有意不叫 `IX_`**——它表达的是唯一性事实，不是查询加速 |
| 存储过程 | `sp_<动词>_<对象>` | `sp_create_order`、`sp_lock_order_inventory` | 42 个（A 19 / B 8 / C 15） |
| 函数 | `fn_<动词>_<对象>` | `fn_get_effective_product_price` | 1 个 |
| 视图 | `v_<使用场景>` | `v_kitchen_queue`、`v_pickup_board` | 10 个；按**场景**不按表名，一张视图可跨表 |
| 数据库角色 | `role_<岗位小写>` | `role_store_manager` | 7 个 |
| 测试主体 | `test_<岗位小写>` | `test_cashier` | 7 个，仅测试夹具使用 |
| 证书签名用户 | `cert_<用途>` + `cert_<用途>_user` | `cert_role_sync` / `cert_role_sync_user` | C 域角色同步过程专用，不给登录 |

**唯一索引与唯一约束同形**是有意为之：两者在业务上都是「这一列（组合）不允许重复」，读者不需要先分辨它是约束还是索引，才知道它管唯一性。

## 2. 表名与数据字典的对应

R5-09 要求命名能对上数据字典，因此每个表名在字典里都有一个且只有一个中文条目。下表是完整映射，**新增表必须同时补进字典，否则本表失效**：

| # | 表 | 中文名 | 字典 |
| --- | --- | --- | --- |
| 1 | `Category` | 商品分类 | [主数据数据字典](../主数据数据字典.md) §1 |
| 2 | `MemberLevel` | 会员等级与积分倍率 | 同上 §2 |
| 3 | `Ingredient` | 原料主数据 | 同上 §3 |
| 4 | `Product` | 商品与套餐 | 同上 §4 |
| 5 | `ProductCategory` | 商品 × 分类关联 | 同上 §5 |
| 6 | `Customer` | 顾客主档 | 同上 §6 |
| 7 | `ProductBom` | 单品 → 原料用量清单 | 同上 §7 |
| 8 | `ComboComponent` | 套餐组成 | 同上 §8 |
| 9 | `Promotion` | 促销活动头 | 同上 §9 |
| 10 | `PromotionProductRule` | 促销规则明细 | 同上 §10 |
| 11 | `SalesOrder` | 销售订单 | [订单履约数据字典](../订单履约数据字典.md) §1 |
| 12 | `SalesOrderItem` | 订单明细 | 同上 §2 |
| 13 | `Payment` | 支付记录 | 同上 §3 |
| 14 | `Delivery` | 配送记录 | 同上 §4 |
| 15 | `PointLedger` | 积分流水 | 同上 §5 |
| 16 | `Inventory` | 原料库存 | [库存权限数据字典](../库存权限数据字典.md) §1 |
| 17 | `InventoryMovement` | 库存变动流水 | 同上 §2 |
| 18 | `ReplenishmentSuggestion` | 补货建议单 | 同上 §3 |
| 19 | `PurchaseOrder` | 采购单头 | 同上 §4 |
| 20 | `PurchaseOrderItem` | 采购单明细 | 同上 §5 |
| 21 | `EmployeeAccount` | 员工账号 | 同上 §6 |
| 22 | `BusinessRole` | 业务角色 | 同上 §7 |
| 23 | `EmployeeBusinessRole` | 员工业务角色关联 | 同上 §8 |
| 24 | `RolePermission` | 业务角色权限映射 | 同上 §9 |
| 25 | `AuditLog` | 审计日志 | 同上 §10 |

两类表名构词法，覆盖全部 25 张：

- **名词 + 限定词**：`PurchaseOrder` 是采购单头，`PurchaseOrderItem` 是它的明细；头/明细成对出现时，明细一律 `<头名>Item`。
- **两实体名拼接**：多对多关联表用两端实体名，`ProductCategory`、`ProductBom`、`ComboComponent`（套餐组成的两端是套餐父项与子商品）、`EmployeeBusinessRole`。**关联表不加 `Link` / `Ref` / `Rel` 后缀**——端点名已经说明了关系。

## 3. 列名细则

1. **主键与外键同名**：主键一律 `<实体单数>_id`；外键与所引用的主键**逐字同名**（`customer_id` → `Customer.customer_id`），不做 `fk_` / `ref_` 前缀，也不做 `customerid` 之类的缩写。复合主码表沿用两端的列名（`ProductCategory(product_id, category_id)`）。
2. **时间列以 `_at` 结尾，类型 `DATETIME2(0)`**：`ordered_at`、`production_finished_at`、`picked_up_at`。没有 `_time` / `_date` 两种写法并存的情况。
3. **快照列以 `_snapshot` 结尾**：`paid_amount_snapshot`、`point_multiplier_snapshot`。这类列是**历史事实**，不随源表变化，名字必须让读者看出它不是当前值。
4. **单位进列名**：`on_hand_qty` / `locked_qty` / `safety_stock_qty` 用 `_qty`，`unit_price` / `total_amount` 用 `_price` / `_amount`。**`qty` 与 `amount` 不混用**——前者是件数/克数，后者是货币，与 `DECIMAL(12,3)` vs `DECIMAL(10,2)` 的类型分工一致。
5. **布尔列以 `is_` 开头**：`is_primary`、`is_completed`（后者是查询派生列，出现在接口结果里）。不用 `flag` / `yn` / `has_`。
6. **状态列分两种形状，按表的性质定**——这是唯一一条「同类不必同形」的规则，但形状由表类别决定，不看作者心情：

   | 表的类别 | 状态列名 | 例 |
   | --- | --- | --- |
   | 主数据、账号、角色 | `status` | `Category`、`MemberLevel`、`Ingredient`、`Product`、`Customer`、`Promotion`、`EmployeeAccount`、`BusinessRole`、`RolePermission` |
   | 单据、明细、流水 | `<对象>_status` | `order_status`、`payment_status`、`delivery_status`、`ledger_status`、`purchase_status`、`suggestion_status` |

   理由：单据域的一次查询常把订单、支付、配送、积分四张表并置，若都叫 `status`，`SELECT` 里必须处处加表别名才能读懂；主数据域不会把九张表并置，裸 `status` 更简洁。**结果是 15 张有状态列的表（A 6 + B 4 + C 5）100% 落在规则内，没有第三种形状。**
7. **`status` 一律加方括号**：`[status]` 是 T-SQL 关键字，虽非保留字、不加括号也能解析，但为免读者怀疑，统一加方括号。现状 6 处加了、3 处没加（见 N-02）。

## 4. 岗位三处命名的一致性

同一个岗位在数据库里有三个名字，必须能一一对上，否则权限守卫和角色授权会错位：

| `job_code`（`EmployeeAccount.job_code`，守卫用） | 数据库角色（`08` 授 EXECUTE） | 测试主体（夹具用） | 中文岗名 |
| --- | --- | --- | --- |
| `CASHIER` | `role_cashier` | `test_cashier` | 收银员 |
| `CHEF` | `role_chef` | `test_chef` | 厨师 |
| `PACKER` | `role_packer` | `test_packer` | 配餐员 |
| `RIDER` | `role_rider` | `test_rider` | 骑手 |
| `WAITER` | `role_waiter` | `test_waiter` | 服务员 |
| `SHIFT_MANAGER` | `role_shift_manager` | `test_shift_manager` | 值班经理 |
| `STORE_MANAGER` | `role_store_manager` | `test_store_manager` | 店长 |

规则：`job_code` 全大写，角色与测试主体是它的**小写形式**加前缀。**只有大小写与前缀的差别，不允许出现同义异名**（如 `BARISTA` / `role_making`）。新增岗位必须同时补上三处，缺一处守卫就会拒掉合法调用。

另外两个名字的对应关系：

- 员工身份有**两列，名字各管一件事，不能混用**：`database_user_name` 存 `USER_NAME()` 的返回值，是过程守卫实际比对的那一列；`login_name` 只登记生产登录名（Windows/AD 账号）以便对上真人，**没有任何过程读它**，也不存密码。两列各有唯一约束（`UQ_EmployeeAccount_database_user_name`、`UQ_EmployeeAccount_login_name`）。这个区分在 `cust_app` 的部署方式里很关键：数据库用户可能 `WITHOUT LOGIN` 建出来，登录名由部署模板另外映射，此时两列天然不同名。
- 业务角色表 `BusinessRole` **不叫** `Role`：数据库里已经有 `role_*` 这类数据库角色，两者不是一回事——`BusinessRole` 是业务概念（店长/收银员），`role_*` 是 SQL Server 的授权载体。名字不同才能避免「谁是数据库角色」的误读。

## 5. 登记在案的偏差（2.2 迁移项）

四条都不影响当前运行，全部由脚本扫描得出，可复算：

| # | 偏差 | 位置 | 2.2 处理 |
| --- | --- | --- | --- |
| N-01 | **A 域 9 条外键匿名**（`foreign key(...) references ...` 未写 `CONSTRAINT`），系统生成名形如 `FK__ProductCa__produ__…`；B/C 域 26 条全部具名 | `01:61`–`135` | 迁移时补名为 `FK_<子表>_<引用表>`；共 9 条（`ProductCategory`×2、`Customer`×1、`ProductBom`×2、`ComboComponent`×2、`PromotionProductRule`×2）。**这是 A 域自身最该补的一条**——匿名名不可引用，ER 图与迁移脚本都只能按列猜 |
| N-02 | `status` 6 处写 `[status]`、3 处写 `status` | `01:20`/`30`/`39`/`49`/`79`/`118` 加了；`03:32`/`44`/`68` 没加 | 统一为 `[status]`（语义不变，纯可读性） |
| N-03 | `01` 的 `CREATE TABLE` 不带 `dbo.` 限定（`create table Category(`），`02`/`03` 全部写 `dbo.` | `01:17`–`123` | 迁移时统一加 `dbo.`。当前部署账号默认模式是 `dbo`，行为无差异；但若被默认模式非 `dbo` 的账号执行，表会落到别的模式里 |
| N-04 | `01` 的 DDL 关键字小写（`bigint not null`），`02`/`03` 大写（`BIGINT NOT NULL`） | 三个文件之间 | 纯风格，迁移时随 N-03 一并统一；不单独改 |
| N-05 | `UQ_Customer_Mobile` 的列名段写成 PascalCase，其余 8 个唯一约束与 3 个唯一索引的列名段均为 lower_snake（`UQ_SalesOrder_order_no`、`UQ_Payment_order_id`） | `01:75` | **不改**。该名已被 4 处文档引用（`stage1/阶段报告.md`、`stage1/a-stage-report.md`、`stage2/a-issues.md`、`stage2/a-normalization.md`），其中两份属第一阶段已交付物；为大小写改一个约束名会打断证据链，收益不抵代价。**作为唯一登记在案的例外保留** |

**不打算改的**：表名不使用 `tbl_` / `tb` 前缀，列名不使用 `c_` 前缀；关联表不加 `Link` 后缀；唯一索引沿用 `UQ_` 前缀。这些都是有意的口径，不是遗漏。

## 6. 与错误码的对应

错误码按**产生错误的对象所属域**分段，读者从码段就能判断该找谁：

| 段 | 归属 | 用途 |
| --- | --- | --- |
| `51000`–`51005` | A 域（`04`） | 主数据校验 |
| `52100`、`52101`–`52114`、`52201`–`52206`、`52301`、`52401`、`52501`–`52502`、`52601`–`52603`、`52701`–`52702`、`52801`–`52806` | B 域（`05`） | `52100` 统一是岗位不符，其余按过程分段 |
| `50000` | C 域（`06`） | 库存与权限类 |
| `53000`–`53002` | 顾客端三过程（2.2 新增） | 参数非法 / 顾客不存在 / 顾客已停用 |

`511xx` / `519xx` 只出现在 `10a` / `10c` 的断言脚本里，**不是业务码**；`09c` / `09d` 的部署期守卫码同为 `510xx`，不进应用调用路径。应用层映射见 [`application-contract.md`](application-contract.md) §1.5 与计划 §6.3。

## 7. 情形验证

命名口径不能只靠读，须用「换个读者还能不能读对」来验。四类情形：

| 情形 | 做法 | 预期 |
| --- | --- | --- |
| 只给表名，问业务含义 | 把 25 个表名交给不熟悉本库的读者，对照 §2 判 | 25/25 能归到唯一中文条目；`ComboComponent` 需借助字典（两端是父项与子商品，名字里的 `Component` 已足够提示） |
| 只给约束名，问它管什么 | 随机取 20 个 `CK_` / `UQ_` / `FK_` | 前缀决定对象种类，后半段决定对象；**匿名的 9 条外键做不到**——这是 N-01 的实际代价 |
| 给一个岗位，问它的三处名字 | 任取一个 `job_code` | 能按 §4 机械推导出 `role_*` 与 `test_*`，不需要查表 |
| 给一个错误码，问找谁 | 任取 `52xxx` / `530xx` | 码段唯一对应一个域，不出现跨段复用 |

这四项随 2.2 迁移后重跑；N-01 修完后第二项才可能 100%。

## 8. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-27 | 建立本文。形状总表与偏差登记由脚本扫 `sql/01`–`sql/08` 得出：25 表、26+9 条外键、42 个过程、10 个视图、7 组岗位三处命名。登记 5 条偏差：N-01 A 域 9 条外键匿名、N-02 `status` 方括号不一致、N-03 `01` 不写 `dbo.`、N-04 关键字大小写（以上 4 条留到 2.2 迁移修正），N-05 `UQ_Customer_Mobile` 列名段大小写（判定不改，记为例外）。逐名验证（§7）待 C 的合并总图落地后重跑 |
