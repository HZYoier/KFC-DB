# 第二阶段跨域接口契约（application-contract）

> 版本：2026-10-21（**草案，未冻结**）
>
> 用途：2.2 编写迁移前，把各域新增或变更的数据库接口汇总成一份可冻结的签名表。计划 §6.2 的流程是：各域提交准确参数类型、返回列类型/可空性、错误码与授权主体 → A 汇总本文 → C 核对身份与授权 → 冻结 → 各域写进 `11*`，C 写进 `12_permissions.sql`。
>
> 冻结前，本文任何条目都**不是**实现承诺，也不代表对象已存在——`sql/` 里目前没有任何顾客端过程。
>
> 范围：只管第二阶段新增或变更的对象。第一阶段已冻结的 `fn_get_effective_product_price`、`sp_apply_customer_points` 仍以 `docs/stage1-cross-domain-interface-contract.md` 为准，本文不重复、也不修改它们。
>
> 当前进度：只登记 OI-10 的顾客端三个过程（§1）。其余接口待 2.2 开工按计划 §6.2 的清单逐条补进 §2。

## 0. 状态口径

| 标记 | 含义 |
| --- | --- |
| 已定 | A 已对照现有实物核对过，可照此实现 |
| 待定 | 还没人拍板；括号内是 A 的建议，采纳前不算数 |
| 待 C 确认 | 需 C 核身份与授权后落定 |
| 待冻结 | 到 2.2 冻结时才生效，冻结前都可改 |

## 1. 顾客端接口（OI-10）

### 1.1 共同前提

1. 调用主体是独立的受限数据库账户（暂名 `cust_app`，最终名与创建方式由 C 的部署模板定），**只**被授予本节三个过程的 `EXECUTE`。
2. 不得授予：任何基表的 SELECT/INSERT/UPDATE/DELETE、任何员工侧过程、七个业务角色已有的任何权限。用显式 `GRANT EXECUTE` 还是新建一个角色，待 C 定。
3. 员工侧过程一律按 `USER_NAME()` 映射 `EmployeeAccount`（要求 `ACTIVE`，多数还要求岗位匹配），顾客账户没有这条映射，**必被拒**。因此本节三个过程各自独立守卫，不调用 `sp_create_order` / `sp_register_customer_for_order` / `sp_create_customer` 的员工守卫段；锁库存、定价和状态规则按 B、A 的口径在本节逐条列明，不复制代码却不写规则。
4. 顾客端不建立会话身份，也不新增登录表（计划 §6.1）。每次调用都带 `@mobile`；查单另带 `@pickup_code` 作第二要素。
5. 三个过程都自持事务：`@entry_trancount = 0` 时 `BEGIN TRANSACTION`，否则 `SAVE TRANSACTION`；`SET XACT_ABORT ON`，`CATCH` 内按 `XACT_STATE()` 回滚后 `THROW`。与 `sp_create_order` 同写法。
6. 参数一律走 pyodbc 占位、类型显式指定；不接受任何拼接进来的值。
7. 对象归属：建档进 `sql/stage2/11a_master_migration.sql`（A），下单与查单进 `11b_order_migration.sql`（B），授权进 `sql/stage2/12_permissions.sql`（C）。

### 1.2 `sp_customer_register`

```sql
dbo.sp_customer_register
(
    @mobile        VARCHAR(20),
    @customer_name NVARCHAR(50) = NULL
)
-- 返回单行：customer_id BIGINT, member_level_id BIGINT, is_new BIT
```

约束：

