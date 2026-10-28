# 第二阶段跨域接口契约（application-contract）

> 版本：2026-10-28（**§2 定于 2026-11-03 冻结；§1 顾客端三过程仍为草案**）
>
> 用途：2.2 编写迁移前，把各域新增或变更的数据库接口汇总成一份可冻结的签名表。计划 §6.2 的流程是：各域提交准确参数类型、返回列类型/可空性、错误码与授权主体 → A 汇总本文 → C 核对身份与授权 → 冻结 → 各域写进 `11*`，C 写进 `12_permissions.sql`。
>
> 冻结前，本文任何条目都**不是**实现承诺，也不代表对象已存在——`sql/` 里目前没有任何顾客端过程。
>
> 范围：只管第二阶段新增或变更的对象。第一阶段已冻结的 `fn_get_effective_product_price`、`sp_apply_customer_points` 仍以 `docs/stage1/cross-domain-interface-contract.md` 为准，本文不重复、也不修改它们。
>
> 当前进度：§1 登记 OI-10 的顾客端三个过程（B 的三项待决已合入，余四条联合边界见 §1.6）；§2 已合入 B 的写接口签名与新查询提案，并**已按源码逐条核对**（结果见 §2.3），剩 C 侧授权核对与 Common 调用样例。

## 0. 状态口径

| 标记 | 含义 |
| --- | --- |
| 已定 | A 已对照现有实物核对过，可照此实现 |
| 待定 | 还没人拍板；括号内是 A 的建议，采纳前不算数 |
| 待 C 确认 | 需 C 核身份与授权后落定 |
| 待冻结 | 到 2.2 冻结时才生效，冻结前都可改 |

## 1. 顾客端接口（OI-10）

### 1.1 共同前提

