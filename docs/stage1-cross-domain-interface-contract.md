# 第一阶段跨域接口契约

> 版本：2026-09-21
>
> 用途：给 A、B、C 在独立分支上并行实现时提供稳定的对象名、参数名、返回列和事务边界。
>
> 本文档只定义契约，不创建空实现或测试桩。A、C 必须在各自负责的脚本中实现同名对象；B 只能调用，不能复制规则或直接写对方表。
>
> 2026-09-26：A 追加第 6–8 节（A 域种子常量、验收主体与跨域分工、待确认项），**待 B、C 确认后再并入上文**。

## 1. B 已交付给 C 的稳定对象

`sql/02_order_schema.sql` 创建 B 所有的五张表：

| 表 | C 可依赖的字段 | C 的后续动作 |
| --- | --- | --- |
| `dbo.SalesOrder` | `order_id`、`order_status`、`fulfillment_method`、时间戳 | 库存过程按 `order_id` 关联订单；不得直接改订单状态 |
| `dbo.SalesOrderItem` | `order_id`、`product_id`、`parent_order_item_id`、`item_role`、`quantity` | 锁库/实扣按 `SELLABLE` 单品和 `COMPONENT` 套餐子项展开 BOM |
| `dbo.Payment` | `order_id`、支付状态和金额快照 | C 不写入 |
| `dbo.Delivery` | `order_id`、`rider_employee_id`（可空） | C 在自己的脚本中补骑手外键；未分配骑手时保持可空 |
| `dbo.PointLedger` | `order_id`、`customer_id`、`point_delta`、`ledger_status` | C 不写入 |

C 可以在自己的 schema 脚本中补充 `Delivery.rider_employee_id -> EmployeeAccount.employee_id` 外键。

## 2. A 提供给 B 的接口

### 2.1 成交价函数

```sql
dbo.fn_get_effective_product_price
(
    @product_id BIGINT,
    @at         DATETIME2(0)
)
RETURNS TABLE
(
    product_id      BIGINT,
    effective_price DECIMAL(10,2),
    promotion_id    BIGINT NULL
)
```

约束：

1. 必须是内联表值函数，每次调用恰好返回一行。
2. 无命中促销时返回标准价和 `NULL` 的 `promotion_id`。
3. 促销必须同时满足活动启用、日期、星期及时段条件。
4. 多条规则命中时按 `priority DESC, promotion_rule_id ASC` 取唯一一条。
5. 星期映射使用 `DATEDIFF(DAY, DATEFROMPARTS(1900,1,1), CAST(@at AS DATE)) % 7 + 1`，不能使用受 `DATEFIRST` 影响的 `DATEPART(WEEKDAY, ...)`。
6. B 的 `sp_create_order` 和 A 的 `v_active_product_price` 都调用此函数，不得复制促销判断。

### 2.2 积分入账过程

```sql
dbo.sp_apply_customer_points
    @customer_id BIGINT,
    @delta       INT
```

约束：

1. 只更新 A 所有的 `Customer.current_points` 和 `Customer.member_level_id`。
2. 先以 `UPDLOCK, HOLDLOCK` 锁定顾客，再将积分加到当前已生效积分。
3. 从 `ACTIVE` 的 `MemberLevel` 中选择 `threshold_points <= 更新后积分` 的最高门槛；同门槛取 `member_level_id` 最小者。
4. 不读取、不更新 B 的 `PointLedger`。
5. `@delta` 不得为负；顾客不存在或已停用时必须 `THROW`。
6. 支持嵌套事务：无外层事务时自行提交；有外层事务时只建立保存点，失败回滚到保存点并 `THROW`。

## 3. C 提供给 B 的接口

以下过程名、参数名和参数类型固定。B 的外层事务由 B 持有，C 过程必须支持嵌套调用。

### 3.1 锁定订单库存

```sql
dbo.sp_lock_order_inventory
    @order_id BIGINT
```