1. `@mobile` 与 `Customer.mobile` 同类型 `VARCHAR(20)`（`01:75`）；NULL、空白或超长按输入错误拒绝。查重与写入都用 `LTRIM(RTRIM(@mobile))`，与 `sp_create_customer` 一致。
2. **幂等**（2026-10-21 定）：手机号已存在时不覆盖、不抛错，返回既有 `customer_id` 与 `is_new = 0`。理由：顾客端页面无法预知自己建过档没有，抛 `51005` 会让老顾客在建档这一步就卡死。手机号枚举风险可接受——查单还需取餐码。
3. 只建 `GUEST`，**不开 `@customer_type` 参数**（2026-10-21 定）。不接受等级、初始积分、`status`、`customer_id` 之类的入参；顾客端不该有能表达它们的入口，少一处可被误用的口子。
4. `current_points = 0`；`member_level_id` 用与 `sp_create_customer`（`04:1398-1410`）**逐字相同**的判据解析：`status = 'ACTIVE' AND threshold_points <= 0`，`ORDER BY threshold_points DESC, member_level_id ASC` 取第一条；解析不到即拒绝建档，不建无等级顾客。
5. `status` 固定写 `ACTIVE`。

### 1.3 `sp_customer_place_order`

```sql
dbo.sp_customer_place_order
(
    @mobile             VARCHAR(20),
    @items_json         NVARCHAR(MAX),
    @fulfillment_method VARCHAR(20) = N'PICKUP',
    @pickup_code        VARCHAR(20) = NULL,
    @order_no           VARCHAR(50) = NULL,
    @ordered_at         DATETIME2(0) = NULL
)
-- 返回单行：order_id BIGINT, order_no VARCHAR(50), pickup_code VARCHAR(20),
--           total_amount DECIMAL(10,2), order_status VARCHAR(20)
```

约束：

1. `@items_json` 与 `sp_create_order` **完全同构**：`[{"product_id":<整数>,"quantity":<整数>}, ...]`。非空数组；每项只允许这两个整数字段；重复顶层商品、套餐父项与其子项同时提交、带价格或 `item_role` 一律拒绝（沿用 `52104`–`52110` 的判据与顺序）。
2. 顾客必须存在且 `ACTIVE`；**不自动建档**（2026-10-21 定），页面先调 §1.2。理由：建档与下单是两个动作，合并后 A 侧的默认等级判据要在两条路径上各实现一次，日后改规则必有一处漏改。手机号未建档时返回 `53001`，由页面引导建档。
3. 商品必须 `ACTIVE`、类型合法、BOM 或套餐组成完整可制作（`52109`、`52110` 及 BOM 检查同口径）。
4. 库存：与 `sp_create_order` 相同的锁库规则——下单一刻按 `UPDLOCK, HOLDLOCK` 锁 `Inventory` 并校验可用量，不足即拒绝。规则文本由 B 在本节补齐，A 不代写。
5. 金额：成交价取 `fn_get_effective_product_price` 同一口径，按当下价写进订单明细快照；不在本过程重算促销规则。
6. `@order_no` 为空时由过程生成；**顾客端不接受顾客提交的单号**，页面上也没有这个输入。长度上限对齐 `SalesOrder.order_no VARCHAR(50)`。
7. `@pickup_code` 为空时由过程生成；顾客自取（`PICKUP`）路径要求取餐码非空——表列可空（`02:35`），非空是过程保证。
8. `@ordered_at` 只允许 `test_%` 主体提供，与 `sp_create_order` 的 `52101` 同规矩。
9. 事务：订单头、订单明细、锁库存一次提交，失败整体回滚；不做跨用户的挂单。

### 1.4 `sp_customer_list_orders`

```sql
dbo.sp_customer_list_orders
(
    @mobile      VARCHAR(20),
    @pickup_code VARCHAR(20)
)
-- 返回订单头，按 ordered_at 倒序：
-- order_id BIGINT, order_no VARCHAR(50), order_status VARCHAR(20),
-- fulfillment_method VARCHAR(20), total_amount DECIMAL(10,2),
-- ordered_at DATETIME2(0), pickup_code VARCHAR(20)
-- 是否附明细结果集：【待定】
```

约束：

