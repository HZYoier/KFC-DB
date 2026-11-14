# 第三阶段销售与折扣语义（冻结）

> 属主：A。适用于第三阶段全部统计对象：`v_settled_sales_line`、`fn_product_sales_summary`、`sp_sales_report`、窗口函数查询与订单完成校验。
> 状态：**2026-11-12 冻结**。B/C 的实现、测试与报告以本文为准；要改口径，先改本文并在 §6 登记，再改代码与断言，不得在单个查询里另立规则。
> 依据：`docs/stage3/three-person-implementation-plan.md` §4—§7、`docs/数据边界清单.md`、`sql/stage1/02_order_schema.sql`、`sql/stage1/05_order_constraints_crud.sql`、`sql/stage2/11b_order_migration.sql`。

## 0. 冻结记录

| 编号 | 冻结项 | 决定 | 直接影响 |
| --- | --- | --- | --- |
| F-01 | v1.1 的改法 | **只加不删**：新增 `InventoryAudit` 表；`SalesOrderItem` 增加 `discount_rate DECIMAL(5,4)`、`discount_amount DECIMAL(10,2)`；不重写存量行、不删对象 | `20_schema_v1_1.sql`、两处 `ALTER PROCEDURE`、`13c` 权限计数 |
| F-02 | 已结算销售口径 | 只看**终态**订单：自取 `PICKED_UP`、外送 `COMPLETED`；以 `completed_at` 落在统计区间为准；只算 `SELLABLE` 明细；金额用折后净额 | `21b` 的视图、`21a` 的汇总函数、全部窗口查询 |
| F-03 | 折扣政策 | 会员等级折扣 + 满 100 减 0.02，下限 0.90；折扣额四舍五入到分；订单级折扣按行毛额比例分摊，分位残差给毛额最大行 | `fn_calculate_discount`、`sp_create_order`、`sp_customer_place_order`、订单完成触发器 |
| F-04 | 权限计数 | `13c` 的 58 个权限码 / 71 行授权改为按 `SchemaVersion` 取常量；v1.1 追加 12 个新码与 19 行授权，断言条数仍为 38 | `27_permissions.sql`、`13c`、`verify_stage3.sql` |

**F-01 的边界：** 折扣两列只对 v1.1 之后新生成的订单写入；v1.0 存量订单的 `discount_amount` 一律为 0，不回填、不推测历史折扣。

**F-02 的口径来源：** 自取订单由 `sp_pick_up_order` 置为 `PICKED_UP` 并写 `completed_at`；外送订单由 `sp_confirm_delivery` 置为 `COMPLETED` 并写 `completed_at`。因此"已完成"不是单一状态值，任何只筛 `COMPLETED` 的统计都会漏掉全部自取订单。

## 1. 已结算销售口径

### 1.1 共享视图 `v_settled_sales_line`

由 B 在 `sql/stage3/21b_order_programmability.sql` 创建，是第三阶段唯一的销售事实入口。A 的函数、B 的报表过程、A/B 的窗口查询都读它，**不得各自拼接订单明细**。

| 列 | 类型 | 含义 |
| --- | --- | --- |
| `order_id` | `BIGINT` | 订单主键 |
| `order_no` | `VARCHAR(50)` | 订单号 |
| `completed_at` | `DATETIME2(0)` | 完成时间，取自 `SalesOrder.completed_at` |
| `product_id` | `BIGINT` | 商品主键 |
| `product_name` | `NVARCHAR(100)` | 商品名称快照（当前取 `Product.product_name`） |
| `category_id` | `BIGINT` | 商品分类 |
| `quantity` | `INT` | 售出数量 |
| `gross_amount` | `DECIMAL(12,2)` | 行毛额 `ROUND(unit_price * quantity, 2)` |
| `discount_amount` | `DECIMAL(12,2)` | 行折扣额，来自 `SalesOrderItem.discount_amount` |
| `net_amount` | `DECIMAL(12,2)` | 行净额 `gross_amount - discount_amount` |