1. 调用主体是独立的受限数据库账户 **`cust_app`**（2026-10-21 C 定）：数据库用户由 `sql/stage2/12_permissions.sql` 以 `WITHOUT LOGIN` 创建并授权（与 `08` 的 `test_*` 同法）；服务器登录名与同名映射由部署模板作为独立显式步骤完成，密码不入仓（计划 §5.1「服务器登录名不属于该事务」）。
2. 不得授予：任何基表的 SELECT/INSERT/UPDATE/DELETE、任何员工侧过程、七个业务角色已有的任何权限。**显式 `GRANT EXECUTE`，不建数据库角色**（2026-10-21 C 定）。
3. 员工侧过程一律按 `USER_NAME()` 映射 `EmployeeAccount`（要求 `ACTIVE`，多数还要求岗位匹配），顾客账户没有这条映射，**必被拒**。因此本节三个过程各自独立守卫，不调用 `sp_create_order` / `sp_register_customer_for_order` / `sp_create_customer` 的员工守卫段；锁库存、定价和状态规则按 B、A 的口径在本节逐条列明，不复制代码却不写规则。
4. 顾客端不建立会话身份，也不新增登录表（计划 §6.1）。每次调用都带 `@mobile`；查单另带 `@pickup_code` 作第二要素。
5. **事务边界按写读分开**（2026-10-27 A 定，订正初稿「三个过程都自持事务」与 §1.4 约束 4 的自相矛盾）：§1.2 建档、§1.3 下单是写过程，自持事务——`@entry_trancount = 0` 时 `BEGIN TRANSACTION`，否则 `SAVE TRANSACTION`；`SET XACT_ABORT ON`，`CATCH` 内按 `XACT_STATE()` 回滚后 `THROW`，与 `sp_create_order` 同写法。§1.4 查单是单语句只读，**不显式开启事务**；被外层事务调用时服从外层（默认隔离级别下不加锁提示，不引入 `NOLOCK`）。
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
4. **库存（规则文本 2026-10-24 B 定，2026-10-27 合入）**：在同一外层事务内校验顾客与商品后，调用 A 唯一的 `fn_get_effective_product_price` 取成交价与促销命中，写订单头、`SELLABLE` 父项及 `COMPONENT` 快照（组件数量已含套餐份数、组件零价，不由调用方提供）；随后调用 C 的 `sp_lock_order_inventory @order_id`，**不调用**有员工身份守卫的 `sp_create_order`，B 也不直接更新 `Inventory`。C 按本单「`SELLABLE` 单品 + `COMPONENT` 子项」各自的 BOM 汇总原料需求（套餐父项不再展开一次），检查不存在本单既有 `LOCK`/`RELEASE`/`CONSUME`、拒绝无制作行/缺 BOM/非正用量，以 `UPDLOCK, HOLDLOCK` 锁住所有涉及库存行并要求 `on_hand_qty − locked_qty ≥ required_qty`。成功仅增加 `locked_qty`，**不减** `on_hand_qty`，逐原料写 `LOCK` 流水（`on_hand_delta = 0`、`locked_delta = required_qty`、`reference_type = 'ORDER'`、`reference_id = 本 order_id`）。同一批库存的竞争必须在持锁后校验，不能「先看页面可售量、插单后直接锁」。C 现有锁库过程没有岗位守卫，B 的专用过程可经 `dbo` 所有权链内部调用，但 **`cust_app` 对该过程不得有直接 `EXECUTE`**。
5. 金额：总额仅对 `SELLABLE` 做高精度 `SUM(quantity × unit_price)`，检查可表示范围后写 `DECIMAL(10,2)`，**不得对组件重复计价**。成交价取 `fn_get_effective_product_price` 同一口径，按当下价写进订单明细快照；不在本过程重算促销规则。
6. `@order_no` 由服务端生成，**非 NULL 即拒**（`53000`）：它不是让浏览器决定订单凭据的入口。长度上限对齐 `SalesOrder.order_no VARCHAR(50)`。单号在订单提交成功后随结果返回。
7. `@pickup_code` 由服务端生成，**非 NULL 即拒**（`53000`）。生成式：`UPPER(LEFT(REPLACE(CONVERT(VARCHAR(36), NEWID()), '-', ''), 20))`，格式 `[0-9A-F]{20}`，与现有员工下单「GUID 去连字符截 20 位」同源；不承诺 `NEWID` 具备密码学随机性或完整 80 位独立熵。唯一范围是 `UQ_SalesOrder_pickup_code` 过滤唯一索引中的**全部非 NULL 取餐码**——不只当天、不只未完成单，不得每日重用；最终防重由该索引保证，**不能只先 `SELECT` 查重**。出现 `2627`/`2601` 时整笔回滚并返回 `E_CONFLICT`，当前不承诺过程自动重试。
8. `@fulfillment_method` 本轮**只开放 `PICKUP`**（2026-10-27 A 定，采纳 B 的收敛建议）：既有 `CHECK` 要求 `DELIVERY` 订单 `pickup_code` 为 `NULL`，而顾客查单固定要求非 NULL 取餐码，两个约束无法同时满足，外送顾客因此无法按同一双要素查单。传 `DELIVERY` 或任何非 `PICKUP` 值一律 `53000` 拒绝；员工侧外送流程不变。若日后必须开放顾客外送，先冻结独立查询凭据或经确认的「手机号 + 订单号」协议，**不得**把外送码硬塞进 `pickup_code` 违反现有 `CHECK`。
9. `@ordered_at` 正常顾客调用必须为 `NULL`（不从浏览器传历史时间、不借此冒充 `test_%`）；生产取当前数据库时间，与 `sp_create_order` 的 `52101` 同规矩。
10. 顾客下单**不得**顺便支付、制作、实扣或生效积分。任何定价、插入或锁库失败，订单头、父子明细、库存锁与流水一并回滚；C 的嵌套保存点不提交 B 的外层，不可提交事务由最外层完整回滚。C 的原错误 `50000` 保留到后端日志，前端按 `E_RULE` 映射。不做跨用户的挂单。

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
-- 返回列 2026-10-21 经 C 确认：只回订单头，不含顾客档案与员工资料
-- 明细不随单返回：只有一个结果集（2026-10-24 B 定，见约束 5）
```

约束：

1. `@mobile` 与 `@pickup_code` 都是必填，缺一即按输入错误拒绝（`53000`）。匹配条件是「该手机号**且**取餐码相同」，不是二选一。
2. `@pickup_code` 先 `TRIM` 再要求恰好 20 位十六进制并转大写；`@mobile` 先 `TRIM` 再精确匹配。**缺失或格式非法为 `53000`；格式合法但不匹配返回空集合**，不是错误。全部走 SQL 参数绑定，**不做模糊前缀查询**。
3. 不返回顾客档案、积分、等级，不返回 `employee_id` 或任何员工资料，不返回其他手机号的订单。内部只读过滤同时限定手机号、有效取餐码与顾客 `status = 'ACTIVE'`；**停用顾客的查询同样返回空集合**，不另抛 `53002`。
4. 无匹配返回空结果集，不抛「顾客不存在」——避免用一次调用探出手机号是否在建档表里。
5. 只读，不开事务（见 §1.1 约束 5）；不加 `NOLOCK`。
6. **只有一个结果集，不附明细**（2026-10-24 B 定，2026-10-27 合入）：订单头已足以支持本轮查状态/金额/取餐码，且保持 C 已确认的「仅三个 `EXECUTE`」最小授权。**不新增第四个顾客过程**——草案里的 `sp_customer_list_order_items @order_id, @mobile` 不采纳：手机号加可枚举的订单 ID 不构成已同意的「手机号 + 取餐码」双要素，另加过程还需 C 扩大授权，不能算 B 单方面的小改动。若日后确需明细，应在同一过程内增加第二结果集，或另开同样必须携带双要素的受限接口，并重新冻结返回列与权限；**不列入当前交付**。
7. 取餐码**不写入**通用访问日志、错误响应、URL 查询参数或其他顾客列表；表单用 `POST` 或同等避免 URL 泄漏的请求方式。该双要素是课程方案，**不等于**完整顾客身份认证，也不为顾客加登录表。

### 1.5 错误码与授权

- 错误码（**2026-10-21 C 定**）：新增 `530xx` 段，与 A 域 `510xx`、B 域 `52xxx`、C 域 `50000` 分开——`53000` 参数非法、`53001` 顾客不存在、`53002` 顾客已停用。C 已按源码复核段位：A 域过程 `04` 恰为 `51000–51005`、B 域 `05` 全 `52xxx`、C 域过程 `06` 统一 `50000`；`511xx` / `519xx` 仅见 `10c` / `10a` 断言脚本，不是业务码；`09c` / `09d` 的部署期守卫码同为 `510xx`，不进应用调用路径，映射按「产生错误的对象」适用。
- 应用层映射（按计划 §6.3 的九类，**2026-10-21 C 定**）：`53000 → E_INPUT`、`53001 → E_NOTFOUND`、`53002 → E_RULE`，与 §6.3 对 `51001` / `51002` 的口径一致。取餐码撞号产生的 `2627` / `2601` 按 §6.3 既有口径映射为 `E_CONFLICT`（不是新码）。`53002` 仍保留给「顾客已停用」的写路径（下单时顾客 `status ≠ 'ACTIVE'`）；查单路径不抛它，见 §1.4 约束 3。
- 授权（**2026-10-21 C 定**）：`cust_app` 只持有 §1.2–§1.4 三个过程的 `EXECUTE`，显式 GRANT、不建角色。C 在 `12_permissions.sql` 落地，越权验收断言为 `EXECUTE AS USER = 'cust_app'` 直调员工过程与基表 SELECT 均须 **229**。
- 部署侧：§6.1 要求连接串 `pooling=False`，顾客连接不得与员工连接共用池。

### 1.6 待决项（冻结前必须清空）

已决（无异议即随契约冻结，有异议按本表流程改）：

- 2026-10-21 **A 决**：重复手机号建档 → **幂等返回**（§1.2 约束 2）；下单时自动建档 → **不做**（§1.3 约束 2）。
- 2026-10-21 **C 决**：`530xx` 错误码与三条应用层映射（§1.5）；`cust_app` 只授三个过程的 `EXECUTE`、显式 GRANT 不建角色、`WITHOUT LOGIN` 建用户（§1.1、§1.5）。建档幂等的手机号可枚举风险 C 无异议（查单需取餐码，课程范围内接受；应用层可限流，非契约项）。
- 2026-10-24 **B 决**（2026-10-27 合入）：查单**只回订单头、一个结果集、不新增第四个过程**（§1.4 约束 6）；取餐码生成式、唯一范围与撞号处理（§1.3 约束 7）；锁库规则文本（§1.3 约束 4）；`@pickup_code` / `@order_no` 非 NULL 即拒 `53000`（§1.3 约束 6、7）。
- 2026-10-27 **A 决**：采纳 B 的收敛建议，**顾客端本轮只开放 `PICKUP`**，非 `PICKUP` 的履约方式按 `53000` 拒绝（§1.3 约束 8）；事务边界按写读分开（§1.1 约束 5）。外送凭据等若日后要开，另走冻结流程。

原三条 B 待决项就此清空。**但这不是「OI-10 全条关闭」**——下列联合问题仍在共同冻结前必须处理：

| # | 仍未定 | 事实 | 谁定 |
| --- | --- | --- | --- |
| 1 | 顾客外送的查询凭据 | 本轮以「只开 `PICKUP`」绕开，未解决；顾客页范围需 C 核（§1.3 约束 8） | A + C |
| 2 | 下单结果未知（响应丢失） | 服务端生成单号与取餐码，响应丢失时浏览器既无号也无码。**不照搬**员工按已知 `order_no` 恢复，本轮无可靠幂等恢复协议、不自动重下；若需恢复，另冻受限请求标识协议，不临时扩大授权 | A + B + C |
| 3 | 服务端员工凭据生命周期 | 计划只按请求保存密码，但下一个 Flask 请求仍需该员工 SQL 身份。须先冻结安全重认证或服务端短期凭据方案；**不得**把密码存客户端 cookie/session 或日志，身份不可用时必须失败，**不能退回 `dbo`** | A + C |
| 4 | `cust_app` 登录映射 | 保持为 C 的部署责任（`WITHOUT LOGIN` 建用户 + 部署模板补映射），B 只定义业务调用，不执行映射或改模式 | C |

## 2. 其余域接口

计划 §6.2 表里除顾客端三行外，其余接口由 B 的 [`b-interface-handoff.md`](b-interface-handoff.md) 于 2026-10-14 交出，2026-10-27 由 A 合入本节。**2026-10-28：本节复核完毕**——§2.1 的 8 个签名、岗位守卫与错误码分段逐条对过源码（见 §2.3），C 另从授权侧核了 55 项；§2.2 的 6 个查询在仓库中尚无对应过程，表中列名与类型已按 `01` / `02` 核过。

**§2 冻结日 2026-11-03**（OI-03）：签名、参数与返回列自此不再改动，`11b` 按本版写；§2.2 的实现归 B，**未实现前应用层不得调用**。冻结后若仍要改，须三人联合决定并记入 §3 变更记录，不在脚本里就地改签名。

### 2.1 现有写接口（8 个，第一阶段已部署，**本轮不改签名**）

通用口径：**无 OUTPUT 参数、无业务结果集**，过程里的 `SELECT` 只作内部赋值，不能当返回契约；没有可供调用方识别新订单的业务 `RETURN` 值；受 `NOCOUNT` 影响的 `ExecuteNonQuery` 行数**不能**作为成功判据。正常完成仅表示过程未抛错，若使用外层事务，业务最终成功还要求外层提交。断线或超时一律视为**结果未知**。

| 过程 | 参数 | 岗位守卫 | 变更结果 |
| --- | --- | --- | --- |
| `sp_create_order` | `@customer_id BIGINT`、`@fulfillment_method VARCHAR(20)`、`@order_no VARCHAR(50)`、`@items_json NVARCHAR(MAX)`、`@ordered_at DATETIME2(0) = NULL` | CASHIER | 订单、价格与组件快照、总额、库存锁 |
| `sp_pay_order` | `@order_id BIGINT`、`@payment_method VARCHAR(20)`、`@paid_amount DECIMAL(10,2)`、`@third_party_txn_no VARCHAR(100)` | CASHIER | 支付、`PAID`、`PENDING` 积分 |
| `sp_start_production` | `@order_id BIGINT` | CHEF | `IN_PRODUCTION` 与开始时间 |
| `sp_finish_production` | `@order_id BIGINT` | PACKER | 实扣、待取 / 待配送、外送 `WAITING_PICKUP` |
| `sp_pick_up_order` | `@order_id BIGINT` | PACKER | `PICKED_UP`、积分生效并给顾客入账 |
| `sp_pick_up_delivery` | `@order_id BIGINT`、`@rider_employee_id BIGINT` | RIDER | 认领与 `DELIVERING` |
| `sp_confirm_delivery` | `@order_id BIGINT` | RIDER | `COMPLETED` / `DELIVERED`、积分入账 |
| `sp_cancel_or_refund_order` | `@order_id BIGINT`、`@reason VARCHAR(20)`、`@operator_employee_id BIGINT` | STORE_MANAGER | 取消、实扣前全额退款、释放锁、积分作废、审计 |

调用细则：

1. 岗位还须 C 授予 `EXECUTE`；数据库按 `USER_NAME()` 验证**启用**员工与 `job_code`，参数里的员工 ID 不能替代真实身份。
2. `@ordered_at` 只有 `sp_create_order` 有默认 `NULL`，正常应用省略；非 `test_*` 主体显式传时间会被 `52101` 拒绝。
3. `sp_create_order` 的 `@order_no` **必须由调用方在请求前生成并保存**，重试不得临时换号掩盖结果未知；`@items_json` 只能是含整数 `product_id` / `quantity` 的非空对象数组，不能传角色、价格、父项或组件。
4. `sp_pay_order` 的 `@third_party_txn_no` 可传 `NULL` 但**没有默认值**，pyodbc 必须显式传 `None`；`@paid_amount` 用 `Decimal` 并以 `DECIMAL(10,2)` 绑定，不用 float；`@payment_method` 目前只校验非空白，**不能**宣称已有 `CASH` / 扫码的枚举白名单。
5. `sp_pick_up_delivery` 的 `@rider_employee_id` 必须等于当前身份上下文，不能替其他骑手代认领。
6. `sp_cancel_or_refund_order` 的 `@operator_employee_id` 来自真实店长上下文；未付用 `CANCEL` / `PAYMENT_TIMEOUT`，已付未实扣只有 `REFUND`；**没有**部分退款或交付后退款接口。

错误码：B 域统一 `52100`（岗位不符），其余按过程分段——下单 `52101`–`52114`、支付 `52201`–`52206`、制作 `52301`、完成 `52401`、取餐 `52501`–`52502`、认领 `52601`–`52603`、送达 `52701`–`52702`、取消退款 `52801`–`52806`。**`52502` 由 `sp_pick_up_order` 与 `sp_confirm_delivery` 共用**（两者都要过同一段积分终态校验），因此它不属于「取餐」一个过程，应用层按码映射时不能把它当取餐专属（2026-10-27 C 核对 `sql/05` 后指出，A 复核确认：`sp_confirm_delivery` 的 `THROW` 集为 `52100` / `52502` / `52701` / `52702`）。外域错误**原样保留**（C 库存不足当前是 `50000`，A 的积分入账抛其自身编号；`2601` / `2627` 可能来自唯一键、`547` 来自完整性约束）。应用层**不得**把所有未知错误归成「库存不足」，按 §1.5 的映射规则与计划 §6.3 的九类处理。

### 2.2 新增查询提案（6 个，**尚未实现**，接口 2026-11-03 冻结）

类型标注中 `?` 表示可空输出，其余非空。所有结果按稳定键排序，**不 `SELECT *`**，参数必须绑定；无结果返回空集合，但权限 / 身份错误必须抛错，**不能冒充空集合**。队列类查询新增 `@take INT = 100`（取值 1..200）限定单次结果。**分页协议已定（A，2026-10-28）**：本轮**不做** offset / keyset 翻页，调用方循环拉取、在「本次返回行数 < `@take`」时停止；两次拉取之间状态可能变化，写过程会再校验，不靠客户端翻页保证一致。`@take` 越界按参数错误拒绝，**不静默截断到 200**——静默截断会让调用方误以为已取完（具体码位归 B 的 `52xxx` 分段，B 落地时给号）。

| 查询 | 参数 | 岗位与过滤 | 返回结果 |
| --- | --- | --- | --- |
| `sp_list_orders_for_payment` | `@take INT = 100` | CASHIER；仅 `PENDING_PAYMENT`；按 `ordered_at, order_id` 升序 | RS1：`order_id BIGINT`、`order_no VARCHAR(50)`、`total_amount DECIMAL(10,2)`、`ordered_at DATETIME2(0)` |
| `sp_get_order_for_payment` | `@order_id BIGINT` | CASHIER；仅 `PENDING_PAYMENT`，不存在或状态已变须明确失败 | RS1：同上加 `fulfillment_method VARCHAR(20)`；RS2：`order_item_id BIGINT`、`product_id BIGINT`、`product_name NVARCHAR(50)`、`quantity INT`、`unit_price DECIMAL(10,2)`、`promotion_id BIGINT?`，仅 `SELLABLE`，按 `order_item_id` |
| `sp_get_order_operation_status` | `@order_id BIGINT = NULL`、`@order_no VARCHAR(50) = NULL`，**恰好一个非 NULL**（B 建议扩展，2026-10-27 A 接受，见 §2.3） | CASHIER / STORE_MANAGER；全状态，精确单订单定位，不返回顾客资料 | RS1：`order_id BIGINT`、`order_no VARCHAR(50)`、`order_status VARCHAR(20)`、`payment_status VARCHAR(20)?`、`paid_amount DECIMAL(10,2)?`、`refunded_amount DECIMAL(10,2)?`、`is_completed BIT`、`pickup_code VARCHAR(20)?`；付款列 `LEFT JOIN`，不把无支付转成 0 |
| `sp_list_orders_for_packing` | `@take INT = 100` | PACKER；`IN_PRODUCTION` / `READY_FOR_PICKUP`，按 `ordered_at, order_id` | RS1：`order_id BIGINT`、`order_no VARCHAR(50)`、`order_status VARCHAR(20)`、`fulfillment_method VARCHAR(20)`、`pickup_code VARCHAR(20)?`；RS2：`order_id BIGINT`、`order_item_id BIGINT`、`parent_order_item_id BIGINT?`、`item_role VARCHAR(20)`、`product_id BIGINT`、`product_name NVARCHAR(50)`、`quantity INT`；只含 RS1 所选订单 |
| `sp_list_my_deliveries` | `@take INT = 100` | 当前启用 RIDER；仅 `rider_employee_id = 自身` 且 `DELIVERING`；按 `picked_up_at, delivery_id` 升序 | RS1：`delivery_id BIGINT`、`order_id BIGINT`、`order_no VARCHAR(50)`、`delivery_status VARCHAR(20)`、`picked_up_at DATETIME2(0)?` |
| `sp_list_deliveries_available_for_pickup` | `@take INT = 100` | 当前启用 RIDER；订单 `READY_FOR_DELIVERY` 且配送 `WAITING_PICKUP`、骑手 `NULL`；按 `production_finished_at, order_id` 升序 | RS1：`delivery_id BIGINT`、`order_id BIGINT`、`order_no VARCHAR(50)`、`production_finished_at DATETIME2(0)?`；不含顾客与金额 |

两条附加规则：配餐查询的 `@take` 限的是**订单数**而非明细数，RS2 必须返回所选订单的**全部**明细，不能把套餐截断；制作项显示须区分套餐父项与组件，**不能**把两者数量相加当原料需求。两结果集查询必须在数据库内取得一致的订单键集合——状态可能在展示后变化，写过程会再验证，**不依赖页面缓存**判断可操作性。

**下单结果确认缺口**：现有 `sp_create_order` 不返回 `order_id`，而计划的状态查询只接收 `order_id`，新下单的客户端在响应丢失时可能既无号也不知 ID。建议把「按精确 `order_no` 查询」纳入上表同名状态过程（即第 3 行的参数扩展），沿用已有唯一订单号，避免为了拿 ID 给收银开放完整详情视图或基表。这是**待冻结的参数扩展，不是本轮新增实现**。读到无记录**仍不证明**旧请求不会提交：超时后先终止并释放旧调用、确认其事务结束，再按相同订单号重试；唯一约束是最终防重兜底，**结果未知时不得换号重下**。

**权限边界**：`v_kitchen_queue` 给 CHEF、`v_pickup_board` 给 WAITER，店长按已有授权用 `v_order_detail` 选单取消/退款；`v_customer_point_ledger` **不是**收银支付页的数据源。视图精确授权以 `08` 为事实，**不因视图存在就授予所有岗位**。商品与顾客检索/注册调用 A 的接口，B 不复制定价或建会员规则；身份来自 C 的上下文，B 不实现登录、不自行 `EXECUTE AS`。

### 2.3 冻结前核对结果（A，2026-10-27）

已按源码逐条核对 `sql/05`，结论如下——**§2.1 / §2.2 的文本与源码一致，无订正**：

| 核对项 | 方法 | 结论 |
| --- | --- | --- |
| 8 个写过程的参数名与类型 | 对照 `05:111`、`05:264`、`05:338`、`05:389`、`05:444`、`05:503`、`05:563`、`05:628` | 与 §2.1 表逐字一致；只有 `sp_create_order.@ordered_at` 有默认 `NULL` |
| 岗位守卫 | 查各过程 `database_user_name = USER_NAME() AND status = 'ACTIVE' AND job_code = ...` | 8 个过程逐个对应 CASHIER / CASHIER / CHEF / PACKER / PACKER / RIDER / RIDER / STORE_MANAGER，与表中「岗位守卫」列一致 |
| 错误码分布 | 抓 `05` 全部 `THROW 52xxx` | `52100`（岗位）+ `52101–52114` / `52201–52206` / `52301` / `52401` / `52501–52502` / `52601–52603` / `52701–52702` / `52801–52806`，与 §2.1 所列分段完全吻合，**无遗漏也无未登记码** |
| 6 个查询提案引用的列 | 对照 `02:29`–`02:87`、`01:45`–`01:46` | 全部存在且类型一致：`order_no VARCHAR(50)`、`pickup_code VARCHAR(20) NULL`、`total_amount DECIMAL(10,2)`、`ordered_at` / `production_finished_at` / `picked_up_at` 均 `DATETIME2(0)`，`refunded_amount DECIMAL(10,2)` 非空而 `LEFT JOIN` 输出可空、`product_name NVARCHAR(50)` |
| 取餐码唯一范围 | 查 `05:91`–`92` | `UQ_SalesOrder_pickup_code` 是 `WHERE pickup_code IS NOT NULL` 的过滤唯一索引，与 §1.3 约束 7 的「全部非 NULL 值」一致 |
| 顾客下单的锁库衔接 | 查 `05:241` | `sp_create_order` 同样只调 `dbo.sp_lock_order_inventory @order_id`，不自行改库存——§1.3 约束 4 与其同源 |

A 已定的两项：

- **接受按 `order_no` 定位**（§2.2 第 3 行的参数扩展）。它用已有唯一订单号补上「`sp_create_order` 不返回 `order_id`」的缺口，避免为此给收银开放 `v_order_detail` 或基表；过程仍按岗位守卫、仍不返回顾客资料。
- **`@take INT = 100`（1..200）作为数据库侧分页口径**（2026-10-28 定稿，见 §2.2 段首）。它限的是订单数而非明细数；**页面层的翻页形状仍可在 2.3 调整，但不得改签名与 `@take` 语义**。

仍待处理：

- [x] **C 侧并行核对**：已完成（2026-10-27，8 个写过程的岗位守卫、`08` GRANT、`06` 白名单、`09c` 种子与 `52xxx` 分段 55 PASS / 0 FAIL，证据 `result/stage2/c-contract-auth-check-2026-10-27.txt`）；核对顺带补出的 `52502` 共用码已写进 §2.1。
- [ ] **Common 层调用样例**：8 个写过程无业务结果集、无 `RETURN` 值，成功判据只能是「未抛错 + 外层提交」，样例须按此写，不能拿 `ExecuteNonQuery` 行数当判据。属 2.3，不阻塞 §2 冻结。
- [ ] §1.6 表里的 4 条联合边界（属 §1 顾客端，不阻塞 §2 冻结）。

## 3. 变更记录

| 日期 | 变更 |
| --- | --- |
| 2026-10-21 | 建立本文。只登记 OI-10 的顾客端三个过程（依据计划 §6.1、§6.2、§6.4 与 `open-issues.md` OI-10）；其余接口留空待 2.2。三个过程的签名按现有实物对齐：`Customer.mobile VARCHAR(20)`（`01:75`）、`SalesOrder.order_no VARCHAR(50)` / `pickup_code VARCHAR(20)` / `total_amount DECIMAL(10,2)` / `ordered_at DATETIME2(0)`（`02:31`–`02:37`）、`items_json` 与 `sp_create_order` 同构（`05:111`）、默认等级判据与 `sp_create_customer` 逐字相同（`04:1398-1410`，取不到即 `51001`） |
| 2026-10-21 | A 决两条：§1.2 建档幂等（不抛 `51005`）、不开 `@customer_type`；§1.3 下单不自动建档。§1.6 待决由 7 条减为 5 条（余 B×3、C×2），本文仍未冻结——冻结卡在 §2 其余接口与 §1.6 剩余 5 条 |
| 2026-10-22 | 同步 C 于 10-21 的决定：§1.5 登记 `530xx` 三码与三条应用层映射；§1.1 / §1.5 落定 `cust_app` 的授权范围、`WITHOUT LOGIN` 建用户与部署侧登录映射、越权断言 `229`；§1.4 返回列经 C 确认只回订单头。§1.6 待决由 5 条减为 **3 条（全在 B：明细、取餐码规则、锁库规则文本）**；本文仍未冻结，冻结卡在 §2 其余接口与 §1.6 剩余 3 条 |
| 2026-10-27 | 合入 B 的 `b-contract-decisions.md` §2–§4：§1.3 约束 4 换为完整锁库规则、约束 6/7 补服务端生成与 `53000` 拒绝、约束 10 补「不顺便支付/整体回滚」；§1.4 约束 2/3/6/7 补匹配口径、停用空集、只回订单头与取餐码不外泄。**订正自相矛盾**：§1.1 约束 5 改为写过程自持事务、查单不显式开事务。新增 §1.3 约束 8 **本轮只开放 `PICKUP`**（A 决，采纳 B 收敛建议；`DELIVERY` 的 `pickup_code` 必须为 `NULL` 与查单要求非空相冲突）。§1.5 补 `2627`/`2601 → E_CONFLICT` 与 `53002` 的适用范围。§1.6 原 3 条 B 待决清空，另列 4 条仍需 A/C 或三方联定的问题（外送凭据、结果未知恢复、员工凭据生命周期、登录映射）。同日并入 `b-interface-handoff.md`：§2 原「待 2.2 补」改为 §2.1 八个现有写接口（参数、岗位守卫、变更结果、`52100`/`52xxx` 分段错误码、无业务结果集与结果未知口径）、§2.2 六个新查询提案（`@take` 限订单数、两结果集一致键集、按 `order_no` 定位的参数扩展）、§2.3 冻结前 A 的核对清单；仅 `05:111`/`05:264`/`05:389`/`05:503`/`05:628` 五处签名经抽查核对。同日 A 完成 §2.3 全量核对：8 个过程签名、岗位守卫、`52xxx` 错误码分布与 6 个查询提案引用的列**全部与源码一致，无订正**；A 定两项——接受 `sp_get_order_operation_status` 按 `order_no` 定位的参数扩展，`@take INT = 100`（1..200）作临时分页口径。**仍未冻结**：卡在 C 侧授权核对、Common 调用样例与 §1.6 表 |
| 2026-10-28 | **定 2.2 冻结日 2026-11-03（OI-03，A 提议、待 B/C 回执）并冻结 §2**：§2 头部改为「已复核完毕」，§2.2 标题去掉「待冻结」；分页协议定稿（`@take` 1..200，**不做** offset / keyset 翻页，调用方在「返回行数 < `@take`」时停止，越界拒绝而不静默截断到 200，具体码位归 B 的 `52xxx`）；§2.3 的 C 侧核对勾掉（10-27 已 55 PASS），Common 调用样例与 §1.6 四条边界注明属 2.3 / §1，不阻塞 §2 冻结。冻结后改签名须三人联定并记入本节 |