- 读取同订单的 `SELLABLE` 单品和 `COMPONENT` 套餐子项，通过 `ProductBom` 汇总原料需求。
- 套餐父项不能直接当作有 BOM 的单品；库存行使用 `UPDLOCK, HOLDLOCK`。
- 成功后增加 `locked_qty`，写 `LOCK` 流水，引用类型为 `ORDER`，引用 ID 为订单 ID。
- 库存不足或订单明细非法时必须抛错，调用方外层事务应整体回滚。

### 3.2 释放订单库存

```sql
dbo.sp_release_order_inventory
    @order_id BIGINT,
    @reason   VARCHAR(20)
```

`@reason` 只允许：`CANCEL`、`PAYMENT_TIMEOUT`、`REFUND`。

- 只能释放尚未实扣的锁定量。
- 写 `RELEASE` 流水：`on_hand_delta = 0`、`locked_delta = -释放量`。
- 已经 `CONSUME` 的订单必须抛错，不能静默加回库存。

### 3.3 实扣订单库存

```sql
dbo.sp_consume_order_inventory
    @order_id BIGINT
```

- 制作完成时调用；同等数量减少 `on_hand_qty` 和 `locked_qty`。
- 写 `CONSUME` 流水：`on_hand_delta = -实扣量`、`locked_delta = -实扣量`。
- 实扣后按 `Ingredient.safety_stock_qty - Inventory.on_hand_qty` 生成或更新补货建议。
- 库存永不得为负。

### 3.4 审计写入

```sql
dbo.sp_write_audit_log
    @employee_id  BIGINT,
    @action_name  VARCHAR(50),
    @entity_name  VARCHAR(50),
    @entity_id    BIGINT,
    @detail_json  NVARCHAR(MAX)
```

- 只写 C 所有的 `AuditLog`，调用方不得直接写审计表。
- 过程内部按 `EmployeeAccount.database_user_name = USER_NAME()` 校验当前激活员工，不能信任伪造的员工 ID。
- 保持 `dbo` 所有权链，使 A/B 通过 `EXECUTE` 调用即可。
- `detail_json` 只记录业务字段，不记录完整支付报文、密码或敏感凭证。

### 3.5 C 自有但一并冻结的收货过程

```sql
dbo.sp_receive_inventory
    @purchase_order_id BIGINT,
    @employee_id       BIGINT
```

该过程不由 B 调用，但名称和参数供 C 的补货验收脚本使用。

## 4. 事务与所有权边界

| 调用方 | 被调用方 | 规则 |
| --- | --- | --- |
| B | A 的定价函数 | 只读，返回成交价快照 |
| B | A 的积分过程 | B 先将 `PointLedger` 从 `PENDING` 改为 `EFFECTIVE`，再调用 A；两者在同一外层事务 |
| B | C 的锁库/释放/实扣过程 | B 持有订单外层事务，C 只用保存点，不提交 B 的事务 |
| B | C 的审计过程 | B 完成取消/退款后调用，失败则整体回滚 |
| A/C | B 的订单表 | 只读或建立外键；不得直接改变订单、支付和积分状态 |

任何一方都不能用直接 `INSERT/UPDATE/DELETE` 绕过另一方的业务过程。

## 5. 接入顺序与当前边界

1. 先执行 A 的 `01_master_schema.sql` 和本目录的 `02_order_schema.sql`。
2. A 按第 2 节创建两个接口和 A 的约束/CRUD。
3. C 按第 3 节创建库存、审计过程，并补 `Delivery.rider_employee_id` 外键。
4. A/C 完成后，再接入 B 的 `05_order_constraints_crud.sql`、视图、种子和验收脚本。

本文档和 `02_order_schema.sql` 是可提前共享的稳定部分；B 的业务过程实现、种子数据和验收脚本仍保留在本地 B 分支，避免未确定的实现先进入远端。

---

## 6. A 已冻结的种子常量（`09a_master_seed_data.sql`，2026-09-26）

以下 ID 与数值由 A 的 `09a` 用显式 `IDENTITY_INSERT` 固定，B/C 的种子与验收脚本可直接引用。A 若改动会先通知。