视图过滤条件（全部 AND）：

1. `o.order_status IN ('PICKED_UP', 'COMPLETED')`；
2. `o.completed_at IS NOT NULL`；
3. `i.item_role = 'SELLABLE'`；
4. `i.quantity > 0`。

套餐父行是 `SELLABLE`，按父行成交价计入；`COMPONENT` 子行价格恒为 0，**排除**，否则会虚增订单数与商品数。

### 1.2 日期区间

统计区间参数统一为闭区间 `[@start_date, @end_date]`（`DATE`），落到谓词上是半开区间：

```sql
l.completed_at >= @start_date
AND l.completed_at < DATEADD(DAY, 1, @end_date)
```

- 包含 `@end_date` 当天 00:00:00—23:59:59 的全部完成订单；
- `@start_date` 或 `@end_date` 为 `NULL`、或 `@start_date > @end_date` 时，函数返回空结果集，**不报错、不返回全表**；
- 不使用 `CONVERT(DATE, completed_at)` 之类列上运算，避免无法走索引。

### 1.3 聚合口径

| 指标 | 定义 |
| --- | --- |
| `sold_qty` | `SUM(quantity)` |
| `sales_amount` | `SUM(net_amount)`，即折后实收，不是毛额 |
| `order_count` | `COUNT(DISTINCT order_id)`，一个订单买同一商品多行只算一单 |

毛利、成本、客单价不在本阶段口径内；需要时另开指标，不复用 `sales_amount` 的名字。

## 2. 折扣政策

### 2.1 订单级折扣函数

`fn_calculate_discount(@customer_id BIGINT, @order_amount DECIMAL(10,2), @category_id BIGINT = NULL)` 返回单行 `(discount_rate DECIMAL(5,4), discount_amount DECIMAL(10,2))`。

计算顺序：

1. 顾客不存在、`Customer.status <> 'ACTIVE'`、会员等级不存在或 `MemberLevel.status <> 'ACTIVE'` → 基准率 `1.0000`；
2. 否则按 `MemberLevel.level_name` 取基准率：`金卡会员` 0.9500、`银卡会员` 0.9800、其他（含 `普通会员`）1.0000；
3. `@order_amount >= 100.00` 时基准率再减 0.0200；
4. 结果低于 0.9000 时取 0.9000（下限）；
5. `discount_amount = ROUND(@order_amount * (1.0000 - rate), 2)`；
6. `@order_amount` 为 `NULL` 或 `<= 0` 时返回 `1.0000 / 0.00`。

**禁止按会员等级主键硬编码。** 等级主键在不同环境可能不同，只认 `level_name`；改名或新增等级时先改本节。

### 2.2 典型取值

| 顾客 | 订单金额 | 基准率 | 满减后 | 折扣率 | 折扣额 |
| --- | --- | --- | --- | --- | --- |
| 普通会员 / 散客 / 未知 ID | 50.00 | 1.0000 | — | 1.0000 | 0.00 |
| 普通会员 / 散客 / 未知 ID | 100.00 | 1.0000 | 0.9800 | 0.9800 | 2.00 |
| 银卡会员 | 50.00 | 0.9800 | — | 0.9800 | 1.00 |
| 金卡会员 | 50.00 | 0.9500 | — | 0.9500 | 2.50 |
| 银卡会员 | 100.00 | 0.9800 | 0.9600 | 0.9600 | 4.00 |
| 金卡会员 | 100.00 | 0.9500 | 0.9300 | 0.9300 | 7.00 |
| 金卡会员 | 1000.00 | 0.9500 | 0.9300 | 0.9300 | 70.00 |

下限 0.9000 在当前等级表下不会触发（最低 0.9300），保留为未来新增更低折扣等级时的护栏。

### 2.3 `@category_id` 的现状

参数为后续"按品类折扣"预留，**当前不参与计算**。测试必须显式断言"传任意分类与传 NULL 结果相同"，防止有人悄悄加规则却不改本文。