1. `@mobile` 与 `@pickup_code` 都是必填，缺一即按输入错误拒绝。匹配条件是「该手机号**且**取餐码相同」，不是二选一。
2. 不返回顾客档案、积分、等级，不返回 `employee_id` 或任何员工资料，不返回其他手机号的订单。
3. 无匹配返回空结果集，不抛「顾客不存在」——避免用一次调用探出手机号是否在建档表里。
4. 只读，不开事务。
5. 明细是否随单返回，【待定】：一个过程返回两个结果集对 pyodbc 可行但要额外约定顺序；建议另开 `sp_customer_list_order_items @order_id, @mobile`，列表接口只回订单头。

### 1.5 错误码与授权

- 错误码：【待 C 登记】建议新增 `530xx` 段，与 A 域 `510xx`、B 域 `52xxx`、C 域 `50000` 分开。拟用：`53000` 参数非法、`53001` 顾客不存在、`53002` 顾客已停用。注意 `511xx` / `519xx` 是验收脚本的断言码，不是业务码。
- 应用层映射（按计划 §6.3 的九类）：`53000 → E_INPUT`、`53001 → E_NOTFOUND`、`53002 → E_RULE`，【待定：确认这三条映射是否合理】。
- 授权：`cust_app` 只持有 §1.2–§1.4 三个过程的 `EXECUTE`，【待 C 确认】；C 在 `12_permissions.sql` 落地并写进部署模板的验收断言（越权直调员工过程应得 229 或 262）。
- 部署侧：§6.1 要求连接串 `pooling=False`，顾客连接不得与员工连接共用池。

### 1.6 待决项（冻结前必须清空）

已由 A 决（2026-10-21，B/C 无异议即随契约冻结，有异议按本表流程改）：

- 重复手机号建档 → **幂等返回**（§1.2 约束 2）。
- 下单时自动建档 → **不做**（§1.3 约束 2）。

| # | 待决 | 建议 | 谁定 |
| --- | --- | --- | --- |
| 1 | 查单是否返回明细、用第二个结果集还是另开过程 | 另开过程，列表只回头 | B |
| 2 | `530xx` 错误码是否可用、三条应用层映射 | 按 §1.5 | C |
| 3 | `cust_app` 的授权主体范围与创建方式 | 只这三个过程；显式 GRANT，不建角色 | C |
| 4 | 取餐码生成规则（格式、唯一范围、重号处理） | —— | B |
| 5 | 下单的库存锁库规则文本 | 与 `sp_create_order` 同，由 B 誊到 §1.3 约束 4 | B |

## 2. 其余域接口（待 2.2 补）

计划 §6.2 表里除顾客端三行外，其余接口（收银选商品、检索顾客、维护主数据、支付列表、后厨叫号、骑手列表、取消退款、库存补货、员工角色等）尚未汇总到本文。补入时每条至少写：对象名、参数名与类型、返回列与可空性、错误码、授权主体、调用方。**在本文冻结前，各域按计划 §6.2 的口径实现，不要把计划里的表格当成已冻结签名。**

## 3. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-21 | 建立本文。只登记 OI-10 的顾客端三个过程（依据计划 §6.1、§6.2、§6.4 与 `open-issues.md` OI-10）；其余接口留空待 2.2。三个过程的签名按现有实物对齐：`Customer.mobile VARCHAR(20)`（`01:75`）、`SalesOrder.order_no VARCHAR(50)` / `pickup_code VARCHAR(20)` / `total_amount DECIMAL(10,2)` / `ordered_at DATETIME2(0)`（`02:31`–`02:37`）、`items_json` 与 `sp_create_order` 同构（`05:111`）、默认等级判据与 `sp_create_customer` 逐字相同（`04:1398-1410`，取不到即 `51001`） |
| 2026-10-21 | A 决两条：§1.2 建档幂等（不抛 `51005`）、不开 `@customer_type`；§1.3 下单不自动建档。§1.6 待决由 7 条减为 5 条（余 B×3、C×2），本文仍未冻结——冻结卡在 §2 其余接口与 §1.6 剩余 5 条 |