| 对象 | 固定 ID 与内容 |
| --- | --- |
| `Category` | `1` 主餐、`2` 小食饮品 |
| `Ingredient` | `1` 鸡腿肉（片，安全线 40.000）、`2` 汉堡面包（片，40.000）、`3` 生菜（克，500.000）、`4` 沙拉酱（克，800.000）、`5` 薯条（克，1000.000）、`6` 可乐原浆（毫升，2000.000） |
| `Product` | `1` 香辣鸡腿堡 19.00 SINGLE、`2` 劲脆鸡腿堡 17.50 SINGLE、`3` 薯条(中) 12.00 SINGLE、`4` 可乐(中) 9.00 SINGLE、`5` 双人分享餐 45.00 **COMBO**、`6` 鲜蔬沙拉 14.00 SINGLE |
| `MemberLevel` | `1` 普通会员 ×1.00 门槛 0、`2` 银卡会员 ×1.20 门槛 500、`3` 金卡会员 ×1.50 门槛 1500 |
| `Customer` | `1` `13900000001` GUEST（无等级、0 分）、`2` `13900000002` WOW（等级 2、500 分）、`3` `13900000003` PAID（等级 3、1500 分） |
| `Promotion` | `1` 疯狂星期四 FIXED_PRICE，2026-01-01 至 2030-12-31，`ACTIVE`；规则 `1`（商品 1、周四、9.90、`priority` 10）、规则 `2`（商品 1、周四、12.00、`priority` 5） |

约定：

1. **会员门槛 0 / 500 / 1500** 供 B 的升级反例使用：A 的 `sp_apply_customer_points` 取 `threshold_points <= 积分` 的最高档，同门槛取最小 `member_level_id`。
2. **压线原料是 `ingredient_id = 5`（薯条，安全线 1000.000 克）**。请 C 的 `09c` 把它的期初 `on_hand_qty` 设在安全线附近，使 B 的制作完成实扣后能落到线下并触发补货建议（计划 C-3 与 E2E-06 靠这个衔接）。
3. **促销按 `weekday_no` 生效**，周四用 `weekday_no = 4` 表达，与部署当天是星期几无关。`v_active_product_price` 内部写死 `SYSDATETIME()`，所以任何断言促销价的脚本都必须传**固定的周四时刻**，否则断言会退化成标准价。
4. **号段**：A 的种子顾客占 `13900000001`–`3`；`139000099xx` 保留给 A 的验收夹具。请 B/C 的种子用别的号段（`Customer.mobile` 有唯一约束）。
5. **套餐不配直接 BOM**：套餐 5 只在 `ComboComponent` 里有行（子项 1、2、4，其中 4 取 2 份）；`ProductBom` 中没有 `product_id = 5`。

## 7. A 域验收的跨域依赖与分工

### 7.1 写主体

- 三人验收脚本统一使用 `08_roles_permissions.sql` 冻结的测试主体：`test_store_manager`、`test_shift_manager`、`test_cashier` 等；凡调用写过程，一律 `EXECUTE AS USER = N'test_...'` 后 `REVERT`。
- A 的 18 个写过程只按 `EmployeeAccount.database_user_name = USER_NAME()` 解析 `ACTIVE` 员工，**不校验业务角色**；因此调用者只需"数据库角色成员资格 + 过程的 `EXECUTE`"（`08` 已把全部 A 域过程授予 `role_store_manager`）。
- **`10a` 依赖 `09c`**：`10a` 需要 `test_store_manager` 有一条 `status = 'ACTIVE'` 的 `EmployeeAccount` 行（计划 C-2 line 316 已定由 `09c` 插入）。`10a` 把这条列为部署前提，缺行时 `THROW 51900` 并在文案里点名 `09c`。请 C 确认 `09c` 覆盖，且该行的 `database_user_name` 恰为 `test_store_manager`。

### 7.2 种子边界

`10a` 断言的正是 A 域种子的**具体行数与内容**（A7/A8/A12/A13），所以：