表值函数不能省略带默认值的实参，所有调用一律写满三个参数（第三位传 `NULL` 或 `DEFAULT`），只传两个会报 Msg 313。

### 2.4 落库与行分摊

订单生成时（`sp_create_order`、`sp_customer_place_order`）执行一次：

1. 先算订单毛额 `@gross = SUM(ROUND(unit_price * quantity, 2))`（只含 `SELLABLE` 行）；
2. 调 `fn_calculate_discount` 得订单级 `(@rate, @discount)`；
3. 每行写 `discount_rate = @rate`；
4. 每行折扣额按行毛额比例分摊：

   ```text
   line_discount_i = ROUND(@discount * line_gross_i / @gross, 2)
   ```

5. 分摊后各行之和不等于 `@discount` 时，差额（正负皆可，通常为 ±0.01）加到**毛额最大**的那一行；毛额相同取 `order_item_id` 最小者；
6. `COMPONENT` 子行 `discount_rate = 0`、`discount_amount = 0`；
7. 订单 `total_amount = @gross - @discount`，与明细净额之和一致。

**强不变量（测试必断言）：**

```text
SUM(SalesOrderItem.discount_amount) = fn_calculate_discount(...).discount_amount
SUM(ROUND(unit_price * quantity, 2) - discount_amount) = SalesOrder.total_amount
```

金额列一律 `DECIMAL`，不得用 `FLOAT`；比较用精确相等，容差只允许出现在"四舍五入到分"的说明里，不写进断言。

## 3. 对第三阶段对象的影响

| 对象 | 属主 | 用法 |
| --- | --- | --- |
| `v_settled_sales_line` | B | 本文 §1 的唯一实现；先于 `21a` 创建 |
| `fn_product_sales_summary` | A | 直接聚合视图，不改过滤条件；日期参数按 §1.2 |
| `sp_sales_report` | B | 汇总与明细都必须来自视图；不得再写一套状态过滤 |
| `23a/23b` 窗口查询 | A/B | 排名、累计、移动平均的输入行集合同样来自视图 |
| `tr_SalesOrder_Complete_Check` | B | 校验 `total_amount` 时按 §2.4 的净额口径，不要求等于毛额 |
| `13c` / `28a` 回归 | A/C | 金额断言以本文 §2.2、§2.4 为准 |

## 4. 明确不做的事

- 不建订单级折扣表，不存"折扣原因"多行记录；一单一率的快照够本阶段用。
- 不做优惠券、积分抵现、跨品类满减；`promotion_id` 管的是商品促销价，与会员折扣叠加时以成交价 `unit_price` 为毛额基数，**不二次打折**。
- 不回填 v1.0 订单的折扣列，不修改历史 `total_amount`。
- 不在 Python/Flask 里重算折扣率或销售额；应用层只展示数据库返回值。

## 5. 测试锚点

| 编号 | 断言 |
| --- | --- |
| S-01 | 普通会员、散客、未知 `customer_id`、`NULL` 顾客在 50.00 时为 `1.0000 / 0.00`，在 100.00 时为 `0.9800 / 2.00`（满减对无等级顾客同样生效） |
| S-02 | 银卡 50.00 → `0.9800 / 1.00`；金卡 50.00 → `0.9500 / 2.50` |
| S-03 | 银卡 100.00 → `0.9600 / 4.00`；金卡 100.00 → `0.9300 / 7.00`（边界含等于） |
| S-04 | `NULL`、0、负数金额 → `1.0000 / 0.00`；任何输入折扣率不低于 0.9000 |
| S-05 | `@category_id` 传值与传 `NULL` 结果完全一致 |
| S-06 | 汇总函数与"直接聚合视图"逐商品相等；空区间、`NULL` 参数、起止倒置均返回 0 行 |
| S-07 | 区间末日 23:59:59 的订单被计入，次日 00:00:00 的不计入 |
| S-08 | `PICKED_UP` 与 `COMPLETED` 两类订单都出现在结果中；`CANCELLED`、未完成状态不出现 |
| S-09 | 套餐只计父行金额，`COMPONENT` 行不产生销售行 |