- `09b`/`09c`/`09d` 只能**只读引用** A 域既有 ID，不得新增或修改 `Category`、`Product`、`ProductCategory`、`ProductBom`、`ComboComponent`、`Ingredient`、`MemberLevel`、`Promotion`、`PromotionProductRule` 的内容。
- `Customer` 的积分与等级允许经 A 的 `sp_apply_customer_points` 改变（那是业务态），但不要新增顾客行或改手机号。
- 需要夹具（"无 BOM 单品"、"子项无 BOM 的套餐"之类）的，请在**回滚事务内临时插入**，不要留在库里——`10a` 的 A9/A10/A11 就是这个做法。
- A 的 `09a` 只允许在空库上执行：它的守卫检查全部 10 张 A 域表，任一非空即 `THROW 51000`。

### 7.3 断言分工

A 的完工标准里有三条落在别人的脚本里：

| 完工标准 | 归属 | 说明 |
| --- | --- | --- |
| 改商品价不影响历史订单快照 | B 的 `10b` | A 只改 `Product.base_price`；快照列 `SalesOrderItem.unit_price` 是 B 的 |
| 无 BOM 单品不能下单 | B 的 `10b` | 走 `sp_create_order`；A 侧只负责"不能上架"（`10a` A9/A11） |
| B 能拿 A 的 `customer_id`/`product_id`/`promotion_id` 开出订单 | B 的 `10b` | 直接用第 6 节的 ID |
| C 能凭 `ingredient_id` + `ProductBom` 算出订单用料 | C 的 `10c` | 直接用第 6 节的 `ingredient_id` |

`10a` 已覆盖：重复手机号被拒、新顾客建档初始态、负数价格被拒、正数价格可改且落库、促销起止校验、建档即 `INACTIVE`、重叠促销取唯一最高优先级、视图与定价函数同价同促销 ID、无用料单品不能上架、有用料单品可上架、子项无用料的套餐不能上架、BOM 视图单品分支、BOM 视图套餐分支（展开、按子项数量缩放、跨子项合计）。

### 7.4 断言写法约定（沿用计划 line 341）

1. 每条断言各自成批、事务包裹，结束一律 `ROLLBACK`，不得把夹具或状态残留给下一条。
2. "故意抛错"只允许以违反既有约束或外键的方式注入，不得为测试给过程加开关参数。
3. **失败文案要带出实际错误码与原始报错文本**。`CATCH` 会吞掉原报错，只报"错误码不是 51005"会把 229（权限不足）、547（外键冲突）之类误读成"校验没生效"。
4. 反例必须配一条"同类操作应当成功"的对照，否则过程恒抛错时反例会恒真而看不出来。
5. 两个语法限制（A 写 `10a` 时都撞过）：`THROW` 的 message 位只收**变量或字符串常量**，`EXEC` 的实参位只收**常量或变量**——两者都不接受 `CONCAT(...)`／`CAST(...)` 这类表达式，必须先 `DECLARE`/`SET` 到变量再传。
6. 行数断言的"非空洞性守卫"不要写死全局行数（下游种子跑在前面，别人加数据是允许的），断言"自己关心的那几行都在且一致"即可。

## 8. 待确认项（A 侧汇总）

| # | 事项 | 提出 | 待定方 |
| --- | --- | --- | --- |
| 1 | `sp_receive_inventory` 是否增加第三个参数 `@received_qty DECIMAL(12,3)`：第 3.5 节冻结的两参形态无法表达"本次实收多少"，两次收货验不出来 | C | B |
| 2 | `contract_interface_check.sql:52` 断言 `fn_get_effective_product_price` 的 `@at` 期望 `max_length = 8`；实测该参数是 `datetime2(0)`、`max_length = 6`、`scale = 0`（A 与 C 各自独立发现）。建议改判 `scale = 0`，或把期望值改为 6 | A、C | B |
| 3 | `v_order_inventory_trace` 是否授予 `role_shift_manager`（计划 line 311 只规定了该视图的语义，没规定授权） | C | A、B |

非接口性的待确认项（`08` 的 DMK 明文口令取舍、`sp_update_product_status` 仅在状态跃迁时校验 BOM 的残留代价、数据字典与 `01` 注释双份维护）已分别记录在计划变更记录与 `docs/主数据数据字典.md` §11，不在此重复。