测试放在 `tests/stage3/a_programmability/`，分母硬编码，缺对象时判失败而不是跳过。

## 6. 变更记录

| 日期 | 变更 | 提出人 | 三人确认 |
| --- | --- | --- | --- |
| 2026-11-12 | 首次冻结：F-01 至 F-04，§1 销售口径、§2 折扣与分摊、§5 测试锚点 | A | 待 B/C 回执；回执前按本文执行，异议先改本节 |
| 2026-11-14 | 补附录 A：应用层计算清单（R10-06），结论为 Python 无业务计算，补货建议数量待 C 接函数 | A | — |

**变更规则：** 任何一条口径变化，必须同时更新本文、`20_schema_v1_1.sql`（如涉列）、`21a/21b` 实现、`28a/28b` 断言与 `13c` 版本常量，五处缺一不可；不允许只在代码里改。

## 附录 A：应用层计算清单（R10-06，2026-11-14 排查）

**目的：** 教学要求“应用里已经实现的替换掉”。先查清哪些业务值仍在 Python 里算，再决定第三阶段要改哪些页面。

**方法：** 通读 `app/{master,orders,inventory,auth,api,common}` 的 service/dao/routes，检索 `SUM`、`AVG`、`ROUND`、`price`、`amount`、`quantity` 与模板中的算术表达式；只读排查，未改任何 B/C 文件。

| 业务值 | 当前来源 | 应用层实际动作 | 判定 |
| --- | --- | --- | --- |
| 商品标准价、促销价、成交价 | `fn_get_effective_product_price`、`v_active_product_price`、下单过程 | `app/master` 只校验金额形状（`_money`）并原样传参；模板只显示 | 已在数据库 |
| 订单总额、明细单价、行金额 | `sp_create_order` / `sp_customer_place_order` 计算并落库，查询过程返回 | `app/orders` 不乘单价、不汇总；`total_amount` 直接展示 | 已在数据库 |
| 实付金额、退款金额 | `sp_pay_order`、`sp_cancel_or_refund_order` | 只校验 `Decimal` 位数与范围；不计算差额 | 已在数据库 |
| 可售量、低库存标记 | `v_inventory_available.available_qty`、`is_low_stock` | 页面直接显示三列，不在 Python 相减 | 已在数据库 |
| 补货建议数量 | 目前由页面人工填写，过程只落库 | **没有数据库计算**；`app/inventory` 把输入当值校验 | **应由 C 的 `fn_replenishment_qty` 接管** |
| 采购未清量 | `v_replenishment_dashboard.outstanding_qty` | 页面直接显示 | 已在数据库 |
| 销售汇总、排名、移动平均 | 第三阶段尚未实现 | 无 Python 汇总代码 | 3.1/3.2 新增，报表页只调过程/函数 |
| 会员折扣率与折扣额 | 第三阶段尚未实现 | 无 Python 折扣代码 | 3.1 新增，B 的页面只显示快照 |

**结论：**

1. 当前 `app/` 中**没有**在 Python 里计算金额、折扣、销售汇总或可售量的代码；`_money`、`_qty`、`_decimal` 只做输入形状校验，不算业务结果，不纳入替换清单。
2. 唯一“本该由数据库算、现在靠人工填”的是**补货建议数量**，由 C 在 3.1 把 `fn_replenishment_qty` 接进建议创建/页面默认值。
3. 第三阶段新增的三处展示必须遵守“只显示、不重算”：A 的销售报表页调 `sp_sales_report`；B 的订单页显示 `SalesOrderItem.discount_rate/discount_amount` 快照；C 的补货页显示函数结果。任何一处在 Python 里再乘、再除、再汇总，都算违反 R10-06。
4. 3.2 合并后再按本表复查一次，重点看新增的 `app/reports/`、订单折扣列和补货默认值。
